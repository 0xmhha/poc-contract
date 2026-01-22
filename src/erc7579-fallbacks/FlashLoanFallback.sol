// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFallback, IModule} from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import {MODULE_TYPE_FALLBACK} from "../erc7579-smartaccount/types/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title FlashLoanFallback
 * @notice ERC-7579 Fallback module for flash loan callbacks
 * @dev Implements various flash loan protocol callbacks
 *
 * Supported Protocols:
 * - AAVE v3: executeOperation
 * - Uniswap v3: uniswapV3FlashCallback
 * - Balancer: receiveFlashLoan
 * - ERC-3156: onFlashLoan
 *
 * Features:
 * - Protocol whitelist for security
 * - Custom callback execution
 * - Flash loan logging
 * - Automatic repayment handling
 *
 * Use Cases:
 * - Arbitrage strategies
 * - Liquidations
 * - Collateral swaps
 * - Leverage/deleverage operations
 */
contract FlashLoanFallback is IFallback {
    using SafeERC20 for IERC20;

    /// @notice Configuration for each smart account
    struct AccountConfig {
        bool requireWhitelistedProtocol;  // Only allow whitelisted protocols
        bool logFlashLoans;               // Log all flash loan operations
        bool isEnabled;
    }

    /// @notice Flash loan callback data
    struct FlashLoanCallback {
        address target;        // Contract to call
        bytes callData;        // Data to execute
        bool executeAfterRepay; // Execute after repayment (for post-callbacks)
    }

    /// @notice Flash loan log entry
    struct FlashLoanLog {
        uint256 timestamp;
        address protocol;
        address[] tokens;
        uint256[] amounts;
        uint256[] premiums;
        bytes32 initiatorHash;
        bool success;
    }

    /// @notice Storage for each smart account
    struct AccountStorage {
        AccountConfig config;
        mapping(address => bool) protocolWhitelist;  // Whitelisted flash loan providers
        mapping(bytes32 => FlashLoanCallback) callbacks;  // Pending callbacks by hash
        FlashLoanLog[] flashLoanLogs;
    }

    /// @notice Account address => AccountStorage
    mapping(address => AccountStorage) internal accountStorage;

    // ERC-3156 callback return value
    bytes32 private constant ERC3156_CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // Events
    event FlashLoanExecuted(
        address indexed account,
        address indexed protocol,
        address[] tokens,
        uint256[] amounts,
        uint256[] premiums
    );
    event ProtocolWhitelistUpdated(address indexed account, address indexed protocol, bool isWhitelisted);
    event ConfigUpdated(address indexed account, bool requireWhitelist, bool logFlashLoans);
    event CallbackRegistered(address indexed account, bytes32 indexed callbackId);
    event FlashLoanFailed(address indexed account, address indexed protocol, string reason);

    // Errors
    error ProtocolNotWhitelisted(address protocol);
    error ModuleNotEnabled();
    error CallbackNotRegistered(bytes32 callbackId);
    error RepaymentFailed();
    error InvalidInitiator();

    // ============ IModule Implementation ============

    /// @inheritdoc IModule
    function onInstall(bytes calldata data) external payable override {
        if (data.length == 0) {
            // Default: require whitelist, log enabled
            accountStorage[msg.sender].config = AccountConfig({
                requireWhitelistedProtocol: true,
                logFlashLoans: true,
                isEnabled: true
            });
        } else {
            (bool requireWhitelist, bool logFlashLoans) = abi.decode(data, (bool, bool));
            accountStorage[msg.sender].config = AccountConfig({
                requireWhitelistedProtocol: requireWhitelist,
                logFlashLoans: logFlashLoans,
                isEnabled: true
            });
        }

        emit ConfigUpdated(
            msg.sender,
            accountStorage[msg.sender].config.requireWhitelistedProtocol,
            accountStorage[msg.sender].config.logFlashLoans
        );
    }

    /// @inheritdoc IModule
    function onUninstall(bytes calldata) external payable override {
        // Preserve logs for historical purposes
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

    // ============ AAVE v3 Callback ============

    /**
     * @notice AAVE v3 flash loan callback
     * @param assets Array of borrowed assets
     * @param amounts Array of borrowed amounts
     * @param premiums Array of premiums (fees)
     * @param initiator The address that initiated the flash loan
     * @param params Encoded parameters for the operation
     * @return bool True if the operation was successful
     */
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        (address protocol, address smartAccount) = _extractContext();

        _validateProtocol(smartAccount, protocol);

        // Decode and execute callback
        if (params.length > 0) {
            _executeCallback(smartAccount, params);
        }

        // Approve repayment to AAVE pool
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 amountOwing = amounts[i] + premiums[i];
            IERC20(assets[i]).approve(protocol, amountOwing);
        }

        // Log flash loan
        _logFlashLoan(smartAccount, protocol, assets, amounts, premiums, initiator, true);

        return true;
    }

    // ============ Uniswap v3 Callback ============

    /**
     * @notice Uniswap v3 flash loan callback
     * @param fee0 Fee amount for token0
     * @param fee1 Fee amount for token1
     * @param data Encoded parameters for the operation
     */
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external {
        (address protocol, address smartAccount) = _extractContext();

        _validateProtocol(smartAccount, protocol);

        // Decode callback data
        (
            address token0,
            address token1,
            uint256 amount0,
            uint256 amount1,
            bytes memory callbackData
        ) = abi.decode(data, (address, address, uint256, uint256, bytes));

        // Execute callback if provided
        if (callbackData.length > 0) {
            _executeCallback(smartAccount, callbackData);
        }

        // Repay flash loan
        if (amount0 > 0) {
            IERC20(token0).safeTransfer(protocol, amount0 + fee0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransfer(protocol, amount1 + fee1);
        }

        // Log flash loan
        address[] memory tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;
        uint256[] memory premiums = new uint256[](2);
        premiums[0] = fee0;
        premiums[1] = fee1;

        _logFlashLoan(smartAccount, protocol, tokens, amounts, premiums, smartAccount, true);
    }

    // ============ Balancer Callback ============

    /**
     * @notice Balancer flash loan callback
     * @param tokens Array of borrowed tokens
     * @param amounts Array of borrowed amounts
     * @param feeAmounts Array of fee amounts
     * @param userData Encoded parameters for the operation
     */
    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external {
        (address protocol, address smartAccount) = _extractContext();

        _validateProtocol(smartAccount, protocol);

        // Execute callback if provided
        if (userData.length > 0) {
            _executeCallback(smartAccount, userData);
        }

        // Repay flash loan
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).safeTransfer(protocol, amounts[i] + feeAmounts[i]);
        }

        // Log flash loan
        _logFlashLoan(smartAccount, protocol, tokens, amounts, feeAmounts, smartAccount, true);
    }

    // ============ ERC-3156 Callback ============

    /**
     * @notice ERC-3156 flash loan callback
     * @param initiator The address that initiated the flash loan
     * @param token The borrowed token
     * @param amount The borrowed amount
     * @param fee The fee amount
     * @param data Encoded parameters for the operation
     * @return bytes32 The callback success value
     */
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        (address protocol, address smartAccount) = _extractContext();

        _validateProtocol(smartAccount, protocol);

        // Execute callback if provided
        if (data.length > 0) {
            _executeCallback(smartAccount, data);
        }

        // Approve repayment to lender
        IERC20(token).approve(protocol, amount + fee);

        // Log flash loan
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = fee;

        _logFlashLoan(smartAccount, protocol, tokens, amounts, premiums, initiator, true);

        return ERC3156_CALLBACK_SUCCESS;
    }

    // ============ Configuration Management ============

    /**
     * @notice Update account configuration
     * @param requireWhitelist Whether to require whitelisted protocols
     * @param logFlashLoans Whether to log flash loans
     */
    function setConfig(bool requireWhitelist, bool logFlashLoans) external {
        AccountStorage storage store = accountStorage[msg.sender];
        store.config.requireWhitelistedProtocol = requireWhitelist;
        store.config.logFlashLoans = logFlashLoans;

        emit ConfigUpdated(msg.sender, requireWhitelist, logFlashLoans);
    }

    /**
     * @notice Add protocol to whitelist
     * @param protocol Protocol address to whitelist
     */
    function addToWhitelist(address protocol) external {
        accountStorage[msg.sender].protocolWhitelist[protocol] = true;
        emit ProtocolWhitelistUpdated(msg.sender, protocol, true);
    }

    /**
     * @notice Remove protocol from whitelist
     * @param protocol Protocol address to remove
     */
    function removeFromWhitelist(address protocol) external {
        accountStorage[msg.sender].protocolWhitelist[protocol] = false;
        emit ProtocolWhitelistUpdated(msg.sender, protocol, false);
    }

    /**
     * @notice Batch update whitelist
     * @param protocols Protocol addresses
     * @param whitelistFlags Whether each protocol is whitelisted
     */
    function batchUpdateWhitelist(address[] calldata protocols, bool[] calldata whitelistFlags) external {
        require(protocols.length == whitelistFlags.length, "Length mismatch");

        AccountStorage storage store = accountStorage[msg.sender];
        for (uint256 i = 0; i < protocols.length; i++) {
            store.protocolWhitelist[protocols[i]] = whitelistFlags[i];
            emit ProtocolWhitelistUpdated(msg.sender, protocols[i], whitelistFlags[i]);
        }
    }

    /**
     * @notice Register a callback for flash loan execution
     * @param callbackId Unique identifier for the callback
     * @param target Contract to call
     * @param callData Data to execute
     * @param executeAfterRepay Whether to execute after repayment
     */
    function registerCallback(
        bytes32 callbackId,
        address target,
        bytes calldata callData,
        bool executeAfterRepay
    ) external {
        accountStorage[msg.sender].callbacks[callbackId] = FlashLoanCallback({
            target: target,
            callData: callData,
            executeAfterRepay: executeAfterRepay
        });

        emit CallbackRegistered(msg.sender, callbackId);
    }

    /**
     * @notice Clear a registered callback
     * @param callbackId Callback identifier to clear
     */
    function clearCallback(bytes32 callbackId) external {
        delete accountStorage[msg.sender].callbacks[callbackId];
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
     * @notice Check if protocol is whitelisted
     * @param account The smart account address
     * @param protocol Protocol address to check
     */
    function isWhitelisted(address account, address protocol) external view returns (bool) {
        return accountStorage[account].protocolWhitelist[protocol];
    }

    /**
     * @notice Check if protocol will be accepted
     * @param account The smart account address
     * @param protocol Protocol address to check
     */
    function willAcceptProtocol(address account, address protocol) external view returns (bool, string memory reason) {
        AccountStorage storage store = accountStorage[account];

        if (!store.config.isEnabled) {
            return (false, "Module not enabled");
        }

        if (store.config.requireWhitelistedProtocol && !store.protocolWhitelist[protocol]) {
            return (false, "Protocol not whitelisted");
        }

        return (true, "");
    }

    /**
     * @notice Get registered callback
     * @param account The smart account address
     * @param callbackId Callback identifier
     */
    function getCallback(address account, bytes32 callbackId) external view returns (FlashLoanCallback memory) {
        return accountStorage[account].callbacks[callbackId];
    }

    /**
     * @notice Get flash loan log length
     * @param account The smart account address
     */
    function getFlashLoanLogLength(address account) external view returns (uint256) {
        return accountStorage[account].flashLoanLogs.length;
    }

    /**
     * @notice Get flash loan log entry
     * @param account The smart account address
     * @param index Log index
     */
    function getFlashLoanLog(address account, uint256 index) external view returns (FlashLoanLog memory) {
        return accountStorage[account].flashLoanLogs[index];
    }

    /**
     * @notice Get flash loan logs in range
     * @param account The smart account address
     * @param startIndex Start index (inclusive)
     * @param endIndex End index (exclusive)
     */
    function getFlashLoanLogs(
        address account,
        uint256 startIndex,
        uint256 endIndex
    ) external view returns (FlashLoanLog[] memory logs) {
        AccountStorage storage store = accountStorage[account];
        uint256 length = store.flashLoanLogs.length;

        if (startIndex >= length) return new FlashLoanLog[](0);
        if (endIndex > length) endIndex = length;

        logs = new FlashLoanLog[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            logs[i - startIndex] = store.flashLoanLogs[i];
        }
    }

    // ============ Internal Functions ============

    /**
     * @dev Extract context from extended ERC-2771 calldata
     * The smart account appends 40 bytes: [original_caller:20][smart_account:20]
     * @return originalCaller The original msg.sender of the smart account (e.g., flash loan provider)
     * @return smartAccount The smart account address
     */
    function _extractContext() internal pure returns (address originalCaller, address smartAccount) {
        assembly {
            // Last 20 bytes = smart account
            smartAccount := shr(96, calldataload(sub(calldatasize(), 20)))
            // Previous 20 bytes = original caller (protocol)
            originalCaller := shr(96, calldataload(sub(calldatasize(), 40)))
        }
    }

    /**
     * @dev Extract only the smart account from ERC-2771 context (backwards compatible)
     */
    function _extractMsgSender() internal pure returns (address sender) {
        assembly {
            sender := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }

    function _validateProtocol(address smartAccount, address protocol) internal view {
        AccountStorage storage store = accountStorage[smartAccount];

        if (!store.config.isEnabled) revert ModuleNotEnabled();

        if (store.config.requireWhitelistedProtocol && !store.protocolWhitelist[protocol]) {
            revert ProtocolNotWhitelisted(protocol);
        }
    }

    function _executeCallback(address smartAccount, bytes memory data) internal {
        // Check if this is a callback ID or raw call data
        if (data.length == 32) {
            bytes32 callbackId = abi.decode(data, (bytes32));
            FlashLoanCallback storage callback = accountStorage[smartAccount].callbacks[callbackId];

            if (callback.target == address(0)) revert CallbackNotRegistered(callbackId);

            (bool success,) = callback.target.call(callback.callData);
            if (!success) revert RepaymentFailed();
        } else if (data.length > 0) {
            // Decode as direct call (target, callData)
            (address target, bytes memory callData) = abi.decode(data, (address, bytes));
            if (target != address(0)) {
                (bool success,) = target.call(callData);
                if (!success) revert RepaymentFailed();
            }
        }
    }

    function _logFlashLoan(
        address smartAccount,
        address protocol,
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory premiums,
        address initiator,
        bool success
    ) internal {
        AccountStorage storage store = accountStorage[smartAccount];

        if (store.config.logFlashLoans) {
            store.flashLoanLogs.push(FlashLoanLog({
                timestamp: block.timestamp,
                protocol: protocol,
                tokens: tokens,
                amounts: amounts,
                premiums: premiums,
                initiatorHash: keccak256(abi.encodePacked(initiator)),
                success: success
            }));

            emit FlashLoanExecuted(smartAccount, protocol, tokens, amounts, premiums);
        }
    }
}
