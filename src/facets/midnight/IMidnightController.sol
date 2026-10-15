// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IMidnightFacet } from "./IMidnightFacet.sol";

import { Market } from "./MidnightUtils.sol";

interface IMidnightController {

    function midnight_VERSION() external pure returns (string memory);

    function midnight_setCallbackAllowed(bytes32 marketId, address callback, bool allowed)
        external;

    function midnight_setDesignatedGroups(bytes32 marketId, bytes32 buyGroup, bytes32 sellGroup)
        external;

    function midnight_setMakeConfig(Market calldata market, uint256 maxOfferSize) external;

    function midnight_setMarketConfig(
        bytes32 marketId,
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  minBuyYield,
        uint16  maxSellYield,
        uint16  maxContinuousFee,
        uint128 maxLossFactor
    ) external;

    function midnight_setRatifierAuthorization(address ratifier, bool authorized) external;

    function midnight_cancelOfferGroup(bytes32 group) external;

    function midnight_fundFill(
        bytes32 marketId,
        bool    buy,
        uint256 assets,
        uint256 units,
        uint256 pendingFee
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

    function midnight_getDesignatedGroups(bytes32 marketId)
        external
        view
        returns (IMidnightFacet.DesignatedGroups memory groups);

    function midnight_getMakeConfig(bytes32 marketId)
        external
        view
        returns (IMidnightFacet.MakeConfig memory config);

    function midnight_getMakeRateLimitKey(bytes32 marketId) external pure returns (bytes32 key);

    function midnight_getMarketConfig(bytes32 marketId)
        external
        view
        returns (IMidnightFacet.MarketConfig memory config);

    function midnight_getRedeemRateLimitKey(bytes32 marketId) external pure returns (bytes32 key);

    function midnight_getSellRateLimitKey(bytes32 marketId) external pure returns (bytes32 key);

    function midnight_isCallbackAllowed(bytes32 marketId, address callback)
        external
        view
        returns (bool allowed);

    function midnight_midnight() external view returns (address);

}
