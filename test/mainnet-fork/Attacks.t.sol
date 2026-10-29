// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import {
    OptionsBuilder
} from "../../lib/layerzero-v2/packages/layerzero-v2/evm/oapp/contracts/oapp/libs/OptionsBuilder.sol";

import { ReentrancyGuard } from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { SafeERC20, IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { ReentrancyGuard } from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { Ethereum } from "../../lib/spark-address-registry/src/Ethereum.sol";

import { Ethereum as GroveEthereum } from "../../lib/grove-address-registry/src/Ethereum.sol";

import { Currency } from "../../lib/uniswap-v4-periphery/lib/v4-core/src/types/Currency.sol";
import { PoolKey }  from "../../lib/uniswap-v4-periphery/lib/v4-core/src/types/PoolKey.sol";

import { makeAddressAddressKey, makeAddressKey } from "../../src/libraries/RateLimitHelpers.sol";

import { AaveV3_TestBase }                   from "./Aave.t.sol";
import { AaveV4_TestBase }                   from "./AaveV4.t.sol";
import { Centrifuge_TestBase }               from "./Centrifuge.t.sol";
import { Curve_TestBase }                    from "./Curve.t.sol";
import { ERC4626_SUSDS_TestBase }            from "./ERC4626.t.sol";
import { MainnetController_Ethena_E2ETests } from "./Ethena.t.sol";
import { Farm_TestBase }                     from "./Farm.t.sol";
import { LayerZero_TestBase }                from "./LayerZero.t.sol";
import { Maple_TestBase }                    from "./Maple.t.sol";
import { Midnight_TestBase, MockOracle }     from "./Midnight.t.sol";
import { IOnBuyLike, Midnight_Maker_TestBase, ITakeLike } from "./MidnightMaker.t.sol";
import { Pendle_TestBase }                   from "./Pendle.t.sol";
import { UniswapV3_TestBase }                from "./UniswapV3.t.sol";
import { UniswapV4_USDC_USDT_TestBase }      from "./UniswapV4.t.sol";
import { WEETH_TestBase }                    from "./WEETH.t.sol";

import { IMidnightFacet } from "../../src/facets/midnight/IMidnightFacet.sol";

import { Market, Offer } from "../../src/facets/midnight/MidnightInterfaces.sol";

import { MidnightTickLib } from "../../src/facets/midnight/MidnightTickLib.sol";

import { IUniswapV3Facet } from "../../src/facets/uniswap-v3/IUniswapV3Facet.sol";

import { INonfungiblePositionManager, IUniswapV3PoolLike } from "../interfaces/UniswapV3.sol";

interface IERC20Like {

    function approve(address spender, uint256 amount) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256 balance);

}

interface IAavePoolWithdraw {

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

}

interface IAaveV4SpokeReserveLike {

    struct Reserve {
        address underlying;
        address hub;
        uint16  assetId;
        uint8   decimals;
        uint24  collateralRisk;
        uint8   flags;
        uint32  dynamicConfigKey;
    }

    function getReserve(uint256 reserveId) external view returns (Reserve memory);

}

interface IUniswapV4PositionManagerLike {
    function poolKeys(bytes25 poolId) external view returns (PoolKey memory poolKey);
}

interface IMidnightFundFillLike {

    function midnight_fundFill(
        bytes32 marketId,
        bool    buy,
        uint256 assets,
        uint256 units,
        uint256 pendingFee
    ) external;

}

// The Midnight entry points a hostile maker callback can reach while the proxy's take is in flight.
interface IMidnightAttackLike {

    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory takerCallbackData
    ) external returns (uint256, uint256);

    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver)
        external;

    function repay(
        Market memory market,
        uint256 units,
        address onBehalf,
        address callback,
        bytes memory data
    ) external;

    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external;

    function liquidate(
        Market memory market,
        uint256 collateralIndex,
        uint256 seizedAssets,
        uint256 repaidUnits,
        address borrower,
        bool    postMaturityMode,
        address receiver,
        address callback,
        bytes memory data
    ) external returns (uint256, uint256);

}

interface ILayerZeroOFTLike {

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct SendParam {
        uint32  dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes   extraOptions;
        bytes   composeMsg;
        bytes   oftCmd;
    }

    function quoteSend(SendParam calldata sendParam, bool payInLzToken)
        external
        view
        returns (MessagingFee memory msgFee);

}

contract MainnetController_Aave_Attack_Tests is AaveV3_TestBase {

    function test_attack_assetChanged_depositAave() external {
        bytes32 aaveDepositKey = mainnetController.aave_getDepositRateLimitKey(ATOKEN_USDS, POOL, Ethereum.USDS);

        assertEq(rateLimits.getCurrentRateLimit(aaveDepositKey), 25_000_000e18);

        // Deposit succeeds with the original underlying (USDS).
        deal(Ethereum.USDS, address(almProxy), 1_000_000e18);

        vm.prank(allocator);
        mainnetController.aave_deposit(ATOKEN_USDS, 1_000_000e18);

        assertEq(rateLimits.getCurrentRateLimit(aaveDepositKey), 24_000_000e18);

        // Attack: mock UNDERLYING_ASSET_ADDRESS() to return a different address
        address changedUnderlying = makeAddr("changed-underlying");
        vm.mockCall(
            ATOKEN_USDS,
            abi.encodeWithSignature("UNDERLYING_ASSET_ADDRESS()"),
            abi.encode(changedUnderlying)
        );

        deal(Ethereum.USDS, address(almProxy), 1_000_000e18);

        // Cannot deposit with the changed asset
        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(allocator);
        mainnetController.aave_deposit(ATOKEN_USDS, 1_000_000e18);
    }

}

contract MainnetController_AaveV4_Attack_Tests is AaveV4_TestBase {

    function test_attack_reserveRemapped_depositAaveV4() external {
        assertEq(rateLimits.getCurrentRateLimit(mainUsdcDepositKey), USDC_DEPOSIT_LIMIT);

        // Deposit succeeds with the original underlying (USDC).
        deal(address(usdc), address(almProxy), USDC_DEPOSIT_AMOUNT);

        vm.prank(allocator);
        mainnetController.aaveV4_deposit(MAIN_SPOKE, MAIN_USDC_RESERVE_ID, USDC_DEPOSIT_AMOUNT);

        assertEq(
            rateLimits.getCurrentRateLimit(mainUsdcDepositKey),
            USDC_DEPOSIT_LIMIT - USDC_DEPOSIT_AMOUNT
        );

        // Attack: mock getReserve() to remap every reserve-derived key component (underlying,
        // hub, assetId), then zero the new hub's deficit read so the deficit gate still passes
        // (the remapped asset has no configured tolerance, so only a zero deficit clears it) and
        // the deposit fails purely on the unconfigured key.
        IAaveV4SpokeReserveLike.Reserve memory reserve
            = IAaveV4SpokeReserveLike(MAIN_SPOKE).getReserve(MAIN_USDC_RESERVE_ID);

        reserve.underlying = makeAddr("changed-underlying");
        reserve.hub        = makeAddr("changed-hub");
        reserve.assetId    = reserve.assetId + 1;

        vm.mockCall(
            MAIN_SPOKE,
            abi.encodeWithSignature("getReserve(uint256)", MAIN_USDC_RESERVE_ID),
            abi.encode(reserve)
        );

        vm.mockCall(
            reserve.hub,
            abi.encodeWithSignature("getAssetDeficitRay(uint256)", reserve.assetId),
            abi.encode(uint256(0))
        );

        deal(address(usdc), address(almProxy), USDC_DEPOSIT_AMOUNT);

        // Cannot deposit against the remapped reserve: its key was never configured.
        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(allocator);
        mainnetController.aaveV4_deposit(MAIN_SPOKE, MAIN_USDC_RESERVE_ID, USDC_DEPOSIT_AMOUNT);
    }

}

