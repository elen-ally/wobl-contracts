// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "../contracts/RevSplitLocker.sol";
import "./Base.sol";
import "./mocks/Mocks.sol";

/// Tests for the shared fee locker used by BOTH launch paths.
///   INV-3 : collect() splits each token side EXACTLY protocolBps/creator, with no
///           remainder retained, and is permissionless.
///   INV-2 : a locked position's ownership never changes (there is no move path).
/// Uses mock ERC20s + a mock NFPM that pays preset fees on collect(). Imports only
/// RevSplitLocker.sol to avoid the duplicate INonfungiblePositionManager interface
/// name it shares with WoblCurve.sol.
contract RevSplitLockerTest is TestBase {
    MockCollectNFPM nfpm;
    RevSplitLocker lockerC;
    MockERC20 t0;
    MockERC20 t1;
    address protocol = address(0xF0F0);
    address creator = address(0xC0FFEE);
    uint16 constant BPS_PROTOCOL = 2000; // 20%

    function setUp() public {
        nfpm = new MockCollectNFPM();
        lockerC = new RevSplitLocker(address(nfpm), protocol, BPS_PROTOCOL);
        t0 = new MockERC20("T0", "T0");
        t1 = new MockERC20("T1", "T1");
    }

    function _lock(uint256 tokenId) internal {
        // token0 < token1 not required by the locker, but pass the real addresses.
        bytes memory data = abi.encode(creator, address(t0), address(t1));
        nfpm.deliver(address(lockerC), tokenId, data);
    }

    // ---- INV-3: exact split, no remainder, permissionless ------------------
    function testFuzz_collectSplitsExactly(uint256 tokenId, uint256 a0, uint256 a1) public {
        tokenId = _bound(tokenId, 1, 1e9);
        a0 = _bound(a0, 0, 1e30);
        a1 = _bound(a1, 0, 1e30);
        _lock(tokenId);

        // Fund the NFPM with the fees it will pay out on collect().
        t0.mint(address(nfpm), a0);
        t1.mint(address(nfpm), a1);
        nfpm.setFees(tokenId, address(t0), address(t1), a0, a1);

        // Permissionless: an arbitrary caller triggers the collect.
        vm.prank(address(0xDEAD));
        lockerC.collect(tokenId);

        uint256 p0 = (a0 * BPS_PROTOCOL) / 10000;
        uint256 p1 = (a1 * BPS_PROTOCOL) / 10000;
        assertEq(t0.balanceOf(protocol), p0, "protocol side0 exact");
        assertEq(t1.balanceOf(protocol), p1, "protocol side1 exact");
        assertEq(t0.balanceOf(creator), a0 - p0, "creator side0 = remainder");
        assertEq(t1.balanceOf(creator), a1 - p1, "creator side1 = remainder");
        // No dust retained by the locker: every collected wei was split out.
        assertEq(t0.balanceOf(address(lockerC)), 0, "locker retains no token0");
        assertEq(t1.balanceOf(address(lockerC)), 0, "locker retains no token1");
        assertEq(t0.balanceOf(protocol) + t0.balanceOf(creator), a0, "side0 conserved");
        assertEq(t1.balanceOf(protocol) + t1.balanceOf(creator), a1, "side1 conserved");
    }

    // ---- INV-1: protocol bps is bounded at construction --------------------
    function test_protocolBpsCapEnforced() public {
        try new RevSplitLocker(address(nfpm), protocol, 3001) {
            assertTrue(false, "must reject protocolBps > 3000");
        } catch {}
        // exactly the cap is allowed
        RevSplitLocker atCap = new RevSplitLocker(address(nfpm), protocol, 3000);
        assertEq(atCap.protocolBps(), 3000, "cap boundary allowed");
    }

    // ---- INV-2: unknown/unlocked position cannot be collected --------------
    function test_collectUnknownReverts() public {
        try lockerC.collect(4242) {
            assertTrue(false, "collect on unlocked id must revert");
        } catch {}
    }

    // A position cannot be locked twice (no re-key / takeover).
    function test_doubleLockReverts() public {
        _lock(7);
        try nfpm.deliver(address(lockerC), 7, abi.encode(creator, address(t0), address(t1))) {
            assertTrue(false, "double lock must revert");
        } catch {}
    }
}
