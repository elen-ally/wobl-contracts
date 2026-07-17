// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice The only NFPM surface this locker touches: fee collection. It
///         deliberately does NOT declare transferFrom / decreaseLiquidity / burn /
///         approve, so the locker literally cannot call what it cannot see.
interface INonfungiblePositionManager {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
}

interface IERC20Min {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title RevSplitLocker
/// @notice Permanent, ownerless Uniswap V3 LP locker with a creator/protocol fee
///         split. A position NFT sent here can NEVER leave and its liquidity can
///         NEVER be removed: there is no transfer, decreaseLiquidity, burn, or
///         approve path anywhere in this contract. The ONLY state-changing action
///         is `collect`, which pulls the position's accrued swap fees to this
///         contract and splits each side:
///             protocolBps/10000  -> protocolWallet  (platform revenue)
///             the rest           -> the creator recorded at lock time
///         Both the split and the protocol wallet are immutable, set once at
///         deployment, unchangeable forever. No owner, no admin, no upgrade path.
/// @dev Self-contained (no imports) so solc-js compiles it with no dependencies.
contract RevSplitLocker {
    address public immutable nfpm;
    address public immutable protocolWallet;
    uint16 public immutable protocolBps; // share of LP fees to the protocol, in bps

    uint16 public constant MAX_PROTOCOL_BPS = 3000; // hard cap: protocol can never take >30%

    struct LockInfo {
        address creator; // fee beneficiary for the creator share; set once, forever
        address token0;  // position's token0 (needed to pay out the split)
        address token1;  // position's token1
    }
    mapping(uint256 => LockInfo) public locks;

    uint256 private _entered = 1; // reentrancy guard: 1 = free, 2 = entered

    event Locked(uint256 indexed tokenId, address indexed creator, address token0, address token1);
    event Collected(
        uint256 indexed tokenId,
        address indexed creator,
        uint256 creator0, uint256 creator1,
        uint256 protocol0, uint256 protocol1
    );

    error OnlyNfpm();
    error AlreadyLocked();
    error UnknownPosition();
    error BadCreator();
    error BadTokens();
    error BpsTooHigh();
    error ZeroAddress();
    error PayoutFailed();
    error Reentrancy();

    constructor(address nfpm_, address protocolWallet_, uint16 protocolBps_) {
        if (nfpm_ == address(0) || protocolWallet_ == address(0)) revert ZeroAddress();
        if (protocolBps_ > MAX_PROTOCOL_BPS) revert BpsTooHigh();
        nfpm = nfpm_;
        protocolWallet = protocolWallet_;
        protocolBps = protocolBps_;
    }

    /// @notice Receive + permanently lock a Uniswap V3 position. The NFT must be
    ///         delivered by the NFPM via safeTransferFrom carrying
    ///         abi.encode(creator, token0, token1). After receipt the position can
    ///         never be moved out again.
    /// @dev token0/token1 come from the (launchpad) sender rather than an on-chain
    ///      positions() read; lying about them only breaks payout of the liar's own
    ///      position; the NFT is irrecoverably locked either way.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4)
    {
        if (msg.sender != nfpm) revert OnlyNfpm();
        if (locks[tokenId].creator != address(0)) revert AlreadyLocked();
        (address creator, address token0, address token1) = abi.decode(data, (address, address, address));
        if (creator == address(0)) revert BadCreator();
        if (token0 == address(0) || token1 == address(0) || token0 == token1) revert BadTokens();
        locks[tokenId] = LockInfo(creator, token0, token1);
        emit Locked(tokenId, creator, token0, token1);
        return this.onERC721Received.selector;
    }

    /// @notice Collect a position's accrued swap fees and split them
    ///         creator/protocol. Permissionless: anyone may trigger it, nobody can
    ///         redirect it.
    function collect(uint256 tokenId) external returns (uint256 amount0, uint256 amount1) {
        if (_entered == 2) revert Reentrancy();
        _entered = 2;

        LockInfo memory info = locks[tokenId];
        if (info.creator == address(0)) revert UnknownPosition();

        (amount0, amount1) = INonfungiblePositionManager(nfpm).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        uint256 p0 = (amount0 * protocolBps) / 10000;
        uint256 p1 = (amount1 * protocolBps) / 10000;
        uint256 c0 = amount0 - p0;
        uint256 c1 = amount1 - p1;

        if (p0 > 0 && !IERC20Min(info.token0).transfer(protocolWallet, p0)) revert PayoutFailed();
        if (p1 > 0 && !IERC20Min(info.token1).transfer(protocolWallet, p1)) revert PayoutFailed();
        if (c0 > 0 && !IERC20Min(info.token0).transfer(info.creator, c0)) revert PayoutFailed();
        if (c1 > 0 && !IERC20Min(info.token1).transfer(info.creator, c1)) revert PayoutFailed();

        emit Collected(tokenId, info.creator, c0, c1, p0, p1);
        _entered = 1;
    }
}