contract MainnetController_Curve_Attack_Tests is Curve_TestBase {

    using SafeERC20 for IERC20;

    function test_attack_coinsChanged_swapCurve() external {
        bytes32 curveSwapUSDTKey = mainnetController.curve_getSwapRateLimitKey(CURVE_POOL, Ethereum.USDT);

        assertEq(rateLimits.getCurrentRateLimit(curveSwapUSDTKey), uint256(type(uint256).max));

        _addLiquidity();

        // Swap succeeds with the original coins() response (USDT at index 1).
        deal(Ethereum.USDT, address(almProxy), 1_000_000e6);

        vm.prank(allocator);
        mainnetController.curve_swap(CURVE_POOL, 1, 0, 1_000_000e6, 998_000e6);

        assertEq(rateLimits.getCurrentRateLimit(curveSwapUSDTKey), uint256(type(uint256).max));

        // Attack: mock coins(1) to return a different token.
        vm.mockCall(
            CURVE_POOL,
            abi.encodeWithSignature("coins(uint256)", 1),
            abi.encode(Ethereum.DAI)
        );

        deal(Ethereum.USDT, address(almProxy), 1);

        // Cannot swap with changed coins().
        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(allocator);
        mainnetController.curve_swap(CURVE_POOL, 1, 0, 1, type(uint256).max);
    }

    function test_attack_coinsChanged_addLiquidityCurve() external {
        assertEq(rateLimits.getCurrentRateLimit(curveAggregateDepositKey), uint256(type(uint256).max));

        // Deposit succeeds with the original coins() response.
        _addLiquidity();
        assertEq(rateLimits.getCurrentRateLimit(curveAggregateDepositKey), uint256(type(uint256).max));

        // Attack: mock coins() to return a different token address.
        vm.mockCall(
            CURVE_POOL,
            abi.encodeWithSignature("coins(uint256)", 0),
            abi.encode(Ethereum.DAI)
        );
        vm.mockCall(
            CURVE_POOL,
            abi.encodeWithSignature("coins(uint256)", 1),
            abi.encode(Ethereum.DAI)
        );

        uint256 usdcAmount = 1_000_000e6;
        uint256 usdtAmount = 1_000_000e6;

        deal(address(usdc), address(almProxy), usdcAmount);
        deal(address(usdt), address(almProxy), usdtAmount);

        vm.startPrank(address(almProxy));
        IERC20Like(address(usdc)).approve(CURVE_POOL, usdcAmount);
        IERC20(address(usdt)).safeIncreaseAllowance(CURVE_POOL, usdtAmount);
        vm.stopPrank();

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = usdtAmount;

        uint256 minLpAmount = (usdcAmount + usdtAmount) * 1e12 * 98/100;

        // Cannot add liquidity with changed coins().
        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(allocator);
        mainnetController.curve_addLiquidity(CURVE_POOL, amounts, minLpAmount);
    }

}

contract MainnetController_Centrifuge_Attack_Tests is Centrifuge_TestBase {

    bytes32 depositKey;

    function setUp() public override {
        super.setUp();

        vm.prank(ROOT);
        restrictionManager.updateMember(address(jTreasuryToken), address(almProxy), type(uint64).max);

        depositKey = mainnetController.erc7540_getRequestDepositRateLimitKey(address(jTreasuryVault), Ethereum.USDC);

        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(depositKey, 2_000_000e6, uint256(2_000_000e6) / 1 days);
    }

    function test_attack_assetChanged_requestDepositERC7540() external {
        assertEq(rateLimits.getCurrentRateLimit(depositKey), 2_000_000e6);

        // Request succeeds with original underlying (USDC).
        deal(Ethereum.USDC, address(almProxy), 1_000_000e6);

        vm.prank(allocator);
        mainnetController.erc7540_requestDeposit(address(jTreasuryVault), 1_000_000e6);

        assertEq(rateLimits.getCurrentRateLimit(depositKey), 1_000_000e6);

        // Attack: mock asset() to return a different address.
        address changedAsset = Ethereum.DAI;
        vm.mockCall(
            address(jTreasuryVault),
            abi.encodeWithSignature("asset()"),
            abi.encode(changedAsset)
        );

        deal(Ethereum.USDC, address(almProxy), 1_000_000e6);

        // Cannot request another deposit with the changed asset.
        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(allocator);
        mainnetController.erc7540_requestDeposit(address(jTreasuryVault), 1_000_000e6);
    }

}

contract MainnetController_ERC4626_Attack_Tests is ERC4626_SUSDS_TestBase {

    function test_attack_assetChanged_depositERC4626() external {
        assertEq(rateLimits.getCurrentRateLimit(depositKey), 5_000_000e18);

        // Deposit succeeds with the original underlying (USDS).
        vm.startPrank(allocator);
        mainnetController.usds_mint(1_000_000e18);
        mainnetController.erc4626_deposit(address(susds), 1_000_000e18, 0);
        vm.stopPrank();

        assertEq(rateLimits.getCurrentRateLimit(depositKey), 4_000_000e18);

        // Attack: mock asset() to return a different address
        address changedAsset = Ethereum.DAI;
        vm.mockCall(
            address(susds),
            abi.encodeWithSignature("asset()"),
            abi.encode(changedAsset)
        );

        vm.prank(allocator);
        mainnetController.usds_mint(1_000_000e18);

        // Cannot deposit with the changed asset
        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(allocator);
        mainnetController.erc4626_deposit(address(susds), 1_000_000e18, 0);
    }

}

contract MainnetController_Ethena_Attack_Tests is MainnetController_Ethena_E2ETests {

    function test_attack_compromisedAllocator_lockingFundsInEthenaSilo() external {
        deal(address(susde), address(almProxy), 1_000_000e18);

        address silo = susde.silo();

        uint256 startingSiloBalance = usde.balanceOf(silo);

        vm.prank(allocator);
        mainnetController.ethena_cooldownAssets(1_000_000e18);

        skip(7 days);

        // Allocator is now compromised and wants to lock funds in the silo
        vm.prank(allocator);
        mainnetController.ethena_cooldownAssets(1);

        // Real allocator cannot withdraw when they want to
        vm.expectRevert(abi.encodeWithSignature("InvalidCooldown()"));
        vm.prank(allocator);
        mainnetController.ethena_unstake();

        // Allocator admin can remove the compromised allocator and fallback to the governance allocator
        vm.prank(allocatorAdmin);
        accessControls.revokeRole(ALLOCATOR_ROLE, allocator);

        skip(7 days);

        // Compromised allocator cannot perform attack anymore
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            allocator,
            ALLOCATOR_ROLE
        ));
        vm.prank(allocator);
        mainnetController.ethena_cooldownAssets(1);

        // Funds have been locked in the silo this whole time
        assertEq(usde.balanceOf(address(almProxy)), 0);
        assertEq(usde.balanceOf(silo),              startingSiloBalance + 1_000_000e18 + 1);  // 1 wei deposit as well

        // Backstop allocator can unstake the funds
        vm.prank(backstopAllocator);
        mainnetController.ethena_unstake();

        assertEq(usde.balanceOf(address(almProxy)), 1_000_000e18 + 1);
        assertEq(usde.balanceOf(silo),              startingSiloBalance);
    }

}

