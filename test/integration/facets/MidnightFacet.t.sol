// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ReentrancyGuard } from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { IMidnightFacet }          from "../../../src/facets/midnight/IMidnightFacet.sol";
import { IEnumerableIntegrations } from "../../../src/interfaces/IEnumerableIntegrations.sol";

import { makeBytes32Key } from "../../../src/libraries/RateLimitHelpers.sol";

import { MidnightFacet } from "../../../src/facets/midnight/MidnightFacet.sol";
import { MidnightUtils } from "../../../src/facets/midnight/MidnightUtils.sol";

import { Integration_TestBase } from "../TestBase.t.sol";

interface IControllerLike {

    function setMarketConfig(bytes32 marketId, IMidnightFacet.MarketConfig calldata config)
        external;

    function getMarketConfig(bytes32 marketId)
        external
        view
        returns (IMidnightFacet.MarketConfig memory);

    function getBuyRateLimitKey(bytes32 marketId) external pure returns (bytes32);

    function getRedeemRateLimitKey(bytes32 marketId) external pure returns (bytes32);

    function getSellRateLimitKey(bytes32 marketId) external pure returns (bytes32);

    function midnight() external view returns (address);

    function updateIntegrations(bytes32[] memory integrationIds) external;

}

contract Controller_MidnightFacet_Tests is Integration_TestBase {

    // Ticks around par: tickToPrice(4152) is ~0.98 and tickToPrice(4384) is ~0.99.
    uint16 internal constant TICK_98 = 4152;
    uint16 internal constant TICK_99 = 4384;

    uint32 internal constant CONTINUOUS_FEE = uint32(uint256(0.01e18) / uint256(365 days));

    // Basis points a year: a 1% floor on entries and a 10% ceiling on what an exit gives up.
    uint16 internal constant MIN_BUY_YIELD  = 100;
    uint16 internal constant MAX_SELL_YIELD = 1000;

    bytes32 internal constant MARKET_ID = keccak256("market");

    address internal midnight = makeAddr("midnight");

    IControllerLike internal controller;

    function setUp() external {
        controller = IControllerLike(_deploy());

        address facet = address(new MidnightFacet(midnight));

        vm.label(facet, "MidnightFacet");

        IEnumerableIntegrations.Wire[] memory wires = new IEnumerableIntegrations.Wire[](6);

        wires[0] = IEnumerableIntegrations.Wire(
            IControllerLike.setMarketConfig.selector,
            IMidnightFacet.setMarketConfig.selector
        );

        wires[1] = IEnumerableIntegrations.Wire(
            IControllerLike.getMarketConfig.selector,
            IMidnightFacet.getMarketConfig.selector
        );

        wires[2] = IEnumerableIntegrations.Wire(
            IControllerLike.getBuyRateLimitKey.selector,
            IMidnightFacet.getBuyRateLimitKey.selector
        );

        wires[3] = IEnumerableIntegrations.Wire(
            IControllerLike.getRedeemRateLimitKey.selector,
            IMidnightFacet.getRedeemRateLimitKey.selector
        );

        wires[4] = IEnumerableIntegrations.Wire(
            IControllerLike.getSellRateLimitKey.selector,
            IMidnightFacet.getSellRateLimitKey.selector
        );

        wires[5] = IEnumerableIntegrations.Wire(
            IControllerLike.midnight.selector,
            IMidnightFacet.midnight.selector
        );

        IEnumerableIntegrations.Config memory config = IEnumerableIntegrations.Config(facet, wires);

        vm.prank(beaconAdmin);
        beacon.setIntegration("MIDNIGHT_FACET", config);

        bytes32[] memory integrationIds = new bytes32[](1);
        integrationIds[0] = "MIDNIGHT_FACET";

        vm.prank(admin);
        controller.updateIntegrations(integrationIds);
    }

    function _config(uint16 maxBuyTick, uint16 minSellTick, uint32 maxContinuousFee)
        internal
        pure
        returns (IMidnightFacet.MarketConfig memory)
    {
        return IMidnightFacet.MarketConfig({
            maxBuyTick       : maxBuyTick,
            minSellTick      : minSellTick,
            minBuyYield      : MIN_BUY_YIELD,
            maxSellYield     : MAX_SELL_YIELD,
            maxContinuousFee : maxContinuousFee,
            maxLossFactor    : 0
        });
    }

    function _assertConfig(
        bytes32 marketId,
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  minBuyYield,
        uint16  maxSellYield,
        uint32  maxContinuousFee,
        uint128 maxLossFactor
    )
        internal
        view
    {
        IMidnightFacet.MarketConfig memory config = controller.getMarketConfig(marketId);

        assertEq(config.maxBuyTick,       maxBuyTick);
        assertEq(config.minSellTick,      minSellTick);
        assertEq(config.minBuyYield,      minBuyYield);
        assertEq(config.maxSellYield,     maxSellYield);
        assertEq(config.maxContinuousFee, maxContinuousFee);
        assertEq(config.maxLossFactor,    maxLossFactor);
    }

    /**********************************************************************************************/
    /*** Constructor Tests                                                                      ***/
    /**********************************************************************************************/

    function test_constructor_zeroMidnight() external {
        vm.expectRevert("MidnightFacet/zero-midnight");
        new MidnightFacet(address(0));
    }

    function test_constructor() external {
        MidnightFacet facet = new MidnightFacet(midnight);

        assertEq(facet.midnight(), midnight);
    }

    /**********************************************************************************************/
    /*** Immutables Tests                                                                       ***/
    /**********************************************************************************************/

    function test_immutables() external view {
        assertEq(controller.midnight(), midnight);
    }

    /**********************************************************************************************/
    /*** setMarketConfig Tests                                                                  ***/
    /**********************************************************************************************/

    function test_setMarketConfig_reentrancy() external {
        _setEntered(address(controller));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        controller.setMarketConfig(MARKET_ID, _config(TICK_99, TICK_98, CONTINUOUS_FEE));
    }

    function test_setMarketConfig_unauthorizedAccount() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        controller.setMarketConfig(MARKET_ID, _config(TICK_99, TICK_98, CONTINUOUS_FEE));
    }

    function test_setMarketConfig_maxBuyTickOutOfBoundsBoundary() external {
        uint16 maxTick = uint16(MidnightUtils.MAX_TICK);

        vm.expectRevert("MidnightFacet/max-buy-tick-oob");
        vm.prank(admin);
        controller.setMarketConfig(MARKET_ID, _config(maxTick + 1, TICK_98, CONTINUOUS_FEE));

        vm.prank(admin);
        controller.setMarketConfig(MARKET_ID, _config(maxTick, TICK_98, CONTINUOUS_FEE));
    }

    function test_setMarketConfig_minSellTickZero() external {
        vm.expectRevert("MidnightFacet/min-sell-tick-oob");
        vm.prank(admin);
        controller.setMarketConfig(MARKET_ID, _config(TICK_99, 0, CONTINUOUS_FEE));
    }

    function test_setMarketConfig_minSellTickOutOfBoundsBoundary() external {
        uint16 maxTick = uint16(MidnightUtils.MAX_TICK);

        vm.expectRevert("MidnightFacet/min-sell-tick-oob");
        vm.prank(admin);
        controller.setMarketConfig(MARKET_ID, _config(TICK_99, maxTick + 1, CONTINUOUS_FEE));

        vm.prank(admin);
        controller.setMarketConfig(MARKET_ID, _config(TICK_99, maxTick, CONTINUOUS_FEE));
    }

    function test_setMarketConfig_maxContinuousFeeOutOfBoundsBoundary() external {
        uint32 maxFee = uint32(MidnightUtils.MAX_CONTINUOUS_FEE);

        vm.expectRevert("MidnightFacet/max-continuous-fee-oob");
        vm.prank(admin);
        controller.setMarketConfig(MARKET_ID, _config(TICK_99, TICK_98, maxFee + 1));

        vm.prank(admin);
        controller.setMarketConfig(MARKET_ID, _config(TICK_99, TICK_98, maxFee));
    }

    function test_setMarketConfig_maxSellYieldZero() external {
        vm.expectRevert("MidnightFacet/max-sell-yield-not-set");
        vm.prank(admin);
        controller.setMarketConfig(MARKET_ID, IMidnightFacet.MarketConfig({
            maxBuyTick       : TICK_99,
            minSellTick      : TICK_98,
            minBuyYield      : MIN_BUY_YIELD,
            maxSellYield     : 0,
            maxContinuousFee : CONTINUOUS_FEE,
            maxLossFactor    : 0
        }));
    }

    function test_setMarketConfig() external {
        _assertConfig(MARKET_ID, 0, 0, 0, 0, 0, 0);

        vm.record();

        vm.expectEmit(address(controller));
        emit IMidnightFacet.MidnightMarketConfigSet(
            MARKET_ID,
            TICK_99,
            TICK_98,
            MIN_BUY_YIELD,
            MAX_SELL_YIELD,
            CONTINUOUS_FEE,
            1
        );

        vm.prank(admin);
        controller.setMarketConfig(MARKET_ID, IMidnightFacet.MarketConfig({
            maxBuyTick       : TICK_99,
            minSellTick      : TICK_98,
            minBuyYield      : MIN_BUY_YIELD,
            maxSellYield     : MAX_SELL_YIELD,
            maxContinuousFee : CONTINUOUS_FEE,
            maxLossFactor    : 1
        }));

        _assertReentrancyGuardWrittenToTwice(address(controller));

        _assertConfig(MARKET_ID, TICK_99, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 1);

        // A zero maxBuyTick closes entries while keeping the exits onboarded, and a zero buy yield
        // floor is the loosest entry bound that still refuses to pay above par.
        vm.expectEmit(address(controller));
        emit IMidnightFacet.MidnightMarketConfigSet(MARKET_ID, 0, TICK_98, 0, MAX_SELL_YIELD, 0, 0);

        vm.prank(admin);
        controller.setMarketConfig(MARKET_ID, IMidnightFacet.MarketConfig({
            maxBuyTick       : 0,
            minSellTick      : TICK_98,
            minBuyYield      : 0,
            maxSellYield     : MAX_SELL_YIELD,
            maxContinuousFee : 0,
            maxLossFactor    : 0
        }));

        _assertConfig(MARKET_ID, 0, TICK_98, 0, MAX_SELL_YIELD, 0, 0);
    }

    function test_setMarketConfig_perMarket() external {
        bytes32 otherMarketId = keccak256("other-market");

        vm.startPrank(admin);
        controller.setMarketConfig(MARKET_ID,     _config(TICK_99, TICK_98, CONTINUOUS_FEE));
        controller.setMarketConfig(otherMarketId, _config(TICK_98, TICK_98, 0));
        vm.stopPrank();

        // Each market keeps its own config.
        _assertConfig(
            MARKET_ID, TICK_99, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );
        _assertConfig(otherMarketId, TICK_98, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, 0, 0);
    }

    /**********************************************************************************************/
    /*** Rate Limit Key Tests                                                                   ***/
    /**********************************************************************************************/

    function test_getBuyRateLimitKey() external view {
        assertEq(
            controller.getBuyRateLimitKey(MARKET_ID),
            makeBytes32Key(keccak256("LIMIT_MIDNIGHT_BUY"), MARKET_ID)
        );
    }

    function test_getRedeemRateLimitKey() external view {
        assertEq(
            controller.getRedeemRateLimitKey(MARKET_ID),
            makeBytes32Key(keccak256("LIMIT_MIDNIGHT_REDEEM"), MARKET_ID)
        );
    }

    function test_getSellRateLimitKey() external view {
        assertEq(
            controller.getSellRateLimitKey(MARKET_ID),
            makeBytes32Key(keccak256("LIMIT_MIDNIGHT_SELL"), MARKET_ID)
        );
    }

}
