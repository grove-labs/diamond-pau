// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IFacet } from "../IFacet.sol";

import { Market, Offer } from "./MidnightInterfaces.sol";

/**
 * @title  IMidnightFacet
 * @notice PAU facet for lending through Morpho Midnight fixed-term markets as taker and maker.
 * @dev    The proxy only ever holds credit (lender units redeemable at par at maturity): it buys
 *         units from makers' sell offers, sells them back into makers' buy offers before maturity,
 *         and redeems them at par once repayments land. Every market is identified by its id, a
 *         hash committing to the full market config including the Midnight venue address.
 * @dev    As a maker the proxy rests its own signed offers. A fill reaches `fundFill` through the
 *         funding strategy named as the offer's callback. A strategy holds no role: it is
 *         onboarded per market and direction by its own rate limit key, so no standing token
 *         approval is needed.
 */
interface IMidnightFacet is IFacet {

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/

    /**
     * @notice Offer groups the proxy's resting offers must sit in, one per direction.
     * @dev    Separate groups let the entry and exit books be cancelled independently, since
     *         cancelling consumes a whole group. Zero is the unset state, which bars both
     *         directions; once set, both groups are non-zero and distinct.
     * @param  buyGroup  Group every resting buy (entry) offer must name.
     * @param  sellGroup Group every resting sell (exit) offer must name.
     */
    struct DesignatedGroups {
        bytes32 buyGroup;
        bytes32 sellGroup;
    }

    /**
     * @notice Make-side limits for one Midnight market. Fits in two storage slots.
     * @dev    `maxOfferSize` caps the loan token a single fill may move, in either direction, and
     *         `maxOfferSize == 0` disables making, independently of take onboarding. Maturity and
     *         loan token are copied from the `Market` that produced the id, and `toId` commits to
     *         every field, so neither can disagree with the market they describe. They are stored
     *         rather than read per fill because `toMarket` resolves the config from contract code.
     * @param  maxOfferSize Largest loan token amount a single fill may move.
     * @param  maturity     Market maturity, used to price the remaining term on a fill.
     * @param  loanToken    Market loan token, the asset a fill is funded in.
     */
    struct MakeConfig {
        uint256 maxOfferSize;
        uint64  maturity;
        address loanToken;
    }

    /**
     * @notice Governance limits for one Midnight market. Fits in one storage slot.
     * @dev    `maxBuyTick == 0` disables entry. `minSellTick != 0` marks the market as onboarded
     *         and gates sell and redeem; it is an exit price floor and has to stay reachable
     *         (below par net of the settlement fee). The fee and loss guards only apply to entry.
     * @dev    Each leg is bounded twice, by an absolute price tick and by an implied yield, and
     *         the stricter of the two binds. The yield bounds are in basis points a year, simple
     *         interest over ACT/365, measured on the all-in cash flow: both the settlement fee
     *         and the continuous fee crystallized over the remaining term are inside the
     *         comparison. They tighten towards par as maturity approaches, so at maturity a sell
     *         only clears at par. `minBuyYield == 0` still bars paying above what a unit returns.
     */
    struct MarketConfig {
        uint16  maxBuyTick;
        uint16  minSellTick;
        uint16  minBuyYield;
        uint16  maxSellYield;
        uint16  maxContinuousFee;
        uint128 maxLossFactor;
    }

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    /**
     * @notice Emitted when the proxy buys credit units from makers' sell offers.
     * @param  marketId    Identifier of the Midnight market.
     * @param  units       Total credit units bought.
     * @param  assetsSpent Loan token actually paid, fees included.
     */
    event MidnightBuy(bytes32 indexed marketId, uint256 units, uint256 assetsSpent);

    /**
     * @notice Emitted when the designated offer groups for a Midnight market are updated.
     * @param  marketId  Identifier of the Midnight market.
     * @param  buyGroup  Group every resting buy offer must name.
     * @param  sellGroup Group every resting sell offer must name.
     */
    event MidnightDesignatedGroupsSet(
        bytes32 indexed marketId,
        bytes32         buyGroup,
        bytes32         sellGroup
    );

