// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "../../lib/forge-std/src/interfaces/IERC20.sol";

import { ReentrancyGuard } from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { Ethereum } from "../../lib/spark-address-registry/src/Ethereum.sol";

import { IMidnightFacet } from "../../src/facets/midnight/IMidnightFacet.sol";

import {
    CollateralParams,
    Market,
    MidnightUtils,
    Offer
} from "../../src/facets/midnight/MidnightUtils.sol";

import { ForkTestBase } from "./ForkTestBase.t.sol";

// The parts of the singleton the tests drive directly or read, most of which the facet never calls.
interface IMidnightLike {

    function configurator() external view returns (address);
    function setFeeSetter(address newFeeSetter) external;
    function setMarketSettlementFee(bytes32 id, uint256 index, uint256 newSettlementFee) external;
    function setMarketContinuousFee(bytes32 id, uint256 newContinuousFee) external;
    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external;
    function isAuthorized(address authorizer, address authorized) external view returns (bool);

    function touchMarket(Market memory market) external returns (bytes32);

    function supplyCollateral(
        Market memory market,
        uint256 collateralIndex,
        uint256 assets,
        address onBehalf
    ) external;

    function repay(
        Market memory market,
        uint256 units,
        address onBehalf,
        address callback,
        bytes memory data
    ) external;

    function liquidate(
        Market memory market,
        uint256 collateralIndex,
        uint256 seizedAssets,
        uint256 repaidUnits,
        address borrower,
        bool    postMaturityMode,
        address receiver,
        address callback,
        bytes memory data
    ) external returns (uint256, uint256);

    function toMarket(bytes32 id) external view returns (Market memory);

    function updatePositionView(Market memory market, bytes32 id, address user)
        external
        view
        returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee);

    function consumed(address user, bytes32 group) external view returns (uint128);
    function debt(bytes32 id, address user) external view returns (uint128);
    function withdrawable(bytes32 id) external view returns (uint128);
    function lossFactor(bytes32 id) external view returns (uint128);
    function continuousFee(bytes32 id) external view returns (uint32);
    function settlementFee(bytes32 id, uint256 timeToMaturity) external view returns (uint256);

}

interface ISetterRatifierLike {

    function setIsRootRatified(address maker, bytes32 root, bool newIsRootRatified) external;

}

