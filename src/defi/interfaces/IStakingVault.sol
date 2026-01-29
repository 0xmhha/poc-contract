// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IStakingVault
 * @notice Interface for the staking vault with rewards distribution
 */
interface IStakingVault {
    // ============ Structs ============

    /// @notice Vault configuration
    struct VaultConfig {
        uint256 rewardRate; // Rewards per second (scaled by 1e18)
        uint256 lockPeriod; // Minimum lock period in seconds
        uint256 earlyWithdrawPenalty; // Penalty for early withdrawal (basis points)
        uint256 maxStake; // Maximum stake per user (0 = unlimited)
        uint256 minStake; // Minimum stake amount
        bool isActive; // Whether vault is accepting stakes
    }

    /// @notice User stake info
    struct StakeInfo {
        uint256 amount; // Staked amount
        uint256 rewardDebt; // Rewards already accounted for
        uint256 stakedAt; // Timestamp when staked
        uint256 lockUntil; // Lock end timestamp
        uint256 pendingRewards; // Unclaimed rewards
    }

    /// @notice Vault state
    struct VaultState {
        uint256 totalStaked; // Total staked in vault
        uint256 accRewardPerShare; // Accumulated rewards per share (scaled by 1e12)
        uint256 lastRewardTime; // Last reward distribution time
        uint256 totalRewardsDistributed; // Total rewards distributed
        uint256 rewardsRemaining; // Remaining rewards in vault
    }

    // ============ Events ============

    event Stake(address indexed user, uint256 amount, uint256 lockUntil);
    event Unstake(address indexed user, uint256 amount, uint256 penalty);
    event Claim(address indexed user, uint256 amount);
    event RewardsAdded(uint256 amount);
    event VaultConfigUpdated(VaultConfig config);
    event EmergencyWithdraw(address indexed user, uint256 amount);

    // ============ Core Functions ============

    /**
     * @notice Stake tokens into the vault
     * @param amount The amount to stake
     */
    function stake(uint256 amount) external;

    /**
     * @notice Stake tokens with a custom lock period
     * @param amount The amount to stake
     * @param lockDuration Lock duration in seconds
     */
    function stakeWithLock(uint256 amount, uint256 lockDuration) external;

    /**
     * @notice Unstake tokens from the vault
     * @param amount The amount to unstake
     */
    function unstake(uint256 amount) external;

    /**
     * @notice Claim pending rewards
     */
    function claim() external;

    /**
     * @notice Compound rewards by restaking
     */
    function compound() external;

    /**
     * @notice Emergency withdraw without caring about rewards
     */
    function emergencyWithdraw() external;

    // ============ View Functions ============

    /**
     * @notice Get user's stake info
     * @param user The user address
     * @return info The stake info
     */
    function getStakeInfo(address user) external view returns (StakeInfo memory info);

    /**
     * @notice Get pending rewards for a user
     * @param user The user address
     * @return The pending rewards amount
     */
    function pendingRewards(address user) external view returns (uint256);

    /**
     * @notice Get vault state
     * @return state The vault state
     */
    function getVaultState() external view returns (VaultState memory state);

    /**
     * @notice Get vault configuration
     * @return config The vault configuration
     */
    function getVaultConfig() external view returns (VaultConfig memory config);

    /**
     * @notice Check if user can withdraw without penalty
     * @param user The user address
     * @return True if can withdraw without penalty
     */
    function canWithdrawWithoutPenalty(address user) external view returns (bool);

    /**
     * @notice Calculate penalty amount for early withdrawal
     * @param user The user address
     * @param amount The amount to withdraw
     * @return The penalty amount
     */
    function calculatePenalty(address user, uint256 amount) external view returns (uint256);

    // ============ Admin Functions ============

    /**
     * @notice Add rewards to the vault
     * @param amount The amount of rewards to add
     */
    function addRewards(uint256 amount) external;

    /**
     * @notice Update vault configuration
     * @param config The new configuration
     */
    function setVaultConfig(VaultConfig memory config) external;

    /**
     * @notice Pause/unpause the vault
     * @param paused Whether to pause
     */
    function setPaused(bool paused) external;
}
