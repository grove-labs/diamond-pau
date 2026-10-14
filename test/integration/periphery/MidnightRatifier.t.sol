// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IMidnightController }     from "../../../src/facets/midnight/IMidnightController.sol";
import { IMidnightFacet }          from "../../../src/facets/midnight/IMidnightFacet.sol";
import { IController }             from "../../../src/interfaces/IController.sol";
import { IEnumerableIntegrations } from "../../../src/interfaces/IEnumerableIntegrations.sol";
import { IRateLimits }             from "../../../src/interfaces/IRateLimits.sol";

import { BeaconConfig }     from "../../../src/libraries/BeaconConfig.sol";
import { MidnightFacet }    from "../../../src/facets/midnight/MidnightFacet.sol";
import { MidnightRatifier } from "../../../src/periphery/MidnightRatifier.sol";
import { MidnightUtils }    from "../../../src/facets/midnight/MidnightUtils.sol";

import { CollateralParams, Market, Offer } from "../../../src/facets/midnight/MidnightUtils.sol";

import {
    MidnightOfferHash,
    COLLATERAL_PARAMS_TYPEHASH,
    MARKET_TYPEHASH,
    OFFER_TYPEHASH
} from "../../../src/periphery/libraries/MidnightOfferHash.sol";

import { Integration_TestBase } from "../TestBase.t.sol";

interface IMidnightMock {

    function toMarket(bytes32 id) external view returns (Market memory);

}

