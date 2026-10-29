// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Ethereum } from "../../lib/spark-address-registry/src/Ethereum.sol";

import { Market, Offer } from "../../src/facets/midnight/MidnightInterfaces.sol";

import { MidnightUtils } from "../../src/facets/midnight/MidnightUtils.sol";

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

    bytes32 internal strategyBuyKey;
    bytes32 internal strategySellKey;

    uint256 internal maxOfferSize;

    function setUp() public virtual override {
        super.setUp();

        strategy = new MockFundingStrategy(MIDNIGHT, address(almProxy), address(mainnetController));

        maxOfferSize = 2 * seedUnits;

        vm.startPrank(Ethereum.SPARK_PROXY);
        mainnetController.midnight_setRatifierAuthorization(SETTER_RATIFIER, true);
        mainnetController.midnight_setMakeConfig(market, maxOfferSize);
        mainnetController.midnight_setDesignatedGroups(marketId, BUY_GROUP, SELL_GROUP);
        vm.stopPrank();

        ( strategyBuyKey, strategySellKey ) = _onboardStrategy(address(strategy));

        vm.label(address(strategy), "MockFundingStrategy");
    }

    function _onboardStrategy(address strategy_)
        internal
        returns (bytes32 buyKey_, bytes32 sellKey_)
    {
        buyKey_  = mainnetController.midnight_getStrategyBuyRateLimitKey(strategy_, marketId);
        sellKey_ = mainnetController.midnight_getStrategySellRateLimitKey(strategy_, marketId);

        vm.startPrank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(buyKey_,  rateLimit, rateLimit / 1 days);
        rateLimits.setRateLimitData(sellKey_, rateLimit, rateLimit / 1 days);
        vm.stopPrank();
    }

    /**********************************************************************************************/
    /*** Maker helpers                                                                          ***/
    /**********************************************************************************************/

    function _makerOffer(bool buy, uint256 tick, uint256 maxUnits)
        internal
        returns (Offer memory offer)
    {
        return _makerOffer(
            market, address(strategy), buy, tick, maxUnits, buy ? BUY_GROUP : SELL_GROUP
        );
    }

    function _makerOffer(
        Market  memory market_,
        address        callback,
        bool           buy,
        uint256        tick,
        uint256        maxUnits,
        bytes32        group
    )
        internal
        returns (Offer memory offer)
    {
        offer = Offer({
            market                  : market_,
            buy                     : buy,
            maker                   : address(almProxy),
            start                   : block.timestamp,
            expiry                  : block.timestamp + MAX_OFFER_WINDOW,
            tick                    : tick,
            group                   : group,
            callback                : callback,
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

        assertEq(rateLimits.getCurrentRateLimit(sellKey),         rateLimit - sellerAssets);
        assertEq(rateLimits.getCurrentRateLimit(strategySellKey), rateLimit - sellerAssets);

        // The exit leg debits its own meters and puts nothing back on the entry side.
        assertEq(rateLimits.getCurrentRateLimit(buyKey),         buyLimitBefore);
        assertEq(rateLimits.getCurrentRateLimit(strategyBuyKey), rateLimit);

        assertEq(midnight.consumed(address(almProxy), SELL_GROUP), units);

        uint256 exitAssets = sellerAssets;

        /*** Entry leg ***/

        creditBefore  = _credit();
        balanceBefore = loanToken.balanceOf(address(almProxy));

        buyLimitBefore = rateLimits.getCurrentRateLimit(buyKey);

        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, units);

        ( buyerAssets, sellerAssets ) = _take(buy, units);

        assertEq(buyerAssets,  _makerBuyerAssets(units, MAKER_BUY_TICK));
        assertEq(sellerAssets, _sellerAssets(units, MAKER_BUY_TICK));

        assertEq(_credit(),                              creditBefore + units);
        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore - buyerAssets);

        assertEq(rateLimits.getCurrentRateLimit(buyKey),          buyLimitBefore - buyerAssets);
        assertEq(rateLimits.getCurrentRateLimit(strategyBuyKey),  rateLimit - buyerAssets);
        assertEq(rateLimits.getCurrentRateLimit(strategySellKey), rateLimit - exitAssets);

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

        assertEq(rateLimits.getCurrentRateLimit(buyKey), rateLimit - buyerAssets);

        assertEq(midnight.consumed(address(almProxy), BUY_GROUP), units);

        ( uint256 moreAssets, ) = _take(buy, units);

        assertEq(_credit(), 2 * units);

        assertEq(
            rateLimits.getCurrentRateLimit(buyKey),
            rateLimit - buyerAssets - moreAssets
        );

        assertEq(midnight.consumed(address(almProxy), BUY_GROUP), 2 * units);
    }

    function test_makerBuy_offerCapExhausted() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        _take(buy, seedUnits);

        _takeExpectRevert(buy, 1, abi.encodeWithSignature("ConsumedUnits()"));
    }

    // The stand-in strategy refuses what the audited one refuses, so no test here leans on a
    // looser callback than production would run.
    function test_mockStrategy_mirrorsTheCallerAndPartyChecks() external {
        vm.expectRevert("MockFundingStrategy/not-midnight");
        strategy.onBuy(marketId, market, 1, 1, 0, address(almProxy), "");

        vm.expectRevert("MockFundingStrategy/not-midnight");
        strategy.onSell(marketId, market, 1, 1, 0, address(almProxy), address(almProxy), "");

        vm.startPrank(MIDNIGHT);

        vm.expectRevert("MockFundingStrategy/buyer-not-proxy");
        strategy.onBuy(marketId, market, 1, 1, 0, maker, "");

        vm.expectRevert("MockFundingStrategy/seller-not-proxy");
        strategy.onSell(marketId, market, 1, 1, 0, maker, address(almProxy), "");

        vm.expectRevert("MockFundingStrategy/receiver-not-proxy");
        strategy.onSell(marketId, market, 1, 1, 0, address(almProxy), maker, "");

        vm.stopPrank();
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

    function test_zeroingStrategyKeysRevokesBothLegs() external {
        _seedCredit();

        Offer memory buy  = _makerOffer(true,  MAKER_BUY_TICK,  seedUnits);
        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, seedUnits);

        uint256 units = seedUnits / 8;

        _take(buy,  units);
        _take(sell, units);

        vm.startPrank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(strategyBuyKey,  0, 0);
        rateLimits.setRateLimitData(strategySellKey, 0, 0);
        vm.stopPrank();

        assertFalse(mainnetController.midnight_isCallbackAllowed(marketId, address(strategy), true));
        assertFalse(mainnetController.midnight_isCallbackAllowed(marketId, address(strategy), false));

        _takeExpectRevert(buy,  units, "RateLimits/zero-maxAmount");
        _takeExpectRevert(sell, units, "RateLimits/zero-maxAmount");

        _onboardStrategy(address(strategy));

        _take(buy,  units);
        _take(sell, units);
    }

    // Each maker leg is bounded by the taker meter for its own direction, and by nothing else.
    function test_exhaustingADirectionLimitStopsThatLegOnly() external {
        _seedCredit();

        Offer memory buy  = _makerOffer(true,  MAKER_BUY_TICK,  seedUnits);
        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, seedUnits);

        uint256 units = seedUnits / 4;

        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(buyKey, 1, 0);

        _takeExpectRevert(buy, units, "RateLimits/rate-limit-exceeded");

        _take(sell, units);

        assertLt(rateLimits.getCurrentRateLimit(sellKey), rateLimit);

        // Exiting restored no entry room, so the buy leg is still stopped.
        _takeExpectRevert(buy, units, "RateLimits/rate-limit-exceeded");

        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(sellKey, 1, 0);

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

