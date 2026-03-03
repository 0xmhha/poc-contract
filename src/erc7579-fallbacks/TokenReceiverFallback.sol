// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IFallback, IModule } from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { MODULE_TYPE_FALLBACK } from "../erc7579-smartaccount/types/Constants.sol";

/**
 * @title TokenReceiverFallback
 * @notice ERC-7579 Fallback module for ERC-777 token receiver callbacks
 * @dev Handles token standards NOT natively supported by Kernel.
 *
 * Supported Interfaces:
 * - ERC-777: tokensReceived
 *
 * NOT supported (handled by Kernel built-in pure functions):
 * - ERC-721: onERC721Received — Kernel natively returns selector
 * - ERC-1155: onERC1155Received, onERC1155BatchReceived — Kernel natively returns selector
 *
 * Design Note:
 * Kernel (following ZeroDev upstream) declares onERC721Received/onERC1155Received/
 * onERC1155BatchReceived as explicit pure functions. Solidity dispatches explicit
 * functions before fallback(), so these selectors can never reach a fallback module.
 * This is intentional — it guarantees token reception safety regardless of module state.
 * See: https://github.com/zerodevapp/kernel (same pattern in all versions)
 *
 * Features:
 * - Token whitelist/blacklist per account (for ERC-777)
 * - Transfer logging for compliance
 * - Configurable acceptance rules
 */
