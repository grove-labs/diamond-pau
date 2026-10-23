// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

// Nothing here is vendored. Inline `src/...` citations are paths in
// https://github.com/morpho-org/midnight/tree/70607569ac348e9880b512ffd3b574be55405932

library MidnightUtils {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    // Mirrors the ceiling in src/libraries/ConstantsLib.sol.
    uint32 internal constant MAX_CONTINUOUS_FEE = uint32(uint256(0.01e18) / uint256(365 days));

    // The units the facet's yield bounds are expressed in.
    uint256 internal constant WAD           = 1e18;
    uint256 internal constant YEAR          = 365 days;
    uint256 internal constant YIELD_BP_RATE = 1e14;  // one basis point per year, WAD
    uint256 internal constant FEE_CBP_RATE  = 1e12;  // one centi-basis point per year, WAD

    /**********************************************************************************************/
    /*** Internal Pure Functions                                                                ***/
    /**********************************************************************************************/

    // Governance names the continuous fee ceiling as an annual rate, while the market stores it per
    // second and charges it over the remaining term. Floors, so the effective ceiling never exceeds
    // the rate governance named.
    function continuousFeePerSecond(uint256 cbpsPerYear) internal pure returns (uint256) {
        return cbpsPerYear * FEE_CBP_RATE / YEAR;
    }

    // Midnight bounds trades in price space, so a yield bound has to be turned into the price it
    // implies at the current time to maturity. Simple interest, ACT/365, over what a unit actually
    // returns: par less the continuous fee still owed on it (src/Midnight.sol#L417).

    // Highest all-in price a buy can pay and still earn `minYield` basis points a year. Entering
    // fixes the market's current rate onto the new units, so that rate is what the buyer owes.
    function maxBuyPrice(uint256 minYield, uint256 timeToMaturity, uint256 continuousFee)
        internal
        pure
        returns (uint256)
    {
        return _yieldPrice(minYield, timeToMaturity, continuousFee * timeToMaturity, false);
    }

    // Lowest net price a sell can accept and still give up at most `maxYield` basis points a year.
    // A position keeps the fee it was bought at, so the floor prices the lien the position still
    // carries (src/Midnight.sol#L51-L53) rather than the market's current rate.
    function minSellPrice(
        uint256 maxYield,
        uint256 timeToMaturity,
        uint256 credit,
        uint256 pendingFee
    )
        internal
        pure
        returns (uint256)
    {
        // Nothing held is nothing to price, and par is the strictest floor.
        if (credit == 0) return WAD;

        return _yieldPrice(maxYield, timeToMaturity, pendingFee * WAD / credit, true);
    }

    // `feePerUnit` is the fee still owed over the remaining term, as a WAD fraction of one unit.
    // Rounds against the caller: down for the buy ceiling, up for the sell floor.
    function _yieldPrice(
        uint256 yieldBp,
        uint256 timeToMaturity,
        uint256 feePerUnit,
        bool    roundUp
    )
        private
        pure
        returns (uint256)
    {
        // Upstream caps maturity 100 years out and the continuous fee at one percent a year, and a
        // position's pending fee never exceeds its credit, so the fee stays below par either way.
        uint256 numerator   = (WAD - feePerUnit) * YEAR * WAD;
        uint256 denominator = YEAR * WAD + yieldBp * YIELD_BP_RATE * timeToMaturity;

        return roundUp ? (numerator + denominator - 1) / denominator : numerator / denominator;
    }

}
