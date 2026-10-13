// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ReentrancyGuard } from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { IMidnightFacet }          from "../../../src/facets/midnight/IMidnightFacet.sol";
import { IController }             from "../../../src/interfaces/IController.sol";
import { IEnumerableIntegrations } from "../../../src/interfaces/IEnumerableIntegrations.sol";
import { IRateLimits }             from "../../../src/interfaces/IRateLimits.sol";

import { makeAddressBytes32Key, makeBytes32Key } from "../../../src/libraries/RateLimitHelpers.sol";

import { MidnightFacet } from "../../../src/facets/midnight/MidnightFacet.sol";
import { MidnightUtils } from "../../../src/facets/midnight/MidnightUtils.sol";

import { CollateralParams, Market, Offer } from "../../../src/facets/midnight/MidnightUtils.sol";

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

    function fundFill(bytes32 marketId, uint256 assets, uint256 units) external;

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

    function getStrategyRateLimitKey(address strategy, bytes32 marketId)
        external
        pure
        returns (bytes32);

    function midnight() external view returns (address);

    function updateIntegrations(bytes32[] memory integrationIds) external;

}

interface IMidnightMock {

    function toMarket(bytes32 id) external view returns (Market memory);

    function lossFactor(bytes32 id) external view returns (uint128);

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

