// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ReentrancyGuard } from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { IMidnightFacet }          from "../../../src/facets/midnight/IMidnightFacet.sol";
import { IController }             from "../../../src/interfaces/IController.sol";
import { IEnumerableIntegrations } from "../../../src/interfaces/IEnumerableIntegrations.sol";
import { IRateLimits }             from "../../../src/interfaces/IRateLimits.sol";

import { makeBytes32Key } from "../../../src/libraries/RateLimitHelpers.sol";

import { MidnightFacet } from "../../../src/facets/midnight/MidnightFacet.sol";
import { MidnightIdLib } from "../../../src/facets/midnight/MidnightIdLib.sol";
import { MAX_TICK, MidnightTickLib } from "../../../src/facets/midnight/MidnightTickLib.sol";
import { MidnightUtils } from "../../../src/facets/midnight/MidnightUtils.sol";

import {
    CollateralParams,
    Market,
    Offer
} from "../../../src/facets/midnight/MidnightInterfaces.sol";

import { MockERC20Decimals } from "../../mocks/Mocks.sol";

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

    function setMakeConfig(Market calldata market, uint256 maxOfferSize) external;

    function setDesignatedGroups(bytes32 marketId, bytes32 buyGroup, bytes32 sellGroup) external;

    function setRatifierAuthorization(address ratifier, bool authorized) external;

    function cancelOfferGroup(bytes32 group) external;

    function fundFill(
        bytes32 marketId,
        bool    buy,
        uint256 assets,
        uint256 units,
        uint256 pendingFee
    ) external;

    function getMarketConfig(bytes32 marketId)
        external
        view
        returns (IMidnightFacet.MarketConfig memory);

    function getMakeConfig(bytes32 marketId)
        external
        view
        returns (IMidnightFacet.MakeConfig memory);

    function getDesignatedGroups(bytes32 marketId)
        external
        view
        returns (IMidnightFacet.DesignatedGroups memory);

    function getBuyRateLimitKey(bytes32 marketId) external pure returns (bytes32);

    function getRedeemRateLimitKey(bytes32 marketId) external pure returns (bytes32);

    function getSellRateLimitKey(bytes32 marketId) external pure returns (bytes32);

    function getStrategyBuyRateLimitKey(address strategy, bytes32 marketId)
        external
        pure
        returns (bytes32);

    function getStrategySellRateLimitKey(address strategy, bytes32 marketId)
        external
        pure
        returns (bytes32);

    function isCallbackAllowed(bytes32 marketId, address callback, bool buy)
        external
        view
        returns (bool);

    function midnight() external view returns (address);

    function updateIntegrations(bytes32[] memory integrationIds) external;

}

interface IMidnightMock {

    function toMarket(bytes32 id) external view returns (Market memory);

    function lossFactor(bytes32 id) external view returns (uint128);

    function continuousFee(bytes32 id) external view returns (uint32);

    function debt(bytes32 id, address user) external view returns (uint128);

    function updatePositionView(Market memory market, bytes32 id, address user)
        external
        view
        returns (uint128 credit, uint128 pendingFee, uint128 accruedFee);

    function setConsumed(bytes32 group, uint128 amount, address onBehalf) external;

    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external;

}

interface IERC20Mock {

    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

}

// Midnight operations the proxy must never be able to perform. Declared with the real argument
// types so the selectors match upstream's, struct expansion included.
interface IMidnightForbidden {

    function supplyCollateral(
        Market memory market,
        uint256       collateralIndex,
        uint256       assets,
        address       onBehalf
    ) external;

    function withdrawCollateral(
        Market memory market,
        uint256       collateralIndex,
        uint256       assets,
        address       onBehalf,
        address       receiver
    ) external;

    function repay(
        Market memory market,
        uint256       units,
        address       onBehalf,
        address       callback,
        bytes  memory data
    ) external;

    function liquidate(
        Market memory market,
        uint256       collateralIndex,
        uint256       seizedAssets,
        uint256       repaidUnits,
        address       borrower,
        bool          postMaturityMode,
        address       receiver,
        address       callback,
        bytes  memory data
    ) external returns (uint256, uint256);

    function flashLoan(
        address[] memory tokens,
        uint256[] memory assets,
        address          callback,
        bytes     memory data
    ) external;

    function multicall(bytes[] memory calls) external;

    function borrow(Market memory market, uint256 units, address onBehalf, address receiver)
        external;

}

// The one call the facet does make through the proxy, as a control for the scan below.
interface IMidnightExpected {

    function take(
        Offer  memory offer,
        bytes  memory ratifierData,
        uint256       units,
        address       taker,
        address       receiverIfTakerIsSeller,
        address       takerCallback,
        bytes  memory takerCallbackData
    ) external returns (uint256, uint256);

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

    bytes32 internal constant BUY_GROUP  = keccak256("buy-group");
    bytes32 internal constant SELL_GROUP = keccak256("sell-group");

    uint256 internal constant MAX_OFFER_SIZE = 1_000_000e6;
    uint256 internal constant FILL_UNITS     = 1_000e6;
    uint256 internal constant PROXY_BALANCE  = 10_000_000e6;

    address internal midnight = makeAddr("midnight");
    address internal ratifier = makeAddr("ratifier");
    address internal strategy = makeAddr("strategy");

    address internal loanToken;

    IControllerLike internal controller;
    IRateLimits     internal rateLimits;

    address internal proxy;

    // Held as fields, not a struct: the legacy pipeline cannot copy its dynamic array to storage.
    address internal marketMidnight;
    uint256 internal marketMaturity;

    address internal facetAddress;

    function setUp() external {
        controller = IControllerLike(_deploy());

        rateLimits = IRateLimits(IController(payable(address(controller))).rateLimits());
        proxy      = IController(payable(address(controller))).proxy();

        loanToken = address(new MockERC20Decimals("Loan Token", "LOAN", 6));

        deal(loanToken, proxy, PROXY_BALANCE);

        marketMidnight = midnight;
        marketMaturity = block.timestamp + 180 days;

        // OZ's functionCall rejects a void call to a codeless target, so the venue needs code.
        vm.etch(midnight, hex"00");

        address facet = address(new MidnightFacet(midnight));

        facetAddress = facet;

        vm.label(facet, "MidnightFacet");

        IEnumerableIntegrations.Wire[] memory wires = new IEnumerableIntegrations.Wire[](16);

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
            IControllerLike.setMakeConfig.selector,
            IMidnightFacet.setMakeConfig.selector
        );

