// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IController }             from "../../../src/interfaces/IController.sol";
import { IEnumerableIntegrations } from "../../../src/interfaces/IEnumerableIntegrations.sol";
import { IRateLimits }             from "../../../src/interfaces/IRateLimits.sol";

import { IFacet } from "../../../src/facets/IFacet.sol";

import { BeaconConfig } from "../../../src/libraries/BeaconConfig.sol";

import { IMidnightController } from "../../../src/facets/midnight/IMidnightController.sol";
import { IMidnightFacet }      from "../../../src/facets/midnight/IMidnightFacet.sol";
import { MidnightFacet }       from "../../../src/facets/midnight/MidnightFacet.sol";
import { MidnightIdLib }       from "../../../src/facets/midnight/MidnightIdLib.sol";

import { CollateralParams, Market } from "../../../src/facets/midnight/MidnightInterfaces.sol";

import { Integration_TestBase } from "../TestBase.t.sol";

contract MidnightWiring_IntegrationTests is Integration_TestBase {

    bytes32 internal constant INTEGRATION = "MIDNIGHT_FACET";

    // Bumping this is the step that forces a new controller alias to be paired below.
    uint256 internal constant WIRE_COUNT = 20;

    address internal midnight = makeAddr("midnight");

    address internal controller;
    address internal facet;

    function setUp() external {
        controller = _deploy();
        facet      = address(new MidnightFacet(midnight));

        vm.prank(beaconAdmin);
        BeaconConfig.setMidnightIntegration(address(beacon), facet);

        bytes32[] memory integrationIds = new bytes32[](1);
        integrationIds[0] = INTEGRATION;

        vm.prank(admin);
        IController(payable(controller)).updateIntegrations(integrationIds);
    }

    function _expectedWires()
        internal
        pure
        returns (bytes4[] memory calls, bytes4[] memory delegates)
    {
        calls     = new bytes4[](WIRE_COUNT);
        delegates = new bytes4[](WIRE_COUNT);

        calls[0]     = IMidnightController.midnight_setMarketConfig.selector;
        delegates[0] = IMidnightFacet.setMarketConfig.selector;

        calls[1]     = IMidnightController.midnight_getMarketConfig.selector;
        delegates[1] = IMidnightFacet.getMarketConfig.selector;

        calls[2]     = IMidnightController.midnight_buy.selector;
        delegates[2] = IMidnightFacet.buy.selector;

        calls[3]     = IMidnightController.midnight_sell.selector;
        delegates[3] = IMidnightFacet.sell.selector;

        calls[4]     = IMidnightController.midnight_redeem.selector;
        delegates[4] = IMidnightFacet.redeem.selector;

        calls[5]     = IMidnightController.midnight_getBuyRateLimitKey.selector;
        delegates[5] = IMidnightFacet.getBuyRateLimitKey.selector;

        calls[6]     = IMidnightController.midnight_getSellRateLimitKey.selector;
        delegates[6] = IMidnightFacet.getSellRateLimitKey.selector;

        calls[7]     = IMidnightController.midnight_getRedeemRateLimitKey.selector;
        delegates[7] = IMidnightFacet.getRedeemRateLimitKey.selector;

        calls[8]     = IMidnightController.midnight_midnight.selector;
        delegates[8] = IMidnightFacet.midnight.selector;

        calls[9]     = IMidnightController.midnight_VERSION.selector;
        delegates[9] = IFacet.VERSION.selector;

        calls[10]     = IMidnightController.midnight_setMakeConfig.selector;
        delegates[10] = IMidnightFacet.setMakeConfig.selector;

        calls[11]     = IMidnightController.midnight_setDesignatedGroups.selector;
        delegates[11] = IMidnightFacet.setDesignatedGroups.selector;

        calls[12]     = IMidnightController.midnight_setRatifierAuthorization.selector;
        delegates[12] = IMidnightFacet.setRatifierAuthorization.selector;

        calls[13]     = IMidnightController.midnight_cancelOfferGroup.selector;
        delegates[13] = IMidnightFacet.cancelOfferGroup.selector;

        calls[14]     = IMidnightController.midnight_fundFill.selector;
        delegates[14] = IMidnightFacet.fundFill.selector;

        calls[15]     = IMidnightController.midnight_getMakeConfig.selector;
        delegates[15] = IMidnightFacet.getMakeConfig.selector;

        calls[16]     = IMidnightController.midnight_getDesignatedGroups.selector;
        delegates[16] = IMidnightFacet.getDesignatedGroups.selector;

        calls[17]     = IMidnightController.midnight_isCallbackAllowed.selector;
        delegates[17] = IMidnightFacet.isCallbackAllowed.selector;

        calls[18]     = IMidnightController.midnight_getStrategyBuyRateLimitKey.selector;
        delegates[18] = IMidnightFacet.getStrategyBuyRateLimitKey.selector;

        calls[19]     = IMidnightController.midnight_getStrategySellRateLimitKey.selector;
        delegates[19] = IMidnightFacet.getStrategySellRateLimitKey.selector;
    }

    // The periphery calls these three by selector, so they are pinned to literals, not derived.
    function test_midnightWiring_peripherySelectors() external view {
        assertEq(IMidnightController.midnight_fundFill.selector,            bytes4(0xfb9e2099));
        assertEq(IMidnightController.midnight_isCallbackAllowed.selector,   bytes4(0x5c0f4590));
        assertEq(IMidnightController.midnight_getDesignatedGroups.selector, bytes4(0x87d2a293));

        assertEq(
            beacon.getDispatch(bytes4(0xfb9e2099)).delegateSelector,
            IMidnightFacet.fundFill.selector
        );
        assertEq(
            beacon.getDispatch(bytes4(0x5c0f4590)).delegateSelector,
            IMidnightFacet.isCallbackAllowed.selector
        );
        assertEq(
            beacon.getDispatch(bytes4(0x87d2a293)).delegateSelector,
            IMidnightFacet.getDesignatedGroups.selector
        );
    }

    function test_midnightWiring_everyDeclaredPairIsInstalled() external view {
        ( bytes4[] memory calls, bytes4[] memory delegates ) = _expectedWires();

        IEnumerableIntegrations.Config memory config = beacon.getConfig(INTEGRATION);

        assertEq(config.facet,        facet);
        assertEq(config.wires.length, WIRE_COUNT);

        for (uint256 i; i < WIRE_COUNT; ++i) {
            IEnumerableIntegrations.Dispatch memory dispatch = beacon.getDispatch(calls[i]);

            assertEq(dispatch.facet,            facet);
            assertEq(dispatch.delegateSelector, delegates[i]);
        }
    }

    // buy/sell and the three key getters each share a signature with a sibling, so a swap compiles.
    function test_midnightWiring_selectorsAreDistinct() external view {
        IEnumerableIntegrations.Wire[] memory wires = beacon.getConfig(INTEGRATION).wires;

        assertEq(wires.length, WIRE_COUNT);

        for (uint256 i; i < wires.length; ++i) {
            for (uint256 j = i + 1; j < wires.length; ++j) {
                assertTrue(wires[i].callSelector     != wires[j].callSelector);
                assertTrue(wires[i].delegateSelector != wires[j].delegateSelector);
            }
        }
    }

    // The alias is the whole access-control story, so the bare facet selector must not dispatch.
    function test_midnightWiring_rawFacetSelectorsAreNotDispatched() external {
        ( , bytes4[] memory delegates ) = _expectedWires();

        for (uint256 i; i < WIRE_COUNT; ++i) {
            assertEq(beacon.getDispatch(delegates[i]).facet, address(0));
        }

        ( bool ok, ) = controller.call(abi.encodeWithSelector(IMidnightFacet.midnight.selector));

        assertFalse(ok);
    }

    function test_midnightWiring_aliasesDispatchThroughTheController() external view {
        assertEq(IMidnightController(controller).midnight_VERSION(),  "1.0.0");
        assertEq(IMidnightController(controller).midnight_midnight(), midnight);
    }

    // Midnight staticcalls isRatified, so a periphery ratifier can only read policy from here if
    // the dispatch itself is static-safe.
    function test_midnightWiring_policyViewsAnswerAStaticCall() external {
        Market memory market = Market({
            chainId          : block.chainid,
            midnight         : midnight,
            loanToken        : makeAddr("loanToken"),
            collateralParams : new CollateralParams[](0),
            maturity         : block.timestamp + 180 days,
            rcfThreshold     : 0,
            enterGate        : address(0),
            liquidatorGate   : address(0)
        });

        bytes32 marketId  = MidnightIdLib.toId(market);
        bytes32 buyGroup  = keccak256("buy");
        bytes32 sellGroup = keccak256("sell");

        address callback = makeAddr("callback");

        IMidnightController alias_ = IMidnightController(controller);
        IRateLimits         limits = IRateLimits(IController(payable(controller)).rateLimits());

        bytes32 strategyKey = alias_.midnight_getStrategyBuyRateLimitKey(callback, marketId);
        bytes32 marketKey   = alias_.midnight_getBuyRateLimitKey(marketId);

        // setMakeConfig reads the market back from the venue, so the venue needs code and an answer.
        vm.etch(midnight, hex"00");
        vm.mockCall(
            midnight,
            abi.encodeWithSignature("toMarket(bytes32)", marketId),
            abi.encode(market)
        );

        vm.startPrank(admin);
        alias_.midnight_setMarketConfig(marketId, 1, 1, 0, 1, 0, 0);
        alias_.midnight_setMakeConfig(market, 1);
        alias_.midnight_setDesignatedGroups(marketId, buyGroup, sellGroup);
        limits.setRateLimitData(strategyKey, 1, 0);
        limits.setRateLimitData(marketKey,   1, 0);
        vm.stopPrank();

        ( bool ok, bytes memory data ) = controller.staticcall(
            abi.encodeCall(IMidnightController.midnight_getDesignatedGroups, (marketId))
        );

        assertTrue(ok);

        IMidnightFacet.DesignatedGroups memory groups =
            abi.decode(data, (IMidnightFacet.DesignatedGroups));

        assertEq(groups.buyGroup,  buyGroup);
        assertEq(groups.sellGroup, sellGroup);

        ( ok, data ) = controller.staticcall(
            abi.encodeCall(IMidnightController.midnight_isCallbackAllowed, (marketId, callback, true))
        );

        assertTrue(ok);
        assertTrue(abi.decode(data, (bool)));
    }

}
