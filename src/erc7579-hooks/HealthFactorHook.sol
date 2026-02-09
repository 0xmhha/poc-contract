// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHook, IModule} from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import {MODULE_TYPE_HOOK} from "../erc7579-smartaccount/types/Constants.sol";

/**
 * @title ILendingPool
 * @notice Interface for lending pool health factor queries
 */
interface ILendingPool {
    function calculateHealthFactor(address user) external view returns (uint256);
}

/**
 * @title HealthFactorHook
 * @notice ERC-7579 Hook module that validates health factor for lending operations
 * @dev Prevents transactions that would cause health factor to drop below threshold
 *
 * Health Factor = (Collateral Value * Liquidation Threshold) / Debt Value
 * If HF < 1.0, position can be liquidated
 *
 * Features:
 * - Configurable minimum health factor threshold (default 1.2)
 * - Monitored target contracts (selective enforcement)
 * - Pre/post transaction health factor validation
 * - Enable/disable functionality
 *
 * Use Cases:
 * - Prevent risky DeFi operations
 * - Automated liquidation protection
 * - Risk management for lending positions
 */
contract HealthFactorHook is IHook {
    // ============ Storage ============

    /// @notice Account configuration
    struct AccountConfig {
        uint256 minHealthFactor;
        bool enabled;
        bool initialized;
    }

    /// @notice Lending pool address for health factor queries
    address public immutable LENDING_POOL;

    /// @notice Minimum allowed health factor (1.0 = liquidation threshold)
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    /// @notice Default threshold (1.2)
    uint256 public constant DEFAULT_THRESHOLD = 1.2e18;

    /// @notice Account address => configuration
    mapping(address => AccountConfig) internal accountConfigs;

    /// @notice Account address => monitored target => is monitored
    mapping(address => mapping(address => bool)) internal monitoredTargets;

    /// @notice Account address => list of monitored targets
    mapping(address => address[]) internal monitoredTargetList;

    // ============ Events ============

    event HealthFactorChanged(address indexed account, uint256 preHealthFactor, uint256 postHealthFactor);
    event MinHealthFactorSet(address indexed account, uint256 threshold);
    event EnabledChanged(address indexed account, bool enabled);
    event MonitoredTargetAdded(address indexed account, address indexed target);
    event MonitoredTargetRemoved(address indexed account, address indexed target);

    // ============ Errors ============

    error InvalidThreshold();
    error InvalidTarget();
    error TargetAlreadyMonitored();
    error TargetNotMonitored();
    error HealthFactorTooLow();

    // ============ Constructor ============

    /**
     * @notice Initialize hook with lending pool address
     * @param _lendingPool Address of the lending pool for health factor queries
     */
    constructor(address _lendingPool) {
        LENDING_POOL = _lendingPool;
    }

    // ============ IModule Implementation ============

    /**
     * @notice Called when the module is installed
     * @param data Optional encoded configuration: (uint256 threshold, bool enabled)
     */
    function onInstall(bytes calldata data) external payable override {
        if (accountConfigs[msg.sender].initialized) {
            revert IModule.AlreadyInitialized(msg.sender);
        }

        uint256 threshold = DEFAULT_THRESHOLD;
        bool enabled = true;

        if (data.length > 0) {
            (threshold, enabled) = abi.decode(data, (uint256, bool));
            if (threshold < MIN_HEALTH_FACTOR) {
                revert InvalidThreshold();
            }
        }

        accountConfigs[msg.sender] = AccountConfig({
            minHealthFactor: threshold,
            enabled: enabled,
            initialized: true
        });

        emit MinHealthFactorSet(msg.sender, threshold);
        emit EnabledChanged(msg.sender, enabled);
    }

    /**
     * @notice Called when the module is uninstalled
     * @param data Unused
     */
    function onUninstall(bytes calldata data) external payable override {
        (data); // Silence unused warning

        // Clear monitored targets
        address[] storage targets = monitoredTargetList[msg.sender];
        for (uint256 i = 0; i < targets.length; i++) {
            delete monitoredTargets[msg.sender][targets[i]];
        }
        delete monitoredTargetList[msg.sender];

        // Clear config
        delete accountConfigs[msg.sender];
    }

    /**
     * @notice Returns true if this is a Hook module
     * @param moduleTypeId The module type ID to check
     */
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_HOOK;
    }

    /**
     * @notice Returns true if the module is initialized for the account
     * @param smartAccount The smart account address
     */
    function isInitialized(address smartAccount) external view override returns (bool) {
        return accountConfigs[smartAccount].initialized;
    }

    // ============ IHook Implementation ============

    /**
     * @notice Pre-execution check - records current health factor
     * @param msgSender The target contract being called
     * @param msgValue ETH value (unused)
     * @param msgData Calldata (unused)
     * @return hookData Encoded pre-tx health factor, or empty if skipped
     */
    function preCheck(
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external payable override returns (bytes memory hookData) {
        (msgValue, msgData); // Silence unused warnings

        AccountConfig storage config = accountConfigs[msg.sender];

        // Skip if not enabled
        if (!config.enabled) {
            return bytes("");
        }

        // Skip if target not monitored
        if (!monitoredTargets[msg.sender][msgSender]) {
            return bytes("");
        }

        // Get current health factor
        uint256 currentHf = ILendingPool(LENDING_POOL).calculateHealthFactor(msg.sender);

        // Encode pre-tx health factor and account for postCheck
        return abi.encode(msg.sender, currentHf, config.minHealthFactor);
    }

    /**
     * @notice Post-execution check - validates health factor didn't drop below threshold
     * @param hookData Data from preCheck containing pre-tx health factor
     */
    function postCheck(bytes calldata hookData) external payable override {
        // Skip if no context (preCheck was skipped)
        if (hookData.length == 0) {
            return;
        }

        // Decode pre-tx data
        (address account, uint256 preHealthFactor, uint256 minHealthFactor) =
            abi.decode(hookData, (address, uint256, uint256));

        // Get post-tx health factor
        uint256 postHealthFactor = ILendingPool(LENDING_POOL).calculateHealthFactor(account);

        // Check if health factor dropped below threshold
        if (postHealthFactor < minHealthFactor) {
            revert HealthFactorTooLow();
        }

        // Emit event if significant change (> 5% drop)
        if (postHealthFactor < preHealthFactor) {
            uint256 dropPercent = ((preHealthFactor - postHealthFactor) * 100) / preHealthFactor;
            if (dropPercent >= 5) {
                emit HealthFactorChanged(account, preHealthFactor, postHealthFactor);
            }
        }
    }

    // ============ Configuration Functions ============

    /**
     * @notice Set minimum health factor threshold
     * @param threshold New threshold (must be >= 1.0)
     */
    function setMinHealthFactor(uint256 threshold) external {
        AccountConfig storage config = accountConfigs[msg.sender];

        if (!config.initialized) {
            revert IModule.NotInitialized(msg.sender);
        }

        if (threshold < MIN_HEALTH_FACTOR) {
            revert InvalidThreshold();
        }

        config.minHealthFactor = threshold;
        emit MinHealthFactorSet(msg.sender, threshold);
    }

    /**
     * @notice Enable or disable the hook
     * @param enabled New enabled state
     */
    function setEnabled(bool enabled) external {
        AccountConfig storage config = accountConfigs[msg.sender];

        if (!config.initialized) {
            revert IModule.NotInitialized(msg.sender);
        }

        config.enabled = enabled;
        emit EnabledChanged(msg.sender, enabled);
    }

    /**
     * @notice Add a contract to the monitored targets list
     * @param target Contract address to monitor
     */
    function addMonitoredTarget(address target) external {
        if (target == address(0)) {
            revert InvalidTarget();
        }

        AccountConfig storage config = accountConfigs[msg.sender];
        if (!config.initialized) {
            revert IModule.NotInitialized(msg.sender);
        }

        if (monitoredTargets[msg.sender][target]) {
            revert TargetAlreadyMonitored();
        }

        monitoredTargets[msg.sender][target] = true;
        monitoredTargetList[msg.sender].push(target);

        emit MonitoredTargetAdded(msg.sender, target);
    }

    /**
     * @notice Remove a contract from the monitored targets list
     * @param target Contract address to remove
     */
    function removeMonitoredTarget(address target) external {
        AccountConfig storage config = accountConfigs[msg.sender];
        if (!config.initialized) {
            revert IModule.NotInitialized(msg.sender);
        }

        if (!monitoredTargets[msg.sender][target]) {
            revert TargetNotMonitored();
        }

        monitoredTargets[msg.sender][target] = false;
        _removeFromTargetList(msg.sender, target);

        emit MonitoredTargetRemoved(msg.sender, target);
    }

    // ============ View Functions ============

    /**
     * @notice Get minimum health factor threshold for an account
     * @param account The smart account address
     */
    function getMinHealthFactor(address account) external view returns (uint256) {
        return accountConfigs[account].minHealthFactor;
    }

    /**
     * @notice Check if hook is enabled for an account
     * @param account The smart account address
     */
    function isEnabled(address account) external view returns (bool) {
        return accountConfigs[account].enabled;
    }

    /**
     * @notice Check if a target is monitored for an account
     * @param account The smart account address
     * @param target The target contract address
     */
    function isMonitoredTarget(address account, address target) external view returns (bool) {
        return monitoredTargets[account][target];
    }

    /**
     * @notice Get all monitored targets for an account
     * @param account The smart account address
     */
    function getMonitoredTargets(address account) external view returns (address[] memory) {
        return monitoredTargetList[account];
    }

    /**
     * @notice Get full account configuration
     * @param account The smart account address
     * @return minHf Minimum health factor threshold
     * @return enabled Whether hook is enabled
     * @return initialized Whether hook is installed
     */
    function getAccountConfig(address account) external view returns (
        uint256 minHf,
        bool enabled,
        bool initialized
    ) {
        AccountConfig storage config = accountConfigs[account];
        return (config.minHealthFactor, config.enabled, config.initialized);
    }

    /**
     * @notice Get the lending pool address
     */
    function getLendingPool() external view returns (address) {
        return LENDING_POOL;
    }

    /**
     * @notice Get current health factor for an account from lending pool
     * @param account The account to query
     */
    function getCurrentHealthFactor(address account) external view returns (uint256) {
        return ILendingPool(LENDING_POOL).calculateHealthFactor(account);
    }

    // ============ Internal Functions ============

    /**
     * @notice Remove target from the monitored list array
     * @param account The smart account address
     * @param target The target to remove
     */
    function _removeFromTargetList(address account, address target) internal {
        address[] storage targets = monitoredTargetList[account];
        uint256 length = targets.length;

        for (uint256 i = 0; i < length; i++) {
            if (targets[i] == target) {
                targets[i] = targets[length - 1];
                targets.pop();
                break;
            }
        }
    }
}
