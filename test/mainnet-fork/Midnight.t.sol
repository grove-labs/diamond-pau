// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Market, MidnightUtils } from "../../src/facets/midnight/MidnightUtils.sol";

import { ForkTestBase } from "./ForkTestBase.t.sol";

interface IMidnightLike {

    function toMarket(bytes32 id) external view returns (Market memory);

}

abstract contract Midnight_TestBase is ForkTestBase {

    // https://docs.morpho.org/get-started/resources/addresses/#morpho-midnight
    address internal constant MIDNIGHT        = 0x471686c42792F93528B000beF54bC10E3aa2045f;
    address internal constant SETTER_RATIFIER = 0xb72c416382c8A6399D0765CebfB032F040B00B3c;

    // Live mainnet markets at the pinned block, from GET /v0/midnight/markets?chain_ids=1.
    bytes32 internal constant LIVE_MARKET_ID_1 =
        0xb21ce1d6ad577ee45d09d0a9934f658e65603ff7f1ac5958a7bf12dbfa560b24;
    bytes32 internal constant LIVE_MARKET_ID_2 =
        0x9ac6a639ace1c291b68b212eb1a95fd080332793f7bfc7dbed58b92bc518ca70;
    bytes32 internal constant LIVE_MARKET_ID_3 =
        0x2a9ae59053a64e409e819d3b76750948e06065b3164278915eb80cb1b7474b65;

    IMidnightLike internal constant midnight = IMidnightLike(MIDNIGHT);

    function _getBlock() internal pure override returns (uint256) {
        return 25970000;  // September 2026 (Midnight live on mainnet since July 2026)
    }

}

contract MainnetController_Midnight_Utils_Tests is Midnight_TestBase {

    // The vendored structs must hash to the same id the singleton derives, or every market
    // check in the facet is silently wrong. The live ids are the oracle for the struct layout.
    function test_toId_matchesLiveMarkets() public view {
        assertEq(MidnightUtils.toId(midnight.toMarket(LIVE_MARKET_ID_1)), LIVE_MARKET_ID_1);
        assertEq(MidnightUtils.toId(midnight.toMarket(LIVE_MARKET_ID_2)), LIVE_MARKET_ID_2);
        assertEq(MidnightUtils.toId(midnight.toMarket(LIVE_MARKET_ID_3)), LIVE_MARKET_ID_3);
    }

    function test_toId_liveMarketsBindToVenue() public view {
        assertEq(midnight.toMarket(LIVE_MARKET_ID_1).midnight, MIDNIGHT);
        assertEq(midnight.toMarket(LIVE_MARKET_ID_1).chainId,  1);
    }

}