    /**
     * @notice Emitted when a fill of one of the proxy's resting offers is settled.
     * @param  marketId Identifier of the Midnight market.
     * @param  callback Offer callback that reported the fill.
     * @param  buy      True when the proxy was the buyer, in which case the loan token was sent.
     * @param  assets   Loan token sent to the callback on a buy, or received by the proxy on a
     *                  sell.
     * @param  units    Credit units the fill moves for the proxy.
     */
    event MidnightFillFunded(
        bytes32 indexed marketId,
        address indexed callback,
        bool            buy,
        uint256         assets,
        uint256         units
    );

    /**
     * @notice Emitted when the make-side limits for a Midnight market are updated.
     * @param  marketId     Identifier of the Midnight market.
     * @param  maxOfferSize Largest loan token amount a single fill may move.
     * @param  maturity     Market maturity, as committed to by the market id.
     * @param  loanToken    Market loan token, as committed to by the market id.
     */
    event MidnightMakeConfigSet(
        bytes32 indexed marketId,
        uint256         maxOfferSize,
        uint64          maturity,
        address         loanToken
    );

    /**
     * @notice Emitted when the governance limits for a Midnight market are updated.
     * @param  marketId         Identifier of the Midnight market.
     * @param  maxBuyTick       Highest offer tick a buy may pay.
     * @param  minSellTick      Lowest offer tick a sell may accept.
     * @param  minBuyYield      Lowest implied yield a buy may accept (basis points a year).
     * @param  maxSellYield     Highest implied yield a sell may give up (basis points a year).
     * @param  maxContinuousFee Highest market continuous fee a buy tolerates (centi-basis points
     *                          a year).
     * @param  maxLossFactor    Highest market loss factor a buy tolerates.
     */
    event MidnightMarketConfigSet(
        bytes32 indexed marketId,
        uint16          maxBuyTick,
        uint16          minSellTick,
        uint16          minBuyYield,
        uint16          maxSellYield,
        uint16          maxContinuousFee,
        uint128         maxLossFactor
    );

    /**
     * @notice Emitted when the proxy cancels one of its offer groups on Midnight.
     * @param  group Offer group consumed to its maximum.
     */
    event MidnightOfferGroupCancelled(bytes32 indexed group);

    /**
     * @notice Emitted when the proxy's ratifier authorization on Midnight is changed.
     * @dev    An authorized ratifier can act for the proxy across Midnight, so this is the loudest
     *         event the facet emits.
     * @param  ratifier   Address whose authorization changed.
     * @param  authorized Whether the address may now ratify the proxy's offers.
     */
    event MidnightRatifierAuthorizationSet(address indexed ratifier, bool authorized);

    /**
     * @notice Emitted when the proxy redeems credit units at par from repayments.
     * @param  marketId        Identifier of the Midnight market.
     * @param  units           Credit units redeemed.
     * @param  assetsWithdrawn Loan token actually received.
     */
    event MidnightRedeem(bytes32 indexed marketId, uint256 units, uint256 assetsWithdrawn);

    /**
     * @notice Emitted when the proxy sells credit units into makers' buy offers.
     * @param  marketId       Identifier of the Midnight market.
     * @param  units          Total credit units sold.
     * @param  assetsReceived Loan token actually received, net of fees.
     */
    event MidnightSell(bytes32 indexed marketId, uint256 units, uint256 assetsReceived);

    /**********************************************************************************************/
    /*** Interactive Functions                                                                  ***/
    /**********************************************************************************************/

