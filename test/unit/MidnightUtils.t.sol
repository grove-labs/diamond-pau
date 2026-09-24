// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import {
    CollateralParams,
    Market,
    MidnightUtils
} from "../../src/facets/midnight/MidnightUtils.sol";

// Wrapper contract to expose library internals for testing
contract MidnightUtilsHarness {

    function toId(Market memory market) external pure returns (bytes32) {
        return MidnightUtils.toId(market);
    }

    function tickToPrice(uint256 tick) external pure returns (uint256) {
        return MidnightUtils.tickToPrice(tick);
    }

    function wExp(int256 x) external pure returns (uint256) {
        return MidnightUtils.wExp(x);
    }

    function divHalfDownUnchecked(uint256 x, uint256 d) external pure returns (uint256) {
        return MidnightUtils.divHalfDownUnchecked(x, d);
    }

    function maxBuyPrice(uint256 minYield, uint256 timeToMaturity, uint256 continuousFee)
        external
        pure
        returns (uint256)
    {
        return MidnightUtils.maxBuyPrice(minYield, timeToMaturity, continuousFee);
    }

    function minSellPrice(uint256 maxYield, uint256 timeToMaturity, uint256 continuousFee)
        external
        pure
        returns (uint256)
    {
        return MidnightUtils.minSellPrice(maxYield, timeToMaturity, continuousFee);
    }

    function continuousFeePerSecond(uint256 cbpsPerYear) external pure returns (uint256) {
        return MidnightUtils.continuousFeePerSecond(cbpsPerYear);
    }

}

contract MidnightUtilsTestBase is Test {

    MidnightUtilsHarness internal harness;

    function setUp() public {
        harness = new MidnightUtilsHarness();
    }

}

contract MidnightUtils_TickToPrice_Tests is MidnightUtilsTestBase {

    // The grid is centered on a price of one half at the middle tick and capped at par.
    function test_tickToPrice_anchors() external view {
        assertEq(harness.tickToPrice(0),                      0);
        assertEq(harness.tickToPrice(MidnightUtils.MAX_TICK / 2), 0.5e18);
        assertEq(harness.tickToPrice(MidnightUtils.MAX_TICK),     1e18);
    }

    function test_tickToPrice_outOfRange() external {
        vm.expectRevert("MidnightFacet/tick-out-of-range");
        harness.tickToPrice(MidnightUtils.MAX_TICK + 1);
    }

    function test_tickToPrice_roundedToStep() external view {
        for (uint256 tick = 0; tick <= MidnightUtils.MAX_TICK; tick += 97) {
            assertEq(harness.tickToPrice(tick) % MidnightUtils.PRICE_ROUNDING_STEP, 0);
        }
    }

    // Tick bounds are enforced in price space, which only works if the conversion never
    // reverses order: a higher tick must never map to a lower price.
    function testFuzz_tickToPrice_monotonic(uint256 tick) external view {
        tick = bound(tick, 1, MidnightUtils.MAX_TICK);

        assertGe(harness.tickToPrice(tick), harness.tickToPrice(tick - 1));
    }

    function testFuzz_tickToPrice_atMostPar(uint256 tick) external view {
        tick = bound(tick, 0, MidnightUtils.MAX_TICK);

        assertLe(harness.tickToPrice(tick), 1e18);
    }

}

contract MidnightUtils_WExp_Tests is MidnightUtilsTestBase {

    function test_wExp_zero() external view {
        assertEq(harness.wExp(0), 1e18);
    }

    // The negative branch is the reciprocal of the positive branch.
    function test_wExp_negativeIsReciprocal() external view {
        int256 x = 0.5e18;

        assertEq(harness.wExp(-x), 1e36 / harness.wExp(x));
    }

    function testFuzz_wExp_nonDecreasing(int256 x) external view {
        // Ticks only ever feed |x| <= LN_ONE_PLUS_DELTA * MAX_TICK / 2 into wExp.
        x = bound(x, -17e18, 17e18 - 1);

        assertLe(harness.wExp(x), harness.wExp(x + 1));
    }

}

