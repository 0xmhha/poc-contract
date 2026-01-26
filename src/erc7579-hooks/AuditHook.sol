// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IHook } from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { MODULE_TYPE_HOOK } from "../erc7579-smartaccount/types/Constants.sol";

/**
 * @title AuditHook
 * @notice ERC-7579 Hook module for comprehensive transaction auditing
 * @dev Logs all transactions for compliance and audit purposes
 *
 * Features:
 * - Complete transaction logging with timestamps
 * - Operation categorization (transfer, call, delegatecall)
 * - High-value transaction flagging
 * - Optional delay for flagged transactions
 * - Blocklist for restricted addresses
 * - Audit trail accessible on-chain
 *
 * Use Cases:
 * - Regulatory compliance
 * - Corporate governance
 * - Security monitoring
 * - Forensic analysis
 */
contract AuditHook is IHook {
    /// @notice Audit log entry
    struct AuditEntry {
        uint256 timestamp;
        address sender;
        address target;
        uint256 value;
        bytes4 selector;
        bytes32 dataHash;
        bool isFlagged;
        bool isExecuted;
    }

    /// @notice Configuration for each smart account
    struct AccountConfig {
        uint256 highValueThreshold; // Value above which transactions are flagged
        uint256 flaggedDelay; // Required delay for flagged transactions (0 = no delay)
        bool isEnabled;
    }

    /// @notice Storage for each smart account
    struct AccountStorage {
        AccountConfig config;
        AuditEntry[] auditLog;
        mapping(address => bool) blocklist;
        mapping(bytes32 => uint256) pendingExecutions; // txHash => timestamp when allowed
        uint256 totalTransactions;
        uint256 totalValueTransferred;
        uint256 flaggedCount;
    }

    /// @notice Account address => AccountStorage
    mapping(address => AccountStorage) internal accountStorage;

    // Events
    event TransactionLogged(
        address indexed account,
        uint256 indexed logIndex,
        address indexed target,
        uint256 value,
        bytes4 selector,
        bool isFlagged
    );
    event TransactionFlagged(address indexed account, bytes32 indexed txHash, uint256 allowedAfter);
    event BlocklistUpdated(address indexed account, address indexed target, bool isBlocked);
    event ConfigUpdated(address indexed account, uint256 highValueThreshold, uint256 flaggedDelay);
    event TransactionBlocked(address indexed account, address indexed target, string reason);
    event TransactionQueued(address indexed account, bytes32 indexed txHash, uint256 allowedAfter);

    // Errors
    error AddressBlocked(address target);
    error TransactionPending(bytes32 txHash, uint256 allowedAfter);
    error TransactionNotQueued(bytes32 txHash);
    error ModuleNotEnabled();
    error InvalidThreshold();

    // ============ IModule Implementation ============

    /// @notice Called when the module is installed
    function onInstall(bytes calldata data) external payable override {
        if (data.length == 0) {
            // Default configuration
            accountStorage[msg.sender].config =
                AccountConfig({ highValueThreshold: 1 ether, flaggedDelay: 0, isEnabled: true });
        } else {
            (uint256 threshold, uint256 delay) = abi.decode(data, (uint256, uint256));
            accountStorage[msg.sender].config =
                AccountConfig({ highValueThreshold: threshold, flaggedDelay: delay, isEnabled: true });
        }

        emit ConfigUpdated(
            msg.sender,
            accountStorage[msg.sender].config.highValueThreshold,
            accountStorage[msg.sender].config.flaggedDelay
        );
    }

    /// @notice Called when the module is uninstalled
    function onUninstall(bytes calldata) external payable override {
        // Note: Audit log is preserved for historical purposes
        accountStorage[msg.sender].config.isEnabled = false;
    }

    /// @notice Returns true if this is a Hook module
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_HOOK;
    }

    /// @notice Returns true if the module is initialized for the account
    function isInitialized(address smartAccount) external view override returns (bool) {
        return accountStorage[smartAccount].config.isEnabled;
    }

    // ============ IHook Implementation ============

    /**
     * @notice Pre-execution check - logs transaction and checks restrictions
     * @param msgSender The original sender
     * @param msgValue ETH value being sent
     * @param msgData The calldata being executed
     * @return hookData Encoded audit entry index
     */
    function preCheck(address msgSender, uint256 msgValue, bytes calldata msgData)
        external
        payable
        override
        returns (bytes memory hookData)
    {
        AccountStorage storage store = accountStorage[msg.sender];

        if (!store.config.isEnabled) revert ModuleNotEnabled();

        // Extract target address
        address target = address(0);
        bytes4 selector = bytes4(0);

        if (msgData.length >= 20) {
            target = address(bytes20(msgData[0:20]));
        }
        if (msgData.length >= 56) {
            selector = bytes4(msgData[52:56]);
        }

        // Check blocklist
        if (store.blocklist[target]) {
            emit TransactionBlocked(msg.sender, target, "Address is blocked");
            revert AddressBlocked(target);
        }

        // Check if flagged transaction
        bool isFlagged = msgValue >= store.config.highValueThreshold;

        // Check pending delay for flagged transactions
        if (isFlagged && store.config.flaggedDelay > 0) {
            bytes32 txHash = _getTxHash(msg.sender, target, msgValue, msgData);
            uint256 allowedAfter = store.pendingExecutions[txHash];

            if (allowedAfter == 0) {
                // Transaction not queued - must call queueFlaggedTransaction first
                revert TransactionNotQueued(txHash);
            } else if (block.timestamp < allowedAfter) {
                revert TransactionPending(txHash, allowedAfter);
            }
            // Clear pending status
            delete store.pendingExecutions[txHash];
        }

        // Create audit entry
        uint256 logIndex = store.auditLog.length;
        store.auditLog
        .push(
            AuditEntry({
                timestamp: block.timestamp,
                sender: msgSender,
                target: target,
                value: msgValue,
                selector: selector,
                dataHash: keccak256(msgData),
                isFlagged: isFlagged,
                isExecuted: false
            })
        );

        // Update statistics
        store.totalTransactions++;
        if (isFlagged) {
            store.flaggedCount++;
        }

        emit TransactionLogged(msg.sender, logIndex, target, msgValue, selector, isFlagged);

        return abi.encode(logIndex);
    }

    /**
     * @notice Post-execution check - marks transaction as executed
     * @param hookData Encoded audit entry index from preCheck
     */
    function postCheck(bytes calldata hookData) external payable override {
        if (hookData.length == 0) return;

        uint256 logIndex = abi.decode(hookData, (uint256));
        AccountStorage storage store = accountStorage[msg.sender];

        if (logIndex < store.auditLog.length) {
            AuditEntry storage entry = store.auditLog[logIndex];
            entry.isExecuted = true;

            // Update total value transferred
            store.totalValueTransferred += entry.value;
        }
    }

    // ============ Configuration Management ============

    /**
     * @notice Update configuration
     * @param highValueThreshold New threshold for flagging
     * @param flaggedDelay New delay for flagged transactions
     */
    function setConfig(uint256 highValueThreshold, uint256 flaggedDelay) external {
        if (highValueThreshold == 0) revert InvalidThreshold();

        AccountStorage storage store = accountStorage[msg.sender];
        store.config.highValueThreshold = highValueThreshold;
        store.config.flaggedDelay = flaggedDelay;

        emit ConfigUpdated(msg.sender, highValueThreshold, flaggedDelay);
    }

    /**
     * @notice Update blocklist
     * @param target Address to block/unblock
     * @param blocked Whether to block
     */
    function setBlocklist(address target, bool blocked) external {
        accountStorage[msg.sender].blocklist[target] = blocked;
        emit BlocklistUpdated(msg.sender, target, blocked);
    }

    /**
     * @notice Batch update blocklist
     * @param targets Addresses to update
     * @param blockedStatuses Whether to block each address
     */
    function setBlocklistBatch(address[] calldata targets, bool[] calldata blockedStatuses) external {
        require(targets.length == blockedStatuses.length, "Length mismatch");

        AccountStorage storage store = accountStorage[msg.sender];
        for (uint256 i = 0; i < targets.length; i++) {
            store.blocklist[targets[i]] = blockedStatuses[i];
            emit BlocklistUpdated(msg.sender, targets[i], blockedStatuses[i]);
        }
    }

    /**
     * @notice Queue a flagged transaction for delayed execution
     * @dev Must be called before preCheck for high-value transactions when delay is configured
     * @param target Target address
     * @param value Transaction value
     * @param data Transaction data
     */
    function queueFlaggedTransaction(address target, uint256 value, bytes calldata data) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (!store.config.isEnabled) revert ModuleNotEnabled();

        // Only queue if this would be a flagged transaction
        if (value >= store.config.highValueThreshold && store.config.flaggedDelay > 0) {
            bytes32 txHash = _getTxHash(msg.sender, target, value, data);

            // Only set if not already queued
            if (store.pendingExecutions[txHash] == 0) {
                store.pendingExecutions[txHash] = block.timestamp + store.config.flaggedDelay;
                emit TransactionQueued(msg.sender, txHash, block.timestamp + store.config.flaggedDelay);
            }
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get account configuration
     * @param account The smart account
     */
    function getConfig(address account) external view returns (AccountConfig memory) {
        return accountStorage[account].config;
    }

    /**
     * @notice Get audit log entry
     * @param account The smart account
     * @param index Log index
     */
    function getAuditEntry(address account, uint256 index) external view returns (AuditEntry memory) {
        return accountStorage[account].auditLog[index];
    }

    /**
     * @notice Get total audit log entries
     * @param account The smart account
     */
    function getAuditLogLength(address account) external view returns (uint256) {
        return accountStorage[account].auditLog.length;
    }

    /**
     * @notice Get audit entries in range
     * @param account The smart account
     * @param startIndex Start index (inclusive)
     * @param endIndex End index (exclusive)
     */
    function getAuditEntries(address account, uint256 startIndex, uint256 endIndex)
        external
        view
        returns (AuditEntry[] memory entries)
    {
        AccountStorage storage store = accountStorage[account];
        uint256 length = store.auditLog.length;

        if (startIndex >= length) return new AuditEntry[](0);
        if (endIndex > length) endIndex = length;

        entries = new AuditEntry[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            entries[i - startIndex] = store.auditLog[i];
        }
    }

    /**
     * @notice Get account statistics
     * @param account The smart account
     */
    function getStatistics(address account)
        external
        view
        returns (uint256 totalTransactions, uint256 totalValueTransferred, uint256 flaggedCount, uint256 pendingCount)
    {
        AccountStorage storage store = accountStorage[account];
        return (
            store.totalTransactions,
            store.totalValueTransferred,
            store.flaggedCount,
            0 // Pending count would require iteration, skipped for gas efficiency
        );
    }

    /**
     * @notice Check if address is blocked
     * @param account The smart account
     * @param target Address to check
     */
    function isBlocked(address account, address target) external view returns (bool) {
        return accountStorage[account].blocklist[target];
    }

    /**
     * @notice Get pending execution time for a transaction
     * @param account The smart account
     * @param target Target address
     * @param value Value
     * @param data Calldata
     */
    function getPendingExecutionTime(address account, address target, uint256 value, bytes calldata data)
        external
        view
        returns (uint256)
    {
        bytes32 txHash = _getTxHash(account, target, value, data);
        return accountStorage[account].pendingExecutions[txHash];
    }

    /**
     * @notice Check if transaction can be executed now
     * @param account The smart account
     * @param target Target address
     * @param value Value
     * @param data Calldata
     */
    function canExecute(address account, address target, uint256 value, bytes calldata data)
        external
        view
        returns (bool, string memory reason)
    {
        AccountStorage storage store = accountStorage[account];

        if (!store.config.isEnabled) {
            return (false, "Module not enabled");
        }

        if (store.blocklist[target]) {
            return (false, "Target is blocked");
        }

        if (value >= store.config.highValueThreshold && store.config.flaggedDelay > 0) {
            bytes32 txHash = _getTxHash(account, target, value, data);
            uint256 allowedAfter = store.pendingExecutions[txHash];

            if (allowedAfter == 0) {
                return (false, "Transaction needs to be submitted first");
            }
            if (block.timestamp < allowedAfter) {
                return (false, "Transaction is still pending");
            }
        }

        return (true, "");
    }

    // ============ Internal Functions ============

    function _getTxHash(address account, address target, uint256 value, bytes calldata data)
        internal
        pure
        returns (bytes32)
    {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encodePacked(account, target, value, data));
    }
}
