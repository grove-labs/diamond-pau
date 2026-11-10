// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { MidnightFacet }             from "../../src/facets/midnight/MidnightFacet.sol";
import { MAX_TICK, MidnightTickLib } from "../../src/facets/midnight/MidnightTickLib.sol";
import { MidnightUtils }             from "../../src/facets/midnight/MidnightUtils.sol";

contract MidnightFacetHarness is MidnightFacet {

    constructor(address midnight_) MidnightFacet(midnight_) {}

    function buyBounds(MarketConfig memory config, uint256 timeToMaturity, uint256 continuousFee)
        external
        returns (uint256, uint256)
    {
        return _buyBounds(_store(config), timeToMaturity, continuousFee);
    }

    function sellBounds(MarketConfig memory config, uint256 timeToMaturity, uint256 feePerUnit)
        external
        returns (uint256, uint256)
    {
        return _sellBounds(_store(config), timeToMaturity, feePerUnit);
    }

    function sellFeePerUnit(
        uint256 creditPost,
        uint256 carriedFee,
        uint256 units,
        uint256 reportedFee
    )
        external
        pure
        returns (uint256)
    {
        return _sellFeePerUnit(creditPost, carriedFee, units, reportedFee);
    }

    function _store(MarketConfig memory config) internal returns (MarketConfig storage stored) {
        stored = _getFacetStorage().marketConfigs[bytes32(0)];

        stored.maxBuyTick   = config.maxBuyTick;
        stored.minSellTick  = config.minSellTick;
        stored.minBuyYield  = config.minBuyYield;
        stored.maxSellYield = config.maxSellYield;
    }

}

contract MidnightFacet_Bounds_Tests is Test {

    uint256 internal constant MAX_TIME_TO_MATURITY = 100 * 365 days;  // Upstream's own ceiling.

    MidnightFacetHarness internal harness;

    function setUp() public {
        harness = new MidnightFacetHarness(makeAddr("midnight"));
    }

    function _config(uint16 maxBuyTick, uint16 minSellTick, uint16 minBuyYield, uint16 maxSellYield)
        internal
        pure
        returns (MidnightFacet.MarketConfig memory config)
    {
        config.maxBuyTick   = maxBuyTick;
        config.minSellTick  = minSellTick;
        config.minBuyYield  = minBuyYield;
        config.maxSellYield = maxSellYield;
    }

    function testFuzz_buyBounds_matchTakeBounds(
        uint16  maxBuyTick,
        uint16  minBuyYield,
        uint256 timeToMaturity,
        uint256 continuousFee
    )
        external
    {
        maxBuyTick     = uint16(bound(maxBuyTick, 0, MAX_TICK));
        timeToMaturity = bound(timeToMaturity, 0, MAX_TIME_TO_MATURITY);
        continuousFee  = bound(continuousFee, 0, MidnightUtils.MAX_CONTINUOUS_FEE);

        ( uint256 tickBound, uint256 yieldBound ) = harness.buyBounds(
            _config(maxBuyTick, 0, minBuyYield, 0), timeToMaturity, continuousFee
        );

        assertEq(tickBound,  MidnightTickLib.tickToPrice(maxBuyTick));
        assertEq(yieldBound, MidnightUtils.maxBuyPrice(minBuyYield, timeToMaturity, continuousFee));
    }

    function testFuzz_sellBounds_takeYieldBoundUnchanged(
        uint16  minSellTick,
        uint16  maxSellYield,
        uint256 timeToMaturity,
        uint256 credit,
        uint256 pendingFee
    )
        external
    {
        minSellTick    = uint16(bound(minSellTick, 1, MAX_TICK));
        timeToMaturity = bound(timeToMaturity, 0, MAX_TIME_TO_MATURITY);
        credit         = bound(credit, 1, type(uint128).max);
        pendingFee     = bound(pendingFee, 0, credit);

        ( uint256 tickBound, uint256 yieldBound ) = harness.sellBounds(
            _config(0, minSellTick, 0, maxSellYield), timeToMaturity, pendingFee * 1e18 / credit
        );

        assertEq(tickBound, MidnightTickLib.tickToPrice(minSellTick));
        assertEq(
            yieldBound,
            MidnightUtils.minSellPrice(maxSellYield, timeToMaturity, credit, pendingFee)
        );
    }

    function testFuzz_sellFeePerUnit_isTheLowerOfReportedAndCarried(
        uint256 creditPost,
        uint256 carriedFee,
        uint256 units,
        uint256 reportedFee,
        bool    fullExit
    )
        external
        view
    {
        units       = bound(units, 1, type(uint128).max);
        creditPost  = fullExit ? 0 : bound(creditPost, 1, type(uint128).max);
        carriedFee  = bound(carriedFee, 0, creditPost);
        reportedFee = bound(reportedFee, 0, type(uint128).max);

        uint256 expected;

        if (creditPost != 0) {
            uint256 carried  = carriedFee  * 1e18 / creditPost;
            uint256 reported = reportedFee * 1e18 / units;

            expected = carried < reported ? carried : reported;
        }

        uint256 feePerUnit = harness.sellFeePerUnit(creditPost, carriedFee, units, reportedFee);

        assertEq(feePerUnit, expected);
        assertEq(feePerUnit, _exitFeePerUnit(creditPost, carriedFee, units, reportedFee));
    }

    // The facet's earlier form, which read the position itself and divided before the zero check.
    function _exitFeePerUnit(uint256 credit, uint256 carried, uint256 units, uint256 pendingFee)
        internal
        pure
        returns (uint256 feePerUnit)
    {
        feePerUnit = pendingFee * MidnightUtils.WAD / units;

        uint256 carriedPerUnit = credit == 0 ? 0 : carried * MidnightUtils.WAD / credit;

        if (carriedPerUnit < feePerUnit) feePerUnit = carriedPerUnit;
    }

}