contract TokenReceiverFallback is IFallback {
    /// @notice Configuration for each smart account
    struct AccountConfig {
        bool acceptAllTokens; // If true, accept all tokens (default behavior)
        bool logTransfers; // If true, emit events for transfers
        bool isEnabled;
    }

    /// @notice Transfer log entry
    struct TransferLog {
        uint256 timestamp;
        address token;
        address from;
        uint256 tokenId; // For ERC-721/1155
        uint256 amount; // For ERC-1155/777
        bytes32 dataHash;
    }

    /// @notice Storage for each smart account
    struct AccountStorage {
        AccountConfig config;
        mapping(address => bool) tokenWhitelist; // Tokens that are always accepted
        mapping(address => bool) tokenBlacklist; // Tokens that are always rejected
        TransferLog[] transferLogs;
    }

    /// @notice Account address => AccountStorage
    mapping(address => AccountStorage) internal accountStorage;

    // ERC-777 callback selector (only standard handled by this fallback)
    bytes4 private constant ERC777_TOKENS_RECEIVED = 0x00_23d_e29;

    // Events
    event TokenReceived(
        address indexed account,
        address indexed token,
        address indexed from,
        uint256 tokenId,
        uint256 amount,
        string tokenType
    );
    event TokenWhitelistUpdated(address indexed account, address indexed token, bool isWhitelisted);
    event TokenBlacklistUpdated(address indexed account, address indexed token, bool isBlacklisted);
    event ConfigUpdated(address indexed account, bool acceptAllTokens, bool logTransfers);
    event TokenRejected(address indexed account, address indexed token, string reason);

    // Errors
    error TokenBlacklisted(address token);
    error TokenNotWhitelisted(address token);
    error ModuleNotEnabled();

    // ============ IModule Implementation ============

    /// @inheritdoc IModule
    function onInstall(bytes calldata data) external payable override {
        if (data.length == 0) {
            // Default: accept all tokens, no logging
            accountStorage[msg.sender].config =
                AccountConfig({ acceptAllTokens: true, logTransfers: false, isEnabled: true });
        } else {
            (bool acceptAll, bool logTransfers) = abi.decode(data, (bool, bool));
            accountStorage[msg.sender].config =
                AccountConfig({ acceptAllTokens: acceptAll, logTransfers: logTransfers, isEnabled: true });
        }

        emit ConfigUpdated(
            msg.sender,
            accountStorage[msg.sender].config.acceptAllTokens,
            accountStorage[msg.sender].config.logTransfers
        );
    }

    /// @inheritdoc IModule
    function onUninstall(bytes calldata) external payable override {
        // Preserve transfer logs for historical purposes
        accountStorage[msg.sender].config.isEnabled = false;
    }

    /// @inheritdoc IModule
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_FALLBACK;
    }

    /// @inheritdoc IModule
    function isInitialized(address smartAccount) external view override returns (bool) {
        return accountStorage[smartAccount].config.isEnabled;
    }

    // ============ ERC-777 Receiver ============
    //
    // NOTE: ERC-721 and ERC-1155 handlers are intentionally NOT implemented here.
    // Kernel declares onERC721Received/onERC1155Received/onERC1155BatchReceived as
    // explicit pure functions, so those selectors never reach fallback(). This is a
    // deliberate design choice (matching ZeroDev upstream) that guarantees token
    // reception safety regardless of module installation state.

    /**
     * @notice Handle ERC-777 tokens received
     * @param from The address which previously owned the tokens
     * @param amount The amount of tokens transferred
     * @param userData Data provided by the user
     */
    function tokensReceived(address, address from, address, uint256 amount, bytes calldata userData, bytes calldata)
        external
    {
        (address token, address smartAccount) = _extractContext();

        _validateAndLogTransfer(smartAccount, token, from, 0, amount, userData, "ERC777");
    }

    // ============ Configuration Management ============

    /**
     * @notice Update account configuration
     * @param acceptAllTokens Whether to accept all tokens
     * @param logTransfers Whether to log transfers
     */
    function setConfig(bool acceptAllTokens, bool logTransfers) external {
        AccountStorage storage store = accountStorage[msg.sender];
        store.config.acceptAllTokens = acceptAllTokens;
        store.config.logTransfers = logTransfers;

        emit ConfigUpdated(msg.sender, acceptAllTokens, logTransfers);
    }

    /**
     * @notice Add token to whitelist
     * @param token Token address to whitelist
     */
    function addToWhitelist(address token) external {
        accountStorage[msg.sender].tokenWhitelist[token] = true;
        emit TokenWhitelistUpdated(msg.sender, token, true);
    }

    /**
     * @notice Remove token from whitelist
     * @param token Token address to remove
     */
    function removeFromWhitelist(address token) external {
        accountStorage[msg.sender].tokenWhitelist[token] = false;
        emit TokenWhitelistUpdated(msg.sender, token, false);
    }

    /**
     * @notice Add token to blacklist
     * @param token Token address to blacklist
     */
    function addToBlacklist(address token) external {
        accountStorage[msg.sender].tokenBlacklist[token] = true;
        emit TokenBlacklistUpdated(msg.sender, token, true);
    }

    /**
     * @notice Remove token from blacklist
     * @param token Token address to remove
     */
    function removeFromBlacklist(address token) external {
        accountStorage[msg.sender].tokenBlacklist[token] = false;
        emit TokenBlacklistUpdated(msg.sender, token, false);
    }

    /**
     * @notice Batch update whitelist
     * @param tokens Token addresses
     * @param whitelistFlags Whether each token is whitelisted
     */
    function batchUpdateWhitelist(address[] calldata tokens, bool[] calldata whitelistFlags) external {
        require(tokens.length == whitelistFlags.length, "Length mismatch");

        AccountStorage storage store = accountStorage[msg.sender];
        for (uint256 i = 0; i < tokens.length; i++) {
            store.tokenWhitelist[tokens[i]] = whitelistFlags[i];
            emit TokenWhitelistUpdated(msg.sender, tokens[i], whitelistFlags[i]);
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get account configuration
     * @param account The smart account address
     */
    function getConfig(address account) external view returns (AccountConfig memory) {
        return accountStorage[account].config;
    }

    /**
     * @notice Check if token is whitelisted
     * @param account The smart account address
     * @param token Token address to check
     */
    function isWhitelisted(address account, address token) external view returns (bool) {
        return accountStorage[account].tokenWhitelist[token];
    }

    /**
     * @notice Check if token is blacklisted
     * @param account The smart account address
     * @param token Token address to check
     */
    function isBlacklisted(address account, address token) external view returns (bool) {
        return accountStorage[account].tokenBlacklist[token];
    }

    /**
     * @notice Check if token will be accepted
     * @param account The smart account address
     * @param token Token address to check
     */
    function willAcceptToken(address account, address token) external view returns (bool, string memory reason) {
        AccountStorage storage store = accountStorage[account];

        if (!store.config.isEnabled) {
            return (false, "Module not enabled");
        }

        if (store.tokenBlacklist[token]) {
            return (false, "Token is blacklisted");
        }

        if (!store.config.acceptAllTokens && !store.tokenWhitelist[token]) {
            return (false, "Token not whitelisted");
        }

        return (true, "");
    }

    /**
     * @notice Get transfer log length
     * @param account The smart account address
     */
    function getTransferLogLength(address account) external view returns (uint256) {
        return accountStorage[account].transferLogs.length;
    }

    /**
     * @notice Get transfer log entry
     * @param account The smart account address
     * @param index Log index
     */
    function getTransferLog(address account, uint256 index) external view returns (TransferLog memory) {
        return accountStorage[account].transferLogs[index];
    }

    /**
     * @notice Get transfer logs in range
     * @param account The smart account address
     * @param startIndex Start index (inclusive)
     * @param endIndex End index (exclusive)
     */
    function getTransferLogs(address account, uint256 startIndex, uint256 endIndex)
        external
        view
        returns (TransferLog[] memory logs)
    {
        AccountStorage storage store = accountStorage[account];
        uint256 length = store.transferLogs.length;

        if (startIndex >= length) return new TransferLog[](0);
        if (endIndex > length) endIndex = length;

        logs = new TransferLog[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            logs[i - startIndex] = store.transferLogs[i];
        }
    }

    // ============ Internal Functions ============

    /**
     * @dev Extract context from ERC-2771 calldata
     * Kernel appends 20 bytes (original caller) per ERC-2771 standard.
     * msg.sender is the smart account (Kernel) that forwarded the call.
     * @return originalCaller The original msg.sender of the smart account (e.g., token contract)
     * @return smartAccount The smart account address (Kernel)
     */
    function _extractContext() internal view returns (address originalCaller, address smartAccount) {
        // msg.sender = Kernel (smart account) that called this fallback module
        smartAccount = msg.sender;
        assembly {
            // Last 20 bytes = original caller (appended by Kernel per ERC-2771)
            originalCaller := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }

    function _validateAndLogTransfer(
        address smartAccount,
        address token,
        address from,
        uint256 tokenId,
        uint256 amount,
        bytes calldata data,
        string memory tokenType
    ) internal {
        AccountStorage storage store = accountStorage[smartAccount];

        if (!store.config.isEnabled) revert ModuleNotEnabled();

        // Check blacklist
        if (store.tokenBlacklist[token]) {
            emit TokenRejected(smartAccount, token, "Token blacklisted");
            revert TokenBlacklisted(token);
        }

        // Check whitelist if not accepting all
        if (!store.config.acceptAllTokens && !store.tokenWhitelist[token]) {
            emit TokenRejected(smartAccount, token, "Token not whitelisted");
            revert TokenNotWhitelisted(token);
        }

        // Log transfer if enabled
        if (store.config.logTransfers) {
            _logTransfer(store, token, from, tokenId, amount, data);
            emit TokenReceived(smartAccount, token, from, tokenId, amount, tokenType);
        }
    }

    function _logTransfer(
        AccountStorage storage store,
        address token,
        address from,
        uint256 tokenId,
        uint256 amount,
        bytes calldata data
    ) internal {
        store.transferLogs
            .push(
                TransferLog({
                    timestamp: block.timestamp,
                    token: token,
                    from: from,
                    tokenId: tokenId,
                    amount: amount,
                    dataHash: keccak256(data)
                })
            );
    }
}
