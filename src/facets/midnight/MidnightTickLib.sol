// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

// Modified from src/libraries/TickLib.sol in
// https://github.com/morpho-org/midnight/tree/70607569ac348e9880b512ffd3b574be55405932
//
// The singleton exposes no tickToPrice view, and bounding offer prices on-chain needs the exact
// conversion it uses internally. The unchecked blocks are kept as upstream wrote them, for parity.

int256  constant LN_ONE_PLUS_DELTA   = 0.004987541511039073e18;  // floor(ln(1.005)e18)
uint256 constant MAX_TICK            = 6744;
uint256 constant PRICE_ROUNDING_STEP = 1e11;  // 1e-7 WAD, prices round to multiples

library MidnightTickLib {

    // The only deviation from upstream is the require string.
    function tickToPrice(uint256 tick) internal pure returns (uint256) {
        require(tick <= MAX_TICK, "MidnightTickLib/tick-out-of-range");
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

    // Returns x / d rounded to the nearest integer with ties rounded down, without overflow checks.
    function divHalfDownUnchecked(uint256 x, uint256 d) internal pure returns (uint256) {
        unchecked {
            return (x + (d - 1) / 2) / d;
        }
    }

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
