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
 * @title SubscriptionIntegrationTest
 * @notice Integration tests for SubscriptionManager ↔ ERC7715PermissionManager interaction
 * @dev Tests the complete workflow and cross-module interactions
 */
contract SubscriptionIntegrationTest is Test {
    SubscriptionManager public subManager;
    ERC7715PermissionManager public permManager;
    MockERC20 public token;

    address public owner;
    address public merchant;
    address public subscriber;
    address public processor;

    uint256 public planId;
    bytes32 public permissionId;
    bytes32 public subscriptionId;

    event PlanCreated(uint256 indexed planId, address indexed merchant, uint256 amount, uint256 period, address token);
    event SubscriptionCreated(
        bytes32 indexed subscriptionId, uint256 indexed planId, address indexed subscriber, uint256 startTime
    );
    event PaymentProcessed(
        bytes32 indexed subscriptionId,
        address indexed subscriber,
        address indexed merchant,
        uint256 amount,
        uint256 paymentNumber
    );

    function setUp() public {
        owner = makeAddr("owner");
        merchant = makeAddr("merchant");
        subscriber = makeAddr("subscriber");
        processor = makeAddr("processor");

        vm.startPrank(owner);

        // Deploy permission manager first
        permManager = new ERC7715PermissionManager();

        // Deploy subscription manager with permission manager
        subManager = new SubscriptionManager(address(permManager));

        // Setup authorizations
        permManager.addAuthorizedExecutor(address(subManager));
        subManager.addProcessor(processor);

        // Deploy and distribute tokens
        token = new MockERC20();
        token.mint(subscriber, 100_000 ether);
        token.mint(merchant, 10_000 ether);

        vm.stopPrank();

        // Give subscriber some ETH for native token tests
        vm.deal(subscriber, 1000 ether);
    }

    /* //////////////////////////////////////////////////////////////
                    COMPLETE WORKFLOW TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Test complete subscription workflow from plan creation to payment processing
     */
    function test_CompleteSubscriptionWorkflow() public {
        // Step 1: Merchant creates plan
        vm.prank(merchant);
        planId = subManager.createPlan(
            10 ether, // 10 tokens per period
            30 days, // Monthly
            address(token), // ERC20 token
            7 days, // 7 day trial
            3 days, // 3 day grace period
            0, // No minimum subscription time
            "Premium Plan",
            "Monthly premium access"
        );
        assertEq(planId, 1, "First plan should have ID 1");

        // Step 2: Subscriber grants permission to SubscriptionManager
        vm.startPrank(subscriber);

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: true,
            data: abi.encode(uint256(1000 ether)) // High spending limit for tests
        });
        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);

        permissionId = permManager.grantPermission(address(subManager), address(subManager), permission, rules);
        assertTrue(permissionId != bytes32(0), "Permission should be granted");

        // Step 3: Subscriber approves tokens for SubscriptionManager
        token.approve(address(subManager), type(uint256).max);

        // Step 4: Subscriber subscribes to the plan
        subscriptionId = subManager.subscribe(planId, permissionId);
        assertTrue(subscriptionId != bytes32(0), "Subscription should be created");
        vm.stopPrank();

        // Verify subscription state
        (
            uint256 storedPlanId,
            address storedSubscriber,
            bytes32 storedPermissionId,
            uint256 startTime,,
            uint256 nextPayment,,,
            bool active,
        ) = subManager.subscriptions(subscriptionId);

        assertEq(storedPlanId, planId, "Plan ID should match");
        assertEq(storedSubscriber, subscriber, "Subscriber should match");
        assertEq(storedPermissionId, permissionId, "Permission ID should match");
        assertEq(startTime, block.timestamp, "Start time should be current");
        assertEq(nextPayment, block.timestamp + 7 days, "Next payment should be after trial");
        assertTrue(active, "Subscription should be active");

        // Step 5: Skip trial period
        vm.warp(block.timestamp + 7 days + 1);

        // Step 6: Process first payment
        uint256 merchantBalanceBefore = token.balanceOf(merchant);
        uint256 subscriberBalanceBefore = token.balanceOf(subscriber);

        vm.prank(processor);
        subManager.processPayment(subscriptionId);

        // Verify payment was processed
        uint256 merchantBalanceAfter = token.balanceOf(merchant);
        uint256 subscriberBalanceAfter = token.balanceOf(subscriber);

        // Calculate expected amounts (considering protocol fee)
        uint256 fee = (10 ether * subManager.protocolFeeBps()) / 10_000;
        uint256 merchantAmount = 10 ether - fee;

        assertEq(
            merchantBalanceAfter - merchantBalanceBefore, merchantAmount, "Merchant should receive payment minus fee"
        );
        assertEq(subscriberBalanceBefore - subscriberBalanceAfter, 10 ether, "Subscriber should pay full amount");
    }

    /**
     * @notice Test permission revocation blocks payment processing
     */
    function test_PermissionRevocation_BlocksPayment() public {
        // Setup: Create plan with grace period so we can test permission revocation properly
        vm.prank(merchant);
        planId = subManager.createPlan(
            10 ether,
            30 days,
            address(token),
            0, // No trial
            3 days, // 3 day grace period
            0,
            "Test Plan",
            "Description"
        );

        // Setup subscription
        vm.startPrank(subscriber);
        token.approve(address(subManager), type(uint256).max);

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription", isAdjustmentAllowed: true, data: abi.encode(uint256(1000 ether))
        });

        permissionId = permManager.grantPermission(
            address(subManager), address(subManager), permission, new IERC7715PermissionManager.Rule[](0)
        );

        subscriptionId = subManager.subscribe(planId, permissionId);
        vm.stopPrank();

        // First payment was processed during subscribe
        // Warp to next payment time (within grace period)
        vm.warp(block.timestamp + 30 days + 1);

        // Revoke permission before payment
        vm.prank(subscriber);
        permManager.revokePermission(permissionId);

        // Attempt to process payment should fail with PaymentFailed (within grace period)
        vm.prank(processor);
        vm.expectRevert(ISubscriptionManager.PaymentFailed.selector);
        subManager.processPayment(subscriptionId);
    }

    /**
     * @notice Test multiple subscriptions with different permissions
     */
    function test_MultipleSubscriptions_SeparatePermissions() public {
        // Create two plans
        vm.startPrank(merchant);
        uint256 planId1 = subManager.createPlan(10 ether, 30 days, address(token), 0, 0, 0, "Basic", "Basic plan");
        uint256 planId2 = subManager.createPlan(50 ether, 30 days, address(token), 0, 0, 0, "Premium", "Premium plan");
        vm.stopPrank();

        // Subscriber creates two separate permissions
        vm.startPrank(subscriber);
        token.approve(address(subManager), type(uint256).max);

        // Permission 1 for basic plan (lower limit)
        IERC7715PermissionManager.Permission memory perm1 = IERC7715PermissionManager.Permission({
            permissionType: "subscription", isAdjustmentAllowed: true, data: abi.encode(uint256(100 ether))
        });
        bytes32 permId1 = permManager.grantPermission(
            address(subManager), address(subManager), perm1, new IERC7715PermissionManager.Rule[](0)
        );

        // Permission 2 for premium plan (higher limit)
        IERC7715PermissionManager.Permission memory perm2 = IERC7715PermissionManager.Permission({
            permissionType: "subscription", isAdjustmentAllowed: true, data: abi.encode(uint256(500 ether))
        });
        bytes32 permId2 = permManager.grantPermission(
            address(subManager), address(subManager), perm2, new IERC7715PermissionManager.Rule[](0)
        );

        // Subscribe to both plans
        bytes32 subId1 = subManager.subscribe(planId1, permId1);
        bytes32 subId2 = subManager.subscribe(planId2, permId2);
        vm.stopPrank();

        // Both subscriptions should be active
        (,,,,,,,, bool active1,) = subManager.subscriptions(subId1);
        (,,,,,,,, bool active2,) = subManager.subscriptions(subId2);

        assertTrue(active1, "First subscription should be active");
        assertTrue(active2, "Second subscription should be active");

        // Verify first payments were already processed during subscribe (since no trial period)
        (,,,,,, uint256 paymentCount1, uint256 totalPaid1,,) = subManager.subscriptions(subId1);
        (,,,,,, uint256 paymentCount2, uint256 totalPaid2,,) = subManager.subscriptions(subId2);

        assertEq(paymentCount1, 1, "First subscription should have 1 payment from subscribe");
        assertEq(paymentCount2, 1, "Second subscription should have 1 payment from subscribe");
        assertEq(totalPaid1, 10 ether, "First subscription total should be 10 ether");
        assertEq(totalPaid2, 50 ether, "Second subscription total should be 50 ether");

        // Warp to next payment period and process second payments
        vm.warp(block.timestamp + 30 days + 1);

        vm.startPrank(processor);
        subManager.processPayment(subId1);
        subManager.processPayment(subId2);
        vm.stopPrank();

        // Verify second payments were processed
        (,,,,,, uint256 paymentCount1After, uint256 totalPaid1After,,) = subManager.subscriptions(subId1);
        (,,,,,, uint256 paymentCount2After, uint256 totalPaid2After,,) = subManager.subscriptions(subId2);

        assertEq(paymentCount1After, 2, "First subscription should have 2 payments");
        assertEq(paymentCount2After, 2, "Second subscription should have 2 payments");
        assertEq(totalPaid1After, 20 ether, "First subscription total should be 20 ether");
        assertEq(totalPaid2After, 100 ether, "Second subscription total should be 100 ether");
    }

    /**
     * @notice Test spending limit exhaustion
     */
    function test_SpendingLimit_Exhaustion() public {
        // Create plan with amount close to spending limit
        vm.prank(merchant);
        planId = subManager.createPlan(
            100 ether, // 100 tokens per period
            1 hours, // Very short period for testing
            address(token),
            0,
            0,
            0,
            "Expensive Plan",
            "Test spending limits"
        );

        // Grant permission with limited spending
        vm.startPrank(subscriber);
        token.approve(address(subManager), type(uint256).max);

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: true,
            data: abi.encode(uint256(250 ether)) // Limit for ~2 payments
        });

        permissionId = permManager.grantPermission(
            address(subManager), address(subManager), permission, new IERC7715PermissionManager.Rule[](0)
        );

        subscriptionId = subManager.subscribe(planId, permissionId);
        vm.stopPrank();

        // First payment was already processed during subscribe (since no trial period)
        // Warp to second payment time
        vm.warp(block.timestamp + 1 hours + 1);

        // Process second payment
        vm.prank(processor);
        subManager.processPayment(subscriptionId);

        // Warp to third payment
        vm.warp(block.timestamp + 1 hours + 1);

        // Process third payment (this should use up most of the limit: 100 + 100 + 100 = 300 > 250)
        // Third payment should fail due to spending limit
        vm.prank(processor);
        vm.expectRevert(); // Should fail due to limit exceeded
        subManager.processPayment(subscriptionId);
    }

    /**
     * @notice Test grace period behavior
     */
    function test_GracePeriod_Behavior() public {
        // Create plan with grace period
        vm.prank(merchant);
        planId = subManager.createPlan(
            10 ether,
            30 days,
            address(token),
            0, // No trial
            3 days, // 3 day grace period
            0,
            "Grace Plan",
            "Test grace period"
        );

        // Setup subscription
        vm.startPrank(subscriber);
        token.approve(address(subManager), type(uint256).max);

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription", isAdjustmentAllowed: true, data: abi.encode(uint256(1000 ether))
        });

        permissionId = permManager.grantPermission(
            address(subManager), address(subManager), permission, new IERC7715PermissionManager.Rule[](0)
        );

        subscriptionId = subManager.subscribe(planId, permissionId);
        vm.stopPrank();

        // First payment was already processed during subscribe (since no trial period)
        // Warp to second payment time (30 days after first payment)
        vm.warp(block.timestamp + 30 days + 1);

        // Process second payment
        vm.prank(processor);
        subManager.processPayment(subscriptionId);

        // Warp past third payment due date but within grace period (30 days + 1 day into grace period)
        vm.warp(block.timestamp + 30 days + 1 days);

        // Payment should still be possible within grace period
        vm.prank(processor);
        subManager.processPayment(subscriptionId);

        // Verify subscription is still active
        (,,,,,,,, bool active,) = subManager.subscriptions(subscriptionId);
        assertTrue(active, "Subscription should still be active within grace period");
    }

    /**
     * @notice Test subscription cancellation workflow
     */
    function test_SubscriptionCancellation_Workflow() public {
        // Setup subscription (first payment is processed during subscribe since no trial)
        _setupBasicSubscription();

        // Subscriber cancels subscription
        vm.prank(subscriber);
        subManager.cancelSubscription(subscriptionId);

        // Verify subscription is cancelled
        (,,,,,,,, bool active,) = subManager.subscriptions(subscriptionId);
        assertFalse(active, "Subscription should be cancelled");

        // Attempt to process payment should fail
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(processor);
        vm.expectRevert(ISubscriptionManager.SubscriptionNotActive.selector);
        subManager.processPayment(subscriptionId);
    }

    /**
     * @notice Test plan deactivation prevents new subscriptions
     */
    function test_PlanDeactivation_BlocksNewSubscriptions() public {
        // Create and deactivate plan
        vm.startPrank(merchant);
        planId = subManager.createPlan(10 ether, 30 days, address(token), 0, 0, 0, "Test Plan", "Description");
        subManager.updatePlan(planId, 10 ether, 30 days, false);
        vm.stopPrank();

        // Setup permission
        vm.startPrank(subscriber);
        token.approve(address(subManager), type(uint256).max);

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription", isAdjustmentAllowed: true, data: abi.encode(uint256(1000 ether))
        });

        permissionId = permManager.grantPermission(
            address(subManager), address(subManager), permission, new IERC7715PermissionManager.Rule[](0)
        );

        // Attempt to subscribe should fail
        vm.expectRevert(ISubscriptionManager.PlanNotActive.selector);
        subManager.subscribe(planId, permissionId);
        vm.stopPrank();
    }

    /**
     * @notice Test permission adjustment (increase spending limit)
     */
    function test_PermissionAdjustment_IncreasedLimit() public {
        // Setup with low limit
        vm.prank(merchant);
        planId = subManager.createPlan(50 ether, 30 days, address(token), 0, 0, 0, "Test Plan", "Description");

        vm.startPrank(subscriber);
        token.approve(address(subManager), type(uint256).max);

        // Initial permission with low limit
        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: true, // Allow adjustments
            data: abi.encode(uint256(60 ether)) // Just over 1 payment
        });

        permissionId = permManager.grantPermission(
            address(subManager), address(subManager), permission, new IERC7715PermissionManager.Rule[](0)
        );

        subscriptionId = subManager.subscribe(planId, permissionId);
        vm.stopPrank();

        // First payment was already processed during subscribe (since no trial period)
        // Warp to second payment time
        vm.warp(block.timestamp + 30 days + 1);

        // Second payment would fail due to low limit...
        // Adjust permission to increase limit before processing
        vm.prank(subscriber);
        permManager.adjustPermission(permissionId, abi.encode(200 ether));

        // Now payment should succeed
        vm.prank(processor);
        subManager.processPayment(subscriptionId);

        (,,,,,, uint256 paymentCount,,,) = subManager.subscriptions(subscriptionId);
        assertEq(paymentCount, 2, "Should have 2 successful payments after adjustment");
    }

    /* //////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    function _setupBasicSubscription() internal {
        // Create plan
        vm.prank(merchant);
        planId = subManager.createPlan(10 ether, 30 days, address(token), 0, 0, 0, "Basic Plan", "Description");

        // Setup subscription
        vm.startPrank(subscriber);
        token.approve(address(subManager), type(uint256).max);

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription", isAdjustmentAllowed: true, data: abi.encode(uint256(1000 ether))
        });

        permissionId = permManager.grantPermission(
            address(subManager), address(subManager), permission, new IERC7715PermissionManager.Rule[](0)
        );

        subscriptionId = subManager.subscribe(planId, permissionId);
        vm.stopPrank();
    }
}