contract Periphery_MidnightRatifier_Tests is Integration_TestBase {

    // Ticks around par: tickToPrice(4152) is ~0.98 and tickToPrice(4384) is ~0.99.
    uint16 internal constant TICK_98 = 4152;
    uint16 internal constant TICK_99 = 4384;

    uint16 internal constant CONTINUOUS_FEE = 1_00_00;
    uint16 internal constant MAX_SELL_YIELD = 10_00;

    // Zero so the tick rail is the binding entry bound in the fixture: at 1% a year over 180 days
    // the fee alone puts the yield bound under tickToPrice(4384), which would make every offer at
    // the configured maxBuyTick unfillable. The yield rail gets its own tests, which raise this.
    uint16 internal constant MIN_BUY_YIELD = 0;

    uint256 internal constant MAX_OFFER_SIZE    = 1_000_000e6;
    uint256 internal constant MAX_OFFER_WINDOW  = 1 hours;

    bytes32 internal constant BUY_GROUP  = keccak256("buy-group");
    bytes32 internal constant SELL_GROUP = keccak256("sell-group");

    address internal midnight  = makeAddr("midnight");
    address internal loanToken = makeAddr("loanToken");
    address internal strategy  = makeAddr("strategy");
    address internal taker     = makeAddr("taker");

    uint256 internal quoterKey = 0xA11CE;

    address internal quoter;

    IMidnightController internal controller;
    IRateLimits         internal rateLimits;

    MidnightRatifier internal ratifier;

    address internal proxy;

    uint256 internal marketMaturity;

    function setUp() external {
        quoter = vm.addr(quoterKey);

        controller = IMidnightController(_deploy());

        rateLimits = IRateLimits(IController(payable(address(controller))).rateLimits());
        proxy      = IController(payable(address(controller))).proxy();

        marketMaturity = block.timestamp + 180 days;

        // Deployed outside the prank: a creation in the argument list would consume it.
        address facet = address(new MidnightFacet(midnight));

        // Production wiring, so the selectors the ratifier reads are exactly the deployed ones.
        vm.prank(beaconAdmin);
        BeaconConfig.setMidnightIntegration(address(beacon), facet);

        bytes32[] memory integrationIds = new bytes32[](1);
        integrationIds[0] = "MIDNIGHT_FACET";

        vm.prank(admin);
        IController(payable(address(controller))).updateIntegrations(integrationIds);

        ratifier = new MidnightRatifier(
            admin,
            midnight,
            proxy,
            address(controller),
            address(rateLimits),
            quoter,
            MAX_OFFER_WINDOW
        );
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _market() internal view returns (Market memory) {
        return Market({
            chainId          : block.chainid,
            midnight         : midnight,
            loanToken        : loanToken,
            collateralParams : new CollateralParams[](0),
            maturity         : marketMaturity,
            rcfThreshold     : 0,
            enterGate        : address(0),
            liquidatorGate   : address(0)
        });
    }

    function _marketId() internal view returns (bytes32) {
        return MidnightUtils.toId(_market());
    }

    function _onboard() internal {
        vm.mockCall(
            midnight,
            abi.encodeCall(IMidnightMock.toMarket, (_marketId())),
            abi.encode(_market())
        );

        bytes32 strategyKey = controller.midnight_getStrategyRateLimitKey(strategy, _marketId());

        vm.startPrank(admin);
        controller.midnight_setMarketConfig(
            _marketId(),
            TICK_99,
            TICK_98,
            MIN_BUY_YIELD,
            MAX_SELL_YIELD,
            CONTINUOUS_FEE,
            0
        );
        controller.midnight_setMakeConfig(_market(), MAX_OFFER_SIZE);
        controller.midnight_setDesignatedGroups(_marketId(), BUY_GROUP, SELL_GROUP);
        rateLimits.setRateLimitData(strategyKey, MAX_OFFER_SIZE, 0);
        vm.stopPrank();
    }

    function _buyOffer() internal view returns (Offer memory) {
        return Offer({
            market                  : _market(),
            buy                     : true,
            maker                   : proxy,
            start                   : block.timestamp,
            expiry                  : block.timestamp + MAX_OFFER_WINDOW,
            tick                    : TICK_99,
            group                   : BUY_GROUP,
            callback                : strategy,
            callbackData            : new bytes(0),
            receiverIfMakerIsSeller : address(0),
            ratifier                : address(ratifier),
            reduceOnly              : false,
            maxUnits                : uint128(MAX_OFFER_SIZE),
            maxAssets               : 0,
            continuousFeeCap        : MidnightUtils.continuousFeePerSecond(CONTINUOUS_FEE)
        });
    }

    function _sellOffer() internal view returns (Offer memory offer) {
        offer = _buyOffer();

        offer.buy                     = false;
        offer.tick                    = TICK_98;
        offer.group                   = SELL_GROUP;
        offer.callback                = address(0);
        offer.reduceOnly              = true;
        offer.receiverIfMakerIsSeller = proxy;
    }

    function _sign(Offer memory offer) internal view returns (bytes memory) {
        return _signWith(offer, quoterKey);
    }

    function _signWith(Offer memory offer, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, ratifier.digest(offer));
        return abi.encodePacked(r, s, v);
    }

    function _assertRatified(Offer memory offer) internal view {
        assertEq(
            ratifier.isRatified(offer, _sign(offer), taker),
            ratifier.CALLBACK_SUCCESS()
        );
    }

    function _assertRejected(Offer memory offer, string memory reason) internal {
        bytes memory signature = _sign(offer);

        vm.expectRevert(bytes(reason));
        ratifier.isRatified(offer, signature, taker);
    }

    /**********************************************************************************************/
    /*** Constructor Tests                                                                      ***/
    /**********************************************************************************************/

    function test_constructor() external view {
        assertEq(ratifier.midnight(),       midnight);
        assertEq(ratifier.proxy(),          proxy);
        assertEq(ratifier.controller(),     address(controller));
        assertEq(ratifier.rateLimits(),     address(rateLimits));
        assertEq(ratifier.quoter(),         quoter);
        assertEq(ratifier.maxOfferWindow(), MAX_OFFER_WINDOW);

        assertTrue(ratifier.hasRole(0x00, admin));
    }

    function test_constructor_zeroArguments() external {
        vm.expectRevert("MidnightRatifier/zero-admin");
        new MidnightRatifier(
            address(0),
            midnight,
            proxy,
            address(controller),
            address(rateLimits),
            quoter,
            1
        );

        vm.expectRevert("MidnightRatifier/zero-midnight");
        new MidnightRatifier(
            admin,
            address(0),
            proxy,
            address(controller),
            address(rateLimits),
            quoter,
            1
        );

        vm.expectRevert("MidnightRatifier/zero-proxy");
        new MidnightRatifier(
            admin,
            midnight,
            address(0),
            address(controller),
            address(rateLimits),
            quoter,
            1
        );

        vm.expectRevert("MidnightRatifier/zero-controller");
        new MidnightRatifier(admin, midnight, proxy, address(0), address(rateLimits), quoter, 1);

        vm.expectRevert("MidnightRatifier/zero-rate-limits");
        new MidnightRatifier(admin, midnight, proxy, address(controller), address(0), quoter, 1);

        vm.expectRevert("MidnightRatifier/zero-quoter");
        new MidnightRatifier(
            admin,
            midnight,
            proxy,
            address(controller),
            address(rateLimits),
            address(0),
            1
        );

        vm.expectRevert("MidnightRatifier/zero-max-offer-window");
        new MidnightRatifier(
            admin,
            midnight,
            proxy,
            address(controller),
            address(rateLimits),
            quoter,
            0
        );
    }

    /**********************************************************************************************/
    /*** setQuoter Tests                                                                        ***/
    /**********************************************************************************************/

    function test_setQuoter_unauthorizedAccount() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            bytes32(0)
        ));
        ratifier.setQuoter(makeAddr("newQuoter"));
    }

    function test_setQuoter_zeroQuoter() external {
        vm.expectRevert("MidnightRatifier/zero-quoter");
        vm.prank(admin);
        ratifier.setQuoter(address(0));
    }

    // Rotating the key is the first kill switch: offers signed by the old quoter stop ratifying.
    function test_setQuoter() external {
        _onboard();

        Offer memory offer = _buyOffer();

        _assertRatified(offer);

        bytes memory oldSignature = _sign(offer);

        address newQuoter = vm.addr(0xB0B);

        vm.expectEmit(address(ratifier));
        emit MidnightRatifier.QuoterSet(quoter, newQuoter);

        vm.prank(admin);
        ratifier.setQuoter(newQuoter);

        assertEq(ratifier.quoter(), newQuoter);

        vm.expectRevert("MidnightRatifier/invalid-signature");
        ratifier.isRatified(offer, oldSignature, taker);
    }

    /**********************************************************************************************/
    /*** Structural Tests                                                                       ***/
    /**********************************************************************************************/

    // The central audit claim. Midnight's isAuthorized grant is total, so the only durable defence
    // is that this contract cannot make a state-changing call at all.
    function test_containsNoStateChangingCallOpcode() external view {
        bytes memory code = _strippedCode(address(ratifier));

        uint256 statics;
        uint256 i;

        while (i < code.length) {
            uint8 op = uint8(code[i]);

            // PUSH1..PUSH32: skip the immediate so constants are never read as opcodes.
            if (op >= 0x60 && op <= 0x7F) {
                i += 1 + (op - 0x5F);
                continue;
            }

            assertTrue(op != 0xF1, "CALL present");
            assertTrue(op != 0xF2, "CALLCODE present");
            assertTrue(op != 0xF4, "DELEGATECALL present");
            assertTrue(op != 0xF0, "CREATE present");
            assertTrue(op != 0xF5, "CREATE2 present");
            assertTrue(op != 0xFF, "SELFDESTRUCT present");

            if (op == 0xFA) ++statics;

            ++i;
        }

        // Control: the walk does reach real call opcodes, so the assertions above are not vacuous.
        assertGt(statics, 0);
    }

    // Trailing CBOR metadata is data, not code; walking it finds opcodes that do not exist.
    function _strippedCode(address target) internal view returns (bytes memory stripped) {
        bytes memory raw = target.code;

        uint256 length = (uint256(uint8(raw[raw.length - 2])) << 8) | uint8(raw[raw.length - 1]);

        assertLt(length + 2, raw.length);

        stripped = new bytes(raw.length - length - 2);

        for (uint256 i; i < stripped.length; ++i) stripped[i] = raw[i];
    }

    /**********************************************************************************************/
    /*** Offer Hash Tests                                                                       ***/
    /**********************************************************************************************/

    // A hardcoded typehash is unauditable on its own, so each is rebuilt from the type string the
    // quoter's signing frontend uses (upstream: test/frontend/sign-root.ts).
    function test_typehashes_matchUpstreamTypeStrings() external pure {
        bytes memory collateralParamsType =
            "CollateralParams(address token,uint256 lltv,uint256 liquidationCursor,address oracle)";

        bytes memory marketType =
            "Market(uint256 chainId,address midnight,address loanToken,"
            "CollateralParams[] collateralParams,uint256 maturity,uint256 rcfThreshold,"
            "address enterGate,address liquidatorGate)";

        bytes memory offerType =
            "Offer(Market market,bool buy,address maker,uint256 start,uint256 expiry,uint256 tick,"
            "bytes32 group,address callback,bytes callbackData,address receiverIfMakerIsSeller,"
            "address ratifier,bool reduceOnly,uint128 maxUnits,uint128 maxAssets,"
            "uint256 continuousFeeCap)";

        assertEq(keccak256(collateralParamsType), COLLATERAL_PARAMS_TYPEHASH);

        assertEq(
            keccak256(bytes.concat(marketType, collateralParamsType)),
            MARKET_TYPEHASH
        );

        assertEq(
            keccak256(bytes.concat(offerType, collateralParamsType, marketType)),
            OFFER_TYPEHASH
        );
    }

    // Our split encode must equal upstream's single one, or a quoter signature would not verify.
    function test_hashOffer_matchesUpstreamLayout() external {
        Offer memory offer = _buyOffer();

        assertEq(MidnightOfferHash.hashOffer(offer), _upstreamHashOffer(offer));

        // Non-empty collateral params exercise the array hashing too.
        CollateralParams[] memory params = new CollateralParams[](2);
        params[0] = CollateralParams(makeAddr("token0"), 1e18, 1e17, makeAddr("oracle0"));
        params[1] = CollateralParams(makeAddr("token1"), 2e18, 2e17, makeAddr("oracle1"));

        offer.market.collateralParams = params;
        offer.callbackData            = hex"deadbeef";

        assertEq(MidnightOfferHash.hashOffer(offer), _upstreamHashOffer(offer));
    }

    // upstream: src/ratifiers/libraries/HashLib.sol, reproduced verbatim including the assembly.
    function _upstreamHashOffer(Offer memory offer) internal pure returns (bytes32) {
        bytes32[] memory collateralParamsHashes =
            new bytes32[](offer.market.collateralParams.length);

        for (uint256 i = 0; i < offer.market.collateralParams.length; i++) {
            collateralParamsHashes[i] =
                MidnightOfferHash.hashCollateralParams(offer.market.collateralParams[i]);
        }

        bytes32 collateralParamsHash;
        assembly ("memory-safe") {
            collateralParamsHash := keccak256(
                add(collateralParamsHashes, 0x20),
                mul(mload(collateralParamsHashes), 0x20)
            )
        }

        bytes32 marketHash = keccak256(
            abi.encode(
                MARKET_TYPEHASH,
                offer.market.chainId,
                offer.market.midnight,
                offer.market.loanToken,
                collateralParamsHash,
                offer.market.maturity,
                offer.market.rcfThreshold,
                offer.market.enterGate,
                offer.market.liquidatorGate
            )
        );

        return keccak256(
            bytes.concat(
                abi.encode(
                    OFFER_TYPEHASH,
                    marketHash,
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

    function test_domainSeparator_bindsChainAndAddress() external {
        bytes32 before = ratifier.domainSeparator();

        vm.chainId(block.chainid + 1);

        assertTrue(ratifier.domainSeparator() != before);
    }

    /**********************************************************************************************/
    /*** isRatified Happy Path Tests                                                            ***/
    /**********************************************************************************************/

    function test_isRatified_buy() external {
        _onboard();
        _assertRatified(_buyOffer());
    }

    function test_isRatified_sell() external {
        _onboard();
        _assertRatified(_sellOffer());
    }

    /**********************************************************************************************/
    /*** isRatified Authenticity Tests                                                          ***/
    /**********************************************************************************************/

    function test_isRatified_invalidSignature_wrongSigner() external {
        _onboard();

        Offer memory offer = _buyOffer();

        bytes memory signature = _signWith(offer, 0xBAD);

        vm.expectRevert("MidnightRatifier/invalid-signature");
        ratifier.isRatified(offer, signature, taker);
    }

    // Any field change invalidates the signature, since the digest covers the whole offer.
    function test_isRatified_invalidSignature_tamperedField() external {
        _onboard();

        Offer memory offer = _buyOffer();

        bytes memory signature = _sign(offer);

        offer.tick = TICK_98;

        vm.expectRevert("MidnightRatifier/invalid-signature");
        ratifier.isRatified(offer, signature, taker);
    }

    // A signature for one ratifier must not ratify at another, which is what the domain binds.
    function test_isRatified_invalidSignature_otherRatifierDomain() external {
        _onboard();

        MidnightRatifier other = new MidnightRatifier(
            admin,
            midnight,
            proxy,
            address(controller),
            address(rateLimits),
            quoter,
            MAX_OFFER_WINDOW
        );

        Offer memory offer = _buyOffer();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterKey, other.digest(offer));

        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert("MidnightRatifier/invalid-signature");
        ratifier.isRatified(offer, signature, taker);
    }

    /**********************************************************************************************/
    /*** isRatified Identity Tests                                                              ***/
    /**********************************************************************************************/

    function test_isRatified_makerNotProxy() external {
        _onboard();

        Offer memory offer = _buyOffer();
        offer.maker = makeAddr("attacker");

        _assertRejected(offer, "MidnightRatifier/maker-not-proxy");
    }

    function test_isRatified_notOurRatifier() external {
        _onboard();

        Offer memory offer = _buyOffer();
        offer.ratifier = makeAddr("otherRatifier");

        _assertRejected(offer, "MidnightRatifier/not-our-ratifier");
    }

    function test_isRatified_invalidMidnight() external {
        _onboard();

        Offer memory offer = _buyOffer();
        offer.market.midnight = makeAddr("otherMidnight");

        _assertRejected(offer, "MidnightRatifier/invalid-midnight");
    }

    // A sell must route proceeds to the proxy. A buy must leave the field zero, because upstream
    // rejects a non-zero one at Midnight.sol#L382-385 before this contract is ever consulted, so
    // requiring the proxy there would have made every buy offer we sign unfillable.
    function test_isRatified_invalidReceiver() external {
        _onboard();

        Offer memory sell = _sellOffer();
        sell.receiverIfMakerIsSeller = makeAddr("attacker");

        _assertRejected(sell, "MidnightRatifier/invalid-receiver");

        sell.receiverIfMakerIsSeller = address(0);

        _assertRejected(sell, "MidnightRatifier/invalid-receiver");

        Offer memory buy = _buyOffer();
        buy.receiverIfMakerIsSeller = proxy;

        _assertRejected(buy, "MidnightRatifier/invalid-receiver");
    }

    /**********************************************************************************************/
    /*** isRatified Policy Tests                                                                ***/
    /**********************************************************************************************/

    function test_isRatified_makeNotEnabled() external {
        _onboard();

        vm.prank(admin);
        controller.midnight_setMakeConfig(_market(), 0);

        _assertRejected(_buyOffer(), "MidnightRatifier/make-not-enabled");
    }

    function test_isRatified_offerTooLargeBoundary() external {
        _onboard();

        Offer memory offer = _buyOffer();

        offer.maxUnits = uint128(MAX_OFFER_SIZE + 1);
        _assertRejected(offer, "MidnightRatifier/offer-too-large");

        offer.maxUnits = uint128(MAX_OFFER_SIZE);
        _assertRatified(offer);

        offer.maxUnits  = 0;
        offer.maxAssets = uint128(MAX_OFFER_SIZE + 1);
        _assertRejected(offer, "MidnightRatifier/offer-too-large");
    }

    function test_isRatified_offerExpired() external {
        _onboard();

        Offer memory offer = _buyOffer();

        vm.warp(offer.expiry);
        _assertRatified(offer);

        vm.warp(offer.expiry + 1);
        _assertRejected(offer, "MidnightRatifier/offer-expired");
    }

    function test_isRatified_offerWindowInverted() external {
        _onboard();

        Offer memory offer = _buyOffer();
        offer.start = offer.expiry + 1;

        _assertRejected(offer, "MidnightRatifier/offer-window-inverted");
    }

    function test_isRatified_offerWindowTooLongBoundary() external {
        _onboard();

        Offer memory offer = _buyOffer();

        offer.expiry = offer.start + MAX_OFFER_WINDOW;
        _assertRatified(offer);

        offer.expiry = offer.start + MAX_OFFER_WINDOW + 1;
        _assertRejected(offer, "MidnightRatifier/offer-window-too-long");
    }

    function test_isRatified_windowStraddlingMaturity() external {
        _onboard();

        vm.warp(marketMaturity - MAX_OFFER_WINDOW / 2);

        Offer memory offer = _buyOffer();

        assertGt(offer.expiry, marketMaturity);

        _assertRatified(offer);

        vm.warp(marketMaturity + 1);

        _assertRatified(offer);

        Offer memory sell = _sellOffer();

        sell.start  = offer.start;
        sell.expiry = offer.expiry;

        // Past maturity the floor is par, so price turns the exit away rather than the clock.
        _assertRejected(sell, "MidnightRatifier/sell-yield-too-high");
    }

    function test_isRatified_sellNotReduceOnly() external {
        _onboard();

        Offer memory offer = _sellOffer();
        offer.reduceOnly = false;

        _assertRejected(offer, "MidnightRatifier/sell-not-reduce-only");
    }

    function test_isRatified_groupNotDesignated() external {
        _onboard();

        vm.prank(admin);
        controller.midnight_setDesignatedGroups(_marketId(), 0, 0);

        _assertRejected(_buyOffer(), "MidnightRatifier/group-not-designated");
    }

    function test_isRatified_wrongGroup() external {
        _onboard();

        Offer memory offer = _buyOffer();
        offer.group = SELL_GROUP;

        _assertRejected(offer, "MidnightRatifier/wrong-group");

        Offer memory sell = _sellOffer();
        sell.group = BUY_GROUP;

        _assertRejected(sell, "MidnightRatifier/wrong-group");
    }

    /**********************************************************************************************/
    /*** isRatified Callback Tests                                                              ***/
    /**********************************************************************************************/

    function test_isRatified_buyStrategyNotAuthorized() external {
        _onboard();

        Offer memory offer = _buyOffer();
        offer.callback = makeAddr("rogueStrategy");

        _assertRejected(offer, "MidnightRatifier/strategy-not-authorized");

        // Zeroing the pair key is the documented kill switch, so it must also stop ratification.
        bytes32 key = controller.midnight_getStrategyRateLimitKey(strategy, _marketId());

        vm.prank(admin);
        rateLimits.setRateLimitData(key, 0, 0);

        _assertRejected(_buyOffer(), "MidnightRatifier/strategy-not-authorized");
    }

    // A maker sell routes its callback to onSell, which our funding strategy does not implement.
    function test_isRatified_sellHasCallback() external {
        _onboard();

        Offer memory offer = _sellOffer();
        offer.callback = strategy;

        _assertRejected(offer, "MidnightRatifier/sell-has-callback");
    }

    /**********************************************************************************************/
    /*** isRatified Price Tests                                                                 ***/
    /**********************************************************************************************/

    function test_isRatified_tickAboveMaxBuyBoundary() external {
        _onboard();

        Offer memory offer = _buyOffer();

        offer.tick = TICK_99;
        _assertRatified(offer);

        offer.tick = TICK_99 + 1;
        _assertRejected(offer, "MidnightRatifier/tick-above-max-buy");
    }

    function test_isRatified_tickBelowMinSellBoundary() external {
        _onboard();

        Offer memory offer = _sellOffer();

        offer.tick = TICK_98;
        _assertRatified(offer);

        offer.tick = TICK_98 - 1;
        _assertRejected(offer, "MidnightRatifier/tick-below-min-sell");
    }

    // Tightening the yield floor retroactively kills an already-signed offer.
    function test_isRatified_buyYieldTooLow() external {
        _onboard();

        _assertRatified(_buyOffer());

        vm.prank(admin);
        controller.midnight_setMarketConfig(
            _marketId(), TICK_99, TICK_98, 5_00, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );

        _assertRejected(_buyOffer(), "MidnightRatifier/buy-yield-too-low");
    }

    function test_isRatified_sellYieldTooHigh() external {
        _onboard();

        _assertRatified(_sellOffer());

        vm.prank(admin);
        controller.midnight_setMarketConfig(
            _marketId(), TICK_99, TICK_98, MIN_BUY_YIELD, 1, CONTINUOUS_FEE, 0
        );

        _assertRejected(_sellOffer(), "MidnightRatifier/sell-yield-too-high");
    }

    // Pins the floor to an exact tick, so any change to how it is derived -- including the zero
    // lien basis the live fee would otherwise supply -- moves the boundary and breaks this.
    function test_isRatified_sellFloorBoundary() external {
        _onboard();

        // Sell tick opened to the bottom of the grid so the yield floor is the only binding bound.
        vm.prank(admin);
        controller.midnight_setMarketConfig(
            _marketId(), TICK_99, 1, MIN_BUY_YIELD, MAX_SELL_YIELD, CONTINUOUS_FEE, 0
        );

        uint256 floor = MidnightUtils.minSellPrice(
            MAX_SELL_YIELD,
            marketMaturity - block.timestamp,
            MidnightUtils.WAD,
            0
        );

        uint256 lo = 1;
        uint256 hi = MidnightUtils.MAX_TICK;

        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;

            if (MidnightUtils.tickToPrice(mid) < floor) lo = mid + 1;
            else                                        hi = mid;
        }

        assertGt(lo, 1);

        Offer memory offer = _sellOffer();

        offer.tick = lo;
        _assertRatified(offer);

        offer.tick = lo - 1;
        _assertRejected(offer, "MidnightRatifier/sell-yield-too-high");
    }

    function test_isRatified_feeCapTooHighBoundary() external {
        _onboard();

        Offer memory offer = _buyOffer();

        offer.continuousFeeCap = MidnightUtils.continuousFeePerSecond(CONTINUOUS_FEE);
        _assertRatified(offer);

        offer.continuousFeeCap = MidnightUtils.continuousFeePerSecond(CONTINUOUS_FEE) + 1;
        _assertRejected(offer, "MidnightRatifier/fee-cap-too-high");

        // Zero is self-punishing rather than risky, so policy permits it.
        offer.continuousFeeCap = 0;
        _assertRatified(offer);
    }

    /**********************************************************************************************/
    /*** Agreement With fundFill                                                                ***/
    /**********************************************************************************************/

    // Gate 0d: an offer that ratifies must then be fundable, so across the operating band the
    // ratifier's verdict has to agree exactly with fundFill's safeguard, tick by tick.
    function test_isRatified_buyBoundAgreesWithFundFill() external {
        _onboard();

        // Entry tick opened to the top of the grid, so the yield rail is the only binding bound
        // and the sweep below actually tests it rather than the tick comparison.
        vm.prank(admin);
        controller.midnight_setMarketConfig(
            _marketId(),
            uint16(MidnightUtils.MAX_TICK),
            TICK_98,
            1_00,
            MAX_SELL_YIELD,
            CONTINUOUS_FEE,
            0
        );

        uint256 bound = MidnightUtils.maxBuyPrice(
            1_00,
            marketMaturity - block.timestamp,
            MidnightUtils.continuousFeePerSecond(CONTINUOUS_FEE)
        );

        Offer memory offer = _buyOffer();

        uint256 accepted;
        uint256 rejected;

        for (uint256 tick = 4100; tick <= 4400; tick += 4) {
            offer.tick = tick;

            bool fundable = MidnightUtils.tickToPrice(tick) <= bound;
            bool ratified = _tryRatify(offer);

            assertEq(ratified, fundable);

            if (ratified) ++accepted;
            else          ++rejected;
        }

        // The band must straddle the bound, or the equality above proves nothing.
        assertGt(accepted, 0);
        assertGt(rejected, 0);
    }

    function _tryRatify(Offer memory offer) internal returns (bool) {
        try ratifier.isRatified(offer, _sign(offer), taker) returns (bytes32 magic) {
            return magic == ratifier.CALLBACK_SUCCESS();
        } catch {
            return false;
        }
    }

}
