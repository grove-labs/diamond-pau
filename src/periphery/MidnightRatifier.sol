// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { AccessControl } from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import { ECDSA }
    from "../../lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

import { IMidnightController } from "../facets/midnight/IMidnightController.sol";
import { IMidnightFacet }      from "../facets/midnight/IMidnightFacet.sol";
import { IRateLimits }         from "../interfaces/IRateLimits.sol";

import { Market, MidnightUtils, Offer } from "../facets/midnight/MidnightUtils.sol";

import { MidnightOfferHash } from "./libraries/MidnightOfferHash.sol";

// Midnight gates maker fills on isAuthorized[maker][ratifier], one flat mapping that also gates
// withdraw, repay, supplyCollateral, withdrawCollateral, setConsumed and setIsAuthorized, so the
// grant hands over the proxy's whole position. No code here calls the singleton, which voids it.
contract MidnightRatifier is AccessControl {

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    event QuoterSet(address indexed oldQuoter, address indexed newQuoter);

    /**********************************************************************************************/
    /*** Constants and Immutables                                                               ***/
    /**********************************************************************************************/

    // upstream: src/libraries/ConstantsLib.sol
    bytes32 public constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    bytes32 public constant NAME_HASH    = keccak256("MidnightRatifier");
    bytes32 public constant VERSION_HASH = keccak256("1");

    address public immutable midnight;
    address public immutable proxy;
    address public immutable controller;
    address public immutable rateLimits;

    uint256 public immutable maxOfferWindow;

    /**********************************************************************************************/
    /*** Storage                                                                                ***/
    /**********************************************************************************************/

    address public quoter;

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor(
        address admin_,
        address midnight_,
        address proxy_,
        address controller_,
        address rateLimits_,
        address quoter_,
        uint256 maxOfferWindow_
    ) {
        require(admin_      != address(0), "MidnightRatifier/zero-admin");
        require(midnight_   != address(0), "MidnightRatifier/zero-midnight");
        require(proxy_      != address(0), "MidnightRatifier/zero-proxy");
        require(controller_ != address(0), "MidnightRatifier/zero-controller");
        require(rateLimits_ != address(0), "MidnightRatifier/zero-rate-limits");
        require(quoter_     != address(0), "MidnightRatifier/zero-quoter");
        require(maxOfferWindow_ != 0,      "MidnightRatifier/zero-max-offer-window");

        midnight   = midnight_;
        proxy      = proxy_;
        controller = controller_;
        rateLimits = rateLimits_;

        maxOfferWindow = maxOfferWindow_;

        quoter = quoter_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        emit QuoterSet(address(0), quoter_);
    }

    /**********************************************************************************************/
    /*** Admin Functions                                                                        ***/
    /**********************************************************************************************/

    function setQuoter(address newQuoter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newQuoter != address(0), "MidnightRatifier/zero-quoter");

        emit QuoterSet(quoter, newQuoter);

        quoter = newQuoter;
    }

    /**********************************************************************************************/
    /*** Midnight Ratification                                                                  ***/
    /**********************************************************************************************/

    function isRatified(Offer memory offer, bytes memory ratifierData, address)
        external
        view
        returns (bytes32)
    {
        // First, because everything below reads policy keyed by an id taken from the offer itself.
        require(
            ECDSA.recover(digest(offer), ratifierData) == quoter,
            "MidnightRatifier/invalid-signature"
        );

        require(offer.maker           == proxy,         "MidnightRatifier/maker-not-proxy");
        require(offer.ratifier        == address(this), "MidnightRatifier/not-our-ratifier");
        require(offer.market.midnight == midnight,      "MidnightRatifier/invalid-midnight");

        // Unused on a buy, where upstream requires it zero (Midnight.sol#L382-385) before us.
        require(
            offer.receiverIfMakerIsSeller == (offer.buy ? address(0) : proxy),
            "MidnightRatifier/invalid-receiver"
        );

        bytes32 marketId = MidnightUtils.toId(offer.market);

        IMidnightFacet.MakeConfig memory makeConfig =
            IMidnightController(controller).midnight_getMakeConfig(marketId);

        require(makeConfig.maxOfferSize != 0, "MidnightRatifier/make-not-enabled");

        // Exactly one of the two is set upstream, so the one that is set is the offer's size.
        uint256 offerSize = offer.maxUnits != 0 ? offer.maxUnits : offer.maxAssets;

        require(offerSize <= makeConfig.maxOfferSize, "MidnightRatifier/offer-too-large");

        require(offer.expiry >= block.timestamp,  "MidnightRatifier/offer-expired");
        require(offer.expiry >= offer.start,      "MidnightRatifier/offer-window-inverted");
        require(
            offer.expiry - offer.start <= maxOfferWindow,
            "MidnightRatifier/offer-window-too-long"
        );

        // Selling may only shed credit we already hold, never open naked debt.
        require(offer.buy || offer.reduceOnly, "MidnightRatifier/sell-not-reduce-only");

        IMidnightFacet.DesignatedGroups memory groups =
            IMidnightController(controller).midnight_getDesignatedGroups(marketId);

        bytes32 expectedGroup = offer.buy ? groups.buyGroup : groups.sellGroup;

        require(expectedGroup != 0,            "MidnightRatifier/group-not-designated");
        require(offer.group == expectedGroup,  "MidnightRatifier/wrong-group");

        _requireCallback(offer, marketId);
        _requirePrice(offer, marketId, makeConfig.maturity);

        return CALLBACK_SUCCESS;
    }

    /**********************************************************************************************/
    /*** Views                                                                                  ***/
    /**********************************************************************************************/

    // Rebuilt per call rather than cached, so a chain split cannot leave a stale separator behind.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }

    function digest(Offer memory offer) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(hex"1901", domainSeparator(), MidnightOfferHash.hashOffer(offer))
        );
    }

    /**********************************************************************************************/
    /*** Internal Functions                                                                     ***/
    /**********************************************************************************************/

    // Midnight routes a maker sell's callback to onSell (Midnight.sol#L453-454), which our
    // strategy does not implement; a buy's must hold the pair limit that lets it draw on the proxy.
    function _requireCallback(Offer memory offer, bytes32 marketId) internal view {
        if (!offer.buy) {
            require(offer.callback == address(0), "MidnightRatifier/sell-has-callback");
            return;
        }

        bytes32 strategyKey =
            IMidnightController(controller)
                .midnight_getStrategyRateLimitKey(offer.callback, marketId);

        require(
            IRateLimits(rateLimits).getRateLimitData(strategyKey).maxAmount != 0,
            "MidnightRatifier/strategy-not-authorized"
        );
    }

    // Same inputs fundFill uses, so an offer that ratifies here cannot then fail to fund.
    function _requirePrice(Offer memory offer, bytes32 marketId, uint64 maturity) internal view {
        IMidnightFacet.MarketConfig memory config =
            IMidnightController(controller).midnight_getMarketConfig(marketId);

        uint256 timeToMaturity = maturity > block.timestamp ? maturity - block.timestamp : 0;

        uint256 price = MidnightUtils.tickToPrice(offer.tick);

        if (offer.buy) {
            require(offer.tick <= config.maxBuyTick, "MidnightRatifier/tick-above-max-buy");

            uint256 bound = MidnightUtils.maxBuyPrice(
                config.minBuyYield,
                timeToMaturity,
                MidnightUtils.continuousFeePerSecond(config.maxContinuousFee)
            );

            require(price <= bound, "MidnightRatifier/buy-yield-too-low");
        } else {
            require(offer.tick >= config.minSellTick, "MidnightRatifier/tick-below-min-sell");

            // The strictest floor, and unlike the live lien it cannot move between sign and fill.
            uint256 floor = MidnightUtils.minSellPrice(
                config.maxSellYield,
                timeToMaturity,
                MidnightUtils.WAD,
                0
            );

            require(price >= floor, "MidnightRatifier/sell-yield-too-high");
        }

        // Upstream voids a fill whose live fee exceeds this cap, so bounding it bounds the fee.
        require(
            offer.continuousFeeCap
                <= MidnightUtils.continuousFeePerSecond(config.maxContinuousFee),
            "MidnightRatifier/fee-cap-too-high"
        );
    }

}
