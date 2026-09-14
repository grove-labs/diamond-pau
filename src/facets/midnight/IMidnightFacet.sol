// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IFacet } from "../IFacet.sol";

import { Offer } from "./MidnightUtils.sol";

/**
 * @title  IMidnightFacet
 * @notice PAU facet for lending through Morpho Midnight fixed-term markets as a taker.
 * @dev    The proxy only ever holds credit (lender units redeemable at par at maturity): it buys
 *         units from makers' sell offers, sells them back into makers' buy offers before maturity,
 *         and redeems them at par once repayments land. Every market is identified by its id, a
 *         hash committing to the full market config including the Midnight venue address.
 */
interface IMidnightFacet is IFacet {

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/

    /**
     * @notice Governance limits for one Midnight market. Fits in one storage slot.
     * @dev    `maxBuyTick == 0` disables entry. `minSellTick != 0` marks the market as onboarded
     *         and gates sell and redeem; it is an exit price floor and has to stay reachable
     *         (below par net of the settlement fee). The fee and loss guards only apply to entry.
     * @param  maxBuyTick       Highest offer tick a buy may pay (fee-adjusted at call time).
     * @param  minSellTick      Lowest offer tick a sell may accept (fee-adjusted at call time).
     * @param  maxContinuousFee Highest market continuous fee a buy tolerates (per second, WAD).
     * @param  maxLossFactor    Highest market loss factor a buy tolerates (fraction of
     *                          `type(uint128).max`).
     */
    struct MarketConfig {
        uint16  maxBuyTick;
        uint16  minSellTick;
        uint32  maxContinuousFee;
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
     * @notice Emitted when the governance limits for a Midnight market are updated.
     * @param  marketId         Identifier of the Midnight market.
     * @param  maxBuyTick       Highest offer tick a buy may pay.
     * @param  minSellTick      Lowest offer tick a sell may accept.
     * @param  maxContinuousFee Highest market continuous fee a buy tolerates.
     * @param  maxLossFactor    Highest market loss factor a buy tolerates.
     */
    event MidnightMarketConfigSet(
        bytes32 indexed marketId,
        uint16          maxBuyTick,
        uint16          minSellTick,
        uint32          maxContinuousFee,
        uint128         maxLossFactor
    );

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
     * @notice Buys credit units by taking makers' sell offers on one Midnight market.
     * @dev    Every offer must name the configured Midnight venue, hash to `marketId`, be a sell
     *         offer, and price at or below the configured `maxBuyTick` net of the current
     *         settlement fee. Reverts if the market's continuous fee or loss factor exceeds the
     *         configured tolerances, or if the market has never been touched on Midnight. The
     *         rate limit is decreased by the loan token actually spent.
     * @param  marketId     Identifier of the Midnight market.
     * @param  offers       Makers' sell offers to take, in order.
     * @param  ratifierData Per-offer opaque data forwarded to each maker's ratifier.
     * @param  units        Per-offer credit units to buy; must be non-zero.
     * @param  maxAssetsIn  Upper bound on loan token spent across the batch; also the allowance
     *                      granted to Midnight for the duration of the call.
     * @return assetsSpent  Loan token actually paid, fees included.
     */
    function buy(
        bytes32            marketId,
        Offer[]   calldata offers,
        bytes[]   calldata ratifierData,
        uint256[] calldata units,
        uint256            maxAssetsIn
    )
        external
        returns (uint256 assetsSpent);

    /**
     * @notice Redeems credit units at par out of the market's repayments.
     * @dev    Units are capped at both the proxy's live credit and the market's withdrawable
     *         amount, so passing `type(uint256).max` redeems everything currently available.
     *         The market is resolved from the id on the configured Midnight venue.
     * @param  marketId        Identifier of the Midnight market.
     * @param  units           Credit units to redeem before capping.
     * @param  minAssetsOut    Lower bound on loan token received.
     * @return assetsWithdrawn Loan token actually received.
     */
    function redeem(bytes32 marketId, uint256 units, uint256 minAssetsOut)
        external
        returns (uint256 assetsWithdrawn);

    /**
     * @notice Sells credit units by taking makers' buy offers on one Midnight market.
     * @dev    Every offer must name the configured Midnight venue, hash to `marketId`, be a buy
     *         offer, and price at or above the configured `minSellTick` plus the current
     *         settlement fee. Per-offer units are
     *         capped at the proxy's remaining live credit; the batch stops once credit runs out.
     *         The rate limit is decreased by the loan token actually received, and the same
     *         amount is restored on the buy limit when one is configured.
     * @param  marketId       Identifier of the Midnight market.
     * @param  offers         Makers' buy offers to take, in order.
     * @param  ratifierData   Per-offer opaque data forwarded to each maker's ratifier.
     * @param  units          Per-offer credit units to sell; must be non-zero.
     * @param  minAssetsOut   Lower bound on loan token received across the batch.
     * @return assetsReceived Loan token actually received, net of fees.
     */
    function sell(
        bytes32            marketId,
        Offer[]   calldata offers,
        bytes[]   calldata ratifierData,
        uint256[] calldata units,
        uint256            minAssetsOut
    )
        external
        returns (uint256 assetsReceived);

    /**
     * @notice Sets the governance limits for a Midnight market.
     * @dev    Reverts unless `maxBuyTick` and `minSellTick` are within Midnight's tick range,
     *         `minSellTick` is non-zero, and `maxContinuousFee` is within Midnight's ceiling.
     *         Setting `maxBuyTick` to zero blocks new entries while leaving exits open.
     * @param  marketId Identifier of the Midnight market.
     * @param  config   New limits.
     */
    function setMarketConfig(bytes32 marketId, MarketConfig calldata config) external;

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

}
