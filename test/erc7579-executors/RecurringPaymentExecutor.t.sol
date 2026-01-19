// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RecurringPaymentExecutor} from "../../src/erc7579-executors/RecurringPaymentExecutor.sol";
import {MockSmartAccount} from "./mocks/MockSmartAccount.sol";
import {MockERC20} from "../erc4337-paymaster/mocks/MockERC20.sol";
import {MODULE_TYPE_EXECUTOR} from "../../src/erc7579-smartaccount/types/Constants.sol";

contract RecurringPaymentExecutorTest is Test {
    RecurringPaymentExecutor public executor;
    MockSmartAccount public smartAccount;
    MockERC20 public token;

    address public owner;
    address public recipient;

    uint256 constant PAYMENT_AMOUNT = 100e18;
    uint256 constant INTERVAL = 1 days;

    function setUp() public {
        owner = makeAddr("owner");
        recipient = makeAddr("recipient");

        // Deploy contracts
        executor = new RecurringPaymentExecutor();
        smartAccount = new MockSmartAccount(owner);
        token = new MockERC20("Test Token", "TEST", 18);

        // Fund smart account
        vm.deal(address(smartAccount), 100 ether);
        token.mint(address(smartAccount), 1_000_000e18);

        // Approve executor to spend tokens (needed for token transfers)
        vm.prank(address(smartAccount));
        token.approve(address(token), type(uint256).max);

        // Install executor
        vm.prank(address(smartAccount));
        smartAccount.installModule(MODULE_TYPE_EXECUTOR, address(executor), "");
    }

    function test_onInstall_withData() public {
        RecurringPaymentExecutor newExecutor = new RecurringPaymentExecutor();
        MockSmartAccount newAccount = new MockSmartAccount(owner);
        vm.deal(address(newAccount), 100 ether);

        // Install executor to register it first
        vm.prank(address(newAccount));
        newAccount.installModule(MODULE_TYPE_EXECUTOR, address(newExecutor), "");

        bytes memory installData = abi.encode(
            recipient,
            address(0), // ETH
            PAYMENT_AMOUNT,
            INTERVAL,
            uint256(0), // startTime = now
            uint256(12) // maxPayments
        );

        vm.prank(address(newAccount));
        newExecutor.onInstall(installData);

        RecurringPaymentExecutor.PaymentSchedule memory schedule = newExecutor.getSchedule(address(newAccount), 0);
        assertTrue(schedule.isActive);
        assertEq(schedule.recipient, recipient);
        assertEq(schedule.amount, PAYMENT_AMOUNT);
        assertEq(schedule.interval, INTERVAL);
        assertEq(schedule.maxPayments, 12);
    }

    function test_createSchedule_ETH() public {
        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(
            recipient,
            address(0), // ETH
            1 ether,
            INTERVAL,
            block.timestamp,
            0 // unlimited
        );

        RecurringPaymentExecutor.PaymentSchedule memory schedule = executor.getSchedule(address(smartAccount), scheduleId);
        assertTrue(schedule.isActive);
        assertEq(schedule.recipient, recipient);
        assertEq(schedule.token, address(0));
        assertEq(schedule.amount, 1 ether);
        assertEq(schedule.interval, INTERVAL);
        assertEq(schedule.maxPayments, 0);
    }

    function test_createSchedule_ERC20() public {
        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(
            recipient,
            address(token),
            PAYMENT_AMOUNT,
            INTERVAL,
            block.timestamp,
            10
        );

        RecurringPaymentExecutor.PaymentSchedule memory schedule = executor.getSchedule(address(smartAccount), scheduleId);
        assertTrue(schedule.isActive);
        assertEq(schedule.token, address(token));
        assertEq(schedule.amount, PAYMENT_AMOUNT);
        assertEq(schedule.maxPayments, 10);
    }

    function test_createSchedule_revertIfInvalidRecipient() public {
        vm.prank(address(smartAccount));
        vm.expectRevert(RecurringPaymentExecutor.InvalidRecipient.selector);
        executor.createSchedule(address(0), address(0), 1 ether, INTERVAL, 0, 0);
    }

    function test_createSchedule_revertIfInvalidAmount() public {
        vm.prank(address(smartAccount));
        vm.expectRevert(RecurringPaymentExecutor.InvalidAmount.selector);
        executor.createSchedule(recipient, address(0), 0, INTERVAL, 0, 0);
    }

    function test_createSchedule_revertIfInvalidInterval() public {
        vm.prank(address(smartAccount));
        vm.expectRevert(RecurringPaymentExecutor.InvalidInterval.selector);
        executor.createSchedule(recipient, address(0), 1 ether, 0, 0, 0);
    }

    function test_cancelSchedule() public {
        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, 0, 0);

        vm.prank(address(smartAccount));
        executor.cancelSchedule(scheduleId);

        RecurringPaymentExecutor.PaymentSchedule memory schedule = executor.getSchedule(address(smartAccount), scheduleId);
        assertFalse(schedule.isActive);
    }

    function test_cancelSchedule_revertIfNotActive() public {
        vm.prank(address(smartAccount));
        vm.expectRevert(RecurringPaymentExecutor.ScheduleNotActive.selector);
        executor.cancelSchedule(999);
    }

    function test_updateAmount() public {
        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, 0, 0);

        vm.prank(address(smartAccount));
        executor.updateAmount(scheduleId, 2 ether);

        RecurringPaymentExecutor.PaymentSchedule memory schedule = executor.getSchedule(address(smartAccount), scheduleId);
        assertEq(schedule.amount, 2 ether);
    }

    function test_updateRecipient() public {
        address newRecipient = makeAddr("newRecipient");

        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, 0, 0);

        vm.prank(address(smartAccount));
        executor.updateRecipient(scheduleId, newRecipient);

        RecurringPaymentExecutor.PaymentSchedule memory schedule = executor.getSchedule(address(smartAccount), scheduleId);
        assertEq(schedule.recipient, newRecipient);
    }

    function test_executePayment_ETH() public {
        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, block.timestamp, 0);

        uint256 balanceBefore = recipient.balance;

        // Anyone can execute when payment is due
        executor.executePayment(address(smartAccount), scheduleId);

        assertEq(recipient.balance, balanceBefore + 1 ether);

        RecurringPaymentExecutor.PaymentSchedule memory schedule = executor.getSchedule(address(smartAccount), scheduleId);
        assertEq(schedule.paymentsMade, 1);
    }

    function test_executePayment_revertIfNotDue() public {
        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, block.timestamp, 0);

        // Execute first payment
        executor.executePayment(address(smartAccount), scheduleId);

        // Try to execute again immediately
        vm.expectRevert(RecurringPaymentExecutor.PaymentNotDue.selector);
        executor.executePayment(address(smartAccount), scheduleId);
    }

    function test_executePayment_multiplePayments() public {
        uint256 startTime = block.timestamp;

        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, startTime, 0);

        uint256 balanceBefore = recipient.balance;

        // Execute first payment
        executor.executePayment(address(smartAccount), scheduleId);
        assertEq(recipient.balance, balanceBefore + 1 ether);

        // Warp time and execute second payment
        vm.warp(startTime + INTERVAL);
        executor.executePayment(address(smartAccount), scheduleId);
        assertEq(recipient.balance, balanceBefore + 2 ether);

        // Warp time and execute third payment
        vm.warp(startTime + 2 * INTERVAL);
        executor.executePayment(address(smartAccount), scheduleId);
        assertEq(recipient.balance, balanceBefore + 3 ether);

        RecurringPaymentExecutor.PaymentSchedule memory schedule = executor.getSchedule(address(smartAccount), scheduleId);
        assertEq(schedule.paymentsMade, 3);
    }

    function test_executePayment_maxPaymentsReached() public {
        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, block.timestamp, 2);

        // Execute first payment
        executor.executePayment(address(smartAccount), scheduleId);

        // Execute second payment
        vm.warp(block.timestamp + INTERVAL);
        executor.executePayment(address(smartAccount), scheduleId);

        // Schedule should be completed
        RecurringPaymentExecutor.PaymentSchedule memory schedule = executor.getSchedule(address(smartAccount), scheduleId);
        assertFalse(schedule.isActive);
        assertEq(schedule.paymentsMade, 2);

        // Try to execute third payment
        vm.warp(block.timestamp + INTERVAL);
        vm.expectRevert(RecurringPaymentExecutor.ScheduleNotActive.selector);
        executor.executePayment(address(smartAccount), scheduleId);
    }

    function test_isPaymentDue() public {
        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, block.timestamp, 0);

        assertTrue(executor.isPaymentDue(address(smartAccount), scheduleId));

        executor.executePayment(address(smartAccount), scheduleId);
        assertFalse(executor.isPaymentDue(address(smartAccount), scheduleId));

        vm.warp(block.timestamp + INTERVAL);
        assertTrue(executor.isPaymentDue(address(smartAccount), scheduleId));
    }

    function test_getNextPaymentTime() public {
        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, block.timestamp, 0);

        assertEq(executor.getNextPaymentTime(address(smartAccount), scheduleId), block.timestamp);

        executor.executePayment(address(smartAccount), scheduleId);
        uint256 expectedNext = block.timestamp + INTERVAL;
        assertEq(executor.getNextPaymentTime(address(smartAccount), scheduleId), expectedNext);
    }

    function test_getRemainingPayments() public {
        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, block.timestamp, 5);

        assertEq(executor.getRemainingPayments(address(smartAccount), scheduleId), 5);

        executor.executePayment(address(smartAccount), scheduleId);
        assertEq(executor.getRemainingPayments(address(smartAccount), scheduleId), 4);
    }

    function test_getRemainingPayments_unlimited() public {
        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, block.timestamp, 0);

        assertEq(executor.getRemainingPayments(address(smartAccount), scheduleId), type(uint256).max);
    }

    function test_getTotalRemainingValue() public {
        vm.prank(address(smartAccount));
        uint256 scheduleId = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, block.timestamp, 5);

        assertEq(executor.getTotalRemainingValue(address(smartAccount), scheduleId), 5 ether);

        executor.executePayment(address(smartAccount), scheduleId);
        assertEq(executor.getTotalRemainingValue(address(smartAccount), scheduleId), 4 ether);
    }

    function test_getActiveSchedules() public {
        vm.startPrank(address(smartAccount));
        uint256 scheduleId1 = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, 0, 0);
        uint256 scheduleId2 = executor.createSchedule(recipient, address(0), 2 ether, INTERVAL, 0, 0);
        vm.stopPrank();

        uint256[] memory schedules = executor.getActiveSchedules(address(smartAccount));
        assertEq(schedules.length, 2);
        assertEq(schedules[0], scheduleId1);
        assertEq(schedules[1], scheduleId2);
    }

    function test_executePaymentBatch() public {
        vm.startPrank(address(smartAccount));
        uint256 scheduleId1 = executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, block.timestamp, 0);
        uint256 scheduleId2 = executor.createSchedule(recipient, address(0), 2 ether, INTERVAL, block.timestamp, 0);
        vm.stopPrank();

        uint256[] memory scheduleIds = new uint256[](2);
        scheduleIds[0] = scheduleId1;
        scheduleIds[1] = scheduleId2;

        uint256 balanceBefore = recipient.balance;

        uint256 successCount = executor.executePaymentBatch(address(smartAccount), scheduleIds);
        assertEq(successCount, 2);
        assertEq(recipient.balance, balanceBefore + 3 ether);
    }

    function test_isModuleType() public view {
        assertTrue(executor.isModuleType(MODULE_TYPE_EXECUTOR));
        assertFalse(executor.isModuleType(1)); // VALIDATOR type
    }

    function test_isInitialized() public {
        assertFalse(executor.isInitialized(address(smartAccount)));

        vm.prank(address(smartAccount));
        executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, 0, 0);

        assertTrue(executor.isInitialized(address(smartAccount)));
    }

    function test_onUninstall() public {
        vm.prank(address(smartAccount));
        executor.createSchedule(recipient, address(0), 1 ether, INTERVAL, 0, 0);

        vm.prank(address(smartAccount));
        executor.onUninstall("");

        uint256[] memory schedules = executor.getActiveSchedules(address(smartAccount));
        assertEq(schedules.length, 0);
    }

    function test_intervalConstants() public view {
        assertEq(executor.INTERVAL_DAILY(), 1 days);
        assertEq(executor.INTERVAL_WEEKLY(), 7 days);
        assertEq(executor.INTERVAL_MONTHLY(), 30 days);
        assertEq(executor.INTERVAL_YEARLY(), 365 days);
    }
}