// Midnight reads `price()` as the loan-token value of one collateral token, scaled by 1e36.
contract MockOracle {

    uint256 public price;

    constructor(uint256 price_) {
        price = price_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

}

// Test-local port of Midnight's ratifier HashLib, needed to ratify an offer on the deployed
// SetterRatifier: a single-offer tree has the offer hash as its root and an empty proof.
// https://github.com/morpho-org/midnight/blob/70607569ac348e9880b512ffd3b574be55405932/src/ratifiers/libraries/HashLib.sol
library MidnightHashLib {

    bytes32 internal constant COLLATERAL_PARAMS_TYPEHASH =
        0x39ed3f928d24fd00574b1a02aba9c2483abcf5d9a3a366118c9a5aa29885b841;
    bytes32 internal constant MARKET_TYPEHASH =
        0x510b3862f3816a109c9340b76972e8a30984246be06e034ae12ed2934220391a;
    bytes32 internal constant OFFER_TYPEHASH =
        0x9905214264a9fb7b6cc1b0e33db7a04687c6e4185a84755d29914314aa9d8906;

    function hashMarket(Market memory market) internal pure returns (bytes32) {
        bytes32[] memory collateralParamsHashes = new bytes32[](market.collateralParams.length);

        for (uint256 i = 0; i < market.collateralParams.length; i++) {
            CollateralParams memory params = market.collateralParams[i];

            collateralParamsHashes[i] = keccak256(abi.encode(
                COLLATERAL_PARAMS_TYPEHASH,
                params.token,
                params.lltv,
                params.liquidationCursor,
                params.oracle
            ));
        }

        return keccak256(abi.encode(
            MARKET_TYPEHASH,
            market.chainId,
            market.midnight,
            market.loanToken,
            keccak256(abi.encodePacked(collateralParamsHashes)),
            market.maturity,
            market.rcfThreshold,
            market.enterGate,
            market.liquidatorGate
        ));
    }

    // Every field is a static type, so the encoding is the concatenation of the two halves.
    function hashOffer(Offer memory offer) internal pure returns (bytes32) {
        return keccak256(bytes.concat(
            abi.encode(
                OFFER_TYPEHASH,
                hashMarket(offer.market),
                offer.buy,
                offer.maker,
                offer.start,
                offer.expiry,
                offer.tick,
                offer.group
            ),
            abi.encode(
                offer.callback,
                keccak256(offer.callbackData),
                offer.receiverIfMakerIsSeller,
                offer.ratifier,
                offer.reduceOnly,
                offer.maxUnits,
                offer.maxAssets,
                offer.continuousFeeCap
            )
        ));
    }

}

abstract contract Midnight_TestBase is ForkTestBase {

    // https://docs.morpho.org/get-started/resources/addresses/#morpho-midnight
    address internal constant SETTER_RATIFIER = 0xb72c416382c8A6399D0765CebfB032F040B00B3c;

    // Live mainnet markets at the pinned block, from GET /v0/midnight/markets?chain_ids=1.
    bytes32 internal constant LIVE_MARKET_ID_1 =
        0xb21ce1d6ad577ee45d09d0a9934f658e65603ff7f1ac5958a7bf12dbfa560b24;
    bytes32 internal constant LIVE_MARKET_ID_2 =
        0x9ac6a639ace1c291b68b212eb1a95fd080332793f7bfc7dbed58b92bc518ca70;
    bytes32 internal constant LIVE_MARKET_ID_3 =
        0x2a9ae59053a64e409e819d3b76750948e06065b3164278915eb80cb1b7474b65;

    // Both tiers are enabled on the mainnet singleton at the fork block.
    uint256 internal constant LLTV               = 0.86e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;

    // Offer ticks have to be multiples of the market's tick spacing (4 by default). The price
    // curve is logistic in the tick: tickToPrice(3372) == 0.5e18 and it rises towards par.
    uint16 internal constant TICK_98 = 4152;  // ~0.98
    uint16 internal constant TICK_99 = 4384;  // ~0.99

    // Midnight stores the continuous fee per second and caps it at one percent a year, which the
    // config names as an annual rate in centi-basis points.
    uint32 internal constant MAX_CONTINUOUS_FEE      = uint32(uint256(0.01e18) / uint256(365 days));
    uint16 internal constant MAX_CONTINUOUS_FEE_CBPS = 1_00_00;

    // Basis points a year. Both rails are live in every suite: at the 180 day term the entry floor
    // allows anything up to ~0.995 and the exit ceiling anything down to ~0.953, so the tick
    // bounds are what bind on the happy paths.
    uint16 internal constant MIN_BUY_YIELD  = 1_00;
    uint16 internal constant MAX_SELL_YIELD = 10_00;

    // Multiple of Midnight's fee granularity (1e12) and under the cap of every breakpoint it is
    // written to; set flat across the 90 to 360 day breakpoints so a warp cannot move it.
    uint256 internal constant SETTLEMENT_FEE = 0.001e18;

    // Upstream's ceiling for the shortest breakpoint, which is the one a matured market resolves to.
    uint256 internal constant SETTLEMENT_FEE_0_DAYS_CAP = 0.000014e18;

    uint256 internal constant MATURITY_PERIOD = 180 days;

    uint256 internal constant COLLATERAL_SUPPLY = 10_000_000e18;  // WETH, valued 1:1 with the loan

    IMidnightLike       internal midnight = IMidnightLike(MIDNIGHT);
    ISetterRatifierLike internal ratifier = ISetterRatifierLike(SETTER_RATIFIER);

    IERC20     internal loanToken;
    IERC20     internal weth = IERC20(Ethereum.WETH);
    MockOracle internal oracle;

    address internal maker      = makeAddr("maker");
    address internal liquidator = makeAddr("liquidator");

    Market  internal market;
    bytes32 internal marketId;

    bytes32 internal buyKey;
    bytes32 internal sellKey;
    bytes32 internal redeemKey;

    uint256 internal loanUnit;
    uint256 internal rateLimit;     // 5m loan tokens on each of the three keys
    uint256 internal proxyBalance;  // 10m loan tokens
    uint256 internal seedUnits;     // 1m units, the position the exit suites start from

    uint256 internal offerNonce;

    function _loanToken() internal pure virtual returns (address) {
        return Ethereum.USDC;
    }

    function setUp() public virtual override {
        super.setUp();

        loanToken = IERC20(_loanToken());
        loanUnit  = 10 ** loanToken.decimals();

        rateLimit    = 5_000_000  * loanUnit;
        proxyBalance = 10_000_000 * loanUnit;
        seedUnits    = 1_000_000  * loanUnit;

        oracle = new MockOracle(1e36 * loanUnit / 1e18);

        // Assigned field by field because solc cannot copy an array of structs into storage.
        market.chainId   = block.chainid;
        market.midnight  = MIDNIGHT;
        market.loanToken = address(loanToken);
        market.maturity  = block.timestamp + MATURITY_PERIOD;

        market.collateralParams.push(CollateralParams({
            token             : address(weth),
            lltv              : LLTV,
            liquidationCursor : LIQUIDATION_CURSOR,
            oracle            : address(oracle)
        }));

        marketId = midnight.touchMarket(market);

        // The maker is the counterparty for every fill: collateralized so it can sell units, and
        // ratifying through the deployed SetterRatifier rather than a test double.
        deal(address(loanToken), maker, 100_000_000 * loanUnit);
        deal(address(weth),      maker, COLLATERAL_SUPPLY);

        vm.startPrank(maker);
        midnight.setIsAuthorized(SETTER_RATIFIER, true, maker);
        loanToken.approve(MIDNIGHT, type(uint256).max);
        weth.approve(MIDNIGHT, type(uint256).max);
        midnight.supplyCollateral(market, 0, COLLATERAL_SUPPLY, maker);
        vm.stopPrank();

        deal(address(loanToken), address(almProxy), proxyBalance);

        buyKey    = mainnetController.midnight_getBuyRateLimitKey(marketId);
        sellKey   = mainnetController.midnight_getSellRateLimitKey(marketId);
        redeemKey = mainnetController.midnight_getRedeemRateLimitKey(marketId);

        vm.startPrank(Ethereum.SPARK_PROXY);

        rateLimits.setRateLimitData(buyKey,    rateLimit, rateLimit / 1 days);
        rateLimits.setRateLimitData(sellKey,   rateLimit, rateLimit / 1 days);
        rateLimits.setRateLimitData(redeemKey, rateLimit, rateLimit / 1 days);

        mainnetController.midnight_setMarketConfig(
            marketId,
            TICK_99,
            TICK_98,
            MIN_BUY_YIELD,
            MAX_SELL_YIELD,
            MAX_CONTINUOUS_FEE_CBPS,
            0
        );

        vm.stopPrank();
    }

    function _getBlock() internal pure override returns (uint256) {
        return 25970000;  // September 2026 (Midnight live on mainnet since July 2026)
    }

    /**********************************************************************************************/
    /*** Offer helpers                                                                          ***/
    /**********************************************************************************************/

    // Consumed capacity is tracked per (maker, group), so each offer gets its own group.
    function _offer(bool buy, uint256 tick, uint256 maxUnits) internal returns (Offer memory offer) {
        offer = Offer({
            market                  : market,
            buy                     : buy,
            maker                   : maker,
            start                   : 0,
            expiry                  : block.timestamp + 1 days,
            tick                    : tick,
            group                   : bytes32(++offerNonce),
            callback                : address(0),
            callbackData            : new bytes(0),
            // Midnight rejects a non-zero receiver on the leg where the maker is not the seller.
            receiverIfMakerIsSeller : buy ? address(0) : maker,
            ratifier                : SETTER_RATIFIER,
            reduceOnly              : false,
            maxUnits                : uint128(maxUnits),
            maxAssets               : 0,
            continuousFeeCap        : type(uint256).max
        });

        _ratify(offer);
    }

    function _ratify(Offer memory offer) internal {
        vm.prank(offer.maker);
        ratifier.setIsRootRatified(offer.maker, MidnightHashLib.hashOffer(offer), true);
    }

    function _ratifierData(Offer memory offer) internal pure returns (bytes memory) {
        return abi.encode(MidnightHashLib.hashOffer(offer), uint256(0), new bytes32[](0));
    }

    function _fill(Offer memory offer, uint256 units)
        internal
        pure
        returns (IMidnightFacet.Fill memory)
    {
        return IMidnightFacet.Fill({
            offer        : offer,
            ratifierData : _ratifierData(offer),
            units        : units
        });
    }

    function _batch(Offer memory offer, uint256 units)
        internal
        pure
        returns (IMidnightFacet.Fill[] memory fills)
    {
        fills    = new IMidnightFacet.Fill[](1);
        fills[0] = _fill(offer, units);
    }

    /**********************************************************************************************/
    /*** Controller helpers                                                                     ***/
    /**********************************************************************************************/

    function _buy(Offer memory offer, uint256 units, uint256 maxAssetsIn)
        internal
        returns (uint256)
    {
        vm.prank(allocator);
        return mainnetController.midnight_buy(marketId, _batch(offer, units), maxAssetsIn);
    }

    function _sell(Offer memory offer, uint256 units, uint256 minAssetsOut)
        internal
        returns (uint256)
    {
        vm.prank(allocator);
        return mainnetController.midnight_sell(marketId, _batch(offer, units), minAssetsOut);
    }

    function _redeem(uint256 units, uint256 minAssetsOut) internal returns (uint256) {
        vm.prank(allocator);
        return mainnetController.midnight_redeem(marketId, units, minAssetsOut);
    }

    function _setConfig(
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  maxContinuousFee,
        uint128 maxLossFactor
    )
        internal
    {
        _setConfig(
            maxBuyTick, minSellTick, MIN_BUY_YIELD, MAX_SELL_YIELD, maxContinuousFee, maxLossFactor
        );
    }

    function _setConfig(
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  minBuyYield,
        uint16  maxSellYield,
        uint16  maxContinuousFee,
        uint128 maxLossFactor
    )
        internal
    {
        vm.prank(Ethereum.SPARK_PROXY);
        mainnetController.midnight_setMarketConfig(
            marketId,
            maxBuyTick,
            minSellTick,
            minBuyYield,
            maxSellYield,
            maxContinuousFee,
            maxLossFactor
        );
    }

    function _setYields(uint16 minBuyYield, uint16 maxSellYield) internal {
        _setConfig(TICK_99, TICK_98, minBuyYield, maxSellYield, MAX_CONTINUOUS_FEE_CBPS, 0);
    }

    // Buys units into the proxy at TICK_98 with no fees, so the exit paths have a position.
    function _seedCredit() internal returns (uint256 assetsSpent) {
        return _buy(_offer(false, TICK_98, seedUnits), seedUnits, type(uint256).max);
    }

    /**********************************************************************************************/
    /*** Protocol helpers                                                                       ***/
    /**********************************************************************************************/

    // The fee setter is unset on mainnet; the configurator can appoint one.
    function _becomeFeeSetter() internal {
        vm.prank(midnight.configurator());
        midnight.setFeeSetter(address(this));
    }

    function _setSettlementFee(uint256 fee) internal {
        _becomeFeeSetter();

        midnight.setMarketSettlementFee(marketId, 4, fee);
        midnight.setMarketSettlementFee(marketId, 5, fee);
        midnight.setMarketSettlementFee(marketId, 6, fee);
    }

    function _setContinuousFee(uint256 fee) internal {
        _becomeFeeSetter();

        midnight.setMarketContinuousFee(marketId, fee);
    }

    function _repay(uint256 units) internal {
        vm.prank(maker);
        midnight.repay(market, units, maker, address(0), "");
    }

    // Craters the collateral price and liquidates repaying and seizing nothing, which writes the
    // maker's bad debt off against every lender. The price then recovers; the loss does not.
    function _slash() internal {
        oracle.setPrice(oracle.price() / 100);

        vm.prank(liquidator);
        midnight.liquidate(market, 0, 0, 0, maker, false, liquidator, address(0), "");

        oracle.setPrice(oracle.price() * 100);
    }

    function _credit() internal view returns (uint256 credit) {
        ( credit, , ) = midnight.updatePositionView(market, marketId, address(almProxy));
    }

    function _timeToMaturity() internal view returns (uint256) {
        return market.maturity > block.timestamp ? market.maturity - block.timestamp : 0;
    }

    function _settlementFee() internal view returns (uint256) {
        return midnight.settlementFee(marketId, _timeToMaturity());
    }

    // Midnight's settlement arithmetic. Taking a sell offer: the taker pays the tick price plus
    // the fee rounded up and the maker receives the tick price rounded up. Taking a buy offer:
    // the taker receives the tick price less the fee rounded down and the maker pays the tick
    // price rounded down. The fee is the difference and stays in the singleton.
    function _buyerAssets(uint256 units, uint256 tick) internal view returns (uint256) {
        return _divUp(units * (MidnightUtils.tickToPrice(tick) + _settlementFee()), 1e18);
    }

    function _makerSellerAssets(uint256 units, uint256 tick) internal pure returns (uint256) {
        return _divUp(units * MidnightUtils.tickToPrice(tick), 1e18);
    }

    function _sellerAssets(uint256 units, uint256 tick) internal view returns (uint256) {
        return units * (MidnightUtils.tickToPrice(tick) - _settlementFee()) / 1e18;
    }

    function _makerBuyerAssets(uint256 units, uint256 tick) internal pure returns (uint256) {
        return units * MidnightUtils.tickToPrice(tick) / 1e18;
    }

    function _divUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x + y - 1) / y;
    }

}