        wires[7] = IEnumerableIntegrations.Wire(
            IControllerLike.setDesignatedGroups.selector,
            IMidnightFacet.setDesignatedGroups.selector
        );

        wires[8] = IEnumerableIntegrations.Wire(
            IControllerLike.setRatifierAuthorization.selector,
            IMidnightFacet.setRatifierAuthorization.selector
        );

        wires[9] = IEnumerableIntegrations.Wire(
            IControllerLike.cancelOfferGroup.selector,
            IMidnightFacet.cancelOfferGroup.selector
        );

        wires[10] = IEnumerableIntegrations.Wire(
            IControllerLike.fundFill.selector,
            IMidnightFacet.fundFill.selector
        );

        wires[11] = IEnumerableIntegrations.Wire(
            IControllerLike.getMakeConfig.selector,
            IMidnightFacet.getMakeConfig.selector
        );

        wires[12] = IEnumerableIntegrations.Wire(
            IControllerLike.getDesignatedGroups.selector,
            IMidnightFacet.getDesignatedGroups.selector
        );

        wires[13] = IEnumerableIntegrations.Wire(
            IControllerLike.isCallbackAllowed.selector,
            IMidnightFacet.isCallbackAllowed.selector
        );

        wires[14] = IEnumerableIntegrations.Wire(
            IControllerLike.getStrategyBuyRateLimitKey.selector,
            IMidnightFacet.getStrategyBuyRateLimitKey.selector
        );

        wires[15] = IEnumerableIntegrations.Wire(
            IControllerLike.getStrategySellRateLimitKey.selector,
            IMidnightFacet.getStrategySellRateLimitKey.selector
        );

        IEnumerableIntegrations.Config memory config = IEnumerableIntegrations.Config(facet, wires);

        vm.prank(beaconAdmin);
        beacon.setIntegration("MIDNIGHT_FACET", config);

        bytes32[] memory integrationIds = new bytes32[](1);
        integrationIds[0] = "MIDNIGHT_FACET";

        vm.prank(admin);
        controller.updateIntegrations(integrationIds);
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

    /**********************************************************************************************/
    /*** Make-side Helpers                                                                      ***/
    /**********************************************************************************************/

    function _market() internal view returns (Market memory) {
        return Market({
            chainId          : block.chainid,
            midnight         : marketMidnight,
            loanToken        : loanToken,
            collateralParams : new CollateralParams[](0),
            maturity         : marketMaturity,
            rcfThreshold     : 0,
            enterGate        : address(0),
            liquidatorGate   : address(0)
        });
    }

    function _marketId() internal view returns (bytes32) {
        return MidnightIdLib.toId(_market());
    }

    function _mockMarketExists() internal {
        vm.mockCall(
            midnight,
            abi.encodeCall(IMidnightMock.toMarket, (_marketId())),
            abi.encode(_market())
        );

        _mockContinuousFee(CONTINUOUS_FEE);
        _mockDebt(0);
        _mockPosition(0, 0);
    }

    function _mockContinuousFee(uint16 annualCbps) internal {
        vm.mockCall(
            midnight,
            abi.encodeCall(IMidnightMock.continuousFee, (_marketId())),
            abi.encode(MidnightUtils.continuousFeePerSecond(annualCbps))
        );
    }

    function _mockDebt(uint128 value) internal {
        vm.mockCall(
            midnight,
            abi.encodeCall(IMidnightMock.debt, (_marketId(), proxy)),
            abi.encode(value)
        );
    }

    // The fee the proxy's remaining credit carries, which is what caps a reported exit fee.
    function _mockPosition(uint128 credit, uint128 pendingFee) internal {
        vm.mockCall(
            midnight,
            abi.encodeCall(IMidnightMock.updatePositionView, (_market(), _marketId(), proxy)),
            abi.encode(credit, pendingFee, uint128(0))
        );
    }

    function _onboardAndEnableMake(uint128 maxLossFactor) internal {
        _mockMarketExists();

        vm.startPrank(admin);
        controller.setMarketConfig(
            _marketId(),
            TICK_99,
            TICK_98,
            MIN_BUY_YIELD,
            MAX_SELL_YIELD,
            CONTINUOUS_FEE,
            maxLossFactor
        );
        controller.setMakeConfig(_market(), MAX_OFFER_SIZE);
        vm.stopPrank();
    }

    // Both strategy keys and the market buy key; the market sell key is set per test.
    function _onboardStrategy(uint256 maxAmount) internal {
        _setStrategyBuyLimit(strategy, maxAmount);
        _setStrategySellLimit(strategy, maxAmount);
        _setBuyLimit(maxAmount);
    }

    // Key resolved before the prank: an external call in the argument list would consume it.
    function _setStrategyBuyLimit(address strategy_, uint256 maxAmount) internal {
        bytes32 key = controller.getStrategyBuyRateLimitKey(strategy_, _marketId());

        vm.prank(admin);
        rateLimits.setRateLimitData(key, maxAmount, 0);
    }

    function _setStrategySellLimit(address strategy_, uint256 maxAmount) internal {
        bytes32 key = controller.getStrategySellRateLimitKey(strategy_, _marketId());

        vm.prank(admin);
        rateLimits.setRateLimitData(key, maxAmount, 0);
    }

    function _setBuyLimit(uint256 maxAmount) internal {
        bytes32 buyKey = controller.getBuyRateLimitKey(_marketId());

        vm.prank(admin);
        rateLimits.setRateLimitData(buyKey, maxAmount, 0);
    }

    function _setSellLimit(uint256 maxAmount) internal {
        bytes32 sellKey = controller.getSellRateLimitKey(_marketId());

        vm.prank(admin);
        rateLimits.setRateLimitData(sellKey, maxAmount, 0);
    }

    function _mockLossFactor(uint128 value) internal {
        vm.mockCall(
            midnight,
            abi.encodeCall(IMidnightMock.lossFactor, (_marketId())),
            abi.encode(value)
        );
    }

    // Mirrors fundFill's bound from config alone, so a live market rate cannot satisfy it.
    function _maxFillPrice() internal view returns (uint256 bound) {
        bound = MidnightTickLib.tickToPrice(TICK_99);

        uint256 yieldBound = MidnightUtils.maxBuyPrice(
            MIN_BUY_YIELD,
            marketMaturity - block.timestamp,
            MidnightUtils.continuousFeePerSecond(CONTINUOUS_FEE)
        );

        if (yieldBound < bound) bound = yieldBound;
    }

