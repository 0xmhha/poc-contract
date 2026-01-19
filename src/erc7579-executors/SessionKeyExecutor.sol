// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IExecutor, IModule} from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import {IERC7579Account} from "../erc7579-smartaccount/interfaces/IERC7579Account.sol";
import {MODULE_TYPE_EXECUTOR} from "../erc7579-smartaccount/types/Constants.sol";
import {ExecMode} from "../erc7579-smartaccount/types/Types.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

/**
 * @title SessionKeyExecutor
 * @notice ERC-7579 Executor module that enables delegated execution via session keys
 * @dev Allows smart account owners to grant limited execution permissions to session keys
 *
 * Features:
 * - Time-bounded sessions (validAfter, validUntil)
 * - Target contract restrictions
 * - Function selector whitelisting
 * - Value (ETH) spending limits per session
 * - Nonce-based replay protection
 *
 * Use Cases:
 * - Gaming: Allow game contracts to execute moves without user signatures
 * - DeFi: Automated trading within limits
 * - dApps: Seamless UX without constant wallet confirmations
 */
contract SessionKeyExecutor is IExecutor {
    using ECDSA for bytes32;

    /// @notice Session key configuration
    struct SessionKeyConfig {
        address sessionKey;
        uint48 validAfter;
        uint48 validUntil;
        uint256 spendingLimit;    // Max ETH that can be spent
        uint256 spentAmount;      // ETH already spent
        uint256 nonce;            // For replay protection
        bool isActive;
    }

    /// @notice Permission for a specific target and selector
    struct Permission {
        address target;
        bytes4 selector;
        uint256 maxValue;         // Max value per call (0 = unlimited for this call)
        bool allowed;
    }

    /// @notice Storage for each smart account
    struct AccountStorage {
        mapping(address sessionKey => SessionKeyConfig) sessions;
        mapping(address sessionKey => mapping(bytes32 permissionHash => Permission)) permissions;
        address[] activeSessionKeys;
    }

    /// @notice Account address => AccountStorage
    mapping(address => AccountStorage) internal accountStorage;

    // Events
    event SessionKeyAdded(
        address indexed account,
        address indexed sessionKey,
        uint48 validAfter,
        uint48 validUntil,
        uint256 spendingLimit
    );
    event SessionKeyRevoked(address indexed account, address indexed sessionKey);
    event PermissionGranted(
        address indexed account,
        address indexed sessionKey,
        address target,
        bytes4 selector
    );
    event PermissionRevoked(
        address indexed account,
        address indexed sessionKey,
        address target,
        bytes4 selector
    );
    event SessionKeyExecuted(
        address indexed account,
        address indexed sessionKey,
        address target,
        uint256 value,
        bytes4 selector
    );

    // Errors
    error SessionKeyNotActive();
    error SessionKeyExpired();
    error SessionKeyNotYetValid();
    error PermissionDenied();
    error SpendingLimitExceeded();
    error InvalidSignature();
    error InvalidNonce();
    error InvalidSessionKey();
    error SessionKeyAlreadyExists();

    // ============ IModule Implementation ============

    /// @inheritdoc IModule
    function onInstall(bytes calldata data) external payable override {
        if (data.length == 0) return;

        // Decode initial session key setup
        (
            address sessionKey,
            uint48 validAfter,
            uint48 validUntil,
            uint256 spendingLimit,
            bytes memory permissionsData
        ) = abi.decode(data, (address, uint48, uint48, uint256, bytes));

        _addSessionKey(msg.sender, sessionKey, validAfter, validUntil, spendingLimit);

        // Decode and add permissions if provided
        if (permissionsData.length > 0) {
            Permission[] memory perms = abi.decode(permissionsData, (Permission[]));
            for (uint256 i = 0; i < perms.length; i++) {
                _grantPermission(msg.sender, sessionKey, perms[i]);
            }
        }
    }

    /// @inheritdoc IModule
    function onUninstall(bytes calldata) external payable override {
        AccountStorage storage store = accountStorage[msg.sender];

        // Revoke all session keys
        address[] memory keys = store.activeSessionKeys;
        for (uint256 i = 0; i < keys.length; i++) {
            delete store.sessions[keys[i]];
        }
        delete store.activeSessionKeys;
    }

    /// @inheritdoc IModule
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    /// @inheritdoc IModule
    function isInitialized(address smartAccount) external view override returns (bool) {
        return accountStorage[smartAccount].activeSessionKeys.length > 0;
    }

    // ============ Session Key Management ============

    /**
     * @notice Add a new session key
     * @param sessionKey The session key address
     * @param validAfter Timestamp when session becomes valid
     * @param validUntil Timestamp when session expires
     * @param spendingLimit Maximum ETH that can be spent
     */
    function addSessionKey(
        address sessionKey,
        uint48 validAfter,
        uint48 validUntil,
        uint256 spendingLimit
    ) external {
        _addSessionKey(msg.sender, sessionKey, validAfter, validUntil, spendingLimit);
    }

    /**
     * @notice Revoke a session key
     * @param sessionKey The session key to revoke
     */
    function revokeSessionKey(address sessionKey) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (!store.sessions[sessionKey].isActive) {
            revert SessionKeyNotActive();
        }

        store.sessions[sessionKey].isActive = false;

        // Remove from active list
        _removeFromActiveList(msg.sender, sessionKey);

        emit SessionKeyRevoked(msg.sender, sessionKey);
    }

    /**
     * @notice Grant permission to a session key
     * @param sessionKey The session key
     * @param target Target contract address
     * @param selector Function selector (bytes4(0) for any selector)
     * @param maxValue Maximum value per call
     */
    function grantPermission(
        address sessionKey,
        address target,
        bytes4 selector,
        uint256 maxValue
    ) external {
        Permission memory perm = Permission({
            target: target,
            selector: selector,
            maxValue: maxValue,
            allowed: true
        });
        _grantPermission(msg.sender, sessionKey, perm);
    }

    /**
     * @notice Revoke permission from a session key
     * @param sessionKey The session key
     * @param target Target contract address
     * @param selector Function selector
     */
    function revokePermission(
        address sessionKey,
        address target,
        bytes4 selector
    ) external {
        AccountStorage storage store = accountStorage[msg.sender];
        bytes32 permHash = _getPermissionHash(target, selector);

        store.permissions[sessionKey][permHash].allowed = false;

        emit PermissionRevoked(msg.sender, sessionKey, target, selector);
    }

    // ============ Execution ============

    /**
     * @notice Execute a call on behalf of a smart account
     * @param account The smart account to execute from
     * @param target Target contract
     * @param value ETH value to send
     * @param data Call data
     * @param signature Session key signature over the execution params
     */
    function executeOnBehalf(
        address account,
        address target,
        uint256 value,
        bytes calldata data,
        bytes calldata signature
    ) external returns (bytes[] memory) {
        AccountStorage storage store = accountStorage[account];

        // Recover signer from signature
        bytes32 execHash = _getExecutionHash(account, target, value, data, store.sessions[msg.sender].nonce);
        address signer = execHash.toEthSignedMessageHash().recover(signature);

        // Validate session key
        SessionKeyConfig storage session = store.sessions[signer];
        _validateSession(session);

        // Validate permission
        bytes4 selector = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
        _validatePermission(store, signer, target, selector, value);

        // Update spending
        if (value > 0) {
            if (session.spentAmount + value > session.spendingLimit) {
                revert SpendingLimitExceeded();
            }
            session.spentAmount += value;
        }

        // Increment nonce
        session.nonce++;

        // Execute via smart account
        bytes memory execData = abi.encodePacked(target, value, data);
        ExecMode execMode = _encodeExecMode();

        emit SessionKeyExecuted(account, signer, target, value, selector);

        return IERC7579Account(account).executeFromExecutor(execMode, execData);
    }

    /**
     * @notice Execute with direct session key call (session key is msg.sender)
     * @param account The smart account to execute from
     * @param target Target contract
     * @param value ETH value to send
     * @param data Call data
     */
    function executeAsSessionKey(
        address account,
        address target,
        uint256 value,
        bytes calldata data
    ) external returns (bytes[] memory) {
        AccountStorage storage store = accountStorage[account];
        SessionKeyConfig storage session = store.sessions[msg.sender];

        // Validate session key
        _validateSession(session);

        // Validate permission
        bytes4 selector = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
        _validatePermission(store, msg.sender, target, selector, value);

        // Update spending
        if (value > 0) {
            if (session.spentAmount + value > session.spendingLimit) {
                revert SpendingLimitExceeded();
            }
            session.spentAmount += value;
        }

        // Increment nonce
        session.nonce++;

        // Execute via smart account
        bytes memory execData = abi.encodePacked(target, value, data);
        ExecMode execMode = _encodeExecMode();

        emit SessionKeyExecuted(account, msg.sender, target, value, selector);

        return IERC7579Account(account).executeFromExecutor(execMode, execData);
    }

    // ============ View Functions ============

    /**
     * @notice Get session key configuration
     * @param account The smart account
     * @param sessionKey The session key address
     */
    function getSessionKey(
        address account,
        address sessionKey
    ) external view returns (SessionKeyConfig memory) {
        return accountStorage[account].sessions[sessionKey];
    }

    /**
     * @notice Check if a session key has permission
     * @param account The smart account
     * @param sessionKey The session key
     * @param target Target contract
     * @param selector Function selector
     */
    function hasPermission(
        address account,
        address sessionKey,
        address target,
        bytes4 selector
    ) external view returns (bool) {
        AccountStorage storage store = accountStorage[account];
        bytes32 permHash = _getPermissionHash(target, selector);
        bytes32 wildcardHash = _getPermissionHash(target, bytes4(0));

        return store.permissions[sessionKey][permHash].allowed ||
               store.permissions[sessionKey][wildcardHash].allowed;
    }

    /**
     * @notice Get all active session keys for an account
     * @param account The smart account
     */
    function getActiveSessionKeys(address account) external view returns (address[] memory) {
        return accountStorage[account].activeSessionKeys;
    }

    /**
     * @notice Get remaining spending limit
     * @param account The smart account
     * @param sessionKey The session key
     */
    function getRemainingSpendingLimit(
        address account,
        address sessionKey
    ) external view returns (uint256) {
        SessionKeyConfig storage session = accountStorage[account].sessions[sessionKey];
        if (session.spendingLimit <= session.spentAmount) return 0;
        return session.spendingLimit - session.spentAmount;
    }

    // ============ Internal Functions ============

    function _addSessionKey(
        address account,
        address sessionKey,
        uint48 validAfter,
        uint48 validUntil,
        uint256 spendingLimit
    ) internal {
        if (sessionKey == address(0)) revert InvalidSessionKey();

        AccountStorage storage store = accountStorage[account];

        if (store.sessions[sessionKey].isActive) {
            revert SessionKeyAlreadyExists();
        }

        store.sessions[sessionKey] = SessionKeyConfig({
            sessionKey: sessionKey,
            validAfter: validAfter,
            validUntil: validUntil,
            spendingLimit: spendingLimit,
            spentAmount: 0,
            nonce: 0,
            isActive: true
        });

        store.activeSessionKeys.push(sessionKey);

        emit SessionKeyAdded(account, sessionKey, validAfter, validUntil, spendingLimit);
    }

    function _grantPermission(
        address account,
        address sessionKey,
        Permission memory perm
    ) internal {
        AccountStorage storage store = accountStorage[account];
        bytes32 permHash = _getPermissionHash(perm.target, perm.selector);

        store.permissions[sessionKey][permHash] = perm;

        emit PermissionGranted(account, sessionKey, perm.target, perm.selector);
    }

    function _validateSession(SessionKeyConfig storage session) internal view {
        if (!session.isActive) revert SessionKeyNotActive();
        if (block.timestamp < session.validAfter) revert SessionKeyNotYetValid();
        if (block.timestamp > session.validUntil) revert SessionKeyExpired();
    }

    function _validatePermission(
        AccountStorage storage store,
        address sessionKey,
        address target,
        bytes4 selector,
        uint256 value
    ) internal view {
        bytes32 permHash = _getPermissionHash(target, selector);
        bytes32 wildcardHash = _getPermissionHash(target, bytes4(0));

        Permission storage perm = store.permissions[sessionKey][permHash];
        Permission storage wildcardPerm = store.permissions[sessionKey][wildcardHash];

        bool hasExactPermission = perm.allowed;
        bool hasWildcardPermission = wildcardPerm.allowed;

        if (!hasExactPermission && !hasWildcardPermission) {
            revert PermissionDenied();
        }

        // Check max value
        Permission storage activePerm = hasExactPermission ? perm : wildcardPerm;
        if (activePerm.maxValue > 0 && value > activePerm.maxValue) {
            revert SpendingLimitExceeded();
        }
    }

    function _removeFromActiveList(address account, address sessionKey) internal {
        AccountStorage storage store = accountStorage[account];
        uint256 length = store.activeSessionKeys.length;

        for (uint256 i = 0; i < length; i++) {
            if (store.activeSessionKeys[i] == sessionKey) {
                store.activeSessionKeys[i] = store.activeSessionKeys[length - 1];
                store.activeSessionKeys.pop();
                break;
            }
        }
    }

    function _getPermissionHash(address target, bytes4 selector) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(target, selector));
    }

    function _getExecutionHash(
        address account,
        address target,
        uint256 value,
        bytes calldata data,
        uint256 nonce
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            block.chainid,
            address(this),
            account,
            target,
            value,
            data,
            nonce
        ));
    }

    function _encodeExecMode() internal pure returns (ExecMode) {
        // Single call, default exec type
        return ExecMode.wrap(bytes32(0));
    }
}
