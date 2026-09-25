// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IMidnightFacet } from "./IMidnightFacet.sol";

interface IMidnightController {

    function midnight_VERSION() external pure returns (string memory);

    function midnight_setMarketConfig(
        bytes32 marketId,
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  minBuyYield,
        uint16  maxSellYield,
        uint16  maxContinuousFee,
        uint128 maxLossFactor
    ) external;

    function midnight_buy(
        bytes32                        marketId,
        IMidnightFacet.Fill[] calldata fills,
        uint256                        maxAssetsIn
    )
        external
        returns (uint256 assetsSpent);

    function midnight_redeem(bytes32 marketId, uint256 units, uint256 minAssetsOut)
        external
        returns (uint256 assetsWithdrawn);

    function midnight_sell(
        bytes32                        marketId,
        IMidnightFacet.Fill[] calldata fills,
        uint256                        minAssetsOut
    )
        external
        returns (uint256 assetsReceived);

    function midnight_getBuyRateLimitKey(bytes32 marketId) external pure returns (bytes32 key);

    function midnight_getMarketConfig(bytes32 marketId)
        external
        view
        returns (IMidnightFacet.MarketConfig memory config);

    function midnight_getRedeemRateLimitKey(bytes32 marketId) external pure returns (bytes32 key);

    function midnight_getSellRateLimitKey(bytes32 marketId) external pure returns (bytes32 key);

    function midnight_midnight() external view returns (address);

}
