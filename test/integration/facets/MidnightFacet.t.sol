// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ERC20Mock } from "../../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import { ReentrancyGuard } from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { IMidnightFacet }          from "../../../src/facets/midnight/IMidnightFacet.sol";
import { IEnumerableIntegrations } from "../../../src/interfaces/IEnumerableIntegrations.sol";

import { makeBytes32Key } from "../../../src/libraries/RateLimitHelpers.sol";

import { MidnightFacet } from "../../../src/facets/midnight/MidnightFacet.sol";
import { Market }        from "../../../src/facets/midnight/MidnightInterfaces.sol";
import { MAX_TICK, MidnightTickLib } from "../../../src/facets/midnight/MidnightTickLib.sol";

import { MidnightTakeBuffer } from "../../mocks/MidnightTakeBuffer.sol";

import { Integration_TestBase } from "../TestBase.t.sol";

interface IControllerLike {

    function setMarketConfig(
        bytes32 marketId,
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  minBuyYield,
        uint16  maxSellYield,
        uint16  maxContinuousFee,
        uint128 maxLossFactor
    ) external;

    function getMarketConfig(bytes32 marketId)
        external
        view
        returns (IMidnightFacet.MarketConfig memory);

    function getBuyRateLimitKey(bytes32 marketId) external pure returns (bytes32);

    function getRedeemRateLimitKey(bytes32 marketId) external pure returns (bytes32);

    function getSellRateLimitKey(bytes32 marketId) external pure returns (bytes32);

    function midnight() external view returns (address);

    function proxy() external view returns (address);

    function setTakeBuffer(address buffer) external;

    function takeBuffer() external view returns (address);

    function updateIntegrations(bytes32[] memory integrationIds) external;

}