contract MainnetController_Midnight_Utils_Tests is Midnight_TestBase {

    // The vendored structs must hash to the same id the singleton derives, or every market
    // check in the facet is silently wrong. The live ids are the oracle for the struct layout.
    function test_toId_matchesLiveMarkets() public view {
        assertEq(MidnightUtils.toId(midnight.toMarket(LIVE_MARKET_ID_1)), LIVE_MARKET_ID_1);
        assertEq(MidnightUtils.toId(midnight.toMarket(LIVE_MARKET_ID_2)), LIVE_MARKET_ID_2);
        assertEq(MidnightUtils.toId(midnight.toMarket(LIVE_MARKET_ID_3)), LIVE_MARKET_ID_3);
    }

    function test_toId_liveMarketsBindToVenue() public view {
        assertEq(midnight.toMarket(LIVE_MARKET_ID_1).midnight, MIDNIGHT);
        assertEq(midnight.toMarket(LIVE_MARKET_ID_1).chainId,  1);
    }

    function test_toId_matchesTestMarket() public view {
        assertEq(MidnightUtils.toId(market), marketId);
    }

    function test_midnight() public view {
        assertEq(mainnetController.midnight_midnight(), MIDNIGHT);
    }

}

// NOTE: Only testing USDC for non-rate-limit failures as the revert path is asset-agnostic.

