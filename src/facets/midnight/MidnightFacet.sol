// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ApproveLib } from "../../libraries/ApproveLib.sol";

import { makeAddressBytes32Key, makeBytes32Key } from "../../libraries/RateLimitHelpers.sol";

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

    bytes32 internal constant _LIMIT_STRATEGY_BUY  = keccak256("LIMIT_MIDNIGHT_STRATEGY_BUY");
    bytes32 internal constant _LIMIT_STRATEGY_SELL = keccak256("LIMIT_MIDNIGHT_STRATEGY_SELL");

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
    function setDesignatedGroups(bytes32 marketId, bytes32 buyGroup, bytes32 sellGroup)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // Zero is the ratifier's "not designated" sentinel, and one shared group cancels both sides.
        require(
            buyGroup != 0 && sellGroup != 0 && buyGroup != sellGroup,
            "MidnightFacet/invalid-groups"
        );

        _getFacetStorage().designatedGroups[marketId] =
            DesignatedGroups({ buyGroup: buyGroup, sellGroup: sellGroup });

        emit MidnightGroupsSet(marketId, buyGroup, sellGroup);
    }

    /// @inheritdoc IMidnightFacet
    function setMakeConfig(Market calldata market, uint256 maxOfferSize)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(market.midnight == midnight, "MidnightFacet/invalid-midnight");

        bytes32 marketId = MidnightIdLib.toId(market);

        // Making rests offers that only an onboarded market can price, so take onboarding gates it.
        require(
            _getFacetStorage().marketConfigs[marketId].minSellTick != 0,
            "MidnightFacet/market-not-onboarded"
        );
        require(market.maturity <= type(uint64).max, "MidnightFacet/maturity-oob");

        // Midnight moves at most uint128 assets in one fill, so a larger cap could never bind.
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

        emit MidnightMakeConfigSet(marketId, market.loanToken, market.maturity, maxOfferSize);
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
    /*** External Interactive Strategy Functions                                                ***/
    /**********************************************************************************************/

    /// @inheritdoc IMidnightFacet
    function fundFill(
        bytes32 marketId,
        bool    buying,
        uint256 assets,
        uint256 units,
        uint256 pendingFee
    )
        external
        override
        nonReentrant
    {
        FacetStorage storage $ = _getFacetStorage();

        MakeConfig   storage makeConfig = $.makeConfigs[marketId];
        MarketConfig storage config     = $.marketConfigs[marketId];

        // No role gate: the caller's own strategy key is the authorization, and an unset key
        // reverts in the rate limits before anything moves.
        require(makeConfig.maxOfferSize != 0, "MidnightFacet/make-not-enabled");
        require(assets != 0,                  "MidnightFacet/zero-assets");
        require(units  != 0,                  "MidnightFacet/zero-units");

        require(assets <= makeConfig.maxOfferSize, "MidnightFacet/offer-size-too-large");

        // Midnight pays the proxy before calling back on an exit, so this branch moves nothing.
        if (!buying) {
            address proxy = _getSharedControllerStorage().proxy;

            uint256 floor = _minFillPrice(
                config,
                makeConfig.maturity,
                _exitFeePerUnit(marketId, proxy, units, pendingFee)
            );

            require(
                assets * MidnightUtils.WAD >= units * floor,
                "MidnightFacet/fill-price-too-low"
            );

            // Upstream only checks the proxy is healthy, which collateral alone can satisfy.
            _requireDebtFree(marketId, proxy);

            _decreaseRateLimit(getStrategySellRateLimitKey(msg.sender, marketId), assets);
            _decreaseRateLimit(getSellRateLimitKey(marketId),                     assets);

            emit MidnightFillFunded(marketId, msg.sender, false, assets, units);

            return;
        }

        // A non-zero loss factor means this market's lenders have already been slashed.
        require(
            IMidnightLike(midnight).lossFactor(marketId) <= config.maxLossFactor,
            "MidnightFacet/loss-factor-too-high"
        );

        // The entry bound is priced at the ceiling, so a higher live fee undercuts the yield.
        require(
            IMidnightLike(midnight).continuousFee(marketId)
                <= MidnightUtils.continuousFeePerSecond(config.maxContinuousFee),
            "MidnightFacet/continuous-fee-too-high"
        );

        require(
            assets * MidnightUtils.WAD <= units * _maxFillPrice(config, makeConfig.maturity),
            "MidnightFacet/fill-price-too-high"
        );

        _decreaseRateLimit(getStrategyBuyRateLimitKey(msg.sender, marketId), assets);
        _decreaseRateLimit(getBuyRateLimitKey(marketId),                     assets);

        // Last step, so every gate and both meters have already passed.
        IALMProxy(_getSharedControllerStorage().proxy).doCall(
            makeConfig.loanToken,
            abi.encodeCall(IERC20Like.transfer, (msg.sender, assets))
        );

        emit MidnightFillFunded(marketId, msg.sender, true, assets, units);
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
    function getStrategyBuyRateLimitKey(address strategy, bytes32 marketId)
        public
        pure
        override
        returns (bytes32)
    {
        return makeAddressBytes32Key(_LIMIT_STRATEGY_BUY, strategy, marketId);
    }

    /// @inheritdoc IMidnightFacet
    function getStrategySellRateLimitKey(address strategy, bytes32 marketId)
        public
        pure
        override
        returns (bytes32)
    {
        return makeAddressBytes32Key(_LIMIT_STRATEGY_SELL, strategy, marketId);
    }

    /// @inheritdoc IMidnightFacet
    function isCallbackAllowed(bytes32 marketId, address callback, bool buying)
        external
        view
        override
        returns (bool)
    {
        // Hard-coded, so a key funded for the zero address by mistake cannot ratify an offer
        // whose fills would never reach fundFill.
        if (callback == address(0)) return false;

        if (_getFacetStorage().makeConfigs[marketId].maxOfferSize == 0) return false;

        bytes32 strategyKey = buying
            ? getStrategyBuyRateLimitKey(callback, marketId)
            : getStrategySellRateLimitKey(callback, marketId);

        bytes32 marketKey = buying ? getBuyRateLimitKey(marketId) : getSellRateLimitKey(marketId);

        return _rateLimitExists(strategyKey) && _rateLimitExists(marketKey);
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
        bound = MidnightTickLib.tickToPrice(config.maxBuyTick);

        uint256 yieldBound = MidnightUtils.maxBuyPrice(
            config.minBuyYield,
            _timeToMaturity(maturity),
            MidnightUtils.continuousFeePerSecond(config.maxContinuousFee)
        );

        if (yieldBound < bound) bound = yieldBound;
    }

    function _minFillPrice(MarketConfig storage config, uint64 maturity, uint256 feePerUnit)
        internal
        view
        returns (uint256 bound)
    {
        bound = MidnightTickLib.tickToPrice(config.minSellTick);

        uint256 yieldBound = MidnightUtils.minSellPrice(
            config.maxSellYield,
            _timeToMaturity(maturity),
            MidnightUtils.WAD,
            feePerUnit
        );

        if (yieldBound > bound) bound = yieldBound;
    }

    function _exitFeePerUnit(bytes32 marketId, address proxy, uint256 units, uint256 pendingFee)
        internal
        view
        returns (uint256 feePerUnit)
    {
        feePerUnit = pendingFee * MidnightUtils.WAD / units;

        ( uint256 credit, uint256 carried ) =
            _credit(IMidnightLike(midnight).toMarket(marketId), marketId, proxy);

        // The split is pro rata, so what is left per unit is what the fill shed per unit. A full
        // exit leaves no ratio to read, and prices unencumbered.
        uint256 carriedPerUnit = credit == 0 ? 0 : carried * MidnightUtils.WAD / credit;

        if (carriedPerUnit < feePerUnit) feePerUnit = carriedPerUnit;
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
