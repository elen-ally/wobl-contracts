// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// ---------------------------------------------------------------------------
// Minimal Uniswap-V3 + WETH mocks for the WoblCurve Foundry suite. They model
// exactly the surface WoblCurve touches: pool create/init at a pinned price, a
// two-sided mint that pulls the approved token+WETH and yields nonzero
// liquidity, safeTransferFrom into the locker, and ownerOf. No real V3 math:
// the curve-math invariants under test do not depend on the pool internals, only
// on the graduation handoff succeeding. (Fork tests would exercise the real V3;
// see the report for what is covered here vs deferred-to-fork.)
// ---------------------------------------------------------------------------

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "WETH_BAL");
        balanceOf[msg.sender] -= wad;
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "WETH_SEND");
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= value, "WETH_ALLOW");
            allowance[from][msg.sender] = a - value;
        }
        return _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        require(balanceOf[from] >= value, "WETH_BAL");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract MockPool {
    uint160 public sqrtPriceX96;
    uint128 public liquidity;

    constructor(uint160 sqrtP) {
        sqrtPriceX96 = sqrtP;
    }

    function setLiquidity(uint128 l) external {
        liquidity += l;
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (sqrtPriceX96, int24(0), uint16(0), uint16(0), uint16(0), uint8(0), true);
    }
}

interface IMintable {
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice One mock serving as BOTH the NFPM and the V3 factory (WoblCurve calls
///         them at separate addresses but never requires them to differ). Deploys
///         a MockPool at the pinned sqrtPrice, mints a two-sided position by
///         pulling the approved amounts, and hands the NFT to a receiver.
contract MockUniswap {
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

    mapping(bytes32 => address) public pools;
    mapping(uint256 => address) public ownerOf;
    uint256 public nextId = 1;

    function _key(address a, address b, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b, fee));
    }

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool)
    {
        bytes32 k = _key(token0, token1, fee);
        pool = pools[k];
        if (pool == address(0)) {
            pool = address(new MockPool(sqrtPriceX96));
            pools[k] = pool;
        }
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_key(tokenA, tokenB, fee)];
    }

    function mint(MintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // Pull the approved two-sided amounts from the caller (the curve), exactly
        // like the real NFPM. Both sides must be fully deliverable.
        require(IMintable(p.token0).transferFrom(msg.sender, address(this), p.amount0Desired), "PULL0");
        require(IMintable(p.token1).transferFrom(msg.sender, address(this), p.amount1Desired), "PULL1");
        amount0 = p.amount0Desired;
        amount1 = p.amount1Desired;
        require(amount0 >= p.amount0Min && amount1 >= p.amount1Min, "SLIPPAGE");
        // Nonzero liquidity: sqrt of the product, saturated into uint128.
        uint256 l = _sqrt(amount0 * 1 + amount1 * 1);
        if (l == 0) l = 1;
        liquidity = l > type(uint128).max ? type(uint128).max : uint128(l);
        tokenId = nextId++;
        ownerOf[tokenId] = p.recipient;
        address pool = pools[_key(p.token0, p.token1, p.fee)];
        if (pool != address(0)) MockPool(pool).setLiquidity(liquidity);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external {
        require(ownerOf[tokenId] == from, "NOT_OWNER");
        ownerOf[tokenId] = to;
        // Real NFPM calls the receiver as msg.sender == NFPM.
        bytes4 ret = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data);
        require(ret == IERC721Receiver.onERC721Received.selector, "BAD_RECEIVER");
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

/// @notice Minimal locker stand-in for the WoblCurve graduation tests. Records the
///         decoded (creator, token0, token1) so a test can assert the fee creator
///         was read from curve storage, NOT the graduating buyer (INV-9/INV-11).
///         The REAL RevSplitLocker split is tested separately (RevSplitLocker.t.sol)
///         to avoid a duplicate INonfungiblePositionManager interface declaration.
contract MockLocker {
    address public nfpm;
    mapping(uint256 => address) public creatorOf;
    mapping(uint256 => bool) public locked;

    constructor(address nfpm_) {
        nfpm = nfpm_;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4)
    {
        require(msg.sender == nfpm, "ONLY_NFPM");
        (address creator,,) = abi.decode(data, (address, address, address));
        creatorOf[tokenId] = creator;
        locked[tokenId] = true;
        return this.onERC721Received.selector;
    }
}

// ---------------------------------------------------------------------------
// Mocks for the RevSplitLocker exact-split test (INV-3 / INV-2).
// ---------------------------------------------------------------------------

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "BAL");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= value, "ALLOW");
            allowance[from][msg.sender] = a - value;
        }
        require(balanceOf[from] >= value, "BAL");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        return true;
    }
}

/// @notice NFPM stand-in for RevSplitLocker: it only needs `collect`, plus a way
///         to deliver an NFT into the locker (as msg.sender == nfpm). `collect`
///         pays out preset fee amounts to the recipient from its own balances.
contract MockCollectNFPM {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    mapping(uint256 => uint256) public fee0;
    mapping(uint256 => uint256) public fee1;
    mapping(uint256 => address) public token0Of;
    mapping(uint256 => address) public token1Of;

    function setFees(uint256 tokenId, address t0, address t1, uint256 a0, uint256 a1) external {
        token0Of[tokenId] = t0;
        token1Of[tokenId] = t1;
        fee0[tokenId] = a0;
        fee1[tokenId] = a1;
    }

    function deliver(address locker, uint256 tokenId, bytes calldata data) external {
        bytes4 ret = IERC721Receiver(locker).onERC721Received(address(this), address(this), tokenId, data);
        require(ret == IERC721Receiver.onERC721Received.selector, "BAD_RECEIVER");
    }

    function collect(CollectParams calldata p) external returns (uint256 amount0, uint256 amount1) {
        amount0 = fee0[p.tokenId];
        amount1 = fee1[p.tokenId];
        fee0[p.tokenId] = 0;
        fee1[p.tokenId] = 0;
        if (amount0 > 0) require(MockERC20(token0Of[p.tokenId]).transfer(p.recipient, amount0), "T0");
        if (amount1 > 0) require(MockERC20(token1Of[p.tokenId]).transfer(p.recipient, amount1), "T1");
    }
}
