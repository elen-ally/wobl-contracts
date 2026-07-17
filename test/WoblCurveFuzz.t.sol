// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "../contracts/WoblCurve.sol";
import "./Base.sol";
import "./mocks/Mocks.sol";

/// Stateless fuzz + scenario tests for the WoblCurve bonding curve against the
/// REAL WoblCurve contract (mocked Uniswap V3 + WETH). Covers:
///   INV-8   k = vEth*vTok non-decreasing across buy and across sell
///   round   sell(buy(x)) <= x  (a user can never extract more than deposited)
///   INV-9   graduation caller gets no fee rights; creator read from storage
///   INV-10  pre-graduation transfers between non-curve addresses revert
///   LOW-4   buy/sell revert past their deadline
contract WoblCurveFuzz is TestBase {
    MockUniswap uni;
    MockWETH weth;
    MockLocker locker;
    WoblCurve curve;
    address protocol = address(0x9999);

    uint128 constant VETH_SEED = 1 ether; // graduation raise = 3 ether

    function setUp() public {
        uni = new MockUniswap();
        weth = new MockWETH();
        locker = new MockLocker(address(uni));
        // nfpm and factory are the same mock (WoblCurve never requires them to differ).
        curve = new WoblCurve(
            address(uni), address(uni), address(weth), address(locker), protocol, VETH_SEED, 0, address(this)
        );
        vm.deal(address(this), 1_000 ether);
    }

    function _create(string memory salt) internal returns (address token) {
        token = curve.createToken("Tok", "TK", "data:,x", 0, keccak256(bytes(salt)));
    }

    function _k(address token) internal view returns (uint256) {
        WoblCurve.Curve memory c = curve.getCurve(token);
        return uint256(c.virtualEth) * uint256(c.virtualTokens);
    }

    // ---- INV-8: k non-decreasing on a buy ----------------------------------
    function testFuzz_kNonDecreasingOnBuy(uint256 ethIn) public {
        address tok = _create("k-buy");
        ethIn = _bound(ethIn, 1e10, 2 ether); // stay below the 3-ether graduation
        uint256 k0 = _k(tok);
        curve.buy{value: ethIn}(tok, 0, block.timestamp);
        assertGe(_k(tok), k0, "k must not decrease on buy");
    }

    // ---- INV-8: k non-decreasing on a sell ---------------------------------
    function testFuzz_kNonDecreasingOnSell(uint256 ethIn, uint256 sellFrac) public {
        address tok = _create("k-sell");
        ethIn = _bound(ethIn, 1e12, 2 ether);
        curve.buy{value: ethIn}(tok, 0, block.timestamp);
        uint256 bal = WoblToken(tok).balanceOf(address(this));
        vm.assume(bal > 0);
        uint256 amt = _bound(sellFrac, 1, bal);
        WoblToken(tok).approve(address(curve), amt);
        uint256 k0 = _k(tok);
        // Selling can revert on a dust amount (0 ETH out); that is fine, skip it.
        try curve.sell(tok, amt, 0, block.timestamp) {
            assertGe(_k(tok), k0, "k must not decrease on sell");
        } catch {}
    }

    // ---- Round-trip loss: sell(buy(x)) <= x --------------------------------
    function testFuzz_roundTripLoss(uint256 ethIn) public {
        address tok = _create("roundtrip");
        ethIn = _bound(ethIn, 1e13, 1 ether); // comfortably below graduation
        uint256 balEthBefore = address(this).balance;
        (, , uint256 ethUsed) = curve.quoteBuy(tok, ethIn);
        curve.buy{value: ethIn}(tok, 0, block.timestamp);
        uint256 got = WoblToken(tok).balanceOf(address(this));
        vm.assume(got > 0);
        WoblToken(tok).approve(address(curve), got);
        (uint256 ethQuote, ) = curve.quoteSell(tok, got);
        vm.assume(ethQuote > 0);
        curve.sell(tok, got, 0, block.timestamp);
        // The curve consumed `ethUsed` of the input (rest refunded). Selling every
        // token back must return strictly less than that (two 1% fees + rounding).
        assertLt(ethQuote, ethUsed, "round-trip must lose to fees+rounding");
        // Net ETH position of the round-tripper is negative.
        assertLe(address(this).balance, balEthBefore, "cannot end with more ETH than started");
    }

    // ---- INV-9: graduation caller gets no fee rights, creator from storage --
    function test_graduationNoSelfDeal() public {
        address tok = _create("grad"); // creator == address(this)
        address buyer = address(0xB0B);
        vm.deal(buyer, 100 ether);

        uint256 raise = curve.graduationRaise();
        vm.prank(buyer);
        curve.buy{value: raise * 2}(tok, 0, block.timestamp); // fills + graduates

        WoblCurve.Curve memory c = curve.getCurve(tok);
        assertTrue(c.graduated, "curve graduated");
        assertTrue(c.migrated, "curve migrated atomically");
        assertEq(c.realTokens, 0, "realTokens exactly 0 at graduation");
        assertEq(c.realEth, 0, "realEth swept to LP");

        uint256 tokenId = uni.nextId() - 1;
        // Creator recorded at the locker is the LAUNCH creator, never the buyer.
        assertEq(locker.creatorOf(tokenId), address(this), "locker creator == launch creator");
        assertTrue(buyer != address(this), "buyer is not the creator");
        assertTrue(locker.locked(tokenId), "LP NFT locked");
        assertEq(uni.ownerOf(tokenId), address(locker), "NFT owned by locker");

        // The buyer has no creator-fee rights; fees accrue to the creator's mapping.
        assertGt(curve.creatorFees(tok), 0, "creator fees accrued");
        vm.prank(buyer);
        try curve.claimCreatorFees(tok) {
            assertTrue(false, "buyer must not claim creator fees");
        } catch {}
    }

    // ---- INV-10: transfer lock holds pre-graduation, lifts after -----------
    function test_transferLock() public {
        address tok = _create("lock");
        curve.buy{value: 0.1 ether}(tok, 0, block.timestamp);
        uint256 bal = WoblToken(tok).balanceOf(address(this));
        assertGt(bal, 0, "have tokens");
        // transfer to a non-curve address must revert while locked
        try WoblToken(tok).transfer(address(0xBEEF), 1) {
            assertTrue(false, "transfer must revert while locked");
        } catch {}
        // push to graduation
        curve.buy{value: curve.graduationRaise() * 2}(tok, 0, block.timestamp);
        assertTrue(WoblToken(tok).unlocked(), "token unlocked after graduation");
        // now transfers between arbitrary addresses succeed
        bool ok = WoblToken(tok).transfer(address(0xBEEF), 1);
        assertTrue(ok, "transfer succeeds after unlock");
        assertEq(WoblToken(tok).balanceOf(address(0xBEEF)), 1, "recipient credited");
    }

    // ---- LOW-4: deadline enforcement ---------------------------------------
    function test_deadlineRevertsBuy() public {
        address tok = _create("dl-buy");
        vm.warp(1_000);
        try curve.buy{value: 0.01 ether}(tok, 0, 999) {
            assertTrue(false, "buy past deadline must revert");
        } catch {}
        // exactly-now deadline is allowed
        curve.buy{value: 0.01 ether}(tok, 0, 1_000);
    }

    function test_deadlineRevertsSell() public {
        address tok = _create("dl-sell");
        curve.buy{value: 0.05 ether}(tok, 0, block.timestamp);
        uint256 bal = WoblToken(tok).balanceOf(address(this));
        WoblToken(tok).approve(address(curve), bal);
        vm.warp(1_000);
        try curve.sell(tok, bal, 0, 999) {
            assertTrue(false, "sell past deadline must revert");
        } catch {}
        curve.sell(tok, bal, 0, 1_000);
    }
}