contract MainnetController_Midnight_Buy_Tests is Midnight_TestBase {

    function test_buyMidnight_reentrancy() external {
        _setControllerEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        mainnetController.midnight_buy(marketId, new IMidnightFacet.Fill[](0), 1);
    }

    function test_buyMidnight_notAllocator() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            ALLOCATOR_ROLE
        ));
        mainnetController.midnight_buy(marketId, new IMidnightFacet.Fill[](0), 1);
    }

    function test_buyMidnight_buyNotEnabled() external {
        _setConfig(0, TICK_98, MAX_CONTINUOUS_FEE_CBPS, 0);

        Offer memory offer = _offer(false, TICK_98, seedUnits);

        vm.expectRevert("MidnightFacet/buy-not-enabled");
        _buy(offer, seedUnits, type(uint256).max);
    }

    function test_buyMidnight_zeroMaxAssetsIn() external {
        Offer memory offer = _offer(false, TICK_98, seedUnits);

        vm.expectRevert("MidnightFacet/max-assets-in-not-set");
        _buy(offer, seedUnits, 0);
    }

    function test_buyMidnight_emptyBatch() external {
        vm.expectRevert("MidnightFacet/empty-batch");
        vm.prank(allocator);
        mainnetController.midnight_buy(marketId, new IMidnightFacet.Fill[](0), 1);
    }

    function test_buyMidnight_invalidMidnight() external {
        Offer memory offer = _offer(false, TICK_98, seedUnits);
        offer.market.midnight = makeAddr("otherMidnight");

        vm.expectRevert("MidnightFacet/invalid-midnight");
        _buy(offer, seedUnits, type(uint256).max);
    }

    function test_buyMidnight_marketMismatch() external {
        Offer memory offer = _offer(false, TICK_98, seedUnits);
        offer.market.maturity += 1 days;

        vm.expectRevert("MidnightFacet/market-mismatch");
        _buy(offer, seedUnits, type(uint256).max);
    }

    // A fabricated term past WAD / continuousFee would underflow the yield bound, so binding the
    // market to the id has to happen before that bound is computed, not just in the take loop.
    function test_buyMidnight_marketMismatchBeyondFeeHorizon() external {
        _setContinuousFee(MAX_CONTINUOUS_FEE);

        Offer memory offer = _offer(false, TICK_98, seedUnits);
        offer.market.maturity = block.timestamp + 1e18 / MAX_CONTINUOUS_FEE + 1;

        vm.expectRevert("MidnightFacet/market-mismatch");
        _buy(offer, seedUnits, type(uint256).max);
    }

    function test_buyMidnight_invalidOfferDirection() external {
        Offer memory offer = _offer(true, TICK_98, seedUnits);

        vm.expectRevert("MidnightFacet/invalid-offer-direction");
        _buy(offer, seedUnits, type(uint256).max);
    }

    function test_buyMidnight_zeroUnits() external {
        Offer memory offer = _offer(false, TICK_98, seedUnits);

        vm.expectRevert("MidnightFacet/zero-units");
        _buy(offer, 0, type(uint256).max);
    }

    function test_buyMidnight_invalidOfferReceiver() external {
        Offer memory offer = _offer(false, TICK_98, seedUnits);
        offer.receiverIfMakerIsSeller = address(almProxy);

        vm.expectRevert("MidnightFacet/invalid-offer-receiver");
        _buy(offer, seedUnits, type(uint256).max);
    }

    // The deployed SetterRatifier is in the loop: an offer the maker never flagged does not fill.
    function test_buyMidnight_unratifiedOffer() external {
        Offer memory offer = _offer(false, TICK_98, seedUnits);
        offer.group = "never-ratified";

        vm.expectRevert(abi.encodeWithSignature("NotRatified()"));
        _buy(offer, seedUnits, type(uint256).max);
    }

    // A brand new market has to be touched once on Midnight, by anyone, before its fee resolves.
    function test_buyMidnight_untouchedMarket() external {
        Offer memory offer = _offer(false, TICK_98, seedUnits);
        offer.market.maturity += 1 days;

        marketId = MidnightUtils.toId(offer.market);

        _setConfig(TICK_99, TICK_98, MAX_CONTINUOUS_FEE_CBPS, 0);

        vm.expectRevert(abi.encodeWithSignature("MarketNotCreated()"));
        _buy(offer, seedUnits, type(uint256).max);
    }

    // Midnight refuses to let a seller take on new debt after maturity, so a maker who would have
    // to borrow to fill cannot be taken from.
    function test_buyMidnight_postMaturity() external {
        vm.warp(market.maturity + 1);

        Offer memory offer = _offer(false, TICK_98, seedUnits);

        vm.expectRevert(abi.encodeWithSignature("CannotIncreaseDebtPostMaturity()"));
        _buy(offer, seedUnits, type(uint256).max);
    }

    // The block is on the seller's debt increasing, not on maturity itself, so a maker who already
    // holds credit can still sell it after maturity. Twin of the test above, differing only in
    // whether the maker has credit of their own.
    function test_buyMidnight_postMaturityMakerHoldsCredit() external {
        _seedCredit();
        _repay(seedUnits);

        // Hand the maker credit, so selling it back nets against credit rather than creating debt.
        _sell(_offer(true, TICK_99, seedUnits), seedUnits, 1);

        vm.warp(market.maturity + 1);

        uint256 creditBefore = _credit();

        _buy(_offer(false, TICK_98, seedUnits), seedUnits, type(uint256).max);

        assertEq(_credit(), creditBefore + seedUnits);
    }

    function test_buyMidnight_zeroMaxAmount() external {
        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(buyKey, 0, 0);

        Offer memory offer = _offer(false, TICK_98, seedUnits);

        vm.expectRevert("RateLimits/zero-maxAmount");
        _buy(offer, seedUnits, type(uint256).max);
    }

    // One more unit rounds the spend up by one loan token wei, the smallest possible overshoot.
    function test_buyMidnight_usdc_rateLimitedBoundary() external {
        uint256 limit = _buyerAssets(seedUnits, TICK_98);

        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(buyKey, limit, limit / 1 days);

        Offer memory offer = _offer(false, TICK_98, seedUnits + 1);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        _buy(offer, seedUnits + 1, type(uint256).max);

        _buy(_offer(false, TICK_98, seedUnits), seedUnits, type(uint256).max);
    }

    // The config names an annual rate while the market stores a per second one, so the guard binds
    // on the converted value. Held off the ceiling so the market can be moved either side of it.
    function test_buyMidnight_usdc_continuousFeeBoundary() external {
        uint16  cap    = MAX_CONTINUOUS_FEE_CBPS / 2;
        uint256 perSec = MidnightUtils.continuousFeePerSecond(cap);

        _setConfig(TICK_99, TICK_98, cap, 0);
        _setContinuousFee(perSec + 1);

        Offer memory offer = _offer(false, TICK_98, seedUnits);

        vm.expectRevert("MidnightFacet/continuous-fee-too-high");
        _buy(offer, seedUnits, type(uint256).max);

        _setContinuousFee(perSec);

        _buy(_offer(false, TICK_98, seedUnits), seedUnits, type(uint256).max);
    }

    function test_buyMidnight_usdc_lossFactorBoundary() external {
        _seedCredit();
        _slash();

        uint128 lossFactor = midnight.lossFactor(marketId);

        // The write-down is what makes the rest of the test meaningful.
        assertGt(lossFactor, 0);

        Offer memory offer = _offer(false, TICK_98, seedUnits);

        vm.expectRevert("MidnightFacet/loss-factor-too-high");
        _buy(offer, seedUnits, type(uint256).max);

        _setConfig(TICK_99, TICK_98, MAX_CONTINUOUS_FEE_CBPS, lossFactor - 1);

        vm.expectRevert("MidnightFacet/loss-factor-too-high");
        _buy(offer, seedUnits, type(uint256).max);

        _setConfig(TICK_99, TICK_98, MAX_CONTINUOUS_FEE_CBPS, lossFactor);

        _buy(offer, seedUnits, type(uint256).max);
    }

    // The ceiling binds on the all-in cost, so a maxBuyTick priced under the fee leaves nothing
    // fillable. At the lowest tick that clears it, only offers priced at zero fit and the proxy
    // pays the fee alone.
    function test_buyMidnight_usdc_maxBuyTickBelowFeeBoundary() external {
        _setSettlementFee(SETTLEMENT_FEE);

        uint16 tick = 0;
        while (MidnightUtils.tickToPrice(tick) < SETTLEMENT_FEE) tick++;

        _setConfig(tick - 1, TICK_98, MAX_CONTINUOUS_FEE_CBPS, 0);

        Offer memory offer = _offer(false, 0, seedUnits);

        vm.expectRevert("MidnightFacet/buy-price-too-high");
        _buy(offer, seedUnits, type(uint256).max);

        _setConfig(tick, TICK_98, MAX_CONTINUOUS_FEE_CBPS, 0);

        _buy(_offer(false, 0, seedUnits), seedUnits, type(uint256).max);
    }

    // The tick bound is on the all-in price, so a live fee pushes the highest fillable offer
    // below the configured tick.
    function test_buyMidnight_usdc_buyPriceTooHighBoundary() external {
        _setSettlementFee(SETTLEMENT_FEE);

        uint256 bound = MidnightUtils.tickToPrice(TICK_99) - SETTLEMENT_FEE;

        uint256 tick = TICK_99;
        while (MidnightUtils.tickToPrice(tick) > bound) tick -= 4;

        Offer memory offer = _offer(false, tick + 4, seedUnits);

        vm.expectRevert("MidnightFacet/buy-price-too-high");
        _buy(offer, seedUnits, type(uint256).max);

        _buy(_offer(false, tick, seedUnits), seedUnits, type(uint256).max);
    }

    // The yield floor is on the all-in price too, so a live fee pushes the highest fillable offer
    // below the price the floor on its own would allow.
    function test_buyMidnight_usdc_buyYieldTooLowBoundary() external {
        _setSettlementFee(SETTLEMENT_FEE);
        _setYields(4_00, MAX_SELL_YIELD);

        uint256 bound =
            MidnightUtils.maxBuyPrice(4_00, _timeToMaturity(), 0) - SETTLEMENT_FEE;

        uint256 tick = TICK_99;
        while (MidnightUtils.tickToPrice(tick) > bound) tick -= 4;

        Offer memory offer = _offer(false, tick + 4, seedUnits);

        vm.expectRevert("MidnightFacet/buy-yield-too-low");
        _buy(offer, seedUnits, type(uint256).max);

        _buy(_offer(false, tick, seedUnits), seedUnits, type(uint256).max);
    }

    // The floor is measured on what a unit returns, so the continuous fee it will pay over the
    // remaining term comes out of the price the same floor allows.
    function test_buyMidnight_usdc_buyYieldNetsContinuousFee() external {
        _setYields(4_00, MAX_SELL_YIELD);

        _buy(_offer(false, TICK_98, seedUnits), seedUnits, type(uint256).max);

        _setContinuousFee(MAX_CONTINUOUS_FEE);

        Offer memory offer = _offer(false, TICK_98, seedUnits);

        vm.expectRevert("MidnightFacet/buy-yield-too-low");
        _buy(offer, seedUnits, type(uint256).max);
    }

    // The bound doubles as the allowance, so Midnight's pull fails before the facet's own check.
    function test_buyMidnight_usdc_maxAssetsInBoundary() external {
        uint256 expected = _buyerAssets(seedUnits, TICK_98);

        Offer memory offer = _offer(false, TICK_98, seedUnits);

        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        _buy(offer, seedUnits, expected - 1);

        _buy(offer, seedUnits, expected);
    }

    function test_buyMidnight_usdc() external {
        _setSettlementFee(SETTLEMENT_FEE);

        uint256 expected     = _buyerAssets(seedUnits, TICK_98);
        uint256 makerAssets  = _makerSellerAssets(seedUnits, TICK_98);
        uint256 makerBalance = loanToken.balanceOf(maker);
        uint256 venueBalance = loanToken.balanceOf(MIDNIGHT);

        Offer memory offer = _offer(false, TICK_98, seedUnits);

        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
        assertEq(loanToken.balanceOf(address(almProxy)),           proxyBalance);
        assertEq(loanToken.balanceOf(maker),                       makerBalance);
        assertEq(loanToken.balanceOf(MIDNIGHT),                    venueBalance);
        assertEq(_credit(),                                        0);
        assertEq(midnight.debt(marketId, address(almProxy)),       0);
        assertEq(midnight.consumed(maker, offer.group),            0);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),           rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),          rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),        rateLimit);

        vm.record();

        vm.expectEmit(address(mainnetController));
        emit IMidnightFacet.MidnightBuy(marketId, seedUnits, expected);

        assertEq(_buy(offer, seedUnits, type(uint256).max), expected);

        _assertReentrancyGuardWrittenToTwice();

        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
        assertEq(loanToken.balanceOf(address(almProxy)),           proxyBalance - expected);
        assertEq(loanToken.balanceOf(maker),                       makerBalance + makerAssets);
        assertEq(loanToken.balanceOf(MIDNIGHT),                    venueBalance + expected - makerAssets);
        assertEq(_credit(),                                        seedUnits);
        assertEq(midnight.debt(marketId, address(almProxy)),       0);
        assertEq(midnight.consumed(maker, offer.group),            seedUnits);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),           rateLimit - expected);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),          rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),        rateLimit);
    }

    function test_buyMidnight_usdc_batch() external {
        uint256 units1 = seedUnits;
        uint256 units2 = seedUnits / 2;

        uint256 expected = _buyerAssets(units1, TICK_98) + _buyerAssets(units2, TICK_99);

        IMidnightFacet.Fill[] memory fills = new IMidnightFacet.Fill[](2);

        fills[0] = _fill(_offer(false, TICK_98, units1), units1);
        fills[1] = _fill(_offer(false, TICK_99, units2), units2);

        vm.expectEmit(address(mainnetController));
        emit IMidnightFacet.MidnightBuy(marketId, units1 + units2, expected);

        vm.prank(allocator);
        uint256 assetsSpent = mainnetController.midnight_buy(marketId, fills, expected);

        assertEq(assetsSpent,                                      expected);
        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
        assertEq(loanToken.balanceOf(address(almProxy)),           proxyBalance - expected);
        assertEq(_credit(),                                        units1 + units2);
        assertEq(midnight.consumed(maker, fills[0].offer.group),   units1);
        assertEq(midnight.consumed(maker, fills[1].offer.group),   units2);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),           rateLimit - expected);
    }

    function test_buyMidnight_usdc_unlimitedRateLimit() external {
        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setUnlimitedRateLimitData(buyKey);

        _buy(_offer(false, TICK_98, seedUnits), seedUnits, type(uint256).max);

        assertEq(_credit(),                              seedUnits);
        assertEq(rateLimits.getCurrentRateLimit(buyKey), type(uint256).max);
    }

}

