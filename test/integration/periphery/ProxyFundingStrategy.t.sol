// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {
    ReentrancyGuard
} from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { IMidnightController } from "../../../src/facets/midnight/IMidnightController.sol";
import { IController }         from "../../../src/interfaces/IController.sol";
import { IRateLimits }         from "../../../src/interfaces/IRateLimits.sol";

import { BeaconConfig }         from "../../../src/libraries/BeaconConfig.sol";
import { MidnightFacet }        from "../../../src/facets/midnight/MidnightFacet.sol";
import { MidnightUtils }        from "../../../src/facets/midnight/MidnightUtils.sol";
import { ProxyFundingStrategy } from "../../../src/periphery/ProxyFundingStrategy.sol";

import { CollateralParams, Market } from "../../../src/facets/midnight/MidnightUtils.sol";

import { Integration_TestBase } from "../TestBase.t.sol";

interface IMidnightMock {

    function toMarket(bytes32 id) external view returns (Market memory);

    function lossFactor(bytes32 id) external view returns (uint128);

}

// upstream: src/interfaces/ICallbacks.sol ISellCallback, so the probe below is correctly encoded.
interface ISellCallbackLike {

    function onSell(
        bytes32 id,
        Market memory market,
        uint256 sellerAssets,
        uint256 units,
        uint256 pendingFeeDecrease,
        address seller,
        address receiver,
        bytes memory data
    ) external returns (bytes32);

}

// Stands in for the singleton, so onBuy can be re-entered by code rather than only by a prank.
contract MidnightRelay {

    function relay(address strategy, bytes memory callData) external returns (bytes memory) {
        (bool success, bytes memory result) = strategy.call(callData);

        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }

        return result;
    }

}

// Re-enters from both legs: transfer, inside fundFill, and approve, after its guard has released.
contract ReentrantToken is ERC20 {

    address public transferTarget;
    address public approveTarget;

    bytes public payload;

    bool public innerAttempted;
    bool public innerSucceeded;

    bytes public innerError;

    constructor() ERC20("Reentrant", "RE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function armTransfer(address target, bytes memory payload_) external {
        transferTarget = target;
        payload        = payload_;
    }

    function armApprove(address target, bytes memory payload_) external {
        approveTarget = target;
        payload       = payload_;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (transferTarget != address(0)) {
            address armed = transferTarget;

            transferTarget = address(0);

            (bool success, bytes memory result) = armed.call(payload);

            if (!success) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }

        return super.transfer(to, value);
    }

    // Records the inner outcome instead of bubbling it, so a test can assert which guard rejected
    // the re-entry rather than only that something did.
    function approve(address spender, uint256 value) public override returns (bool) {
        if (approveTarget != address(0)) {
            address armed = approveTarget;

            approveTarget = address(0);

            innerAttempted = true;

            (bool success, bytes memory result) = armed.call(payload);

            innerSucceeded = success;
            innerError     = result;
        }

        return super.approve(spender, value);
    }

}

