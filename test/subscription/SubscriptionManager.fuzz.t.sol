// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SubscriptionManager, ISubscriptionManager } from "../../src/subscription/SubscriptionManager.sol";
import {
    ERC7715PermissionManager,
    IERC7715PermissionManager
} from "../../src/subscription/ERC7715PermissionManager.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice Mock ERC20 for testing
 */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title SubscriptionManagerFuzzTest
 * @notice Fuzzing tests for SubscriptionManager edge cases and boundary values
 */
contract SubscriptionManagerFuzzTest is Test {
    SubscriptionManager public subManager;
    ERC7715PermissionManager public permManager;
    MockERC20 public token;

    address public owner;
    address public merchant;
    address public processor;

    uint256 public constant MIN_PERIOD = 1 hours;
    uint256 public constant MAX_PERIOD = 365 days;

    function setUp() public {
        owner = makeAddr("owner");
        merchant = makeAddr("merchant");
        processor = makeAddr("processor");

        vm.startPrank(owner);
        permManager = new ERC7715PermissionManager();
        subManager = new SubscriptionManager(address(permManager));

        permManager.addAuthorizedExecutor(address(subManager));
        subManager.addProcessor(processor);

        token = new MockERC20();
        vm.stopPrank();
    }

    /* //////////////////////////////////////////////////////////////
                        PLAN CREATION FUZZ TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Fuzz test plan creation with various amounts
     * @param amount The subscription amount (bounded to reasonable range)
     */
    function testFuzz_CreatePlan_Amount(uint256 amount) public {
        // Bound to reasonable values (1 wei to 1 billion tokens)
        amount = bound(amount, 1, 1_000_000_000 ether);

        vm.prank(merchant);
        uint256 planId = subManager.createPlan(amount, 30 days, address(token), 0, 0, 0, "Test Plan", "Description");

        (, uint256 storedAmount,,,,,,,,,) = subManager.plans(planId);
        assertEq(storedAmount, amount, "Amount not stored correctly");
    }

    /**
     * @notice Fuzz test plan creation with various periods
     * @param period The payment period (bounded to valid range)
     */
    function testFuzz_CreatePlan_Period(uint256 period) public {
        // Bound to valid period range
        period = bound(period, MIN_PERIOD, MAX_PERIOD);

        vm.prank(merchant);
        uint256 planId = subManager.createPlan(10 ether, period, address(token), 0, 0, 0, "Test Plan", "Description");

        (,, uint256 storedPeriod,,,,,,,,) = subManager.plans(planId);
        assertEq(storedPeriod, period, "Period not stored correctly");
    }

    /**
     * @notice Fuzz test plan creation should fail with period below minimum
     * @param period Period value below MIN_PERIOD
     */
    function testFuzz_CreatePlan_InvalidPeriod_TooShort(uint256 period) public {
        // Ensure period is below minimum (1 hour)
        period = bound(period, 0, MIN_PERIOD - 1);

        vm.prank(merchant);
        vm.expectRevert(ISubscriptionManager.InvalidPeriod.selector);
        subManager.createPlan(10 ether, period, address(token), 0, 0, 0, "Test Plan", "Description");
    }

    /**
     * @notice Fuzz test plan creation should fail with period above maximum
     * @param period Period value above MAX_PERIOD
     */
    function testFuzz_CreatePlan_InvalidPeriod_TooLong(uint256 period) public {
        // Ensure period is above maximum (365 days)
        period = bound(period, MAX_PERIOD + 1, type(uint128).max);

        vm.prank(merchant);
        vm.expectRevert(ISubscriptionManager.InvalidPeriod.selector);
        subManager.createPlan(10 ether, period, address(token), 0, 0, 0, "Test Plan", "Description");
    }

    /**
     * @notice Fuzz test plan creation with trial periods
     * @param trialPeriod Trial period duration
     */
    function testFuzz_CreatePlan_TrialPeriod(uint256 trialPeriod) public {
        // Bound trial period to reasonable range
        trialPeriod = bound(trialPeriod, 0, 90 days);

        vm.prank(merchant);
        uint256 planId =
            subManager.createPlan(10 ether, 30 days, address(token), trialPeriod, 0, 0, "Test Plan", "Description");

        (,,,, uint256 storedTrialPeriod,,,,,,) = subManager.plans(planId);
        assertEq(storedTrialPeriod, trialPeriod, "Trial period not stored correctly");
    }

    /**
     * @notice Fuzz test plan creation with grace periods
     * @param gracePeriod Grace period duration
     */
    function testFuzz_CreatePlan_GracePeriod(uint256 gracePeriod) public {
        // Bound grace period to reasonable range
        gracePeriod = bound(gracePeriod, 0, 30 days);

        vm.prank(merchant);
        uint256 planId =
            subManager.createPlan(10 ether, 30 days, address(token), 0, gracePeriod, 0, "Test Plan", "Description");

        (,,,,, uint256 storedGracePeriod,,,,,) = subManager.plans(planId);
        assertEq(storedGracePeriod, gracePeriod, "Grace period not stored correctly");
    }

    /* //////////////////////////////////////////////////////////////
                        PROTOCOL FEE FUZZ TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Fuzz test protocol fee setting within valid range
     * @param feeBps Fee in basis points
     */
    function testFuzz_SetProtocolFee_Valid(uint256 feeBps) public {
        // Bound to valid fee range (0 to 10%)
        feeBps = bound(feeBps, 0, 1000);

        vm.prank(owner);
        subManager.setProtocolFee(feeBps);

        assertEq(subManager.protocolFeeBps(), feeBps, "Fee not set correctly");
    }

    /**
     * @notice Fuzz test protocol fee setting should fail above maximum
     * @param feeBps Fee value above MAX_FEE_BPS
     */
    function testFuzz_SetProtocolFee_Invalid(uint256 feeBps) public {
        // Ensure fee is above maximum (10%)
        feeBps = bound(feeBps, 1001, type(uint256).max);

        vm.prank(owner);
        vm.expectRevert(); // Expect revert for fee too high
        subManager.setProtocolFee(feeBps);
    }

    /* //////////////////////////////////////////////////////////////
                    SUBSCRIPTION FUZZ TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Fuzz test subscription with various subscriber addresses
     * @param subscriberSeed Seed to generate subscriber address
     */
    function testFuzz_Subscribe_DifferentSubscribers(uint256 subscriberSeed) public {
        // Create a random subscriber
        address subscriber = address(uint160(bound(subscriberSeed, 1, type(uint160).max)));
        vm.assume(subscriber != address(0));
        vm.assume(subscriber != merchant);
        vm.assume(subscriber != owner);

        // Create plan
        vm.prank(merchant);
        uint256 planId = subManager.createPlan(10 ether, 30 days, address(token), 0, 0, 0, "Test Plan", "Description");

        // Fund subscriber
        vm.prank(owner);
        token.mint(subscriber, 1000 ether);

        // Grant permission
        vm.startPrank(subscriber);
        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription", isAdjustmentAllowed: true, data: abi.encode(uint256(1000 ether))
        });
        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);
        bytes32 permissionId = permManager.grantPermission(address(subManager), address(subManager), permission, rules);

        // Approve tokens
        token.approve(address(subManager), type(uint256).max);

        // Subscribe
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);
        vm.stopPrank();

        // Verify subscription
        (, address storedSubscriber,,,,,,,,) = subManager.subscriptions(subscriptionId);
        assertEq(storedSubscriber, subscriber, "Subscriber not stored correctly");
    }

    /* //////////////////////////////////////////////////////////////
                    PAYMENT CALCULATION FUZZ TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Fuzz test fee calculation with various amounts
     * @param amount Payment amount
     * @param feeBps Fee basis points
     */
    function testFuzz_FeeCalculation(uint256 amount, uint256 feeBps) public {
        // Bound to reasonable values
        amount = bound(amount, 1 ether, 1_000_000 ether);
        feeBps = bound(feeBps, 0, 1000);

        // Set fee
        vm.prank(owner);
        subManager.setProtocolFee(feeBps);

        // Calculate expected fee
        uint256 expectedFee = (amount * feeBps) / 10_000;
        uint256 expectedMerchantAmount = amount - expectedFee;

        // Verify calculation doesn't overflow
        assertTrue(expectedFee <= amount, "Fee should not exceed amount");
        assertEq(expectedFee + expectedMerchantAmount, amount, "Fee calculation should be correct");
    }

    /* //////////////////////////////////////////////////////////////
                        TIMESTAMP FUZZ TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Fuzz test subscription at various block timestamps
     * @param timestamp Block timestamp
     */
    function testFuzz_Subscribe_DifferentTimestamps(uint256 timestamp) public {
        // Bound timestamp to reasonable future range
        timestamp = bound(timestamp, block.timestamp, block.timestamp + 365 days);

        // Warp to timestamp
        vm.warp(timestamp);

        address subscriber = makeAddr("subscriber");

        // Create plan
        vm.prank(merchant);
        uint256 planId = subManager.createPlan(
            10 ether,
            30 days,
            address(token),
            7 days, // trial period
            0,
            0,
            "Test Plan",
            "Description"
        );

        // Fund subscriber
        vm.prank(owner);
        token.mint(subscriber, 1000 ether);

        // Grant permission and subscribe
        vm.startPrank(subscriber);
        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription", isAdjustmentAllowed: true, data: abi.encode(uint256(1000 ether))
        });
        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);
        bytes32 permissionId = permManager.grantPermission(address(subManager), address(subManager), permission, rules);

        token.approve(address(subManager), type(uint256).max);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);
        vm.stopPrank();

        // Verify timestamps
        (,,, uint256 startTime,,,,,,) = subManager.subscriptions(subscriptionId);
        assertEq(startTime, timestamp, "Start time should match block timestamp");
    }

    /* //////////////////////////////////////////////////////////////
                    MULTIPLE PLANS FUZZ TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Fuzz test creating multiple plans
     * @param planCountInput Number of plans to create
     */
    function testFuzz_CreateMultiplePlans(uint8 planCountInput) public {
        // Bound plan count to reasonable range
        uint256 planCount = bound(uint256(planCountInput), 1, 50);

        for (uint256 i = 0; i < planCount; i++) {
            vm.prank(merchant);
            uint256 planId = subManager.createPlan(
                (i + 1) * 1 ether, 30 days, address(token), 0, 0, 0, string(abi.encodePacked("Plan ", i)), "Description"
            );

            assertEq(planId, i + 1, "Plan ID should be sequential starting from 1");
        }

        assertEq(subManager.planCount(), planCount, "Plan count should match");
    }

    /* //////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Test minimum valid amount
     */
    function test_CreatePlan_MinimumAmount() public {
        vm.prank(merchant);
        uint256 planId = subManager.createPlan(
            1, // 1 wei
            30 days,
            address(token),
            0,
            0,
            0,
            "Minimum Plan",
            "Description"
        );

        (, uint256 amount,,,,,,,,,) = subManager.plans(planId);
        assertEq(amount, 1, "Minimum amount should be accepted");
    }

    /**
     * @notice Test zero amount should fail
     */
    function test_CreatePlan_ZeroAmount_Reverts() public {
        vm.prank(merchant);
        vm.expectRevert(ISubscriptionManager.InvalidAmount.selector);
        subManager.createPlan(
            0, // Zero amount
            30 days,
            address(token),
            0,
            0,
            0,
            "Zero Plan",
            "Description"
        );
    }

    /**
     * @notice Test minimum valid period
     */
    function test_CreatePlan_MinimumPeriod() public {
        vm.prank(merchant);
        uint256 planId = subManager.createPlan(
            10 ether,
            MIN_PERIOD, // 1 hour
            address(token),
            0,
            0,
            0,
            "Minimum Period Plan",
            "Description"
        );

        (,, uint256 period,,,,,,,,) = subManager.plans(planId);
        assertEq(period, MIN_PERIOD, "Minimum period should be accepted");
    }

    /**
     * @notice Test maximum valid period
     */
    function test_CreatePlan_MaximumPeriod() public {
        vm.prank(merchant);
        uint256 planId = subManager.createPlan(
            10 ether,
            MAX_PERIOD, // 365 days
            address(token),
            0,
            0,
            0,
            "Maximum Period Plan",
            "Description"
        );

        (,, uint256 period,,,,,,,,) = subManager.plans(planId);
        assertEq(period, MAX_PERIOD, "Maximum period should be accepted");
    }
}