contract MidnightUtils_DivHalfDownUnchecked_Tests is MidnightUtilsTestBase {

    function test_divHalfDownUnchecked_exact() external view {
        assertEq(harness.divHalfDownUnchecked(10, 5), 2);
    }

    function test_divHalfDownUnchecked_roundsHalfDown() external view {
        assertEq(harness.divHalfDownUnchecked(15, 10), 1);  // 1.5 -> 1
        assertEq(harness.divHalfDownUnchecked(16, 10), 2);  // 1.6 -> 2
        assertEq(harness.divHalfDownUnchecked(14, 10), 1);  // 1.4 -> 1
    }

}

contract MidnightUtils_YieldPrice_Tests is MidnightUtilsTestBase {

    uint256 internal constant MAX_TIME_TO_MATURITY = 100 * 365 days;  // Upstream's own ceiling.

    // Simple interest on cost: the yield a price implies over the term, annualized ACT/365.
    function _earnsAtLeast(uint256 price, uint256 ttm, uint256 fee, uint256 yieldBp)
        internal
        pure
        returns (bool)
    {
        uint256 payoff = MidnightUtils.WAD - fee * ttm;

        if (price > payoff) return false;

        return (payoff - price) * MidnightUtils.YEAR * MidnightUtils.WAD
            >= yieldBp * MidnightUtils.YIELD_BP_RATE * ttm * price;
    }

    function _givesUpAtMost(uint256 price, uint256 ttm, uint256 fee, uint256 yieldBp)
        internal
        pure
        returns (bool)
    {
        uint256 payoff = MidnightUtils.WAD - fee * ttm;

        if (price > payoff) return true;

        return (payoff - price) * MidnightUtils.YEAR * MidnightUtils.WAD
            <= yieldBp * MidnightUtils.YIELD_BP_RATE * ttm * price;
    }

    // Five percent a year over exactly a year is par discounted by 1.05: floored for the buy
    // ceiling, ceilinged for the sell floor.
    function test_yieldPrice_anchors() external view {
        assertEq(harness.maxBuyPrice(5_00, 365 days, 0),  952380952380952380);
        assertEq(harness.minSellPrice(5_00, 365 days, 0), 952380952380952381);
    }

    // Pinned against an independent model of the same formula.
    function test_yieldPrice_modelAnchors() external view {
        assertEq(harness.maxBuyPrice(1_00,   30 days, 0),  999178757185874623);
        assertEq(harness.maxBuyPrice(4_00,  180 days, 0),  980655561526061257);
        assertEq(harness.maxBuyPrice(10_00, 360 days, 0),  910224438902743142);
        assertEq(harness.minSellPrice(4_00, 180 days, 0),  980655561526061258);
        assertEq(harness.minSellPrice(10_00, 30 days, 0),  991847826086956522);

        assertEq(
            harness.maxBuyPrice(4_00, 180 days, MidnightUtils.MAX_CONTINUOUS_FEE),
            975819451920351638
        );
    }

    // The bound is the exact price at which the configured yield is met, not an approximation of
    // it: it satisfies the rail and one wei the wrong way does not.
    function testFuzz_yieldPrice_impliedYieldIsTight(
        uint256 yieldBp,
        uint256 timeToMaturity,
        uint256 continuousFee
    )
        external
        view
    {
        yieldBp        = bound(yieldBp, 0, type(uint16).max);
        timeToMaturity = bound(timeToMaturity, 0, MAX_TIME_TO_MATURITY);
        continuousFee  = bound(continuousFee, 0, MidnightUtils.MAX_CONTINUOUS_FEE);

        uint256 buyCap    = harness.maxBuyPrice(yieldBp, timeToMaturity, continuousFee);
        uint256 sellFloor = harness.minSellPrice(yieldBp, timeToMaturity, continuousFee);

        assertTrue(_earnsAtLeast(buyCap,       timeToMaturity, continuousFee, yieldBp));
        assertFalse(_earnsAtLeast(buyCap + 1,  timeToMaturity, continuousFee, yieldBp));

        assertTrue(_givesUpAtMost(sellFloor,      timeToMaturity, continuousFee, yieldBp));
        assertFalse(_givesUpAtMost(sellFloor - 1, timeToMaturity, continuousFee, yieldBp));
    }

    // With no term left there is no yield to earn or give up, so both bounds collapse onto par.
    function test_yieldPrice_zeroTimeToMaturity() external view {
        assertEq(harness.maxBuyPrice(50_00, 0, MidnightUtils.MAX_CONTINUOUS_FEE),  1e18);
        assertEq(harness.minSellPrice(50_00, 0, MidnightUtils.MAX_CONTINUOUS_FEE), 1e18);
    }

    // A zero bound is not a disabled bound: it still refuses a price above what a unit pays back.
    function test_yieldPrice_zeroYield() external view {
        uint256 fee = MidnightUtils.MAX_CONTINUOUS_FEE;

        assertEq(harness.maxBuyPrice(0, 180 days, 0),   1e18);
        assertEq(harness.maxBuyPrice(0, 180 days, fee), 1e18 - fee * 180 days);
    }

    function test_yieldPrice_netsContinuousFee() external view {
        uint256 fee = MidnightUtils.MAX_CONTINUOUS_FEE;

        uint256 term = 180 days;

        assertLt(harness.maxBuyPrice(4_00, term, fee),  harness.maxBuyPrice(4_00, term, 0));
        assertLt(harness.minSellPrice(4_00, term, fee), harness.minSellPrice(4_00, term, 0));
    }

    // Upstream caps maturity a hundred years out and the continuous fee at one percent a year, so
    // even at both ceilings the payoff stays above zero and the arithmetic does not overflow.
    function test_yieldPrice_extremeInputs() external view {
        uint256 fee   = MidnightUtils.MAX_CONTINUOUS_FEE;
        uint256 yield_ = type(uint16).max;

        assertGt(harness.maxBuyPrice(yield_, MAX_TIME_TO_MATURITY, fee),  0);
        assertLe(harness.minSellPrice(yield_, MAX_TIME_TO_MATURITY, fee), 1e18);
    }

    // A tighter bound must never let a worse price through.
    function testFuzz_yieldPrice_nonIncreasingInYield(uint256 yieldBp, uint256 timeToMaturity)
        external
        view
    {
        yieldBp        = bound(yieldBp, 1, type(uint16).max);
        timeToMaturity = bound(timeToMaturity, 0, MAX_TIME_TO_MATURITY);

        assertLe(
            harness.maxBuyPrice(yieldBp, timeToMaturity, 0),
            harness.maxBuyPrice(yieldBp - 1, timeToMaturity, 0)
        );
        assertLe(
            harness.minSellPrice(yieldBp, timeToMaturity, 0),
            harness.minSellPrice(yieldBp - 1, timeToMaturity, 0)
        );
    }

    // The same bound is worth a lower price the longer the term left on it.
    function testFuzz_yieldPrice_nonIncreasingInTerm(uint256 timeToMaturity) external view {
        timeToMaturity = bound(timeToMaturity, 1, MAX_TIME_TO_MATURITY);

        assertLe(
            harness.maxBuyPrice(4_00, timeToMaturity, 0),
            harness.maxBuyPrice(4_00, timeToMaturity - 1, 0)
        );
    }

    // Rounding separates the two directions by at most one wei, and never the wrong way round.
    function testFuzz_yieldPrice_roundingBrackets(
        uint256 yieldBp,
        uint256 timeToMaturity,
        uint256 continuousFee
    )
        external
        view
    {
        yieldBp        = bound(yieldBp, 0, type(uint16).max);
        timeToMaturity = bound(timeToMaturity, 0, MAX_TIME_TO_MATURITY);
        continuousFee  = bound(continuousFee, 0, MidnightUtils.MAX_CONTINUOUS_FEE);

        uint256 buyCap    = harness.maxBuyPrice(yieldBp, timeToMaturity, continuousFee);
        uint256 sellFloor = harness.minSellPrice(yieldBp, timeToMaturity, continuousFee);

        assertGe(sellFloor, buyCap);
        assertLe(sellFloor - buyCap, 1);
        assertLe(sellFloor, 1e18);
    }

}