    /**
     * @notice Buys credit units by taking one maker's sell offer on a Midnight market.
     * @dev    The offer must name the configured Midnight venue, hash to `marketId`, be a sell
     *         offer, price at or below the configured `maxBuyTick` minus the current settlement
     *         fee, and clear `minBuyYield` once the settlement fee and the continuous fee for the
     *         remaining term are counted in. Reverts if the market's continuous fee or loss factor
     *         exceeds the configured tolerances, or if the market has never been touched on
     *         Midnight. The buy rate limit is decreased by the higher of the proxy's balance
     *         delta and the assets Midnight reports the buyer paid.
     * @param  marketId     Identifier of the Midnight market.
     * @param  offer        Maker's sell offer to take.
     * @param  ratifierData Opaque data forwarded to the maker's ratifier.
     * @param  units        Credit units to take from the offer; must be non-zero.
     * @param  maxAssetsIn  Upper bound on loan token spent; also the allowance granted to
     *                      Midnight for the duration of the call.
     * @return assetsSpent  Loan token actually paid, fees included.
     */
    function buy(
        bytes32         marketId,
        Offer  calldata offer,
        bytes  calldata ratifierData,
        uint256         units,
        uint256         maxAssetsIn
    )
        external
        returns (uint256 assetsSpent);

    /**
     * @notice Cancels every resting offer in one of the proxy's offer groups.
     * @dev    Consumes the group to its maximum on Midnight, which is irreversible for that group:
     *         consumption only ever increases. Risk-reducing, so it is allocator-callable, and it
     *         is the only way to retire offers already published to the mempool. Groups are
     *         per-direction, so the entry and exit books can be cancelled separately.
     * @param  group Offer group to consume.
     */
    function cancelOfferGroup(bytes32 group) external;

    /**
     * @notice Settles a fill of one of the proxy's resting offers, funding it when the proxy buys.
     * @dev    Called by the funding strategy named as the offer's callback, from inside Midnight's
     *         settlement. Carries no role on purpose: the caller's own strategy key for the market
     *         and direction is the authorization, so an unset key reverts with
     *         `RateLimits/zero-maxAmount` before anything moves, and zeroing it offboards the
     *         strategy for offers already published.
     * @dev    On a buy the loan token is sent to the caller, which is what Midnight then pulls. The
     *         fill must clear the configured loss factor, meet the configured fee ceiling against
     *         the market's live continuous fee, and price at or below the stricter of the
     *         configured entry tick and entry yield. On a sell the proceeds have already reached
     *         the proxy, so nothing moves here; the fill must price at or above the stricter of the
     *         configured exit tick and exit yield, and must leave the proxy free of debt on the
     *         market, which is what stops an exit from opening a short.
     * @dev    In both directions `assets` must not exceed the market's `maxOfferSize`, which caps
     *         each fill rather than an offer's total size.
     * @dev    `pendingFee` only ever tightens the exit bound. It is clamped to the fee the proxy's
     *         position actually carries, read back from the venue, so a caller cannot widen its own
     *         floor by overstating the lien it sheds.
     * @dev    A fill decreases two keys for its direction, the caller's strategy key first and then
     *         the per-market key it shares with the taker legs. Neither direction restores
     *         anything.
     * @param  marketId   Identifier of the Midnight market.
     * @param  buying     True when the proxy is the buyer, so the fill is an entry.
     * @param  assets     Loan token the settlement moves, as reported by the caller.
     * @param  units      Credit units the fill moves for the proxy, as reported by the caller.
     * @param  pendingFee Pending fee the fill adds on a buy or sheds on a sell, as reported by the
     *                    caller. Used only on a sell, and only as far as the venue corroborates it.
     */
    function fundFill(
        bytes32 marketId,
        bool    buying,
        uint256 assets,
        uint256 units,
        uint256 pendingFee
    ) external;

    /**
     * @notice Redeems credit units at par out of the market's repayments.
     * @dev    Units are capped at both the proxy's live credit and the market's withdrawable
     *         amount, so passing `type(uint256).max` redeems everything currently available.
     *         The market is resolved from the id on the configured Midnight venue. The redeem
     *         rate limit is decreased by the loan token actually received; nothing is restored.
     * @param  marketId        Identifier of the Midnight market.
     * @param  units           Credit units to redeem before capping.
     * @param  minAssetsOut    Lower bound on loan token received.
     * @return assetsWithdrawn Loan token actually received.
     */
    function redeem(bytes32 marketId, uint256 units, uint256 minAssetsOut)
        external
        returns (uint256 assetsWithdrawn);

