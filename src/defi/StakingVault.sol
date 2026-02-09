// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IStakingVault } from "./interfaces/IStakingVault.sol";

/**
 * @title StakingVault
 * @notice Staking vault with time-locked rewards and early withdrawal penalties
 * @dev Features:
 *      - Configurable reward rates
 *      - Lock periods with early withdrawal penalties
 *      - Compound rewards functionality
 *      - Emergency withdraw
 */
contract StakingVault is IStakingVault, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Precision for reward calculations
    uint256 public constant ACC_REWARD_PRECISION = 1e12;

    /// @notice Maximum lock period (1 year)
    uint256 public constant MAX_LOCK_PERIOD = 365 days;

    /// @notice Maximum penalty (50%)
    uint256 public constant MAX_PENALTY = 5000;

    // ============ State Variables ============

    /// @notice The staking token
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC20 public immutable stakingToken;

    /// @notice The reward token (can be same as staking token)
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC20 public immutable rewardToken;

    /// @notice Vault configuration
    VaultConfig public config;

    /// @notice Vault state
    VaultState public state;

    /// @notice User stakes
    mapping(address => StakeInfo) public stakes;

    /// @notice Whether vault is paused
    bool public paused;

    // ============ Errors ============

    error VaultPaused();
    error VaultNotActive();
    error InvalidAmount();
    error BelowMinStake();
    error AboveMaxStake();
    error NoStake();
    error StillLocked();
    error InsufficientRewards();
    error InvalidLockDuration();
    error InvalidConfig();

    // ============ Modifiers ============

    modifier whenNotPaused() {
        _checkNotPaused();
        _;
    }

    modifier whenActive() {
        _checkActive();
        _;
    }

    function _checkNotPaused() internal view {
        if (paused) revert VaultPaused();
    }

    function _checkActive() internal view {
        if (!config.isActive) revert VaultNotActive();
    }

    // ============ Constructor ============

    constructor(address _stakingToken, address _rewardToken, VaultConfig memory _config) Ownable(msg.sender) {
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);

        _validateConfig(_config);
        config = _config;

        state.lastRewardTime = block.timestamp;
    }

    // ============ Core Functions ============

    /**
     * @inheritdoc IStakingVault
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused whenActive {
        _stake(msg.sender, amount, config.lockPeriod);
    }

    /**
     * @inheritdoc IStakingVault
     */
    function stakeWithLock(uint256 amount, uint256 lockDuration) external nonReentrant whenNotPaused whenActive {
        if (lockDuration < config.lockPeriod) revert InvalidLockDuration();
        if (lockDuration > MAX_LOCK_PERIOD) revert InvalidLockDuration();
        _stake(msg.sender, amount, lockDuration);
    }

    /**
     * @inheritdoc IStakingVault
     */
    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        StakeInfo storage userStake = stakes[msg.sender];
        if (userStake.amount == 0) revert NoStake();
        if (amount == 0 || amount > userStake.amount) revert InvalidAmount();

        _updateRewards();
        _updateUserRewards(msg.sender);

        // Calculate penalty if early withdrawal
        uint256 penalty = 0;
        if (block.timestamp < userStake.lockUntil) {
            penalty = (amount * config.earlyWithdrawPenalty) / BASIS_POINTS;
        }

        uint256 amountAfterPenalty = amount - penalty;

        // Update state
        userStake.amount -= amount;
        state.totalStaked -= amount;

        // Update reward debt
        userStake.rewardDebt = (userStake.amount * state.accRewardPerShare) / ACC_REWARD_PRECISION;

        // Transfer tokens
        stakingToken.safeTransfer(msg.sender, amountAfterPenalty);

        // Penalty goes to rewards pool
        if (penalty > 0) {
            state.rewardsRemaining += penalty;
        }

        emit Unstake(msg.sender, amount, penalty);
    }

    /**
     * @inheritdoc IStakingVault
     */
    function claim() external nonReentrant whenNotPaused {
        _updateRewards();
        _updateUserRewards(msg.sender);

        StakeInfo storage userStake = stakes[msg.sender];
        uint256 rewards = userStake.pendingRewards;

        if (rewards == 0) revert InvalidAmount();
        if (rewards > state.rewardsRemaining) revert InsufficientRewards();

        userStake.pendingRewards = 0;
        state.rewardsRemaining -= rewards;
        state.totalRewardsDistributed += rewards;

        rewardToken.safeTransfer(msg.sender, rewards);

        emit Claim(msg.sender, rewards);
    }

    /**
     * @inheritdoc IStakingVault
     */
    function compound() external nonReentrant whenNotPaused whenActive {
        // Only works if staking token == reward token
        require(address(stakingToken) == address(rewardToken), "Cannot compound different tokens");

        _updateRewards();
        _updateUserRewards(msg.sender);

        StakeInfo storage userStake = stakes[msg.sender];
        uint256 rewards = userStake.pendingRewards;

        if (rewards == 0) revert InvalidAmount();
        if (rewards > state.rewardsRemaining) revert InsufficientRewards();

        // Reset pending rewards
        userStake.pendingRewards = 0;
        state.rewardsRemaining -= rewards;
        state.totalRewardsDistributed += rewards;

        // Add to stake
        userStake.amount += rewards;
        state.totalStaked += rewards;

        // Update reward debt
        userStake.rewardDebt = (userStake.amount * state.accRewardPerShare) / ACC_REWARD_PRECISION;

        emit Stake(msg.sender, rewards, userStake.lockUntil);
    }

    /**
     * @inheritdoc IStakingVault
     */
    function emergencyWithdraw() external nonReentrant {
        StakeInfo storage userStake = stakes[msg.sender];
        uint256 amount = userStake.amount;

        if (amount == 0) revert NoStake();

        // Reset user state (forfeit all rewards)
        userStake.amount = 0;
        userStake.rewardDebt = 0;
        userStake.pendingRewards = 0;
        state.totalStaked -= amount;

        // No penalty for emergency withdraw, but forfeit rewards
        stakingToken.safeTransfer(msg.sender, amount);

        emit EmergencyWithdraw(msg.sender, amount);
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IStakingVault
     */
    function getStakeInfo(address user) external view returns (StakeInfo memory info) {
        StakeInfo memory userStake = stakes[user];

        // Calculate current pending rewards
        if (userStake.amount > 0) {
            uint256 accRewardPerShare = _calculateAccRewardPerShare();
            uint256 pending = (userStake.amount * accRewardPerShare) / ACC_REWARD_PRECISION - userStake.rewardDebt;
            userStake.pendingRewards += pending;
        }

        return userStake;
    }

    /**
     * @inheritdoc IStakingVault
     */
    function pendingRewards(address user) public view returns (uint256) {
        StakeInfo memory userStake = stakes[user];
        if (userStake.amount == 0) return userStake.pendingRewards;

        uint256 accRewardPerShare = _calculateAccRewardPerShare();
        uint256 pending = (userStake.amount * accRewardPerShare) / ACC_REWARD_PRECISION - userStake.rewardDebt;

        return userStake.pendingRewards + pending;
    }

    /**
     * @inheritdoc IStakingVault
     */
    function getVaultState() external view returns (VaultState memory) {
        return state;
    }

    /**
     * @inheritdoc IStakingVault
     */
    function getVaultConfig() external view returns (VaultConfig memory) {
        return config;
    }

    /**
     * @inheritdoc IStakingVault
     */
    function canWithdrawWithoutPenalty(address user) external view returns (bool) {
        return block.timestamp >= stakes[user].lockUntil;
    }

    /**
     * @inheritdoc IStakingVault
     */
    function calculatePenalty(address user, uint256 amount) external view returns (uint256) {
        if (block.timestamp >= stakes[user].lockUntil) return 0;
        return (amount * config.earlyWithdrawPenalty) / BASIS_POINTS;
    }

    // ============ Admin Functions ============

    /**
     * @inheritdoc IStakingVault
     */
    function addRewards(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidAmount();

        _updateRewards();

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        state.rewardsRemaining += amount;

        emit RewardsAdded(amount);
    }

    /**
     * @inheritdoc IStakingVault
     */
    function setVaultConfig(VaultConfig memory _config) external onlyOwner {
        _validateConfig(_config);

        _updateRewards();

        config = _config;

        emit VaultConfigUpdated(_config);
    }

    /**
     * @inheritdoc IStakingVault
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    /**
     * @notice Recover tokens accidentally sent to contract
     * @param token Token to recover
     * @param to Recipient address
     * @param amount Amount to recover
     */
    function recoverTokens(address token, address to, uint256 amount) external onlyOwner {
        // Cannot recover staking token if it would affect user stakes
        if (token == address(stakingToken)) {
            uint256 excess = IERC20(token).balanceOf(address(this)) - state.totalStaked;
            if (amount > excess) revert InvalidAmount();
        }
        IERC20(token).safeTransfer(to, amount);
    }

    // ============ Internal Functions ============

    function _stake(address user, uint256 amount, uint256 lockDuration) internal {
        if (amount == 0) revert InvalidAmount();
        if (amount < config.minStake) revert BelowMinStake();

        StakeInfo storage userStake = stakes[user];

        if (config.maxStake > 0 && userStake.amount + amount > config.maxStake) {
            revert AboveMaxStake();
        }

        _updateRewards();
        _updateUserRewards(user);

        // Transfer tokens
        stakingToken.safeTransferFrom(user, address(this), amount);

        // Update stake
        userStake.amount += amount;
        state.totalStaked += amount;

        // Set lock period (extend if new lock is longer)
        uint256 newLockUntil = block.timestamp + lockDuration;
        if (newLockUntil > userStake.lockUntil) {
            userStake.lockUntil = newLockUntil;
        }

        // Update staked timestamp if first stake or reset
        if (userStake.stakedAt == 0) {
            userStake.stakedAt = block.timestamp;
        }

        // Update reward debt
        userStake.rewardDebt = (userStake.amount * state.accRewardPerShare) / ACC_REWARD_PRECISION;

        emit Stake(user, amount, userStake.lockUntil);
    }

    function _updateRewards() internal {
        if (state.totalStaked == 0) {
            state.lastRewardTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - state.lastRewardTime;
        if (timeElapsed == 0) return;

        uint256 rewards = timeElapsed * config.rewardRate;

        // Cap rewards to available
        if (rewards > state.rewardsRemaining) {
            rewards = state.rewardsRemaining;
        }

        state.accRewardPerShare += (rewards * ACC_REWARD_PRECISION) / state.totalStaked;
        state.lastRewardTime = block.timestamp;
    }

    function _updateUserRewards(address user) internal {
        StakeInfo storage userStake = stakes[user];
        if (userStake.amount == 0) return;

        uint256 pending = (userStake.amount * state.accRewardPerShare) / ACC_REWARD_PRECISION - userStake.rewardDebt;
        userStake.pendingRewards += pending;
        userStake.rewardDebt = (userStake.amount * state.accRewardPerShare) / ACC_REWARD_PRECISION;
    }

    function _calculateAccRewardPerShare() internal view returns (uint256) {
        if (state.totalStaked == 0) return state.accRewardPerShare;

        uint256 timeElapsed = block.timestamp - state.lastRewardTime;
        if (timeElapsed == 0) return state.accRewardPerShare;

        uint256 rewards = timeElapsed * config.rewardRate;
        if (rewards > state.rewardsRemaining) {
            rewards = state.rewardsRemaining;
        }

        return state.accRewardPerShare + (rewards * ACC_REWARD_PRECISION) / state.totalStaked;
    }

    function _validateConfig(VaultConfig memory _config) internal pure {
        if (_config.lockPeriod > MAX_LOCK_PERIOD) revert InvalidConfig();
        if (_config.earlyWithdrawPenalty > MAX_PENALTY) revert InvalidConfig();
        if (_config.minStake > _config.maxStake && _config.maxStake > 0) revert InvalidConfig();
    }
}
