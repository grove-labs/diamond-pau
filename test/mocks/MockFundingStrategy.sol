// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 }    from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMidnightController } from "../../src/facets/midnight/IMidnightController.sol";

import { Market } from "../../src/facets/midnight/MidnightInterfaces.sol";

// Stand-in for the audited funding strategy, which lives outside this repo. It mirrors that
// contract's caller and party checks, so a fill it settles is one the real strategy would settle.
contract MockFundingStrategy {

    bytes32 public constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address public immutable midnight;
    address public immutable proxy;
    address public immutable controller;

    constructor(address midnight_, address proxy_, address controller_) {
        midnight   = midnight_;
        proxy      = proxy_;
        controller = controller_;
    }

    function onBuy(
        bytes32         marketId,
        Market   memory market,
        uint256         buyerAssets,
        uint256         units,
        uint256         pendingFeeIncrease,
        address         buyer,
        bytes    memory
    )
        external
        returns (bytes32)
    {
        require(msg.sender == midnight, "MockFundingStrategy/not-midnight");
        require(buyer      == proxy,    "MockFundingStrategy/buyer-not-proxy");

        // A zero-unit take or a dust fill rounds the price to nothing, which fundFill rejects.
        if (buyerAssets == 0) return CALLBACK_SUCCESS;

        IMidnightController(controller).midnight_fundFill({
            marketId   : marketId,
            buy        : true,
            assets     : buyerAssets,
            units      : units,
            pendingFee : pendingFeeIncrease
        });

        SafeERC20.forceApprove(IERC20(market.loanToken), midnight, buyerAssets);

        return CALLBACK_SUCCESS;
    }

    function onSell(
        bytes32       marketId,
        Market memory,
        uint256       sellerAssets,
        uint256       units,
        uint256       pendingFeeDecrease,
        address       seller,
        address       receiver,
        bytes  memory
    )
        external
        returns (bytes32)
    {
        require(msg.sender == midnight, "MockFundingStrategy/not-midnight");
        require(seller     == proxy,    "MockFundingStrategy/seller-not-proxy");
        require(receiver   == proxy,    "MockFundingStrategy/receiver-not-proxy");

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
