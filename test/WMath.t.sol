// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "../contracts/WoblCurve.sol";
import "./Base.sol";

/// External wrapper so the internal WMath helpers can be exercised via try/catch.
contract WMathWrapper {
    function toUint128(uint256 x) external pure returns (uint128) {
        return WMath.toUint128(x);
    }

    function toUint160(uint256 x) external pure returns (uint160) {
        return WMath.toUint160(x);
    }

    function ceilDiv(uint256 a, uint256 b) external pure returns (uint256) {
        return WMath.ceilDiv(a, b);
    }

    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return WMath.mulDiv(a, b, d);
    }
}

contract WMathTest is TestBase {
    WMathWrapper w;

    function setUp() public {
        w = new WMathWrapper();
    }

    // LOW-1: toUint128 passes through in-range values and reverts on overflow.
    function testFuzz_ToUint128InRange(uint256 x) public view {
        x = _bound(x, 0, type(uint128).max);
        assertEq(uint256(w.toUint128(x)), x, "toUint128 identity in range");
    }

    function test_ToUint128RevertsOnOverflow() public {
        uint256 over = uint256(type(uint128).max) + 1;
        try w.toUint128(over) {
            assertTrue(false, "toUint128 must revert above 2^128-1");
        } catch {}
    }

    function testFuzz_ToUint160InRange(uint256 x) public view {
        x = _bound(x, 0, type(uint160).max);
        assertEq(uint256(w.toUint160(x)), x, "toUint160 identity in range");
    }

    function test_ToUint160RevertsOnOverflow() public {
        uint256 over = uint256(type(uint160).max) + 1;
        try w.toUint160(over) {
            assertTrue(false, "toUint160 must revert above 2^160-1");
        } catch {}
    }

    // ceilDiv rounds up and never below floor division.
    function testFuzz_CeilDiv(uint256 a, uint256 b) public view {
        a = _bound(a, 0, type(uint128).max);
        b = _bound(b, 1, type(uint128).max);
        uint256 c = w.ceilDiv(a, b);
        assertGe(c, a / b, "ceilDiv >= floor");
        if (a % b == 0) assertEq(c, a / b, "exact division: ceil == floor");
        else assertEq(c, a / b + 1, "inexact: ceil == floor + 1");
    }
}
