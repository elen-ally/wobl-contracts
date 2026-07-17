// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "../contracts/WoblCurve.sol";
import "./Base.sol";

// ===========================================================================
// WoblCurveFork.t.sol: REAL Uniswap V3 graduation on a Robinhood-Chain (4663)
// mainnet fork.
//
// The rest of the suite (WoblCurveFuzz / WoblCurveInvariant) drives the curve
// against MOCK Uniswap contracts (mocks/Mocks.sol) whose mint() pulls BOTH seed
// sides in full and fakes the pool. That never exercises the real two-sided V3
// seed, the amount0Min/amount1Min (SEED_MIN_BPS) binding, or graduation into a
// live NFPM/factory/pool. This file closes that gap: it deploys a fresh
// WoblCurve wired to the REAL NFPM / factory / WETH / RevSplitLocker on the
// fork, creates a token, buys the curve out, and asserts the graduation seed +
// LP lock happened for real.
//
// Run against any Robinhood Chain mainnet (chainId 4663) RPC endpoint:
//   forge test --match-path test/WoblCurveFork.t.sol --fork-url "$FORK" -vv
// where $FORK is an archive-capable 4663 RPC URL. All pinned addresses below are
// mainnet Uniswap V3 / WETH / RevSplitLocker; no project-specific state is needed.
// ===========================================================================

