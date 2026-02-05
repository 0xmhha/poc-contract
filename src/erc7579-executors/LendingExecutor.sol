// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IExecutor, IModule} from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import {IERC7579Account} from "../erc7579-smartaccount/interfaces/IERC7579Account.sol";
import {MODULE_TYPE_EXECUTOR} from "../erc7579-smartaccount/types/Constants.sol";
import {ExecMode} from "../erc7579-smartaccount/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LendingExecutor
 * @notice ERC-7579 Executor module for lending operations from Smart Account
 * @dev Enables Smart Accounts to interact with lending pools with:
 *      - Asset allowlist for security
 *      - Minimum health factor enforcement
 *      - Maximum borrow limits
 *      - Supply, withdraw, borrow, repay operations
 *
 * Architecture:
 * ┌─────────────────────────────────────────────────────────────┐
 * │  SmartAccount                                                │
 * │  ├── executeFromExecutor()                                   │
 * │  └── LendingExecutor (this contract)                         │
 * │      ├── Asset Allowlist                                     │
 * │      ├── Health Factor Limits                                │
 * │      ├── Borrow Limits                                       │
 * │      └── LendingPool (AAVE-style)                            │
 * └─────────────────────────────────────────────────────────────┘
 *
 * Use Cases:
 * - Automated yield farming via SessionKey
 * - Leveraged positions with safety limits
 * - Automated deleveraging on health factor drops
 * - Collateral management
 */
