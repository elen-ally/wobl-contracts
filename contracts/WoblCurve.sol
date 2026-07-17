// SPDX-License-Identifier: MIT
// LOW-3: pragma pinned to a single exact version (matches the production solc-js
// build in lib/compile.js and the forge test harness in foundry.toml) so the
// audited bytecode is reproducible. The live contracts stay on floating ^0.8.20;
// this new, not-yet-deployed contract is pinned.
pragma solidity 0.8.36;

// ===========================================================================
// wobl.fun: bonding-curve launchpad (WoblCurve) + transfer-locked token
// (WoblToken).
//
// A NEW launch path that COEXISTS with the shipped direct-to-V3 `Launchpad.sol`
// (the ~960 live tokens are untouched). A WoblToken trades on an x*y=k
// virtual-reserve bonding curve (the constant-product "pump.fun" model, the
// universal standard for this token class) and when curve inventory is
// exhausted it GRADUATES and, in the same transaction, seeds a TWO-SIDED
// full-range Uniswap V3 1% pool and locks the LP NFT forever in the existing
// `RevSplitLocker` (80% creator / 20% protocol, immutable). Trading migrates to
// that pool.
//
// The curve constants are DERIVED from first principles for a smooth (zero-gap)
// graduation (see VTOK_SEED), so the LP opens at exactly the curve's final
// price with no arb-able discontinuity, the same continuous-price property
// pump.fun's own graduation has. Three defenses are layered against the
// graduation-freeze attack that a naive constant-product launchpad misses:
//   (a) the V3 pool is INITIALIZED AT TOKEN-CREATION at the deterministic final
//       price, so no external pre-init window exists;
//   (b) a creation-time deviation guard + salt rotation (the same defense
//       `Launchpad.sol` already ships) rejects a griefer who front-ran the pool
//       init, and creation reverting is SAFE (no funds are locked yet);
//   (c) the token is TRANSFER-LOCKED until graduation so no one can hold curve
//       tokens to add hostile liquidity before the seed.
//   Graduation therefore NEVER hard-reverts on pool state: the price is pinned.
//
// Security posture (NO formal audit; testnet gates + adversarial review are the
// compensating controls):
//   - ONE shared reentrancy guard across create/buy/sell/graduate; strict CEI
//     (all storage written before any external .call / token move).
//   - Reserves tracked in STORAGE only, never address(this).balance / balanceOf,
//     so a force-fed ETH/token transfer can never trip graduation or brick sell.
//   - Trade fee accrues to a SEPARATE accumulator, never into the curve reserves.
//   - Rounding floored against the user (buy: ceilDiv on the ETH the curve keeps;
//     sell: ceilDiv on the ETH removed), the standard integer rounding for a
//     constant-product curve.
//   - Last-buyer overage refunded from the DELIVERED tokens, not msg.value.
//   - Fees are PULL-based (claimCreatorFees / sweepProtocolFees).
//   - Ownership is a NEW-LAUNCHES-ONLY kill switch: the owner can pause
//     createToken (halt an exploited factory) and nothing else; it CANNOT touch
//     in-flight curve ETH, creator fees, a live curve's sell(), or the locked LP.
//     Renounceable. This is the only admin surface; everything else is immutable.
// ===========================================================================

// --------------------------------------------------------------------------
// Minimal external interfaces (self-contained: the solc-js build has no import
// resolution). Only the exact surface we touch is declared.
// --------------------------------------------------------------------------
interface INonfungiblePositionManager {
    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external payable returns (address pool);

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata params)
        external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality,
        uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked);
}

interface IWETH9 {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IWoblToken {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function unlock() external;
}

// --------------------------------------------------------------------------
// Math: self-contained ports (no OpenZeppelin). ceilDiv, integer sqrt, and the
// 512-bit mulDiv needed to compute sqrtPriceX96 without intermediate overflow
// (a1 * 2^192 overflows uint256 for our token-heavy amounts).
// --------------------------------------------------------------------------
library WMath {
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // LOW-1 SafeCast: checked narrowing casts so a reserve/amount downcast can
    // never silently truncate. Hand-rolled (solc-js has no import resolution, so
    // we do not import OpenZeppelin's SafeCast).
    function toUint128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max, "SAFECAST_128");
        return uint128(x);
    }

    function toUint160(uint256 x) internal pure returns (uint160) {
        require(x <= type(uint160).max, "SAFECAST_160");
        return uint160(x);
    }

    // Babylonian integer sqrt.
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // Uniswap FullMath.mulDiv: floor(a*b/denominator) with full 512-bit
    // intermediate precision. Reverts on overflow / division by zero.
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(denominator > 0);
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }
            require(denominator > prod1);

            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;

            result = prod0 * inverse;
            return result;
        }
    }
}