    /**
     * @notice Sells credit units by taking one maker's buy offer on a Midnight market.
     * @dev    The offer must name the configured Midnight venue, hash to `marketId`, be a buy
     *         offer, price at or above the configured `minSellTick` plus the current settlement
     *         fee, and give up no more than `maxSellYield` measured on the proceeds net of that
     *         fee. Units are capped at the proxy's live credit, and a position with none left to
     *         sell reverts. The sell rate limit is decreased by the loan token actually received;
     *         nothing is restored.
     * @param  marketId       Identifier of the Midnight market.
     * @param  offer          Maker's buy offer to take.
     * @param  ratifierData   Opaque data forwarded to the maker's ratifier.
     * @param  units          Credit units to take from the offer before capping; must be non-zero.
     * @param  minAssetsOut   Lower bound on loan token received.
     * @return assetsReceived Loan token actually received, net of fees.
     */
    function sell(
        bytes32         marketId,
        Offer  calldata offer,
        bytes  calldata ratifierData,
        uint256         units,
        uint256         minAssetsOut
    )
        external
        returns (uint256 assetsReceived);

    /**
     * @notice Sets the offer groups the proxy's resting offers must sit in on one market.
     * @dev    One group per direction, so cancelling the entry book leaves the exit book alive.
     *         Reverts unless both groups are non-zero and distinct. A market meant to trade in
     *         one direction only leaves the other direction's rate limit keys unset.
     * @param  marketId  Identifier of the Midnight market.
     * @param  buyGroup  Group every resting buy offer must name.
     * @param  sellGroup Group every resting sell offer must name.
     */
    function setDesignatedGroups(bytes32 marketId, bytes32 buyGroup, bytes32 sellGroup) external;

    /**
     * @notice Sets the make-side limits for a Midnight market.
     * @dev    Takes the whole `Market` rather than an id so that maturity and loan token are
     *         committed to by the id they are stored under and can never be passed loose. Reverts
     *         unless the market names the configured venue, is already take-onboarded, and exists
     *         on Midnight, so a mistyped or uncreated market fails in the spell instead of
     *         silently resting an unfillable book. A cap above `type(uint128).max` is rejected,
     *         since Midnight moves at most that much in one fill and a larger cap could never
     *         bind. Setting `maxOfferSize` to zero disables making.
     * @param  market       Full market config; its id is derived here.
     * @param  maxOfferSize Largest loan token amount a single fill may move.
     */
    function setMakeConfig(Market calldata market, uint256 maxOfferSize) external;

    /**
     * @notice Sets the governance limits for a Midnight market.
     * @dev    Reverts unless `maxBuyTick` and `minSellTick` are within Midnight's tick range,
     *         `minSellTick` and `maxSellYield` are non-zero, and `maxContinuousFee` is within
     *         Midnight's ceiling. Setting `maxBuyTick` to zero blocks new entries while leaving
     *         exits open.
     * @param  marketId         Identifier of the Midnight market.
     * @param  maxBuyTick       Highest offer tick a buy may pay (fee-adjusted at call time).
     * @param  minSellTick      Lowest offer tick a sell may accept (fee-adjusted at call time).
     * @param  minBuyYield      Lowest implied yield a buy may accept (basis points a year).
     * @param  maxSellYield     Highest implied yield a sell may give up (basis points a year).
     * @param  maxContinuousFee Highest market continuous fee a buy tolerates (centi-basis points
     *                          a year).
     * @param  maxLossFactor    Highest market loss factor a buy tolerates (fraction of
     *                          `type(uint128).max`).
     */
    function setMarketConfig(
        bytes32 marketId,
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  minBuyYield,
        uint16  maxSellYield,
        uint16  maxContinuousFee,
        uint128 maxLossFactor
    ) external;