contract MainnetController_Farm_Attack_Tests is Farm_TestBase {

    bytes32 depositKey;

    function setUp() public override {
        super.setUp();

        depositKey = mainnetController.farm_getDepositRateLimitKey(FARM, Ethereum.USDS);
    }

    function test_attack_stakingTokenChanged_depositToFarm() external {
        assertEq(rateLimits.getCurrentRateLimit(depositKey), 10_000_000e18);

        // Deposit succeeds with the original staking token (USDS).
        deal(Ethereum.USDS, address(almProxy), 1_000_000e18);

        vm.prank(allocator);
        mainnetController.farm_deposit(FARM, 1_000_000e18);

        assertEq(rateLimits.getCurrentRateLimit(depositKey), 9_000_000e18);

        // Attack: mock stakingToken() to return a different address.
        address changedStakingToken = Ethereum.DAI;
        vm.mockCall(
            FARM,
            abi.encodeWithSignature("stakingToken()"),
            abi.encode(changedStakingToken)
        );

        // Cannot deposit with changed staking token key.
        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(allocator);
        mainnetController.farm_deposit(FARM, 1);
    }

}

contract MainnetController_LayerZero_Attack_Tests is LayerZero_TestBase {

    using OptionsBuilder for bytes;

    function setUp() public override {
        super.setUp();

        vm.startPrank(SPARK_PROXY);
        rateLimits.setRateLimitData(key, 10_000_000e6, 0);
        mainnetController.layerZero_setRecipient(DESTINATION_ENDPOINT_ID, target);
        vm.stopPrank();
    }

    function test_attack_tokenChanged_transferTokenLayerZero() external {
        assertEq(rateLimits.getCurrentRateLimit(key), 10_000_000e6);

        deal(Ethereum.USDT, address(almProxy), 1_000_000e6);

        deal(allocator, 1 ether);

        ILayerZeroOFTLike.SendParam memory sendParams = ILayerZeroOFTLike.SendParam({
            dstEid       : DESTINATION_ENDPOINT_ID,
            to           : target,
            amountLD     : 1_000_000e6,
            minAmountLD  : 1_000_000e6,
            extraOptions : OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0),
            composeMsg   : "",
            oftCmd       : ""
        });

        ILayerZeroOFTLike.MessagingFee memory fee = ILayerZeroOFTLike(USDT_OFT).quoteSend(sendParams, false);

        // Transfer succeeds with original token() response (USDT).
        vm.prank(allocator);
        mainnetController.layerZero_transfer{value: fee.nativeFee}(
            USDT_OFT,
            1_000_000e6,
            DESTINATION_ENDPOINT_ID
        );

        assertEq(rateLimits.getCurrentRateLimit(key), 9_000_000e6);

        // Attack: mock token() to return a different asset.
        vm.mockCall(USDT_OFT, abi.encodeWithSignature("token()"), abi.encode(Ethereum.DAI));

        // Cannot transfer with changed token key.
        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(allocator);
        mainnetController.layerZero_transfer{value: fee.nativeFee}(USDT_OFT, 1, DESTINATION_ENDPOINT_ID);
    }

}

contract MainnetController_Maple_Attack_Tests is Maple_TestBase {

    function test_attack_compromisedAllocator_delayRequestMapleRedemption() external {
        deal(address(usdc), address(almProxy), 1_000_000e6);

        vm.prank(allocator);
        mainnetController.erc4626_deposit(address(SYRUP), 1_000_000e6, 0);

        // Malicious allocator delays the request for redemption for 1m
        // because new requests can't be fulfilled until the previous is fulfilled or cancelled
        vm.prank(allocator);
        mainnetController.maple_requestRedemption(address(SYRUP), 1);

        // Cannot process request
        vm.prank(allocator);
        vm.expectRevert("WM:AS:IN_QUEUE");
        mainnetController.maple_requestRedemption(address(SYRUP), 500_000e6);

        // Allocator admin can remove the compromised allocator and fallback to the governance allocator
        vm.prank(allocatorAdmin);
        accessControls.revokeRole(ALLOCATOR_ROLE, allocator);

        // Compromised allocator cannot perform attack anymore
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            allocator,
            ALLOCATOR_ROLE
        ));
        mainnetController.maple_requestRedemption(address(SYRUP), 1);

        // Governance allocator can cancel and submit the real request
        vm.startPrank(backstopAllocator);
        mainnetController.maple_cancelRedemption(address(SYRUP), 1);
        mainnetController.maple_requestRedemption(address(SYRUP), 500_000e6);
        vm.stopPrank();
    }

}

// A maker whose sell callback runs inside the proxy's buy, after the transfers, while the proxy's
// approval to Midnight is still open.
contract MidnightHostileMaker {

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address public immutable midnight;

    bool public tookOffer;
    bool public withdrew;
    bool public authorized;
    bool public repaid;
    bool public reenteredController;

    uint256 public allowanceSeen;

    address public controller;
    bytes   public controllerCall;
    bytes   public reentryRevertData;

    constructor(address midnight_) {
        midnight = midnight_;
    }

    function approveMidnight(address token) external {
        IERC20Like(token).approve(midnight, type(uint256).max);
    }

    function setControllerReentry(address controller_, bytes calldata call_) external {
        controller     = controller_;
        controllerCall = call_;
    }

    // Maker is the buyer: runs before the transfers of the proxy's sell.
    function onBuy(bytes32, Market memory market, uint256, uint256, uint256, address, bytes memory data)
        external returns (bytes32)
    {
        _attack(market, data);
        return CALLBACK_SUCCESS;
    }

    function onSell(
        bytes32,
        Market  memory market,
        uint256,
        uint256,
        uint256,
        address,
        address,
        bytes   memory data
    )
        external returns (bytes32)
    {
        _attack(market, data);
        return CALLBACK_SUCCESS;
    }

    function _attack(Market memory market, bytes memory data) internal {
        ( address proxy, Offer memory attackOffer, bytes memory ratifierData, uint256 units ) =
            abi.decode(data, (address, Offer, bytes, uint256));

        allowanceSeen = IERC20(market.loanToken).allowance(proxy, midnight);

        // Take an offer of our own choosing while the proxy's approval is live.
        try IMidnightAttackLike(midnight).take(
            attackOffer, ratifierData, units, address(this), address(0), address(0), ""
        ) {
            tookOffer = true;
        } catch {}

        // Move the proxy's position out from under it.
        try IMidnightAttackLike(midnight).withdraw(market, units, proxy, address(this)) {
            withdrew = true;
        } catch {}

        // Become an operator of the proxy for later.
        try IMidnightAttackLike(midnight).setIsAuthorized(address(this), true, proxy) {
            authorized = true;
        } catch {}

        // Name the proxy as the payer of our own repayment; zero units isolates the payer check.
        try IMidnightAttackLike(midnight).repay(market, 0, address(this), proxy, "") {
            repaid = true;
        } catch {}

        if (controller == address(0)) return;

        ( bool ok, bytes memory returnData ) = controller.call(controllerCall);

        reenteredController = ok;
        reentryRevertData   = returnData;
    }

}