contract MidnightUtils_ContinuousFee_Tests is MidnightUtilsTestBase {

    // Centi-basis points a year, grouped as percent_bp_cbp, so 1_00_00 is one percent a year.
    function test_continuousFeePerSecond_anchors() external view {
        assertEq(harness.continuousFeePerSecond(0),       0);
        assertEq(harness.continuousFeePerSecond(1),       31_709);
        assertEq(harness.continuousFeePerSecond(20_00),   63_419_583);
        assertEq(harness.continuousFeePerSecond(1_00_00), 317_097_919);
    }

    // The config ceiling is the annual form of Midnight's own per second cap, so the top of the
    // range has to land on it exactly and the next value up has to overshoot it.
    function test_continuousFeePerSecond_matchesUpstreamCeiling() external view {
        assertEq(harness.continuousFeePerSecond(1_00_00), MidnightUtils.MAX_CONTINUOUS_FEE);
        assertGt(harness.continuousFeePerSecond(1_00_01), MidnightUtils.MAX_CONTINUOUS_FEE);
    }

    // Flooring is the strict direction: what the market may charge never annualizes above the rate
    // governance named, and falls short of it by less than one unit of the per second rate.
    function testFuzz_continuousFeePerSecond_floorsToNamedRate(uint256 cbpsPerYear) external view {
        cbpsPerYear = bound(cbpsPerYear, 0, type(uint16).max);

        uint256 charged = harness.continuousFeePerSecond(cbpsPerYear) * MidnightUtils.YEAR;
        uint256 named   = cbpsPerYear * MidnightUtils.FEE_CBP_RATE;

        assertLe(charged, named);
        assertLt(named - charged, MidnightUtils.YEAR);
    }

}

