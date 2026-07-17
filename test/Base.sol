// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Self-contained test base: this repo has no forge-std installed (solc-js is the
// production build; Foundry is used only for property tests). We declare the small
// cheatcode surface we need and assert via reverts (a reverting test/invariant body
// is how the forge runner records a failure). Revert-expectation is done with
// try/catch rather than the versioned expectRevert cheatcode.

interface Vm {
    function deal(address who, uint256 newBalance) external;
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function warp(uint256 newTimestamp) external;
    function assume(bool condition) external;
    function label(address addr, string calldata newLabel) external;
}

contract TestBase {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function assertTrue(bool c, string memory m) internal pure {
        require(c, m);
    }

    function assertFalse(bool c, string memory m) internal pure {
        require(!c, m);
    }

    function assertEq(uint256 a, uint256 b, string memory m) internal pure {
        require(a == b, m);
    }

    function assertEq(address a, address b, string memory m) internal pure {
        require(a == b, m);
    }

    function assertLe(uint256 a, uint256 b, string memory m) internal pure {
        require(a <= b, m);
    }

    function assertGe(uint256 a, uint256 b, string memory m) internal pure {
        require(a >= b, m);
    }

    function assertLt(uint256 a, uint256 b, string memory m) internal pure {
        require(a < b, m);
    }

    function assertGt(uint256 a, uint256 b, string memory m) internal pure {
        require(a > b, m);
    }

    // Deterministic clamp of a fuzzed value into [min, max] (forge-std bound port).
    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        require(min <= max, "BOUND_RANGE");
        uint256 size = max - min + 1;
        if (size == 0) return min;
        return min + (x % size);
    }

    receive() external payable {}
}
