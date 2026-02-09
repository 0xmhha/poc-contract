// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IExecutor, IModule } from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { MODULE_TYPE_EXECUTOR } from "../erc7579-smartaccount/types/Constants.sol";
import { IERC7579Account } from "../erc7579-smartaccount/interfaces/IERC7579Account.sol";
import { ExecMode } from "../erc7579-smartaccount/types/Types.sol";

/**
 * @title IStakingPool
 * @notice Interface for staking pool interactions
 */
interface IStakingPool {
    function stake(uint256 amount) external;
    function stakeWithLock(uint256 amount, uint256 lockDuration) external;
    function unstake(uint256 amount) external;
    function claim() external;
    function compound() external;
    function stakedAmount(address user) external view returns (uint256);
    function pendingRewards(address user) external view returns (uint256);
}

/**
 * @title StakingExecutor
 * @notice ERC-7579 Executor module for staking operations from Smart Accounts
 * @dev Enables stake/unstake/claim/compound operations with security controls
 *
 * Features:
 * - Pool registry for allowed staking pools
 * - Max stake per pool limits
 * - Daily staking limits
 * - Pause functionality
 *
 * Use Cases:
 * - Automated yield farming
 * - Session key controlled staking
 * - Corporate treasury staking policies
 */
contract StakingExecutor is IExecutor {
    // ============ Storage ============

    /// @notice Account configuration
    struct AccountConfig {
        uint256 maxStakePerPool;
        uint256 dailyStakeLimit;
        uint256 dailyUsed;
        uint256 lastResetTime;
        bool isActive;
        bool isPaused;
    }

    /// @notice Account address => configuration
    mapping(address => AccountConfig) internal accountConfigs;

    /// @notice Account address => pool address => is allowed
    mapping(address => mapping(address => bool)) internal allowedPools;

    /// @notice Account address => list of allowed pools
    mapping(address => address[]) internal allowedPoolList;

    /// @notice Account address => pool address => staked amount (cached)
    mapping(address => mapping(address => uint256)) internal stakedAmounts;

    // ============ Constants ============

    /// @notice Default max stake per pool (unlimited if 0)
    uint256 public constant DEFAULT_MAX_STAKE = 0;

    /// @notice Default daily limit (unlimited if 0)
    uint256 public constant DEFAULT_DAILY_LIMIT = 0;

    // ============ Events ============

    event Staked(address indexed account, address indexed pool, uint256 amount);
    event Unstaked(address indexed account, address indexed pool, uint256 amount);
    event RewardsClaimed(address indexed account, address indexed pool, uint256 amount);
    event RewardsCompounded(address indexed account, address indexed pool, uint256 amount);
    event PoolAllowed(address indexed account, address indexed pool);
    event PoolRemoved(address indexed account, address indexed pool);
    event ConfigUpdated(address indexed account, uint256 maxStake, uint256 dailyLimit);
    event ExecutorPausedEvent(address indexed account, bool isPaused);

    // ============ Errors ============

    error InvalidPool();
    error PoolAlreadyAllowed();
    error PoolNotAllowed();
    error ExceedsMaxStake();
    error ExceedsDailyLimit();
    error ExecutorPaused();
    error InvalidAmount();

    // ============ IModule Implementation ============

    /**
     * @notice Called when the module is installed
     * @param data Optional encoded configuration: (uint256 maxStakePerPool, uint256 dailyStakeLimit)
     */
    function onInstall(bytes calldata data) external payable override {
        if (accountConfigs[msg.sender].isActive) {
            revert IModule.AlreadyInitialized(msg.sender);
        }

        uint256 maxStake = DEFAULT_MAX_STAKE;
        uint256 dailyLimit = DEFAULT_DAILY_LIMIT;

        if (data.length > 0) {
            (maxStake, dailyLimit) = abi.decode(data, (uint256, uint256));
        }

        accountConfigs[msg.sender] = AccountConfig({
            maxStakePerPool: maxStake,
            dailyStakeLimit: dailyLimit,
            dailyUsed: 0,
            lastResetTime: block.timestamp,
            isActive: true,
            isPaused: false
        });

        emit ConfigUpdated(msg.sender, maxStake, dailyLimit);
    }

    /**
     * @notice Called when the module is uninstalled
     * @param data Unused
     */
    function onUninstall(bytes calldata data) external payable override {
        (data); // Silence unused warning

        // Clear allowed pools
        address[] storage pools = allowedPoolList[msg.sender];
        for (uint256 i = 0; i < pools.length; i++) {
            delete allowedPools[msg.sender][pools[i]];
            delete stakedAmounts[msg.sender][pools[i]];
        }
        delete allowedPoolList[msg.sender];

        // Clear config
        delete accountConfigs[msg.sender];
    }

    /**
     * @notice Returns true if this is an Executor module
     * @param moduleTypeId The module type ID to check
     */
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    /**
     * @notice Returns true if the module is initialized for the account
     * @param smartAccount The smart account address
     */
    function isInitialized(address smartAccount) external view override returns (bool) {
        return accountConfigs[smartAccount].isActive;
    }

    // ============ Pool Management ============

    /**
     * @notice Add a staking pool to the allowed list
     * @param pool Pool address to allow
     */
    function addAllowedPool(address pool) external {
        _checkInitialized(msg.sender);

        if (pool == address(0)) {
            revert InvalidPool();
        }

        if (allowedPools[msg.sender][pool]) {
            revert PoolAlreadyAllowed();
        }

        allowedPools[msg.sender][pool] = true;
        allowedPoolList[msg.sender].push(pool);

        emit PoolAllowed(msg.sender, pool);
    }

    /**
     * @notice Remove a staking pool from the allowed list
     * @param pool Pool address to remove
     */
    function removeAllowedPool(address pool) external {
        _checkInitialized(msg.sender);

        if (!allowedPools[msg.sender][pool]) {
            revert PoolNotAllowed();
        }

        allowedPools[msg.sender][pool] = false;
        _removeFromPoolList(msg.sender, pool);

        emit PoolRemoved(msg.sender, pool);
    }

    // ============ Configuration ============

    /**
     * @notice Set maximum stake per pool
     * @param maxStake New max stake (0 = unlimited)
     */
    function setMaxStakePerPool(uint256 maxStake) external {
        _checkInitialized(msg.sender);

        accountConfigs[msg.sender].maxStakePerPool = maxStake;
        emit ConfigUpdated(msg.sender, maxStake, accountConfigs[msg.sender].dailyStakeLimit);
    }

    /**
     * @notice Set daily staking limit
     * @param dailyLimit New daily limit (0 = unlimited)
     */
    function setDailyStakeLimit(uint256 dailyLimit) external {
        _checkInitialized(msg.sender);

        accountConfigs[msg.sender].dailyStakeLimit = dailyLimit;
        emit ConfigUpdated(msg.sender, accountConfigs[msg.sender].maxStakePerPool, dailyLimit);
    }

    /**
     * @notice Pause or unpause the executor
     * @param paused Whether to pause
     */
    function setPaused(bool paused) external {
        _checkInitialized(msg.sender);

        accountConfigs[msg.sender].isPaused = paused;
        emit ExecutorPausedEvent(msg.sender, paused);
    }

    // ============ Staking Operations ============

    /**
     * @notice Stake tokens into a pool
     * @param pool Staking pool address
     * @param amount Amount to stake
     */
    function stake(address pool, uint256 amount) external {
        _checkInitialized(msg.sender);
        _checkNotPaused(msg.sender);
        _checkPoolAllowed(msg.sender, pool);

        AccountConfig storage config = accountConfigs[msg.sender];

        // Reset daily limit if new day
        _resetDailyLimitIfNeeded(config);

        // Check max stake per pool
        if (config.maxStakePerPool > 0) {
            uint256 currentStake = stakedAmounts[msg.sender][pool];
            if (currentStake + amount > config.maxStakePerPool) {
                revert ExceedsMaxStake();
            }
        }

        // Check daily limit
        if (config.dailyStakeLimit > 0) {
            if (config.dailyUsed + amount > config.dailyStakeLimit) {
                revert ExceedsDailyLimit();
            }
            config.dailyUsed += amount;
        }

        // Execute stake via smart account
        bytes memory callData = abi.encodeWithSelector(IStakingPool.stake.selector, amount);
        _executeFromAccount(msg.sender, pool, 0, callData);

        // Update cached stake amount
        stakedAmounts[msg.sender][pool] += amount;

        emit Staked(msg.sender, pool, amount);
    }

    /**
     * @notice Stake tokens with a custom lock duration
     * @param pool Staking pool address
     * @param amount Amount to stake
     * @param lockDuration Lock duration in seconds
     */
    function stakeWithLock(address pool, uint256 amount, uint256 lockDuration) external {
        _checkInitialized(msg.sender);
        _checkNotPaused(msg.sender);
        _checkPoolAllowed(msg.sender, pool);

        AccountConfig storage config = accountConfigs[msg.sender];

        // Reset daily limit if new day
        _resetDailyLimitIfNeeded(config);

        // Check max stake per pool
        if (config.maxStakePerPool > 0) {
            uint256 currentStake = stakedAmounts[msg.sender][pool];
            if (currentStake + amount > config.maxStakePerPool) {
                revert ExceedsMaxStake();
            }
        }

        // Check daily limit
        if (config.dailyStakeLimit > 0) {
            if (config.dailyUsed + amount > config.dailyStakeLimit) {
                revert ExceedsDailyLimit();
            }
            config.dailyUsed += amount;
        }

        // Execute stake with lock via smart account
        bytes memory callData = abi.encodeWithSelector(IStakingPool.stakeWithLock.selector, amount, lockDuration);
        _executeFromAccount(msg.sender, pool, 0, callData);

        // Update cached stake amount
        stakedAmounts[msg.sender][pool] += amount;

        emit Staked(msg.sender, pool, amount);
    }

    /**
     * @notice Unstake tokens from a pool
     * @param pool Staking pool address
     * @param amount Amount to unstake
     */
    function unstake(address pool, uint256 amount) external {
        _checkInitialized(msg.sender);
        _checkNotPaused(msg.sender);
        _checkPoolAllowed(msg.sender, pool);

        if (amount == 0) {
            revert InvalidAmount();
        }

        // Execute unstake via smart account
        bytes memory callData = abi.encodeWithSelector(IStakingPool.unstake.selector, amount);
        _executeFromAccount(msg.sender, pool, 0, callData);

        // Update cached stake amount
        if (stakedAmounts[msg.sender][pool] >= amount) {
            stakedAmounts[msg.sender][pool] -= amount;
        } else {
            stakedAmounts[msg.sender][pool] = 0;
        }

        emit Unstaked(msg.sender, pool, amount);
    }

    /**
     * @notice Claim rewards from a pool
     * @param pool Staking pool address
     */
    function claimRewards(address pool) external {
        _checkInitialized(msg.sender);
        _checkNotPaused(msg.sender);
        _checkPoolAllowed(msg.sender, pool);

        // Get pending rewards before claim
        uint256 pending = IStakingPool(pool).pendingRewards(msg.sender);

        // Execute claim via smart account
        bytes memory callData = abi.encodeWithSelector(IStakingPool.claim.selector);
        _executeFromAccount(msg.sender, pool, 0, callData);

        emit RewardsClaimed(msg.sender, pool, pending);
    }

    /**
     * @notice Compound rewards by restaking
     * @param pool Staking pool address
     */
    function compoundRewards(address pool) external {
        _checkInitialized(msg.sender);
        _checkNotPaused(msg.sender);
        _checkPoolAllowed(msg.sender, pool);

        // Get pending rewards before compound
        uint256 pending = IStakingPool(pool).pendingRewards(msg.sender);

        // Execute compound via smart account
        bytes memory callData = abi.encodeWithSelector(IStakingPool.compound.selector);
        _executeFromAccount(msg.sender, pool, 0, callData);

        // Update cached stake amount (rewards added to stake)
        stakedAmounts[msg.sender][pool] += pending;

        emit RewardsCompounded(msg.sender, pool, pending);
    }

    // ============ View Functions ============

    /**
     * @notice Get account configuration
     * @param account The smart account address
     * @return maxStakePerPool Max stake per pool
     * @return dailyStakeLimit Daily stake limit
     * @return dailyUsed Amount used today
     * @return isActive Whether executor is active
     * @return isPaused Whether executor is paused
     */
    function getAccountConfig(address account)
        external
        view
        returns (uint256 maxStakePerPool, uint256 dailyStakeLimit, uint256 dailyUsed, bool isActive, bool isPaused)
    {
        AccountConfig storage config = accountConfigs[account];
        return (config.maxStakePerPool, config.dailyStakeLimit, config.dailyUsed, config.isActive, config.isPaused);
    }

    /**
     * @notice Check if a pool is allowed for an account
     * @param account The smart account address
     * @param pool The pool address
     */
    function isPoolAllowed(address account, address pool) external view returns (bool) {
        return allowedPools[account][pool];
    }

    /**
     * @notice Get all allowed pools for an account
     * @param account The smart account address
     */
    function getAllowedPools(address account) external view returns (address[] memory) {
        return allowedPoolList[account];
    }

    /**
     * @notice Get staked amount for an account in a pool
     * @param account The smart account address
     * @param pool The pool address
     */
    function getStakedAmount(address account, address pool) external view returns (uint256) {
        return stakedAmounts[account][pool];
    }

    /**
     * @notice Get pending rewards for an account in a pool
     * @param account The smart account address
     * @param pool The pool address
     */
    function getPendingRewards(address account, address pool) external view returns (uint256) {
        return IStakingPool(pool).pendingRewards(account);
    }

    /**
     * @notice Get daily used stake amount
     * @param account The smart account address
     */
    function getDailyUsed(address account) external view returns (uint256) {
        return accountConfigs[account].dailyUsed;
    }

    // ============ Internal Functions ============

    /**
     * @notice Check if account is initialized
     */
    function _checkInitialized(address account) internal view {
        if (!accountConfigs[account].isActive) {
            revert IModule.NotInitialized(account);
        }
    }

    /**
     * @notice Check if executor is not paused
     */
    function _checkNotPaused(address account) internal view {
        if (accountConfigs[account].isPaused) {
            revert ExecutorPaused();
        }
    }

    /**
     * @notice Check if pool is allowed
     */
    function _checkPoolAllowed(address account, address pool) internal view {
        if (!allowedPools[account][pool]) {
            revert PoolNotAllowed();
        }
    }

    /**
     * @notice Reset daily limit if a new day has started
     */
    function _resetDailyLimitIfNeeded(AccountConfig storage config) internal {
        if (block.timestamp >= config.lastResetTime + 1 days) {
            config.dailyUsed = 0;
            config.lastResetTime = block.timestamp;
        }
    }

    /**
     * @notice Execute a call from the smart account
     */
    function _executeFromAccount(address account, address target, uint256 value, bytes memory data) internal {
        bytes memory executionCalldata = abi.encode(target, value, data);
        ExecMode execMode = _encodeExecMode();

        IERC7579Account(account).executeFromExecutor(execMode, executionCalldata);
    }

    /**
     * @notice Encode execution mode for single call
     * @dev Default mode (0x00) for single call with revert on failure
     */
    function _encodeExecMode() internal pure returns (ExecMode) {
        return ExecMode.wrap(bytes32(0));
    }

    /**
     * @notice Remove pool from the allowed list array
     */
    function _removeFromPoolList(address account, address pool) internal {
        address[] storage pools = allowedPoolList[account];
        uint256 length = pools.length;

        for (uint256 i = 0; i < length; i++) {
            if (pools[i] == pool) {
                pools[i] = pools[length - 1];
                pools.pop();
                break;
            }
        }
    }
}