/// @dev Extended cheatcode surface (Base.sol's Vm has no log-recording). Same
///      cheatcode address; declared separately to avoid clashing with the
///      imported `Vm`/`vm` symbols.
interface VmExt {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

interface INFPMView {
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IPoolView {
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

contract WoblCurveFork is TestBase {
    // Extra cheatcodes at the same well-known address as Base.sol's `vm`.
    VmExt internal constant vmx = VmExt(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // Real Robinhood-Chain (4663) mainnet contracts (deployments.mainnet.json).
    address constant NFPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant LOCKER = 0xd5C2A00E56f3E181622d1136643512A203078EB1;

    address constant PROTOCOL = address(0xFEE1);
    address constant BUYER = address(0xB0B);
    address constant BOB2 = address(0xB0B2);

    int24 constant MIN_TICK = -887200;
    int24 constant MAX_TICK = 887200;

    function _deployCurve(uint128 seed) internal returns (WoblCurve) {
        // migrationFeeBps = 0 so the whole raise seeds the LP and the ETH
        // accounting reconciliation below is exact.
        return new WoblCurve(NFPM, FACTORY, WETH, LOCKER, PROTOCOL, seed, 0, address(this));
    }

    // -----------------------------------------------------------------------
    // Full graduation against the REAL V3 stack, parameterised by the seed.
    // Split into helpers so the live stack stays small (viaIR is banned).
    // -----------------------------------------------------------------------
    function _fullGraduation(uint128 seed, bytes32 salt) internal {
        WoblCurve curve = _deployCurve(seed);

        // ---- create: real pool must be created + initialized, no revert ----
        address token = curve.createToken("ForkTok", "FORK", "data:,x", 0, salt);
        address poolAddr = address(uint160(curve.pool(token)));
        assertTrue(poolAddr != address(0), "pool created at creation");
        (uint160 sqrtAtCreate,,,,,,) = IPoolView(poolAddr).slot0();
        assertGt(uint256(sqrtAtCreate), 0, "pool initialized at pinned price");

        uint256 lockerBalBefore = INFPMView(NFPM).balanceOf(LOCKER);
        _buyOut(curve, token);

        // ---- graduation state (INV-9) ----
        WoblCurve.Curve memory c = curve.getCurve(token);
        assertTrue(c.graduated, "graduated flag set");
        assertTrue(c.migrated, "migrated atomically inside the filling buy");
        assertEq(uint256(c.realTokens), 0, "INV-9: realTokens == 0 at graduation");
        assertEq(uint256(c.realEth), 0, "realEth swept into the LP seed");

        // ---- recover the LP tokenId from the Migrated event ----
        uint256 tokenId = _findMigratedTokenId(address(curve));

        _assertLpLockedAndActive(poolAddr, tokenId, lockerBalBefore);
        _assertUnlockedAndClosed(curve, token);
    }

    /// Buy the curve out in chunks (exercises the repeated-rounding path then the
    /// last-buy exact-fill/refund branch). Records logs first so the graduating
    /// buy's Migrated event is captured.
    function _buyOut(WoblCurve curve, address token) internal {
        uint256 raise = curve.graduationRaise();
        assertGt(raise, 0, "positive graduation raise");
        vm.deal(BUYER, raise * 5 + 10 ether);
        uint256 chunk = raise / 4 + 1;

        vmx.recordLogs();

        bool graduated = false;
        for (uint256 i = 0; i < 12 && !graduated; i++) {
            vm.prank(BUYER);
            curve.buy{value: chunk}(token, 0, block.timestamp + 3600);
            graduated = curve.getCurve(token).graduated;
        }
        assertTrue(graduated, "curve graduated after buying it out");
    }

    /// INV-2 + two-sided, full-range, ACTIVE position, read from the REAL V3.
    function _assertLpLockedAndActive(address poolAddr, uint256 tokenId, uint256 lockerBalBefore)
        internal
    {
        assertEq(INFPMView(NFPM).ownerOf(tokenId), LOCKER, "INV-2: LP NFT owned by locker");
        assertEq(
            INFPMView(NFPM).balanceOf(LOCKER),
            lockerBalBefore + 1,
            "locker received exactly one new position"
        );

        (, , , , , int24 tl, int24 tu, uint128 posLiq, , , , ) = INFPMView(NFPM).positions(tokenId);
        assertEq(uint256(int256(tl)), uint256(int256(MIN_TICK)), "full-range lower tick");
        assertEq(uint256(int256(tu)), uint256(int256(MAX_TICK)), "full-range upper tick");
        assertGt(uint256(posLiq), 0, "position has nonzero liquidity");
        // Pool active liquidity > 0: a full-range two-sided seed spans the spot
        // tick, unlike the one-sided Launchpad seed whose pool.liquidity() is 0.
        assertGt(uint256(IPoolView(poolAddr).liquidity()), 0, "pool active liquidity > 0");
    }

    /// INV-10 (lock lifted), no-trapped-ETH reconciliation, and curve-is-closed.
    function _assertUnlockedAndClosed(WoblCurve curve, address token) internal {
        assertTrue(WoblToken(token).unlocked(), "INV-10: token unlocked at graduation");
        uint256 buyerBal = WoblToken(token).balanceOf(BUYER);
        assertGt(buyerBal, 0, "buyer holds curve tokens");
        vm.prank(BUYER);
        bool moved = WoblToken(token).transfer(BOB2, 1);
        assertTrue(moved, "a normal holder can transfer after graduation");
        assertEq(WoblToken(token).balanceOf(BOB2), 1, "recipient credited");

        // No ETH trapped beyond accrued (pull-based) fees: realEth (the raise)
        // became WETH in the LP; the only ETH left is unclaimed creator+protocol
        // fees. With migrationFeeBps=0 this reconciles exactly.
        uint256 liabilities = curve.creatorFees(token) + curve.protocolFeesAccrued();
        assertEq(address(curve).balance, liabilities, "curve ETH == accrued fees (no trapped ETH)");

        // Curve is CLOSED: post-graduation trades revert.
        vm.deal(BUYER, 1 ether);
        vm.prank(BUYER);
        try curve.buy{value: 0.01 ether}(token, 0, block.timestamp + 3600) {
            assertTrue(false, "buy must revert after graduation");
        } catch {}

        vm.prank(BUYER);
        WoblToken(token).approve(address(curve), buyerBal);
        vm.prank(BUYER);
        try curve.sell(token, 1, 0, block.timestamp + 3600) {
            assertTrue(false, "sell must revert after graduation");
        } catch {}
    }

    /// @dev Scan the recorded logs for Migrated(address,address,uint256,uint256,uint256)
    ///      emitted by the curve and decode the tokenId (first non-indexed arg).
    function _findMigratedTokenId(address curveAddr) internal returns (uint256 tokenId) {
        VmExt.Log[] memory logs = vmx.getRecordedLogs();
        bytes32 sig = keccak256("Migrated(address,address,uint256,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == curveAddr &&
                logs[i].topics.length > 0 &&
                logs[i].topics[0] == sig
            ) {
                (uint256 tid, , ) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                tokenId = tid;
                found = true;
            }
        }
        assertTrue(found, "Migrated event emitted");
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    /// Deploy-config seed (0.001 ether) -> full real V3 graduation.
    function test_graduation_smallSeed() public {
        _fullGraduation(0.001 ether, keccak256("fork-small-seed"));
    }

    /// Modeled mainnet seed (2.222 ether) -> full real V3 graduation.
    function test_graduation_mainnetSeed() public {
        _fullGraduation(2.222 ether, keccak256("fork-mainnet-seed"));
    }

    /// Mid-curve round trip against the REAL math (not mocked): selling every
    /// token bought back returns strictly less ETH than the curve consumed
    /// (two 1% fees + rounding), and the round-tripper ends no richer.
    function test_midCurveRoundTripLoss() public {
        WoblCurve curve = _deployCurve(2.222 ether);
        address token = curve.createToken("RT", "RT", "data:,x", 0, keccak256("fork-roundtrip"));

        uint256 ethIn = 0.5 ether; // comfortably below the 6.666-ether graduation
        vm.deal(BUYER, 10 ether);
        uint256 balBefore = BUYER.balance;

        (, , uint256 ethUsed) = curve.quoteBuy(token, ethIn);
        vm.prank(BUYER);
        curve.buy{value: ethIn}(token, 0, block.timestamp + 3600);

        uint256 got = WoblToken(token).balanceOf(BUYER);
        assertGt(got, 0, "received tokens");
        assertFalse(curve.getCurve(token).graduated, "still on the curve");

        (uint256 ethQuote, ) = curve.quoteSell(token, got);
        assertGt(ethQuote, 0, "sell returns something");

        vm.prank(BUYER);
        WoblToken(token).approve(address(curve), got);
        vm.prank(BUYER);
        curve.sell(token, got, 0, block.timestamp + 3600);

        assertLt(ethQuote, ethUsed, "round-trip loses to fees + rounding");
        assertLe(BUYER.balance, balBefore, "round-tripper ends no richer than started");
    }
}
