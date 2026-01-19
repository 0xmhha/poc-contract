// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IExecutor, IModule} from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import {IERC7579Account} from "../erc7579-smartaccount/interfaces/IERC7579Account.sol";
import {MODULE_TYPE_EXECUTOR} from "../erc7579-smartaccount/types/Constants.sol";
import {ExecMode} from "../erc7579-smartaccount/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RecurringPaymentExecutor
 * @notice ERC-7579 Executor module for automated recurring payments
 * @dev Enables smart accounts to set up subscription-like payments
 *
 * Features:
 * - Support for ETH and ERC-20 token payments
 * - Configurable payment intervals (daily, weekly, monthly, custom)
 * - Maximum payment count limits
 * - Anyone can trigger execution when payment is due
 * - Cancellation by account owner
 *
 * Use Cases:
 * - Subscription services (SaaS, streaming)
 * - Salary payments
 * - Recurring donations
 * - Rent/lease payments
 */
contract RecurringPaymentExecutor is IExecutor {
    /// @notice Payment schedule configuration
    struct PaymentSchedule {
        address recipient;
        address token;           // address(0) for ETH
        uint256 amount;
        uint256 interval;        // Seconds between payments
        uint256 startTime;
        uint256 lastPaymentTime;
        uint256 maxPayments;     // 0 = unlimited
        uint256 paymentsMade;
        bool isActive;
    }

    /// @notice Storage for each smart account
    struct AccountStorage {
        mapping(uint256 scheduleId => PaymentSchedule) schedules;
        uint256 nextScheduleId;
        uint256[] activeScheduleIds;
    }

    /// @notice Account address => AccountStorage
    mapping(address => AccountStorage) internal accountStorage;

    // Common intervals
    uint256 public constant INTERVAL_DAILY = 1 days;
    uint256 public constant INTERVAL_WEEKLY = 7 days;
    uint256 public constant INTERVAL_MONTHLY = 30 days;
    uint256 public constant INTERVAL_YEARLY = 365 days;

    // Events
    event PaymentScheduleCreated(
        address indexed account,
        uint256 indexed scheduleId,
        address recipient,
        address token,
        uint256 amount,
        uint256 interval
    );
    event PaymentScheduleCancelled(address indexed account, uint256 indexed scheduleId);
    event PaymentExecuted(
        address indexed account,
        uint256 indexed scheduleId,
        address recipient,
        address token,
        uint256 amount,
        uint256 paymentNumber
    );
    event PaymentScheduleCompleted(address indexed account, uint256 indexed scheduleId);

    // Errors
    error ScheduleNotFound();
    error ScheduleNotActive();
    error PaymentNotDue();
    error MaxPaymentsReached();
    error InvalidRecipient();
    error InvalidAmount();
    error InvalidInterval();
    error PaymentFailed();

    // ============ IModule Implementation ============

    /// @inheritdoc IModule
    function onInstall(bytes calldata data) external payable override {
        if (data.length == 0) return;

        // Decode initial payment schedule
        (
            address recipient,
            address token,
            uint256 amount,
            uint256 interval,
            uint256 startTime,
            uint256 maxPayments
        ) = abi.decode(data, (address, address, uint256, uint256, uint256, uint256));

        _createSchedule(
            msg.sender,
            recipient,
            token,
            amount,
            interval,
            startTime,
            maxPayments
        );
    }

    /// @inheritdoc IModule
    function onUninstall(bytes calldata) external payable override {
        AccountStorage storage store = accountStorage[msg.sender];

        // Cancel all schedules
        uint256[] memory ids = store.activeScheduleIds;
        for (uint256 i = 0; i < ids.length; i++) {
            store.schedules[ids[i]].isActive = false;
        }
        delete store.activeScheduleIds;
    }

    /// @inheritdoc IModule
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    /// @inheritdoc IModule
    function isInitialized(address smartAccount) external view override returns (bool) {
        return accountStorage[smartAccount].nextScheduleId > 0;
    }

    // ============ Schedule Management ============

    /**
     * @notice Create a new recurring payment schedule
     * @param recipient Payment recipient address
     * @param token Token address (address(0) for ETH)
     * @param amount Payment amount per interval
     * @param interval Time between payments in seconds
     * @param startTime When payments can start (0 = now)
     * @param maxPayments Maximum number of payments (0 = unlimited)
     * @return scheduleId The ID of the created schedule
     */
    function createSchedule(
        address recipient,
        address token,
        uint256 amount,
        uint256 interval,
        uint256 startTime,
        uint256 maxPayments
    ) external returns (uint256 scheduleId) {
        return _createSchedule(
            msg.sender,
            recipient,
            token,
            amount,
            interval,
            startTime,
            maxPayments
        );
    }

    /**
     * @notice Cancel a payment schedule
     * @param scheduleId The schedule ID to cancel
     */
    function cancelSchedule(uint256 scheduleId) external {
        AccountStorage storage store = accountStorage[msg.sender];
        PaymentSchedule storage schedule = store.schedules[scheduleId];

        if (!schedule.isActive) revert ScheduleNotActive();

        schedule.isActive = false;
        _removeFromActiveList(msg.sender, scheduleId);

        emit PaymentScheduleCancelled(msg.sender, scheduleId);
    }

    /**
     * @notice Update payment amount for a schedule
     * @param scheduleId The schedule ID
     * @param newAmount The new payment amount
     */
    function updateAmount(uint256 scheduleId, uint256 newAmount) external {
        if (newAmount == 0) revert InvalidAmount();

        AccountStorage storage store = accountStorage[msg.sender];
        PaymentSchedule storage schedule = store.schedules[scheduleId];

        if (!schedule.isActive) revert ScheduleNotActive();

        schedule.amount = newAmount;
    }

    /**
     * @notice Update recipient for a schedule
     * @param scheduleId The schedule ID
     * @param newRecipient The new recipient address
     */
    function updateRecipient(uint256 scheduleId, address newRecipient) external {
        if (newRecipient == address(0)) revert InvalidRecipient();

        AccountStorage storage store = accountStorage[msg.sender];
        PaymentSchedule storage schedule = store.schedules[scheduleId];

        if (!schedule.isActive) revert ScheduleNotActive();

        schedule.recipient = newRecipient;
    }

    // ============ Execution ============

    /**
     * @notice Execute a due payment (callable by anyone)
     * @param account The smart account
     * @param scheduleId The schedule ID to execute
     */
    function executePayment(address account, uint256 scheduleId) external returns (bytes[] memory) {
        AccountStorage storage store = accountStorage[account];
        PaymentSchedule storage schedule = store.schedules[scheduleId];

        // Validate schedule
        if (!schedule.isActive) revert ScheduleNotActive();
        if (schedule.maxPayments > 0 && schedule.paymentsMade >= schedule.maxPayments) {
            revert MaxPaymentsReached();
        }

        // Check if payment is due
        uint256 nextPaymentTime = schedule.lastPaymentTime == 0
            ? schedule.startTime
            : schedule.lastPaymentTime + schedule.interval;

        if (block.timestamp < nextPaymentTime) revert PaymentNotDue();

        // Update schedule state
        schedule.lastPaymentTime = block.timestamp;
        schedule.paymentsMade++;

        // Execute payment
        bytes[] memory result;
        if (schedule.token == address(0)) {
            // ETH payment
            result = _executeETHPayment(account, schedule.recipient, schedule.amount);
        } else {
            // ERC-20 payment
            result = _executeTokenPayment(account, schedule.token, schedule.recipient, schedule.amount);
        }

        emit PaymentExecuted(
            account,
            scheduleId,
            schedule.recipient,
            schedule.token,
            schedule.amount,
            schedule.paymentsMade
        );

        // Check if schedule is complete
        if (schedule.maxPayments > 0 && schedule.paymentsMade >= schedule.maxPayments) {
            schedule.isActive = false;
            _removeFromActiveList(account, scheduleId);
            emit PaymentScheduleCompleted(account, scheduleId);
        }

        return result;
    }

    /**
     * @notice Execute multiple due payments in batch
     * @param account The smart account
     * @param scheduleIds Array of schedule IDs to execute
     */
    function executePaymentBatch(
        address account,
        uint256[] calldata scheduleIds
    ) external returns (uint256 successCount) {
        for (uint256 i = 0; i < scheduleIds.length; i++) {
            try this.executePayment(account, scheduleIds[i]) {
                successCount++;
            } catch {
                // Continue with next payment
            }
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get a payment schedule
     * @param account The smart account
     * @param scheduleId The schedule ID
     */
    function getSchedule(
        address account,
        uint256 scheduleId
    ) external view returns (PaymentSchedule memory) {
        return accountStorage[account].schedules[scheduleId];
    }

    /**
     * @notice Get all active schedule IDs for an account
     * @param account The smart account
     */
    function getActiveSchedules(address account) external view returns (uint256[] memory) {
        return accountStorage[account].activeScheduleIds;
    }

    /**
     * @notice Check if a payment is due
     * @param account The smart account
     * @param scheduleId The schedule ID
     */
    function isPaymentDue(address account, uint256 scheduleId) external view returns (bool) {
        PaymentSchedule storage schedule = accountStorage[account].schedules[scheduleId];

        if (!schedule.isActive) return false;
        if (schedule.maxPayments > 0 && schedule.paymentsMade >= schedule.maxPayments) return false;

        uint256 nextPaymentTime = schedule.lastPaymentTime == 0
            ? schedule.startTime
            : schedule.lastPaymentTime + schedule.interval;

        return block.timestamp >= nextPaymentTime;
    }

    /**
     * @notice Get the next payment time for a schedule
     * @param account The smart account
     * @param scheduleId The schedule ID
     */
    function getNextPaymentTime(
        address account,
        uint256 scheduleId
    ) external view returns (uint256) {
        PaymentSchedule storage schedule = accountStorage[account].schedules[scheduleId];

        if (!schedule.isActive) return 0;

        return schedule.lastPaymentTime == 0
            ? schedule.startTime
            : schedule.lastPaymentTime + schedule.interval;
    }

    /**
     * @notice Get remaining payments for a schedule
     * @param account The smart account
     * @param scheduleId The schedule ID
     */
    function getRemainingPayments(
        address account,
        uint256 scheduleId
    ) external view returns (uint256) {
        PaymentSchedule storage schedule = accountStorage[account].schedules[scheduleId];

        if (!schedule.isActive) return 0;
        if (schedule.maxPayments == 0) return type(uint256).max; // Unlimited

        return schedule.maxPayments > schedule.paymentsMade
            ? schedule.maxPayments - schedule.paymentsMade
            : 0;
    }

    /**
     * @notice Calculate total remaining value for a schedule
     * @param account The smart account
     * @param scheduleId The schedule ID
     */
    function getTotalRemainingValue(
        address account,
        uint256 scheduleId
    ) external view returns (uint256) {
        PaymentSchedule storage schedule = accountStorage[account].schedules[scheduleId];

        if (!schedule.isActive) return 0;
        if (schedule.maxPayments == 0) return type(uint256).max; // Unlimited

        uint256 remaining = schedule.maxPayments > schedule.paymentsMade
            ? schedule.maxPayments - schedule.paymentsMade
            : 0;

        return remaining * schedule.amount;
    }

    // ============ Internal Functions ============

    function _createSchedule(
        address account,
        address recipient,
        address token,
        uint256 amount,
        uint256 interval,
        uint256 startTime,
        uint256 maxPayments
    ) internal returns (uint256 scheduleId) {
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        if (interval == 0) revert InvalidInterval();

        AccountStorage storage store = accountStorage[account];
        scheduleId = store.nextScheduleId++;

        if (startTime == 0) {
            startTime = block.timestamp;
        }

        store.schedules[scheduleId] = PaymentSchedule({
            recipient: recipient,
            token: token,
            amount: amount,
            interval: interval,
            startTime: startTime,
            lastPaymentTime: 0,
            maxPayments: maxPayments,
            paymentsMade: 0,
            isActive: true
        });

        store.activeScheduleIds.push(scheduleId);

        emit PaymentScheduleCreated(
            account,
            scheduleId,
            recipient,
            token,
            amount,
            interval
        );
    }

    function _executeETHPayment(
        address account,
        address recipient,
        uint256 amount
    ) internal returns (bytes[] memory) {
        bytes memory execData = abi.encodePacked(
            recipient,
            amount,
            bytes("")
        );

        ExecMode execMode = _encodeExecMode();
        return IERC7579Account(account).executeFromExecutor(execMode, execData);
    }

    function _executeTokenPayment(
        address account,
        address token,
        address recipient,
        uint256 amount
    ) internal returns (bytes[] memory) {
        bytes memory transferCall = abi.encodeWithSelector(
            IERC20.transfer.selector,
            recipient,
            amount
        );

        bytes memory execData = abi.encodePacked(
            token,
            uint256(0),
            transferCall
        );

        ExecMode execMode = _encodeExecMode();
        return IERC7579Account(account).executeFromExecutor(execMode, execData);
    }

    function _removeFromActiveList(address account, uint256 scheduleId) internal {
        AccountStorage storage store = accountStorage[account];
        uint256 length = store.activeScheduleIds.length;

        for (uint256 i = 0; i < length; i++) {
            if (store.activeScheduleIds[i] == scheduleId) {
                store.activeScheduleIds[i] = store.activeScheduleIds[length - 1];
                store.activeScheduleIds.pop();
                break;
            }
        }
    }

    function _encodeExecMode() internal pure returns (ExecMode) {
        // Single call, default exec type
        return ExecMode.wrap(bytes32(0));
    }
}
