// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ApproveLib } from "../../libraries/ApproveLib.sol";

import { makeAddressBytes32Key, makeBytes32Key } from "../../libraries/RateLimitHelpers.sol";

import { IAccessControls } from "../../interfaces/IAccessControls.sol";
import { IALMProxy }       from "../../interfaces/IALMProxy.sol";

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
        mapping (bytes32 marketId => MarketConfig config) marketConfigs;
        mapping (address strategy => bool enabled)        enabledStrategies;
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
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    bytes32 internal constant _LIMIT_BUY    = keccak256("LIMIT_MIDNIGHT_BUY");
    bytes32 internal constant _LIMIT_REDEEM = keccak256("LIMIT_MIDNIGHT_REDEEM");
    bytes32 internal constant _LIMIT_SELL   = keccak256("LIMIT_MIDNIGHT_SELL");

    bytes32 internal constant _LIMIT_STRATEGY_BUY  = keccak256("LIMIT_MIDNIGHT_STRATEGY_BUY");
    bytes32 internal constant _LIMIT_STRATEGY_SELL = keccak256("LIMIT_MIDNIGHT_STRATEGY_SELL");

    /// @inheritdoc IMidnightFacet
    bytes32 public constant override MIDNIGHT_FREEZER_ROLE = keccak256("MIDNIGHT_FREEZER_ROLE");

    /// @inheritdoc IFacet
    string public constant override VERSION = "1.0.0";

    /**********************************************************************************************/
    /*** Declarations                                                                           ***/
    /**********************************************************************************************/

    /// @inheritdoc IMidnightFacet
    address public immutable override midnight;

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
    function disableMake(bytes32 marketId)
        external
        override
        nonReentrant
        onlyRole(MIDNIGHT_FREEZER_ROLE)
    {
        _getFacetStorage().marketConfigs[marketId].maxMakeOfferSize = 0;

        emit MidnightMakeDisabled(marketId);
    }

    /// @inheritdoc IMidnightFacet
    function disableStrategy(address strategy)
        external
        override
        nonReentrant
        onlyRole(MIDNIGHT_FREEZER_ROLE)
    {
        _getFacetStorage().enabledStrategies[strategy] = false;

        emit MidnightStrategySet(strategy, false);
    }

    /// @inheritdoc IMidnightFacet
    function setMarketConfig(
        Market calldata market,
        uint16          maxBuyTick,
        uint16          minSellTick,
        uint16          minBuyYield,
        uint16          maxSellYield,
        uint16          maxContinuousFee,
        uint128         maxLossFactor,
        uint256         maxMakeOfferSize
    )
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _validateMarket(market);

        _validateMarketConfig(
            maxBuyTick, minSellTick, maxContinuousFee, maxSellYield, maxMakeOfferSize
        );

        bytes32 marketId = MidnightIdLib.toId(market);

        _validateMarketExists(marketId, market.maturity);

        _getFacetStorage().marketConfigs[marketId] = MarketConfig({
            maxBuyTick       : maxBuyTick,
            minSellTick      : minSellTick,
            minBuyYield      : minBuyYield,
            maxSellYield     : maxSellYield,
            maxContinuousFee : maxContinuousFee,
            maxLossFactor    : maxLossFactor,
            maxMakeOfferSize : uint128(maxMakeOfferSize),
            maturity         : uint64(market.maturity),
            loanToken        : market.loanToken
        });

        emit MidnightMarketConfigSet(
            marketId,
            market.loanToken,
            market.maturity,
            maxBuyTick,
            minSellTick,
            minBuyYield,
            maxSellYield,
            maxContinuousFee,
            maxLossFactor,
            maxMakeOfferSize
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

    /// @inheritdoc IMidnightFacet
    function setStrategy(address strategy, bool enabled)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _getFacetStorage().enabledStrategies[strategy] = enabled;

        emit MidnightStrategySet(strategy, enabled);
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

        TakeContext memory ctx = _takeContext(marketId, config.maturity, offer.market);

        uint256 continuousFee = IMidnightLike(midnight).continuousFee(marketId);

        _validateBuyMarketState(marketId, config, continuousFee);

        require(!offer.buy, "MidnightFacet/invalid-offer-direction");
        require(units != 0, "MidnightFacet/zero-units");

        {
            ( uint256 tickBound, uint256 yieldBound ) =
                _buyBounds(config, ctx.timeToMaturity, continuousFee);

            uint256 price = MidnightTickLib.tickToPrice(offer.tick);

            require(price + ctx.settlementFee <= tickBound,  "MidnightFacet/buy-price-too-high");
            require(price + ctx.settlementFee <= yieldBound, "MidnightFacet/buy-yield-too-low");
        }

        // Paying the proxy would net out the transfer and hide the spend from the rate limit.
        require(
            offer.receiverIfMakerIsSeller != ctx.proxy,
            "MidnightFacet/invalid-offer-receiver"
        );

        ApproveLib.approve(ctx.market.loanToken, ctx.proxy, midnight, maxAssetsIn);

        uint256 buyerAssets = _take(ctx, offer, ratifierData, units, address(0));

        ApproveLib.approve(ctx.market.loanToken, ctx.proxy, midnight, 0);

        assetsSpent = ctx.balanceBefore - IERC20Like(ctx.market.loanToken).balanceOf(ctx.proxy);

        if (buyerAssets > assetsSpent) assetsSpent = buyerAssets;

        require(assetsSpent <= maxAssetsIn, "MidnightFacet/max-assets-in-exceeded");

        ( uint256 creditAfter, ) = _credit(ctx.market, marketId, ctx.proxy);

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
    {
        _checkCancelOfferGroupRole();

        address proxy = _getSharedControllerStorage().proxy;

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
        require(
            _getFacetStorage().marketConfigs[marketId].minSellTick != 0,
            "MidnightFacet/market-not-onboarded"
        );
        require(minAssetsOut != 0, "MidnightFacet/min-assets-out-not-set");

        address proxy = _getSharedControllerStorage().proxy;

        Market memory market = IMidnightLike(midnight).toMarket(marketId);

        require(market.midnight == midnight,            "MidnightFacet/invalid-midnight");
        require(MidnightIdLib.toId(market) == marketId, "MidnightFacet/market-mismatch");

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

        TakeContext memory ctx = _takeContext(marketId, config.maturity, offer.market);

        require(offer.buy,  "MidnightFacet/invalid-offer-direction");
        require(units != 0, "MidnightFacet/zero-units");

        if (units > ctx.creditBefore) units = ctx.creditBefore;

        require(units != 0, "MidnightFacet/no-credit-to-sell");

        {
            uint256 feePerUnit = ctx.pendingFeeBefore * MidnightUtils.WAD / ctx.creditBefore;

            ( uint256 tickBound, uint256 yieldBound ) =
                _sellBounds(config, ctx.timeToMaturity, feePerUnit);

            uint256 price = MidnightTickLib.tickToPrice(offer.tick);

            require(price >= tickBound + ctx.settlementFee,  "MidnightFacet/sell-price-too-low");
            require(price >= yieldBound + ctx.settlementFee, "MidnightFacet/sell-yield-too-high");
        }

        _take(ctx, offer, ratifierData, units, ctx.proxy);

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
        require(
            _getFacetStorage().enabledStrategies[msg.sender],
            "MidnightFacet/strategy-not-enabled"
        );

        MarketConfig storage config = _getFacetStorage().marketConfigs[marketId];

        require(config.maxMakeOfferSize != 0, "MidnightFacet/make-not-enabled");
        require(assets != 0,                  "MidnightFacet/zero-assets");
        require(units  != 0,                  "MidnightFacet/zero-units");

        require(assets <= config.maxMakeOfferSize, "MidnightFacet/offer-size-too-large");

        if (buying) {
            _fundFillBuy(marketId, config, assets, units);
        } else {
            _fundFillSell(marketId, config, assets, units, pendingFee);
        }
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
        // Hard-coded: a key funded for address(0) by mistake would let unmetered offers through.
        if (callback == address(0)) return false;

        if (!_getFacetStorage().enabledStrategies[callback]) return false;

        MarketConfig storage config = _getFacetStorage().marketConfigs[marketId];

        if (config.maxMakeOfferSize == 0) return false;

        if (buying && config.maxBuyTick == 0) return false;

        bytes32 strategyKey = buying
            ? getStrategyBuyRateLimitKey(callback, marketId)
            : getStrategySellRateLimitKey(callback, marketId);

        bytes32 marketKey = buying ? getBuyRateLimitKey(marketId) : getSellRateLimitKey(marketId);

        return _rateLimitExists(strategyKey) && _rateLimitExists(marketKey);
    }

    /// @inheritdoc IMidnightFacet
    function isStrategyEnabled(address strategy) external view override returns (bool) {
        return _getFacetStorage().enabledStrategies[strategy];
    }

    /**********************************************************************************************/
    /*** Internal Interactive Functions                                                         ***/
    /**********************************************************************************************/

    function _fundFillBuy(
        bytes32              marketId,
        MarketConfig storage config,
        uint256              assets,
        uint256              units
    )
        internal
    {
        uint256 continuousFee = IMidnightLike(midnight).continuousFee(marketId);

        _validateBuyMarketState(marketId, config, continuousFee);

        ( uint256 tickBound, uint256 yieldBound ) =
            _buyBounds(config, _timeToMaturity(config.maturity), continuousFee);

        require(
            assets * MidnightUtils.WAD <= units * tickBound,
            "MidnightFacet/fill-price-too-high"
        );
        require(
            assets * MidnightUtils.WAD <= units * yieldBound,
            "MidnightFacet/fill-yield-too-low"
        );

        _decreaseRateLimit(getStrategyBuyRateLimitKey(msg.sender, marketId), assets);
        _decreaseRateLimit(getBuyRateLimitKey(marketId),                     assets);

        bytes memory returnData = IALMProxy(_getSharedControllerStorage().proxy).doCall(
            config.loanToken,
            abi.encodeCall(IERC20Like.transfer, (msg.sender, assets))
        );

        require(
            returnData.length == 0 || (returnData.length == 32 && abi.decode(returnData, (bool))),
            "MidnightFacet/transfer-failed"
        );

        emit MidnightFillFunded(marketId, msg.sender, true, assets, units);
    }

    function _fundFillSell(
        bytes32              marketId,
        MarketConfig storage config,
        uint256              assets,
        uint256              units,
        uint256              pendingFee
    )
        internal
    {
        address proxy = _getSharedControllerStorage().proxy;

        ( uint256 creditPost, uint256 carriedFee ) =
            _credit(IMidnightLike(midnight).toMarket(marketId), marketId, proxy);

        uint256 feePerUnit = _sellFeePerUnit(creditPost, carriedFee, units, pendingFee);

        ( uint256 tickBound, uint256 yieldBound ) =
            _sellBounds(config, _timeToMaturity(config.maturity), feePerUnit);

        require(
            assets * MidnightUtils.WAD >= units * tickBound,
            "MidnightFacet/fill-price-too-low"
        );
        require(
            assets * MidnightUtils.WAD >= units * yieldBound,
            "MidnightFacet/fill-yield-too-high"
        );

        // Upstream only checks the proxy is healthy, which collateral alone can satisfy.
        _requireDebtFree(marketId, proxy);

        _decreaseRateLimit(getStrategySellRateLimitKey(msg.sender, marketId), assets);
        _decreaseRateLimit(getSellRateLimitKey(marketId),                     assets);

        emit MidnightFillFunded(marketId, msg.sender, false, assets, units);
    }

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

        ( buyerAssets, ) = abi.decode(result, (uint256, uint256));
    }

    /**********************************************************************************************/
    /*** Internal View/Pure Functions                                                           ***/
    /**********************************************************************************************/

    function _takeContext(bytes32 marketId, uint256 maturity, Market calldata market)
        internal
        view
        returns (TakeContext memory ctx)
    {
        require(market.midnight == midnight,            "MidnightFacet/invalid-midnight");
        require(MidnightIdLib.toId(market) == marketId, "MidnightFacet/market-mismatch");

        ctx.proxy          = _getSharedControllerStorage().proxy;
        ctx.market         = market;
        ctx.timeToMaturity = _timeToMaturity(maturity);
        ctx.settlementFee  = IMidnightLike(midnight).settlementFee(marketId, ctx.timeToMaturity);
        ctx.balanceBefore  = IERC20Like(market.loanToken).balanceOf(ctx.proxy);

        ( ctx.creditBefore, ctx.pendingFeeBefore ) = _credit(ctx.market, marketId, ctx.proxy);
    }

    function _validateBuyMarketState(
        bytes32              marketId,
        MarketConfig storage config,
        uint256              continuousFee
    )
        internal
        view
    {
        require(
            continuousFee <= MidnightUtils.continuousFeePerSecond(config.maxContinuousFee),
            "MidnightFacet/continuous-fee-too-high"
        );

        require(
            IMidnightLike(midnight).lossFactor(marketId) <= config.maxLossFactor,
            "MidnightFacet/loss-factor-too-high"
        );
    }

    function _buyBounds(MarketConfig storage config, uint256 timeToMaturity, uint256 continuousFee)
        internal
        view
        returns (uint256 tickBound, uint256 yieldBound)
    {
        tickBound  = MidnightTickLib.tickToPrice(config.maxBuyTick);
        yieldBound = MidnightUtils.maxBuyPrice(config.minBuyYield, timeToMaturity, continuousFee);
    }

    function _sellBounds(MarketConfig storage config, uint256 timeToMaturity, uint256 feePerUnit)
        internal
        view
        returns (uint256 tickBound, uint256 yieldBound)
    {
        tickBound  = MidnightTickLib.tickToPrice(config.minSellTick);
        yieldBound = MidnightUtils.minSellPrice(
            config.maxSellYield,
            timeToMaturity,
            MidnightUtils.WAD,
            feePerUnit
        );
    }

    function _sellFeePerUnit(
        uint256 creditPost,
        uint256 carriedFee,
        uint256 units,
        uint256 reportedFee
    )
        internal
        pure
        returns (uint256 feePerUnit)
    {
        if (creditPost == 0) return 0;

        feePerUnit = carriedFee * MidnightUtils.WAD / creditPost;

        uint256 reportedFeePerUnit = reportedFee * MidnightUtils.WAD / units;

        if (reportedFeePerUnit < feePerUnit) feePerUnit = reportedFeePerUnit;
    }

    function _credit(Market memory market, bytes32 marketId, address user)
        internal
        view
        returns (uint256 credit, uint256 pendingFee)
    {
        ( credit, pendingFee, ) =
            IMidnightLike(midnight).updatePositionView(market, marketId, user);
    }

    function _timeToMaturity(uint256 maturity) internal view returns (uint256) {
        return maturity > block.timestamp ? maturity - block.timestamp : 0;
    }

    function _requireDebtFree(bytes32 marketId, address user) internal view {
        require(IMidnightLike(midnight).debt(marketId, user) == 0, "MidnightFacet/debt-not-zero");
    }

    function _validateMarket(Market calldata market) internal view {
        require(market.midnight == midnight,         "MidnightFacet/invalid-midnight");
        require(market.maturity <= type(uint64).max, "MidnightFacet/maturity-oob");
    }

    function _validateMarketConfig(
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  maxContinuousFee,
        uint16  maxSellYield,
        uint256 maxMakeOfferSize
    )
        internal
        pure
    {
        require(maxBuyTick <= MAX_TICK, "MidnightFacet/max-buy-tick-oob");
        require(
            minSellTick != 0
                && minSellTick <= MAX_TICK
                && MidnightTickLib.tickToPrice(minSellTick) != 0,
            "MidnightFacet/min-sell-tick-oob"
        );
        require(
            MidnightUtils.continuousFeePerSecond(maxContinuousFee)
                <= MidnightUtils.MAX_CONTINUOUS_FEE,
            "MidnightFacet/max-continuous-fee-oob"
        );
        require(maxSellYield != 0, "MidnightFacet/max-sell-yield-not-set");
        require(maxMakeOfferSize <= type(uint128).max, "MidnightFacet/max-offer-size-oob");
    }

    function _validateMarketExists(bytes32 marketId, uint256 maturity) internal view {
        require(
            IMidnightLike(midnight).toMarket(marketId).maturity == maturity,
            "MidnightFacet/market-mismatch"
        );
    }

    function _checkCancelOfferGroupRole() private view {
        IAccessControls accessControls =
            IAccessControls(_getSharedControllerStorage().accessControls);

        if (accessControls.hasRole(MIDNIGHT_FREEZER_ROLE, msg.sender)) return;

        require(
            accessControls.hasRole(ALLOCATOR_ROLE, msg.sender),
            AccessControlUnauthorizedAccount(msg.sender, ALLOCATOR_ROLE)
        );
    }

}
