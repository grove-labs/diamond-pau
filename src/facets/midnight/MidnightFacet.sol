// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ApproveLib } from "../../libraries/ApproveLib.sol";

import { makeAddressBytes32Key, makeBytes32Key } from "../../libraries/RateLimitHelpers.sol";

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

    function setConsumed(bytes32 group, uint128 amount, address onBehalf) external;

    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external;

}

interface IERC20Like {

    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

}

contract MidnightFacet is IMidnightFacet, Facet {

    /**********************************************************************************************/
    /*** Facet Storage Domain                                                                   ***/
    /**********************************************************************************************/

    /// @custom:storage-location erc7201:sky.pau.storage.MidnightFacet.v1
    struct FacetStorage {
        mapping (bytes32 marketId => MarketConfig config)     marketConfigs;
        mapping (bytes32 marketId => MakeConfig config)       makeConfigs;
        mapping (bytes32 marketId => DesignatedGroups groups) designatedGroups;
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
        uint256 timeToMaturity;
        uint256 settlementFee;
        uint256 continuousFee;    // Market's current rate, set on the buy leg only.
        uint256 tickPriceBound;   // Ceiling when buying, floor when selling; fee applied per offer.
        uint256 yieldPriceBound;  // Same shape, derived from the yield rail.
        uint256 creditCap;        // Sellable position, ignored when buying.
        uint256 creditBefore;
        uint256 pendingFeeBefore;
        uint256 balanceBefore;
        uint256 totalUnits;
    }

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    bytes32 internal constant _LIMIT_BUY      = keccak256("LIMIT_MIDNIGHT_BUY");
    bytes32 internal constant _LIMIT_REDEEM   = keccak256("LIMIT_MIDNIGHT_REDEEM");
    bytes32 internal constant _LIMIT_SELL     = keccak256("LIMIT_MIDNIGHT_SELL");
    bytes32 internal constant _LIMIT_STRATEGY = keccak256("LIMIT_MIDNIGHT_STRATEGY");

    /// @inheritdoc IFacet
    string public constant override VERSION = "1.1.0";

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
    function setDesignatedGroups(bytes32 marketId, bytes32 buyGroup, bytes32 sellGroup)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // Sharing a group across directions would make either book uncancellable on its own.
        require(buyGroup != sellGroup || buyGroup == 0, "MidnightFacet/groups-not-distinct");

        _getFacetStorage().designatedGroups[marketId] =
            DesignatedGroups({ buyGroup: buyGroup, sellGroup: sellGroup });

        emit MidnightDesignatedGroupsSet(marketId, buyGroup, sellGroup);
    }

    /// @inheritdoc IMidnightFacet
    function setMakeConfig(Market calldata market, uint256 maxOfferSize)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(market.midnight == midnight, "MidnightFacet/invalid-midnight");

        bytes32 marketId = MidnightUtils.toId(market);

        // Making rests offers that only an onboarded market can price, so take onboarding gates it.
        require(
            _getFacetStorage().marketConfigs[marketId].minSellTick != 0,
            "MidnightFacet/market-not-onboarded"
        );
        require(market.maturity <= type(uint64).max, "MidnightFacet/maturity-oob");

        // An offer's own size fields are uint128, so a larger cap could never bind.
        require(maxOfferSize <= type(uint128).max, "MidnightFacet/max-offer-size-oob");

        // Reverts unless the market exists on Midnight; the equality holds by construction.
        require(
            IMidnightLike(midnight).toMarket(marketId).maturity == market.maturity,
            "MidnightFacet/market-mismatch"
        );

        _getFacetStorage().makeConfigs[marketId] = MakeConfig({
            maxOfferSize : maxOfferSize,
            maturity     : uint64(market.maturity),
            loanToken    : market.loanToken
        });

        emit MidnightMakeConfigSet(
            marketId,
            maxOfferSize,
            uint64(market.maturity),
            market.loanToken
        );
    }

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
        require(maxBuyTick <= MidnightUtils.MAX_TICK, "MidnightFacet/max-buy-tick-oob");
        require(
            minSellTick != 0 && minSellTick <= MidnightUtils.MAX_TICK,
            "MidnightFacet/min-sell-tick-oob"
        );
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

    /// @inheritdoc IMidnightFacet
    function setRatifierAuthorization(address ratifier, bool authorized)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(ratifier != address(0), "MidnightFacet/zero-ratifier");

        address proxy = _getSharedControllerStorage().proxy;

        IALMProxy(proxy).doCall(
            midnight,
            abi.encodeCall(IMidnightLike.setIsAuthorized, (ratifier, authorized, proxy))
        );

        emit MidnightRatifierAuthorizationSet(ratifier, authorized);
    }

    /**********************************************************************************************/
    /*** External Interactive Allocator Functions                                               ***/
    /**********************************************************************************************/

    /// @inheritdoc IMidnightFacet
    function buy(
        bytes32         marketId,
        Fill[] calldata fills,
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
        require(fills.length != 0,      "MidnightFacet/empty-batch");

        TakeContext memory ctx = _takeContext(marketId, fills[0].offer.market, false);

        ctx.continuousFee = IMidnightLike(midnight).continuousFee(marketId);

        // Entering fixes the market's current rate onto the new units for their whole term.
        require(
            ctx.continuousFee <= MidnightUtils.continuousFeePerSecond(config.maxContinuousFee),
            "MidnightFacet/continuous-fee-too-high"
        );

        // A non-zero loss factor means this market's lenders have already been slashed.
        require(
            IMidnightLike(midnight).lossFactor(marketId) <= config.maxLossFactor,
            "MidnightFacet/loss-factor-too-high"
        );

        ctx.tickPriceBound = MidnightUtils.tickToPrice(config.maxBuyTick);

        ctx.yieldPriceBound =
            MidnightUtils.maxBuyPrice(config.minBuyYield, ctx.timeToMaturity, ctx.continuousFee);

        ApproveLib.approve(ctx.market.loanToken, ctx.proxy, midnight, maxAssetsIn);

        _takeBatch(ctx, fills);

        // Clear the approval in case Midnight did not pull the full amount.
        ApproveLib.approve(ctx.market.loanToken, ctx.proxy, midnight, 0);

        // Measure the loan token actually paid rather than trusting the take return values.
        assetsSpent = ctx.balanceBefore - IERC20Like(ctx.market.loanToken).balanceOf(ctx.proxy);

        require(assetsSpent <= maxAssetsIn, "MidnightFacet/max-assets-in-exceeded");

        ( uint256 creditAfter, ) = _credit(ctx.market, marketId, ctx.proxy);

        // The proxy never holds debt, so a buy increases credit by exactly the units taken.
        require(
            creditAfter == ctx.creditBefore + ctx.totalUnits,
            "MidnightFacet/credit-delta-mismatch"
        );

        _requireDebtFree(marketId, ctx.proxy);

        _decreaseRateLimit(getBuyRateLimitKey(marketId), assetsSpent);

        emit MidnightBuy(marketId, ctx.totalUnits, assetsSpent);
    }

    /// @inheritdoc IMidnightFacet
    function cancelOfferGroup(bytes32 group)
        external
        override
        nonReentrant
        onlyRole(ALLOCATOR_ROLE)
    {
        address proxy = _getSharedControllerStorage().proxy;

        // Midnight rejects any amount below what the group consumed, so max can only retire.
        IALMProxy(proxy).doCall(
            midnight,
            abi.encodeCall(
                IMidnightLike.setConsumed,
                (group, type(uint128).max, proxy)
            )
        );

        emit MidnightOfferGroupCancelled(group);
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

        // Restores entry capacity by the assets returned; skipped when no buy limit is set.
        _tryIncreaseRateLimit(getBuyRateLimitKey(marketId), assetsWithdrawn);

        emit MidnightRedeem(marketId, units, assetsWithdrawn);
    }

    /// @inheritdoc IMidnightFacet
    function sell(
        bytes32         marketId,
        Fill[] calldata fills,
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
        require(fills.length != 0,       "MidnightFacet/empty-batch");

        TakeContext memory ctx = _takeContext(marketId, fills[0].offer.market, true);

        ctx.tickPriceBound = MidnightUtils.tickToPrice(config.minSellTick);

        ctx.yieldPriceBound = MidnightUtils.minSellPrice(
            config.maxSellYield,
            ctx.timeToMaturity,
            ctx.creditBefore,
            ctx.pendingFeeBefore
        );

        ctx.creditCap = ctx.creditBefore;

        _takeBatch(ctx, fills);

        // Measure the loan token actually received rather than trusting the take return values.
        assetsReceived = IERC20Like(ctx.market.loanToken).balanceOf(ctx.proxy) - ctx.balanceBefore;

        require(assetsReceived >= minAssetsOut, "MidnightFacet/min-assets-out-not-met");

        ( uint256 creditAfter, ) = _credit(ctx.market, marketId, ctx.proxy);

        require(
            ctx.creditBefore == creditAfter + ctx.totalUnits,
            "MidnightFacet/credit-delta-mismatch"
        );

        _requireDebtFree(marketId, ctx.proxy);

        _decreaseRateLimit(getSellRateLimitKey(marketId), assetsReceived);

        // Restores entry capacity by the assets returned; skipped when no buy limit is set.
        _tryIncreaseRateLimit(getBuyRateLimitKey(marketId), assetsReceived);

        emit MidnightSell(marketId, ctx.totalUnits, assetsReceived);
    }

    /**********************************************************************************************/
    /*** External Interactive Strategy Functions                                                ***/
    /**********************************************************************************************/

    /// @inheritdoc IMidnightFacet
    function fundFill(bytes32 marketId, uint256 assets, uint256 units)
        external
        override
        nonReentrant
    {
        FacetStorage storage $ = _getFacetStorage();

        MakeConfig   storage makeConfig = $.makeConfigs[marketId];
        MarketConfig storage config     = $.marketConfigs[marketId];

        bytes32 strategyKey = getStrategyRateLimitKey(msg.sender, marketId);

        // No role gate: the pair limit's existence is the authorization, so zeroing it revokes.
        require(_rateLimitExists(strategyKey), "MidnightFacet/strategy-not-authorized");

        require(makeConfig.maxOfferSize != 0, "MidnightFacet/make-not-enabled");
        require(assets != 0,                  "MidnightFacet/zero-assets");
        require(units  != 0,                  "MidnightFacet/zero-units");

        // A non-zero loss factor means this market's lenders have already been slashed.
        require(
            IMidnightLike(midnight).lossFactor(marketId) <= config.maxLossFactor,
            "MidnightFacet/loss-factor-too-high"
        );

        require(
            assets <= units * _maxFillPrice(config, makeConfig.maturity) / MidnightUtils.WAD,
            "MidnightFacet/fill-price-too-high"
        );

        _decreaseRateLimit(strategyKey, assets);
        _decreaseRateLimit(getBuyRateLimitKey(marketId), assets);

        // Last step, so every gate and both meters have already passed.
        IALMProxy(_getSharedControllerStorage().proxy).doCall(
            makeConfig.loanToken,
            abi.encodeCall(IERC20Like.transfer, (msg.sender, assets))
        );

        emit MidnightFillFunded(marketId, msg.sender, assets, units);
    }

    /**********************************************************************************************/
    /*** External View/Pure Functions                                                           ***/
    /**********************************************************************************************/

    /// @inheritdoc IMidnightFacet
    function getBuyRateLimitKey(bytes32 marketId) public pure override returns (bytes32) {
        return makeBytes32Key(_LIMIT_BUY, marketId);
    }

    /// @inheritdoc IMidnightFacet
    function getDesignatedGroups(bytes32 marketId)
        external
        view
        override
        returns (DesignatedGroups memory)
    {
        return _getFacetStorage().designatedGroups[marketId];
    }

    /// @inheritdoc IMidnightFacet
    function getMakeConfig(bytes32 marketId)
        external
        view
        override
        returns (MakeConfig memory)
    {
        return _getFacetStorage().makeConfigs[marketId];
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

    /// @inheritdoc IMidnightFacet
    function getStrategyRateLimitKey(address strategy, bytes32 marketId)
        public
        pure
        override
        returns (bytes32)
    {
        return makeAddressBytes32Key(_LIMIT_STRATEGY, strategy, marketId);
    }

    /**********************************************************************************************/
    /*** Internal Functions                                                                     ***/
    /**********************************************************************************************/

    function _takeBatch(TakeContext memory ctx, Fill[] calldata fills) internal {
        for (uint256 i = 0; i < fills.length; ++i) {
            Offer memory offer = fills[i].offer;

            // The id commits to the whole market config, venue included.
            require(
                MidnightUtils.toId(offer.market) == ctx.marketId,
                "MidnightFacet/market-mismatch"
            );

            require(offer.buy == ctx.selling, "MidnightFacet/invalid-offer-direction");
            require(fills[i].units != 0,      "MidnightFacet/zero-units");

            uint256 price     = MidnightUtils.tickToPrice(offer.tick);
            uint256 takeUnits = fills[i].units;

            if (ctx.selling) {
                // Credit drifts down with fee accrual and slashing; the excess would be naked debt.
                // Bounded before the rails so an offer left unreachable cannot gate the batch.
                if (takeUnits > ctx.creditCap) takeUnits = ctx.creditCap;
                if (takeUnits == 0)            break;

                ctx.creditCap -= takeUnits;

                // The fee is taken out of the proceeds, so both floors bind on the gross price.
                require(
                    price >= ctx.tickPriceBound + ctx.settlementFee,
                    "MidnightFacet/sell-price-too-low"
                );
                require(
                    price >= ctx.yieldPriceBound + ctx.settlementFee,
                    "MidnightFacet/sell-yield-too-high"
                );
            } else {
                // The fee is paid on top of the price, so both ceilings bind on the all-in cost.
                require(
                    price + ctx.settlementFee <= ctx.tickPriceBound,
                    "MidnightFacet/buy-price-too-high"
                );
                require(
                    price + ctx.settlementFee <= ctx.yieldPriceBound,
                    "MidnightFacet/buy-yield-too-low"
                );

                // Paying ourselves nets the transfer out and hides the spend from the rate limit.
                require(
                    offer.receiverIfMakerIsSeller != ctx.proxy,
                    "MidnightFacet/invalid-offer-receiver"
                );
            }

            ctx.totalUnits += takeUnits;

            _take(ctx, offer, fills[i].ratifierData, takeUnits);
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

    function _takeContext(bytes32 marketId, Market calldata market, bool selling)
        internal
        view
        returns (TakeContext memory ctx)
    {
        // This market comes from calldata and its maturity feeds the caller's price bounds, so both
        // the venue and the id are bound here, before anything is derived from it.
        require(market.midnight == midnight,            "MidnightFacet/invalid-midnight");
        require(MidnightUtils.toId(market) == marketId, "MidnightFacet/market-mismatch");

        ctx.proxy          = _getSharedControllerStorage().proxy;
        ctx.marketId       = marketId;
        ctx.market         = market;
        ctx.selling        = selling;
        ctx.timeToMaturity = _timeToMaturity(market.maturity);
        // Reverts on a market that has never been touched (`touchMarket`, permissionless, once).
        ctx.settlementFee  = IMidnightLike(midnight).settlementFee(marketId, ctx.timeToMaturity);
        ctx.balanceBefore  = IERC20Like(market.loanToken).balanceOf(ctx.proxy);

        ( ctx.creditBefore, ctx.pendingFeeBefore ) = _credit(ctx.market, marketId, ctx.proxy);
    }

    // Every input comes from config, never the live market, so the bound cannot loosen.
    function _maxFillPrice(MarketConfig storage config, uint64 maturity)
        internal
        view
        returns (uint256 bound)
    {
        bound = MidnightUtils.tickToPrice(config.maxBuyTick);

        uint256 yieldBound = MidnightUtils.maxBuyPrice(
            config.minBuyYield,
            _timeToMaturity(maturity),
            MidnightUtils.continuousFeePerSecond(config.maxContinuousFee)
        );

        if (yieldBound < bound) bound = yieldBound;
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

    function _timeToMaturity(uint256 maturity) internal view returns (uint256) {
        return maturity > block.timestamp ? maturity - block.timestamp : 0;
    }

    function _requireDebtFree(bytes32 marketId, address user) internal view {
        require(IMidnightLike(midnight).debt(marketId, user) == 0, "MidnightFacet/debt-not-zero");
    }

}