    function _honestAssets(uint256 units) internal view returns (uint256) {
        return units * _maxFillPrice() / MidnightUtils.WAD;
    }

    // Same shape on the exit side, and on the unencumbered basis a ratifier can commit to.
    function _minFillPrice() internal view returns (uint256 bound) {
        bound = MidnightTickLib.tickToPrice(TICK_98);

        uint256 yieldBound = MidnightUtils.minSellPrice(
            MAX_SELL_YIELD,
            marketMaturity - block.timestamp,
            MidnightUtils.WAD,
            0
        );

        if (yieldBound > bound) bound = yieldBound;
    }

    // Rounded up, matching both Midnight's mulDivUp on a maker sell and fundFill's exact bound.
    function _honestSellAssets(uint256 units) internal view returns (uint256) {
        uint256 numerator = units * _minFillPrice();

        return (numerator + MidnightUtils.WAD - 1) / MidnightUtils.WAD;
    }

    function _containsSelector(bytes memory code, bytes4 selector) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= code.length; ++i) {
            if (
                code[i]     == selector[0] &&
                code[i + 1] == selector[1] &&
                code[i + 2] == selector[2] &&
                code[i + 3] == selector[3]
            ) return true;
        }
        return false;
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

    function test_setMarketConfig_preservesMakeConfig() external {
        _onboardAndEnableMake(0);

        vm.prank(admin);
        controller.setMarketConfig(
            _marketId(), TICK_98, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, 0, 0
        );

        IMidnightFacet.MakeConfig memory config = controller.getMakeConfig(_marketId());

        assertEq(config.maxOfferSize, MAX_OFFER_SIZE);
        assertEq(config.maturity,     uint64(marketMaturity));
        assertEq(config.loanToken,    loanToken);
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

    function test_getStrategyBuyRateLimitKey() external view {
        assertEq(
            controller.getStrategyBuyRateLimitKey(strategy, MARKET_ID),
            keccak256(abi.encode(keccak256("LIMIT_MIDNIGHT_STRATEGY_BUY"), strategy, MARKET_ID))
        );
    }

    function test_getStrategySellRateLimitKey() external view {
        assertEq(
            controller.getStrategySellRateLimitKey(strategy, MARKET_ID),
            keccak256(abi.encode(keccak256("LIMIT_MIDNIGHT_STRATEGY_SELL"), strategy, MARKET_ID))
        );
    }

    /**********************************************************************************************/
    /*** Forbidden Operation Tests                                                              ***/
    /**********************************************************************************************/

    // Authorizing the ratifier hands it the proxy's whole Midnight position, since isAuthorized is
    // one flat mapping. Nothing upstream narrows it, so the block has to be that no contract of
    // ours can encode these calls at all.
    function test_facetCannotEncodeForbiddenOperations() external view {
        bytes memory code = facetAddress.code;

        // Control: the scan finds a selector the facet really does use.
        assertTrue(_containsSelector(code, IMidnightExpected.take.selector));

        assertFalse(_containsSelector(code, IMidnightForbidden.supplyCollateral.selector));
        assertFalse(_containsSelector(code, IMidnightForbidden.withdrawCollateral.selector));
        assertFalse(_containsSelector(code, IMidnightForbidden.repay.selector));
        assertFalse(_containsSelector(code, IMidnightForbidden.liquidate.selector));
        assertFalse(_containsSelector(code, IMidnightForbidden.flashLoan.selector));
        assertFalse(_containsSelector(code, IMidnightForbidden.multicall.selector));
        assertFalse(_containsSelector(code, IMidnightForbidden.borrow.selector));
    }

    // Collateral operations are unreachable by name as well as by selector: the controller exposes
    // no entry point for them, so a spell cannot route one through the diamond.
    function test_controllerExposesNoCollateralEntryPoint() external {
        vm.expectRevert();
        (bool ok, ) = address(controller).call(
            abi.encodeWithSelector(IMidnightForbidden.supplyCollateral.selector)
        );
        ok;

        vm.expectRevert();
        (ok, ) = address(controller).call(
            abi.encodeWithSelector(IMidnightForbidden.withdrawCollateral.selector)
        );
        ok;
    }

    /**********************************************************************************************/
    /*** setMakeConfig Tests                                                                    ***/
    /**********************************************************************************************/

    function test_setMakeConfig_reentrancy() external {
        _setEntered(address(controller));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        controller.setMakeConfig(_market(), MAX_OFFER_SIZE);
    }

    function test_setMakeConfig_unauthorizedAccount() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        controller.setMakeConfig(_market(), MAX_OFFER_SIZE);
    }

    function test_setMakeConfig_invalidMidnight() external {
        marketMidnight = makeAddr("otherMidnight");

        vm.expectRevert("MidnightFacet/invalid-midnight");
        vm.prank(admin);
        controller.setMakeConfig(_market(), MAX_OFFER_SIZE);
    }

    function test_setMakeConfig_marketNotOnboarded() external {
        _mockMarketExists();

        vm.expectRevert("MidnightFacet/market-not-onboarded");
        vm.prank(admin);
        controller.setMakeConfig(_market(), MAX_OFFER_SIZE);
    }

    function test_setMakeConfig_maturityOob() external {
        marketMaturity = uint256(type(uint64).max) + 1;

        vm.prank(admin);
        controller.setMarketConfig(
            _marketId(), TICK_99, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );

        vm.expectRevert("MidnightFacet/maturity-oob");
        vm.prank(admin);
        controller.setMakeConfig(_market(), MAX_OFFER_SIZE);
    }

    function test_setMakeConfig_maxOfferSizeOob() external {
        vm.prank(admin);
        controller.setMarketConfig(
            _marketId(), TICK_99, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );

        vm.expectRevert("MidnightFacet/max-offer-size-oob");
        vm.prank(admin);
        controller.setMakeConfig(_market(), uint256(type(uint128).max) + 1);

        _mockMarketExists();

        vm.prank(admin);
        controller.setMakeConfig(_market(), uint256(type(uint128).max));

        assertEq(
            controller.getMakeConfig(_marketId()).maxOfferSize,
            uint256(type(uint128).max)
        );
    }

    function test_setMakeConfig_marketNotCreated() external {
        vm.prank(admin);
        controller.setMarketConfig(
            _marketId(), TICK_99, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );

        vm.mockCallRevert(
            midnight,
            abi.encodeCall(IMidnightMock.toMarket, (_marketId())),
            abi.encodeWithSignature("MarketNotCreated()")
        );

        vm.expectRevert(abi.encodeWithSignature("MarketNotCreated()"));
        vm.prank(admin);
        controller.setMakeConfig(_market(), MAX_OFFER_SIZE);
    }

    // The id commits to the maturity, so only a venue contradicting its own storage trips this.
    function test_setMakeConfig_marketMismatch() external {
        vm.prank(admin);
        controller.setMarketConfig(
            _marketId(), TICK_99, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );

        Market memory lying = _market();

        lying.maturity = marketMaturity + 1;

        vm.mockCall(
            midnight,
            abi.encodeCall(IMidnightMock.toMarket, (_marketId())),
            abi.encode(lying)
        );

        vm.expectRevert("MidnightFacet/market-mismatch");
        vm.prank(admin);
        controller.setMakeConfig(_market(), MAX_OFFER_SIZE);
    }

    function test_setMakeConfig() external {
        _mockMarketExists();

        vm.prank(admin);
        controller.setMarketConfig(
            _marketId(), TICK_99, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );

        IMidnightFacet.MakeConfig memory before = controller.getMakeConfig(_marketId());

        assertEq(before.maxOfferSize, 0);
        assertEq(before.maturity,     0);
        assertEq(before.loanToken,    address(0));

        vm.record();

        vm.expectEmit(address(controller));
        emit IMidnightFacet.MidnightMakeConfigSet(
            _marketId(),
            MAX_OFFER_SIZE,
            uint64(marketMaturity),
            loanToken
        );

        vm.prank(admin);
        controller.setMakeConfig(_market(), MAX_OFFER_SIZE);

        _assertReentrancyGuardWrittenToTwice(address(controller));

        IMidnightFacet.MakeConfig memory config = controller.getMakeConfig(_marketId());

        assertEq(config.maxOfferSize, MAX_OFFER_SIZE);
        assertEq(config.maturity,     uint64(marketMaturity));
        assertEq(config.loanToken,    loanToken);

        vm.prank(admin);
        controller.setMakeConfig(_market(), 0);

        config = controller.getMakeConfig(_marketId());

        assertEq(config.maxOfferSize, 0);
        assertEq(config.loanToken,    loanToken);
    }

    /**********************************************************************************************/
    /*** setDesignatedGroups Tests                                                              ***/
    /**********************************************************************************************/

    function test_setDesignatedGroups_reentrancy() external {
        _setEntered(address(controller));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        controller.setDesignatedGroups(MARKET_ID, BUY_GROUP, SELL_GROUP);
    }

    function test_setDesignatedGroups_unauthorizedAccount() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        controller.setDesignatedGroups(MARKET_ID, BUY_GROUP, SELL_GROUP);
    }

    function test_setDesignatedGroups_groupsNotDistinct() external {
        vm.expectRevert("MidnightFacet/groups-not-distinct");
        vm.prank(admin);
        controller.setDesignatedGroups(MARKET_ID, BUY_GROUP, BUY_GROUP);

        // Both zero is the uninitialised state, not a collision.
        vm.prank(admin);
        controller.setDesignatedGroups(MARKET_ID, 0, 0);
    }

    function test_setDesignatedGroups() external {
        vm.record();

        vm.expectEmit(address(controller));
        emit IMidnightFacet.MidnightDesignatedGroupsSet(MARKET_ID, BUY_GROUP, SELL_GROUP);

        vm.prank(admin);
        controller.setDesignatedGroups(MARKET_ID, BUY_GROUP, SELL_GROUP);

        _assertReentrancyGuardWrittenToTwice(address(controller));

        IMidnightFacet.DesignatedGroups memory groups =
            controller.getDesignatedGroups(MARKET_ID);

        assertEq(groups.buyGroup,  BUY_GROUP);
        assertEq(groups.sellGroup, SELL_GROUP);
    }

    /**********************************************************************************************/
    /*** setRatifierAuthorization Tests                                                         ***/
    /**********************************************************************************************/

    function test_setRatifierAuthorization_reentrancy() external {
        _setEntered(address(controller));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        controller.setRatifierAuthorization(ratifier, true);
    }

    function test_setRatifierAuthorization_unauthorizedAccount() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        controller.setRatifierAuthorization(ratifier, true);
    }

    function test_setRatifierAuthorization_zeroRatifier() external {
        vm.expectRevert("MidnightFacet/zero-ratifier");
        vm.prank(admin);
        controller.setRatifierAuthorization(address(0), true);
    }

    function test_setRatifierAuthorization() external {
        vm.record();

        vm.expectCall(
            midnight,
            abi.encodeCall(IMidnightMock.setIsAuthorized, (ratifier, true, proxy))
        );

        vm.expectEmit(address(controller));
        emit IMidnightFacet.MidnightRatifierAuthorizationSet(ratifier, true);

        vm.prank(admin);
        controller.setRatifierAuthorization(ratifier, true);

        _assertReentrancyGuardWrittenToTwice(address(controller));

        vm.expectCall(
            midnight,
            abi.encodeCall(IMidnightMock.setIsAuthorized, (ratifier, false, proxy))
        );

        vm.prank(admin);
        controller.setRatifierAuthorization(ratifier, false);
    }

    /**********************************************************************************************/
    /*** cancelOfferGroup Tests                                                                 ***/
    /**********************************************************************************************/

    function test_cancelOfferGroup_reentrancy() external {
        _setEntered(address(controller));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        controller.cancelOfferGroup(BUY_GROUP);
    }

    function test_cancelOfferGroup_unauthorizedAccount() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            ALLOCATOR_ROLE
        ));
        controller.cancelOfferGroup(BUY_GROUP);
    }

    function test_cancelOfferGroup() external {
        vm.record();

        vm.expectCall(
            midnight,
            abi.encodeCall(
                IMidnightMock.setConsumed,
                (BUY_GROUP, type(uint128).max, proxy)
            )
        );

        vm.expectEmit(address(controller));
        emit IMidnightFacet.MidnightOfferGroupCancelled(BUY_GROUP);

        vm.prank(allocator);
        controller.cancelOfferGroup(BUY_GROUP);

        _assertReentrancyGuardWrittenToTwice(address(controller));
    }

    /**********************************************************************************************/
    /*** fundFill Tests                                                                         ***/
    /**********************************************************************************************/

    function test_fundFill_reentrancy() external {
        _setEntered(address(controller));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        controller.fundFill(MARKET_ID, true, 1, 1, 0);
    }

    // No role gates fundFill; the caller's own strategy key is the whole authorization.
    function test_fundFill_zeroStrategyBuyKey() external {
        _onboardAndEnableMake(0);
        _setBuyLimit(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        uint256 assets = _honestAssets(FILL_UNITS);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        _setStrategyBuyLimit(strategy, MAX_OFFER_SIZE);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(unauthorized);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);
    }

    function test_fundFill_sell_zeroStrategySellKey() external {
        _onboardAndEnableMake(0);
        _setSellLimit(MAX_OFFER_SIZE);

        uint256 assets = _honestSellAssets(FILL_UNITS);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, assets, FILL_UNITS, 0);

        _setStrategySellLimit(strategy, MAX_OFFER_SIZE);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, assets, FILL_UNITS, 0);
    }

    // Each direction is its own onboarding, so a strategy keyed for entries cannot report exits.
    function test_fundFill_strategyKeyIsDirectional() external {
        _onboardAndEnableMake(0);
        _setBuyLimit(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        _setStrategyBuyLimit(strategy, MAX_OFFER_SIZE);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, _honestSellAssets(FILL_UNITS), FILL_UNITS, 0);

        _setStrategyBuyLimit(strategy, 0);
        _setStrategySellLimit(strategy, MAX_OFFER_SIZE);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, _honestAssets(FILL_UNITS), FILL_UNITS, 0);
    }

    // Offboarding is zeroing the key, and it has to bite on fills of offers already published.
    function test_fundFill_strategyOffboarded() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, _honestAssets(FILL_UNITS), FILL_UNITS, 0);

        _setStrategyBuyLimit(strategy, 0);
        _setStrategySellLimit(strategy, 0);

        assertEq(controller.isCallbackAllowed(_marketId(), strategy, true),  false);
        assertEq(controller.isCallbackAllowed(_marketId(), strategy, false), false);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, _honestAssets(FILL_UNITS), FILL_UNITS, 0);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, _honestSellAssets(FILL_UNITS), FILL_UNITS, 0);
    }

    // With the market key unset, only a strategy-first debit can fail on the strategy's capacity.
    function test_fundFill_debitsStrategyKeyFirst() external {
        _onboardAndEnableMake(0);
        _mockLossFactor(0);

        uint256 buyAssets  = _honestAssets(FILL_UNITS);
        uint256 sellAssets = _honestSellAssets(FILL_UNITS);

        _setStrategyBuyLimit(strategy, buyAssets - 1);
        _setStrategySellLimit(strategy, sellAssets - 1);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, buyAssets, FILL_UNITS, 0);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, sellAssets, FILL_UNITS, 0);
    }

    function test_fundFill_zeroBuyKey() external {
        _onboardAndEnableMake(0);
        _setStrategyBuyLimit(strategy, MAX_OFFER_SIZE);
        _mockLossFactor(0);

        uint256 assets = _honestAssets(FILL_UNITS);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        assertEq(IERC20Mock(loanToken).balanceOf(proxy),    PROXY_BALANCE);
        assertEq(IERC20Mock(loanToken).balanceOf(strategy), 0);
    }

    function test_fundFill_sell_zeroSellKey() external {
        _onboardAndEnableMake(0);
        _setStrategySellLimit(strategy, MAX_OFFER_SIZE);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, _honestSellAssets(FILL_UNITS), FILL_UNITS, 0);
    }

    function test_fundFill_makeNotEnabled() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);

        vm.prank(admin);
        controller.setMakeConfig(_market(), 0);

        vm.expectRevert("MidnightFacet/make-not-enabled");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, _honestAssets(FILL_UNITS), FILL_UNITS, 0);
    }

    // Both guards sit above the direction branch, so neither leg can report nothing.
    function test_fundFill_zeroAmounts() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);

        vm.expectRevert("MidnightFacet/zero-assets");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, 0, FILL_UNITS, 0);

        vm.expectRevert("MidnightFacet/zero-assets");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, 0, FILL_UNITS, 0);

        vm.expectRevert("MidnightFacet/zero-units");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, _honestAssets(FILL_UNITS), 0, 0);

        vm.expectRevert("MidnightFacet/zero-units");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, _honestSellAssets(FILL_UNITS), 0, 0);
    }

    function test_fundFill_lossFactorTooHighBoundary() external {
        _onboardAndEnableMake(1);
        _onboardStrategy(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(FILL_UNITS);

        _mockLossFactor(2);

        vm.expectRevert("MidnightFacet/loss-factor-too-high");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        _mockLossFactor(1);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);
    }

    // A slashed market is exactly when an exit matters most, so the loss factor cannot gate it.
    function test_fundFill_sell_ignoresLossFactor() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);

        _mockLossFactor(type(uint128).max);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, _honestSellAssets(FILL_UNITS), FILL_UNITS, 0);
    }

    function test_fundFill_fillPriceTooHighBoundary() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        uint256 honest = _honestAssets(FILL_UNITS);

        vm.expectRevert("MidnightFacet/fill-price-too-high");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, honest + 1, FILL_UNITS, 0);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, honest, FILL_UNITS, 0);
    }

    function test_fundFill_sell_fillPriceTooLowBoundary() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);

        uint256 honest = _honestSellAssets(FILL_UNITS);

        vm.expectRevert("MidnightFacet/fill-price-too-low");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, honest - 1, FILL_UNITS, 0);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, honest, FILL_UNITS, 0);
    }

    // With the tick floor priced near zero the exit yield is the only thing left holding.
    function test_fundFill_sell_yieldFloorBinds() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);

        vm.prank(admin);
        controller.setMarketConfig(
            _marketId(), TICK_99, 1, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );

        uint256 floorPrice = MidnightUtils.minSellPrice(
            MAX_SELL_YIELD,
            marketMaturity - block.timestamp,
            MidnightUtils.WAD,
            0
        );

        assertGt(floorPrice, MidnightTickLib.tickToPrice(1));

        uint256 honest =
            (FILL_UNITS * floorPrice + MidnightUtils.WAD - 1) / MidnightUtils.WAD;

        vm.expectRevert("MidnightFacet/fill-price-too-low");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, honest - 1, FILL_UNITS, 0);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, honest, FILL_UNITS, 0);
    }

    function test_fundFill_continuousFeeTooHighBoundary() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        uint256 assets = _honestAssets(FILL_UNITS);

        // One wei per second above the configured ceiling, which is what the entry bound assumes.
        vm.mockCall(
            midnight,
            abi.encodeCall(IMidnightMock.continuousFee, (_marketId())),
            abi.encode(MidnightUtils.continuousFeePerSecond(CONTINUOUS_FEE) + 1)
        );

        vm.expectRevert("MidnightFacet/continuous-fee-too-high");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        _mockContinuousFee(CONTINUOUS_FEE);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);
    }

    // An exit is a report, not a transfer, so the live fee has no bearing on what it may accept.
    function test_fundFill_sell_ignoresContinuousFee() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);

        vm.mockCall(
            midnight,
            abi.encodeCall(IMidnightMock.continuousFee, (_marketId())),
            abi.encode(type(uint32).max)
        );

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, _honestSellAssets(FILL_UNITS), FILL_UNITS, 0);
    }

    function test_fundFill_sell_openedDebt() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);

        _mockDebt(1);

        vm.expectRevert("MidnightFacet/debt-not-zero");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, _honestSellAssets(FILL_UNITS), FILL_UNITS, 0);

        _mockDebt(0);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, _honestSellAssets(FILL_UNITS), FILL_UNITS, 0);
    }

    // A debt-free entry cannot be what the guard is reading, or it would pass on an exit too.
    function test_fundFill_ignoresDebtOnEntry() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        _mockDebt(1);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, _honestAssets(FILL_UNITS), FILL_UNITS, 0);
    }

    // The reported fee only ever tightens the floor, so an honest report of zero is the loosest.
    function test_fundFill_sell_reportedFeeOnlyTightens() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);

        // Lower the tick floor out of the way so the yield rail is what the fee moves.
        vm.prank(admin);
        controller.setMarketConfig(
            _marketId(), TICK_99, 1, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );

        uint256 unencumbered = MidnightUtils.minSellPrice(
            MAX_SELL_YIELD,
            marketMaturity - block.timestamp,
            MidnightUtils.WAD,
            0
        );

        uint256 honest = (FILL_UNITS * unencumbered + MidnightUtils.WAD - 1) / MidnightUtils.WAD;

        // The position carries half a unit of fee per unit, but the fill reports only a quarter.
        _mockPosition(uint128(FILL_UNITS), uint128(FILL_UNITS / 2));

        uint256 relieved = MidnightUtils.minSellPrice(
            MAX_SELL_YIELD,
            marketMaturity - block.timestamp,
            MidnightUtils.WAD,
            MidnightUtils.WAD / 4
        );

        uint256 corroborated = MidnightUtils.minSellPrice(
            MAX_SELL_YIELD,
            marketMaturity - block.timestamp,
            MidnightUtils.WAD,
            MidnightUtils.WAD / 2
        );

        assertLt(relieved,     unencumbered);
        assertLt(corroborated, relieved);

        uint256 floorWithRelief =
            (FILL_UNITS * relieved + MidnightUtils.WAD - 1) / MidnightUtils.WAD;

        assertLt(floorWithRelief, honest);

        // Below the quarter the fill reported, even though the venue would corroborate a half.
        vm.expectRevert("MidnightFacet/fill-price-too-low");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, floorWithRelief - 1, FILL_UNITS, FILL_UNITS / 4);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, floorWithRelief, FILL_UNITS, FILL_UNITS / 4);
    }

    // Overstating the lien is the whole attack: the venue's own ratio is what the floor uses.
    function test_fundFill_sell_overstatedFeeIsClamped() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);

        vm.prank(admin);
        controller.setMarketConfig(
            _marketId(), TICK_99, 1, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );

        // The position carries no fee at all, so no relief is corroborated.
        _mockPosition(uint128(FILL_UNITS), 0);

        uint256 unencumbered = MidnightUtils.minSellPrice(
            MAX_SELL_YIELD,
            marketMaturity - block.timestamp,
            MidnightUtils.WAD,
            0
        );

        uint256 floor = (FILL_UNITS * unencumbered + MidnightUtils.WAD - 1) / MidnightUtils.WAD;

        // Claiming a unit of fee per unit would drive the yield rail to zero if it were trusted.
        vm.expectRevert("MidnightFacet/fill-price-too-low");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, floor - 1, FILL_UNITS, FILL_UNITS - 1);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, floor, FILL_UNITS, FILL_UNITS - 1);
    }

    // A full exit leaves no ratio behind, so it has to price as though no fee was shed.
    function test_fundFill_sell_fullExitPricesUnencumbered() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);

        vm.prank(admin);
        controller.setMarketConfig(
            _marketId(), TICK_99, 1, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );

        _mockPosition(0, 0);

        uint256 unencumbered = MidnightUtils.minSellPrice(
            MAX_SELL_YIELD,
            marketMaturity - block.timestamp,
            MidnightUtils.WAD,
            0
        );

        uint256 floor = (FILL_UNITS * unencumbered + MidnightUtils.WAD - 1) / MidnightUtils.WAD;

        vm.expectRevert("MidnightFacet/fill-price-too-low");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, floor - 1, FILL_UNITS, FILL_UNITS / 2);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, floor, FILL_UNITS, FILL_UNITS / 2);
    }

    function testFuzz_fundFill_honestFillIsFundable(uint256 units) external {
        // One unit prices to nothing, which trips the zero-assets guard instead of the bound.
        units = bound(units, 2, MAX_OFFER_SIZE);

        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        uint256 honest = _honestAssets(units);

        vm.expectRevert("MidnightFacet/fill-price-too-high");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, honest + 1, units, 0);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, honest, units, 0);
    }

    function testFuzz_fundFill_sell_honestFillIsSettleable(uint256 units) external {
        // Below three units an honest exit prices to one wei, so a wei less is nothing at all.
        units = bound(units, 3, MAX_OFFER_SIZE);

        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);

        uint256 honest = _honestSellAssets(units);

        vm.expectRevert("MidnightFacet/fill-price-too-low");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, honest - 1, units, 0);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, honest, units, 0);
    }

    // The 1 wei fill the open market accepts is the control leg.
    function test_fundFill_entriesClosed() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, 1, FILL_UNITS, 0);

        vm.prank(admin);
        controller.setMarketConfig(
            _marketId(), 0, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );

        vm.expectRevert("MidnightFacet/fill-price-too-high");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, 1, FILL_UNITS, 0);
    }

    function test_fundFill_buyRateLimitBoundary() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        uint256 assets = _honestAssets(FILL_UNITS);

        _setBuyLimit(assets - 1);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        _setBuyLimit(assets);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);
    }

    function test_fundFill_sell_sellRateLimitBoundary() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);

        uint256 assets = _honestSellAssets(FILL_UNITS);

        _setSellLimit(assets - 1);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, assets, FILL_UNITS, 0);

        _setSellLimit(assets);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, assets, FILL_UNITS, 0);
    }

    function test_fundFill_strategyBuyRateLimitBoundary() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        uint256 assets = _honestAssets(FILL_UNITS);

        _setStrategyBuyLimit(strategy, assets - 1);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        _setStrategyBuyLimit(strategy, assets);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);
    }

    function test_fundFill_sell_strategySellRateLimitBoundary() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);

        uint256 assets = _honestSellAssets(FILL_UNITS);

        _setStrategySellLimit(strategy, assets - 1);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, assets, FILL_UNITS, 0);

        _setStrategySellLimit(strategy, assets);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, assets, FILL_UNITS, 0);
    }

    function test_fundFill() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        bytes32 buyKey         = controller.getBuyRateLimitKey(_marketId());
        bytes32 strategyBuyKey = controller.getStrategyBuyRateLimitKey(strategy, _marketId());

        assertEq(rateLimits.getCurrentRateLimit(buyKey),         MAX_OFFER_SIZE);
        assertEq(rateLimits.getCurrentRateLimit(strategyBuyKey), MAX_OFFER_SIZE);

        assertEq(IERC20Mock(loanToken).balanceOf(proxy),               PROXY_BALANCE);
        assertEq(IERC20Mock(loanToken).balanceOf(strategy),            0);
        assertEq(IERC20Mock(loanToken).balanceOf(address(controller)), 0);

        uint256 assets = _honestAssets(FILL_UNITS);

        vm.record();

        vm.expectCall(loanToken, abi.encodeCall(IERC20Mock.transfer, (strategy, assets)));

        vm.expectEmit(address(controller));
        emit IMidnightFacet.MidnightFillFunded(_marketId(), strategy, true, assets, FILL_UNITS);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        _assertReentrancyGuardWrittenToTwice(address(controller));

        assertEq(rateLimits.getCurrentRateLimit(buyKey),         MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(strategyBuyKey), MAX_OFFER_SIZE - assets);

        assertEq(IERC20Mock(loanToken).balanceOf(proxy),               PROXY_BALANCE - assets);
        assertEq(IERC20Mock(loanToken).balanceOf(strategy),            assets);
        assertEq(IERC20Mock(loanToken).balanceOf(address(controller)), 0);
    }

    // Midnight pays the proxy before calling back, so settling an exit moves nothing here.
    function test_fundFill_sell() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);

        bytes32 buyKey          = controller.getBuyRateLimitKey(_marketId());
        bytes32 sellKey         = controller.getSellRateLimitKey(_marketId());
        bytes32 strategySellKey = controller.getStrategySellRateLimitKey(strategy, _marketId());

        uint256 assets = _honestSellAssets(FILL_UNITS);

        vm.record();

        vm.expectEmit(address(controller));
        emit IMidnightFacet.MidnightFillFunded(_marketId(), strategy, false, assets, FILL_UNITS);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, assets, FILL_UNITS, 0);

        _assertReentrancyGuardWrittenToTwice(address(controller));

        assertEq(rateLimits.getCurrentRateLimit(sellKey),         MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(strategySellKey), MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),          MAX_OFFER_SIZE);

        assertEq(IERC20Mock(loanToken).balanceOf(proxy),               PROXY_BALANCE);
        assertEq(IERC20Mock(loanToken).balanceOf(strategy),            0);
        assertEq(IERC20Mock(loanToken).balanceOf(address(controller)), 0);
    }

    // Entry, exit, entry: each leg debits its own meter and neither one restores the other's.
    function test_fundFill_roundTripRestoresNothing() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        bytes32 buyKey          = controller.getBuyRateLimitKey(_marketId());
        bytes32 sellKey         = controller.getSellRateLimitKey(_marketId());
        bytes32 strategyBuyKey  = controller.getStrategyBuyRateLimitKey(strategy, _marketId());
        bytes32 strategySellKey = controller.getStrategySellRateLimitKey(strategy, _marketId());

        uint256 assets = _honestAssets(FILL_UNITS);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        assertEq(rateLimits.getCurrentRateLimit(buyKey),          MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),         MAX_OFFER_SIZE);
        assertEq(rateLimits.getCurrentRateLimit(strategyBuyKey),  MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(strategySellKey), MAX_OFFER_SIZE);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, assets, FILL_UNITS, 0);

        assertEq(rateLimits.getCurrentRateLimit(buyKey),          MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),         MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(strategyBuyKey),  MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(strategySellKey), MAX_OFFER_SIZE - assets);

        // Every meter is below its ceiling now, so a restore from the entry would show.
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        assertEq(rateLimits.getCurrentRateLimit(buyKey),          MAX_OFFER_SIZE - 2 * assets);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),         MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(strategyBuyKey),  MAX_OFFER_SIZE - 2 * assets);
        assertEq(rateLimits.getCurrentRateLimit(strategySellKey), MAX_OFFER_SIZE - assets);
    }

    // One market, two strategies: each spends its own key and both spend the shared market key.
    function test_fundFill_twoStrategiesMeteredIndependently() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        address other = makeAddr("otherStrategy");

        _setStrategyBuyLimit(other, MAX_OFFER_SIZE);

        bytes32 buyKey      = controller.getBuyRateLimitKey(_marketId());
        bytes32 strategyKey = controller.getStrategyBuyRateLimitKey(strategy, _marketId());
        bytes32 otherKey    = controller.getStrategyBuyRateLimitKey(other,    _marketId());

        uint256 assets = _honestAssets(FILL_UNITS);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        vm.prank(other);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        vm.prank(other);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        assertEq(rateLimits.getCurrentRateLimit(strategyKey), MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(otherKey),    MAX_OFFER_SIZE - 2 * assets);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),      MAX_OFFER_SIZE - 3 * assets);

        assertEq(IERC20Mock(loanToken).balanceOf(strategy), assets);
        assertEq(IERC20Mock(loanToken).balanceOf(other),    2 * assets);
    }

    // The exit leg never touches a buy meter, so unset buy keys cannot block it.
    function test_fundFill_sell_noBuyLimit() external {
        _onboardAndEnableMake(0);
        _setSellLimit(MAX_OFFER_SIZE);
        _setStrategySellLimit(strategy, MAX_OFFER_SIZE);

        bytes32 buyKey         = controller.getBuyRateLimitKey(_marketId());
        bytes32 strategyBuyKey = controller.getStrategyBuyRateLimitKey(strategy, _marketId());

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, _honestSellAssets(FILL_UNITS), FILL_UNITS, 0);

        assertEq(rateLimits.getRateLimitData(buyKey).maxAmount,         0);
        assertEq(rateLimits.getRateLimitData(strategyBuyKey).maxAmount, 0);
    }

    // The strategy key is per market, so being onboarded elsewhere is no authorization here.
    function test_fundFill_strategyKeyedOnAnotherMarket() external {
        _onboardAndEnableMake(0);
        _setBuyLimit(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        bytes32 otherKey = controller.getStrategyBuyRateLimitKey(strategy, keccak256("other"));

        vm.prank(admin);
        rateLimits.setRateLimitData(otherKey, MAX_OFFER_SIZE, 0);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, _honestAssets(FILL_UNITS), FILL_UNITS, 0);
    }

    // Past maturity the yield-implied ceiling collapses onto par, leaving the tick ceiling alone.
    function test_fundFill_postMaturity() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        vm.warp(marketMaturity + 1 days);

        uint256 ceiling = FILL_UNITS * MidnightTickLib.tickToPrice(TICK_99) / MidnightUtils.WAD;

        vm.expectRevert("MidnightFacet/fill-price-too-high");
        vm.prank(strategy);
        controller.fundFill(_marketId(), true, ceiling + 1, FILL_UNITS, 0);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, ceiling, FILL_UNITS, 0);
    }

    // Past maturity the exit floor collapses onto par, which is above every tick floor.
    function test_fundFill_sell_postMaturity() external {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);

        vm.warp(marketMaturity + 1 days);

        vm.expectRevert("MidnightFacet/fill-price-too-low");
        vm.prank(strategy);
        controller.fundFill(_marketId(), false, FILL_UNITS - 1, FILL_UNITS, 0);

        vm.prank(strategy);
        controller.fundFill(_marketId(), false, FILL_UNITS, FILL_UNITS, 0);
    }

    /**********************************************************************************************/
    /*** isCallbackAllowed Tests                                                                ***/
    /**********************************************************************************************/

    function _onboardForView() internal {
        _onboardAndEnableMake(0);
        _onboardStrategy(MAX_OFFER_SIZE);
        _setSellLimit(MAX_OFFER_SIZE);
    }

    function test_isCallbackAllowed() external {
        _onboardForView();

        assertEq(controller.isCallbackAllowed(_marketId(), strategy, true),  true);
        assertEq(controller.isCallbackAllowed(_marketId(), strategy, false), true);
    }

    // Reads the ceiling, not the capacity left, so a drained key keeps its offers ratifiable.
    function test_isCallbackAllowed_drainedKeyStillAllowed() external {
        _onboardForView();
        _mockLossFactor(0);

        uint256 assets = _honestAssets(FILL_UNITS);

        _setStrategyBuyLimit(strategy, assets);

        vm.prank(strategy);
        controller.fundFill(_marketId(), true, assets, FILL_UNITS, 0);

        bytes32 strategyBuyKey = controller.getStrategyBuyRateLimitKey(strategy, _marketId());

        assertEq(rateLimits.getCurrentRateLimit(strategyBuyKey), 0);

        assertEq(controller.isCallbackAllowed(_marketId(), strategy, true), true);
    }

    // A zero callback never reaches fundFill, so no key configuration can make it allowed.
    function test_isCallbackAllowed_zeroCallback() external {
        _onboardForView();
        _setStrategyBuyLimit(address(0), MAX_OFFER_SIZE);
        _setStrategySellLimit(address(0), MAX_OFFER_SIZE);

        assertEq(controller.isCallbackAllowed(_marketId(), address(0), true),  false);
        assertEq(controller.isCallbackAllowed(_marketId(), address(0), false), false);
    }

    function test_isCallbackAllowed_makeNotEnabled() external {
        _onboardForView();

        vm.prank(admin);
        controller.setMakeConfig(_market(), 0);

        assertEq(controller.isCallbackAllowed(_marketId(), strategy, true),  false);
        assertEq(controller.isCallbackAllowed(_marketId(), strategy, false), false);
    }

    function test_isCallbackAllowed_zeroStrategyKey() external {
        _onboardForView();

        _setStrategyBuyLimit(strategy, 0);

        assertEq(controller.isCallbackAllowed(_marketId(), strategy, true),  false);
        assertEq(controller.isCallbackAllowed(_marketId(), strategy, false), true);

        _setStrategyBuyLimit(strategy, MAX_OFFER_SIZE);
        _setStrategySellLimit(strategy, 0);

        assertEq(controller.isCallbackAllowed(_marketId(), strategy, true),  true);
        assertEq(controller.isCallbackAllowed(_marketId(), strategy, false), false);
    }

    function test_isCallbackAllowed_zeroMarketKey() external {
        _onboardForView();

        _setBuyLimit(0);

        assertEq(controller.isCallbackAllowed(_marketId(), strategy, true),  false);
        assertEq(controller.isCallbackAllowed(_marketId(), strategy, false), true);

        _setBuyLimit(MAX_OFFER_SIZE);
        _setSellLimit(0);

        assertEq(controller.isCallbackAllowed(_marketId(), strategy, true),  true);
        assertEq(controller.isCallbackAllowed(_marketId(), strategy, false), false);
    }

    function test_isCallbackAllowed_otherStrategy() external {
        _onboardForView();

        address other = makeAddr("otherStrategy");

        assertEq(controller.isCallbackAllowed(_marketId(), other, true),  false);
        assertEq(controller.isCallbackAllowed(_marketId(), other, false), false);
    }

}
