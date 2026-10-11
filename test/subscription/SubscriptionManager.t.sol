// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SubscriptionManager, ISubscriptionManager } from "../../src/subscription/SubscriptionManager.sol";
import {
    ERC7715PermissionManager,
    IERC7715PermissionManager
} from "../../src/subscription/ERC7715PermissionManager.sol";
import { MerchantRegistry } from "../../src/subscription/MerchantRegistry.sol";
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
        emit PlanCreated(2, merchant, 5 ether, 7 days, address(token));
        uint256 newPlanId =
            subManager.createPlan(5 ether, 7 days, address(token), 0, 1 days, 0, "Basic Plan", "Basic features");

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
        subManager.createPlan(1 ether, 30 minutes, address(token), 0, 0, 0, "Plan", "Desc");
    }

    function test_CreatePlan_RevertsOnInvalidPeriod_TooLong() public {
        vm.prank(merchant);
        vm.expectRevert(ISubscriptionManager.InvalidPeriod.selector);
        subManager.createPlan(1 ether, 400 days, address(token), 0, 0, 0, "Plan", "Desc");
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

    function test_UpdatePlan_DoesNotChangeExistingSubscriptionPeriod() public {
        vm.prank(subscriber);
        token.approve(address(subManager), type(uint256).max);
        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);

        // Merchant shrinks the period after the subscriber agreed to 30 days
        vm.prank(merchant);
        subManager.updatePlan(planId, 0, 1 hours, true);

        // First charge after the 7-day trial
        vm.warp(1 + 7 days);
        vm.prank(processor);
        subManager.processPayment(subscriptionId);

        // One day later the subscription must not be due again
        vm.warp(1 + 8 days);
        vm.prank(processor);
        vm.expectRevert(ISubscriptionManager.NotDueForPayment.selector);
        subManager.processPayment(subscriptionId);

        assertEq(subManager.getSubscription(subscriptionId).nextPayment, 1 + 7 days + 30 days);
    }

    function test_UpdatePlan_DoesNotChangeExistingSubscriptionAmount() public {
        vm.prank(subscriber);
        token.approve(address(subManager), type(uint256).max);
        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);

        // Merchant raises the price 100x after the subscriber agreed to 10 ether
        vm.prank(merchant);
        subManager.updatePlan(planId, 1000 ether, 0, true);

        uint256 balanceBefore = token.balanceOf(subscriber);
        vm.warp(1 + 7 days);
        vm.prank(processor);
        subManager.processPayment(subscriptionId);

        assertEq(balanceBefore - token.balanceOf(subscriber), 10 ether);
        assertEq(subManager.getSubscription(subscriptionId).totalPaid, 10 ether);
    }

    function test_UpdatePlan_AppliesToNewSubscriptions() public {
        vm.prank(merchant);
        subManager.updatePlan(planId, 15 ether, 60 days, true);

        vm.prank(subscriber);
        bytes32 subscriptionId = subManager.subscribe(planId, permissionId);

        (uint256 amount, uint256 period) = subManager.subscriptionTerms(subscriptionId);
        assertEq(amount, 15 ether);
        assertEq(period, 60 days);
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

    /// @dev Subscribe `who` to the default plan (7-day trial, 3-day grace) with its own permission
    function _subscribeAs(address who) internal returns (bytes32 subscriptionId, bytes32 permId) {
        token.mint(who, 1000 ether);
        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription", isAdjustmentAllowed: true, data: abi.encode(uint256(1000 ether))
        });
        vm.startPrank(who);
        token.approve(address(subManager), type(uint256).max);
        permId = permManager.grantPermission(
            address(subManager), address(subManager), permission, new IERC7715PermissionManager.Rule[](0)
        );
        subscriptionId = subManager.subscribe(planId, permId);
        vm.stopPrank();
    }

    function test_ProcessPayment_FailureWithinGracePersistsGraceState() public {
        (bytes32 subscriptionId, bytes32 permId) = _subscribeAs(subscriber);
        vm.prank(subscriber);
        permManager.revokePermission(permId);

        vm.warp(1 + 7 days + 1 hours);
        vm.prank(processor);
        subManager.processPayment(subscriptionId);

        ISubscriptionManager.Subscription memory sub = subManager.getSubscription(subscriptionId);
        assertTrue(sub.inGracePeriod);
        assertTrue(sub.active);
        assertEq(sub.paymentCount, 0);
    }

    function test_ProcessPayment_FailureAfterGraceDeactivatesSubscription() public {
        (bytes32 subscriptionId, bytes32 permId) = _subscribeAs(subscriber);
        vm.prank(subscriber);
        permManager.revokePermission(permId);

        vm.warp(1 + 7 days + 4 days);
        vm.prank(processor);
        subManager.processPayment(subscriptionId);

        assertFalse(subManager.getSubscription(subscriptionId).active);
        assertEq(subManager.getPlan(planId).subscriberCount, 0);
        assertFalse(subManager.isPaymentDue(subscriptionId));
    }

    function test_BatchProcessPayments_SkipsRevokedPermission() public {
        (bytes32 subA, bytes32 permA) = _subscribeAs(makeAddr("alice"));
        (bytes32 subB,) = _subscribeAs(makeAddr("bob"));
        vm.prank(makeAddr("alice"));
        permManager.revokePermission(permA);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = subA;
        ids[1] = subB;
        vm.warp(1 + 7 days);
        vm.prank(processor);
        subManager.batchProcessPayments(ids);

        assertEq(subManager.getSubscription(subB).paymentCount, 1, "bob charged despite alice's revocation");
        assertTrue(subManager.getSubscription(subA).inGracePeriod, "alice's failure recorded");
    }

    function test_BatchProcessPayments_SkipsRevokedTokenApproval() public {
        address alice = makeAddr("alice");
        (bytes32 subA,) = _subscribeAs(alice);
        (bytes32 subB,) = _subscribeAs(makeAddr("bob"));
        vm.prank(alice);
        token.approve(address(subManager), 0);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = subA;
        ids[1] = subB;
        vm.warp(1 + 7 days);
        vm.prank(processor);
        subManager.batchProcessPayments(ids);

        assertEq(subManager.getSubscription(subB).paymentCount, 1);
        assertTrue(subManager.getSubscription(subA).inGracePeriod);
    }

    function test_BatchProcessPayments_SkipsNotDueAndInactive() public {
        (bytes32 subA,) = _subscribeAs(makeAddr("alice"));
        (bytes32 subB,) = _subscribeAs(makeAddr("bob"));
        vm.prank(owner);
        subManager.emergencyCancelSubscription(subA);

        bytes32[] memory ids = new bytes32[](3);
        ids[0] = subA; // inactive
        ids[1] = bytes32(uint256(123)); // unknown
        ids[2] = subB;
        vm.warp(1 + 7 days);
        vm.prank(processor);
        subManager.batchProcessPayments(ids);
        assertEq(subManager.getSubscription(subB).paymentCount, 1);

        // Re-running immediately skips subB as not due instead of reverting
        vm.prank(processor);
        subManager.batchProcessPayments(ids);
        assertEq(subManager.getSubscription(subB).paymentCount, 1);
    }

    function test_ProcessPayment_ExhaustedPermissionLimitRecordsFailure() public {
        // Permission limit below the plan amount: usePermission reverts with InsufficientAllowance
        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription", isAdjustmentAllowed: true, data: abi.encode(uint256(5 ether))
        });
        vm.startPrank(subscriber);
        token.approve(address(subManager), type(uint256).max);
        bytes32 permId = permManager.grantPermission(
            address(subManager), address(subManager), permission, new IERC7715PermissionManager.Rule[](0)
        );
        bytes32 subscriptionId = subManager.subscribe(planId, permId);
        vm.stopPrank();

        vm.warp(1 + 7 days);
        vm.prank(processor);
        subManager.processPayment(subscriptionId);

        assertTrue(subManager.getSubscription(subscriptionId).inGracePeriod);
        assertEq(subManager.getSubscription(subscriptionId).paymentCount, 0);
    }

    function test_ProcessPayment_RevertsWhilePermissionManagerPaused() public {
        (bytes32 subscriptionId,) = _subscribeAs(subscriber);
        vm.prank(owner);
        permManager.setPaused(true);

        uint256 balanceBefore = token.balanceOf(subscriber);
        vm.warp(1 + 7 days + 4 days); // past the grace period
        vm.prank(processor);
        vm.expectRevert(IERC7715PermissionManager.PermissionPaused.selector);
        subManager.processPayment(subscriptionId);

        // The batch also reverts rather than expiring subscriptions because of an operator pause
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = subscriptionId;
        vm.prank(processor);
        vm.expectRevert(IERC7715PermissionManager.PermissionPaused.selector);
        subManager.batchProcessPayments(ids);

        assertEq(token.balanceOf(subscriber), balanceBefore);
        assertTrue(subManager.getSubscription(subscriptionId).active);
    }

    function test_Subscribe_RevertsWhenFirstPaymentFails() public {
        vm.prank(merchant);
        uint256 noTrialPlanId =
            subManager.createPlan(10 ether, 30 days, address(token), 0, 3 days, 0, "No Trial", "Desc");

        // No token approval: the first payment cannot be collected
        vm.prank(subscriber);
        vm.expectRevert(ISubscriptionManager.PaymentFailed.selector);
        subManager.subscribe(noTrialPlanId, permissionId);
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

    /// @dev Cancelling an already inactive subscription must not decrement subscriberCount again
    function test_EmergencyCancelSubscription_RevertsOnInactive() public {
        (bytes32 subA,) = _subscribeAs(makeAddr("alice"));
        _subscribeAs(makeAddr("bob"));
        vm.prank(makeAddr("alice"));
        subManager.cancelSubscription(subA);
        assertEq(subManager.getPlan(planId).subscriberCount, 1);

        vm.prank(owner);
        vm.expectRevert(ISubscriptionManager.SubscriptionNotActive.selector);
        subManager.emergencyCancelSubscription(subA);
        assertEq(subManager.getPlan(planId).subscriberCount, 1);
    }

    function test_EmergencyCancelSubscription_RevertsOnNotFound() public {
        bytes32 fakeId = keccak256("fake");

        vm.prank(owner);
        vm.expectRevert(ISubscriptionManager.SubscriptionNotFound.selector);
        subManager.emergencyCancelSubscription(fakeId);
    }

    // ============ Merchant Registry Tests ============

    /// @dev Deploy a registry, verify the default merchant and wire it into the manager
    function _wireRegistry() internal returns (MerchantRegistry registry) {
        address verifier = makeAddr("verifier");
        vm.startPrank(owner);
        registry = new MerchantRegistry();
        registry.addVerifier(verifier);
        subManager.setMerchantRegistry(address(registry));
        vm.stopPrank();
        vm.prank(merchant);
        registry.registerMerchant("m", "https://m.example", "m@example.com");
        vm.prank(verifier);
        registry.verifyMerchant(merchant);
    }

    function test_SetMerchantRegistry_OnlyOwner() public {
        vm.prank(merchant);
        vm.expectRevert();
        subManager.setMerchantRegistry(address(1));

        vm.prank(owner);
        subManager.setMerchantRegistry(address(1));
        assertEq(address(subManager.merchantRegistry()), address(1));
    }

    function test_MerchantRegistry_SuspendedMerchantIsNotPaid() public {
        MerchantRegistry registry = _wireRegistry();
        (bytes32 subscriptionId,) = _subscribeAs(subscriber);

        vm.prank(owner);
        registry.suspendMerchant(merchant);

        vm.warp(1 + 7 days);
        uint256 merchantBefore = token.balanceOf(merchant);
        vm.prank(processor);
        vm.expectRevert(ISubscriptionManager.UnauthorizedMerchant.selector);
        subManager.processPayment(subscriptionId);

        // The batch skips the suspended merchant's subscription instead of reverting
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = subscriptionId;
        vm.prank(processor);
        subManager.batchProcessPayments(ids);
        assertEq(token.balanceOf(merchant), merchantBefore);
        assertEq(subManager.getSubscription(subscriptionId).paymentCount, 0);
        assertFalse(subManager.getSubscription(subscriptionId).inGracePeriod);

        // Reinstated merchant is paid again
        vm.prank(owner);
        registry.unsuspendMerchant(merchant);
        vm.prank(processor);
        subManager.processPayment(subscriptionId);
        assertEq(subManager.getSubscription(subscriptionId).paymentCount, 1);
    }

    function test_MerchantRegistry_SuspendedMerchantCannotCreatePlanOrGainSubscribers() public {
        MerchantRegistry registry = _wireRegistry();
        vm.prank(owner);
        registry.suspendMerchant(merchant);

        vm.prank(merchant);
        vm.expectRevert(ISubscriptionManager.UnauthorizedMerchant.selector);
        subManager.createPlan(1 ether, 30 days, address(token), 0, 0, 0, "p2", "d2");

        vm.prank(subscriber);
        vm.expectRevert(ISubscriptionManager.UnauthorizedMerchant.selector);
        subManager.subscribe(planId, permissionId);
    }

    function test_MerchantRegistry_UnverifiedMerchantCannotCreatePlan() public {
        _wireRegistry();
        vm.prank(makeAddr("unverified"));
        vm.expectRevert(ISubscriptionManager.UnauthorizedMerchant.selector);
        subManager.createPlan(1 ether, 30 days, address(token), 0, 0, 0, "p", "d");
    }
}
