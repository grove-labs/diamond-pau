// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import { Market } from "./MidnightInterfaces.sol";

// Modified from src/libraries/IdLib.sol in
// https://github.com/morpho-org/midnight/tree/70607569ac348e9880b512ffd3b574be55405932
//
// The singleton exposes no toId view. The id is the full CREATE2 hash (salt 0) of the market config
// stored as bytecode; its low 20 bytes are the address the config lives at. It is a pure function
// of the full config, so an address-derivation helper would never match.

library MidnightIdLib {

    // Creation code prefix that deploys the appended data as runtime bytecode.
    bytes internal constant SSTORE2_PREFIX = hex"600b380380600b5f395ff3";

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

}