contract MainnetController_MidnightMaker_RateLimit_Tests is Midnight_Maker_TestBase {

    uint256 internal constant BUY        = 0;
    uint256 internal constant SELL       = 1;
    uint256 internal constant REDEEM     = 2;
    uint256 internal constant STRAT_BUY  = 3;
    uint256 internal constant STRAT_SELL = 4;

    function setUp() public override {
        super.setUp();

        // No slope, so every key only ever moves by what a leg spends.
        vm.startPrank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(buyKey,          rateLimit, 0);
        rateLimits.setRateLimitData(sellKey,         rateLimit, 0);
        rateLimits.setRateLimitData(redeemKey,       rateLimit, 0);
        rateLimits.setRateLimitData(strategyBuyKey,  rateLimit, 0);
        rateLimits.setRateLimitData(strategySellKey, rateLimit, 0);
        vm.stopPrank();
    }

    function _limits() internal view returns (uint256[5] memory limits) {
        limits[BUY]        = rateLimits.getCurrentRateLimit(buyKey);
        limits[SELL]       = rateLimits.getCurrentRateLimit(sellKey);
        limits[REDEEM]     = rateLimits.getCurrentRateLimit(redeemKey);
        limits[STRAT_BUY]  = rateLimits.getCurrentRateLimit(strategyBuyKey);
        limits[STRAT_SELL] = rateLimits.getCurrentRateLimit(strategySellKey);
    }

    function _assertSpent(uint256[5] memory before, uint256[5] memory spent) internal view {
        uint256[5] memory limits = _limits();

        for (uint256 i; i < 5; ++i) {
            assertEq(limits[i], before[i] - spent[i]);
        }
    }

    // Runs every leg once. The first round drains each key below its ceiling, where a stray
    // restore would be invisible, so only the second round's deltas are asserted.
    function _everyLeg(Offer memory makerBuy, Offer memory makerSell, bool check) internal {
        uint256 units = seedUnits / 16;

        uint256[5] memory before = _limits();
        uint256[5] memory spent;

        spent[BUY] = _buy(_offer(false, TICK_98, units), units, type(uint256).max);
        if (check) _assertSpent(before, spent);

        before = _limits();
        spent  = [uint256(0), 0, 0, 0, 0];

        spent[SELL] = _sell(_offer(true, TICK_99, units), units, 1);
        if (check) _assertSpent(before, spent);

        before = _limits();
        spent  = [uint256(0), 0, 0, 0, 0];

        _repay(units);
        spent[REDEEM] = _redeem(units, 1);
        if (check) _assertSpent(before, spent);

        before = _limits();
        spent  = [uint256(0), 0, 0, 0, 0];

        ( uint256 buyerAssets, ) = _take(makerBuy, units);
        spent[BUY]       = buyerAssets;
        spent[STRAT_BUY] = buyerAssets;
        if (check) _assertSpent(before, spent);

        before = _limits();
        spent  = [uint256(0), 0, 0, 0, 0];

        ( , uint256 sellerAssets ) = _take(makerSell, units);
        spent[SELL]       = sellerAssets;
        spent[STRAT_SELL] = sellerAssets;
        if (check) _assertSpent(before, spent);
    }

    // Takes and maker fills draw on one market budget per direction; only a maker fill also
    // draws on its strategy's key, and no leg touches a key of another direction or kind.
    function test_rateLimits_eachLegSpendsOnlyItsOwnKeys() external {
        _seedCredit();

        Offer memory makerBuy  = _makerOffer(true,  MAKER_BUY_TICK,  seedUnits);
        Offer memory makerSell = _makerOffer(false, MAKER_SELL_TICK, seedUnits);

        _everyLeg(makerBuy, makerSell, false);

        uint256[5] memory limits = _limits();

        for (uint256 i; i < 5; ++i) {
            assertLt(limits[i], rateLimit);
        }

        _everyLeg(makerBuy, makerSell, true);
    }

    function test_rateLimits_twoStrategiesOnOneMarketAreMeteredIndependently() external {
        MockFundingStrategy other =
            new MockFundingStrategy(MIDNIGHT, address(almProxy), address(mainnetController));

        ( bytes32 otherBuyKey, bytes32 otherSellKey ) = _onboardStrategy(address(other));

        vm.startPrank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(otherBuyKey,  rateLimit, 0);
        rateLimits.setRateLimitData(otherSellKey, rateLimit, 0);
        vm.stopPrank();

        Offer memory ours = _makerOffer(true, MAKER_BUY_TICK, seedUnits);
        Offer memory theirs =
            _makerOffer(market, address(other), true, MAKER_BUY_TICK, 2 * seedUnits, BUY_GROUP);

        ( uint256 oursAssets,   ) = _take(ours,   seedUnits / 8);
        ( uint256 theirsAssets, ) = _take(theirs, seedUnits / 4);

        assertEq(rateLimits.getCurrentRateLimit(strategyBuyKey), rateLimit - oursAssets);
        assertEq(rateLimits.getCurrentRateLimit(otherBuyKey),    rateLimit - theirsAssets);
        assertEq(rateLimits.getCurrentRateLimit(buyKey), rateLimit - oursAssets - theirsAssets);

        assertEq(rateLimits.getCurrentRateLimit(strategySellKey), rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(otherSellKey),    rateLimit);

        assertEq(midnight.consumed(address(almProxy), BUY_GROUP), 3 * seedUnits / 8);
    }

    // The strategy key is salted with the market, so onboarding on one market funds nothing on
    // another, even one sharing the loan token and every other piece of configuration.
    function test_rateLimits_strategyKeyCannotFundAnotherMarket() external {
        Market memory other = market;
        other.maturity += 30 days;

        bytes32 otherId = midnight.touchMarket(other);

        deal(address(weth), maker, COLLATERAL_SUPPLY);

        vm.prank(maker);
        midnight.supplyCollateral(other, 0, COLLATERAL_SUPPLY, maker);

        vm.startPrank(Ethereum.SPARK_PROXY);
        mainnetController.midnight_setMarketConfig(
            otherId, TICK_99, TICK_98, MIN_BUY_YIELD, MAX_SELL_YIELD, MAX_CONTINUOUS_FEE_CBPS, 0
        );
        mainnetController.midnight_setMakeConfig(other, maxOfferSize);
        mainnetController.midnight_setDesignatedGroups(
            otherId, keccak256("other.buy"), keccak256("other.sell")
        );
        rateLimits.setRateLimitData(
            mainnetController.midnight_getBuyRateLimitKey(otherId), rateLimit, 0
        );
        vm.stopPrank();

        assertFalse(mainnetController.midnight_isCallbackAllowed(otherId, address(strategy), true));

        Offer memory buy = _makerOffer(
            other, address(strategy), true, MAKER_BUY_TICK, seedUnits, keccak256("other.buy")
        );

        _takeExpectRevert(buy, seedUnits / 4, "RateLimits/zero-maxAmount");

        bytes32 otherStrategyBuyKey =
            mainnetController.midnight_getStrategyBuyRateLimitKey(address(strategy), otherId);

        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(otherStrategyBuyKey, rateLimit, 0);

        assertTrue(mainnetController.midnight_isCallbackAllowed(otherId, address(strategy), true));

        ( uint256 buyerAssets, ) = _take(buy, seedUnits / 4);

        assertEq(rateLimits.getCurrentRateLimit(otherStrategyBuyKey), rateLimit - buyerAssets);

        // The first market's keys paid for none of it.
        assertEq(rateLimits.getCurrentRateLimit(strategyBuyKey), rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),         rateLimit);
    }

    // A fill small enough to price at zero reaches the strategy with nothing to fund. It
    // short-circuits, so the proxy gains the dust credit without drawing on any key.
    function test_makerBuy_dustFillIsUnmetered() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        assertEq(_makerBuyerAssets(1, MAKER_BUY_TICK), 0);

        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));
        uint256[5] memory before = _limits();

        ( uint256 buyerAssets, uint256 sellerAssets ) = _take(buy, 1);

        assertEq(buyerAssets,  0);
        assertEq(sellerAssets, 0);

        assertEq(_credit(), 1);
        assertEq(midnight.consumed(address(almProxy), BUY_GROUP), 1);

        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore);
        assertEq(loanToken.balanceOf(address(strategy)), 0);

        _assertSpent(before, [uint256(0), 0, 0, 0, 0]);
    }

}
