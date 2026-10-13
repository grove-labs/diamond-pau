// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {
    SafeERC20
} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    ReentrancyGuard
} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { IMidnightController } from "../facets/midnight/IMidnightController.sol";

import { Market } from "../facets/midnight/MidnightUtils.sol";

// Every `upstream:` reference in this file is a path under
// https://github.com/morpho-org/midnight/tree/70607569ac348e9880b512ffd3b574be55405932

// Funds one maker buy fill. Midnight names this contract as the offer's callback and therefore as
// the payer, and its only authorization is the (strategy, market) pair limit governance can zero.
contract ProxyFundingStrategy is ReentrancyGuard {

    using SafeERC20 for IERC20;

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    event Skimmed(address indexed token, uint256 amount);

    /**********************************************************************************************/
    /*** Constants and Immutables                                                               ***/
    /**********************************************************************************************/

    // upstream: src/libraries/ConstantsLib.sol
    bytes32 public constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address public immutable midnight;
    address public immutable proxy;
    address public immutable controller;

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor(address midnight_, address proxy_, address controller_) {
        require(midnight_   != address(0), "ProxyFundingStrategy/invalid-midnight");
        require(proxy_      != address(0), "ProxyFundingStrategy/invalid-proxy");
        require(controller_ != address(0), "ProxyFundingStrategy/invalid-controller");

        midnight   = midnight_;
        proxy      = proxy_;
        controller = controller_;
    }

    /**********************************************************************************************/
    /*** External Interactive Functions                                                         ***/
    /**********************************************************************************************/

    // upstream: ICallbacks.sol IBuyCallback.onBuy, invoked at Midnight.sol#L481-489, just before
    // the two transferFrom legs at #L491-492 pull `buyerAssets` from this contract in total.
    function onBuy(
        bytes32 marketId,
        Market memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256,
        address buyer,
        bytes memory
    )
        external
        nonReentrant
        returns (bytes32)
    {
        require(msg.sender == midnight, "ProxyFundingStrategy/not-midnight");
        require(buyer      == proxy,    "ProxyFundingStrategy/buyer-not-proxy");

        // Midnight pokes a consumed offer at zero; reverting fails an unrelated taker's call.
        if (buyerAssets == 0) return CALLBACK_SUCCESS;

        // Reverts unless the pair limit exists, so zeroing that limit revokes this contract.
        IMidnightController(controller).midnight_fundFill(marketId, buyerAssets, units);

        // Exactly what Midnight is about to pull; a disagreement leaves the pull unfunded.
        IERC20(market.loanToken).forceApprove(midnight, buyerAssets);

        return CALLBACK_SUCCESS;
    }

    // Permissionless: a stray balance is the proxy's either way, and no other target exists.
    function skim(address token) external {
        uint256 amount = IERC20(token).balanceOf(address(this));

        require(amount != 0, "ProxyFundingStrategy/nothing-to-skim");

        IERC20(token).safeTransfer(proxy, amount);

        emit Skimmed(token, amount);
    }

}
