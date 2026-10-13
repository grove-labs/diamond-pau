// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { CollateralParams, Market, Offer } from "../../facets/midnight/MidnightUtils.sol";

// Every `upstream:` reference in this file is a path under
// https://github.com/morpho-org/midnight/tree/70607569ac348e9880b512ffd3b574be55405932
//
// Vendored from upstream: src/ratifiers/libraries/HashLib.sol. The struct hashes must match
// upstream's byte for byte, or a quoter signature produced against the published typehashes would
// not verify here.


// upstream: HashLib.sol keccak256(COLLATERAL_PARAMS_TYPE)
bytes32 constant COLLATERAL_PARAMS_TYPEHASH =
    0x39ed3f928d24fd00574b1a02aba9c2483abcf5d9a3a366118c9a5aa29885b841;

// upstream: HashLib.sol keccak256(bytes.concat(MARKET_TYPE, COLLATERAL_PARAMS_TYPE))
bytes32 constant MARKET_TYPEHASH =
    0x510b3862f3816a109c9340b76972e8a30984246be06e034ae12ed2934220391a;

// upstream: HashLib.sol keccak256(bytes.concat(OFFER_TYPE, COLLATERAL_PARAMS_TYPE, MARKET_TYPE))
bytes32 constant OFFER_TYPEHASH =
    0x9905214264a9fb7b6cc1b0e33db7a04687c6e4185a84755d29914314aa9d8906;

library MidnightOfferHash {

    // upstream: HashLib.sol hashCollateralParams
    function hashCollateralParams(CollateralParams memory collateralParams)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                COLLATERAL_PARAMS_TYPEHASH,
                collateralParams.token,
                collateralParams.lltv,
                collateralParams.liquidationCursor,
                collateralParams.oracle
            )
        );
    }

    // upstream: HashLib.sol hashMarket
    function hashMarket(Market memory market) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](market.collateralParams.length);

        for (uint256 i; i < market.collateralParams.length; ++i) {
            hashes[i] = hashCollateralParams(market.collateralParams[i]);
        }

        return keccak256(
            abi.encode(
                MARKET_TYPEHASH,
                market.chainId,
                market.midnight,
                market.loanToken,
                keccak256(abi.encodePacked(hashes)),
                market.maturity,
                market.rcfThreshold,
                market.enterGate,
                market.liquidatorGate
            )
        );
    }

    // upstream: HashLib.sol hashOffer
    //
    // Split in two only to fit the legacy pipeline's stack; every field encodes to exactly one
    // word, so the concatenation is identical to encoding all sixteen at once.
    function hashOffer(Offer memory offer) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    OFFER_TYPEHASH,
                    hashMarket(offer.market),
                    offer.buy,
                    offer.maker,
                    offer.start,
                    offer.expiry,
                    offer.tick,
                    offer.group
                ),
                abi.encode(
                    offer.callback,
                    keccak256(offer.callbackData),
                    offer.receiverIfMakerIsSeller,
                    offer.ratifier,
                    offer.reduceOnly,
                    offer.maxUnits,
                    offer.maxAssets,
                    offer.continuousFeeCap
                )
            )
        );
    }

}
