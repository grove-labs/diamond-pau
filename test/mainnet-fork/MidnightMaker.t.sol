// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Ethereum } from "../../lib/spark-address-registry/src/Ethereum.sol";

import { Market, MidnightUtils, Offer } from "../../src/facets/midnight/MidnightUtils.sol";

import { MockFundingStrategy } from "../mocks/MockFundingStrategy.sol";

import { Midnight_TestBase } from "./Midnight.t.sol";

interface IOnBuyLike {

    function onBuy(
        bytes32 id,
        Market  memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256 pendingFeeIncrease,
        address buyer,
        bytes   memory data
    ) external returns (bytes32);

}

interface IOnSellLike {

    function onSell(
        bytes32 id,
        Market  memory market,
        uint256 sellerAssets,
        uint256 units,
        uint256 pendingFeeDecrease,
        address seller,
        address receiver,
        bytes   memory data
    ) external returns (bytes32);

}

// Takers call the singleton directly, so no code of ours runs on the exit leg.
interface ITakeLike {

    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory takerCallbackData
    ) external returns (uint256 buyerAssets, uint256 sellerAssets);

}

abstract contract Midnight_Maker_TestBase is Midnight_TestBase {

    bytes32 internal constant BUY_GROUP  = keccak256("grove.midnight.buy");
    bytes32 internal constant SELL_GROUP = keccak256("grove.midnight.sell");

    uint256 internal constant MAX_OFFER_WINDOW = 1 days;

    // fundFill prices the fee at the cap, which at 180 days puts the bound below TICK_99.
    uint16 internal constant MAKER_BUY_TICK  = TICK_98;
    uint16 internal constant MAKER_SELL_TICK = TICK_99;

    MockFundingStrategy internal strategy;

    bytes32 internal makeKey;

    uint256 internal maxOfferSize;

    function setUp() public virtual override {
        super.setUp();

        strategy = new MockFundingStrategy(address(mainnetController));

        maxOfferSize = 2 * seedUnits;
        makeKey      = mainnetController.midnight_getMakeRateLimitKey(marketId);

        vm.startPrank(Ethereum.SPARK_PROXY);
        mainnetController.midnight_setRatifierAuthorization(SETTER_RATIFIER, true);
        mainnetController.midnight_setMakeConfig(market, maxOfferSize);
        mainnetController.midnight_setDesignatedGroups(marketId, BUY_GROUP, SELL_GROUP);
        mainnetController.midnight_setCallbackAllowed(marketId, address(strategy), true);
        rateLimits.setRateLimitData(makeKey, rateLimit, rateLimit / 1 days);
        vm.stopPrank();

        vm.label(address(strategy), "MockFundingStrategy");
    }

    /**********************************************************************************************/
    /*** Maker helpers                                                                          ***/
    /**********************************************************************************************/

    function _makerOffer(bool buy, uint256 tick, uint256 maxUnits)
        internal
        returns (Offer memory offer)
    {
        offer = Offer({
            market                  : market,
            buy                     : buy,
            maker                   : address(almProxy),
            start                   : block.timestamp,
            expiry                  : block.timestamp + MAX_OFFER_WINDOW,
            tick                    : tick,
            group                   : buy ? BUY_GROUP : SELL_GROUP,
            callback                : address(strategy),
            callbackData            : new bytes(0),
            receiverIfMakerIsSeller : buy ? address(0) : address(almProxy),
            ratifier                : SETTER_RATIFIER,
            reduceOnly              : !buy,
            maxUnits                : uint128(maxUnits),
            maxAssets               : 0,
            continuousFeeCap        : MidnightUtils.continuousFeePerSecond(MAX_CONTINUOUS_FEE_CBPS)
        });

        _ratify(offer);
    }

    // The collateralized maker EOA the base fixture funds, so it can both buy and sell units.
    function _take(Offer memory offer, uint256 units)
        internal
        returns (uint256 buyerAssets, uint256 sellerAssets)
    {
        vm.prank(maker);
        return ITakeLike(MIDNIGHT).take(
            offer,
            _ratifierData(offer),
            units,
            maker,
            offer.buy ? maker : address(0),
            address(0),
            new bytes(0)
        );
    }

    function _takeExpectRevert(Offer memory offer, uint256 units, bytes memory reason) internal {
        vm.prank(maker);
        vm.expectRevert(reason);
        ITakeLike(MIDNIGHT).take(
            offer,
            _ratifierData(offer),
            units,
            maker,
            offer.buy ? maker : address(0),
            address(0),
            new bytes(0)
        );
    }

}