contract MainnetController_Midnight_Sell_Tests is Midnight_TestBase {

    uint256 internal seedSpent;

    function setUp() public override {
        super.setUp();

        seedSpent = _seedCredit();
    }

    function test_sellMidnight_reentrancy() external {
        _setControllerEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        mainnetController.midnight_sell(marketId, new IMidnightFacet.Fill[](0), 1);
    }

    function test_sellMidnight_notAllocator() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            ALLOCATOR_ROLE
        ));
        mainnetController.midnight_sell(marketId, new IMidnightFacet.Fill[](0), 1);
    }

    // A non-zero minSellTick is what marks a market as onboarded, so only an unconfigured id
    // trips this.
    function test_sellMidnight_sellNotEnabled() external {
        marketId = keccak256("not-onboarded");

        Offer memory offer = _offer(true, TICK_99, seedUnits);

        vm.expectRevert("MidnightFacet/sell-not-enabled");
        _sell(offer, seedUnits, 1);
    }

    function test_sellMidnight_zeroMinAssetsOut() external {
        Offer memory offer = _offer(true, TICK_99, seedUnits);

        vm.expectRevert("MidnightFacet/min-assets-out-not-set");
        _sell(offer, seedUnits, 0);
    }

    function test_sellMidnight_emptyBatch() external {
        vm.expectRevert("MidnightFacet/empty-batch");
        vm.prank(allocator);
        mainnetController.midnight_sell(marketId, new IMidnightFacet.Fill[](0), 1);
    }

    function test_sellMidnight_invalidMidnight() external {
        Offer memory offer = _offer(true, TICK_99, seedUnits);
        offer.market.midnight = makeAddr("otherMidnight");

        vm.expectRevert("MidnightFacet/invalid-midnight");
        _sell(offer, seedUnits, 1);
    }

    function test_sellMidnight_marketMismatch() external {
        Offer memory offer = _offer(true, TICK_99, seedUnits);
        offer.market.maturity += 1 days;

        vm.expectRevert("MidnightFacet/market-mismatch");
        _sell(offer, seedUnits, 1);
    }

    function test_sellMidnight_invalidOfferDirection() external {
        Offer memory offer = _offer(false, TICK_99, seedUnits);

        vm.expectRevert("MidnightFacet/invalid-offer-direction");
        _sell(offer, seedUnits, 1);
    }

    function test_sellMidnight_zeroUnits() external {
        Offer memory offer = _offer(true, TICK_99, seedUnits);

        vm.expectRevert("MidnightFacet/zero-units");
        _sell(offer, 0, 1);
    }

    function test_sellMidnight_zeroMaxAmount() external {
        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(sellKey, 0, 0);

        Offer memory offer = _offer(true, TICK_99, seedUnits);

        vm.expectRevert("RateLimits/zero-maxAmount");
        _sell(offer, seedUnits, 1);
    }

    // Two more units are worth just over one loan token wei at this price, the smallest overshoot
    // that survives Midnight's round-down.
    function test_sellMidnight_usdc_rateLimitedBoundary() external {
        uint256 units = seedUnits / 2;
        uint256 limit = _sellerAssets(units, TICK_99);

        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(sellKey, limit, limit / 1 days);

        Offer memory offer = _offer(true, TICK_99, units + 2);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        _sell(offer, units + 2, 1);

        _sell(_offer(true, TICK_99, units), units, 1);
    }

    // The tick floor is on the net price, so a live fee pushes the lowest fillable offer above
    // the configured tick.
    function test_sellMidnight_usdc_sellPriceTooLowBoundary() external {
        _setSettlementFee(SETTLEMENT_FEE);

        uint256 bound = MidnightUtils.tickToPrice(TICK_98) + SETTLEMENT_FEE;

        uint256 tick = TICK_98;
        while (MidnightUtils.tickToPrice(tick) < bound) tick += 4;

        Offer memory offer = _offer(true, tick - 4, seedUnits);

        vm.expectRevert("MidnightFacet/sell-price-too-low");
        _sell(offer, seedUnits, 1);

        _sell(_offer(true, tick, seedUnits), seedUnits, 1);
    }

    // The yield ceiling is on the proceeds, so a live fee pushes the lowest fillable offer above
    // the price the ceiling on its own would allow.
    function test_sellMidnight_usdc_sellYieldTooHighBoundary() external {
        _setSettlementFee(SETTLEMENT_FEE);
        _setYields(MIN_BUY_YIELD, 2_00);

        uint256 bound =
            MidnightUtils.minSellPrice(2_00, _timeToMaturity(), 0) + SETTLEMENT_FEE;

        uint256 tick = TICK_98;
        while (MidnightUtils.tickToPrice(tick) < bound) tick += 4;

        Offer memory offer = _offer(true, tick - 4, seedUnits);

        vm.expectRevert("MidnightFacet/sell-yield-too-high");
        _sell(offer, seedUnits, 1);

        _sell(_offer(true, tick, seedUnits), seedUnits, 1);
    }

    function test_sellMidnight_usdc_minAssetsOutBoundary() external {
        uint256 expected = _sellerAssets(seedUnits, TICK_99);

        Offer memory offer = _offer(true, TICK_99, seedUnits);

        vm.expectRevert("MidnightFacet/min-assets-out-not-met");
        _sell(offer, seedUnits, expected + 1);

        _sell(offer, seedUnits, expected);
    }

    // With a live settlement fee the exit closes completely past maturity: the floor is par and the
    // fee is added on top, so not even a par offer clears. Redemption still pays par, which is why
    // no discounted escape hatch is needed.
    function test_sellMidnight_usdc_postMaturitySettlementFee() external {
        _becomeFeeSetter();
        midnight.setMarketSettlementFee(marketId, 0, SETTLEMENT_FEE_0_DAYS_CAP);

        vm.warp(market.maturity + 1);

        Offer memory atPar = _offer(true, MidnightUtils.MAX_TICK, seedUnits);

        vm.expectRevert("MidnightFacet/sell-yield-too-high");
        _sell(atPar, seedUnits, 1);

        _repay(seedUnits);

        assertEq(_redeem(seedUnits, seedUnits), seedUnits);
        assertEq(_credit(),                     0);
    }

    // Exiting still works after maturity, but only at par: with no term left, any discount hands
    // over unbounded yield against a redemption that pays par, so the yield ceiling refuses it.
    function test_sellMidnight_usdc_postMaturity() external {
        vm.warp(market.maturity + 1);

        Offer memory discounted = _offer(true, TICK_99, seedUnits);

        vm.expectRevert("MidnightFacet/sell-yield-too-high");
        _sell(discounted, seedUnits, 1);

        uint256 expected = _sellerAssets(seedUnits, MidnightUtils.MAX_TICK);

        assertEq(
            _sell(_offer(true, MidnightUtils.MAX_TICK, seedUnits), seedUnits, expected),
            expected
        );

        assertEq(_credit(),                              0);
        assertEq(rateLimits.getCurrentRateLimit(sellKey), rateLimit - expected);
    }

    // An oversized ask is clamped to the live position instead of turning into naked debt.
    // Credit decays every block once a continuous fee is live, so a batch sized from a stale read
    // has to be trimmed to the live balance rather than turned into debt.
    function test_sellMidnight_usdc_creditDecaysWithContinuousFee() external {
        _setContinuousFee(MAX_CONTINUOUS_FEE);

        // Bought with the fee live, so this tranche carries a pendingFee the seeded one does not.
        _seedCredit();

        uint256 held = 2 * seedUnits;

        assertEq(_credit(), held);

        vm.warp(block.timestamp + _timeToMaturity() / 2);

        assertLt(_credit(), held);

        // Ask with the pre-decay figure; only what is left may be filled.
        _sell(_offer(true, MidnightUtils.MAX_TICK, held), held, 1);

        assertEq(_credit(),                                  0);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
    }

    function test_sellMidnight_usdc_unitsCappedAtCredit() external {
        uint256 expected = _sellerAssets(seedUnits, TICK_99);

        Offer memory offer = _offer(true, TICK_99, 2 * seedUnits);

        vm.expectEmit(address(mainnetController));
        emit IMidnightFacet.MidnightSell(marketId, seedUnits, expected);

        assertEq(_sell(offer, 2 * seedUnits, expected), expected);

        assertEq(_credit(),                                  0);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
    }

    // Once credit runs out the rest of the batch is skipped rather than filled with debt.
    function test_sellMidnight_usdc_batchStopsWhenCreditRunsOut() external {
        uint256 expected = _sellerAssets(seedUnits, TICK_99);

        IMidnightFacet.Fill[] memory fills = new IMidnightFacet.Fill[](2);

        fills[0] = _fill(_offer(true, TICK_99, seedUnits), seedUnits);
        fills[1] = _fill(_offer(true, TICK_99, seedUnits), seedUnits);

        vm.expectEmit(address(mainnetController));
        emit IMidnightFacet.MidnightSell(marketId, seedUnits, expected);

        vm.prank(allocator);
        uint256 assetsReceived = mainnetController.midnight_sell(marketId, fills, expected);

        assertEq(assetsReceived,                                 expected);
        assertEq(_credit(),                                      0);
        assertEq(midnight.debt(marketId, address(almProxy)),     0);
        assertEq(midnight.consumed(maker, fills[0].offer.group), seedUnits);
        assertEq(midnight.consumed(maker, fills[1].offer.group), 0);
    }

    // An offer left unreachable once credit is exhausted must not gate the batch, even when its
    // price sits outside the rails: the rails guard taking, and this one is never taken.
    function test_sellMidnight_usdc_unreachableOfferOutsideRailsIsSkipped() external {
        uint256 expected = _sellerAssets(seedUnits, TICK_99);

        IMidnightFacet.Fill[] memory fills = new IMidnightFacet.Fill[](2);

        fills[0] = _fill(_offer(true, TICK_99, seedUnits), seedUnits);
        fills[1] = _fill(_offer(true, 3000,    seedUnits), seedUnits);

        vm.prank(allocator);
        uint256 assetsReceived = mainnetController.midnight_sell(marketId, fills, expected);

        assertEq(assetsReceived,                                 expected);
        assertEq(_credit(),                                      0);
        assertEq(midnight.consumed(maker, fills[0].offer.group), seedUnits);
        assertEq(midnight.consumed(maker, fills[1].offer.group), 0);
    }

    // Offers may cap on assets instead of units. The clamp bounds our credit, not the maker's asset
    // budget, so an ask that overruns it is rejected by Midnight rather than trimmed to fit.
    function test_sellMidnight_usdc_assetsBasedOfferNotTrimmed() external {
        uint256 fullAssets = _sellerAssets(seedUnits, TICK_99);

        Offer memory offer = _offer(true, TICK_99, seedUnits);

        offer.maxUnits  = 0;
        offer.maxAssets = uint128(fullAssets / 2);

        _ratify(offer);

        vm.expectRevert(abi.encodeWithSignature("ConsumedAssets()"));
        _sell(offer, seedUnits, 1);

        // Sized to the budget it clears, so the cap is the maker's, not a facet limitation.
        assertEq(_sell(offer, seedUnits / 2, 1), fullAssets / 2);
    }

    // Slashing writes the position down, so the credit delta is measured against the new balance.
    function test_sellMidnight_usdc_afterSlashing() external {
        _slash();

        uint256 slashedCredit = _credit();

        assertLt(slashedCredit, seedUnits);

        uint256 expected = _sellerAssets(slashedCredit, TICK_99);

        assertEq(_sell(_offer(true, TICK_99, seedUnits), seedUnits, expected), expected);

        assertEq(_credit(),                                  0);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
    }

    function test_sellMidnight_usdc() external {
        _setSettlementFee(SETTLEMENT_FEE);

        uint256 units        = seedUnits / 2;
        uint256 expected     = _sellerAssets(units, TICK_99);
        uint256 makerAssets  = _makerBuyerAssets(units, TICK_99);
        uint256 makerBalance = loanToken.balanceOf(maker);
        uint256 venueBalance = loanToken.balanceOf(MIDNIGHT);

        Offer memory offer = _offer(true, TICK_99, units);

        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
        assertEq(loanToken.balanceOf(address(almProxy)),           proxyBalance - seedSpent);
        assertEq(loanToken.balanceOf(maker),                       makerBalance);
        assertEq(loanToken.balanceOf(MIDNIGHT),                    venueBalance);
        assertEq(_credit(),                                        seedUnits);
        assertEq(midnight.debt(marketId, address(almProxy)),       0);
        assertEq(midnight.consumed(maker, offer.group),            0);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),           rateLimit - seedSpent);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),          rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),        rateLimit);

        vm.record();

        vm.expectEmit(address(mainnetController));
        emit IMidnightFacet.MidnightSell(marketId, units, expected);

        assertEq(_sell(offer, units, expected), expected);

        _assertReentrancyGuardWrittenToTwice();

        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
        assertEq(loanToken.balanceOf(address(almProxy)),           proxyBalance - seedSpent + expected);
        assertEq(loanToken.balanceOf(maker),                       makerBalance - makerAssets);
        assertEq(loanToken.balanceOf(MIDNIGHT),                    venueBalance + makerAssets - expected);
        assertEq(_credit(),                                        seedUnits - units);
        assertEq(midnight.debt(marketId, address(almProxy)),       0);
        assertEq(midnight.consumed(maker, offer.group),            units);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),           rateLimit - seedSpent + expected);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),          rateLimit - expected);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),        rateLimit);
    }

    function test_sellMidnight_usdc_zeroBuyRateLimit() external {
        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(buyKey, 0, 0);

        uint256 expected = _sellerAssets(seedUnits, TICK_99);

        assertEq(_sell(_offer(true, TICK_99, seedUnits), seedUnits, expected), expected);

        // The restore is skipped when no buy limit is set, never blocking the exit.
        assertEq(rateLimits.getCurrentRateLimit(buyKey),  0);
        assertEq(rateLimits.getCurrentRateLimit(sellKey), rateLimit - expected);
    }

    function test_sellMidnight_usdc_unlimitedRateLimit() external {
        vm.startPrank(Ethereum.SPARK_PROXY);
        rateLimits.setUnlimitedRateLimitData(buyKey);
        rateLimits.setUnlimitedRateLimitData(sellKey);
        vm.stopPrank();

        uint256 expected = _sellerAssets(seedUnits, TICK_99);

        assertEq(_sell(_offer(true, TICK_99, seedUnits), seedUnits, expected), expected);

        assertEq(_credit(),                               0);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),  type(uint256).max);
        assertEq(rateLimits.getCurrentRateLimit(sellKey), type(uint256).max);
    }

}