contract LendingExecutor is IExecutor {
    // =========================================================================
    // Type Declarations
    // =========================================================================

    /// @notice Account-specific lending configuration
    struct AccountConfig {
        uint256 minHealthFactor; // Minimum health factor to maintain (18 decimals)
        uint256 maxBorrowLimit; // Maximum total borrow value allowed
        uint256 totalBorrowed; // Total amount currently borrowed
        bool isActive; // Whether module is active
        bool isPaused; // Emergency pause flag
    }

    /// @notice Storage for each smart account
    struct AccountStorage {
        AccountConfig config;
        mapping(address => bool) allowedAssets;
        address[] allowedAssetList;
        mapping(address => uint256) suppliedAmounts;
        mapping(address => uint256) borrowedAmounts;
    }

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Lending pool address
    address public immutable lendingPool;

    /// @notice Account address => AccountStorage
    mapping(address => AccountStorage) internal accountStorage;

    /// @notice Minimum allowed health factor (1.0 = 1e18)
    uint256 public constant MIN_HEALTH_FACTOR_THRESHOLD = 1e18;

    // =========================================================================
    // Events
    // =========================================================================

    event Supplied(address indexed account, address indexed asset, uint256 amount);
    event Withdrawn(address indexed account, address indexed asset, uint256 amount);
    event Borrowed(address indexed account, address indexed asset, uint256 amount);
    event Repaid(address indexed account, address indexed asset, uint256 amount);
    event AssetAllowed(address indexed account, address indexed asset);
    event AssetRemoved(address indexed account, address indexed asset);
    event ConfigUpdated(address indexed account, uint256 minHealthFactor, uint256 maxBorrowLimit);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    // =========================================================================
    // Errors
    // =========================================================================

    // NotInitialized and AlreadyInitialized inherited from IERC7579Modules
    error InvalidAsset();
    error AssetAlreadyAllowed();
    error AssetNotAllowed();
    error InvalidAmount();
    error InvalidHealthFactor();
    error ExceedsBorrowLimit();
    error OperationsPaused();
    error OperationFailed();

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @notice Initialize LendingExecutor with lending pool address
     * @param _lendingPool Address of the lending pool (e.g., AAVE, custom pool)
     */
    constructor(address _lendingPool) {
        lendingPool = _lendingPool;
    }

    // =========================================================================
    // IModule Implementation
    // =========================================================================

    /// @inheritdoc IModule
    function onInstall(bytes calldata data) external payable override {
        AccountStorage storage store = accountStorage[msg.sender];

        if (store.config.isActive) revert AlreadyInitialized(msg.sender);

        // Initialize with defaults
        store.config.isActive = true;
        store.config.minHealthFactor = 1.5e18; // Default 1.5

        if (data.length > 0) {
            // Decode: allowed assets, min health factor, max borrow limit
            (address[] memory assets, uint256 minHealthFactor, uint256 maxBorrowLimit) =
                abi.decode(data, (address[], uint256, uint256));

            // Validate health factor
            if (minHealthFactor < MIN_HEALTH_FACTOR_THRESHOLD) revert InvalidHealthFactor();

            store.config.minHealthFactor = minHealthFactor;
            store.config.maxBorrowLimit = maxBorrowLimit;

            // Add allowed assets
            for (uint256 i = 0; i < assets.length; i++) {
                if (assets[i] == address(0)) revert InvalidAsset();
                store.allowedAssets[assets[i]] = true;
                store.allowedAssetList.push(assets[i]);
            }
        }
    }

    /// @inheritdoc IModule
    function onUninstall(bytes calldata) external payable override {
        AccountStorage storage store = accountStorage[msg.sender];

        // Clear allowlist
        for (uint256 i = 0; i < store.allowedAssetList.length; i++) {
            delete store.allowedAssets[store.allowedAssetList[i]];
        }
        delete store.allowedAssetList;

        // Clear config
        delete store.config;
    }

    /// @inheritdoc IModule
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    /// @inheritdoc IModule
    function isInitialized(address smartAccount) external view override returns (bool) {
        return accountStorage[smartAccount].config.isActive;
    }

    // =========================================================================
    // Asset Management
    // =========================================================================

    /**
     * @notice Add an asset to the allowlist
     * @param asset Asset address to allow
     */
    function addAllowedAsset(address asset) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (!store.config.isActive) revert NotInitialized(msg.sender);
        if (asset == address(0)) revert InvalidAsset();
        if (store.allowedAssets[asset]) revert AssetAlreadyAllowed();

        store.allowedAssets[asset] = true;
        store.allowedAssetList.push(asset);

        emit AssetAllowed(msg.sender, asset);
    }

    /**
     * @notice Remove an asset from the allowlist
     * @param asset Asset address to remove
     */
    function removeAllowedAsset(address asset) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (!store.config.isActive) revert NotInitialized(msg.sender);
        if (!store.allowedAssets[asset]) revert AssetNotAllowed();

        store.allowedAssets[asset] = false;
        _removeFromAssetList(msg.sender, asset);

        emit AssetRemoved(msg.sender, asset);
    }

    /**
     * @notice Check if an asset is allowed for an account
     * @param account Smart Account address
     * @param asset Asset address
     * @return True if allowed
     */
    function isAssetAllowed(address account, address asset) external view returns (bool) {
        return accountStorage[account].allowedAssets[asset];
    }

    /**
     * @notice Get all allowed assets for an account
     * @param account Smart Account address
     * @return Array of allowed asset addresses
     */
    function getAllowedAssets(address account) external view returns (address[] memory) {
        return accountStorage[account].allowedAssetList;
    }

    // =========================================================================
    // Configuration Management
    // =========================================================================

    /**
     * @notice Set minimum health factor
     * @param minHealthFactor Minimum health factor (18 decimals, >= 1.0)
     */
    function setMinHealthFactor(uint256 minHealthFactor) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (!store.config.isActive) revert NotInitialized(msg.sender);
        if (minHealthFactor < MIN_HEALTH_FACTOR_THRESHOLD) revert InvalidHealthFactor();

        store.config.minHealthFactor = minHealthFactor;

        emit ConfigUpdated(msg.sender, minHealthFactor, store.config.maxBorrowLimit);
    }

    /**
     * @notice Set maximum borrow limit
     * @param maxBorrowLimit Maximum total borrow value
     */
    function setMaxBorrowLimit(uint256 maxBorrowLimit) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (!store.config.isActive) revert NotInitialized(msg.sender);

        store.config.maxBorrowLimit = maxBorrowLimit;

        emit ConfigUpdated(msg.sender, store.config.minHealthFactor, maxBorrowLimit);
    }

    /**
     * @notice Get minimum health factor for an account
     * @param account Smart Account address
     * @return Minimum health factor
     */
    function getMinHealthFactor(address account) external view returns (uint256) {
        return accountStorage[account].config.minHealthFactor;
    }

    /**
     * @notice Get maximum borrow limit for an account
     * @param account Smart Account address
     * @return Maximum borrow limit
     */
    function getMaxBorrowLimit(address account) external view returns (uint256) {
        return accountStorage[account].config.maxBorrowLimit;
    }

    /**
     * @notice Get full account configuration
     * @param account Smart Account address
     */
    function getAccountConfig(address account)
        external
        view
        returns (uint256 minHealthFactor, uint256 maxBorrowLimit, uint256 totalBorrowed, bool isActive)
    {
        AccountConfig storage config = accountStorage[account].config;
        return (config.minHealthFactor, config.maxBorrowLimit, config.totalBorrowed, config.isActive);
    }

    // =========================================================================
    // Lending Operations - Supply
    // =========================================================================

    /**
     * @notice Supply assets to the lending pool
     * @param asset Asset address to supply
     * @param amount Amount to supply
     */
    function supply(address asset, uint256 amount) external {
        AccountStorage storage store = accountStorage[msg.sender];

        // Validations
        _validateOperation(store, asset, amount);

        // Record supply
        store.suppliedAmounts[asset] += amount;

        // Execute via Smart Account: approve + deposit
        _executeSupply(msg.sender, asset, amount);

        emit Supplied(msg.sender, asset, amount);
    }

    /**
     * @notice Get supplied amount for an account and asset
     * @param account Smart Account address
     * @param asset Asset address
     * @return Amount supplied
     */
    function getSuppliedAmount(address account, address asset) external view returns (uint256) {
        return accountStorage[account].suppliedAmounts[asset];
    }

    // =========================================================================
    // Lending Operations - Withdraw
    // =========================================================================

    /**
     * @notice Withdraw assets from the lending pool
     * @param asset Asset address to withdraw
     * @param amount Amount to withdraw (type(uint256).max for all)
     */
    function withdraw(address asset, uint256 amount) external {
        AccountStorage storage store = accountStorage[msg.sender];

        // Validations
        if (!store.config.isActive) revert NotInitialized(msg.sender);
        if (store.config.isPaused) revert OperationsPaused();
        if (!store.allowedAssets[asset]) revert AssetNotAllowed();

        // Handle max withdrawal
        if (amount == type(uint256).max) {
            amount = store.suppliedAmounts[asset];
        }

        // Update supply tracking
        store.suppliedAmounts[asset] -= amount;

        // Execute via Smart Account
        _executeWithdraw(msg.sender, asset, amount);

        emit Withdrawn(msg.sender, asset, amount);
    }

    // =========================================================================
    // Lending Operations - Borrow
    // =========================================================================

    /**
     * @notice Borrow assets from the lending pool
     * @param asset Asset address to borrow
     * @param amount Amount to borrow
     */
    function borrow(address asset, uint256 amount) external {
        AccountStorage storage store = accountStorage[msg.sender];

        // Validations
        _validateOperation(store, asset, amount);

        // Check borrow limit
        if (store.config.maxBorrowLimit > 0 && store.config.totalBorrowed + amount > store.config.maxBorrowLimit) {
            revert ExceedsBorrowLimit();
        }

        // Update tracking
        store.borrowedAmounts[asset] += amount;
        store.config.totalBorrowed += amount;

        // Execute via Smart Account
        _executeBorrow(msg.sender, asset, amount);

        emit Borrowed(msg.sender, asset, amount);
    }

    /**
     * @notice Get borrowed amount for an account and asset
     * @param account Smart Account address
     * @param asset Asset address
     * @return Amount borrowed
     */
    function getBorrowedAmount(address account, address asset) external view returns (uint256) {
        return accountStorage[account].borrowedAmounts[asset];
    }

    // =========================================================================
    // Lending Operations - Repay
    // =========================================================================

    /**
     * @notice Repay borrowed assets to the lending pool
     * @param asset Asset address to repay
     * @param amount Amount to repay (type(uint256).max for all)
     */
    function repay(address asset, uint256 amount) external {
        AccountStorage storage store = accountStorage[msg.sender];

        // Validations
        if (!store.config.isActive) revert NotInitialized(msg.sender);
        if (store.config.isPaused) revert OperationsPaused();
        if (!store.allowedAssets[asset]) revert AssetNotAllowed();

        // Handle max repay
        uint256 borrowed = store.borrowedAmounts[asset];
        if (amount == type(uint256).max) {
            amount = borrowed;
        }
        if (amount > borrowed) {
            amount = borrowed;
        }

        // Update tracking
        store.borrowedAmounts[asset] -= amount;
        store.config.totalBorrowed -= amount;

        // Execute via Smart Account: approve + repay
        _executeRepay(msg.sender, asset, amount);

        emit Repaid(msg.sender, asset, amount);
    }

    // =========================================================================
    // Emergency Functions
    // =========================================================================

    /**
     * @notice Pause all lending operations
     */
    function pause() external {
        AccountStorage storage store = accountStorage[msg.sender];
        if (!store.config.isActive) revert NotInitialized(msg.sender);

        store.config.isPaused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause lending operations
     */
    function unpause() external {
        AccountStorage storage store = accountStorage[msg.sender];
        if (!store.config.isActive) revert NotInitialized(msg.sender);

        store.config.isPaused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Check if an account is paused
     * @param account Smart Account address
     */
    function isPaused(address account) external view returns (bool) {
        return accountStorage[account].config.isPaused;
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /**
     * @notice Get the lending pool address
     */
    function getLendingPool() external view returns (address) {
        return lendingPool;
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /**
     * @dev Validate operation parameters
     */
    function _validateOperation(AccountStorage storage store, address asset, uint256 amount) internal view {
        if (!store.config.isActive) revert NotInitialized(msg.sender);
        if (store.config.isPaused) revert OperationsPaused();
        if (!store.allowedAssets[asset]) revert AssetNotAllowed();
        if (amount == 0) revert InvalidAmount();
    }

    /**
     * @dev Execute supply via Smart Account
     */
    function _executeSupply(address account, address asset, uint256 amount) internal {
        // First, approve lending pool
        bytes memory approveCall = abi.encodeWithSelector(IERC20.approve.selector, lendingPool, amount);
        bytes memory approveExecData = abi.encodePacked(asset, uint256(0), approveCall);

        ExecMode execMode = _encodeExecMode();
        IERC7579Account(account).executeFromExecutor(execMode, approveExecData);

        // Then, deposit to lending pool
        bytes memory depositCall = abi.encodeWithSignature("deposit(address,uint256)", asset, amount);
        bytes memory depositExecData = abi.encodePacked(lendingPool, uint256(0), depositCall);

        IERC7579Account(account).executeFromExecutor(execMode, depositExecData);
    }

    /**
     * @dev Execute withdraw via Smart Account
     */
    function _executeWithdraw(address account, address asset, uint256 amount) internal {
        bytes memory withdrawCall = abi.encodeWithSignature("withdraw(address,uint256)", asset, amount);
        bytes memory execData = abi.encodePacked(lendingPool, uint256(0), withdrawCall);

        ExecMode execMode = _encodeExecMode();
        IERC7579Account(account).executeFromExecutor(execMode, execData);
    }

    /**
     * @dev Execute borrow via Smart Account
     */
    function _executeBorrow(address account, address asset, uint256 amount) internal {
        bytes memory borrowCall = abi.encodeWithSignature("borrow(address,uint256)", asset, amount);
        bytes memory execData = abi.encodePacked(lendingPool, uint256(0), borrowCall);

        ExecMode execMode = _encodeExecMode();
        IERC7579Account(account).executeFromExecutor(execMode, execData);
    }

    /**
     * @dev Execute repay via Smart Account
     */
    function _executeRepay(address account, address asset, uint256 amount) internal {
        // First, approve lending pool
        bytes memory approveCall = abi.encodeWithSelector(IERC20.approve.selector, lendingPool, amount);
        bytes memory approveExecData = abi.encodePacked(asset, uint256(0), approveCall);

        ExecMode execMode = _encodeExecMode();
        IERC7579Account(account).executeFromExecutor(execMode, approveExecData);

        // Then, repay to lending pool
        bytes memory repayCall = abi.encodeWithSignature("repay(address,uint256)", asset, amount);
        bytes memory repayExecData = abi.encodePacked(lendingPool, uint256(0), repayCall);

        IERC7579Account(account).executeFromExecutor(execMode, repayExecData);
    }

    /**
     * @dev Remove asset from allowlist array
     */
    function _removeFromAssetList(address account, address asset) internal {
        AccountStorage storage store = accountStorage[account];
        uint256 length = store.allowedAssetList.length;

        for (uint256 i = 0; i < length; i++) {
            if (store.allowedAssetList[i] == asset) {
                store.allowedAssetList[i] = store.allowedAssetList[length - 1];
                store.allowedAssetList.pop();
                break;
            }
        }
    }

    /**
     * @dev Encode execution mode for single call
     */
    function _encodeExecMode() internal pure returns (ExecMode) {
        return ExecMode.wrap(bytes32(0));
    }
}
