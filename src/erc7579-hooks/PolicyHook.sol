// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IHook } from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { MODULE_TYPE_HOOK } from "../erc7579-smartaccount/types/Constants.sol";

/**
 * @title PolicyHook
 * @notice ERC-7579 Hook module that enforces execution policies on smart accounts
 * @dev Provides flexible policy enforcement including:
 *      - Target address whitelist/blacklist modes
 *      - Function selector restrictions per target
 *      - Value limits per target
 *      - Transaction count limits per period
 *      - Emergency pause functionality
 *
 * Policy Modes:
 * - ALLOWLIST: Only explicitly allowed targets can be called (default deny)
 * - BLOCKLIST: All targets allowed except explicitly blocked ones (default allow)
 *
 * Use Cases:
 * - Corporate policy enforcement
 * - Child account restrictions
 * - Risk management for automated operations
 * - DeFi protocol interaction control
 */
contract PolicyHook is IHook {
    // ============ Enums ============

    /// @notice Policy enforcement mode
    enum PolicyMode {
        ALLOWLIST, // Default deny - only allowed targets can be called
        BLOCKLIST // Default allow - only blocked targets are restricted
    }

    // ============ Structs ============

    /// @notice Target configuration
    struct TargetConfig {
        bool isAllowed; // For ALLOWLIST mode
        bool isBlocked; // For BLOCKLIST mode
        uint256 valueLimit; // Max value per transaction (0 = no limit)
        bool strictSelectorMode; // If true, only allowed selectors can be called
        mapping(bytes4 => bool) allowedSelectors;
        mapping(bytes4 => bool) blockedSelectors;
        bytes4[] allowedSelectorsList;
        bytes4[] blockedSelectorsList;
    }

    /// @notice Transaction count limit configuration
    struct TxCountLimit {
        uint256 limit; // Max transactions per period
        uint256 count; // Current count in period
        uint256 periodLength; // Period length in seconds
        uint256 periodStart; // Start of current period
        bool isEnabled;
    }

    /// @notice Account policy storage
    struct AccountStorage {
        PolicyMode mode;
        bool isStrict; // Strict mode flag
        bool isPaused;
        bool isInitialized;
        TxCountLimit txCountLimit;
        address[] allowedTargets;
        address[] blockedTargets;
        mapping(address => TargetConfig) targets;
    }

    // ============ Storage ============

    /// @notice Account address => AccountStorage
    mapping(address => AccountStorage) internal accountStorage;

    // ============ Events ============

    event PolicyModeSet(address indexed account, PolicyMode mode);
    event TargetAllowed(address indexed account, address indexed target);
    event TargetAllowRemoved(address indexed account, address indexed target);
    event TargetBlocked(address indexed account, address indexed target);
    event TargetBlockRemoved(address indexed account, address indexed target);
    event SelectorAllowed(address indexed account, address indexed target, bytes4 selector);
    event SelectorAllowRemoved(address indexed account, address indexed target, bytes4 selector);
    event SelectorBlocked(address indexed account, address indexed target, bytes4 selector);
    event SelectorBlockRemoved(address indexed account, address indexed target, bytes4 selector);
    event ValueLimitSet(address indexed account, address indexed target, uint256 limit);
    event ValueLimitRemoved(address indexed account, address indexed target);
    event TxCountLimitSet(address indexed account, uint256 limit, uint256 periodLength);
    event StrictSelectorModeSet(address indexed account, address indexed target, bool strict);
    event AccountPaused(address indexed account);
    event AccountUnpaused(address indexed account);
    event TransactionCounted(address indexed account, uint256 newCount, uint256 limit);
    event TxCountPeriodReset(address indexed account, uint256 newPeriodStart);

    // ============ Errors ============

    error AccountIsPaused();
    error TargetNotAllowed(address target);
    error TargetIsBlocked(address target);
    error SelectorNotAllowed(address target, bytes4 selector);
    error SelectorIsBlocked(address target, bytes4 selector);
    error ValueExceedsLimit(address target, uint256 value, uint256 limit);
    error TransactionCountExceeded();
    error InvalidConfiguration();
    error TargetNotConfigured(address target);

    // ============ IModule Implementation ============

    /// @notice Called when the module is installed
    function onInstall(bytes calldata data) external payable override {
        if (data.length == 0) return;

        // Decode initial configuration: (PolicyMode, bool strict)
        (PolicyMode mode, bool strict) = abi.decode(data, (PolicyMode, bool));

        AccountStorage storage store = accountStorage[msg.sender];
        store.mode = mode;
        store.isStrict = strict;
        store.isInitialized = true;

        emit PolicyModeSet(msg.sender, mode);
    }

    /// @notice Called when the module is uninstalled
    function onUninstall(bytes calldata) external payable override {
        AccountStorage storage store = accountStorage[msg.sender];

        // Clear allowed targets
        for (uint256 i = 0; i < store.allowedTargets.length; i++) {
            address target = store.allowedTargets[i];
            _clearTargetConfig(store, target);
        }
        delete store.allowedTargets;

        // Clear blocked targets
        for (uint256 i = 0; i < store.blockedTargets.length; i++) {
            address target = store.blockedTargets[i];
            _clearTargetConfig(store, target);
        }
        delete store.blockedTargets;

        // Clear other state
        store.isPaused = false;
        store.isInitialized = false;
        delete store.txCountLimit;
    }

    /// @notice Returns true if this is a Hook module
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_HOOK;
    }

    /// @notice Returns true if the module is initialized for the account
    function isInitialized(address smartAccount) external view override returns (bool) {
        return accountStorage[smartAccount].isInitialized;
    }

    // ============ IHook Implementation ============

    /**
     * @notice Pre-execution check - validates policies
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
            return abi.encode(address(0), uint256(0));
        }

        (address target, uint256 execValue, bytes calldata execCalldata) =
            _extractExecutionData(msgData, msgValue);

        // Check policy mode
        if (store.mode == PolicyMode.ALLOWLIST) {
            _checkAllowlistPolicy(store, target, execValue, execCalldata);
        } else {
            _checkBlocklistPolicy(store, target, execValue, execCalldata);
        }

        // Check and record transaction count
        _checkAndRecordTxCount(store);

        return abi.encode(target, execValue);
    }

    /**
     * @notice Post-execution check
     * @param hookData Data from preCheck (unused in this implementation)
     */
    function postCheck(bytes calldata hookData) external payable override {
        // Post-check can be used for additional validation if needed
        (hookData); // Silence unused warning
    }

    // ============ Policy Mode Management ============

    /// @notice Set the policy mode
    function setPolicyMode(PolicyMode mode) external {
        accountStorage[msg.sender].mode = mode;
        emit PolicyModeSet(msg.sender, mode);
    }

    /// @notice Get the policy mode for an account
    function getPolicyMode(address account) external view returns (PolicyMode) {
        return accountStorage[account].mode;
    }

    // ============ Target Management ============

    /// @notice Add a target to the allowlist
    function addAllowedTarget(address target) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (!store.targets[target].isAllowed) {
            store.targets[target].isAllowed = true;
            store.allowedTargets.push(target);
            emit TargetAllowed(msg.sender, target);
        }
    }

    /// @notice Remove a target from the allowlist
    function removeAllowedTarget(address target) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (store.targets[target].isAllowed) {
            store.targets[target].isAllowed = false;
            _removeFromArray(store.allowedTargets, target);
            emit TargetAllowRemoved(msg.sender, target);
        }
    }

    /// @notice Add a target to the blocklist
    function addBlockedTarget(address target) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (!store.targets[target].isBlocked) {
            store.targets[target].isBlocked = true;
            store.blockedTargets.push(target);
            emit TargetBlocked(msg.sender, target);
        }
    }

    /// @notice Remove a target from the blocklist
    function removeBlockedTarget(address target) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (store.targets[target].isBlocked) {
            store.targets[target].isBlocked = false;
            _removeFromArray(store.blockedTargets, target);
            emit TargetBlockRemoved(msg.sender, target);
        }
    }

    /// @notice Batch add allowed targets
    function batchAddAllowedTargets(address[] calldata targets) external {
        for (uint256 i = 0; i < targets.length; i++) {
            AccountStorage storage store = accountStorage[msg.sender];
            if (!store.targets[targets[i]].isAllowed) {
                store.targets[targets[i]].isAllowed = true;
                store.allowedTargets.push(targets[i]);
                emit TargetAllowed(msg.sender, targets[i]);
            }
        }
    }

    /// @notice Configure a target with all settings at once
    function configureTarget(
        address target,
        bool allowed,
        bytes4[] calldata selectors,
        uint256 valueLimit,
        bool strictSelectorMode
    ) external {
        AccountStorage storage store = accountStorage[msg.sender];
        TargetConfig storage config = store.targets[target];

        // Set allowed status
        if (allowed && !config.isAllowed) {
            config.isAllowed = true;
            store.allowedTargets.push(target);
            emit TargetAllowed(msg.sender, target);
        }

        // Set selectors
        for (uint256 i = 0; i < selectors.length; i++) {
            if (!config.allowedSelectors[selectors[i]]) {
                config.allowedSelectors[selectors[i]] = true;
                config.allowedSelectorsList.push(selectors[i]);
                emit SelectorAllowed(msg.sender, target, selectors[i]);
            }
        }

        // Set value limit
        if (valueLimit > 0) {
            config.valueLimit = valueLimit;
            emit ValueLimitSet(msg.sender, target, valueLimit);
        }

        // Set strict selector mode
        config.strictSelectorMode = strictSelectorMode;
        emit StrictSelectorModeSet(msg.sender, target, strictSelectorMode);
    }

    // ============ Selector Management ============

    /// @notice Add an allowed selector for a target
    function addAllowedSelector(address target, bytes4 selector) external {
        AccountStorage storage store = accountStorage[msg.sender];
        TargetConfig storage config = store.targets[target];

        if (!config.allowedSelectors[selector]) {
            config.allowedSelectors[selector] = true;
            config.allowedSelectorsList.push(selector);
            emit SelectorAllowed(msg.sender, target, selector);
        }
    }

    /// @notice Remove an allowed selector for a target
    function removeAllowedSelector(address target, bytes4 selector) external {
        AccountStorage storage store = accountStorage[msg.sender];
        TargetConfig storage config = store.targets[target];

        if (config.allowedSelectors[selector]) {
            config.allowedSelectors[selector] = false;
            _removeSelector(config.allowedSelectorsList, selector);
            emit SelectorAllowRemoved(msg.sender, target, selector);
        }
    }

    /// @notice Add a blocked selector for a target
    function addBlockedSelector(address target, bytes4 selector) external {
        AccountStorage storage store = accountStorage[msg.sender];
        TargetConfig storage config = store.targets[target];

        if (!config.blockedSelectors[selector]) {
            config.blockedSelectors[selector] = true;
            config.blockedSelectorsList.push(selector);
            emit SelectorBlocked(msg.sender, target, selector);
        }
    }

    /// @notice Remove a blocked selector for a target
    function removeBlockedSelector(address target, bytes4 selector) external {
        AccountStorage storage store = accountStorage[msg.sender];
        TargetConfig storage config = store.targets[target];

        if (config.blockedSelectors[selector]) {
            config.blockedSelectors[selector] = false;
            _removeSelector(config.blockedSelectorsList, selector);
            emit SelectorBlockRemoved(msg.sender, target, selector);
        }
    }

    /// @notice Set strict selector mode for a target
    function setStrictSelectorMode(address target, bool strict) external {
        accountStorage[msg.sender].targets[target].strictSelectorMode = strict;
        emit StrictSelectorModeSet(msg.sender, target, strict);
    }

    // ============ Value Limit Management ============

    /// @notice Set a value limit for a target
    function setTargetValueLimit(address target, uint256 limit) external {
        accountStorage[msg.sender].targets[target].valueLimit = limit;
        emit ValueLimitSet(msg.sender, target, limit);
    }

    /// @notice Remove a value limit for a target
    function removeTargetValueLimit(address target) external {
        accountStorage[msg.sender].targets[target].valueLimit = 0;
        emit ValueLimitRemoved(msg.sender, target);
    }

    // ============ Transaction Count Limit Management ============

    /// @notice Set transaction count limit
    function setTransactionCountLimit(uint256 limit, uint256 periodLength) external {
        AccountStorage storage store = accountStorage[msg.sender];

        store.txCountLimit = TxCountLimit({
            limit: limit, count: 0, periodLength: periodLength, periodStart: block.timestamp, isEnabled: true
        });

        emit TxCountLimitSet(msg.sender, limit, periodLength);
    }

    /// @notice Get transaction count limit configuration
    function getTransactionCountLimit(address account) external view returns (uint256 limit, uint256 periodLength) {
        TxCountLimit storage txLimit = accountStorage[account].txCountLimit;
        return (txLimit.limit, txLimit.periodLength);
    }

    /// @notice Get remaining transaction count
    function getRemainingTransactionCount(address account) external view returns (uint256) {
        TxCountLimit storage txLimit = accountStorage[account].txCountLimit;

        if (!txLimit.isEnabled) return type(uint256).max;

        // Check if period has expired
        if (block.timestamp >= txLimit.periodStart + txLimit.periodLength) {
            return txLimit.limit; // Full count after period reset
        }

        return txLimit.limit > txLimit.count ? txLimit.limit - txLimit.count : 0;
    }

    // ============ Pause Management ============

    /// @notice Pause all operations for the account
    function pause() external {
        accountStorage[msg.sender].isPaused = true;
        emit AccountPaused(msg.sender);
    }

    /// @notice Unpause operations for the account
    function unpause() external {
        accountStorage[msg.sender].isPaused = false;
        emit AccountUnpaused(msg.sender);
    }

    /// @notice Check if account is paused
    function isPaused(address account) external view returns (bool) {
        return accountStorage[account].isPaused;
    }

    // ============ View Functions ============

    /// @notice Check if a target is allowed
    function isTargetAllowed(address account, address target) external view returns (bool) {
        return accountStorage[account].targets[target].isAllowed;
    }

    /// @notice Check if a target is blocked
    function isTargetBlocked(address account, address target) external view returns (bool) {
        return accountStorage[account].targets[target].isBlocked;
    }

    /// @notice Check if a selector is allowed for a target
    function isSelectorAllowed(address account, address target, bytes4 selector) external view returns (bool) {
        return accountStorage[account].targets[target].allowedSelectors[selector];
    }

    /// @notice Check if a selector is blocked for a target
    function isSelectorBlocked(address account, address target, bytes4 selector) external view returns (bool) {
        return accountStorage[account].targets[target].blockedSelectors[selector];
    }

    /// @notice Get the value limit for a target
    function getTargetValueLimit(address account, address target) external view returns (uint256) {
        return accountStorage[account].targets[target].valueLimit;
    }

    /// @notice Get all allowed targets
    function getAllowedTargets(address account) external view returns (address[] memory) {
        return accountStorage[account].allowedTargets;
    }

    /// @notice Get all blocked targets
    function getBlockedTargets(address account) external view returns (address[] memory) {
        return accountStorage[account].blockedTargets;
    }

    /// @notice Get allowed selectors for a target
    function getAllowedSelectors(address account, address target) external view returns (bytes4[] memory) {
        return accountStorage[account].targets[target].allowedSelectorsList;
    }

    /// @notice Get blocked selectors for a target
    function getBlockedSelectors(address account, address target) external view returns (bytes4[] memory) {
        return accountStorage[account].targets[target].blockedSelectorsList;
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
     *      This function detects the wrapper format and extracts the inner execution data.
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
                // msg.data = selector(4) + abi.encode(ExecMode, bytes executionCalldata)
                // Skip selector, ABI-decode to get executionCalldata, then parse as raw exec data
                if (msgData.length >= 100) {
                    // 4 (selector) + 32 (ExecMode) + 32 (offset) + 32 (length) = 100 minimum
                    bytes calldata abiPayload = msgData[4:];
                    return _decodeAbiWrappedExecution(abiPayload, msgValue);
                }
            }

            // Path 2: executeUserOp path — selector already stripped, data is abi.encode(ExecMode, bytes)
            // Detect by checking if bytes[32:64] contain a valid ABI offset (0x40 = 64 for two params)
            if (msgData.length >= 96) {
                // 32 (ExecMode) + 32 (offset) + 32 (length) = 96 minimum
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
            execCalldata = msgData[0:0]; // empty slice
        }
    }

    /**
     * @notice Decode ABI-encoded (ExecMode, bytes executionCalldata) and extract raw execution data
     * @param abiPayload ABI-encoded payload: ExecMode(32) + offset(32) + length(32) + executionCalldata
     * @param msgValue Fallback value if inner calldata doesn't contain value
     * @return target The execution target address
     * @return value The ETH value for the execution
     * @return execCalldata The inner calldata being called on the target
     */
    function _decodeAbiWrappedExecution(bytes calldata abiPayload, uint256 msgValue)
        internal
        pure
        returns (address target, uint256 value, bytes calldata execCalldata)
    {
        // abiPayload = ExecMode(32 bytes) + ABI-encoded bytes (offset + length + data)
        // Standard ABI: offset at [32:64] should be 0x40, length at [64:96], data starts at [96:]
        if (abiPayload.length < 96) {
            // Too short, fall back to raw parsing
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
            // Invalid encoding, fall back to raw parsing
            if (abiPayload.length >= 20) {
                target = address(bytes20(abiPayload[0:20]));
            }
            value = msgValue;
            execCalldata = abiPayload[0:0];
            return (target, value, execCalldata);
        }

        // The inner executionCalldata is in raw format: target[0:20] || value[20:52] || calldata[52:]
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

    function _checkAllowlistPolicy(
        AccountStorage storage store,
        address target,
        uint256 value,
        bytes calldata execCalldata
    ) internal view {
        TargetConfig storage config = store.targets[target];

        // Check target is allowed
        if (!config.isAllowed) {
            revert TargetNotAllowed(target);
        }

        // Check value limit
        if (config.valueLimit > 0 && value > config.valueLimit) {
            revert ValueExceedsLimit(target, value, config.valueLimit);
        }

        // Check selector if strict mode is enabled
        if (config.strictSelectorMode && execCalldata.length >= 4) {
            bytes4 selector = bytes4(execCalldata[0:4]);

            if (!config.allowedSelectors[selector]) {
                revert SelectorNotAllowed(target, selector);
            }
        }
    }

    function _checkBlocklistPolicy(
        AccountStorage storage store,
        address target,
        uint256 value,
        bytes calldata execCalldata
    ) internal view {
        TargetConfig storage config = store.targets[target];

        // Check target is not blocked
        if (config.isBlocked) {
            revert TargetIsBlocked(target);
        }

        // Check value limit if set
        if (config.valueLimit > 0 && value > config.valueLimit) {
            revert ValueExceedsLimit(target, value, config.valueLimit);
        }

        // Check selector is not blocked
        if (execCalldata.length >= 4) {
            bytes4 selector = bytes4(execCalldata[0:4]);

            if (config.blockedSelectors[selector]) {
                revert SelectorIsBlocked(target, selector);
            }
        }
    }

    function _checkAndRecordTxCount(AccountStorage storage store) internal {
        TxCountLimit storage txLimit = store.txCountLimit;

        if (!txLimit.isEnabled) return;

        // Check if period has expired and reset
        if (block.timestamp >= txLimit.periodStart + txLimit.periodLength) {
            txLimit.count = 0;
            txLimit.periodStart = block.timestamp;
            emit TxCountPeriodReset(msg.sender, block.timestamp);
        }

        // Check limit
        if (txLimit.count >= txLimit.limit) {
            revert TransactionCountExceeded();
        }

        // Record transaction
        txLimit.count++;
        emit TransactionCounted(msg.sender, txLimit.count, txLimit.limit);
    }

    function _clearTargetConfig(AccountStorage storage store, address target) internal {
        TargetConfig storage config = store.targets[target];

        // Clear allowed selectors
        for (uint256 i = 0; i < config.allowedSelectorsList.length; i++) {
            delete config.allowedSelectors[config.allowedSelectorsList[i]];
        }
        delete config.allowedSelectorsList;

        // Clear blocked selectors
        for (uint256 i = 0; i < config.blockedSelectorsList.length; i++) {
            delete config.blockedSelectors[config.blockedSelectorsList[i]];
        }
        delete config.blockedSelectorsList;

        // Clear other config
        config.isAllowed = false;
        config.isBlocked = false;
        config.valueLimit = 0;
        config.strictSelectorMode = false;
    }

    function _removeFromArray(address[] storage arr, address item) internal {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == item) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }
    }

    function _removeSelector(bytes4[] storage arr, bytes4 item) internal {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == item) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }
    }
}