// A maker callback that socializes a third borrower's bad debt while the proxy's fill is in
// flight, then restores the price so the maker's own health check still passes.
contract MidnightSlashingMaker {

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address    public immutable midnight;
    MockOracle public immutable oracle;
    address    public immutable victim;
    uint256    public immutable price;

    constructor(address midnight_, MockOracle oracle_, address victim_) {
        midnight = midnight_;
        oracle   = oracle_;
        victim   = victim_;
        price    = oracle_.price();
    }

    function approveMidnight(address token) external {
        IERC20Like(token).approve(midnight, type(uint256).max);
    }

    // Maker is the seller: runs after the transfers of the proxy's buy.
    function onSell(
        bytes32,
        Market  memory market,
        uint256,
        uint256,
        uint256,
        address,
        address,
        bytes   memory
    )
        external returns (bytes32)
    {
        _slash(market);
        return CALLBACK_SUCCESS;
    }

    // Maker is the buyer: runs before the transfers of the proxy's sell, and this contract pays.
    function onBuy(bytes32, Market memory market, uint256, uint256, uint256, address, bytes memory)
        external returns (bytes32)
    {
        _slash(market);
        return CALLBACK_SUCCESS;
    }

    function _slash(Market memory market) internal {
        oracle.setPrice(price / 100);
        IMidnightAttackLike(midnight).liquidate(
            market, 0, 0, 0, victim, false, address(this), address(0), ""
        );
        oracle.setPrice(price);
    }

}

// A maker callback that sends loan token to the proxy mid-fill, shrinking the balance delta the
// buy would otherwise meter and inflating the one the sell meters.
contract MidnightDonatingMaker {

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address public immutable midnight;

    constructor(address midnight_) {
        midnight = midnight_;
    }

    // Midnight charges the callback, not the maker, on the leg where the maker is the buyer.
    function approveMidnight(address token) external {
        IERC20Like(token).approve(midnight, type(uint256).max);
    }

    // Maker is the buyer: runs before the transfers of the proxy's sell.
    function onBuy(bytes32, Market memory market, uint256, uint256, uint256, address, bytes memory data)
        external returns (bytes32)
    {
        _donate(market, data);
        return CALLBACK_SUCCESS;
    }

    // Maker is the seller: runs after the transfers of the proxy's buy.
    function onSell(
        bytes32,
        Market  memory market,
        uint256,
        uint256,
        uint256,
        address,
        address,
        bytes   memory data
    )
        external returns (bytes32)
    {
        _donate(market, data);
        return CALLBACK_SUCCESS;
    }

    function _donate(Market memory market, bytes memory data) internal {
        ( address proxy, uint256 amount ) = abi.decode(data, (address, uint256));

        IERC20(market.loanToken).transfer(proxy, amount);
    }

}

