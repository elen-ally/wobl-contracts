// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "../contracts/WoblCurve.sol";
import "./Base.sol";
import "./mocks/Mocks.sol";

/// Stateful handler: performs bounded, interleaved buys and sells as itself and
/// records two ghost violations for the invariant engine to assert on:
///   - kViolated       : k = vEth*vTok ever decreased across a trade (INV-8)
///   - solvencyViolated: the curve's ETH balance ever fell below its liabilities
///                       (realEth + accrued creator + protocol fees) (INV-8/INV-13)
contract CurveHandler {
    WoblCurve public curve;
    address public token;
    bool public kViolated;
    bool public solvencyViolated;
    uint256 public buys;
    uint256 public sells;

    constructor(WoblCurve curve_) {
        curve = curve_;
        token = curve.createToken("Inv", "INV", "data:,x", 0, keccak256("invariant-token"));
    }

    function _k() internal view returns (uint256) {
        WoblCurve.Curve memory c = curve.getCurve(token);
        return uint256(c.virtualEth) * uint256(c.virtualTokens);
    }

    function _checkSolvency() internal {
        WoblCurve.Curve memory c = curve.getCurve(token);
        uint256 liabilities = uint256(c.realEth) + curve.creatorFees(token) + curve.protocolFeesAccrued();
        if (address(curve).balance < liabilities) solvencyViolated = true;
    }

    function buy(uint256 seed) external {
        uint256 value = _clamp(seed, 1e12, 1e16);
        if (address(this).balance < value) return;
        WoblCurve.Curve memory c = curve.getCurve(token);
        if (c.graduated) return;
        uint256 k0 = _k();
        try curve.buy{value: value}(token, 0, block.timestamp + 1) {
            if (_k() < k0) kViolated = true;
            buys++;
        } catch {}
        _checkSolvency();
    }

    function sell(uint256 seed) external {
        uint256 bal = WoblToken(token).balanceOf(address(this));
        if (bal == 0) return;
        WoblCurve.Curve memory c = curve.getCurve(token);
        if (c.graduated) return;
        uint256 amt = _clamp(seed, 1, bal);
        WoblToken(token).approve(address(curve), amt);
        uint256 k0 = _k();
        try curve.sell(token, amt, 0, block.timestamp + 1) {
            if (_k() < k0) kViolated = true;
            sells++;
        } catch {}
        _checkSolvency();
    }

    function _clamp(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        uint256 size = max - min + 1;
        return min + (x % size);
    }

    receive() external payable {}
}

contract WoblCurveInvariant is TestBase {
    MockUniswap uni;
    MockWETH weth;
    MockLocker locker;
    WoblCurve curve;
    CurveHandler handler;
    address protocol = address(0x9999);

    // Large seed so the invariant run (bounded small trades) never graduates;
    // graduation is a separate scenario test; here we want a long live-curve run.
    uint128 constant VETH_SEED = 1_000 ether; // graduation raise = 3,000 ether

    function setUp() public {
        uni = new MockUniswap();
        weth = new MockWETH();
        locker = new MockLocker(address(uni));
        curve = new WoblCurve(
            address(uni), address(uni), address(weth), address(locker), protocol, VETH_SEED, 0, address(this)
        );
        handler = new CurveHandler(curve);
        vm.deal(address(handler), 100 ether);
    }

    function targetContracts() public view returns (address[] memory addrs) {
        addrs = new address[](1);
        addrs[0] = address(handler);
    }

    // INV-8: the constant-product k never decreases across any buy or sell.
    function invariant_kNonDecreasing() public view {
        assertFalse(handler.kViolated(), "k decreased across a trade");
    }

    // INV-8 / INV-13: the curve always holds enough ETH to cover its liabilities
    // (net reserves + accrued but unclaimed creator/protocol fees).
    function invariant_solvent() public view {
        assertFalse(handler.solvencyViolated(), "curve ETH balance fell below liabilities");
        WoblCurve.Curve memory c = curve.getCurve(handler.token());
        uint256 liabilities =
            uint256(c.realEth) + curve.creatorFees(handler.token()) + curve.protocolFeesAccrued();
        assertGe(address(curve).balance, liabilities, "live solvency check");
    }
}
