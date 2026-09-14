// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ApproveLib } from "../../libraries/ApproveLib.sol";

import { makeBytes32Key } from "../../libraries/RateLimitHelpers.sol";

import { IALMProxy } from "../../interfaces/IALMProxy.sol";

import { IFacet } from "../IFacet.sol";

import { Facet } from "../Facet.sol";

import { IMidnightFacet } from "./IMidnightFacet.sol";

import { Market, MidnightUtils, Offer } from "./MidnightUtils.sol";

interface IMidnightLike {

    function take(
        Offer  memory offer,
        bytes  memory ratifierData,
        uint256       units,
        address       taker,
        address       receiverIfTakerIsSeller,
        address       takerCallback,
        bytes  memory takerCallbackData
    )
        external
        returns (uint256 buyerAssets, uint256 sellerAssets);

    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver)
        external;

    function updatePositionView(Market memory market, bytes32 id, address user)
        external
        view
        returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee);

    function toMarket(bytes32 id) external view returns (Market memory);

    function debt(bytes32 id, address user) external view returns (uint128);

    function withdrawable(bytes32 id) external view returns (uint128);

    function lossFactor(bytes32 id) external view returns (uint128);

    function continuousFee(bytes32 id) external view returns (uint32);

    function settlementFee(bytes32 id, uint256 timeToMaturity) external view returns (uint256);

}

interface IERC20Like {

    function balanceOf(address account) external view returns (uint256);

}