contract MainnetController_Midnight_Attack_Tests is Midnight_TestBase {

    address internal victim = makeAddr("victim");

    uint256 internal attackUnits;  // 1k units, small enough to leave the approval mostly open

    MidnightHostileMaker  internal hostile;
    MidnightSlashingMaker internal slasher;
    MidnightDonatingMaker internal donator;

    function setUp() public override {
        super.setUp();

        attackUnits = 1_000 * loanUnit;

        hostile = new MidnightHostileMaker(MIDNIGHT);

        deal(address(loanToken), address(hostile), proxyBalance);
        hostile.approveMidnight(address(loanToken));

        donator = new MidnightDonatingMaker(MIDNIGHT);

        deal(address(loanToken), address(donator), proxyBalance);
        donator.approveMidnight(address(loanToken));

        // A second borrower whose debt backs part of the proxy's credit and can be written off
        // mid-fill. Thinly collateralized so a price crash leaves most of its debt as a loss.
        deal(address(weth), victim, 2_000_000e18);

        vm.startPrank(victim);
        midnight.setIsAuthorized(SETTER_RATIFIER, true, victim);
        weth.approve(MIDNIGHT, type(uint256).max);
        midnight.supplyCollateral(market, 0, 2_000_000e18, victim);
        vm.stopPrank();

        Offer memory victimOffer = _offer(false, TICK_98, seedUnits);
        victimOffer.maker                   = victim;
        victimOffer.receiverIfMakerIsSeller = victim;
        _ratify(victimOffer);

        _buy(victimOffer, seedUnits, type(uint256).max);

        slasher = new MidnightSlashingMaker(MIDNIGHT, oracle, victim);

        deal(address(loanToken), address(slasher), proxyBalance);
        slasher.approveMidnight(address(loanToken));
    }

    // An offer that would make the proxy the payer. The proxy authorizes no ratifier, so Midnight
    // refuses it before the ratifier is even consulted.
    function _proxyAsMakerOffer(uint256 units) internal view returns (Offer memory offer) {
        offer = Offer({
            market                  : market,
            buy                     : true,
            maker                   : address(almProxy),
            start                   : 0,
            expiry                  : block.timestamp + 1 days,
            tick                    : TICK_98,
            group                   : "attack",
            callback                : address(0),
            callbackData            : new bytes(0),
            receiverIfMakerIsSeller : address(0),
            ratifier                : SETTER_RATIFIER,
            reduceOnly              : false,
            maxUnits                : uint128(units),
            maxAssets               : 0,
            continuousFeeCap        : type(uint256).max
        });
    }

    // The victim repays part of its debt so there is something in the redeemable pool.
    function _victimRepays() internal {
        deal(address(loanToken), victim, attackUnits);

        vm.startPrank(victim);
        loanToken.approve(MIDNIGHT, attackUnits);
        midnight.repay(market, attackUnits, victim, address(0), "");
        vm.stopPrank();
    }

    function _positionCall() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            midnight.updatePositionView.selector, market, marketId, address(almProxy)
        );
    }

    function _position(uint256 credit, uint256 pendingFee) internal pure returns (bytes memory) {
        return abi.encode(uint128(credit), uint128(pendingFee), uint128(0));
    }

    function _mockProxyBalances(uint256 balanceBefore, uint256 balanceAfter) internal {
        bytes[] memory balances = new bytes[](2);
        balances[0] = abi.encode(balanceBefore);
        balances[1] = abi.encode(balanceAfter);

        vm.mockCalls(
            address(loanToken),
            abi.encodeWithSignature("balanceOf(address)", address(almProxy)),
            balances
        );
    }

    function test_attack_hostileMakerCallback_buyMidnight() external {
        uint256 expected     = _buyerAssets(attackUnits, TICK_98);
        uint256 creditBefore = _credit();

        Offer memory offer = _offer(false, TICK_98, attackUnits);
        offer.callback     = address(hostile);
        offer.callbackData = abi.encode(
            address(almProxy), _proxyAsMakerOffer(attackUnits), new bytes(0), attackUnits
        );
        _ratify(offer);

        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));

        // An unbounded maxAssetsIn leaves the approval open while the callback runs; the exact
        // bound would be fully spent before `onSell` and make the take leg fail on allowance alone.
        assertEq(_buy(offer, attackUnits, type(uint256).max), expected);

        assertGt(hostile.allowanceSeen(), 0);

        assertFalse(hostile.tookOffer());
        assertFalse(hostile.withdrew());
        assertFalse(hostile.authorized());
        assertFalse(hostile.repaid());

        // The proxy paid exactly the fill and nothing else, and holds no leftover approval.
        assertEq(loanToken.balanceOf(address(almProxy)),           balanceBefore - expected);
        assertEq(loanToken.balanceOf(address(hostile)),            proxyBalance);
        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
        assertEq(_credit(),                                        creditBefore + attackUnits);
        assertEq(midnight.debt(marketId, address(almProxy)),       0);

        assertFalse(midnight.isAuthorized(address(almProxy), address(hostile)));
    }

    // The same callback on the other leg, where the proxy gives up units instead of paying for
    // them, so there is no approval for the callback to spend in the first place.
    function test_attack_hostileMakerCallback_sellMidnight() external {
        uint256 expected     = _sellerAssets(attackUnits, TICK_99);
        uint256 creditBefore = _credit();

        Offer memory offer = _offer(true, TICK_99, attackUnits);
        offer.callback     = address(hostile);
        offer.callbackData = abi.encode(
            address(almProxy), _proxyAsMakerOffer(attackUnits), new bytes(0), attackUnits
        );
        _ratify(offer);

        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));

        assertEq(_sell(offer, attackUnits, expected), expected);

        assertEq(hostile.allowanceSeen(), 0);

        assertFalse(hostile.tookOffer());
        assertFalse(hostile.withdrew());
        assertFalse(hostile.authorized());
        assertFalse(hostile.repaid());

        assertEq(loanToken.balanceOf(address(almProxy)),           balanceBefore + expected);
        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
        assertEq(_credit(),                                        creditBefore - attackUnits);
        assertEq(midnight.debt(marketId, address(almProxy)),       0);

        assertFalse(midnight.isAuthorized(address(almProxy), address(hostile)));
    }

    // The entry leg runs the callback after its transfers, still inside the controller's call, so
    // the guard has to reject a nested entry point there too.
    function test_attack_controllerReentry_buyMidnight() external {
        _victimRepays();

        vm.prank(allocatorAdmin);
        accessControls.grantRole(ALLOCATOR_ROLE, address(hostile));

        hostile.setControllerReentry(
            address(mainnetController),
            abi.encodeWithSignature(
                "midnight_redeem(bytes32,uint256,uint256)", marketId, attackUnits, 1
            )
        );

        uint256 expected     = _buyerAssets(attackUnits, TICK_98);
        uint256 creditBefore = _credit();

        Offer memory offer = _offer(false, TICK_98, attackUnits);
        offer.callback     = address(hostile);
        offer.callbackData = abi.encode(
            address(almProxy), _proxyAsMakerOffer(attackUnits), new bytes(0), attackUnits
        );
        _ratify(offer);

        assertEq(_buy(offer, attackUnits, type(uint256).max), expected);

        assertFalse(hostile.reenteredController());

        assertEq(
            hostile.reentryRevertData(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );

        // Only the buy moved the position, and the redeem rate limit was never touched.
        assertEq(_credit(),                                 creditBefore + attackUnits);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey), rateLimit);
    }

    // The maker's callback runs inside the controller's own entry point, so the guard rejects a
    // reentry even from a caller holding the allocator role. The victim repays first so the nested
    // redeem reaches the venue rather than failing earlier on withdrawable liquidity.
    function test_attack_controllerReentry_sellMidnight() external {
        _victimRepays();

        vm.prank(allocatorAdmin);
        accessControls.grantRole(ALLOCATOR_ROLE, address(hostile));

        hostile.setControllerReentry(
            address(mainnetController),
            abi.encodeWithSignature(
                "midnight_redeem(bytes32,uint256,uint256)", marketId, attackUnits, 1
            )
        );

        uint256 expected     = _sellerAssets(attackUnits, TICK_99);
        uint256 creditBefore = _credit();

        Offer memory offer = _offer(true, TICK_99, attackUnits);
        offer.callback     = address(hostile);
        offer.callbackData = abi.encode(
            address(almProxy), _proxyAsMakerOffer(attackUnits), new bytes(0), attackUnits
        );
        _ratify(offer);

        assertEq(_sell(offer, attackUnits, expected), expected);

        assertFalse(hostile.reenteredController());

        assertEq(
            hostile.reentryRevertData(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );

        // Only the sell moved the position, and the redeem rate limit was never touched.
        assertEq(_credit(),                                   creditBefore - attackUnits);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),   rateLimit);
    }

    // The exact credit delta check is what catches a write-down landing inside the fill.
    function test_attack_slashedMidFill_buyMidnight() external {
        Offer memory offer = _offer(false, TICK_98, attackUnits);
        offer.callback = address(slasher);
        _ratify(offer);

        vm.expectRevert("MidnightFacet/credit-delta-mismatch");
        _buy(offer, attackUnits, type(uint256).max);
    }

    function test_attack_slashedMidFill_sellMidnight() external {
        uint256 units = seedUnits / 2;

        Offer memory offer = _offer(true, TICK_99, units);
        offer.callback = address(slasher);
        _ratify(offer);

        vm.expectRevert("MidnightFacet/credit-delta-mismatch");
        _sell(offer, units, 1);
    }

    // The delta is an equality, so a fill that credits more than the units taken is refused too.
    // Mocked because Midnight credits a take exactly.
    function test_attack_overcreditedFill_buyMidnight() external {
        Offer memory offer = _offer(false, TICK_98, attackUnits);

        bytes[] memory positions = new bytes[](2);
        positions[0] = _position(_credit(),                    _pendingFee());
        positions[1] = _position(_credit() + attackUnits + 1,  _pendingFee());

        vm.mockCalls(MIDNIGHT, _positionCall(), positions);

        vm.expectRevert("MidnightFacet/credit-delta-mismatch");
        _buy(offer, attackUnits, type(uint256).max);
    }

    function test_attack_undercreditedFill_sellMidnight() external {
        Offer memory offer = _offer(true, TICK_99, attackUnits);

        bytes[] memory positions = new bytes[](2);
        positions[0] = _position(_credit(),                   _pendingFee());
        positions[1] = _position(_credit() - attackUnits + 1, _pendingFee());

        vm.mockCalls(MIDNIGHT, _positionCall(), positions);

        vm.expectRevert("MidnightFacet/credit-delta-mismatch");
        _sell(offer, attackUnits, 1);
    }

    // The approval bounds what Midnight can pull, so the spend can only overshoot the bound if the
    // loan token itself moves more than Midnight asked for. Mocked because no live token does.
    function test_attack_loanTokenOvercharges_buyMidnight() external {
        uint256 maxAssetsIn = _buyerAssets(attackUnits, TICK_98);
        uint256 balance     = loanToken.balanceOf(address(almProxy));

        Offer memory offer = _offer(false, TICK_98, attackUnits);

        _mockProxyBalances(balance, balance - maxAssetsIn - 1);

        vm.expectRevert("MidnightFacet/max-assets-in-exceeded");
        _buy(offer, attackUnits, maxAssetsIn);
    }

    // Loan token arriving inside the take shrinks the balance delta, so the buy meters the higher
    // of that delta and the assets Midnight reports the buyer paid.
    function test_attack_donatedMidFill_buyMidnight() external {
        // A live fee separates what the buyer pays from what the maker receives, pinning which
        // half of the take return the facet meters.
        _setSettlementFee(SETTLEMENT_FEE);

        uint256 expected = _buyerAssets(attackUnits, TICK_98);
        uint256 donation = expected / 2;

        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));
        uint256 buyRoom       = rateLimits.getCurrentRateLimit(buyKey);

        Offer memory offer = _offer(false, TICK_98, attackUnits);
        offer.callback     = address(donator);
        offer.callbackData = abi.encode(address(almProxy), donation);
        _ratify(offer);

        vm.expectEmit(address(mainnetController));
        emit IMidnightFacet.MidnightBuy(marketId, attackUnits, expected);

        assertEq(_buy(offer, attackUnits, expected), expected);

        // The balance delta understates the spend by the donation; the rate limit does not.
        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore - expected + donation);
        assertEq(rateLimits.getCurrentRateLimit(buyKey), buyRoom - expected);
    }

    // On the other leg the donation inflates the delta instead, and the sell is metered on it: the
    // key is charged for loan token the trade never earned.
    function test_attack_donatedMidFill_sellMidnight() external {
        _setSettlementFee(SETTLEMENT_FEE);

        uint256 expected = _sellerAssets(attackUnits, TICK_99);
        uint256 donation = expected / 2;

        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));
        uint256 sellRoom      = rateLimits.getCurrentRateLimit(sellKey);

        Offer memory offer = _offer(true, TICK_99, attackUnits);
        offer.callback     = address(donator);
        offer.callbackData = abi.encode(address(almProxy), donation);
        _ratify(offer);

        vm.expectEmit(address(mainnetController));
        emit IMidnightFacet.MidnightSell(marketId, attackUnits, expected + donation);

        assertEq(_sell(offer, attackUnits, expected), expected + donation);

        assertEq(loanToken.balanceOf(address(almProxy)),  balanceBefore + expected + donation);
        assertEq(rateLimits.getCurrentRateLimit(sellKey), sellRoom - expected - donation);
    }

    // Every take is capped at the proxy's credit, so debt can only appear if the venue reports it
    // against the proxy anyway. Mocked because Midnight cannot be driven into that state.
    function test_attack_debtReported_buyMidnight() external {
        Offer memory offer = _offer(false, TICK_98, attackUnits);

        vm.mockCall(
            MIDNIGHT,
            abi.encodeWithSignature("debt(bytes32,address)", marketId, address(almProxy)),
            abi.encode(uint128(1))
        );

        vm.expectRevert("MidnightFacet/debt-not-zero");
        _buy(offer, attackUnits, type(uint256).max);
    }

    function test_attack_debtReported_sellMidnight() external {
        Offer memory offer = _offer(true, TICK_99, attackUnits);

        vm.mockCall(
            MIDNIGHT,
            abi.encodeWithSignature("debt(bytes32,address)", marketId, address(almProxy)),
            abi.encode(uint128(1))
        );

        vm.expectRevert("MidnightFacet/debt-not-zero");
        _sell(offer, attackUnits, 1);
    }

    function test_attack_debtReported_redeemMidnight() external {
        _victimRepays();

        vm.mockCall(
            MIDNIGHT,
            abi.encodeWithSignature("debt(bytes32,address)", marketId, address(almProxy)),
            abi.encode(uint128(1))
        );

        vm.expectRevert("MidnightFacet/debt-not-zero");
        _redeem(attackUnits, 1);
    }

    // Redemption meters the loan token actually received, not the units asked for. Mocked because
    // a live withdraw pays the units exactly.
    function test_attack_loanTokenUnderpays_redeemMidnight() external {
        _victimRepays();

        uint256 balance    = loanToken.balanceOf(address(almProxy));
        uint256 redeemRoom = rateLimits.getCurrentRateLimit(redeemKey);

        _mockProxyBalances(balance, balance + attackUnits - 1);

        vm.expectEmit(address(mainnetController));
        emit IMidnightFacet.MidnightRedeem(marketId, attackUnits, attackUnits - 1);

        assertEq(_redeem(attackUnits, attackUnits - 1), attackUnits - 1);

        assertEq(rateLimits.getCurrentRateLimit(redeemKey), redeemRoom - attackUnits + 1);
    }

    function test_attack_loanTokenUnderpays_redeemMidnight_minAssetsOut() external {
        _victimRepays();

        uint256 balance = loanToken.balanceOf(address(almProxy));

        _mockProxyBalances(balance, balance + attackUnits - 1);

        vm.expectRevert("MidnightFacet/min-assets-out-not-met");
        _redeem(attackUnits, attackUnits);
    }

}