contract MidnightUtils_ToId_Tests is MidnightUtilsTestBase {

    function _market(address midnight, address loanToken) internal pure returns (Market memory) {
        CollateralParams[] memory collateralParams = new CollateralParams[](1);
        collateralParams[0] = CollateralParams({
            token             : address(0xC0),
            lltv              : 0.86e18,
            liquidationCursor : 0.3e18,
            oracle            : address(0x01)
        });

        return Market({
            chainId          : 1,
            midnight         : midnight,
            loanToken        : loanToken,
            collateralParams : collateralParams,
            maturity         : 1_800_000_000,
            rcfThreshold     : type(uint256).max,
            enterGate        : address(0),
            liquidatorGate   : address(0)
        });
    }

    // The id is the CREATE2 address of the config stored as bytecode, so every field commits.
    function test_toId_isCreate2Address() external view {
        Market memory market = _market(address(0xA1), address(0xB1));

        bytes32 expected = keccak256(abi.encodePacked(
            uint8(0xff),
            market.midnight,
            uint256(0),
            keccak256(abi.encodePacked(MidnightUtils.SSTORE2_PREFIX, abi.encode(market)))
        ));

        assertEq(harness.toId(market), expected);
    }

    function test_toId_commitsToEveryField() external view {
        Market memory base = _market(address(0xA1), address(0xB1));
        bytes32 baseId = harness.toId(base);

        Market memory m = _market(address(0xA1), address(0xB1));
        m.chainId = 8453;
        assertNotEq(harness.toId(m), baseId);

        m = _market(address(0xA2), address(0xB1));
        assertNotEq(harness.toId(m), baseId);

        m = _market(address(0xA1), address(0xB2));
        assertNotEq(harness.toId(m), baseId);

        m = _market(address(0xA1), address(0xB1));
        m.maturity += 1;
        assertNotEq(harness.toId(m), baseId);

        m = _market(address(0xA1), address(0xB1));
        m.collateralParams[0].lltv += 1;
        assertNotEq(harness.toId(m), baseId);
    }

}
