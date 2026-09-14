// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import {
    CollateralParams,
    Market,
    MidnightUtils
} from "../../src/facets/midnight/MidnightUtils.sol";

// Wrapper contract to expose library internals for testing
contract MidnightUtilsHarness {

    function toId(Market memory market) external pure returns (bytes32) {
        return MidnightUtils.toId(market);
    }

    function tickToPrice(uint256 tick) external pure returns (uint256) {
        return MidnightUtils.tickToPrice(tick);
    }

    function wExp(int256 x) external pure returns (uint256) {
        return MidnightUtils.wExp(x);
    }

    function divHalfDownUnchecked(uint256 x, uint256 d) external pure returns (uint256) {
        return MidnightUtils.divHalfDownUnchecked(x, d);
    }

}

contract MidnightUtilsTestBase is Test {

    MidnightUtilsHarness internal harness;

    function setUp() public {
        harness = new MidnightUtilsHarness();
    }

}

contract MidnightUtils_TickToPrice_Tests is MidnightUtilsTestBase {

    // The grid is centered on a price of one half at the middle tick and capped at par.
    function test_tickToPrice_anchors() external view {
        assertEq(harness.tickToPrice(0),                      0);
        assertEq(harness.tickToPrice(MidnightUtils.MAX_TICK / 2), 0.5e18);
        assertEq(harness.tickToPrice(MidnightUtils.MAX_TICK),     1e18);
    }

    function test_tickToPrice_outOfRange() external {
        vm.expectRevert("MidnightFacet/tick-out-of-range");
        harness.tickToPrice(MidnightUtils.MAX_TICK + 1);
    }

    function test_tickToPrice_roundedToStep() external view {
        for (uint256 tick = 0; tick <= MidnightUtils.MAX_TICK; tick += 97) {
            assertEq(harness.tickToPrice(tick) % MidnightUtils.PRICE_ROUNDING_STEP, 0);
        }
    }

    // Tick bounds are enforced in price space, which only works if the conversion never
    // reverses order: a higher tick must never map to a lower price.
    function testFuzz_tickToPrice_monotonic(uint256 tick) external view {
        tick = bound(tick, 1, MidnightUtils.MAX_TICK);

        assertGe(harness.tickToPrice(tick), harness.tickToPrice(tick - 1));
    }

    function testFuzz_tickToPrice_atMostPar(uint256 tick) external view {
        tick = bound(tick, 0, MidnightUtils.MAX_TICK);

        assertLe(harness.tickToPrice(tick), 1e18);
    }

}

contract MidnightUtils_WExp_Tests is MidnightUtilsTestBase {

    function test_wExp_zero() external view {
        assertEq(harness.wExp(0), 1e18);
    }

    // The negative branch is the reciprocal of the positive branch.
    function test_wExp_negativeIsReciprocal() external view {
        int256 x = 0.5e18;

        assertEq(harness.wExp(-x), 1e36 / harness.wExp(x));
    }

    function testFuzz_wExp_nonDecreasing(int256 x) external view {
        // Ticks only ever feed |x| <= LN_ONE_PLUS_DELTA * MAX_TICK / 2 into wExp.
        x = bound(x, -17e18, 17e18 - 1);

        assertLe(harness.wExp(x), harness.wExp(x + 1));
    }

}

contract MidnightUtils_DivHalfDownUnchecked_Tests is MidnightUtilsTestBase {

    function test_divHalfDownUnchecked_exact() external view {
        assertEq(harness.divHalfDownUnchecked(10, 5), 2);
    }

    function test_divHalfDownUnchecked_roundsHalfDown() external view {
        assertEq(harness.divHalfDownUnchecked(15, 10), 1);  // 1.5 -> 1
        assertEq(harness.divHalfDownUnchecked(16, 10), 2);  // 1.6 -> 2
        assertEq(harness.divHalfDownUnchecked(14, 10), 1);  // 1.4 -> 1
    }

}

contract MidnightUtils_ToId_Tests is MidnightUtilsTestBase {

    function _market(address midnight, address loanToken) internal pure returns (Market memory) {
        CollateralParams[] memory collateralParams = new CollateralParams[](1);
        collateralParams[0] = CollateralParams({
            token             : address(0xC0),
            lltv              : 0.86e18,
            liquidationCursor : 0.3e18,
            oracle            : address(0x01)
        });

        return Market({
            chainId          : 1,
            midnight         : midnight,
            loanToken        : loanToken,
            collateralParams : collateralParams,
            maturity         : 1_800_000_000,
            rcfThreshold     : type(uint256).max,
            enterGate        : address(0),
            liquidatorGate   : address(0)
        });
    }

    // The id is the CREATE2 address of the config stored as bytecode, so every field commits.
    function test_toId_isCreate2Address() external view {
        Market memory market = _market(address(0xA1), address(0xB1));

        bytes32 expected = keccak256(abi.encodePacked(
            uint8(0xff),
            market.midnight,
            uint256(0),
            keccak256(abi.encodePacked(MidnightUtils.SSTORE2_PREFIX, abi.encode(market)))
        ));

        assertEq(harness.toId(market), expected);
    }

    function test_toId_commitsToEveryField() external view {
        Market memory base = _market(address(0xA1), address(0xB1));
        bytes32 baseId = harness.toId(base);

        Market memory m = _market(address(0xA1), address(0xB1));
        m.chainId = 8453;
        assertNotEq(harness.toId(m), baseId);

        m = _market(address(0xA2), address(0xB1));
        assertNotEq(harness.toId(m), baseId);

        m = _market(address(0xA1), address(0xB2));
        assertNotEq(harness.toId(m), baseId);

        m = _market(address(0xA1), address(0xB1));
        m.maturity += 1;
        assertNotEq(harness.toId(m), baseId);

        m = _market(address(0xA1), address(0xB1));
        m.collateralParams[0].lltv += 1;
        assertNotEq(harness.toId(m), baseId);
    }

}
