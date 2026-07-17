// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ---------------------------------------------------------------------------
// Minimal external interfaces (self-contained: lib/compile.js has no import
// resolution).
// ---------------------------------------------------------------------------
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
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality,
        uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title LaunchToken
/// @notice Minimal, maximally-trustless fixed-supply ERC-20 deployed by the
///         Launchpad for every launch. Deliberately has:
///           - NO owner / admin / upgrade path
///           - NO mint function after construction (supply is fixed forever)
///           - NO blacklist, NO transfer fee, NO pausing
///         The entire supply is minted to the Launchpad at construction, which
///         immediately seeds ALL of it into a permanently-locked Uniswap V3
///         position; nothing here can rug holders.
contract LaunchToken {
    string public name;
    string public symbol;
    string public metadataURI;          // offchain JSON (image, description, socials)
    address public immutable launchpad; // provenance: which factory deployed this
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint256 _supplyWhole, string memory _metadataURI) {
        name = _name;
        symbol = _symbol;
        metadataURI = _metadataURI;
        launchpad = msg.sender;
        totalSupply = _supplyWhole * 1e18;
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    /// @notice EIP-7572 contract-level metadata. Returns the SAME JSON data-URI
    ///         as metadataURI. Aggregators/terminals (Axiom etc.) probe this
    ///         standard function name to auto-pull the token logo/socials;
    ///         our custom metadataURI() alone was invisible to them.
    function contractURI() external view returns (string memory) {
        return metadataURI;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
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

/// @title Launchpad
/// @notice The public token factory: anyone calls createToken() and, in ONE
///         atomic transaction, gets
///           1. a fresh fixed-supply LaunchToken (CREATE2, address predictable
///              client-side so tick params can be computed before the tx),
///           2. a Uniswap V3 pool seeded ONE-SIDED with 100% of the supply
///              (zero ETH required from the creator to provide liquidity),
///           3. the LP position permanently locked in the RevSplitLocker
///              (fees split creator/protocol forever; liquidity unpullable), and
///           4. optionally, a dev buy: all msg.value is swapped into the fresh
///              pool for the creator before anyone else can trade.
///         Trading is live from block one: no bonding curve, no graduation
///         step, no transfer locks needed.
///
///         Ownerless, no admin, nothing upgradeable, no creation fee. Platform
///         revenue comes exclusively from the locker's immutable LP-fee split.
contract Launchpad {
    address public immutable nfpm;
    address public immutable factory;
    address public immutable weth;
    address public immutable locker;

    // Uniswap V3 hard sqrt-price bounds, used as loose swap limits so the dev
    // buy fills fully instead of stopping at a price cap.
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    // Swap-callback trust state, live ONLY for the duration of a dev-buy swap.
    address private _expectedPool;
    bool private _wethIsToken0;

    uint256 private _entered = 1; // reentrancy guard: 1 = free, 2 = entered

    struct LaunchInfo {
        address token;
        address pool;
        address creator;
        uint256 tokenId;    // locked LP position NFT id
        uint64 createdAt;
    }
    // registry: feed pages read these directly, no indexer required for MVP
    address[] public allTokens;
    mapping(address => LaunchInfo) public launches;

    struct CreateParams {
        string name;
        string symbol;
        string metadataURI;
        uint256 supplyWhole;   // whole tokens, scaled by 1e18 in LaunchToken
        bytes32 salt;          // caller-chosen; namespaced by msg.sender below
        uint24 fee;            // pool fee tier (e.g. 10000 = 1%)
        int24 tickLower;       // one-sided seed range, computed client-side for
        int24 tickUpper;       //   the PREDICTED token address ordering
        uint160 sqrtPriceX96;  // pool init price, AT the seed tick boundary
    }

    // name/symbol/metadataURI are deliberately NOT in the event; they are
    // permanent public fields on the token contract itself; indexers read them
    // from there. Keeps the launch path lean (and under solc's stack limit).
    event TokenLaunched(
        address indexed token,
        address indexed pool,
        address indexed creator,
        uint256 tokenId,
        uint256 supplyWhole,
        uint256 devBuyEth,
        uint256 devBuyTokens
    );

    error Reentrancy();
    error ZeroAddress();
    error BadSupply();
    error PoolMismatch();
    error PriceDeviation();
    error MintFailed();
    error LockFailed();
    error DevBuyFailed();
    error UnexpectedPool();
    error UnexpectedDeltas();
    error PayFailed();
    error RefundFailed();

    modifier nonReentrant() {
        if (_entered == 2) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    constructor(address nfpm_, address factory_, address weth_, address locker_) {
        if (nfpm_ == address(0) || factory_ == address(0) || weth_ == address(0) || locker_ == address(0)) {
            revert ZeroAddress();
        }
        nfpm = nfpm_;
        factory = factory_;
        weth = weth_;
        locker = locker_;
    }

    // Accept ETH only from WETH.withdraw during refund.
    receive() external payable {
        require(msg.sender == weth, "ETH only from WETH");
    }

    // ---------------------------------------------------------------------
    // CREATE2 prediction helpers. The frontend calls these (free eth_calls)
    // to know the token address BEFORE the tx, so it can compute the correct
    // token/WETH ordering and seed ticks.
    // ---------------------------------------------------------------------
    function tokenInitCodeHash(
        string memory name_, string memory symbol_, uint256 supplyWhole_, string memory metadataURI_
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            type(LaunchToken).creationCode,
            abi.encode(name_, symbol_, supplyWhole_, metadataURI_)
        ));
    }

    function predictToken(
        address creator, bytes32 salt,
        string memory name_, string memory symbol_, uint256 supplyWhole_, string memory metadataURI_
    ) external view returns (address) {
        bytes32 fullSalt = keccak256(abi.encodePacked(creator, salt));
        return address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", address(this), fullSalt,
            tokenInitCodeHash(name_, symbol_, supplyWhole_, metadataURI_)
        )))));
    }

    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }

    /// @notice Page through launched tokens, newest-last. `count` capped by array end.
    function getTokens(uint256 start, uint256 count) external view returns (address[] memory out) {
        uint256 n = allTokens.length;
        if (start >= n) return new address[](0);
        uint256 end = start + count > n ? n : start + count;
        out = new address[](end - start);
        for (uint256 i = start; i < end; i++) out[i - start] = allTokens[i];
    }

    // ---------------------------------------------------------------------
    // The one public action: create + seed + lock (+ optional dev buy).
    // ---------------------------------------------------------------------
    function createToken(CreateParams calldata p) external payable nonReentrant returns (address token) {
        if (p.supplyWhole == 0 || p.supplyWhole > 1e15) revert BadSupply(); // cap: 1 quadrillion whole tokens

        // 1. Deploy the token via CREATE2. Salt is namespaced by msg.sender so a
        //    mempool copy-cat gets a DIFFERENT token address; their stolen tick
        //    params then mismatch their ordering and their launch misprices or
        //    reverts; ours is unaffected.
        bytes32 fullSalt = keccak256(abi.encodePacked(msg.sender, p.salt));
        token = address(new LaunchToken{salt: fullSalt}(p.name, p.symbol, p.supplyWhole, p.metadataURI));

        uint256 supplyRaw = p.supplyWhole * 1e18;
        bool memeIsToken0 = token < weth;
        (address token0, address token1) = memeIsToken0 ? (token, weth) : (weth, token);

        (address pool, uint256 tokenId) = _seedAndLock(token, token0, token1, memeIsToken0, supplyRaw, p);

        // 4. Optional dev buy: swap ALL msg.value into the fresh pool for the
        //    creator, atomically; no one can trade between seed and dev buy.
        uint256 devTokens = 0;
        if (msg.value > 0) {
            IWETH9(weth).deposit{value: msg.value}();
            devTokens = _devBuy(pool, memeIsToken0, msg.value);
        }

        // 5. Refund: any token mint-rounding dust goes to the creator. (WETH is
        //    fully consumed by the exact-input dev buy; unwrap defensively anyway.)
        _refund(token);

        launches[token] = LaunchInfo({
            token: token,
            pool: pool,
            creator: msg.sender,
            tokenId: tokenId,
            createdAt: uint64(block.timestamp)
        });
        allTokens.push(token);

        emit TokenLaunched(token, pool, msg.sender, tokenId, p.supplyWhole, msg.value, devTokens);
    }

    // ---------------------------------------------------------------------
    // internals
    // ---------------------------------------------------------------------
    function _seedAndLock(
        address token, address token0, address token1, bool memeIsToken0,
        uint256 supplyRaw, CreateParams calldata p
    ) internal returns (address pool, uint256 tokenId) {
        // 2. Create + initialize the pool at the client-computed seed price.
        pool = INonfungiblePositionManager(nfpm).createAndInitializePoolIfNecessary(
            token0, token1, p.fee, p.sqrtPriceX96
        );
        if (pool == address(0) || pool != IUniswapV3Factory(factory).getPool(token0, token1, p.fee)) {
            revert PoolMismatch();
        }

        // Guard against a pre-existing pool initialized at a FOREIGN price: the
        // token address is predictable pre-deploy (CREATE2), so a griefer could
        // create+init the pool first at a bad price.
        // (createAndInitializePoolIfNecessary is a no-op if already initialized.)
        (uint160 curSqrt,,,,,,) = IUniswapV3Pool(pool).slot0();
        {
            uint160 want = p.sqrtPriceX96;
            uint160 hi = curSqrt > want ? curSqrt : want;
            uint160 lo = curSqrt > want ? want : curSqrt;
            // reject > ~1% deviation on sqrtPrice (~2% on price)
            if (curSqrt == 0 || (uint256(hi - lo) * 10000 > uint256(hi) * 100)) revert PriceDeviation();
        }

        // 3. Seed the ENTIRE supply one-sided and lock the position forever.
        //    WETH-side desired amount is hardwired to zero: the contract, not the
        //    client, enforces one-sidedness.
        LaunchToken(token).approve(nfpm, supplyRaw);
        uint128 liquidity;
        (tokenId, liquidity, , ) = INonfungiblePositionManager(nfpm).mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: p.fee,
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                amount0Desired: memeIsToken0 ? supplyRaw : 0,
                amount1Desired: memeIsToken0 ? 0 : supplyRaw,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        // One-sidedness rests on three fail-closed facts: (a) the WETH-side
        // desired amount is 0 above, (b) this contract never approves WETH to the
        // NFPM (we hold no WETH yet; dev-buy wrapping happens AFTER this), and
        // (c) if the seed price landed strictly inside the range, Uniswap computes
        // liquidity from the zero WETH side -> liquidity == 0 -> revert here.
        if (liquidity == 0) revert MintFailed();

        INonfungiblePositionManager(nfpm).safeTransferFrom(
            address(this), locker, tokenId, abi.encode(msg.sender, token0, token1)
        );
        if (INonfungiblePositionManager(nfpm).ownerOf(tokenId) != locker) revert LockFailed();
    }

    function _devBuy(address pool, bool memeIsToken0, uint256 wethIn) internal returns (uint256 tokensOut) {
        // Exact-INPUT swap: spend all wethIn, creator receives whatever the curve
        // gives at the seed price. WETH in on one side, token out on the other.
        bool wethIsToken0 = !memeIsToken0;
        bool zeroForOne = wethIsToken0;
        uint160 limit = zeroForOne ? (MIN_SQRT_RATIO + 1) : (MAX_SQRT_RATIO - 1);

        _expectedPool = pool;
        _wethIsToken0 = wethIsToken0;

        (int256 a0, int256 a1) = IUniswapV3Pool(pool).swap(
            msg.sender, zeroForOne, int256(wethIn), limit, ""
        );
        tokensOut = memeIsToken0 ? uint256(-a0) : uint256(-a1);
        if (tokensOut == 0) revert DevBuyFailed();

        _expectedPool = address(0);
        _wethIsToken0 = false;
    }

    /// @notice Pay the pool the WETH it is owed for the swap in progress. Only
    ///         ever called re-entrantly by the exact pool we are mid-swap against.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != _expectedPool) revert UnexpectedPool();
        if (_wethIsToken0) {
            if (amount0Delta <= 0 || amount1Delta > 0) revert UnexpectedDeltas();
            if (!IWETH9(weth).transfer(_expectedPool, uint256(amount0Delta))) revert PayFailed();
        } else {
            if (amount1Delta <= 0 || amount0Delta > 0) revert UnexpectedDeltas();
            if (!IWETH9(weth).transfer(_expectedPool, uint256(amount1Delta))) revert PayFailed();
        }
    }

    /// @notice Return leftovers to the creator: unwrap any WETH -> ETH and sweep
    ///         token mint-rounding dust. The contract holds no funds after.
    function _refund(address token) internal {
        uint256 wbal = IWETH9(weth).balanceOf(address(this));
        if (wbal > 0) IWETH9(weth).withdraw(wbal);
        uint256 ethBal = address(this).balance;
        if (ethBal > 0) {
            (bool ok, ) = msg.sender.call{value: ethBal}("");
            if (!ok) revert RefundFailed();
        }
        uint256 dust = LaunchToken(token).balanceOf(address(this));
        if (dust > 0) LaunchToken(token).transfer(msg.sender, dust);
    }
}