// Takes an offer of its own choosing from inside the proxy's fill, and keeps the reason it failed.
contract MidnightNestedTaker {

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address public immutable midnight;

    bool public innerAttempted;
    bool public innerSucceeded;

    bytes public innerError;

    constructor(address midnight_) {
        midnight = midnight_;
    }

    function onSell(
        bytes32,
        Market  memory,
        uint256,
        uint256,
        uint256,
        address,
        address,
        bytes   memory data
    )
        external returns (bytes32)
    {
        ( Offer memory offer, bytes memory ratifierData, uint256 units ) =
            abi.decode(data, (Offer, bytes, uint256));

        innerAttempted = true;

        try IMidnightAttackLike(midnight).take(
            offer, ratifierData, units, address(this), address(this), address(0), ""
        ) {
            innerSucceeded = true;
        } catch (bytes memory err) {
            innerError = err;
        }

        return CALLBACK_SUCCESS;
    }

}

// A compromised funding strategy, asking `fundFill` for more than its reported units justify.
contract MidnightGreedyStrategy {

    address public immutable controller;

    constructor(address controller_) {
        controller = controller_;
    }

    function pull(bytes32 marketId, bool buy, uint256 assets, uint256 units, uint256 pendingFee)
        external
    {
        IMidnightFundFillLike(controller)
            .midnight_fundFill(marketId, buy, assets, units, pendingFee);
    }

}