contract MainnetController_Midnight_Redeem_Tests is Midnight_TestBase {

    uint256 internal seedSpent;

    function setUp() public override {
        super.setUp();

        seedSpent = _seedCredit();
    }

    function test_redeemMidnight_reentrancy() external {
        _setControllerEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        mainnetController.midnight_redeem(marketId, seedUnits, 1);
    }

    function test_redeemMidnight_notAllocator() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            ALLOCATOR_ROLE
        ));
        mainnetController.midnight_redeem(marketId, seedUnits, 1);
    }

    function test_redeemMidnight_marketNotOnboarded() external {
        vm.expectRevert("MidnightFacet/market-not-onboarded");
        vm.prank(allocator);
        mainnetController.midnight_redeem(keccak256("not-onboarded"), seedUnits, 1);
    }

    function test_redeemMidnight_zeroMinAssetsOut() external {
        vm.expectRevert("MidnightFacet/min-assets-out-not-set");
        _redeem(seedUnits, 0);
    }

    // Nothing has been repaid yet, so nothing is withdrawable.
    function test_redeemMidnight_zeroUnits() external {
        vm.expectRevert("MidnightFacet/zero-units");
        _redeem(seedUnits, 1);
    }

    function test_redeemMidnight_zeroMaxAmount() external {
        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(redeemKey, 0, 0);

        _repay(seedUnits);

        vm.expectRevert("RateLimits/zero-maxAmount");
        _redeem(seedUnits, 1);
    }

    function test_redeemMidnight_usdc_rateLimitedBoundary() external {
        uint256 limit = seedUnits / 2;

        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(redeemKey, limit, limit / 1 days);

        _repay(seedUnits);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        _redeem(limit + 1, 1);

        _redeem(limit, 1);
    }

    function test_redeemMidnight_usdc_minAssetsOutBoundary() external {
        _repay(seedUnits);

        vm.expectRevert("MidnightFacet/min-assets-out-not-met");
        _redeem(seedUnits, seedUnits + 1);

        _redeem(seedUnits, seedUnits);
    }

    // Redemption comes out of repayments, so the ask is clamped to what has been repaid so far.
    function test_redeemMidnight_usdc_cappedAtWithdrawable() external {
        uint256 repaid = seedUnits / 4;

        _repay(repaid);

        vm.expectEmit(address(mainnetController));
        emit IMidnightFacet.MidnightRedeem(marketId, repaid, repaid);

        assertEq(_redeem(type(uint256).max, repaid), repaid);

        assertEq(_credit(),                       seedUnits - repaid);
        assertEq(midnight.withdrawable(marketId), 0);
    }

    // With more repaid than the proxy holds, the ask is clamped to the live position instead.
    function test_redeemMidnight_usdc_cappedAtCredit() external {
        uint256 sold = seedUnits / 2;

        // Repaid in full first, so the units sold back leave the maker as a fellow lender rather
        // than cancelling its debt, and the pool covers more than our credit.
        _repay(seedUnits);
        _sell(_offer(true, TICK_99, sold), sold, 1);

        assertGt(midnight.withdrawable(marketId), _credit());

        assertEq(_redeem(type(uint256).max, seedUnits - sold), seedUnits - sold);

        assertEq(_credit(),                                  0);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
    }

    function test_redeemMidnight_usdc_postMaturity() external {
        vm.warp(market.maturity + 1);

        _repay(seedUnits);

        assertEq(_redeem(seedUnits, seedUnits), seedUnits);

        assertEq(_credit(), 0);
    }

    function test_redeemMidnight_usdc_afterSlashing() external {
        _slash();

        uint256 slashedCredit = _credit();

        assertLt(slashedCredit, seedUnits);

        _repay(slashedCredit);

        assertEq(_redeem(seedUnits, slashedCredit), slashedCredit);

        assertEq(_credit(), 0);
    }

    function test_redeemMidnight_usdc() external {
        uint256 units        = seedUnits / 2;
        uint256 makerBalance = loanToken.balanceOf(maker);
        uint256 venueBalance = loanToken.balanceOf(MIDNIGHT);

        _repay(units);

        assertEq(loanToken.balanceOf(address(almProxy)),     proxyBalance - seedSpent);
        assertEq(loanToken.balanceOf(maker),                 makerBalance - units);
        assertEq(loanToken.balanceOf(MIDNIGHT),              venueBalance + units);
        assertEq(_credit(),                                  seedUnits);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
        assertEq(midnight.withdrawable(marketId),            units);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),     rateLimit - seedSpent);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),    rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),  rateLimit);

        vm.record();

        vm.expectEmit(address(mainnetController));
        emit IMidnightFacet.MidnightRedeem(marketId, units, units);

        assertEq(_redeem(units, units), units);

        _assertReentrancyGuardWrittenToTwice();

        assertEq(loanToken.balanceOf(address(almProxy)),     proxyBalance - seedSpent + units);
        assertEq(loanToken.balanceOf(maker),                 makerBalance - units);
        assertEq(loanToken.balanceOf(MIDNIGHT),              venueBalance);
        assertEq(_credit(),                                  seedUnits - units);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
        assertEq(midnight.withdrawable(marketId),            0);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),     rateLimit - seedSpent + units);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),    rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),  rateLimit - units);
    }

    function test_redeemMidnight_usdc_zeroBuyRateLimit() external {
        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(buyKey, 0, 0);

        _repay(seedUnits);

        assertEq(_redeem(seedUnits, seedUnits), seedUnits);

        // The restore is skipped when no buy limit is set, never blocking the exit.
        assertEq(rateLimits.getCurrentRateLimit(buyKey),    0);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey), rateLimit - seedUnits);
    }

    function test_redeemMidnight_usdc_unlimitedRateLimit() external {
        vm.startPrank(Ethereum.SPARK_PROXY);
        rateLimits.setUnlimitedRateLimitData(buyKey);
        rateLimits.setUnlimitedRateLimitData(redeemKey);
        vm.stopPrank();

        _repay(seedUnits);

        assertEq(_redeem(seedUnits, seedUnits), seedUnits);

        assertEq(_credit(),                                 0);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),    type(uint256).max);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey), type(uint256).max);
    }

}

