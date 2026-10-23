// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ApproveLib } from "../../libraries/ApproveLib.sol";

import { makeBytes32Key } from "../../libraries/RateLimitHelpers.sol";

import { IALMProxy } from "../../interfaces/IALMProxy.sol";

import { IFacet } from "../IFacet.sol";

import { Facet } from "../Facet.sol";

import { IMidnightFacet } from "./IMidnightFacet.sol";

import { Market, Offer } from "./MidnightInterfaces.sol";

import { MidnightIdLib } from "./MidnightIdLib.sol";

import { MAX_TICK, MidnightTickLib } from "./MidnightTickLib.sol";

import { MidnightUtils } from "./MidnightUtils.sol";

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
        Market  market;
        uint256 timeToMaturity;
        uint256 settlementFee;
        uint256 creditBefore;
        uint256 pendingFeeBefore;
        uint256 balanceBefore;
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
    function setMarketConfig(
        bytes32 marketId,
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  minBuyYield,
        uint16  maxSellYield,
        uint16  maxContinuousFee,
        uint128 maxLossFactor
    )
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // Zero is meaningful: no maxBuyTick kills entries, no minSellTick means not onboarded.
        require(maxBuyTick <= MAX_TICK, "MidnightFacet/max-buy-tick-oob");
        require(minSellTick != 0 && minSellTick <= MAX_TICK, "MidnightFacet/min-sell-tick-oob");
        require(
            MidnightUtils.continuousFeePerSecond(maxContinuousFee)
                <= MidnightUtils.MAX_CONTINUOUS_FEE,
            "MidnightFacet/max-continuous-fee-oob"
        );
        // A zero sell yield would only clear at par and brick the exit, so one must be named.
        require(maxSellYield != 0, "MidnightFacet/max-sell-yield-not-set");

        _getFacetStorage().marketConfigs[marketId] = MarketConfig({
            maxBuyTick       : maxBuyTick,
            minSellTick      : minSellTick,
            minBuyYield      : minBuyYield,
            maxSellYield     : maxSellYield,
            maxContinuousFee : maxContinuousFee,
            maxLossFactor    : maxLossFactor
        });

        emit MidnightMarketConfigSet(
            marketId,
            maxBuyTick,
            minSellTick,
            minBuyYield,
            maxSellYield,
            maxContinuousFee,
            maxLossFactor
        );
    }

    /**********************************************************************************************/
    /*** External Interactive Allocator Functions                                               ***/
    /**********************************************************************************************/

    /// @inheritdoc IMidnightFacet
    function buy(
        bytes32         marketId,
        Offer  calldata offer,
        bytes  calldata ratifierData,
        uint256         units,
        uint256         maxAssetsIn
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

        TakeContext memory ctx = _takeContext(marketId, offer.market);

        uint256 continuousFee = IMidnightLike(midnight).continuousFee(marketId);

        // Entering fixes the market's current rate onto the new units for their whole term.
        require(
            continuousFee <= MidnightUtils.continuousFeePerSecond(config.maxContinuousFee),
            "MidnightFacet/continuous-fee-too-high"
        );

        // A non-zero loss factor means this market's lenders have already been slashed.
        require(
            IMidnightLike(midnight).lossFactor(marketId) <= config.maxLossFactor,
            "MidnightFacet/loss-factor-too-high"
        );

        require(!offer.buy, "MidnightFacet/invalid-offer-direction");
        require(units != 0, "MidnightFacet/zero-units");

        // Scoped to free the price locals before the take; buy is at the stack limit.
        {
            uint256 price = MidnightTickLib.tickToPrice(offer.tick);

            // The fee is paid on top of the price, so both ceilings bind on the all-in cost.
            require(
                price + ctx.settlementFee <= MidnightTickLib.tickToPrice(config.maxBuyTick),
                "MidnightFacet/buy-price-too-high"
            );
            require(
                price + ctx.settlementFee <= MidnightUtils.maxBuyPrice(
                    config.minBuyYield,
                    ctx.timeToMaturity,
                    continuousFee
                ),
                "MidnightFacet/buy-yield-too-low"
            );
        }

        // Paying ourselves nets the transfer out, so the balance delta stops tracking the fill.
        require(
            offer.receiverIfMakerIsSeller != ctx.proxy,
            "MidnightFacet/invalid-offer-receiver"
        );

        ApproveLib.approve(ctx.market.loanToken, ctx.proxy, midnight, maxAssetsIn);

        uint256 buyerAssets = _take(ctx, offer, ratifierData, units, address(0));

        // Clear the approval in case Midnight did not pull the full amount.
        ApproveLib.approve(ctx.market.loanToken, ctx.proxy, midnight, 0);

        assetsSpent = ctx.balanceBefore - IERC20Like(ctx.market.loanToken).balanceOf(ctx.proxy);

        // Loan token arriving during the take shrinks the measured delta, so charge the higher of
        // what the balance moved and what Midnight says the buyer paid.
        if (buyerAssets > assetsSpent) assetsSpent = buyerAssets;

        require(assetsSpent <= maxAssetsIn, "MidnightFacet/max-assets-in-exceeded");

        ( uint256 creditAfter, ) = _credit(ctx.market, marketId, ctx.proxy);

        // The proxy never holds debt, so a buy increases credit by exactly the units taken.
        require(
            creditAfter == ctx.creditBefore + units,
            "MidnightFacet/credit-delta-mismatch"
        );

        _requireDebtFree(marketId, ctx.proxy);

        _decreaseRateLimit(getBuyRateLimitKey(marketId), assetsSpent);

        emit MidnightBuy(marketId, units, assetsSpent);
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
        require(minAssetsOut != 0, "MidnightFacet/min-assets-out-not-set");

        address proxy = _getSharedControllerStorage().proxy;

        Market memory market = IMidnightLike(midnight).toMarket(marketId);

        // Redemption is at par out of repayments, so units are capped by both sides of the pool.
        ( uint256 credit, ) = _credit(market, marketId, proxy);

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

        emit MidnightRedeem(marketId, units, assetsWithdrawn);
    }

    /// @inheritdoc IMidnightFacet
    function sell(
        bytes32         marketId,
        Offer  calldata offer,
        bytes  calldata ratifierData,
        uint256         units,
        uint256         minAssetsOut
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

        TakeContext memory ctx = _takeContext(marketId, offer.market);

        require(offer.buy,  "MidnightFacet/invalid-offer-direction");
        require(units != 0, "MidnightFacet/zero-units");

        // Credit drifts down with fee accrual and slashing; the excess would be naked debt.
        if (units > ctx.creditBefore) units = ctx.creditBefore;

        require(units != 0, "MidnightFacet/no-credit-to-sell");

        uint256 price = MidnightTickLib.tickToPrice(offer.tick);

        // The fee is taken out of the proceeds, so both floors bind on the gross price.
        require(
            price >= MidnightTickLib.tickToPrice(config.minSellTick) + ctx.settlementFee,
            "MidnightFacet/sell-price-too-low"
        );
        require(
            price >= MidnightUtils.minSellPrice(
                config.maxSellYield,
                ctx.timeToMaturity,
                ctx.creditBefore,
                ctx.pendingFeeBefore
            ) + ctx.settlementFee,
            "MidnightFacet/sell-yield-too-high"
        );

        _take(ctx, offer, ratifierData, units, ctx.proxy);

        // Loan token arriving during the take only inflates this, which over-charges the sell key.
        assetsReceived = IERC20Like(ctx.market.loanToken).balanceOf(ctx.proxy) - ctx.balanceBefore;

        require(assetsReceived >= minAssetsOut, "MidnightFacet/min-assets-out-not-met");

        ( uint256 creditAfter, ) = _credit(ctx.market, marketId, ctx.proxy);

        require(
            ctx.creditBefore == creditAfter + units,
            "MidnightFacet/credit-delta-mismatch"
        );

        _requireDebtFree(marketId, ctx.proxy);

        _decreaseRateLimit(getSellRateLimitKey(marketId), assetsReceived);

        emit MidnightSell(marketId, units, assetsReceived);
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
    /*** Internal Interactive Functions                                                         ***/
    /**********************************************************************************************/

    function _take(
        TakeContext memory ctx,
        Offer     calldata offer,
        bytes     calldata ratifierData,
        uint256            units,
        address            receiverIfTakerIsSeller
    )
        internal
        returns (uint256 buyerAssets)
    {
        // Midnight requires the unused receiver to be zero; taker mode uses no taker callback.
        bytes memory result = IALMProxy(ctx.proxy).doCall(
            midnight,
            abi.encodeCall(
                IMidnightLike.take,
                (
                    offer,
                    ratifierData,
                    units,
                    ctx.proxy,
                    receiverIfTakerIsSeller,
                    address(0),
                    new bytes(0)
                )
            )
        );

        // NOTE: Midnight is immutable, and the buy only lets this raise the metered spend above
        //       the balance delta, never lower it.
        ( buyerAssets, ) = abi.decode(result, (uint256, uint256));
    }

    /**********************************************************************************************/
    /*** Internal View/Pure Functions                                                           ***/
    /**********************************************************************************************/

    function _takeContext(bytes32 marketId, Market calldata market)
        internal
        view
        returns (TakeContext memory ctx)
    {
        // This market comes from calldata and its maturity feeds the caller's price bounds, so both
        // the venue and the id are bound here, before anything is derived from it.
        require(market.midnight == midnight,            "MidnightFacet/invalid-midnight");
        require(MidnightIdLib.toId(market) == marketId, "MidnightFacet/market-mismatch");

        ctx.proxy          = _getSharedControllerStorage().proxy;
        ctx.market         = market;
        ctx.timeToMaturity = market.maturity > block.timestamp
            ? market.maturity - block.timestamp
            : 0;
        // Reverts on a market that has never been touched (`touchMarket`, permissionless, once).
        ctx.settlementFee  = IMidnightLike(midnight).settlementFee(marketId, ctx.timeToMaturity);
        ctx.balanceBefore  = IERC20Like(market.loanToken).balanceOf(ctx.proxy);

        ( ctx.creditBefore, ctx.pendingFeeBefore ) = _credit(ctx.market, marketId, ctx.proxy);
    }

    function _credit(Market memory market, bytes32 marketId, address user)
        internal
        view
        returns (uint256 credit, uint256 pendingFee)
    {
        // Stored credit is stale, so slashing and fee accrual come from the protocol's own view.
        ( credit, pendingFee, ) =
            IMidnightLike(midnight).updatePositionView(market, marketId, user);
    }

    function _requireDebtFree(bytes32 marketId, address user) internal view {
        require(IMidnightLike(midnight).debt(marketId, user) == 0, "MidnightFacet/debt-not-zero");
    }

}