contract Controller_MidnightFacet_Tests is Integration_TestBase {

    // Ticks around par: tickToPrice(4152) is ~0.98 and tickToPrice(4384) is ~0.99.
    uint16 internal constant TICK_98 = 4152;
    uint16 internal constant TICK_99 = 4384;

    // Centi-basis points a year, grouped as percent_bp_cbp. This is Midnight's own ceiling.
    uint16 internal constant CONTINUOUS_FEE = 1_00_00;

    // Basis points a year: a 1% floor on entries and a 10% ceiling on what an exit gives up.
    uint16 internal constant MIN_BUY_YIELD  = 1_00;
    uint16 internal constant MAX_SELL_YIELD = 10_00;

    bytes32 internal constant MARKET_ID = keccak256("market");

    address internal midnight = makeAddr("midnight");

    IControllerLike internal controller;

    address internal takeBuffer;

    ERC20Mock internal loanToken;

    function setUp() external {
        controller = IControllerLike(_deploy());

        address facet = address(new MidnightFacet(midnight));

        vm.label(facet, "MidnightFacet");

        IEnumerableIntegrations.Wire[] memory wires = new IEnumerableIntegrations.Wire[](8);

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

        wires[6] = IEnumerableIntegrations.Wire(
            IControllerLike.setTakeBuffer.selector,
            IMidnightFacet.setTakeBuffer.selector
        );

        wires[7] = IEnumerableIntegrations.Wire(
            IControllerLike.takeBuffer.selector,
            IMidnightFacet.takeBuffer.selector
        );

        IEnumerableIntegrations.Config memory config = IEnumerableIntegrations.Config(facet, wires);

        vm.prank(beaconAdmin);
        beacon.setIntegration("MIDNIGHT_FACET", config);

        bytes32[] memory integrationIds = new bytes32[](1);
        integrationIds[0] = "MIDNIGHT_FACET";

        vm.prank(admin);
        controller.updateIntegrations(integrationIds);

        takeBuffer = address(new MidnightTakeBuffer(midnight, controller.proxy()));

        vm.prank(admin);
        controller.setTakeBuffer(takeBuffer);

        loanToken = new ERC20Mock();

        Market memory market;
        market.loanToken = address(loanToken);

        vm.mockCall(midnight, abi.encodeWithSignature("toMarket(bytes32)"), abi.encode(market));
    }

    function _setConfig(
        bytes32 marketId,
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  maxContinuousFee
    )
        internal
    {
        controller.setMarketConfig(
            marketId, maxBuyTick, minSellTick, MIN_BUY_YIELD, MAX_SELL_YIELD, maxContinuousFee, 0
        );
    }

    function _assertConfig(
        bytes32 marketId,
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  minBuyYield,
        uint16  maxSellYield,
        uint16  maxContinuousFee,
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

    function _clearTakeBuffer() internal {
        bytes32 location =
            keccak256(abi.encode(uint256(keccak256("sky.pau.storage.MidnightFacet.v1")) - 1)) & ~bytes32(uint256(0xff));

        bytes32 buffer = bytes32(uint256(uint160(controller.takeBuffer())));

        assertNotEq(buffer, bytes32(0));

        bytes32 slot;
        uint256 matches;

        for (uint256 i; i < 8; ++i) {
            bytes32 candidate = bytes32(uint256(location) + i);

            if (vm.load(address(controller), candidate) == buffer) {
                slot = candidate;
                ++matches;
            }
        }

        assertEq(matches, 1);

        vm.store(address(controller), slot, bytes32(0));

        assertEq(controller.takeBuffer(), address(0));
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
        _setConfig(MARKET_ID, TICK_99, TICK_98, CONTINUOUS_FEE);
    }

    function test_setMarketConfig_unauthorizedAccount() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        _setConfig(MARKET_ID, TICK_99, TICK_98, CONTINUOUS_FEE);
    }

    function test_setMarketConfig_maxBuyTickOutOfBoundsBoundary() external {
        uint16 maxTick = uint16(MAX_TICK);

        vm.expectRevert("MidnightFacet/max-buy-tick-oob");
        vm.prank(admin);
        _setConfig(MARKET_ID, maxTick + 1, TICK_98, CONTINUOUS_FEE);

        vm.prank(admin);
        _setConfig(MARKET_ID, maxTick, TICK_98, CONTINUOUS_FEE);
    }

    function test_setMarketConfig_minSellTickZero() external {
        vm.expectRevert("MidnightFacet/min-sell-tick-oob");
        vm.prank(admin);
        _setConfig(MARKET_ID, TICK_99, 0, CONTINUOUS_FEE);
    }

    function test_setMarketConfig_minSellTickOutOfBoundsBoundary() external {
        uint16 maxTick = uint16(MAX_TICK);

        vm.expectRevert("MidnightFacet/min-sell-tick-oob");
        vm.prank(admin);
        _setConfig(MARKET_ID, TICK_99, maxTick + 1, CONTINUOUS_FEE);

        vm.prank(admin);
        _setConfig(MARKET_ID, TICK_99, maxTick, CONTINUOUS_FEE);
    }

    function test_setMarketConfig_minSellTickZeroPriceBoundary() external {
        assertEq(MidnightTickLib.tickToPrice(1), 0);
        assertGt(MidnightTickLib.tickToPrice(2), 0);

        vm.expectRevert("MidnightFacet/min-sell-tick-oob");
        vm.prank(admin);
        _setConfig(MARKET_ID, TICK_99, 1, CONTINUOUS_FEE);

        vm.prank(admin);
        _setConfig(MARKET_ID, TICK_99, 2, CONTINUOUS_FEE);
    }

    function test_setMarketConfig_maxContinuousFeeOutOfBoundsBoundary() external {
        vm.expectRevert("MidnightFacet/max-continuous-fee-oob");
        vm.prank(admin);
        _setConfig(MARKET_ID, TICK_99, TICK_98, CONTINUOUS_FEE + 1);

        vm.prank(admin);
        _setConfig(MARKET_ID, TICK_99, TICK_98, CONTINUOUS_FEE);
    }

    function test_setMarketConfig_maxSellYieldZero() external {
        vm.expectRevert("MidnightFacet/max-sell-yield-not-set");
        vm.prank(admin);
        controller.setMarketConfig(
            MARKET_ID, TICK_99, TICK_98, MIN_BUY_YIELD, 0, CONTINUOUS_FEE, 0
        );
    }

    function test_setMarketConfig_takeBufferNotSet() external {
        _clearTakeBuffer();

        vm.expectRevert(bytes(""));
        vm.prank(admin);
        _setConfig(MARKET_ID, TICK_99, TICK_98, CONTINUOUS_FEE);
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
        controller.setMarketConfig(
            MARKET_ID, TICK_99, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 1
        );

        _assertReentrancyGuardWrittenToTwice(address(controller));

        _assertConfig(MARKET_ID, TICK_99, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 1);

        // A zero maxBuyTick closes entries while keeping the exits onboarded, and a zero buy yield
        // floor is the loosest entry bound that still refuses to pay above par.
        vm.expectEmit(address(controller));
        emit IMidnightFacet.MidnightMarketConfigSet(MARKET_ID, 0, TICK_98, 0, MAX_SELL_YIELD, 0, 0);

        vm.prank(admin);
        controller.setMarketConfig(MARKET_ID, 0, TICK_98, 0, MAX_SELL_YIELD, 0, 0);

        _assertConfig(MARKET_ID, 0, TICK_98, 0, MAX_SELL_YIELD, 0, 0);
    }

    function test_setMarketConfig_approvesLoanToken() external {
        assertEq(MidnightTakeBuffer.approve.selector, bytes4(keccak256("approve(address)")));

        address proxy = controller.proxy();

        assertEq(loanToken.allowance(takeBuffer, proxy),    0);
        assertEq(loanToken.allowance(takeBuffer, midnight), 0);

        vm.expectCall(midnight, abi.encodeWithSignature("toMarket(bytes32)", MARKET_ID));
        vm.expectCall(takeBuffer, abi.encodeCall(MidnightTakeBuffer.approve, (address(loanToken))));

        vm.prank(admin);
        _setConfig(MARKET_ID, TICK_99, TICK_98, CONTINUOUS_FEE);

        assertEq(loanToken.allowance(takeBuffer, proxy),    type(uint256).max);
        assertEq(loanToken.allowance(takeBuffer, midnight), type(uint256).max);
    }

    function test_setMarketConfig_perMarket() external {
        bytes32 otherMarketId = keccak256("other-market");

        vm.startPrank(admin);
        _setConfig(MARKET_ID,     TICK_99, TICK_98, CONTINUOUS_FEE);
        _setConfig(otherMarketId, TICK_98, TICK_98, 0);
        vm.stopPrank();

        // Each market keeps its own config.
        _assertConfig(
            MARKET_ID, TICK_99, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );
        _assertConfig(otherMarketId, TICK_98, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, 0, 0);
    }

    /**********************************************************************************************/
    /*** setTakeBuffer Tests                                                                    ***/
    /**********************************************************************************************/

    function test_setTakeBuffer_reentrancy() external {
        _setEntered(address(controller));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        controller.setTakeBuffer(takeBuffer);
    }

    function test_setTakeBuffer_unauthorized() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        controller.setTakeBuffer(takeBuffer);
    }

    function test_setTakeBuffer_zeroAddress() external {
        vm.expectRevert("MidnightFacet/zero-take-buffer");
        vm.prank(admin);
        controller.setTakeBuffer(address(0));
    }

    function test_setTakeBuffer_proxyMismatch() external {
        address buffer = address(new MidnightTakeBuffer(midnight, makeAddr("otherProxy")));

        vm.expectRevert("MidnightFacet/invalid-take-buffer-proxy");
        vm.prank(admin);
        controller.setTakeBuffer(buffer);
    }

    function test_setTakeBuffer_midnightMismatch() external {
        address buffer =
            address(new MidnightTakeBuffer(makeAddr("otherMidnight"), controller.proxy()));

        vm.expectRevert("MidnightFacet/invalid-take-buffer-midnight");
        vm.prank(admin);
        controller.setTakeBuffer(buffer);
    }

    function test_setTakeBuffer_swappedConstructorArguments() external {
        address buffer = address(new MidnightTakeBuffer(controller.proxy(), midnight));

        vm.expectRevert("MidnightFacet/invalid-take-buffer-proxy");
        vm.prank(admin);
        controller.setTakeBuffer(buffer);
    }

    function test_setTakeBuffer() external {
        assertEq(IMidnightFacet.setTakeBuffer.selector, bytes4(keccak256("setTakeBuffer(address)")));
        assertEq(IMidnightFacet.takeBuffer.selector,    bytes4(keccak256("takeBuffer()")));

        assertEq(
            IMidnightFacet.MidnightTakeBufferSet.selector,
            keccak256("MidnightTakeBufferSet(address)")
        );

        address newBuffer = address(new MidnightTakeBuffer(midnight, controller.proxy()));

        assertEq(controller.takeBuffer(), takeBuffer);

        vm.record();

        vm.expectEmit(address(controller));
        emit IMidnightFacet.MidnightTakeBufferSet(newBuffer);

        vm.prank(admin);
        controller.setTakeBuffer(newBuffer);

        _assertReentrancyGuardWrittenToTwice(address(controller));

        assertEq(controller.takeBuffer(), newBuffer);
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