contract MainnetController_Midnight_RoundTrip_Tests is Midnight_TestBase {

    // Buy, sell half back early, and redeem the rest at par once the maker repays: the proxy's
    // loan token balance closes to the cent against the vendored pricing.
    function test_midnight_usdc_roundTrip() external {
        _setSettlementFee(SETTLEMENT_FEE);

        uint256 sold = seedUnits / 2;

        uint256 spent    = _buyerAssets(seedUnits, TICK_98);
        uint256 received = _sellerAssets(sold, TICK_99);

        assertEq(_buy(_offer(false, TICK_98, seedUnits), seedUnits, spent), spent);
        assertEq(_sell(_offer(true, TICK_99, sold), sold, received),      received);

        // Selling to the maker cancelled half its debt; it repays the rest at maturity.
        vm.warp(market.maturity);

        _repay(seedUnits - sold);

        assertEq(_redeem(type(uint256).max, seedUnits - sold), seedUnits - sold);

        assertEq(loanToken.balanceOf(address(almProxy)),     proxyBalance - spent + received + seedUnits - sold);
        assertEq(_credit(),                                  0);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
        assertEq(midnight.debt(marketId, maker),             0);
    }

}

// Same flows against an 18-decimal loan token, since the fee and rounding arithmetic scale with
// the token.
contract MainnetController_Midnight_USDS_Tests is Midnight_TestBase {

    function _loanToken() internal pure override returns (address) {
        return Ethereum.USDS;
    }

    function test_buyMidnight_usds_rateLimitedBoundary() external {
        uint256 limit = _buyerAssets(seedUnits, TICK_98);

        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(buyKey, limit, limit / 1 days);

        Offer memory offer = _offer(false, TICK_98, seedUnits + 1);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        _buy(offer, seedUnits + 1, type(uint256).max);

        _buy(_offer(false, TICK_98, seedUnits), seedUnits, type(uint256).max);
    }

    function test_buyMidnight_usds() external {
        _setSettlementFee(SETTLEMENT_FEE);

        uint256 expected     = _buyerAssets(seedUnits, TICK_98);
        uint256 makerAssets  = _makerSellerAssets(seedUnits, TICK_98);
        uint256 makerBalance = loanToken.balanceOf(maker);
        uint256 venueBalance = loanToken.balanceOf(MIDNIGHT);

        Offer memory offer = _offer(false, TICK_98, seedUnits);

        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
        assertEq(loanToken.balanceOf(address(almProxy)),           proxyBalance);
        assertEq(loanToken.balanceOf(maker),                       makerBalance);
        assertEq(loanToken.balanceOf(MIDNIGHT),                    venueBalance);
        assertEq(_credit(),                                        0);
        assertEq(midnight.debt(marketId, address(almProxy)),       0);
        assertEq(midnight.consumed(maker, offer.group),            0);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),           rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),          rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),        rateLimit);

        vm.record();

        vm.expectEmit(address(mainnetController));
        emit IMidnightFacet.MidnightBuy(marketId, seedUnits, expected);

        assertEq(_buy(offer, seedUnits, type(uint256).max), expected);

        _assertReentrancyGuardWrittenToTwice();

        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
        assertEq(loanToken.balanceOf(address(almProxy)),           proxyBalance - expected);
        assertEq(loanToken.balanceOf(maker),                       makerBalance + makerAssets);
        assertEq(loanToken.balanceOf(MIDNIGHT),                    venueBalance + expected - makerAssets);
        assertEq(_credit(),                                        seedUnits);
        assertEq(midnight.debt(marketId, address(almProxy)),       0);
        assertEq(midnight.consumed(maker, offer.group),            seedUnits);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),           rateLimit - expected);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),          rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),        rateLimit);
    }

    function test_sellMidnight_usds_rateLimitedBoundary() external {
        _seedCredit();

        uint256 units = seedUnits / 2;
        uint256 limit = _sellerAssets(units, TICK_99);

        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(sellKey, limit, limit / 1 days);

        Offer memory offer = _offer(true, TICK_99, units + 2);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        _sell(offer, units + 2, 1);

        _sell(_offer(true, TICK_99, units), units, 1);
    }

    function test_sellMidnight_usds() external {
        uint256 seedSpent = _seedCredit();

        _setSettlementFee(SETTLEMENT_FEE);

        uint256 units        = seedUnits / 2;
        uint256 expected     = _sellerAssets(units, TICK_99);
        uint256 makerAssets  = _makerBuyerAssets(units, TICK_99);
        uint256 makerBalance = loanToken.balanceOf(maker);
        uint256 venueBalance = loanToken.balanceOf(MIDNIGHT);

        Offer memory offer = _offer(true, TICK_99, units);

        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
        assertEq(loanToken.balanceOf(address(almProxy)),           proxyBalance - seedSpent);
        assertEq(loanToken.balanceOf(maker),                       makerBalance);
        assertEq(loanToken.balanceOf(MIDNIGHT),                    venueBalance);
        assertEq(_credit(),                                        seedUnits);
        assertEq(midnight.debt(marketId, address(almProxy)),       0);
        assertEq(midnight.consumed(maker, offer.group),            0);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),           rateLimit - seedSpent);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),          rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),        rateLimit);

        vm.record();

        vm.expectEmit(address(mainnetController));
        emit IMidnightFacet.MidnightSell(marketId, units, expected);

        assertEq(_sell(offer, units, expected), expected);

        _assertReentrancyGuardWrittenToTwice();

        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
        assertEq(loanToken.balanceOf(address(almProxy)),           proxyBalance - seedSpent + expected);
        assertEq(loanToken.balanceOf(maker),                       makerBalance - makerAssets);
        assertEq(loanToken.balanceOf(MIDNIGHT),                    venueBalance + makerAssets - expected);
        assertEq(_credit(),                                        seedUnits - units);
        assertEq(midnight.debt(marketId, address(almProxy)),       0);
        assertEq(midnight.consumed(maker, offer.group),            units);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),           rateLimit - seedSpent + expected);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),          rateLimit - expected);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),        rateLimit);
    }

    function test_redeemMidnight_usds_rateLimitedBoundary() external {
        _seedCredit();

        uint256 limit = seedUnits / 2;

        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(redeemKey, limit, limit / 1 days);

        _repay(seedUnits);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        _redeem(limit + 1, 1);

        _redeem(limit, 1);
    }

    function test_redeemMidnight_usds() external {
        uint256 seedSpent = _seedCredit();

        uint256 units        = seedUnits / 2;
        uint256 makerBalance = loanToken.balanceOf(maker);
        uint256 venueBalance = loanToken.balanceOf(MIDNIGHT);

        _repay(units);

        assertEq(loanToken.balanceOf(address(almProxy)),     proxyBalance - seedSpent);
        assertEq(loanToken.balanceOf(maker),                 makerBalance - units);
        assertEq(loanToken.balanceOf(MIDNIGHT),              venueBalance + units);
        assertEq(_credit(),                                  seedUnits);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
        assertEq(midnight.withdrawable(marketId),            units);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),     rateLimit - seedSpent);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),    rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),  rateLimit);

        vm.record();

        vm.expectEmit(address(mainnetController));
        emit IMidnightFacet.MidnightRedeem(marketId, units, units);

        assertEq(_redeem(units, units), units);

        _assertReentrancyGuardWrittenToTwice();

        assertEq(loanToken.balanceOf(address(almProxy)),     proxyBalance - seedSpent + units);
        assertEq(loanToken.balanceOf(maker),                 makerBalance - units);
        assertEq(loanToken.balanceOf(MIDNIGHT),              venueBalance);
        assertEq(_credit(),                                  seedUnits - units);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
        assertEq(midnight.withdrawable(marketId),            0);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),     rateLimit - seedSpent + units);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),    rateLimit);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),  rateLimit - units);
    }

}
