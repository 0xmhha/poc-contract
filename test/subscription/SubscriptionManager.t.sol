// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SubscriptionManager, ISubscriptionManager } from "../../src/subscription/SubscriptionManager.sol";
import {
    ERC7715PermissionManager,
    IERC7715PermissionManager
} from "../../src/subscription/ERC7715PermissionManager.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SubscriptionManagerTest is Test {
    SubscriptionManager public subManager;
    ERC7715PermissionManager public permManager;
    MockERC20 public token;

    address public owner;
    address public merchant;
    address public subscriber;
    address public processor;

    bytes32 public permissionId;
    uint256 public planId;

    event PlanCreated(uint256 indexed planId, address indexed merchant, uint256 amount, uint256 period, address token);
    event SubscriptionCreated(
        bytes32 indexed subscriptionId, uint256 indexed planId, address indexed subscriber, uint256 startTime
    );
    event SubscriptionCancelled(bytes32 indexed subscriptionId, address indexed subscriber, uint256 cancelTime);
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
        permManager = new ERC7715PermissionManager();
        subManager = new SubscriptionManager(address(permManager));

        // Setup authorization
        permManager.addAuthorizedExecutor(address(subManager));
        subManager.addProcessor(processor);

        token = new MockERC20();
        token.mint(subscriber, 10_000 ether);
        vm.stopPrank();

        vm.deal(subscriber, 100 ether);

        // Create a default plan
        vm.prank(merchant);
        planId = subManager.createPlan(
            10 ether, // amount
            30 days, // period
            address(token), // token
            7 days, // trial period
            3 days, // grace period
            0, // min subscription time
            "Premium Plan",
            "Access to all features"
        );

        // Grant permission for subscriber
        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: true,
            data: abi.encode(uint256(1000 ether)) // Large spending limit
        });
        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);

        vm.prank(subscriber);
        permissionId = permManager.grantPermission(address(subManager), address(subManager), permission, rules);
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertEq(address(subManager.PERMISSION_MANAGER()), address(permManager));
        assertEq(subManager.owner(), owner);
        assertEq(subManager.feeRecipient(), owner);
        assertEq(subManager.protocolFeeBps(), 50); // 0.5%
    }

    // ============ CreatePlan Tests ============

    function test_CreatePlan_Success() public {
        vm.prank(merchant);
        vm.expectEmit(true, true, false, true);
        emit PlanCreated(2, merchant, 5 ether, 7 days, address(0));
        uint256 newPlanId =
            subManager.createPlan(5 ether, 7 days, address(0), 0, 1 days, 0, "Basic Plan", "Basic features");

        assertEq(newPlanId, 2);

        ISubscriptionManager.Plan memory plan = subManager.getPlan(newPlanId);
        assertEq(plan.merchant, merchant);
        assertEq(plan.amount, 5 ether);
        assertEq(plan.period, 7 days);
        assertTrue(plan.active);
    }

    function test_CreatePlan_RevertsOnZeroAmount() public {
        vm.prank(merchant);
        vm.expectRevert(ISubscriptionManager.InvalidAmount.selector);
        subManager.createPlan(0, 7 days, address(0), 0, 0, 0, "Plan", "Desc");
    }

    function test_CreatePlan_RevertsOnInvalidPeriod_TooShort() public {
        vm.prank(merchant);
        vm.expectRevert(ISubscriptionManager.InvalidPeriod.selector);
        subManager.createPlan(1 ether, 30 minutes, address(0), 0, 0, 0, "Plan", "Desc");
    }

    function test_CreatePlan_RevertsOnInvalidPeriod_TooLong() public {
        vm.prank(merchant);
        vm.expectRevert(ISubscriptionManager.InvalidPeriod.selector);
        subManager.createPlan(1 ether, 400 days, address(0), 0, 0, 0, "Plan", "Desc");
    }

    // ============ UpdatePlan Tests ============

    function test_UpdatePlan_Success() public {
        vm.prank(merchant);
        subManager.updatePlan(planId, 15 ether, 60 days, true);

        ISubscriptionManager.Plan memory plan = subManager.getPlan(planId);
        assertEq(plan.amount, 15 ether);
        assertEq(plan.period, 60 days);
    }

    function test_UpdatePlan_Deactivate() public {
        vm.prank(merchant);
        subManager.updatePlan(planId, 0, 0, false);

        ISubscriptionManager.Plan memory plan = subManager.getPlan(planId);
        assertFalse(plan.active);
    }

    function test_UpdatePlan_RevertsOnUnauthorized() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(ISubscriptionManager.UnauthorizedMerchant.selector);
        subManager.updatePlan(planId, 15 ether, 60 days, true);
    }

    function test_UpdatePlan_RevertsOnInvalidPlan() public {
        vm.prank(merchant);
        vm.expectRevert(ISubscriptionManager.InvalidPlan.selector);
        subManager.updatePlan(999, 15 ether, 60 days, true);
    }

    // ============ Subscribe Tests ============

    function test_Subscribe_Success() public {
        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);

        ISubscriptionManager.Subscription memory sub = subManager.getSubscription(subscriptionId);
        assertEq(sub.planId, planId);
        assertEq(sub.subscriber, subscriber);
        assertTrue(sub.active);
        assertEq(sub.paymentCount, 0); // No payment yet (trial period)
    }

    function test_Subscribe_WithoutTrialPeriod() public {
        // Create plan without trial
        vm.prank(merchant);
        uint256 noTrialPlanId =
            subManager.createPlan(10 ether, 30 days, address(token), 0, 3 days, 0, "No Trial", "Desc");

        // Approve token transfer
        vm.prank(subscriber);
        token.approve(address(subManager), 1000 ether);

        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(noTrialPlanId, permissionId);

        ISubscriptionManager.Subscription memory sub = subManager.getSubscription(subscriptionId);
        assertEq(sub.paymentCount, 1); // First payment processed
    }

    function test_Subscribe_RevertsOnInvalidPlan() public {
        vm.prank(subscriber);
        vm.expectRevert(ISubscriptionManager.InvalidPlan.selector);
        subManager.subscribe(999, permissionId);
    }

    function test_Subscribe_RevertsOnInactivePlan() public {
        vm.prank(merchant);
        subManager.updatePlan(planId, 0, 0, false);

        vm.prank(subscriber);
        vm.expectRevert(ISubscriptionManager.PlanNotActive.selector);
        subManager.subscribe(planId, permissionId);
    }

    function test_Subscribe_RevertsOnInvalidPermission() public {
        bytes32 invalidPermissionId = keccak256("invalid");

        vm.prank(subscriber);
        vm.expectRevert(ISubscriptionManager.PermissionNotGranted.selector);
        subManager.subscribe(planId, invalidPermissionId);
    }

    // ============ CancelSubscription Tests ============

    function test_CancelSubscription_Success() public {
        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);

        vm.prank(subscriber);
        vm.expectEmit(true, true, false, true);
        emit SubscriptionCancelled(subscriptionId, subscriber, block.timestamp);
        subManager.cancelSubscription(subscriptionId);

        ISubscriptionManager.Subscription memory sub = subManager.getSubscription(subscriptionId);
        assertFalse(sub.active);
    }

    function test_CancelSubscription_RevertsOnMinSubscriptionTime() public {
        // Create plan with min subscription time
        vm.prank(merchant);
        uint256 minTimePlanId = subManager.createPlan(
            10 ether, 30 days, address(token), 7 days, 3 days, 30 days, "Min Time Plan", "Desc"
        );

        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(minTimePlanId, permissionId);

        vm.prank(subscriber);
        vm.expectRevert(ISubscriptionManager.CancellationPeriodNotMet.selector);
        subManager.cancelSubscription(subscriptionId);
    }

    function test_CancelSubscription_SucceedsAfterMinTime() public {
        // Create plan with min subscription time
        vm.prank(merchant);
        uint256 minTimePlanId = subManager.createPlan(
            10 ether, 30 days, address(token), 7 days, 3 days, 30 days, "Min Time Plan", "Desc"
        );

        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(minTimePlanId, permissionId);

        // Move past min subscription time
        vm.warp(block.timestamp + 31 days);

        vm.prank(subscriber);
        subManager.cancelSubscription(subscriptionId);

        ISubscriptionManager.Subscription memory sub = subManager.getSubscription(subscriptionId);
        assertFalse(sub.active);
    }

    function test_CancelSubscription_RevertsOnNotFound() public {
        bytes32 fakeId = keccak256("fake");

        vm.prank(subscriber);
        vm.expectRevert(ISubscriptionManager.SubscriptionNotFound.selector);
        subManager.cancelSubscription(fakeId);
    }

    function test_CancelSubscription_RevertsOnUnauthorized() public {
        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(ISubscriptionManager.UnauthorizedMerchant.selector);
        subManager.cancelSubscription(subscriptionId);
    }

    // ============ ProcessPayment Tests ============

    function test_ProcessPayment_Success() public {
        // Create plan without trial
        vm.prank(merchant);
        uint256 noTrialPlanId =
            subManager.createPlan(10 ether, 30 days, address(token), 0, 3 days, 0, "No Trial", "Desc");

        vm.prank(subscriber);
        token.approve(address(subManager), 1000 ether);

        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(noTrialPlanId, permissionId);

        // Move to next payment period
        vm.warp(block.timestamp + 31 days);

        vm.prank(processor);
        subManager.processPayment(subscriptionId);

        ISubscriptionManager.Subscription memory sub = subManager.getSubscription(subscriptionId);
        assertEq(sub.paymentCount, 2);
    }

    function test_ProcessPayment_RevertsOnNotDue() public {
        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);

        vm.prank(processor);
        vm.expectRevert(ISubscriptionManager.NotDueForPayment.selector);
        subManager.processPayment(subscriptionId);
    }

    function test_ProcessPayment_RevertsOnUnauthorized() public {
        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);

        vm.warp(block.timestamp + 8 days);

        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(ISubscriptionManager.UnauthorizedMerchant.selector);
        subManager.processPayment(subscriptionId);
    }

    // ============ View Function Tests ============

    function test_GetSubscriberSubscriptions() public {
        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);

        bytes32[] memory subs = subManager.getSubscriberSubscriptions(subscriber);
        assertEq(subs.length, 1);
        assertEq(subs[0], subscriptionId);
    }

    function test_GetMerchantPlans() public view {
        uint256[] memory plans = subManager.getMerchantPlans(merchant);
        assertEq(plans.length, 1);
        assertEq(plans[0], planId);
    }

    function test_IsPaymentDue() public {
        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);

        assertFalse(subManager.isPaymentDue(subscriptionId));

        // Move past trial + payment period
        vm.warp(block.timestamp + 8 days);

        assertTrue(subManager.isPaymentDue(subscriptionId));
    }

    function test_DaysUntilNextPayment() public {
        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);

        int256 days_ = subManager.daysUntilNextPayment(subscriptionId);
        assertEq(days_, 7); // 7 day trial

        // Move past due date
        vm.warp(block.timestamp + 10 days);

        days_ = subManager.daysUntilNextPayment(subscriptionId);
        assertTrue(days_ < 0); // Overdue
    }

    function test_GetDueSubscriptions() public {
        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = subscriptionId;

        bytes32[] memory dueIds = subManager.getDueSubscriptions(ids);
        assertEq(dueIds.length, 0); // Not due yet

        vm.warp(block.timestamp + 8 days);

        dueIds = subManager.getDueSubscriptions(ids);
        assertEq(dueIds.length, 1);
    }

    // ============ Admin Function Tests ============

    function test_AddProcessor() public {
        address newProcessor = makeAddr("newProcessor");

        vm.prank(owner);
        subManager.addProcessor(newProcessor);

        assertTrue(subManager.authorizedProcessors(newProcessor));
    }

    function test_RemoveProcessor() public {
        vm.prank(owner);
        subManager.removeProcessor(processor);

        assertFalse(subManager.authorizedProcessors(processor));
    }

    function test_SetProtocolFee() public {
        vm.prank(owner);
        subManager.setProtocolFee(100); //1%

        assertEq(subManager.protocolFeeBps(), 100);
    }

    function test_SetProtocolFee_RevertsOnTooHigh() public {
        vm.prank(owner);
        vm.expectRevert("Fee too high");
        subManager.setProtocolFee(1001); // > 10%
    }

    function test_SetFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");

        vm.prank(owner);
        subManager.setFeeRecipient(newRecipient);

        assertEq(subManager.feeRecipient(), newRecipient);
    }

    function test_SetFeeRecipient_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Invalid recipient");
        subManager.setFeeRecipient(address(0));
    }

    function test_EmergencyCancelSubscription() public {
        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);

        vm.prank(owner);
        subManager.emergencyCancelSubscription(subscriptionId);

        ISubscriptionManager.Subscription memory sub = subManager.getSubscription(subscriptionId);
        assertFalse(sub.active);
    }

    function test_EmergencyCancelSubscription_RevertsOnNotFound() public {
        bytes32 fakeId = keccak256("fake");

        vm.prank(owner);
        vm.expectRevert(ISubscriptionManager.SubscriptionNotFound.selector);
        subManager.emergencyCancelSubscription(fakeId);
    }
}
