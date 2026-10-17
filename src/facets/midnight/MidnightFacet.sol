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
        mapping (bytes32 marketId =>
            mapping (address callback => bool allowed))       allowedCallbacks;
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
    bytes32 internal constant _LIMIT_MAKE   = keccak256("LIMIT_MIDNIGHT_MAKE");
    bytes32 internal constant _LIMIT_REDEEM = keccak256("LIMIT_MIDNIGHT_REDEEM");
    bytes32 internal constant _LIMIT_SELL   = keccak256("LIMIT_MIDNIGHT_SELL");

    /// @inheritdoc IFacet
    string public constant override VERSION = "1.2.0";

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
    function setCallbackAllowed(bytes32 marketId, address callback, bool allowed)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // A zero callback is never invoked upstream, so allowing it would ratify unmetered fills.
        require(callback != address(0), "MidnightFacet/zero-callback");

        _getFacetStorage().allowedCallbacks[marketId][callback] = allowed;

        emit MidnightCallbackAllowedSet(marketId, callback, allowed);
    }

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

        uint256 price = MidnightUtils.tickToPrice(offer.tick);

        // The fee is paid on top of the price, so both ceilings bind on the all-in cost.
        require(
            price + ctx.settlementFee <= MidnightUtils.tickToPrice(config.maxBuyTick),
            "MidnightFacet/buy-price-too-high"
        );
        require(
            price + ctx.settlementFee
                <= MidnightUtils.maxBuyPrice(config.minBuyYield, ctx.timeToMaturity, continuousFee),
            "MidnightFacet/buy-yield-too-low"
        );

        // Paying ourselves nets the transfer out and hides the spend from the rate limit.
        require(
            offer.receiverIfMakerIsSeller != ctx.proxy,
            "MidnightFacet/invalid-offer-receiver"
        );

        ApproveLib.approve(ctx.market.loanToken, ctx.proxy, midnight, maxAssetsIn);

        _take(ctx, offer, ratifierData, units, address(0));

        // Clear the approval in case Midnight did not pull the full amount.
        ApproveLib.approve(ctx.market.loanToken, ctx.proxy, midnight, 0);

        // Measure the loan token actually paid rather than trusting the take return values.
        assetsSpent = ctx.balanceBefore - IERC20Like(ctx.market.loanToken).balanceOf(ctx.proxy);

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

        // Restores entry capacity by the assets returned; skipped when no buy limit is set.
        _tryIncreaseRateLimit(getBuyRateLimitKey(marketId), assetsWithdrawn);

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

        uint256 price = MidnightUtils.tickToPrice(offer.tick);

        // The fee is taken out of the proceeds, so both floors bind on the gross price.
        require(
            price >= MidnightUtils.tickToPrice(config.minSellTick) + ctx.settlementFee,
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

        // Measure the loan token actually received rather than trusting the take return values.
        assetsReceived = IERC20Like(ctx.market.loanToken).balanceOf(ctx.proxy) - ctx.balanceBefore;

        require(assetsReceived >= minAssetsOut, "MidnightFacet/min-assets-out-not-met");

        ( uint256 creditAfter, ) = _credit(ctx.market, marketId, ctx.proxy);

        require(
            ctx.creditBefore == creditAfter + units,
            "MidnightFacet/credit-delta-mismatch"
        );

        _requireDebtFree(marketId, ctx.proxy);

        _decreaseRateLimit(getSellRateLimitKey(marketId), assetsReceived);

        // Restores entry capacity by the assets returned; skipped when no buy limit is set.
        _tryIncreaseRateLimit(getBuyRateLimitKey(marketId), assetsReceived);

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

        // No role gate: the whitelist is the authorization, so removal revokes it retroactively.
        require(
            $.allowedCallbacks[marketId][msg.sender],
            "MidnightFacet/callback-not-allowed"
        );

        require(makeConfig.maxOfferSize != 0, "MidnightFacet/make-not-enabled");
        require(assets != 0,                  "MidnightFacet/zero-assets");
        require(units  != 0,                  "MidnightFacet/zero-units");

        // Caps maker throughput in either direction and is never restored by either.
        _decreaseRateLimit(getMakeRateLimitKey(marketId), assets);

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

            _decreaseRateLimit(getSellRateLimitKey(marketId), assets);

            // Mirrors the taker exit: capital out of a market restores that market's entry room.
            _tryIncreaseRateLimit(getBuyRateLimitKey(marketId), assets);

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

        _decreaseRateLimit(getBuyRateLimitKey(marketId), assets);

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
    function getMakeRateLimitKey(bytes32 marketId) public pure override returns (bytes32) {
        return makeBytes32Key(_LIMIT_MAKE, marketId);
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
    function isCallbackAllowed(bytes32 marketId, address callback)
        external
        view
        override
        returns (bool)
    {
        return _getFacetStorage().allowedCallbacks[marketId][callback];
    }

    /**********************************************************************************************/
    /*** Internal Functions                                                                     ***/
    /**********************************************************************************************/

    function _take(
        TakeContext memory ctx,
        Offer     calldata offer,
        bytes     calldata ratifierData,
        uint256            units,
        address            receiverIfTakerIsSeller
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
                    receiverIfTakerIsSeller,
                    address(0),
                    new bytes(0)
                )
            )
        );
    }

    function _takeContext(bytes32 marketId, Market calldata market)
        internal
        view
        returns (TakeContext memory ctx)
    {
        // This market comes from calldata and its maturity feeds the caller's price bounds, so both
        // the venue and the id are bound here, before anything is derived from it.
        require(market.midnight == midnight,            "MidnightFacet/invalid-midnight");
        require(MidnightUtils.toId(market) == marketId, "MidnightFacet/market-mismatch");

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
        bound = MidnightUtils.tickToPrice(config.maxBuyTick);

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
        bound = MidnightUtils.tickToPrice(config.minSellTick);

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