/// @title WoblToken
/// @notice Fixed-supply ERC-20 launched through the wobl.fun bonding curve. The
///         entire supply is minted to the curve launchpad at construction and is
///         TRANSFER-LOCKED (tokens can only move to or from the launchpad) until
///         the curve graduates and the launchpad calls `unlock()`. This closes the
///         pre-graduation exploit class where curve tokens are parked in a
///         not-yet-seeded DEX pool to manipulate the graduation price.
/// @dev Self-contained minimal ERC-20 (same shape as LaunchToken) so solc-js
///      compiles it with no dependencies. No owner, no mint-after-construction, no
///      blacklist, no fee-on-transfer.
contract WoblToken {
    string public name;
    string public symbol;
    string public metadataURI;
    address public immutable launchpad;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    bool public unlocked;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    /// @notice Emitted once, at graduation, when the transfer lock is lifted forever.
    event Unlocked();

    error TransfersLocked();
    error OnlyLaunchpad();

    constructor(string memory _name, string memory _symbol, uint256 _supplyWhole, string memory _metadataURI) {
        name = _name;
        symbol = _symbol;
        metadataURI = _metadataURI;
        launchpad = msg.sender;
        totalSupply = _supplyWhole * 1e18;
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    /// @notice EIP-7572 contract-level metadata; aggregators (Axiom, DexScreener)
    ///         probe this standard name to auto-pull the token logo/socials.
    function contractURI() external view returns (string memory) {
        return metadataURI;
    }

    /// @notice Called once by the launchpad at graduation; opens transfers forever.
    function unlock() external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        unlocked = true;
        emit Unlocked();
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "INSUFFICIENT_ALLOWANCE");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - value;
        }
        return _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        require(to != address(0), "ZERO_ADDRESS");
        // Transfer lock: until unlocked, tokens may only move to/from the
        // launchpad (buys, sells, the graduation seed). Mint (from == 0) is
        // exempt. Once graduated the lock is lifted forever.
        if (!unlocked && from != launchpad && to != launchpad) revert TransfersLocked();
        uint256 bal = balanceOf[from];
        require(bal >= value, "INSUFFICIENT_BALANCE");
        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
        return true;
    }
}