contract Periphery_ProxyFundingStrategy_Tests is Integration_TestBase {

    uint16 internal constant TICK_99        = 4384;
    uint16 internal constant TICK_98        = 4152;
    uint16 internal constant CONTINUOUS_FEE = 1_00_00;
    uint16 internal constant MIN_BUY_YIELD  = 1_00;
    uint16 internal constant MAX_SELL_YIELD = 10_00;

    uint256 internal constant MAX_OFFER_SIZE = 1_000_000e6;
    uint256 internal constant FILL_UNITS     = 1_000e6;

    address internal midnight;
    address internal loanToken;

    IMidnightController internal controller;
    IRateLimits         internal rateLimits;

    ProxyFundingStrategy internal strategy;

    address internal proxy;

    uint256 internal marketMaturity;

    function setUp() external {
        controller = IMidnightController(_deploy());

        rateLimits = IRateLimits(IController(payable(address(controller))).rateLimits());
        proxy      = IController(payable(address(controller))).proxy();

        marketMaturity = block.timestamp + 180 days;

        midnight  = address(new MidnightRelay());
        loanToken = address(new ReentrantToken());

        // Deployed outside the prank: a creation in the argument list would consume it.
        address facet = address(new MidnightFacet(midnight));

        vm.prank(beaconAdmin);
        BeaconConfig.setMidnightIntegration(address(beacon), facet);

        bytes32[] memory integrationIds = new bytes32[](1);
        integrationIds[0] = "MIDNIGHT_FACET";

        vm.prank(admin);
        IController(payable(address(controller))).updateIntegrations(integrationIds);

        strategy = new ProxyFundingStrategy(midnight, proxy, address(controller));

        vm.label(midnight,          "MidnightRelay");
        vm.label(loanToken,         "ReentrantToken");
        vm.label(address(strategy), "ProxyFundingStrategy");
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

        vm.mockCall(
            midnight,
            abi.encodeCall(IMidnightMock.lossFactor, (_marketId())),
            abi.encode(uint128(0))
        );

        bytes32 strategyKey =
            controller.midnight_getStrategyRateLimitKey(address(strategy), _marketId());

        bytes32 buyKey = controller.midnight_getBuyRateLimitKey(_marketId());

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
        rateLimits.setRateLimitData(strategyKey, MAX_OFFER_SIZE, 0);
        rateLimits.setRateLimitData(buyKey,      MAX_OFFER_SIZE, 0);
        vm.stopPrank();

        deal(loanToken, proxy, MAX_OFFER_SIZE);
    }

    function _maxFillPrice() internal view returns (uint256 bound) {
        bound = MidnightUtils.tickToPrice(TICK_99);

        uint256 yieldBound = MidnightUtils.maxBuyPrice(
            MIN_BUY_YIELD,
            marketMaturity - block.timestamp,
            MidnightUtils.continuousFeePerSecond(CONTINUOUS_FEE)
        );

        if (yieldBound < bound) bound = yieldBound;
    }

    function _honestAssets(uint256 units) internal view returns (uint256) {
        return units * _maxFillPrice() / MidnightUtils.WAD;
    }

    function _onBuyCallData(uint256 assets, uint256 units, address buyer)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            ProxyFundingStrategy.onBuy,
            (_marketId(), _market(), assets, units, 0, buyer, new bytes(0))
        );
    }

    function _relayCallData(uint256 assets, uint256 units) internal view returns (bytes memory) {
        return abi.encodeCall(
            MidnightRelay.relay,
            (address(strategy), _onBuyCallData(assets, units, proxy))
        );
    }

    function _onBuy(uint256 assets, uint256 units) internal returns (bytes32) {
        vm.prank(midnight);
        return strategy.onBuy(
            _marketId(),
            _market(),
            assets,
            units,
            0,
            proxy,
            new bytes(0)
        );
    }

    /**********************************************************************************************/
    /*** Constructor Tests                                                                      ***/
    /**********************************************************************************************/

    function test_constructor() external view {
        assertEq(strategy.midnight(),   midnight);
        assertEq(strategy.proxy(),      proxy);
        assertEq(strategy.controller(), address(controller));

        assertEq(strategy.CALLBACK_SUCCESS(), keccak256("morpho.midnight.callbackSuccess"));
    }

    function test_constructor_zeroAddresses() external {
        vm.expectRevert("ProxyFundingStrategy/invalid-midnight");
        new ProxyFundingStrategy(address(0), proxy, address(controller));

        vm.expectRevert("ProxyFundingStrategy/invalid-proxy");
        new ProxyFundingStrategy(midnight, address(0), address(controller));

        vm.expectRevert("ProxyFundingStrategy/invalid-controller");
        new ProxyFundingStrategy(midnight, proxy, address(0));
    }

    /**********************************************************************************************/
    /*** Structural Tests                                                                       ***/
    /**********************************************************************************************/

    // The strategy is the payer, so its behaviour must be fixed: no delegatecall to borrow code
    // from elsewhere, no child contract, no way to remove itself.
    function test_containsNoCodeBorrowingOpcode() external view {
        bytes memory code = _strippedCode(address(strategy));

        uint256 calls;
        uint256 i;

        while (i < code.length) {
            uint8 op = uint8(code[i]);

            // PUSH1..PUSH32: skip the immediate so constants are never read as opcodes.
            if (op >= 0x60 && op <= 0x7F) {
                i += 1 + (op - 0x5F);
                continue;
            }

            assertTrue(op != 0xF2, "CALLCODE present");
            assertTrue(op != 0xF4, "DELEGATECALL present");
            assertTrue(op != 0xF0, "CREATE present");
            assertTrue(op != 0xF5, "CREATE2 present");
            assertTrue(op != 0xFF, "SELFDESTRUCT present");

            if (op == 0xF1) ++calls;

            ++i;
        }

        // Control: this contract does call out, so the assertions above are not vacuous.
        assertGt(calls, 0);
    }

    // Midnight routes a maker sell's callback to onSell. Not implementing it is what makes a sell
    // offer naming this contract unfillable rather than silently mis-settled.
    function test_doesNotImplementOnSell() external {
        _onboard();

        uint256 assets = _honestAssets(FILL_UNITS);

        bytes memory buyCallData = _onBuyCallData(assets, FILL_UNITS, proxy);

        bytes memory sellCallData = abi.encodeCall(
            ISellCallbackLike.onSell,
            (_marketId(), _market(), assets, FILL_UNITS, 0, proxy, proxy, new bytes(0))
        );

        // Control: the same raw-call harness reaches the callback this contract does implement, so
        // the failure below is a missing function and not a malformed probe.
        vm.prank(midnight);
        (bool buySuccess,) = address(strategy).call(buyCallData);

        assertTrue(buySuccess);

        vm.prank(midnight);
        (bool sellSuccess,) = address(strategy).call(sellCallData);

        assertFalse(sellSuccess);
    }

    // A drifted argument list would make Midnight's call miss this contract's onBuy entirely.
    function test_onBuySelectorMatchesUpstream() external pure {
        assertEq(
            ProxyFundingStrategy.onBuy.selector,
            bytes4(
                keccak256(
                    "onBuy(bytes32,(uint256,address,address,"
                    "(address,uint256,uint256,address)[],uint256,uint256,address,address),"
                    "uint256,uint256,uint256,address,bytes)"
                )
            )
        );
    }

    /**********************************************************************************************/
    /*** onBuy Guard Tests                                                                      ***/
    /**********************************************************************************************/

    function test_onBuy_notMidnight() external {
        _onboard();

        uint256 assets = _honestAssets(FILL_UNITS);

        vm.expectRevert("ProxyFundingStrategy/not-midnight");
        strategy.onBuy(_marketId(), _market(), assets, FILL_UNITS, 0, proxy, new bytes(0));
    }

    function test_onBuy_buyerNotProxy() external {
        _onboard();

        uint256 assets = _honestAssets(FILL_UNITS);

        address stranger = makeAddr("stranger");

        vm.prank(midnight);
        vm.expectRevert("ProxyFundingStrategy/buyer-not-proxy");
        strategy.onBuy(_marketId(), _market(), assets, FILL_UNITS, 0, stranger, new bytes(0));
    }

    /**********************************************************************************************/
    /*** onBuy Funding Tests                                                                    ***/
    /**********************************************************************************************/

    function test_onBuy() external {
        _onboard();

        uint256 assets = _honestAssets(FILL_UNITS);

        bytes32 strategyKey =
            controller.midnight_getStrategyRateLimitKey(address(strategy), _marketId());

        bytes32 buyKey = controller.midnight_getBuyRateLimitKey(_marketId());

        assertEq(IERC20(loanToken).balanceOf(proxy),             MAX_OFFER_SIZE);
        assertEq(IERC20(loanToken).balanceOf(address(strategy)), 0);
        assertEq(IERC20(loanToken).allowance(address(strategy), midnight), 0);
        assertEq(rateLimits.getCurrentRateLimit(strategyKey),    MAX_OFFER_SIZE);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),         MAX_OFFER_SIZE);

        assertEq(_onBuy(assets, FILL_UNITS), strategy.CALLBACK_SUCCESS());

        assertEq(IERC20(loanToken).balanceOf(proxy),             MAX_OFFER_SIZE - assets);
        assertEq(IERC20(loanToken).balanceOf(address(strategy)), assets);

        // Exactly the pull Midnight is about to make, never an open-ended grant.
        assertEq(IERC20(loanToken).allowance(address(strategy), midnight), assets);

        assertEq(rateLimits.getCurrentRateLimit(strategyKey), MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),      MAX_OFFER_SIZE - assets);
    }

    // The no-op take quirk: Midnight pokes a consumed offer's callback with zeroes, and reverting
    // there would fail an unrelated taker's transaction.
    function test_onBuy_zeroAssetsIsNoOp() external {
        _onboard();

        bytes32 strategyKey =
            controller.midnight_getStrategyRateLimitKey(address(strategy), _marketId());

        assertEq(_onBuy(0, 0), strategy.CALLBACK_SUCCESS());

        assertEq(IERC20(loanToken).balanceOf(address(strategy)), 0);
        assertEq(IERC20(loanToken).allowance(address(strategy), midnight), 0);
        assertEq(rateLimits.getCurrentRateLimit(strategyKey), MAX_OFFER_SIZE);
    }

    // Zero units with assets to pay is not the no-op case, and must not fund anything.
    function test_onBuy_zeroUnits() external {
        _onboard();

        vm.prank(midnight);
        vm.expectRevert("MidnightFacet/zero-units");
        strategy.onBuy(_marketId(), _market(), 1, 0, 0, proxy, new bytes(0));
    }

    // Allowance is set, not accumulated, so an unpulled grant cannot compound across fills.
    function test_onBuy_allowanceIsSetNotAccumulated() external {
        _onboard();

        uint256 assets = _honestAssets(FILL_UNITS);

        _onBuy(assets, FILL_UNITS);

        assertEq(IERC20(loanToken).allowance(address(strategy), midnight), assets);

        _onBuy(assets, FILL_UNITS);

        assertEq(IERC20(loanToken).allowance(address(strategy), midnight), assets);
    }

    /**********************************************************************************************/
    /*** fundFill Gating Tests                                                                  ***/
    /**********************************************************************************************/

    // Pair-key existence is the strategy's whole authorization, so a strategy without one funds
    // nothing even though Midnight happily calls it.
    function test_onBuy_strategyNotAuthorized() external {
        _onboard();

        ProxyFundingStrategy other =
            new ProxyFundingStrategy(midnight, proxy, address(controller));

        uint256 assets = _honestAssets(FILL_UNITS);

        vm.prank(midnight);
        vm.expectRevert("MidnightFacet/strategy-not-authorized");
        other.onBuy(_marketId(), _market(), assets, FILL_UNITS, 0, proxy, new bytes(0));
    }

    function test_onBuy_makeNotEnabled() external {
        _onboard();

        vm.prank(admin);
        controller.midnight_setMakeConfig(_market(), 0);

        uint256 assets = _honestAssets(FILL_UNITS);

        vm.prank(midnight);
        vm.expectRevert("MidnightFacet/make-not-enabled");
        strategy.onBuy(_marketId(), _market(), assets, FILL_UNITS, 0, proxy, new bytes(0));
    }

    function test_onBuy_rateLimitExceededBoundary() external {
        _onboard();

        bytes32 strategyKey =
            controller.midnight_getStrategyRateLimitKey(address(strategy), _marketId());

        uint256 assets = _honestAssets(FILL_UNITS);

        vm.prank(admin);
        rateLimits.setRateLimitData(strategyKey, assets, 0);

        _onBuy(assets, FILL_UNITS);

        vm.prank(admin);
        rateLimits.setRateLimitData(strategyKey, assets - 1, 0);

        vm.prank(midnight);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        strategy.onBuy(_marketId(), _market(), assets, FILL_UNITS, 0, proxy, new bytes(0));
    }

    // The strategy relays Midnight's numbers verbatim, so the price safeguard is what stops an
    // overpriced fill from being funded.
    function test_onBuy_fillPriceTooHighBoundary() external {
        _onboard();

        uint256 assets = _honestAssets(FILL_UNITS);

        _onBuy(assets, FILL_UNITS);

        vm.prank(midnight);
        vm.expectRevert("MidnightFacet/fill-price-too-high");
        strategy.onBuy(_marketId(), _market(), assets + 1, FILL_UNITS, 0, proxy, new bytes(0));
    }

    /**********************************************************************************************/
    /*** Reentrancy Tests                                                                       ***/
    /**********************************************************************************************/

    // The loan token moves through this contract mid-settlement, so a token that calls back must
    // not be able to fund a second fill inside the first. Re-entry from the transfer leg is still
    // inside fundFill, so this only shows that nesting is refused, not by which guard.
    function test_onBuy_reentrantFromTransfer() external {
        _onboard();

        uint256 assets = _honestAssets(FILL_UNITS);

        ReentrantToken(loanToken).armTransfer(midnight, _relayCallData(assets, FILL_UNITS));

        vm.prank(midnight);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        strategy.onBuy(_marketId(), _market(), assets, FILL_UNITS, 0, proxy, new bytes(0));
    }

    // Re-entry from the approve leg happens after fundFill has returned, so the controller's guard
    // is free and only this contract's own lock can reject it. That is what pins nonReentrant here.
    function test_onBuy_reentrantFromApprove() external {
        _onboard();

        uint256 assets = _honestAssets(FILL_UNITS);

        ReentrantToken token = ReentrantToken(loanToken);

        token.armApprove(midnight, _relayCallData(assets, FILL_UNITS));

        assertEq(_onBuy(assets, FILL_UNITS), strategy.CALLBACK_SUCCESS());

        assertTrue(token.innerAttempted());
        assertFalse(token.innerSucceeded());

        assertEq(
            bytes4(token.innerError()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );

        // The outer fill still settled exactly once.
        assertEq(IERC20(loanToken).allowance(address(strategy), midnight), assets);
        assertEq(IERC20(loanToken).balanceOf(address(strategy)),           assets);
    }

    // Control: the same relay path works when it is not nested, so the test above fails for the
    // reentrancy and not because the relay itself is broken.
    function test_onBuy_viaRelayWhenNotNested() external {
        _onboard();

        uint256 assets = _honestAssets(FILL_UNITS);

        bytes memory result = MidnightRelay(midnight).relay(
            address(strategy),
            _onBuyCallData(assets, FILL_UNITS, proxy)
        );

        assertEq(abi.decode(result, (bytes32)), strategy.CALLBACK_SUCCESS());
    }

    /**********************************************************************************************/
    /*** skim Tests                                                                             ***/
    /**********************************************************************************************/

    function test_skim() external {
        deal(loanToken, address(strategy), 123e6);

        address stranger = makeAddr("stranger");

        assertEq(IERC20(loanToken).balanceOf(proxy), 0);

        vm.expectEmit(address(strategy));
        emit ProxyFundingStrategy.Skimmed(loanToken, 123e6);

        vm.prank(stranger);
        strategy.skim(loanToken);

        assertEq(IERC20(loanToken).balanceOf(address(strategy)), 0);
        assertEq(IERC20(loanToken).balanceOf(proxy),             123e6);
    }

    function test_skim_nothingToSkim() external {
        vm.expectRevert("ProxyFundingStrategy/nothing-to-skim");
        strategy.skim(loanToken);
    }

    /**********************************************************************************************/
    /*** Shared Helpers                                                                         ***/
    /**********************************************************************************************/

    // Trailing CBOR metadata is data, not code; walking it finds opcodes that do not exist.
    function _strippedCode(address target) internal view returns (bytes memory stripped) {
        bytes memory raw = target.code;

        uint256 length = (uint256(uint8(raw[raw.length - 2])) << 8) | uint8(raw[raw.length - 1]);

        assertLt(length + 2, raw.length);

        stripped = new bytes(raw.length - length - 2);

        for (uint256 i; i < stripped.length; ++i) stripped[i] = raw[i];
    }

}