contract MainnetController_MidnightMaker_Lifecycle_Tests is Midnight_Maker_TestBase {

    function test_makerLifecycle() external {
        _seedCredit();

        uint256 units = seedUnits / 2;

        /*** Exit leg ***/

        uint256 creditBefore  = _credit();
        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));

        uint256 buyLimitBefore = rateLimits.getCurrentRateLimit(buyKey);

        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, units);

        ( uint256 buyerAssets, uint256 sellerAssets ) = _take(sell, units);

        assertEq(sellerAssets, _makerSellerAssets(units, MAKER_SELL_TICK));
        assertEq(buyerAssets,  _buyerAssets(units, MAKER_SELL_TICK));

        assertEq(_credit(),                            creditBefore - units);
        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore + sellerAssets);

        assertEq(rateLimits.getCurrentRateLimit(makeKey), rateLimit - sellerAssets);
        assertEq(rateLimits.getCurrentRateLimit(sellKey), rateLimit - sellerAssets);

        // Seeding spent from the entry budget, so the exit has room to put back.
        assertEq(rateLimits.getCurrentRateLimit(buyKey), buyLimitBefore + sellerAssets);

        assertEq(midnight.consumed(address(almProxy), SELL_GROUP), units);

        /*** Entry leg ***/

        creditBefore  = _credit();
        balanceBefore = loanToken.balanceOf(address(almProxy));

        uint256 makeLimitBefore = rateLimits.getCurrentRateLimit(makeKey);

        buyLimitBefore = rateLimits.getCurrentRateLimit(buyKey);

        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, units);

        ( buyerAssets, sellerAssets ) = _take(buy, units);

        assertEq(buyerAssets,  _makerBuyerAssets(units, MAKER_BUY_TICK));
        assertEq(sellerAssets, _sellerAssets(units, MAKER_BUY_TICK));

        assertEq(_credit(),                              creditBefore + units);
        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore - buyerAssets);

        assertEq(rateLimits.getCurrentRateLimit(makeKey), makeLimitBefore - buyerAssets);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),  buyLimitBefore  - buyerAssets);

        assertEq(midnight.consumed(address(almProxy), BUY_GROUP), units);

        /*** Strategy conduit ***/

        assertEq(loanToken.balanceOf(address(strategy)),             0);
        assertEq(loanToken.allowance(address(strategy), MIDNIGHT),   0);

        assertEq(midnight.debt(marketId, address(almProxy)), 0);
    }

    // Pins onBuy's argument order against deployed bytecode. The fee argument is zero here, so a
    // swap with units would otherwise surface only as a zero-unit fundFill.
    function test_makerBuy_onBuyArgumentsArePinned() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        uint256 units = seedUnits / 2;

        vm.expectCall(
            address(strategy),
            abi.encodeCall(
                IOnBuyLike.onBuy,
                (
                    marketId,
                    market,
                    _makerBuyerAssets(units, MAKER_BUY_TICK),
                    units,
                    uint256(0),
                    address(almProxy),
                    new bytes(0)
                )
            )
        );

        _take(buy, units);
    }

    // Same pin on the exit side, where the receiver argument sits between seller and data.
    function test_makerSell_onSellArgumentsArePinned() external {
        _seedCredit();

        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, seedUnits);

        uint256 units = seedUnits / 2;

        vm.expectCall(
            address(strategy),
            abi.encodeCall(
                IOnSellLike.onSell,
                (
                    marketId,
                    market,
                    _makerSellerAssets(units, MAKER_SELL_TICK),
                    units,
                    uint256(0),
                    address(almProxy),
                    address(almProxy),
                    new bytes(0)
                )
            )
        );

        _take(sell, units);
    }

    function test_makerBuy_partialFill() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        uint256 units = seedUnits / 4;

        ( uint256 buyerAssets, ) = _take(buy, units);

        assertEq(_credit(), units);

        assertEq(rateLimits.getCurrentRateLimit(makeKey), rateLimit - buyerAssets);

        assertEq(midnight.consumed(address(almProxy), BUY_GROUP), units);

        ( uint256 moreAssets, ) = _take(buy, units);

        assertEq(_credit(), 2 * units);

        assertEq(
            rateLimits.getCurrentRateLimit(makeKey),
            rateLimit - buyerAssets - moreAssets
        );

        assertEq(midnight.consumed(address(almProxy), BUY_GROUP), 2 * units);
    }

    function test_makerBuy_offerCapExhausted() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        _take(buy, seedUnits);

        _takeExpectRevert(buy, 1, abi.encodeWithSignature("ConsumedUnits()"));
    }

    function test_makerSell_reduceOnlyStopsNakedShort() external {
        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, seedUnits);

        // The proxy holds no credit, so a reduce-only sell has nothing to shed.
        _takeExpectRevert(sell, seedUnits, abi.encodeWithSignature("MakerCreditOrDebtIncreased()"));

        assertEq(midnight.debt(marketId, address(almProxy)), 0);
    }

}