/// @title WoblCurve
/// @notice The public bonding-curve launchpad. See the file header for the full
///         design. One shared reentrancy guard, strict CEI, storage-only reserves.
contract WoblCurve {
    // ------------------------------------------------------------- immutables
    address public immutable nfpm;
    address public immutable factory;
    address public immutable weth;
    address public immutable locker;          // existing RevSplitLocker
    address public immutable protocolWallet;  // receives the 20% protocol fee share

    // Curve economics. Fixed 1B supply, 80% on the curve / 20% reserved for the
    // graduation LP. virtualEthSeed is the single knob that scales all ETH
    // economics (start MC + graduation raise scale linearly with it) and is a
    // constructor parameter so testnet can use a tiny value and mainnet a chosen
    // one.
    //
    // VTOK_SEED is DERIVED, not chosen: for a curve fraction f of supply S, the
    // virtual-token seed that makes the graduation LP open at EXACTLY the curve's
    // final marginal price (a smooth, arb-free transition) is
    //     V = f^2 * S / (2f - 1).
    // With f = 0.8, S = 1e9 this is 0.64e9 / 0.6 = 1,066,666,667 tokens. This is
    // the same continuous-price property pump.fun's graduation has, and it means
    // the reserved 20% pairs with the raised ETH at the curve's exit price with no
    // orphaned surplus and no price jump. (A larger seed opens the LP ABOVE the
    // exit price = an instant arb dump; a smaller one leaves an orphan tranche.)
    uint256 public constant SUPPLY_WHOLE = 1_000_000_000;
    uint256 public constant SUPPLY_RAW = 1_000_000_000e18;
    uint256 public constant CURVE_SUPPLY_RAW = 800_000_000e18; // 80% sells on the curve
    uint256 public constant LP_SUPPLY_RAW = 200_000_000e18;    // 20% seeds the LP
    uint256 public constant VTOK_SEED = 1_066_666_667e18;      // f^2*S/(2f-1), smooth graduation
    uint256 public constant TRADE_FEE_BPS = 100;               // 1% on the ETH leg
    uint16 public constant PROTOCOL_FEE_SHARE_BPS = 2000;      // 20% of trade fees to protocol
    uint256 internal constant BPS = 10_000;
    // Seed-mint slippage floor (5%). Loose on purpose: a legitimate graduation
    // consumes ~100% of both seed sides (the price is pinned), so this never
    // reverts a benign graduation; it only bites if a FUTURE change weakened the
    // transfer lock and let someone grossly poison the pool price before the seed.
    uint256 internal constant SEED_MIN_BPS = 9_500;

    uint128 public immutable virtualEthSeed;   // ETH-economics knob (wei)
    uint16 public immutable migrationFeeBps;   // skimmed from the raise at graduation

    // Uniswap V3 1% tier: fee 10000, tick spacing 200. Full range as usable ticks.
    uint24 internal constant FEE = 10000;
    int24 internal constant MIN_TICK = -887200;
    int24 internal constant MAX_TICK = 887200;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ---------------------------------------------------------------- storage
    struct Curve {
        uint128 virtualEth;
        uint128 virtualTokens;
        uint128 realEth;        // == virtualEth - virtualEthSeed at all times (net ETH in curve)
        uint128 realTokens;     // curve inventory remaining; graduation triggers at 0
        address creator;
        uint64 createdAt;       // block.timestamp (block.number is the L1 block on 4663, unusable)
        bool graduated;
        bool migrated;
    }
    // Buy quote result: a memory struct keeps _buy's live-stack small enough to
    // compile without viaIR (the solc-js build must never enable viaIR).
    struct BuyResult {
        uint256 tokensOut;
        uint256 ethForCurve;
        uint256 fee;
        uint256 refund;
    }
    mapping(address => Curve) public curves;
    mapping(address => uint256) public creatorFees;   // pull-based, per token
    mapping(address => uint256) public pool;          // token => its pre-initialized V3 pool
    uint256 public protocolFeesAccrued;               // pull-based, swept to protocolWallet
    address[] public allTokens;

    // Ownership: new-launches-only kill switch. Nothing else.
    // LOW-2: 2-step ownership: a transfer must be accepted by the incoming owner,
    // so a mistyped address cannot brick the (already minimal) admin surface.
    address public owner;
    address public pendingOwner;
    bool public paused;

    uint256 private _entered = 1; // shared reentrancy guard: 1 = free, 2 = entered

    // ----------------------------------------------------------------- events
    event TokenCreated(
        address indexed token,
        address indexed creator,
        address pool,
        uint256 virtualEth,
        uint256 virtualTokens,
        uint256 curveSupply
    );
    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 fee,
        uint256 virtualEthAfter,
        uint256 virtualTokensAfter
    );
    event Graduated(address indexed token, uint256 raisedEth);
    event Migrated(address indexed token, address indexed pool, uint256 tokenId, uint256 ethLiquidity, uint256 tokenLiquidity);
    event CreatorFeesClaimed(address indexed token, address indexed creator, uint256 amount);
    event ProtocolFeesSwept(address indexed to, uint256 amount);
    event PausedSet(bool paused);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ----------------------------------------------------------------- errors
    error Reentrancy();
    error ZeroAddress();
    error Paused();
    error NotOwner();
    error UnknownToken();
    error AlreadyGraduated();
    error NotGraduated();
    error AlreadyMigrated();
    error ZeroAmount();
    error SlippageExceeded();
    error EthTransferFailed();
    error NothingToClaim();
    error NotCreator();
    error PoolMismatch();
    error PriceDeviation();
    error MintFailed();
    error LockFailed();
    error BadSeed();
    error DeadlineExpired();

    modifier nonReentrant() {
        if (_entered == 2) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address nfpm_,
        address factory_,
        address weth_,
        address locker_,
        address protocolWallet_,
        uint128 virtualEthSeed_,
        uint16 migrationFeeBps_,
        address owner_
    ) {
        if (nfpm_ == address(0) || factory_ == address(0) || weth_ == address(0)
            || locker_ == address(0) || protocolWallet_ == address(0)) revert ZeroAddress();
        if (virtualEthSeed_ == 0) revert ZeroAmount();
        if (migrationFeeBps_ > 1000) revert BadSeed(); // migration fee hard-capped at 10%
        // vTokSeed must exceed curve supply so vTok_final > 0.
        if (VTOK_SEED <= CURVE_SUPPLY_RAW) revert BadSeed();
        nfpm = nfpm_;
        factory = factory_;
        weth = weth_;
        locker = locker_;
        protocolWallet = protocolWallet_;
        virtualEthSeed = virtualEthSeed_;
        migrationFeeBps = migrationFeeBps_;
        owner = owner_; // may be address(0) to launch ownerless
    }

    // Accept ETH only from WETH (defensive; buys arrive via payable buy()).
    receive() external payable {
        require(msg.sender == weth, "ETH only from WETH");
    }

    // =====================================================================
    // Views / CREATE2 prediction (frontend reads these free)
    // =====================================================================
    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }

    function getTokens(uint256 start, uint256 count) external view returns (address[] memory out) {
        uint256 n = allTokens.length;
        if (start >= n) return new address[](0);
        uint256 end = start + count > n ? n : start + count;
        out = new address[](end - start);
        for (uint256 i = start; i < end; i++) out[i - start] = allTokens[i];
    }

    function getCurve(address token) external view returns (Curve memory) {
        return curves[token];
    }

    /// @notice Deterministic graduation raise (theoretical, continuous): the net
    ///         ETH the curve holds once all CURVE_SUPPLY tokens are sold.
    function graduationRaise() public view returns (uint256) {
        // raise = vEthSeed * CURVE_SUPPLY / (VTOK_SEED - CURVE_SUPPLY)
        return WMath.mulDiv(virtualEthSeed, CURVE_SUPPLY_RAW, VTOK_SEED - CURVE_SUPPLY_RAW);
    }

    /// @notice Spot price: ETH wei per whole token (1e18 base units).
    function currentPrice(address token) external view returns (uint256) {
        Curve memory c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        return (uint256(c.virtualEth) * 1e18) / c.virtualTokens;
    }

    /// @notice Curve progress toward graduation in basis points.
    function progressBps(address token) external view returns (uint256) {
        Curve memory c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        return ((CURVE_SUPPLY_RAW - c.realTokens) * BPS) / CURVE_SUPPLY_RAW;
    }

    function tokenInitCodeHash(
        string memory name_, string memory symbol_, uint256 supplyWhole_, string memory metadataURI_
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            type(WoblToken).creationCode,
            abi.encode(name_, symbol_, supplyWhole_, metadataURI_)
        ));
    }

    function predictToken(
        address creator, bytes32 salt,
        string memory name_, string memory symbol_, string memory metadataURI_
    ) external view returns (address) {
        bytes32 fullSalt = keccak256(abi.encodePacked(creator, salt));
        return address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", address(this), fullSalt,
            tokenInitCodeHash(name_, symbol_, SUPPLY_WHOLE, metadataURI_)
        )))));
    }

    function quoteBuy(address token, uint256 ethIn)
        external view returns (uint256 tokensOut, uint256 fee, uint256 ethUsed)
    {
        Curve memory c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        if (c.graduated || ethIn == 0) return (0, 0, 0);
        fee = (ethIn * TRADE_FEE_BPS) / BPS;
        uint256 ethForCurve = ethIn - fee;
        // ceilDiv the retained reserve so tokensOut floors AGAINST the buyer
        // (k never leaks in the buyer's favour). Must match _computeBuy exactly.
        tokensOut = uint256(c.virtualTokens) - WMath.ceilDiv(uint256(c.virtualEth) * c.virtualTokens, uint256(c.virtualEth) + ethForCurve);
        ethUsed = ethIn;
        if (tokensOut >= c.realTokens) {
            tokensOut = c.realTokens;
            uint256 newVTok = uint256(c.virtualTokens) - c.realTokens;
            uint256 exactEth = WMath.ceilDiv(uint256(c.virtualEth) * c.virtualTokens, newVTok) - c.virtualEth;
            if (exactEth > ethForCurve) exactEth = ethForCurve;
            ethUsed = WMath.ceilDiv(exactEth * BPS, BPS - TRADE_FEE_BPS);
            if (ethUsed > ethIn) ethUsed = ethIn;
            fee = ethUsed - exactEth;
        }
    }

    function quoteSell(address token, uint256 tokenAmount) external view returns (uint256 ethOut, uint256 fee) {
        Curve memory c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        if (c.graduated || tokenAmount == 0) return (0, 0);
        uint256 gross = uint256(c.virtualEth)
            - WMath.ceilDiv(uint256(c.virtualEth) * c.virtualTokens, uint256(c.virtualTokens) + tokenAmount);
        fee = (gross * TRADE_FEE_BPS) / BPS;
        ethOut = gross - fee;
    }

    // =====================================================================
    // Create
    // =====================================================================
    /// @notice Deploy a token + curve and pre-initialize its graduation V3 pool at
    ///         the deterministic final price. Any ETH beyond zero is the creator's
    ///         atomic first buy.
    function createToken(
        string calldata name_,
        string calldata symbol_,
        string calldata metadataURI_,
        uint256 minTokensOut,
        bytes32 salt
    ) external payable nonReentrant returns (address token) {
        if (paused) revert Paused();

        bytes32 fullSalt = keccak256(abi.encodePacked(msg.sender, salt));
        token = address(new WoblToken{salt: fullSalt}(name_, symbol_, SUPPLY_WHOLE, metadataURI_));

        address poolAddr = _initPool(token);
        pool[token] = uint256(uint160(poolAddr));

        curves[token] = Curve({
            virtualEth: virtualEthSeed,
            virtualTokens: WMath.toUint128(VTOK_SEED),
            realEth: 0,
            realTokens: WMath.toUint128(CURVE_SUPPLY_RAW),
            creator: msg.sender,
            createdAt: uint64(block.timestamp),
            graduated: false,
            migrated: false
        });
        allTokens.push(token);

        emit TokenCreated(token, msg.sender, poolAddr, virtualEthSeed, VTOK_SEED, CURVE_SUPPLY_RAW);

        if (msg.value > 0) {
            _buy(token, msg.sender, msg.value, minTokensOut);
        } else if (minTokensOut != 0) {
            revert SlippageExceeded();
        }
    }

    /// @dev Create + initialize the graduation pool at the deterministic final
    ///      price and reject a hostile pre-init. Reverting here is SAFE (nothing is
    ///      locked yet); the frontend rotates `salt` and retries, exactly like
    ///      Launchpad.sol. Once we init successfully the price is pinned forever
    ///      (V3 pools cannot be re-initialized) and the transfer lock prevents any
    ///      liquidity being added before graduation, so graduation never reverts.
    function _initPool(address token) internal returns (address poolAddr) {
        uint160 sqrtP = _graduationSqrtPrice(token);
        (address token0, address token1) = token < weth ? (token, weth) : (weth, token);
        poolAddr = INonfungiblePositionManager(nfpm).createAndInitializePoolIfNecessary(token0, token1, FEE, sqrtP);
        if (poolAddr == address(0) || poolAddr != IUniswapV3Factory(factory).getPool(token0, token1, FEE)) {
            revert PoolMismatch();
        }
        (uint160 cur,,,,,,) = IUniswapV3Pool(poolAddr).slot0();
        // Reject a pre-existing pool initialized at a foreign price (>~1% sqrt
        // deviation). Fresh pools return exactly sqrtP -> deviation 0.
        uint160 hi = cur > sqrtP ? cur : sqrtP;
        uint160 lo = cur > sqrtP ? sqrtP : cur;
        if (cur == 0 || uint256(hi - lo) * BPS > uint256(hi) * 100) revert PriceDeviation();
    }

    /// @dev The pool price at graduation = sqrt(amount1/amount0)*2^96 over the
    ///      final LP amounts (LP_SUPPLY tokens + the raise net of migration fee),
    ///      ordered by token address. Deterministic from immutables, so it is the
    ///      same at creation and at graduation.
    function _graduationSqrtPrice(address token) internal view returns (uint160) {
        uint256 raise = graduationRaise();
        uint256 ethLiq = raise - (raise * migrationFeeBps) / BPS;
        (uint256 a0, uint256 a1) = token < weth ? (LP_SUPPLY_RAW, ethLiq) : (ethLiq, LP_SUPPLY_RAW);
        // sqrtPriceX96 = sqrt(a1 * 2^192 / a0)
        uint256 ratioX192 = WMath.mulDiv(a1, 1 << 192, a0);
        uint256 s = WMath.sqrt(ratioX192);
        // LOW-1: checked narrowing to uint160 (reverts on overflow).
        return WMath.toUint160(s);
    }

    // =====================================================================
    // Trade
    // =====================================================================
    function buy(address token, uint256 minTokensOut, uint256 deadline) external payable nonReentrant {
        if (block.timestamp > deadline) revert DeadlineExpired(); // LOW-4
        if (msg.value == 0) revert ZeroAmount();
        _requireLiveCurve(token);
        _buy(token, msg.sender, msg.value, minTokensOut);
    }

    function sell(address token, uint256 tokenAmount, uint256 minEthOut, uint256 deadline) external nonReentrant {
        if (block.timestamp > deadline) revert DeadlineExpired(); // LOW-4
        if (tokenAmount == 0) revert ZeroAmount();
        Curve storage c = _requireLiveCurve(token);

        uint256 vEth = c.virtualEth;
        uint256 vTok = c.virtualTokens;
        // ceilDiv floors the ETH removed AGAINST the seller (they receive less).
        uint256 ethOut = vEth - WMath.ceilDiv(vEth * vTok, vTok + tokenAmount);
        uint256 fee = (ethOut * TRADE_FEE_BPS) / BPS;
        uint256 ethToSeller = ethOut - fee;
        if (ethToSeller < minEthOut || ethToSeller == 0) revert SlippageExceeded();

        // CEI: all state written before the token pull and the ETH payout.
        c.virtualEth = WMath.toUint128(vEth - ethOut);
        c.virtualTokens = WMath.toUint128(vTok + tokenAmount);
        c.realEth = WMath.toUint128(uint256(c.realEth) - ethOut);
        c.realTokens = WMath.toUint128(uint256(c.realTokens) + tokenAmount);
        _accrueFee(token, fee);

        emit Trade(token, msg.sender, false, ethToSeller, tokenAmount, fee, c.virtualEth, c.virtualTokens);

        require(IWoblToken(token).transferFrom(msg.sender, address(this), tokenAmount), "TRANSFER_FAILED");
        (bool ok,) = msg.sender.call{value: ethToSeller}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev Standard constant-product buy quote with the last-buyer exact-fill +
    ///      overage refund. Split out so _buy's live stack stays small (no viaIR).
    function _computeBuy(Curve storage c, uint256 ethIn) internal view returns (BuyResult memory b) {
        uint256 vEth = c.virtualEth;
        uint256 vTok = c.virtualTokens;
        uint256 realTokens = c.realTokens;

        b.fee = (ethIn * TRADE_FEE_BPS) / BPS;
        b.ethForCurve = ethIn - b.fee;
        // ceilDiv the retained reserve so tokensOut floors AGAINST the buyer; must
        // stay identical to quoteBuy so an on-chain quote never disagrees with the fill.
        b.tokensOut = vTok - WMath.ceilDiv(vEth * vTok, vEth + b.ethForCurve);

        if (b.tokensOut >= realTokens) {
            // Last buy: fill exactly the remaining inventory, recompute the exact
            // ETH the curve keeps, and refund the overage from msg.value.
            b.tokensOut = realTokens;
            uint256 exactEth = WMath.ceilDiv(vEth * vTok, vTok - realTokens) - vEth;
            if (exactEth > b.ethForCurve) exactEth = b.ethForCurve;
            uint256 grossEth = WMath.ceilDiv(exactEth * BPS, BPS - TRADE_FEE_BPS);
            if (grossEth > ethIn) grossEth = ethIn;
            b.refund = ethIn - grossEth;
            b.fee = grossEth - exactEth;
            b.ethForCurve = exactEth;
        }
    }

    /// @dev The buy core. CEI throughout; graduation (if this buy empties the
    ///      curve) runs AFTER all curve state is committed.
    function _buy(address token, address recipient, uint256 ethIn, uint256 minTokensOut) internal {
        Curve storage c = curves[token];
        BuyResult memory b = _computeBuy(c, ethIn);

        if (b.tokensOut < minTokensOut || b.tokensOut == 0) revert SlippageExceeded();

        // CEI: commit curve state before any external call.
        c.virtualEth = WMath.toUint128(uint256(c.virtualEth) + b.ethForCurve);
        c.virtualTokens = WMath.toUint128(uint256(c.virtualTokens) - b.tokensOut);
        c.realEth = WMath.toUint128(uint256(c.realEth) + b.ethForCurve);
        c.realTokens = WMath.toUint128(uint256(c.realTokens) - b.tokensOut);
        _accrueFee(token, b.fee);

        bool graduating = (c.realTokens == 0);
        if (graduating) {
            c.graduated = true;
            emit Graduated(token, c.realEth);
        }

        emit Trade(token, recipient, true, b.ethForCurve + b.fee, b.tokensOut, b.fee, c.virtualEth, c.virtualTokens);

        require(IWoblToken(token).transfer(recipient, b.tokensOut), "TRANSFER_FAILED");

        // Atomic auto-migration: the tx that fills the curve also seeds + locks the
        // V3 pool. State is already committed, so this is a post-CEI external step.
        if (graduating) {
            _migrate(token, c);
        }

        if (b.refund > 0) {
            (bool ok,) = msg.sender.call{value: b.refund}("");
            if (!ok) revert EthTransferFailed();
        }
    }

    function _accrueFee(address token, uint256 fee) internal {
        if (fee == 0) return;
        uint256 protocolCut = (fee * PROTOCOL_FEE_SHARE_BPS) / BPS;
        protocolFeesAccrued += protocolCut;
        creatorFees[token] += fee - protocolCut;
    }

    // =====================================================================
    // Graduate / migrate
    // =====================================================================
    // Graduation is ATOMIC inside the buy that empties the curve (see _buy): the same
    // tx that sets `graduated` also runs `_migrate` which sets `migrated`. Under the
    // transfer-lock + pinned-price invariants that seed cannot revert, so in normal
    // operation the `graduated && !migrated` state never persists.
    //
    // MEDIUM-1 safety net: `finishGraduation` is a permissionless, idempotent recovery
    // entrypoint reachable ONLY in that `graduated && !migrated` state. If a FUTURE
    // change (or an unforeseen Uniswap edge) ever left a curve graduated-but-unseeded,
    // anyone can complete the two-sided V3 seed + LP lock without an admin key. It is a
    // no-op-by-revert once migration has happened (`AlreadyMigrated`), so calling it
    // twice is safe. Creator is still read from storage inside `_migrate`, never the
    // caller, so there is no self-deal or bounty (INV-11).
    function finishGraduation(address token) external nonReentrant {
        Curve storage c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        if (!c.graduated) revert NotGraduated();
        if (c.migrated) revert AlreadyMigrated();
        _migrate(token, c);
    }

    /// @dev Seeds a TWO-SIDED full-range V3 position (the reserved 20% supply + the
    ///      raised ETH) into the pool that was initialized at CREATION at this exact
    ///      price, then hands the NFT to the RevSplitLocker forever. The creator is
    ///      read from storage (NEVER msg.sender), so the graduation caller gets no
    ///      fee rights and no bounty. Never hard-reverts on pool price; it is
    ///      pinned by the transfer lock + the creation-time init.
    function _migrate(address token, Curve storage c) internal returns (address poolAddr) {
        c.migrated = true; // CEI: kills re-entry / double-migration first

        uint256 ethLiq = c.realEth;
        uint256 migFee = (ethLiq * migrationFeeBps) / BPS;
        if (migFee > 0 && migFee < ethLiq) {
            ethLiq -= migFee;
            protocolFeesAccrued += migFee;
        }
        c.realEth = 0;

        IWoblToken(token).unlock();

        uint256 tokenId = _seedAndLockTwoSided(token, ethLiq, c.creator);

        poolAddr = address(uint160(pool[token]));
        emit Migrated(token, poolAddr, tokenId, ethLiq, LP_SUPPLY_RAW);
    }

    /// @dev Seeds the two-sided full-range V3 position (reserved 20% supply + the
    ///      raised ETH) into the pool already initialized at creation at this exact
    ///      price, hands the NFT to the RevSplitLocker forever (creator from
    ///      storage, never msg.sender), and sweeps seed dust. Own frame so
    ///      _migrate compiles without viaIR.
    function _seedAndLockTwoSided(address token, uint256 ethLiq, address creator) internal returns (uint256 tokenId) {
        (address token0, address token1) = token < weth ? (token, weth) : (weth, token);
        (uint256 a0, uint256 a1) = token < weth ? (LP_SUPPLY_RAW, ethLiq) : (ethLiq, LP_SUPPLY_RAW);

        IWETH9(weth).deposit{value: ethLiq}();
        IWETH9(weth).approve(nfpm, ethLiq);
        IWoblToken(token).approve(nfpm, LP_SUPPLY_RAW);

        INonfungiblePositionManager.MintParams memory mp;
        mp.token0 = token0;
        mp.token1 = token1;
        mp.fee = FEE;
        mp.tickLower = MIN_TICK;
        mp.tickUpper = MAX_TICK;
        mp.amount0Desired = a0;
        mp.amount1Desired = a1;
        // See SEED_MIN_BPS: a non-zero floor so the seed reverts rather than mints
        // into a grossly mispriced pool, without ever tripping on a benign graduation.
        mp.amount0Min = (a0 * SEED_MIN_BPS) / BPS;
        mp.amount1Min = (a1 * SEED_MIN_BPS) / BPS;
        mp.recipient = address(this);
        mp.deadline = block.timestamp;

        uint128 liquidity;
        (tokenId, liquidity, , ) = INonfungiblePositionManager(nfpm).mint(mp);
        if (liquidity == 0) revert MintFailed();

        INonfungiblePositionManager(nfpm).safeTransferFrom(
            address(this), locker, tokenId, abi.encode(creator, token0, token1)
        );
        if (INonfungiblePositionManager(nfpm).ownerOf(tokenId) != locker) revert LockFailed();

        // Sweep seed dust: leftover WETH -> protocol; leftover token -> burn.
        uint256 wLeft = IWETH9(weth).balanceOf(address(this));
        if (wLeft > 0) IWETH9(weth).transfer(protocolWallet, wLeft);
        uint256 tLeft = IWoblToken(token).balanceOf(address(this));
        if (tLeft > 0) IWoblToken(token).transfer(DEAD, tLeft);
    }

    // =====================================================================
    // Fee claims (pull-based)
    // =====================================================================
    function claimCreatorFees(address token) external nonReentrant {
        if (curves[token].creator != msg.sender) revert NotCreator();
        uint256 amount = creatorFees[token];
        if (amount == 0) revert NothingToClaim();
        creatorFees[token] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit CreatorFeesClaimed(token, msg.sender, amount);
    }

    /// @notice Permissionless: sweeps the protocol's accrued trade+migration fees to
    ///         the immutable protocolWallet (anyone may trigger, nobody can redirect).
    function sweepProtocolFees() external nonReentrant {
        uint256 amount = protocolFeesAccrued;
        if (amount == 0) revert NothingToClaim();
        protocolFeesAccrued = 0;
        (bool ok,) = protocolWallet.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit ProtocolFeesSwept(protocolWallet, amount);
    }

    // =====================================================================
    // Ownership: new-launches-only kill switch (nothing else)
    // =====================================================================
    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    /// @notice LOW-2: step 1 of a 2-step transfer. Nominates `newOwner`; the transfer
    ///         only completes when `newOwner` calls `acceptOwnership`. A zero-address
    ///         guard prevents accidentally bricking the admin surface (use
    ///         `renounceOwnership` to intentionally go ownerless).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice LOW-2: step 2, the nominated owner claims ownership.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
        pendingOwner = address(0);
    }

    // ------------------------------------------------------------- internals
    function _requireLiveCurve(address token) internal view returns (Curve storage c) {
        c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        if (c.graduated) revert AlreadyGraduated();
    }
}
