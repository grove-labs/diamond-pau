// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { IMidnightController } from "../../src/facets/midnight/IMidnightController.sol";

import { Market } from "../../src/facets/midnight/MidnightInterfaces.sol";

// Stub for the audited funding strategy, which lives outside this repo. It holds none of that
// contract's guards, so it proves only that the facet's own fundFill ladder holds.
contract MockFundingStrategy {

    bytes32 public constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address public immutable controller;

    constructor(address controller_) {
        controller = controller_;
    }

    function onBuy(
        bytes32         marketId,
        Market   memory market,
        uint256         buyerAssets,
        uint256         units,
        uint256         pendingFeeIncrease,
        address,
        bytes    memory
    )
        external
        returns (bytes32)
    {
        // Midnight pokes a consumed offer at zero, which fundFill rejects outright.
        if (buyerAssets == 0) return CALLBACK_SUCCESS;

        IMidnightController(controller).midnight_fundFill({
            marketId   : marketId,
            buy        : true,
            assets     : buyerAssets,
            units      : units,
            pendingFee : pendingFeeIncrease
        });

        IERC20(market.loanToken).approve(msg.sender, buyerAssets);

        return CALLBACK_SUCCESS;
    }

    function onSell(
        bytes32       marketId,
        Market memory,
        uint256       sellerAssets,
        uint256       units,
        uint256       pendingFeeDecrease,
        address,
        address,
        bytes  memory
    )
        external
        returns (bytes32)
    {
        if (units == 0) return CALLBACK_SUCCESS;

        // Midnight has already paid the proxy, so this only reports the fill for metering.
        IMidnightController(controller).midnight_fundFill({
            marketId   : marketId,
            buy        : false,
            assets     : sellerAssets,
            units      : units,
            pendingFee : pendingFeeDecrease
        });

        return CALLBACK_SUCCESS;
    }

}
