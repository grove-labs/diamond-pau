// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Ethereum } from "../../lib/spark-address-registry/src/Ethereum.sol";

import { Market, MidnightUtils, Offer } from "../../src/facets/midnight/MidnightUtils.sol";

import { MidnightRatifier }     from "../../src/periphery/MidnightRatifier.sol";
import { ProxyFundingStrategy } from "../../src/periphery/ProxyFundingStrategy.sol";

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

    uint256 internal quoterKey = 0xB0B;

    address internal quoter;

    MidnightRatifier     internal ourRatifier;
    ProxyFundingStrategy internal strategy;

    bytes32 internal strategyKey;

    uint256 internal maxOfferSize;

    function setUp() public virtual override {
        super.setUp();

        quoter = vm.addr(quoterKey);

        ourRatifier = new MidnightRatifier(
            Ethereum.SPARK_PROXY,
            MIDNIGHT,
            address(almProxy),
            address(mainnetController),
            address(rateLimits),
            quoter,
            MAX_OFFER_WINDOW
        );

        strategy = new ProxyFundingStrategy(
            MIDNIGHT,
            address(almProxy),
            address(mainnetController)
        );

        maxOfferSize = 2 * seedUnits;
        strategyKey  = mainnetController.midnight_getStrategyRateLimitKey(
            address(strategy),
            marketId
        );

        vm.startPrank(Ethereum.SPARK_PROXY);
        mainnetController.midnight_setRatifierAuthorization(address(ourRatifier), true);
        mainnetController.midnight_setMakeConfig(market, maxOfferSize);
        mainnetController.midnight_setDesignatedGroups(marketId, BUY_GROUP, SELL_GROUP);
        rateLimits.setRateLimitData(strategyKey, rateLimit, rateLimit / 1 days);
        vm.stopPrank();

        vm.label(address(ourRatifier), "MidnightRatifier");
        vm.label(address(strategy),    "ProxyFundingStrategy");
    }

    /**********************************************************************************************/
    /*** Maker helpers                                                                          ***/
    /**********************************************************************************************/

    function _makerOffer(bool buy, uint256 tick, uint256 maxUnits)
        internal
        view
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
            callback                : buy ? address(strategy) : address(0),
            callbackData            : new bytes(0),
            receiverIfMakerIsSeller : buy ? address(0) : address(almProxy),
            ratifier                : address(ourRatifier),
            reduceOnly              : !buy,
            maxUnits                : uint128(maxUnits),
            maxAssets               : 0,
            continuousFeeCap        : MidnightUtils.continuousFeePerSecond(MAX_CONTINUOUS_FEE_CBPS)
        });
    }

    function _sign(Offer memory offer) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterKey, ourRatifier.digest(offer));

        return abi.encodePacked(r, s, v);
    }

    // The collateralized maker EOA the base fixture funds, so it can both buy and sell units.
    function _take(Offer memory offer, uint256 units)
        internal
        returns (uint256 buyerAssets, uint256 sellerAssets)
    {
        bytes memory ratifierData = _sign(offer);

        vm.prank(maker);
        return ITakeLike(MIDNIGHT).take(
            offer,
            ratifierData,
            units,
            maker,
            offer.buy ? maker : address(0),
            address(0),
            new bytes(0)
        );
    }

    function _takeExpectRevert(Offer memory offer, uint256 units, bytes memory reason) internal {
        bytes memory ratifierData = _sign(offer);

        vm.prank(maker);
        vm.expectRevert(reason);
        ITakeLike(MIDNIGHT).take(
            offer,
            ratifierData,
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

        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, units);

        ( uint256 buyerAssets, uint256 sellerAssets ) = _take(sell, units);

        assertEq(sellerAssets, _makerSellerAssets(units, MAKER_SELL_TICK));
        assertEq(buyerAssets,  _buyerAssets(units, MAKER_SELL_TICK));

        assertEq(_credit(),                            creditBefore - units);
        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore + sellerAssets);

        // Exit fills touch no controller code, so the entry meter is untouched.
        assertEq(rateLimits.getCurrentRateLimit(strategyKey), rateLimit);

        assertEq(midnight.consumed(address(almProxy), SELL_GROUP), units);

        /*** Entry leg ***/

        creditBefore  = _credit();
        balanceBefore = loanToken.balanceOf(address(almProxy));

        uint256 strategyLimitBefore = rateLimits.getCurrentRateLimit(strategyKey);
        uint256 buyLimitBefore      = rateLimits.getCurrentRateLimit(buyKey);

        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, units);

        ( buyerAssets, sellerAssets ) = _take(buy, units);

        assertEq(buyerAssets,  _makerBuyerAssets(units, MAKER_BUY_TICK));
        assertEq(sellerAssets, _sellerAssets(units, MAKER_BUY_TICK));

        assertEq(_credit(),                              creditBefore + units);
        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore - buyerAssets);

        assertEq(rateLimits.getCurrentRateLimit(strategyKey), strategyLimitBefore - buyerAssets);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),      buyLimitBefore      - buyerAssets);

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

    function test_makerBuy_partialFill() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        uint256 units = seedUnits / 4;

        ( uint256 buyerAssets, ) = _take(buy, units);

        assertEq(_credit(), units);

        assertEq(rateLimits.getCurrentRateLimit(strategyKey), rateLimit - buyerAssets);

        assertEq(midnight.consumed(address(almProxy), BUY_GROUP), units);

        ( uint256 moreAssets, ) = _take(buy, units);

        assertEq(_credit(), 2 * units);

        assertEq(
            rateLimits.getCurrentRateLimit(strategyKey),
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

        _takeExpectRevert(buy, seedUnits / 4, "MidnightRatifier/tick-above-max-buy");
    }

    function test_tighteningEntryYieldKillsRestingOffer() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        _take(buy, seedUnits / 4);

        _setYields(5_00, MAX_SELL_YIELD);

        _takeExpectRevert(buy, seedUnits / 4, "MidnightRatifier/buy-yield-too-low");
    }

    function test_tighteningExitFloorKillsRestingOffer() external {
        _seedCredit();

        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, seedUnits / 2);

        _take(sell, seedUnits / 4);

        _setYields(MIN_BUY_YIELD, 1);

        _takeExpectRevert(sell, seedUnits / 4, "MidnightRatifier/sell-yield-too-high");
    }

    function test_disablingMakeKillsRestingOffer() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        _take(buy, seedUnits / 4);

        vm.prank(Ethereum.SPARK_PROXY);
        mainnetController.midnight_setMakeConfig(market, 0);

        _takeExpectRevert(buy, seedUnits / 4, "MidnightRatifier/make-not-enabled");
    }

    // The ratifier refuses first, so a revoked strategy never reaches fundFill.
    function test_zeroingPairLimitRevokesStrategy() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        _take(buy, seedUnits / 4);

        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(strategyKey, 0, 0);

        _takeExpectRevert(buy, seedUnits / 4, "MidnightRatifier/strategy-not-authorized");
    }

    function test_rotatingQuoterKillsRestingOffer() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        _take(buy, seedUnits / 4);

        vm.prank(Ethereum.SPARK_PROXY);
        ourRatifier.setQuoter(makeAddr("newQuoter"));

        _takeExpectRevert(buy, seedUnits / 4, "MidnightRatifier/invalid-signature");
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

        assertTrue(midnight.isAuthorized(address(almProxy), address(ourRatifier)));

        vm.prank(Ethereum.SPARK_PROXY);
        mainnetController.midnight_setRatifierAuthorization(address(ourRatifier), false);

        assertFalse(midnight.isAuthorized(address(almProxy), address(ourRatifier)));

        bytes memory unauthorized = abi.encodeWithSignature("RatifierUnauthorized()");

        _takeExpectRevert(buy,  seedUnits / 8, unauthorized);
        _takeExpectRevert(sell, seedUnits / 8, unauthorized);
    }

    // The authorization is total, so the set of addresses holding it is the whole blast radius.
    function test_onlyTheRatifierIsAuthorized() external view {
        address[8] memory others = [
            address(strategy),
            address(mainnetController),
            address(almProxy),
            address(rateLimits),
            SETTER_RATIFIER,
            quoter,
            maker,
            Ethereum.SPARK_PROXY
        ];

        for (uint256 i; i < others.length; ++i) {
            assertFalse(midnight.isAuthorized(address(almProxy), others[i]));
        }

        assertTrue(midnight.isAuthorized(address(almProxy), address(ourRatifier)));
    }

    function test_unauthorizedRatifierCannotBeSubstituted() external {
        MidnightRatifier rogue = new MidnightRatifier(
            Ethereum.SPARK_PROXY,
            MIDNIGHT,
            address(almProxy),
            address(mainnetController),
            address(rateLimits),
            quoter,
            MAX_OFFER_WINDOW
        );

        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);
        buy.ratifier = address(rogue);

        _takeExpectRevert(
            buy,
            seedUnits / 4,
            abi.encodeWithSignature("RatifierUnauthorized()")
        );
    }

}