contract MainnetController_MidnightMaker_Retroactivity_Tests is Midnight_Maker_TestBase {

    function test_tighteningEntryTickKillsRestingOffer() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        _take(buy, seedUnits / 4);

        _setConfig(MAKER_BUY_TICK - 4, TICK_98, MAX_CONTINUOUS_FEE_CBPS, 0);

        _takeExpectRevert(buy, seedUnits / 4, "MidnightFacet/fill-price-too-high");
    }

    function test_tighteningEntryYieldKillsRestingOffer() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        _take(buy, seedUnits / 4);

        _setYields(5_00, MAX_SELL_YIELD);

        _takeExpectRevert(buy, seedUnits / 4, "MidnightFacet/fill-price-too-high");
    }

    function test_disablingMakeKillsRestingOffer() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        _take(buy, seedUnits / 4);

        vm.prank(Ethereum.SPARK_PROXY);
        mainnetController.midnight_setMakeConfig(market, 0);

        _takeExpectRevert(buy, seedUnits / 4, "MidnightFacet/make-not-enabled");
    }

    function test_tighteningExitTickKillsRestingOffer() external {
        _seedCredit();

        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, seedUnits);

        _take(sell, seedUnits / 4);

        _setConfig(TICK_99, MAKER_SELL_TICK + 4, MAX_CONTINUOUS_FEE_CBPS, 0);

        _takeExpectRevert(sell, seedUnits / 4, "MidnightFacet/fill-price-too-low");
    }

    function test_tighteningExitYieldKillsRestingOffer() external {
        _seedCredit();

        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, seedUnits);

        _take(sell, seedUnits / 4);

        // At 180 days a 1% exit yield floors above the offer's tick price.
        _setYields(MIN_BUY_YIELD, 1_00);

        _takeExpectRevert(sell, seedUnits / 4, "MidnightFacet/fill-price-too-low");
    }

    function test_removingCallbackRevokesBothLegs() external {
        _seedCredit();

        Offer memory buy  = _makerOffer(true,  MAKER_BUY_TICK,  seedUnits);
        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, seedUnits);

        _take(buy,  seedUnits / 4);
        _take(sell, seedUnits / 4);

        vm.prank(Ethereum.SPARK_PROXY);
        mainnetController.midnight_setCallbackAllowed(marketId, address(strategy), false);

        _takeExpectRevert(buy,  seedUnits / 4, "MidnightFacet/callback-not-allowed");
        _takeExpectRevert(sell, seedUnits / 4, "MidnightFacet/callback-not-allowed");
    }

    // The make limit never restores, so an exhausted one stops the book in both directions.
    function test_exhaustingMakeLimitStopsBothLegs() external {
        _seedCredit();

        Offer memory buy  = _makerOffer(true,  MAKER_BUY_TICK,  seedUnits);
        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, seedUnits);

        uint256 units = seedUnits / 4;

        _take(buy, units);

        assertLt(rateLimits.getCurrentRateLimit(makeKey), rateLimit);

        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(makeKey, 1, 0);

        _takeExpectRevert(buy,  units, "RateLimits/rate-limit-exceeded");
        _takeExpectRevert(sell, units, "RateLimits/rate-limit-exceeded");
    }

    function test_offerDiesAtExpiry() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        vm.warp(buy.expiry);

        _take(buy, seedUnits / 4);

        vm.warp(buy.expiry + 1);

        // Upstream's own expiry check fires before ours.
        _takeExpectRevert(buy, seedUnits / 4, abi.encodeWithSignature("OfferExpired()"));
    }

    function test_cancellingBuyGroupLeavesSellGroupLive() external {
        _seedCredit();

        Offer memory buy  = _makerOffer(true,  MAKER_BUY_TICK,  seedUnits / 4);
        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, seedUnits / 4);

        vm.prank(allocator);
        mainnetController.midnight_cancelOfferGroup(BUY_GROUP);

        _takeExpectRevert(buy, 1, abi.encodeWithSignature("ConsumedUnits()"));

        uint256 units = seedUnits / 8;

        ( , uint256 sellerAssets ) = _take(sell, units);

        assertGt(sellerAssets, 0);
    }

}

