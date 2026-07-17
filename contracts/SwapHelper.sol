// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3Pool {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IERC20Min {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title SwapHelper
/// @notice Minimal ETH<->token swapper for Uniswap V3 pools, for chains/frontends
///         without a deployed SwapRouter (Robinhood Chain testnet) and as a lean
///         fallback elsewhere. Exact-input only, single pool hop, WETH-paired.
///         Stateless between calls, ownerless, holds nothing after a swap.
/// @dev The swap callback authenticates msg.sender against the CANONICAL factory
///      pool for the (token, fee) pair passed through swap data, the same
///      pattern Uniswap's own periphery uses. A fake pool can never be entered
///      because we only ever call pools returned by factory.getPool, and the
///      callback recomputes that address.
contract SwapHelper {
    address public immutable factory;
    address public immutable weth;

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    uint256 private _entered = 1;

    error Reentrancy();
    error NoPool();
    error BadCallback();
    error Slippage();
    error PayFailed();
    error SendFailed();

    modifier nonReentrant() {
        if (_entered == 2) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    constructor(address factory_, address weth_) {
        require(factory_ != address(0) && weth_ != address(0), "ZERO");
        factory = factory_;
        weth = weth_;
    }

    receive() external payable {
        require(msg.sender == weth, "ETH only from WETH");
    }

    /// @notice Buy `token` with exactly msg.value ETH. Tokens go straight to the caller.
    function buyExactETH(address token, uint24 fee, uint256 minTokensOut)
        external payable nonReentrant returns (uint256 tokensOut)
    {
        address pool = _pool(token, fee);
        bool wethIsToken0 = weth < token;

        IWETH9(weth).deposit{value: msg.value}();
        (int256 a0, int256 a1) = IUniswapV3Pool(pool).swap(
            msg.sender,
            wethIsToken0,                                     // zeroForOne = selling token0(WETH)
            int256(msg.value),                                // exact input
            wethIsToken0 ? (MIN_SQRT_RATIO + 1) : (MAX_SQRT_RATIO - 1),
            abi.encode(token, fee)
        );
        tokensOut = wethIsToken0 ? uint256(-a1) : uint256(-a0);
        if (tokensOut < minTokensOut) revert Slippage();

        // Exact-input V3 swaps consume LESS than amountSpecified when in-range
        // liquidity runs out (real risk on thin one-sided launch pools). Refund
        // any unspent input instead of stranding it here forever.
        uint256 spent = wethIsToken0 ? uint256(a0) : uint256(a1);
        if (spent < msg.value) {
            uint256 refund = msg.value - spent;
            IWETH9(weth).withdraw(refund);
            (bool ok, ) = msg.sender.call{value: refund}("");
            if (!ok) revert SendFailed();
        }
    }

    /// @notice Sell exactly `amountIn` of `token` for ETH. Caller must approve first.
    ///         ETH (unwrapped) goes straight back to the caller.
    function sellExactTokens(address token, uint24 fee, uint256 amountIn, uint256 minEthOut)
        external nonReentrant returns (uint256 ethOut)
    {
        address pool = _pool(token, fee);
        bool tokenIsToken0 = token < weth;

        if (!IERC20Min(token).transferFrom(msg.sender, address(this), amountIn)) revert PayFailed();
        (int256 a0, int256 a1) = IUniswapV3Pool(pool).swap(
            address(this),                                    // WETH lands here, unwrapped below
            tokenIsToken0,                                    // zeroForOne = selling token0(token)
            int256(amountIn),
            tokenIsToken0 ? (MIN_SQRT_RATIO + 1) : (MAX_SQRT_RATIO - 1),
            abi.encode(token, fee)
        );
        ethOut = tokenIsToken0 ? uint256(-a1) : uint256(-a0);
        if (ethOut < minEthOut) revert Slippage();

        IWETH9(weth).withdraw(ethOut);
        (bool ok, ) = msg.sender.call{value: ethOut}("");
        if (!ok) revert SendFailed();

        // Refund unspent token input on a partial fill (see buyExactETH).
        uint256 spentTok = tokenIsToken0 ? uint256(a0) : uint256(a1);
        if (spentTok < amountIn) {
            if (!IERC20Min(token).transfer(msg.sender, amountIn - spentTok)) revert PayFailed();
        }
    }

    /// @notice Pay the pool what it is owed. Only the canonical factory pool for
    ///         the (token, fee) carried in `data` can enter.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        (address token, uint24 fee) = abi.decode(data, (address, uint24));
        if (msg.sender != _pool(token, fee)) revert BadCallback();

        // Whichever side is positive is what we owe; it is always the input asset
        // sitting in this contract (WETH for buys, the token for sells).
        (address owedAsset, uint256 owed) = amount0Delta > 0
            ? (token < weth ? token : weth, uint256(amount0Delta))
            : (token < weth ? weth : token, uint256(amount1Delta));
        if (amount0Delta <= 0 && amount1Delta <= 0) revert BadCallback();
        if (!IERC20Min(owedAsset).transfer(msg.sender, owed)) revert PayFailed();
    }

    function _pool(address token, uint24 fee) internal view returns (address pool) {
        (address t0, address t1) = token < weth ? (token, weth) : (weth, token);
        pool = IUniswapV3Factory(factory).getPool(t0, t1, fee);
        if (pool == address(0)) revert NoPool();
    }
}
