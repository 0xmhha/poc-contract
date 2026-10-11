// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IFallback, IModule } from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { MODULE_TYPE_EXECUTOR, MODULE_TYPE_FALLBACK } from "../erc7579-smartaccount/types/Constants.sol";
import { IERC7579Account } from "../erc7579-smartaccount/interfaces/IERC7579Account.sol";
import { ExecMode } from "../erc7579-smartaccount/types/Types.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
 * Installation:
 * - Install as a CALL-type fallback for each callback selector AND as an executor. The borrowed
 *   funds land on the account, so the strategy calls and the repayment run through
 *   `executeFromExecutor` on the account, not from this module's own address.
 * - Uninstalling either module type disables the module for the account.
 *
 * Usage (one batch from the account):
 * 1. `beginFlashLoan(lender)` on this module
 * 2. the lender's flash loan function, with this account as receiver
 * A callback is accepted only from the lender named in step 1, once, within the same transaction.
 *
 * Use Cases:
 * - Arbitrage strategies
 * - Liquidations
 * - Collateral swaps
 * - Leverage/deleverage operations
 */
contract FlashLoanFallback is IFallback {
    /// @notice Configuration for each smart account
    struct AccountConfig {
        bool requireWhitelistedProtocol; // Only allow whitelisted protocols
        bool logFlashLoans; // Log all flash loan operations
        bool isEnabled;
    }

    /// @notice Flash loan callback data
    struct FlashLoanCallback {
        address target; // Contract to call
        bytes callData; // Data to execute
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
        mapping(address => bool) protocolWhitelist; // Whitelisted flash loan providers
        mapping(bytes32 => FlashLoanCallback) callbacks; // Pending callbacks by hash
        FlashLoanLog[] flashLoanLogs;
    }

    /// @notice Account address => AccountStorage
    mapping(address => AccountStorage) internal accountStorage;

    // ERC-3156 callback return value
    bytes32 private constant ERC3156_CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // Transient slot seed for the lender an account expects a callback from: keccak256("FlashLoanFallback.pending")
    bytes32 private constant PENDING_LOAN_SEED = 0x6ee09fca6dd6f728696e9ec0e9bdf353870f1a3cc9dbdcfb7f10f81cbcdfb179;

    // Events
    event FlashLoanExecuted(
        address indexed account, address indexed protocol, address[] tokens, uint256[] amounts, uint256[] premiums
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
    error FlashLoanNotExpected(address protocol);

    // ============ IModule Implementation ============

    /// @inheritdoc IModule
    function onInstall(bytes calldata data) external payable override {
        // Installed under two module types: the second install with no data keeps the first one's config
        if (data.length == 0 && accountStorage[msg.sender].config.isEnabled) return;
        if (data.length == 0) {
            // Default: require whitelist, log enabled
            accountStorage[msg.sender].config =
                AccountConfig({ requireWhitelistedProtocol: true, logFlashLoans: true, isEnabled: true });
        } else {
            (bool requireWhitelist, bool logFlashLoans) = abi.decode(data, (bool, bool));
            accountStorage[msg.sender].config = AccountConfig({
                requireWhitelistedProtocol: requireWhitelist, logFlashLoans: logFlashLoans, isEnabled: true
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
        return moduleTypeId == MODULE_TYPE_FALLBACK || moduleTypeId == MODULE_TYPE_EXECUTOR;
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
     * @param initiator The address that initiated the flash loan; must be the smart account itself
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
        _consumePendingLoan(smartAccount, protocol);
        _validateInitiator(smartAccount, initiator);

        // Decode and execute callback
        if (params.length > 0) {
            _executeCallback(smartAccount, params);
        }

        // The pool pulls repayment from the account: approve exactly what is owed
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 amountOwing = amounts[i] + premiums[i];
            _executeFromAccount(smartAccount, assets[i], abi.encodeCall(IERC20.approve, (protocol, amountOwing)));
        }

        // Log flash loan
        _logFlashLoan(smartAccount, protocol, assets, amounts, premiums, initiator, true);

        return true;
    }

    // ============ Uniswap v3 Callback ============

    /**
     * @notice Uniswap v3 flash loan callback
     * @dev No initiator argument: a Uniswap v3 pool invokes this callback only on the caller of
     *      `flash()`, so the smart account itself must have started the loan. Repayment is pushed
     *      from the account.
     * @param fee0 Fee amount for token0
     * @param fee1 Fee amount for token1
     * @param data Encoded parameters for the operation
     */
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        (address protocol, address smartAccount) = _extractContext();

        _validateProtocol(smartAccount, protocol);
        _consumePendingLoan(smartAccount, protocol);

        // Decode callback data
        (address token0, address token1, uint256 amount0, uint256 amount1, bytes memory callbackData) =
            abi.decode(data, (address, address, uint256, uint256, bytes));

        // Execute callback if provided
        if (callbackData.length > 0) {
            _executeCallback(smartAccount, callbackData);
        }

        // Repay flash loan from the account
        if (amount0 > 0) {
            _executeFromAccount(smartAccount, token0, abi.encodeCall(IERC20.transfer, (protocol, amount0 + fee0)));
        }
        if (amount1 > 0) {
            _executeFromAccount(smartAccount, token1, abi.encodeCall(IERC20.transfer, (protocol, amount1 + fee1)));
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
     * @dev No initiator argument: the Balancer Vault lets anyone name this account as recipient.
     *      The pending-loan check rejects any loan the account did not announce with
     *      `beginFlashLoan` in the same transaction, so a third party cannot make the account
     *      run a callback or pay a fee. Repayment is pushed from the account.
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
        _consumePendingLoan(smartAccount, protocol);

        // Execute callback if provided
        if (userData.length > 0) {
            _executeCallback(smartAccount, userData);
        }

        // Repay flash loan from the account
        for (uint256 i = 0; i < tokens.length; i++) {
            _executeFromAccount(
                smartAccount, tokens[i], abi.encodeCall(IERC20.transfer, (protocol, amounts[i] + feeAmounts[i]))
            );
        }

        // Log flash loan
        _logFlashLoan(smartAccount, protocol, tokens, amounts, feeAmounts, smartAccount, true);
    }

    // ============ ERC-3156 Callback ============

    /**
     * @notice ERC-3156 flash loan callback
     * @param initiator The address that initiated the flash loan; must be the smart account itself
     * @param token The borrowed token
     * @param amount The borrowed amount
     * @param fee The fee amount
     * @param data Encoded parameters for the operation
     * @return bytes32 The callback success value
     */
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        (address protocol, address smartAccount) = _extractContext();

        _validateProtocol(smartAccount, protocol);
        _consumePendingLoan(smartAccount, protocol);
        _validateInitiator(smartAccount, initiator);

        // Execute callback if provided
        if (data.length > 0) {
            _executeCallback(smartAccount, data);
        }

        // The lender pulls repayment from the account: approve exactly what is owed
        _executeFromAccount(smartAccount, token, abi.encodeCall(IERC20.approve, (protocol, amount + fee)));

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

    // ============ Loan Authorization ============

    /**
     * @notice Announce a flash loan the account is about to take from `protocol`
     * @dev Call from the account in the same transaction as the loan, right before it. The
     *      announcement is held in transient storage and consumed by the first callback.
     * @param protocol The lender expected to call back
     */
    function beginFlashLoan(address protocol) external {
        bytes32 slot = _pendingLoanSlot(msg.sender);
        assembly ("memory-safe") {
            tstore(slot, protocol)
        }
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
    function registerCallback(bytes32 callbackId, address target, bytes calldata callData, bool executeAfterRepay)
        external
    {
        accountStorage[msg.sender].callbacks[callbackId] =
            FlashLoanCallback({ target: target, callData: callData, executeAfterRepay: executeAfterRepay });

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
    function getFlashLoanLogs(address account, uint256 startIndex, uint256 endIndex)
        external
        view
        returns (FlashLoanLog[] memory logs)
    {
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
     * @dev Extract context from ERC-2771 calldata
     * Kernel appends 20 bytes (original caller) per ERC-2771 standard.
     * msg.sender is the smart account (Kernel) that forwarded the call.
     * @return originalCaller The original msg.sender of the smart account (e.g., flash loan provider)
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

    function _validateProtocol(address smartAccount, address protocol) internal view {
        AccountStorage storage store = accountStorage[smartAccount];

        if (!store.config.isEnabled) revert ModuleNotEnabled();

        if (store.config.requireWhitelistedProtocol && !store.protocolWhitelist[protocol]) {
            revert ProtocolNotWhitelisted(protocol);
        }
    }

    /// @dev Pull-based lenders (AAVE, ERC-3156) collect repayment from the account through its allowance,
    ///      so a loan started by anyone other than the account would make the account pay the premium.
    function _validateInitiator(address smartAccount, address initiator) internal pure {
        if (initiator != smartAccount) revert InvalidInitiator();
    }

    function _pendingLoanSlot(address smartAccount) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, smartAccount)
            mstore(0x20, PENDING_LOAN_SEED)
            slot := keccak256(0x00, 0x40)
        }
    }

    /// @dev Accepts one callback per `beginFlashLoan`, and only from the announced lender
    function _consumePendingLoan(address smartAccount, address protocol) internal {
        bytes32 slot = _pendingLoanSlot(smartAccount);
        address expected;
        assembly ("memory-safe") {
            expected := tload(slot)
            tstore(slot, 0)
        }
        if (expected == address(0) || expected != protocol) revert FlashLoanNotExpected(protocol);
    }

    /// @dev Runs a call as the account; requires this module to be installed as its executor
    function _executeFromAccount(address smartAccount, address target, bytes memory data) internal {
        // Default mode (single call, revert on failure); calldata is target || value || data
        IERC7579Account(smartAccount)
            .executeFromExecutor(ExecMode.wrap(bytes32(0)), abi.encodePacked(target, uint256(0), data));
    }

    function _executeCallback(address smartAccount, bytes memory data) internal {
        // Check if this is a callback ID or raw call data
        if (data.length == 32) {
            bytes32 callbackId = abi.decode(data, (bytes32));
            FlashLoanCallback storage callback = accountStorage[smartAccount].callbacks[callbackId];

            if (callback.target == address(0)) revert CallbackNotRegistered(callbackId);

            _executeFromAccount(smartAccount, callback.target, callback.callData);
        } else if (data.length > 0) {
            // Decode as direct call (target, callData)
            (address target, bytes memory callData) = abi.decode(data, (address, bytes));
            if (target != address(0)) {
                _executeFromAccount(smartAccount, target, callData);
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
            store.flashLoanLogs
                .push(
                    FlashLoanLog({
                        timestamp: block.timestamp,
                        protocol: protocol,
                        tokens: tokens,
                        amounts: amounts,
                        premiums: premiums,
                        initiatorHash: keccak256(abi.encodePacked(initiator)),
                        success: success
                    })
                );

            emit FlashLoanExecuted(smartAccount, protocol, tokens, amounts, premiums);
        }
    }
}