    /**
     * @notice Authorizes or de-authorizes a ratifier to ratify the proxy's resting offers.
     * @dev    Midnight requires the maker to have authorized the ratifier its offers name, so
     *         making cannot work without this. Midnight's authorization is not scoped to
     *         ratification: an authorized address can act for the proxy across the venue,
     *         including authorizing further addresses, so only an immutable contract that never
     *         calls Midnight outside a view may be named here. De-authorizing is the one switch
     *         that kills every resting offer at once, including offers already published.
     * @param  ratifier   Address to authorize or de-authorize.
     * @param  authorized Whether the address may ratify the proxy's offers.
     */
    function setRatifierAuthorization(address ratifier, bool authorized) external;

    /**********************************************************************************************/
    /*** Variables                                                                              ***/
    /**********************************************************************************************/

    /// @notice Address of the Midnight singleton entries are pinned to (immutable).
    function midnight() external view returns (address);

    /**********************************************************************************************/
    /*** View/Pure Functions                                                                    ***/
    /**********************************************************************************************/

    /**
     * @notice Returns the derived buy rate limit key for a Midnight market.
     * @param  marketId Identifier of the Midnight market.
     * @return key      Derived rate limit key.
     */
    function getBuyRateLimitKey(bytes32 marketId) external pure returns (bytes32 key);

    /**
     * @notice Returns the designated offer groups for a Midnight market.
     * @param  marketId Identifier of the Midnight market.
     * @return groups   Designated groups. A zero group bars that direction.
     */
    function getDesignatedGroups(bytes32 marketId)
        external
        view
        returns (DesignatedGroups memory groups);

    /**
     * @notice Returns the make-side limits configured for a Midnight market.
     * @param  marketId Identifier of the Midnight market.
     * @return config   Configured limits. A zero `maxOfferSize` means making is disabled.
     */
    function getMakeConfig(bytes32 marketId) external view returns (MakeConfig memory config);

    /**
     * @notice Returns the governance limits configured for a Midnight market.
     * @param  marketId Identifier of the Midnight market.
     * @return config   Configured limits. All-zero means not onboarded.
     */
    function getMarketConfig(bytes32 marketId) external view returns (MarketConfig memory config);

    /**
     * @notice Returns the derived redeem rate limit key for a Midnight market.
     * @param  marketId Identifier of the Midnight market.
     * @return key      Derived rate limit key.
     */
    function getRedeemRateLimitKey(bytes32 marketId) external pure returns (bytes32 key);

    /**
     * @notice Returns the derived sell rate limit key for a Midnight market.
     * @param  marketId Identifier of the Midnight market.
     * @return key      Derived rate limit key.
     */
    function getSellRateLimitKey(bytes32 marketId) external pure returns (bytes32 key);

    /**
     * @notice Returns the derived maker buy rate limit key for one strategy on a Midnight market.
     * @param  strategy Funding strategy the key meters.
     * @param  marketId Identifier of the Midnight market.
     * @return key      Derived rate limit key.
     */
    function getStrategyBuyRateLimitKey(address strategy, bytes32 marketId)
        external
        pure
        returns (bytes32 key);

    /**
     * @notice Returns the derived maker sell rate limit key for one strategy on a Midnight market.
     * @param  strategy Funding strategy the key meters.
     * @param  marketId Identifier of the Midnight market.
     * @return key      Derived rate limit key.
     */
    function getStrategySellRateLimitKey(address strategy, bytes32 marketId)
        external
        pure
        returns (bytes32 key);

    /**
     * @notice Returns whether an offer callback may settle fills in one direction on a market.
     * @dev    True only for a non-zero callback on a market with making enabled whose strategy key
     *         and per-market key for that direction both have a non-zero `maxAmount`. Reads the
     *         configured ceilings, not the capacity left, so a drained key still answers true.
     * @param  marketId Identifier of the Midnight market.
     * @param  callback Offer callback address.
     * @param  buying   True for a buy offer, whose fills reach the callback's `onBuy`.
     * @return allowed  Whether fills naming this callback in this direction can be funded.
     */
    function isCallbackAllowed(bytes32 marketId, address callback, bool buying)
        external
        view
        returns (bool allowed);

}
