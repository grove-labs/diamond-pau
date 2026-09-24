// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

// Every `upstream:` reference in this file is a path under
// https://github.com/morpho-org/midnight/tree/70607569ac348e9880b512ffd3b574be55405932
//
// Structs are vendored verbatim from upstream: src/interfaces/IMidnight.sol because the market id
// is a hash over abi.encode(market): any layout drift silently changes every id.

struct CollateralParams {
    address token;
    uint256 lltv;
    uint256 liquidationCursor;
    address oracle;
}

struct Market {
    uint256            chainId;
    address            midnight;
    address            loanToken;
    CollateralParams[] collateralParams;
    uint256            maturity;
    uint256            rcfThreshold;
    address            enterGate;
    address            liquidatorGate;
}

struct Offer {
    Market  market;
    bool    buy;
    address maker;
    uint256 start;
    uint256 expiry;
    uint256 tick;
    bytes32 group;
    address callback;
    bytes   callbackData;
    address receiverIfMakerIsSeller;
    address ratifier;
    bool    reduceOnly;
    uint128 maxUnits;
    uint128 maxAssets;  // buyerAssets if offer.buy else sellerAssets
    uint256 continuousFeeCap;
}

library MidnightUtils {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    // upstream: src/libraries/TickLib.sol#L5-L8
    int256  internal constant LN_ONE_PLUS_DELTA   = 0.004987541511039073e18;  // floor(ln(1.005)e18)
    uint256 internal constant MAX_TICK            = 6744;
    uint256 internal constant PRICE_ROUNDING_STEP = 1e11;  // 1e-7 WAD, prices round to multiples

    // upstream: src/libraries/ConstantsLib.sol#L18
    uint32 internal constant MAX_CONTINUOUS_FEE = uint32(uint256(0.01e18) / uint256(365 days));

    // Not vendored: the units the facet's yield bounds are expressed in.
    uint256 internal constant WAD           = 1e18;
    uint256 internal constant YEAR          = 365 days;
    uint256 internal constant YIELD_BP_RATE = 1e14;  // one basis point per year, WAD

    // upstream: src/libraries/IdLib.sol#L23
    // Creation code prefix that deploys the appended data as runtime bytecode.
    bytes internal constant SSTORE2_PREFIX = hex"600b380380600b5f395ff3";

    /**********************************************************************************************/
    /*** Internal View/Pure Functions                                                           ***/
    /**********************************************************************************************/

    // upstream: src/libraries/IdLib.sol#L25-L36
    // The singleton exposes no toId view. The id is the full CREATE2 hash (salt 0) of the market
    // config stored as bytecode; its low 20 bytes are the address the config lives at. It is a
    // pure function of the full config.
    function toId(Market memory market) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                uint8(0xff),
                market.midnight,
                uint256(0),
                keccak256(abi.encodePacked(SSTORE2_PREFIX, abi.encode(market)))
            )
        );
    }

    // upstream: src/libraries/TickLib.sol#L50-L58
    // The singleton exposes no tickToPrice view; bounding offer prices on-chain needs the exact
    // conversion Midnight uses internally. The only deviation is the require string.
    function tickToPrice(uint256 tick) internal pure returns (uint256) {
        require(tick <= MAX_TICK, "MidnightFacet/tick-out-of-range");
        unchecked {
            return divHalfDownUnchecked(
                divHalfDownUnchecked(
                    uint256(1e36),
                    1e18 + wExp(LN_ONE_PLUS_DELTA * (int256(MAX_TICK / 2) - int256(tick)))
                ),
                PRICE_ROUNDING_STEP
            ) * PRICE_ROUNDING_STEP;
        }
    }

    // upstream: src/libraries/TickLib.sol#L17-L22
    // Returns x / d rounded to the nearest integer with ties rounded down, without overflow checks.
    function divHalfDownUnchecked(uint256 x, uint256 d) internal pure returns (uint256) {
        unchecked {
            return (x + (d - 1) / 2) / d;
        }
    }

    // Not vendored, no upstream counterpart: Midnight bounds trades in price space, so a yield
    // bound has to be turned into the price it implies at the current time to maturity. Simple
    // interest, ACT/365, over what a unit actually returns: par less the continuous fee
    // crystallized for the remaining term (upstream: src/Midnight.sol#L417).

    // Highest all-in price a buy can pay and still earn `minYield` basis points a year.
    function maxBuyPrice(uint256 minYield, uint256 timeToMaturity, uint256 continuousFee)
        internal
        pure
        returns (uint256)
    {
        return _yieldPrice(minYield, timeToMaturity, continuousFee, false);
    }

    // Lowest net price a sell can accept and still give up at most `maxYield` basis points a year.
    function minSellPrice(uint256 maxYield, uint256 timeToMaturity, uint256 continuousFee)
        internal
        pure
        returns (uint256)
    {
        return _yieldPrice(maxYield, timeToMaturity, continuousFee, true);
    }

    // Rounds against the caller: down for the buy ceiling, up for the sell floor.
    function _yieldPrice(
        uint256 yieldBp,
        uint256 timeToMaturity,
        uint256 continuousFee,
        bool    roundUp
    )
        private
        pure
        returns (uint256)
    {
        // Upstream caps maturity 100 years out and the continuous fee at one percent a year, so
        // the crystallized fee stays below par.
        uint256 numerator   = (WAD - continuousFee * timeToMaturity) * YEAR * WAD;
        uint256 denominator = YEAR * WAD + yieldBp * YIELD_BP_RATE * timeToMaturity;

        return roundUp ? (numerator + denominator - 1) / denominator : numerator / denominator;
    }

    // upstream: src/libraries/TickLib.sol#L24-L48
    function wExp(int256 x) internal pure returns (uint256) {
        unchecked {
            if (x < 0) {
                return 1e36 / wExp(-x);
            } else {
                int256 ln2 = 0.693147180559945309e18;  // floor(ln(2) * 1e18)
                // Chosen so that 2 * expR(-offset) == expR(ln2 - offset - 1), keeping wExp
                // non-decreasing.
                int256 offset = 0.32261121498945987e18;
                int256 q = (x + offset) / ln2;
                int256 r = x - q * ln2;
                int256 secondTerm = r * r / (2 * 1e18);
                int256 thirdTerm = secondTerm * r / (3 * 1e18);
                int256 expR = 1e18 + r + secondTerm + thirdTerm;
                // q is non-negative because x is non-negative in this branch; expR is positive
                // because |r| < ln2 < 1e18 and |secondTerm| > |thirdTerm|.
                return uint256(expR) << uint256(q);
            }
        }
    }

}