contract MidnightFacet is IMidnightFacet, Facet {

    /**********************************************************************************************/
    /*** Facet Storage Domain                                                                   ***/
    /**********************************************************************************************/

    /// @custom:storage-location erc7201:sky.pau.storage.MidnightFacet.v1
    struct FacetStorage {
        mapping (bytes32 marketId => MarketConfig config) marketConfigs;
    }

    // keccak256(abi.encode(uint256(keccak256("sky.pau.storage.MidnightFacet.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant FACET_STORAGE_LOCATION =
        0x339f0f518f1cb2ad517ff2e2a5b3fc6c879e84e8a54dba4e572a869461059b00;

    function _getFacetStorage() internal pure returns (FacetStorage storage $) {
        assembly {
            $.slot := FACET_STORAGE_LOCATION
        }
    }

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/

    // Per-call state kept in memory so buy and sell stay within the stack.
    struct TakeContext {
        address proxy;
        bytes32 marketId;
        Market  market;
        bool    selling;
        uint256 tickPriceBound;  // Fee-adjusted: a ceiling when buying, a floor when selling.
        uint256 creditCap;       // Sellable position, ignored when buying.
        uint256 creditBefore;
        uint256 balanceBefore;
        uint256 totalUnits;
    }

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    bytes32 internal constant _LIMIT_BUY    = keccak256("LIMIT_MIDNIGHT_BUY");
    bytes32 internal constant _LIMIT_REDEEM = keccak256("LIMIT_MIDNIGHT_REDEEM");
    bytes32 internal constant _LIMIT_SELL   = keccak256("LIMIT_MIDNIGHT_SELL");

    /// @inheritdoc IFacet
    string public constant override VERSION = "1.0.0";

    /**********************************************************************************************/
    /*** Declarations                                                                           ***/
    /**********************************************************************************************/

    /// @inheritdoc IMidnightFacet
    address public immutable override midnight;

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor(address midnight_) {
        require(midnight_ != address(0), "MidnightFacet/zero-midnight");

        midnight = midnight_;
    }

    /**********************************************************************************************/
    /*** External Interactive Admin Functions                                                   ***/
    /**********************************************************************************************/

    /// @inheritdoc IMidnightFacet
    function setMarketConfig(bytes32 marketId, MarketConfig calldata config)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // Both ticks feed tickToPrice, which reverts above MAX_TICK; a zero maxBuyTick is the kill
        // switch for entries, while a zero minSellTick means not onboarded and blocks every exit.
        require(config.maxBuyTick <= MidnightUtils.MAX_TICK, "MidnightFacet/max-buy-tick-oob");
        require(
            config.minSellTick != 0 && config.minSellTick <= MidnightUtils.MAX_TICK,
            "MidnightFacet/min-sell-tick-oob"
        );
        require(
            config.maxContinuousFee <= MidnightUtils.MAX_CONTINUOUS_FEE,
            "MidnightFacet/max-continuous-fee-oob"
        );

        _getFacetStorage().marketConfigs[marketId] = config;

        emit MidnightMarketConfigSet(
            marketId,
            config.maxBuyTick,
            config.minSellTick,
            config.maxContinuousFee,
            config.maxLossFactor
        );
    }

    /**********************************************************************************************/
    /*** External Interactive Allocator Functions                                               ***/
    /**********************************************************************************************/

    /// @inheritdoc IMidnightFacet
    function buy(
        bytes32            marketId,
        Offer[]   calldata offers,
        bytes[]   calldata ratifierData,
        uint256[] calldata units,
        uint256            maxAssetsIn
    )
        external
        override
        nonReentrant
        onlyRole(ALLOCATOR_ROLE)
        returns (uint256 assetsSpent)
    {
        MarketConfig storage config = _getFacetStorage().marketConfigs[marketId];

        require(config.maxBuyTick != 0, "MidnightFacet/buy-not-enabled");
        require(maxAssetsIn != 0,       "MidnightFacet/max-assets-in-not-set");

        _validateBatch(offers.length, ratifierData.length, units.length);

        TakeContext memory ctx = _takeContext(marketId, offers[0].market, false);

        // Entering crystallizes the continuous fee over the remaining term, so it is checked up
        // front. A non-zero loss factor means this market's lenders have already been slashed.
        require(
            IMidnightLike(midnight).continuousFee(marketId) <= config.maxContinuousFee,
            "MidnightFacet/continuous-fee-too-high"
        );
        require(
            IMidnightLike(midnight).lossFactor(marketId) <= config.maxLossFactor,
            "MidnightFacet/loss-factor-too-high"
        );

        // The bound is on the all-in price, so the settlement fee is reserved out of it up front.
        {
            uint256 maxPrice = MidnightUtils.tickToPrice(config.maxBuyTick);
            uint256 fee      = _settlementFee(marketId, ctx.market.maturity);

            require(maxPrice >= fee, "MidnightFacet/max-buy-tick-below-fee");

            ctx.tickPriceBound = maxPrice - fee;
        }

        // The proxy is Midnight's payer for the whole batch.
        ApproveLib.approve(ctx.market.loanToken, ctx.proxy, midnight, maxAssetsIn);

        _takeBatch(ctx, offers, ratifierData, units);

        // Clear the approval in case Midnight did not pull the full amount.
        ApproveLib.approve(ctx.market.loanToken, ctx.proxy, midnight, 0);

        // Measure the loan token actually paid rather than trusting the take return values.
        assetsSpent = ctx.balanceBefore - IERC20Like(ctx.market.loanToken).balanceOf(ctx.proxy);

        require(assetsSpent <= maxAssetsIn, "MidnightFacet/max-assets-in-exceeded");

        // The proxy never holds debt, so a buy increases credit by exactly the units taken.
        require(
            _credit(ctx.market, marketId, ctx.proxy) == ctx.creditBefore + ctx.totalUnits,
            "MidnightFacet/credit-delta-mismatch"
        );

        _requireDebtFree(marketId, ctx.proxy);

        _decreaseRateLimit(getBuyRateLimitKey(marketId), assetsSpent);

        emit MidnightBuy(marketId, ctx.totalUnits, assetsSpent);
    }

    /// @inheritdoc IMidnightFacet
    function redeem(bytes32 marketId, uint256 units, uint256 minAssetsOut)
        external
        override
        nonReentrant
        onlyRole(ALLOCATOR_ROLE)
        returns (uint256 assetsWithdrawn)
    {
        // Redemption reads no config value, but an onboarded config is what authenticates the id.
        require(
            _getFacetStorage().marketConfigs[marketId].minSellTick != 0,
            "MidnightFacet/market-not-onboarded"
        );

        address proxy = _getSharedControllerStorage().proxy;

        Market memory market = IMidnightLike(midnight).toMarket(marketId);

        // Redemption is at par out of repayments, so units are capped by both sides of the pool.
        uint256 credit       = _credit(market, marketId, proxy);
        uint256 withdrawable = IMidnightLike(midnight).withdrawable(marketId);

        if (units > credit)       units = credit;
        if (units > withdrawable) units = withdrawable;

        require(units != 0, "MidnightFacet/zero-units");

        uint256 balanceBefore = IERC20Like(market.loanToken).balanceOf(proxy);

        IALMProxy(proxy).doCall(
            midnight,
            abi.encodeCall(IMidnightLike.withdraw, (market, units, proxy, proxy))
        );

        // Measure the loan token actually received rather than trusting the units requested.
        assetsWithdrawn = IERC20Like(market.loanToken).balanceOf(proxy) - balanceBefore;

        require(assetsWithdrawn >= minAssetsOut, "MidnightFacet/min-assets-out-not-met");

        _requireDebtFree(marketId, proxy);

        _decreaseRateLimit(getRedeemRateLimitKey(marketId), assetsWithdrawn);

        // Restores entry capacity by the assets returned; skipped when no buy limit is set.
        _tryIncreaseRateLimit(getBuyRateLimitKey(marketId), assetsWithdrawn);

        emit MidnightRedeem(marketId, units, assetsWithdrawn);
    }

    /// @inheritdoc IMidnightFacet
    function sell(
        bytes32            marketId,
        Offer[]   calldata offers,
        bytes[]   calldata ratifierData,
        uint256[] calldata units,
        uint256            minAssetsOut
    )
        external
        override
        nonReentrant
        onlyRole(ALLOCATOR_ROLE)
        returns (uint256 assetsReceived)
    {
        MarketConfig storage config = _getFacetStorage().marketConfigs[marketId];

        require(config.minSellTick != 0, "MidnightFacet/sell-not-enabled");
        require(minAssetsOut != 0,       "MidnightFacet/min-assets-out-not-set");

        _validateBatch(offers.length, ratifierData.length, units.length);

        TakeContext memory ctx = _takeContext(marketId, offers[0].market, true);

        // Selling receives the tick price less the settlement fee, so the fee is added onto the
        // bound.
        ctx.tickPriceBound =
            MidnightUtils.tickToPrice(config.minSellTick)
            + _settlementFee(marketId, ctx.market.maturity);

        ctx.creditCap = ctx.creditBefore;

        _takeBatch(ctx, offers, ratifierData, units);

        // Measure the loan token actually received rather than trusting the take return values.
        assetsReceived = IERC20Like(ctx.market.loanToken).balanceOf(ctx.proxy) - ctx.balanceBefore;

        require(assetsReceived >= minAssetsOut, "MidnightFacet/min-assets-out-not-met");

        require(
            ctx.creditBefore == _credit(ctx.market, marketId, ctx.proxy) + ctx.totalUnits,
            "MidnightFacet/credit-delta-mismatch"
        );

        _requireDebtFree(marketId, ctx.proxy);

        _decreaseRateLimit(getSellRateLimitKey(marketId), assetsReceived);

        // Restores entry capacity by the assets returned; skipped when no buy limit is set.
        _tryIncreaseRateLimit(getBuyRateLimitKey(marketId), assetsReceived);

        emit MidnightSell(marketId, ctx.totalUnits, assetsReceived);
    }

    /**********************************************************************************************/
    /*** External View/Pure Functions                                                           ***/
    /**********************************************************************************************/

    /// @inheritdoc IMidnightFacet
    function getBuyRateLimitKey(bytes32 marketId) public pure override returns (bytes32) {
        return makeBytes32Key(_LIMIT_BUY, marketId);
    }

    /// @inheritdoc IMidnightFacet
    function getMarketConfig(bytes32 marketId)
        external
        view
        override
        returns (MarketConfig memory)
    {
        return _getFacetStorage().marketConfigs[marketId];
    }

    /// @inheritdoc IMidnightFacet
    function getRedeemRateLimitKey(bytes32 marketId) public pure override returns (bytes32) {
        return makeBytes32Key(_LIMIT_REDEEM, marketId);
    }

    /// @inheritdoc IMidnightFacet
    function getSellRateLimitKey(bytes32 marketId) public pure override returns (bytes32) {
        return makeBytes32Key(_LIMIT_SELL, marketId);
    }

    /**********************************************************************************************/
    /*** Internal Functions                                                                     ***/
    /**********************************************************************************************/

    function _takeBatch(
        TakeContext memory ctx,
        Offer[]   calldata offers,
        bytes[]   calldata ratifierData,
        uint256[] calldata units
    )
        internal
    {
        for (uint256 i = 0; i < offers.length; i++) {
            Offer memory offer = offers[i];

            // The id commits to the whole market config, venue included.
            require(
                MidnightUtils.toId(offer.market) == ctx.marketId,
                "MidnightFacet/market-mismatch"
            );

            require(offer.buy == ctx.selling, "MidnightFacet/invalid-offer-direction");
            require(units[i] != 0,            "MidnightFacet/zero-units");

            uint256 price     = MidnightUtils.tickToPrice(offer.tick);
            uint256 takeUnits = units[i];

            if (ctx.selling) {
                require(price >= ctx.tickPriceBound, "MidnightFacet/sell-price-too-low");

                // Credit drifts down with fee accrual and slashing; the excess would be naked debt.
                if (takeUnits > ctx.creditCap) takeUnits = ctx.creditCap;
                if (takeUnits == 0)            break;

                ctx.creditCap -= takeUnits;
            } else {
                require(price <= ctx.tickPriceBound, "MidnightFacet/buy-price-too-high");

                // Paying ourselves would net the transfer to zero and hide the spend from the rate
                // limit.
                require(
                    offer.receiverIfMakerIsSeller != ctx.proxy,
                    "MidnightFacet/invalid-offer-receiver"
                );
            }

            ctx.totalUnits += takeUnits;

            _take(ctx, offer, ratifierData[i], takeUnits);
        }
    }

    function _take(
        TakeContext memory ctx,
        Offer       memory offer,
        bytes     calldata ratifierData,
        uint256            units
    )
        internal
    {
        // Midnight requires the unused receiver to be zero; taker mode uses no taker callback.
        IALMProxy(ctx.proxy).doCall(
            midnight,
            abi.encodeCall(
                IMidnightLike.take,
                (
                    offer,
                    ratifierData,
                    units,
                    ctx.proxy,
                    ctx.selling ? ctx.proxy : address(0),
                    address(0),
                    new bytes(0)
                )
            )
        );
    }

    function _validateBatch(uint256 offersLength, uint256 ratifierDataLength, uint256 unitsLength)
        internal
        pure
    {
        require(offersLength != 0, "MidnightFacet/empty-batch");
        require(
            offersLength == ratifierDataLength && offersLength == unitsLength,
            "MidnightFacet/invalid-batch-length"
        );
    }

    function _takeContext(bytes32 marketId, Market calldata market, bool selling)
        internal
        view
        returns (TakeContext memory ctx)
    {
        // Every call goes to the immutable singleton, so a market from calldata is only usable once
        // it names that venue. The id check in the take loop then binds the rest of the config.
        require(market.midnight == midnight, "MidnightFacet/invalid-midnight");

        ctx.proxy         = _getSharedControllerStorage().proxy;
        ctx.marketId      = marketId;
        ctx.market        = market;
        ctx.selling       = selling;
        ctx.creditBefore  = _credit(ctx.market, marketId, ctx.proxy);
        ctx.balanceBefore = IERC20Like(market.loanToken).balanceOf(ctx.proxy);
    }

    // Reverts on a market that has never been touched (`touchMarket`, permissionless, once).
    function _settlementFee(bytes32 marketId, uint256 maturity) internal view returns (uint256) {
        uint256 timeToMaturity = maturity > block.timestamp ? maturity - block.timestamp : 0;

        return IMidnightLike(midnight).settlementFee(marketId, timeToMaturity);
    }

    function _credit(Market memory market, bytes32 marketId, address user)
        internal
        view
        returns (uint256 credit)
    {
        // Stored credit is stale, so slashing and fee accrual come from the protocol's own view.
        ( credit, , ) = IMidnightLike(midnight).updatePositionView(market, marketId, user);
    }

    function _requireDebtFree(bytes32 marketId, address user) internal view {
        require(IMidnightLike(midnight).debt(marketId, user) == 0, "MidnightFacet/debt-not-zero");
    }

}
