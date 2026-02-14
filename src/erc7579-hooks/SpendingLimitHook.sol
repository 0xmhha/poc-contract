// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IHook } from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { MODULE_TYPE_HOOK } from "../erc7579-smartaccount/types/Constants.sol";

/**
 * @title SpendingLimitHook
 * @notice ERC-7579 Hook module that enforces spending limits on smart accounts
 * @dev Tracks and limits ETH and ERC-20 token spending per time period
 *
 * Features:
 * - Configurable spending limits per token (including ETH)
 * - Time-based spending windows (hourly, daily, weekly, monthly)
 * - Automatic limit reset after each period
 * - Whitelist for unlimited spending to certain addresses
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
        uint256 limit; // Maximum amount per period
        uint256 spent; // Amount spent in current period
        uint256 periodLength; // Length of period in seconds
        uint256 periodStart; // Start of current period
        bool isEnabled;
    }

    /// @notice Storage for each smart account
    struct AccountStorage {
        mapping(address token => SpendingLimit) limits; // token address(0) = ETH
        mapping(address => bool) whitelist; // Addresses exempt from limits
        bool isPaused;
        address[] configuredTokens;
    }

    /// @notice Account address => AccountStorage
    mapping(address => AccountStorage) internal accountStorage;

    // Common periods
    uint256 public constant PERIOD_HOURLY = 1 hours;
    uint256 public constant PERIOD_DAILY = 1 days;
    uint256 public constant PERIOD_WEEKLY = 7 days;
    uint256 public constant PERIOD_MONTHLY = 30 days;

    // ERC-20 function selectors
    bytes4 private constant TRANSFER_SELECTOR = bytes4(keccak256("transfer(address,uint256)"));
    bytes4 private constant TRANSFER_FROM_SELECTOR = bytes4(keccak256("transferFrom(address,address,uint256)"));
    bytes4 private constant APPROVE_SELECTOR = bytes4(keccak256("approve(address,uint256)"));

    // Events
    event SpendingLimitSet(address indexed account, address indexed token, uint256 limit, uint256 periodLength);
    event SpendingLimitRemoved(address indexed account, address indexed token);
    event SpendingRecorded(
        address indexed account, address indexed token, uint256 amount, uint256 newTotal, uint256 limit
    );
    event WhitelistUpdated(address indexed account, address indexed target, bool isWhitelisted);
    event AccountPaused(address indexed account);
    event AccountUnpaused(address indexed account);
    event PeriodReset(address indexed account, address indexed token, uint256 newPeriodStart);

    // Errors
    error SpendingLimitExceeded(address token, uint256 requested, uint256 available);
    error AccountIsPaused();
    error InvalidLimit();
    error InvalidPeriod();
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
     * @notice Pre-execution check - validates spending limits
     * @param msgValue ETH value being sent
     * @param msgData The calldata being executed
     * @return hookData Data to pass to postCheck
     */
    function preCheck(address, uint256 msgValue, bytes calldata msgData)
        external
        payable
        override
        returns (bytes memory hookData)
    {
        AccountStorage storage store = accountStorage[msg.sender];

        // Check if paused
        if (store.isPaused) revert AccountIsPaused();

        // Extract execution data, handling wrapper calldata from AA/executor paths
        if (msgData.length < 20) {
            return abi.encode(address(0), msgValue);
        }

        (address target, uint256 execValue, bytes calldata execCalldata) =
            _extractExecutionData(msgData, msgValue);

        // Check whitelist
        if (target != address(0) && store.whitelist[target]) {
            return abi.encode(address(0), uint256(0)); // Skip limit check
        }

        // Check ETH spending
        if (execValue > 0) {
            _checkAndRecordSpending(msg.sender, address(0), execValue);
        }

        // Check ERC-20 transfers and approvals
        if (execCalldata.length >= 4) {
            bytes4 selector = bytes4(execCalldata[0:4]);

            if (selector == TRANSFER_SELECTOR && execCalldata.length >= 68) {
                // transfer(address,uint256): selector(4) + to(32) + amount(32) = 68
                uint256 amount = uint256(bytes32(execCalldata[36:68]));
                _checkAndRecordSpending(msg.sender, target, amount);
                return abi.encode(target, amount);
            } else if (selector == TRANSFER_FROM_SELECTOR && execCalldata.length >= 100) {
                // transferFrom(address,address,uint256): selector(4) + from(32) + to(32) + amount(32) = 100
                uint256 amount = uint256(bytes32(execCalldata[68:100]));
                _checkAndRecordSpending(msg.sender, target, amount);
                return abi.encode(target, amount);
            } else if (selector == APPROVE_SELECTOR && execCalldata.length >= 68) {
                // approve(address,uint256): selector(4) + spender(32) + amount(32) = 68
                uint256 amount = uint256(bytes32(execCalldata[36:68]));
                _checkAndRecordSpending(msg.sender, target, amount);
                return abi.encode(target, amount);
            }
        }

        return abi.encode(address(0), execValue);
    }

    /**
     * @notice Post-execution check
     * @param hookData Data from preCheck (unused in this implementation)
     */
    function postCheck(bytes calldata hookData) external payable override {
        // Post-check can be used for additional validation if needed
        // Currently, all validation is done in preCheck
        (hookData); // Silence unused warning
    }

    // ============ Spending Limit Management ============

    /**
     * @notice Set a spending limit for a token
     * @param token Token address (address(0) for ETH)
     * @param limit Maximum spending per period
     * @param periodLength Period length in seconds
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
     * @notice Update whitelist status for an address
     * @param target Address to whitelist/unwhitelist
     * @param whitelisted Whether to whitelist
     */
    function setWhitelist(address target, bool whitelisted) external {
        accountStorage[msg.sender].whitelist[target] = whitelisted;
        emit WhitelistUpdated(msg.sender, target, whitelisted);
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

        limit.spent = 0;
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
        if (block.timestamp >= limit.periodStart + limit.periodLength) {
            return limit.limit; // Full allowance after period reset
        }

        return limit.limit > limit.spent ? limit.limit - limit.spent : 0;
    }

    /**
     * @notice Check if an address is whitelisted
     * @param account The smart account
     * @param target The address to check
     */
    function isWhitelisted(address account, address target) external view returns (bool) {
        return accountStorage[account].whitelist[target];
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

        if (!limit.isEnabled) return 0;

        uint256 periodEnd = limit.periodStart + limit.periodLength;
        if (block.timestamp >= periodEnd) return 0;

        return periodEnd - block.timestamp;
    }

    // ============ Internal Functions ============

    /// @notice Known function selector for wrapper calldata detection (executeFromExecutor path)
    bytes4 private constant EXECUTE_FROM_EXECUTOR_SELECTOR =
        bytes4(keccak256("executeFromExecutor(bytes32,bytes)"));

    /**
     * @notice Extract the actual execution target, value, and calldata from potentially wrapped msgData
     * @dev In the Account Abstraction path, msgData may be:
     *      - executeUserOp path: ABI-encoded (ExecMode, executionCalldata) with selector already stripped
     *      - executeFromExecutor path: selector + ABI-encoded (ExecMode, executionCalldata)
     *      - Direct path: raw execution calldata (target[0:20] || value[20:52] || calldata[52:])
     * @param msgData The calldata passed to preCheck
     * @param msgValue The ETH value passed to preCheck
     * @return target The execution target address
     * @return value The ETH value for the execution
     * @return execCalldata The inner calldata (selector + arguments) being called on the target
     */
    function _extractExecutionData(bytes calldata msgData, uint256 msgValue)
        internal
        pure
        returns (address target, uint256 value, bytes calldata execCalldata)
    {
        // Path 1: executeFromExecutor wrapper — starts with 4-byte selector
        if (msgData.length >= 4) {
            bytes4 selector = bytes4(msgData[0:4]);

            if (selector == EXECUTE_FROM_EXECUTOR_SELECTOR) {
                if (msgData.length >= 100) {
                    bytes calldata abiPayload = msgData[4:];
                    return _decodeAbiWrappedExecution(abiPayload, msgValue);
                }
            }

            // Path 2: executeUserOp path — selector already stripped, data is abi.encode(ExecMode, bytes)
            if (msgData.length >= 96) {
                uint256 offset = uint256(bytes32(msgData[32:64]));
                if (offset == 0x40) {
                    return _decodeAbiWrappedExecution(msgData, msgValue);
                }
            }
        }

        // Path 3: Raw execution calldata — target[0:20] || value[20:52] || calldata[52:]
        if (msgData.length >= 20) {
            target = address(bytes20(msgData[0:20]));
        }
        if (msgData.length >= 52) {
            value = uint256(bytes32(msgData[20:52]));
        } else {
            value = msgValue;
        }
        if (msgData.length > 52) {
            execCalldata = msgData[52:];
        } else {
            execCalldata = msgData[0:0];
        }
    }

    /**
     * @notice Decode ABI-encoded (ExecMode, bytes executionCalldata) and extract raw execution data
     */
    function _decodeAbiWrappedExecution(bytes calldata abiPayload, uint256 msgValue)
        internal
        pure
        returns (address target, uint256 value, bytes calldata execCalldata)
    {
        if (abiPayload.length < 96) {
            if (abiPayload.length >= 20) {
                target = address(bytes20(abiPayload[0:20]));
            }
            value = msgValue;
            execCalldata = abiPayload[0:0];
            return (target, value, execCalldata);
        }

        uint256 dataLength = uint256(bytes32(abiPayload[64:96]));
        uint256 dataStart = 96;
        uint256 dataEnd = dataStart + dataLength;

        if (dataEnd > abiPayload.length) {
            if (abiPayload.length >= 20) {
                target = address(bytes20(abiPayload[0:20]));
            }
            value = msgValue;
            execCalldata = abiPayload[0:0];
            return (target, value, execCalldata);
        }

        bytes calldata innerData = abiPayload[dataStart:dataEnd];

        if (innerData.length >= 20) {
            target = address(bytes20(innerData[0:20]));
        }
        if (innerData.length >= 52) {
            value = uint256(bytes32(innerData[20:52]));
        } else {
            value = msgValue;
        }
        if (innerData.length > 52) {
            execCalldata = innerData[52:];
        } else {
            execCalldata = innerData[0:0];
        }
    }

    function _setSpendingLimit(address account, address token, uint256 limit, uint256 periodLength) internal {
        if (limit == 0) revert InvalidLimit();
        if (periodLength == 0) revert InvalidPeriod();

        AccountStorage storage store = accountStorage[account];

        // Add to configured tokens if new
        if (!store.limits[token].isEnabled) {
            store.configuredTokens.push(token);
        }

        store.limits[token] = SpendingLimit({
            limit: limit, spent: 0, periodLength: periodLength, periodStart: block.timestamp, isEnabled: true
        });

        emit SpendingLimitSet(account, token, limit, periodLength);
    }

    function _checkAndRecordSpending(address account, address token, uint256 amount) internal {
        AccountStorage storage store = accountStorage[account];
        SpendingLimit storage limit = store.limits[token];

        // If no limit configured, allow
        if (!limit.isEnabled) return;

        // Check if period has expired and reset
        if (block.timestamp >= limit.periodStart + limit.periodLength) {
            limit.spent = 0;
            limit.periodStart = block.timestamp;
            emit PeriodReset(account, token, block.timestamp);
        }

        // Check limit
        uint256 newTotal = limit.spent + amount;
        if (newTotal > limit.limit) {
            revert SpendingLimitExceeded(token, amount, limit.limit - limit.spent);
        }

        // Record spending
        limit.spent = newTotal;

        emit SpendingRecorded(account, token, amount, newTotal, limit.limit);
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
