// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

// Modified from src/interfaces/IMidnight.sol in
// https://github.com/morpho-org/midnight/tree/70607569ac348e9880b512ffd3b574be55405932
//
// Vendored verbatim because the market id is a hash over abi.encode(market): any layout drift
// silently changes every id.

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
    uint128 maxAssets;
    uint256 continuousFeeCap;
}