contract MainnetController_MidnightMaker_Attack_Tests is Midnight_Maker_TestBase {

    address internal attacker = makeAddr("attacker");

    MidnightGreedyStrategy internal greedy;

    function setUp() public override {
        super.setUp();

        greedy = new MidnightGreedyStrategy(address(mainnetController));

        // Collateralized and able to ratify offers of its own, so it can publish a book.
        deal(address(loanToken), attacker, proxyBalance);
        deal(address(weth),      attacker, 2_000_000e18);

        vm.startPrank(attacker);
        midnight.setIsAuthorized(SETTER_RATIFIER, true, attacker);
        loanToken.approve(MIDNIGHT, type(uint256).max);
        weth.approve(MIDNIGHT, type(uint256).max);
        midnight.supplyCollateral(market, 0, 2_000_000e18, attacker);
        vm.stopPrank();
    }

    // Both of the singleton's own gates pass here, so ratification of that exact offer is the
    // only thing left between a fabricated one and a fill.
    function test_attack_unratifiedProxyMakerOffer_makeMidnight() external {
        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        assertTrue(midnight.isAuthorized(address(almProxy), SETTER_RATIFIER));

        offer.tick = MAKER_BUY_TICK + 4;

        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotRatified()"));
        ITakeLike(MIDNIGHT).take(
            offer,
            _ratifierData(offer),
            seedUnits,
            attacker,
            attacker,
            address(0),
            new bytes(0)
        );

        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore);
    }

    // Round-tripping the position against our own book would pay the spread to the venue.
    function test_attack_selfTake_makeMidnight() external {
        _seedCredit();

        Offer memory sell = _makerOffer(false, MAKER_SELL_TICK, seedUnits);

        // Caught by the facet's own anti-self-dealing check before it reaches the singleton.
        vm.expectRevert("MidnightFacet/invalid-offer-receiver");
        vm.prank(allocator);
        mainnetController.midnight_buy(
            marketId,
            sell,
            _ratifierData(sell),
            seedUnits,
            type(uint256).max
        );

        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        vm.expectRevert(abi.encodeWithSignature("SelfTake()"));
        vm.prank(allocator);
        mainnetController.midnight_sell(marketId, buy, _ratifierData(buy), seedUnits, 1);
    }

    // The bound needs no rounding slack on real market state: the honest amount clears and one
    // wei more does not.
    function test_attack_greedyStrategyOverdraws_makeMidnight() external {
        // Zero the entry yield so the tick is the binding bound and the expectation is exact.
        _setConfig(MAKER_BUY_TICK, TICK_98, 0, MAX_SELL_YIELD, MAX_CONTINUOUS_FEE_CBPS, 0);

        _onboardStrategy(address(greedy));

        uint256 units = seedUnits;
        uint256 bound = units * MidnightTickLib.tickToPrice(MAKER_BUY_TICK) / 1e18;

        vm.expectRevert("MidnightFacet/fill-price-too-high");
        greedy.pull(marketId, true, bound + 1, units, 0);

        // 362 of the 1,686 accessible steps are flat, so a step up the grid being dearer has to
        // be asserted rather than assumed.
        uint256 dearer = units * MidnightTickLib.tickToPrice(MAKER_BUY_TICK + 4) / 1e18;

        assertGt(dearer, bound);

        vm.expectRevert("MidnightFacet/fill-price-too-high");
        greedy.pull(marketId, true, dearer, units, 0);

        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));

        greedy.pull(marketId, true, bound, units, 0);

        assertEq(loanToken.balanceOf(address(greedy)),   bound);
        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore - bound);
        assertEq(rateLimits.getCurrentRateLimit(buyKey), rateLimit - bound);
    }

    // A whitelisted strategy can report an exit that never happened, but neither leg restores
    // anything, so a fabricated exit buys no entry room and the entry meter alone bounds the game.
    function test_attack_strategyCannotFakeExitsForEntryRoom_makeMidnight() external {
        _onboardStrategy(address(greedy));

        uint256 units = seedUnits;
        uint256 floorAssets = units * MidnightTickLib.tickToPrice(TICK_98) / 1e18;

        // Drain the entry budget down by one honest-priced entry's worth.
        greedy.pull(marketId, true, floorAssets, units, 0);

        assertEq(rateLimits.getCurrentRateLimit(buyKey), rateLimit - floorAssets);

        uint256 proxyBalanceBefore  = loanToken.balanceOf(address(almProxy));
        uint256 greedyBalanceBefore = loanToken.balanceOf(address(greedy));

        greedy.pull(marketId, false, floorAssets, units, 0);

        // The fabricated exit moved nothing, burned exit room, and returned no entry room.
        assertEq(rateLimits.getCurrentRateLimit(buyKey),  rateLimit - floorAssets);
        assertEq(rateLimits.getCurrentRateLimit(sellKey), rateLimit - floorAssets);

        assertEq(loanToken.balanceOf(address(greedy)),   greedyBalanceBefore);
        assertEq(loanToken.balanceOf(address(almProxy)), proxyBalanceBefore);

        // With the entry meter emptied, no number of fabricated exits reopens it.
        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(buyKey, floorAssets, 0);

        greedy.pull(marketId, true, floorAssets, units, 0);

        greedy.pull(marketId, false, floorAssets, units, 0);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        greedy.pull(marketId, true, floorAssets, units, 0);
    }

    // No zero-unit guard upstream and the consumed cap passes at zero, so a consumed offer stays
    // pokeable; the strategy's short-circuit is what keeps that free.
    function test_attack_zeroUnitPokeOnConsumedOffer_makeMidnight() external {
        Offer memory buy = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        _take(buy, seedUnits);

        uint256 balanceBefore  = loanToken.balanceOf(address(almProxy));
        uint256 creditBefore   = _credit();
        uint256 limitBefore    = rateLimits.getCurrentRateLimit(buyKey);
        uint128 consumedBefore = midnight.consumed(address(almProxy), BUY_GROUP);

        _takeExpectRevert(buy, 1, abi.encodeWithSignature("ConsumedUnits()"));

        bytes memory ratifierData = _ratifierData(buy);

        vm.prank(attacker);
        ( uint256 buyerAssets, uint256 sellerAssets ) = ITakeLike(MIDNIGHT).take(
            buy, ratifierData, 0, attacker, attacker, address(0), new bytes(0)
        );

        assertEq(buyerAssets,  0);
        assertEq(sellerAssets, 0);

        assertEq(loanToken.balanceOf(address(almProxy)),          balanceBefore);
        assertEq(_credit(),                                       creditBefore);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),     limitBefore);
        assertEq(midnight.consumed(address(almProxy), BUY_GROUP), consumedBefore);

        // The poke settles two zero-value transfers from the proxy, and needs no allowance to.
        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
    }

    // Filling one of our resting buy offers runs through fundFill, so a taker reached from inside
    // a batch is a second controller entry, and the guard is shared across facets.
    function test_attack_nestedControllerEntry_makeMidnight() external {
        MidnightNestedTaker nested = new MidnightNestedTaker(MIDNIGHT);

        deal(address(weth), address(nested), 2_000_000e18);

        vm.startPrank(address(nested));
        weth.approve(MIDNIGHT, type(uint256).max);
        midnight.supplyCollateral(market, 0, 2_000_000e18, address(nested));
        vm.stopPrank();

        Offer memory ours = _makerOffer(true, MAKER_BUY_TICK, seedUnits);

        Offer memory outer = _offer(false, TICK_98, seedUnits);
        outer.callback     = address(nested);
        outer.callbackData = abi.encode(ours, _ratifierData(ours), seedUnits);

        _ratify(outer);

        uint256 creditBefore   = _credit();
        uint256 limitBefore    = rateLimits.getCurrentRateLimit(buyKey);
        uint128 consumedBefore = midnight.consumed(address(almProxy), BUY_GROUP);

        uint256 spent = _buy(outer, seedUnits, type(uint256).max);

        assertTrue (nested.innerAttempted());
        assertFalse(nested.innerSucceeded());

        assertEq(
            nested.innerError(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );

        // The proxy got exactly the fill it asked for, and none of the nested one.
        assertEq(_credit(), creditBefore + seedUnits);

        // The nested entry would have debited the same meter a second time.
        assertEq(rateLimits.getCurrentRateLimit(buyKey),          limitBefore - spent);
        assertEq(midnight.consumed(address(almProxy), BUY_GROUP), consumedBefore);
    }

}

contract MainnetController_Pendle_Attack_Tests is Pendle_TestBase {

    function test_attack_readTokensChanged_redeemPendlePT() external {
        (address sy, address pt, address yt) = pendleMarket.readTokens();

        // Redeem succeeds with the original market token.
        vm.prank(PT_WHALE);
        IERC20Like(pt).transfer(address(almProxy), 1_000_000e18);

        vm.warp(pendleMarket.expiry());

        uint256 beforeLimit = rateLimits.getCurrentRateLimit(redeemKey);

        vm.prank(allocator);
        mainnetController.pendle_redeem(address(pendleMarket), 500_000e18, 1);

        assertLt(rateLimits.getCurrentRateLimit(redeemKey), beforeLimit);

        vm.prank(PT_WHALE);
        IERC20Like(pt).transfer(address(almProxy), 500_000e18);

        // Attack: market implementation changes readTokens() to return a different PT.
        vm.mockCall(
            address(pendleMarket),
            abi.encodeWithSignature("readTokens()"),
            abi.encode(sy, Ethereum.DAI, yt)
        );

        vm.prank(address(almProxy));
        IERC20Like(pt).approve(GroveEthereum.PENDLE_ROUTER, type(uint256).max);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(allocator);
        mainnetController.pendle_redeem(address(pendleMarket), 500_000e18, 1);
    }

}

