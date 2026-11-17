// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

library MidnightUtils {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    // Mirrors the ceiling in https://github.com/morpho-org/midnight/blob/70607569ac348e9880b512ffd3b574be55405932/src/libraries/ConstantsLib.sol
    uint32 internal constant MAX_CONTINUOUS_FEE = uint32(uint256(0.01e18) / uint256(365 days));

    uint256 internal constant WAD           = 1e18;
    uint256 internal constant YEAR          = 365 days;
    uint256 internal constant YIELD_BP_RATE = 1e14;  // one basis point per year, WAD
    uint256 internal constant FEE_CBP_RATE  = 1e12;  // one centi-basis point per year, WAD

    /**********************************************************************************************/
    /*** Internal Pure Functions                                                                ***/
    /**********************************************************************************************/

    function continuousFeePerSecond(uint256 cbpsPerYear) internal pure returns (uint256) {
        return cbpsPerYear * FEE_CBP_RATE / YEAR;
    }

    function maxBuyPrice(uint256 minYield, uint256 timeToMaturity, uint256 continuousFee)
        internal
        pure
        returns (uint256)
    {
        return _yieldPrice(minYield, timeToMaturity, continuousFee * timeToMaturity, false);
    }

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
        if (credit == 0) return WAD;

        return _yieldPrice(maxYield, timeToMaturity, pendingFee * WAD / credit, true);
    }

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
        uint256 numerator   = (WAD - feePerUnit) * YEAR * WAD;
        uint256 denominator = YEAR * WAD + yieldBp * YIELD_BP_RATE * timeToMaturity;

        return roundUp ? (numerator + denominator - 1) / denominator : numerator / denominator;
    }

}