contract MainnetController_MidnightMaker_KillSwitch_Tests is Midnight_Maker_TestBase {

    function test_deauthorizingRatifierKillsEverything() external {
        _seedCredit();

        Offer memory buy  = _makerOffer(true,  MAKER_BUY_TICK,  seedUnits / 4);
        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, seedUnits / 4);

        _take(buy,  seedUnits / 8);
        _take(sell, seedUnits / 8);

        assertTrue(midnight.isAuthorized(address(almProxy), SETTER_RATIFIER));

        vm.prank(Ethereum.SPARK_PROXY);
        mainnetController.midnight_setRatifierAuthorization(SETTER_RATIFIER, false);

        assertFalse(midnight.isAuthorized(address(almProxy), SETTER_RATIFIER));

        bytes memory unauthorized = abi.encodeWithSignature("RatifierUnauthorized()");

        _takeExpectRevert(buy,  seedUnits / 8, unauthorized);
        _takeExpectRevert(sell, seedUnits / 8, unauthorized);
    }

    // The authorization is total, so the set of addresses holding it is the whole blast radius.
    function test_onlyTheRatifierIsAuthorized() external view {
        address[6] memory others = [
            address(strategy),
            address(mainnetController),
            address(almProxy),
            address(rateLimits),
            maker,
            Ethereum.SPARK_PROXY
        ];

        for (uint256 i; i < others.length; ++i) {
            assertFalse(midnight.isAuthorized(address(almProxy), others[i]));
        }

        assertTrue(midnight.isAuthorized(address(almProxy), SETTER_RATIFIER));
    }

    function test_unauthorizedRatifierCannotBeSubstituted() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);
        buy.ratifier = makeAddr("rogueRatifier");

        _takeExpectRevert(
            buy,
            seedUnits / 4,
            abi.encodeWithSignature("RatifierUnauthorized()")
        );
    }

    function test_makeDisableLeavesTheTakerPathWorking() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        vm.prank(Ethereum.SPARK_PROXY);
        mainnetController.midnight_setMakeConfig(market, 0);

        _takeExpectRevert(buy, seedUnits / 4, "MidnightFacet/make-not-enabled");

        uint256 creditBefore = _credit();

        _seedCredit();

        assertEq(_credit(), creditBefore + seedUnits);
    }

}