contract MainnetController_UniswapV3_Attack_Tests is UniswapV3_TestBase {

    function _defaultAddParams()
        internal
        view
        returns (
            IUniswapV3Facet.Ticks memory tick,
            IUniswapV3Facet.TokenAmounts memory target,
            IUniswapV3Facet.TokenAmounts memory min
        )
    {
        tick = IUniswapV3Facet.Ticks({
            lower : _toSpacedTick(initTick - 100),
            upper : _toSpacedTick(initTick + 100)
        });

        uint256 amount0 = 10_000 * 10 ** uint256(token0Decimals);
        uint256 amount1 = 10_000 * 10 ** uint256(token1.decimals());

        target = IUniswapV3Facet.TokenAmounts({ amount0: amount0, amount1: amount1 });
        min    = _minLiquidityPosition(amount0, amount1);
    }

    function test_attack_token0Changed_addLiquidity() external {
        (
            IUniswapV3Facet.Ticks memory tick,
            IUniswapV3Facet.TokenAmounts memory target,
            IUniswapV3Facet.TokenAmounts memory min
        ) =_defaultAddParams();

        // Mint succeeds with the original token0()/token1() responses.
        deal(address(token0), address(almProxy), target.amount0);
        deal(address(token1), address(almProxy), target.amount1);

        vm.prank(allocator);
        mainnetController.uniswapV3_addLiquidity({
            pool     : _getPool(),
            tokenId  : 0,
            ticks    : tick,
            target   : target,
            min      : min,
            deadline : block.timestamp + 1 hours
        });

        // Attack: returns a different token0().
        vm.mockCall(
            _getPool(),
            abi.encodeCall(IUniswapV3PoolLike.token0, ()),
            abi.encode(Ethereum.DAI)
        );

        // Keep mint path and mock PositionManager.mint so execution reaches rate-limit
        // decrement logic instead of reverting inside PositionManager.
        vm.mockCall(
            UNISWAP_V3_POSITION_MANAGER,
            abi.encodeCall(
                INonfungiblePositionManager.mint,
                (
                    INonfungiblePositionManager.MintParams({
                        token0         : Ethereum.DAI,
                        token1         : address(token1),
                        fee            : poolFee,
                        tickLower      : tick.lower,
                        tickUpper      : tick.upper,
                        amount0Desired : target.amount0,
                        amount1Desired : target.amount1,
                        amount0Min     : min.amount0,
                        amount1Min     : min.amount1,
                        recipient      : address(almProxy),
                        deadline       : block.timestamp + 1 hours
                    })
                )
            ),
            abi.encode(uint256(1), uint128(1), uint256(0), uint256(0))
        );

        deal(Ethereum.DAI,    address(almProxy), target.amount0);
        deal(address(token1), address(almProxy), target.amount1);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(allocator);
        mainnetController.uniswapV3_addLiquidity({
            pool     : _getPool(),
            tokenId  : 0,
            ticks    : tick,
            target   : target,
            min      : min,
            deadline : block.timestamp + 1 hours
        });
    }

}

contract MainnetController_UniswapV4_Attack_Tests is UniswapV4_USDC_USDT_TestBase {

    function _setV4MintConfig() internal {
        vm.startPrank(SPARK_PROXY);
        mainnetController.uniswapV4_setTickLimits(_POOL_ID, -60, 60, 20);
        rateLimits.setRateLimitData(_aggregateDepositLimitKey, 5_000_000e18, uint256(5_000_000e18) / 1 days);
        rateLimits.setRateLimitData(_token0DepositLimitKey,    5_000_000e6,  uint256(5_000_000e6)  / 1 days);
        rateLimits.setRateLimitData(_token1DepositLimitKey,    5_000_000e6,  uint256(5_000_000e6)  / 1 days);
        vm.stopPrank();
    }

    function test_attack_poolKeysCurrency0Changed_mintPosition() external {
        _setV4MintConfig();

        (uint128 amount0Max, uint128 amount1Max) = _getIncreasePositionMaxAmounts(_POOL_ID, -10, 0, 1_000_000e6, 0.99e18);

        PoolKey memory originalPoolKey = IUniswapV4PositionManagerLike(_UNISWAP_V4_POSITION_MANAGER).poolKeys(bytes25(_POOL_ID));

        // Ensure proxy is funded for each mint attempt.
        deal(Currency.unwrap(originalPoolKey.currency0), address(almProxy), amount0Max);
        deal(Currency.unwrap(originalPoolKey.currency1), address(almProxy), amount1Max);

        // Mint succeeds with original poolKeys() response.
        vm.prank(allocator);
        mainnetController.uniswapV4_mintPosition(_POOL_ID, -10, 0, 1_000_000e6, amount0Max, amount1Max);

        PoolKey memory changedPoolKey = originalPoolKey;
        changedPoolKey.currency0 = Currency.wrap(Ethereum.DAI);

        deal(Currency.unwrap(originalPoolKey.currency0), address(almProxy), amount0Max);
        deal(Currency.unwrap(originalPoolKey.currency1), address(almProxy), amount1Max);

        // Attack: returns a different poolKeys().
        vm.mockCall(
            _UNISWAP_V4_POSITION_MANAGER,
            abi.encodeWithSignature("poolKeys(bytes25)", bytes25(_POOL_ID)),
            abi.encode(changedPoolKey)
        );

        // Cannot mint if mutable poolKeys() dependency changes.
        vm.expectRevert("UniswapV4Facet/poolKey-poolId-mismatch");
        vm.prank(allocator);
        mainnetController.uniswapV4_mintPosition(_POOL_ID, -10, 0, 1_000_000e6, amount0Max, amount1Max);
    }

}

contract MainnetController_WEETH_Attack_Tests is WEETH_TestBase {

    bytes32 depositKey;

    function setUp() public override {
        super.setUp();

        depositKey = mainnetController.weeth_getDepositRateLimitKey(address(eeth), address(liquidityPool));

        vm.startPrank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(depositKey, 1_000e18, uint256(1_000e18) / 1 days);
        vm.stopPrank();
    }

    function test_attack_eETHChanged_depositToWeETH() external {
        assertEq(rateLimits.getCurrentRateLimit(depositKey), 1_000e18);

        // Deposit succeeds with the original eETH address.
        deal(Ethereum.WETH, address(almProxy), 1_000e18);

        vm.startPrank(allocator);
        mainnetController.weeth_deposit(1_000e18, _getMinSharesOut(1_000e18));
        vm.stopPrank();

        assertEq(rateLimits.getCurrentRateLimit(depositKey), 0);

        // Attack: mutable dependency changes eETH address.
        vm.mockCall(
            Ethereum.WEETH,
            abi.encodeWithSignature("eETH()"),
            abi.encode(Ethereum.DAI)
        );
        vm.mockCall(
            Ethereum.DAI,
            abi.encodeWithSignature("liquidityPool()"),
            abi.encode(address(liquidityPool))
        );

        // Cannot deposit with the changed eETH address.
        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(allocator);
        mainnetController.weeth_deposit(1, 0);
    }

}