        IEnumerableIntegrations.Wire[] memory wires = new IEnumerableIntegrations.Wire[](14);

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
            IControllerLike.getStrategyRateLimitKey.selector,
            IMidnightFacet.getStrategyRateLimitKey.selector
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
        return MidnightUtils.toId(_market());
    }

    function _mockMarketExists() internal {
        vm.mockCall(
            midnight,
            abi.encodeCall(IMidnightMock.toMarket, (_marketId())),
            abi.encode(_market())
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

    // Keys resolved before the prank: an external call in the argument list would consume it.
    function _authorizeStrategy(uint256 maxAmount) internal {
        bytes32 strategyKey = controller.getStrategyRateLimitKey(strategy, _marketId());
        bytes32 buyKey      = controller.getBuyRateLimitKey(_marketId());

        vm.startPrank(admin);
        rateLimits.setRateLimitData(strategyKey, maxAmount, 0);
        rateLimits.setRateLimitData(buyKey,      maxAmount, 0);
        vm.stopPrank();
    }

    function _setBuyLimit(uint256 maxAmount) internal {
        bytes32 buyKey = controller.getBuyRateLimitKey(_marketId());

        vm.prank(admin);
        rateLimits.setRateLimitData(buyKey, maxAmount, 0);
    }

    function _setStrategyLimit(uint256 maxAmount) internal {
        bytes32 strategyKey = controller.getStrategyRateLimitKey(strategy, _marketId());

        vm.prank(admin);
        rateLimits.setRateLimitData(strategyKey, maxAmount, 0);
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
        bound = MidnightUtils.tickToPrice(TICK_99);

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
        uint16 maxTick = uint16(MidnightUtils.MAX_TICK);

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
        uint16 maxTick = uint16(MidnightUtils.MAX_TICK);

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

    function test_getStrategyRateLimitKey() external view {
        assertEq(
            controller.getStrategyRateLimitKey(strategy, MARKET_ID),
            makeAddressBytes32Key(keccak256("LIMIT_MIDNIGHT_STRATEGY"), strategy, MARKET_ID)
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
        controller.fundFill(MARKET_ID, 1, 1);
    }

    // No role gates fundFill; the pair limit's existence is the whole authorization.
    function test_fundFill_strategyNotAuthorized() external {
        _onboardAndEnableMake(0);

        uint256 assets = _honestAssets(FILL_UNITS);

        vm.expectRevert("MidnightFacet/strategy-not-authorized");
        vm.prank(strategy);
        controller.fundFill(_marketId(), assets, FILL_UNITS);

        _authorizeStrategy(MAX_OFFER_SIZE);

        vm.expectRevert("MidnightFacet/strategy-not-authorized");
        vm.prank(unauthorized);
        controller.fundFill(_marketId(), assets, FILL_UNITS);
    }

    function test_fundFill_makeNotEnabled() external {
        _onboardAndEnableMake(0);
        _authorizeStrategy(MAX_OFFER_SIZE);

        vm.prank(admin);
        controller.setMakeConfig(_market(), 0);

        vm.expectRevert("MidnightFacet/make-not-enabled");
        vm.prank(strategy);
        controller.fundFill(_marketId(), _honestAssets(FILL_UNITS), FILL_UNITS);
    }

    function test_fundFill_zeroAmounts() external {
        _onboardAndEnableMake(0);
        _authorizeStrategy(MAX_OFFER_SIZE);

        vm.expectRevert("MidnightFacet/zero-assets");
        vm.prank(strategy);
        controller.fundFill(_marketId(), 0, FILL_UNITS);

        vm.expectRevert("MidnightFacet/zero-units");
        vm.prank(strategy);
        controller.fundFill(_marketId(), _honestAssets(FILL_UNITS), 0);
    }

    function test_fundFill_lossFactorTooHighBoundary() external {
        _onboardAndEnableMake(1);
        _authorizeStrategy(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(FILL_UNITS);

        _mockLossFactor(2);

        vm.expectRevert("MidnightFacet/loss-factor-too-high");
        vm.prank(strategy);
        controller.fundFill(_marketId(), assets, FILL_UNITS);

        _mockLossFactor(1);

        vm.prank(strategy);
        controller.fundFill(_marketId(), assets, FILL_UNITS);
    }

    function test_fundFill_fillPriceTooHighBoundary() external {
        _onboardAndEnableMake(0);
        _authorizeStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        uint256 honest = _honestAssets(FILL_UNITS);

        vm.expectRevert("MidnightFacet/fill-price-too-high");
        vm.prank(strategy);
        controller.fundFill(_marketId(), honest + 1, FILL_UNITS);

        vm.prank(strategy);
        controller.fundFill(_marketId(), honest, FILL_UNITS);
    }

    // The 1 wei fill the open market accepts is the control leg.
    function test_fundFill_entriesClosed() external {
        _onboardAndEnableMake(0);
        _authorizeStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        vm.prank(strategy);
        controller.fundFill(_marketId(), 1, FILL_UNITS);

        vm.prank(admin);
        controller.setMarketConfig(
            _marketId(), 0, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );

        vm.expectRevert("MidnightFacet/fill-price-too-high");
        vm.prank(strategy);
        controller.fundFill(_marketId(), 1, FILL_UNITS);
    }

    function test_fundFill_buyRateLimitBoundary() external {
        _onboardAndEnableMake(0);
        _authorizeStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        uint256 assets = _honestAssets(FILL_UNITS);

        _setBuyLimit(assets - 1);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        vm.prank(strategy);
        controller.fundFill(_marketId(), assets, FILL_UNITS);

        _setBuyLimit(assets);

        vm.prank(strategy);
        controller.fundFill(_marketId(), assets, FILL_UNITS);
    }

    function test_fundFill() external {
        _onboardAndEnableMake(0);
        _authorizeStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        bytes32 strategyKey = controller.getStrategyRateLimitKey(strategy, _marketId());
        bytes32 buyKey      = controller.getBuyRateLimitKey(_marketId());

        assertEq(rateLimits.getCurrentRateLimit(strategyKey), MAX_OFFER_SIZE);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),      MAX_OFFER_SIZE);

        assertEq(IERC20Mock(loanToken).balanceOf(proxy),               PROXY_BALANCE);
        assertEq(IERC20Mock(loanToken).balanceOf(strategy),            0);
        assertEq(IERC20Mock(loanToken).balanceOf(address(controller)), 0);

        uint256 assets = _honestAssets(FILL_UNITS);

        vm.record();

        vm.expectCall(loanToken, abi.encodeCall(IERC20Mock.transfer, (strategy, assets)));

        vm.expectEmit(address(controller));
        emit IMidnightFacet.MidnightFillFunded(_marketId(), strategy, assets, FILL_UNITS);

        vm.prank(strategy);
        controller.fundFill(_marketId(), assets, FILL_UNITS);

        _assertReentrancyGuardWrittenToTwice(address(controller));

        assertEq(rateLimits.getCurrentRateLimit(strategyKey), MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),      MAX_OFFER_SIZE - assets);

        assertEq(IERC20Mock(loanToken).balanceOf(proxy),               PROXY_BALANCE - assets);
        assertEq(IERC20Mock(loanToken).balanceOf(strategy),            assets);
        assertEq(IERC20Mock(loanToken).balanceOf(address(controller)), 0);
    }

    function test_fundFill_strategyRateLimitBoundary() external {
        _onboardAndEnableMake(0);
        _authorizeStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        uint256 assets = _honestAssets(FILL_UNITS);

        _setStrategyLimit(assets - 1);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        vm.prank(strategy);
        controller.fundFill(_marketId(), assets, FILL_UNITS);

        _setStrategyLimit(assets);

        vm.prank(strategy);
        controller.fundFill(_marketId(), assets, FILL_UNITS);

        assertEq(
            rateLimits.getCurrentRateLimit(
                controller.getStrategyRateLimitKey(strategy, _marketId())
            ),
            0
        );
    }

    // The pair key is per market, so a limit on another market is no authorization for this one.
    function test_fundFill_strategyAuthorizedOnAnotherMarket() external {
        _onboardAndEnableMake(0);

        bytes32 otherKey = controller.getStrategyRateLimitKey(strategy, keccak256("other-market"));

        vm.prank(admin);
        rateLimits.setRateLimitData(otherKey, MAX_OFFER_SIZE, 0);

        vm.expectRevert("MidnightFacet/strategy-not-authorized");
        vm.prank(strategy);
        controller.fundFill(_marketId(), _honestAssets(FILL_UNITS), FILL_UNITS);
    }

    // Past maturity the yield-implied ceiling collapses onto par, leaving the tick ceiling alone.
    function test_fundFill_postMaturity() external {
        _onboardAndEnableMake(0);
        _authorizeStrategy(MAX_OFFER_SIZE);
        _mockLossFactor(0);

        vm.warp(marketMaturity + 1 days);

        uint256 ceiling = FILL_UNITS * MidnightUtils.tickToPrice(TICK_99) / MidnightUtils.WAD;

        vm.expectRevert("MidnightFacet/fill-price-too-high");
        vm.prank(strategy);
        controller.fundFill(_marketId(), ceiling + 1, FILL_UNITS);

        vm.prank(strategy);
        controller.fundFill(_marketId(), ceiling, FILL_UNITS);
    }

}
