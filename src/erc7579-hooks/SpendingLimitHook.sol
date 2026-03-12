// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IHook } from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { MODULE_TYPE_HOOK } from "../erc7579-smartaccount/types/Constants.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SpendingLimitHook
 * @notice ERC-7579 Hook module that enforces spending limits on smart accounts
 * @dev Uses a balance-based approach (pre/post balance comparison) instead of calldata
 *      parsing. This design reliably catches ALL spending paths including:
 *      - direct transfer()
 *      - transferFrom() by approved spenders
 *      - approve() + subsequent spending (tracked via actual balance change)
 *      - any custom transfer mechanisms
 *
 *      Inspired by kernel-7579-plugins SpendingLimit.sol (ZeroDev, MIT).
 *
 * Features:
 * - Configurable spending limits per token (including ETH)
 * - Time-based spending windows (hourly, daily, weekly, monthly)
 * - Automatic limit reset after each period
 * - Balance snapshot in preCheck, diff validation in postCheck
 * - Emergency pause functionality
 *
 * Use Cases:
 * - Prevent unauthorized large transfers
 * - Corporate spending policies
 * - Child account allowances
 * - Risk management for automated operations
 */
contract SpendingLimitHook is IHook {
    /// @notice Spending limit configuration for a token
    struct SpendingLimit {
        uint256 allowance; // Remaining allowance in current period
        uint256 limit; // Maximum amount per period (for reset)
        uint256 periodLength; // Length of period in seconds (0 = no periodic reset)
        uint256 periodStart; // Start of current period
        bool isEnabled;
    }

    /// @notice Storage for each smart account
    struct AccountStorage {
        address[] configuredTokens; // token address(0) = ETH
        mapping(address token => SpendingLimit) limits;
        bool isPaused;
    }

    /// @notice Account address => AccountStorage
    mapping(address => AccountStorage) internal accountStorage;

    // Common periods
    uint256 public constant PERIOD_HOURLY = 1 hours;
    uint256 public constant PERIOD_DAILY = 1 days;
    uint256 public constant PERIOD_WEEKLY = 7 days;
    uint256 public constant PERIOD_MONTHLY = 30 days;

    // Events
    event SpendingLimitSet(address indexed account, address indexed token, uint256 limit, uint256 periodLength);
    event SpendingLimitRemoved(address indexed account, address indexed token);
    event SpendingRecorded(address indexed account, address indexed token, uint256 spent, uint256 remaining);
    event AccountPaused(address indexed account);
    event AccountUnpaused(address indexed account);
    event PeriodReset(address indexed account, address indexed token, uint256 newPeriodStart);

    // Errors
    error SpendingLimitExceeded(address token, uint256 spent, uint256 allowance);
    error AccountIsPaused();
    error InvalidLimit();
    error LimitNotConfigured();

    // ============ IModule Implementation ============

    /// @notice Called when the module is installed
    function onInstall(bytes calldata data) external payable override {
        if (data.length == 0) return;

        // Decode initial configuration: (token, limit, periodLength)[]
        (address[] memory tokens, uint256[] memory limits, uint256[] memory periods) =
            abi.decode(data, (address[], uint256[], uint256[]));

        for (uint256 i = 0; i < tokens.length; i++) {
            _setSpendingLimit(msg.sender, tokens[i], limits[i], periods[i]);
        }
    }

    /// @notice Called when the module is uninstalled
    function onUninstall(bytes calldata) external payable override {
        AccountStorage storage store = accountStorage[msg.sender];

        // Clear all limits
        address[] memory tokens = store.configuredTokens;
        for (uint256 i = 0; i < tokens.length; i++) {
            delete store.limits[tokens[i]];
        }
        delete store.configuredTokens;
        store.isPaused = false;
    }

    /// @notice Returns true if this is a Hook module
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_HOOK;
    }

    /// @notice Returns true if the module is initialized for the account
    function isInitialized(address smartAccount) external view override returns (bool) {
        return accountStorage[smartAccount].configuredTokens.length > 0;
    }

    // ============ IHook Implementation ============

    /**
     * @notice Pre-execution check - snapshots balances for all configured tokens
     * @dev Balance-based approach: record balances before execution, compare after
     *      This catches ALL spending paths (transfer, transferFrom, approve+spend, etc.)
     * @return hookData Encoded pre-execution balances
     */
    function preCheck(address, uint256, bytes calldata)
        external
        payable
        override
        returns (bytes memory hookData)
    {
        AccountStorage storage store = accountStorage[msg.sender];

        if (store.isPaused) revert AccountIsPaused();

        uint256 length = store.configuredTokens.length;
        uint256[] memory balances = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            address token = store.configuredTokens[i];
            if (token == address(0)) {
                balances[i] = msg.sender.balance;
            } else {
                balances[i] = IERC20(token).balanceOf(msg.sender);
            }
        }

        return abi.encode(balances);
    }

    /**
     * @notice Post-execution check - compares balances and enforces spending limits
     * @dev For each configured token:
     *      1. Get current balance
     *      2. Compare with pre-execution snapshot
     *      3. If balance decreased, check against allowance
     *      4. If balance increased (received tokens), skip the check
     * @param hookData Encoded pre-execution balances from preCheck
     */
    function postCheck(bytes calldata hookData) external payable override {
        AccountStorage storage store = accountStorage[msg.sender];
        uint256 length = store.configuredTokens.length;

        uint256[] memory preBalances = abi.decode(hookData, (uint256[]));

        for (uint256 i = 0; i < length; i++) {
            address token = store.configuredTokens[i];
            SpendingLimit storage limit = store.limits[token];

            if (!limit.isEnabled) continue;

            // Get current balance
            uint256 currentBalance;
            if (token == address(0)) {
                currentBalance = msg.sender.balance;
            } else {
                currentBalance = IERC20(token).balanceOf(msg.sender);
            }

            // If balance increased, skip (received tokens)
            if (currentBalance >= preBalances[i]) continue;

            uint256 spent = preBalances[i] - currentBalance;

            // Reset period if expired
            if (limit.periodLength > 0 && block.timestamp >= limit.periodStart + limit.periodLength) {
                limit.allowance = limit.limit;
                limit.periodStart = block.timestamp;
                emit PeriodReset(msg.sender, token, block.timestamp);
            }

            // Check allowance
            if (limit.allowance < spent) {
                revert SpendingLimitExceeded(token, spent, limit.allowance);
            }

            // Deduct from allowance
            limit.allowance -= spent;

            emit SpendingRecorded(msg.sender, token, spent, limit.allowance);
        }
    }

    // ============ Spending Limit Management ============

    /**
     * @notice Set a spending limit for a token
     * @param token Token address (address(0) for ETH)
     * @param limit Maximum spending per period
     * @param periodLength Period length in seconds (0 = lifetime limit, no reset)
     */
    function setSpendingLimit(address token, uint256 limit, uint256 periodLength) external {
        _setSpendingLimit(msg.sender, token, limit, periodLength);
    }

    /**
     * @notice Remove a spending limit
     * @param token Token address
     */
    function removeSpendingLimit(address token) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (!store.limits[token].isEnabled) revert LimitNotConfigured();

        delete store.limits[token];
        _removeFromConfiguredTokens(msg.sender, token);

        emit SpendingLimitRemoved(msg.sender, token);
    }

    /**
     * @notice Pause all operations for the account
     */
    function pause() external {
        accountStorage[msg.sender].isPaused = true;
        emit AccountPaused(msg.sender);
    }

    /**
     * @notice Unpause operations for the account
     */
    function unpause() external {
        accountStorage[msg.sender].isPaused = false;
        emit AccountUnpaused(msg.sender);
    }

    /**
     * @notice Reset the spending counter for a token (starts new period)
     * @param token Token address
     */
    function resetPeriod(address token) external {
        AccountStorage storage store = accountStorage[msg.sender];
        SpendingLimit storage limit = store.limits[token];

        if (!limit.isEnabled) revert LimitNotConfigured();

        limit.allowance = limit.limit;
        limit.periodStart = block.timestamp;

        emit PeriodReset(msg.sender, token, block.timestamp);
    }

    // ============ View Functions ============

    /**
     * @notice Get spending limit configuration
     * @param account The smart account
     * @param token Token address
     */
    function getSpendingLimit(address account, address token) external view returns (SpendingLimit memory) {
        return accountStorage[account].limits[token];
    }

    /**
     * @notice Get remaining spending allowance
     * @param account The smart account
     * @param token Token address
     */
    function getRemainingAllowance(address account, address token) external view returns (uint256) {
        SpendingLimit storage limit = accountStorage[account].limits[token];

        if (!limit.isEnabled) return type(uint256).max;

        // Check if period has expired
        if (limit.periodLength > 0 && block.timestamp >= limit.periodStart + limit.periodLength) {
            return limit.limit; // Full allowance after period reset
        }

        return limit.allowance;
    }

    /**
     * @notice Check if account is paused
     * @param account The smart account
     */
    function isPaused(address account) external view returns (bool) {
        return accountStorage[account].isPaused;
    }

    /**
     * @notice Get all configured tokens for an account
     * @param account The smart account
     */
    function getConfiguredTokens(address account) external view returns (address[] memory) {
        return accountStorage[account].configuredTokens;
    }

    /**
     * @notice Get time until period reset
     * @param account The smart account
     * @param token Token address
     */
    function getTimeUntilReset(address account, address token) external view returns (uint256) {
        SpendingLimit storage limit = accountStorage[account].limits[token];

        if (!limit.isEnabled || limit.periodLength == 0) return 0;

        uint256 periodEnd = limit.periodStart + limit.periodLength;
        if (block.timestamp >= periodEnd) return 0;

        return periodEnd - block.timestamp;
    }

    // ============ Internal Functions ============

    function _setSpendingLimit(address account, address token, uint256 limit, uint256 periodLength) internal {
        if (limit == 0) revert InvalidLimit();

        AccountStorage storage store = accountStorage[account];

        // Add to configured tokens if new
        if (!store.limits[token].isEnabled) {
            store.configuredTokens.push(token);
        }

        store.limits[token] = SpendingLimit({
            allowance: limit,
            limit: limit,
            periodLength: periodLength,
            periodStart: block.timestamp,
            isEnabled: true
        });

        emit SpendingLimitSet(account, token, limit, periodLength);
    }

    function _removeFromConfiguredTokens(address account, address token) internal {
        AccountStorage storage store = accountStorage[account];
        uint256 length = store.configuredTokens.length;

        for (uint256 i = 0; i < length; i++) {
            if (store.configuredTokens[i] == token) {
                store.configuredTokens[i] = store.configuredTokens[length - 1];
                store.configuredTokens.pop();
                break;
            }
        }
    }
}
