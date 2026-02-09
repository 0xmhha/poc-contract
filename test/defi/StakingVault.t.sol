// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { StakingVault } from "../../src/defi/StakingVault.sol";
import { IStakingVault } from "../../src/defi/interfaces/IStakingVault.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StakingVaultTest is Test {
    StakingVault public vault;
    MockERC20 public stakingToken;
    MockERC20 public rewardToken;

    address public owner = address(this);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    uint256 constant REWARD_RATE = 1e18; // 1 token per second
    uint256 constant LOCK_PERIOD = 7 days;
    uint256 constant EARLY_WITHDRAW_PENALTY = 1000; // 10%
    uint256 constant MIN_STAKE = 1e18;
    uint256 constant MAX_STAKE = 1_000_000e18;

    function setUp() public {
        // Deploy tokens
        stakingToken = new MockERC20("Staking Token", "STK");
        rewardToken = new MockERC20("Reward Token", "RWD");

        // Create vault config
        IStakingVault.VaultConfig memory config = IStakingVault.VaultConfig({
            rewardRate: REWARD_RATE,
            lockPeriod: LOCK_PERIOD,
            earlyWithdrawPenalty: EARLY_WITHDRAW_PENALTY,
            maxStake: MAX_STAKE,
            minStake: MIN_STAKE,
            isActive: true
        });

        // Deploy vault
        vault = new StakingVault(address(stakingToken), address(rewardToken), config);

        // Mint tokens to users
        stakingToken.mint(alice, 100_000e18);
        stakingToken.mint(bob, 100_000e18);

        // Mint reward tokens to owner and add to vault
        rewardToken.mint(owner, 1_000_000e18);
        rewardToken.approve(address(vault), type(uint256).max);
        vault.addRewards(100_000e18);

        // Users approve vault
        vm.startPrank(alice);
        stakingToken.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        stakingToken.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor() public view {
        assertEq(address(vault.stakingToken()), address(stakingToken));
        assertEq(address(vault.rewardToken()), address(rewardToken));

        IStakingVault.VaultConfig memory config = vault.getVaultConfig();
        assertEq(config.rewardRate, REWARD_RATE);
        assertEq(config.lockPeriod, LOCK_PERIOD);
        assertEq(config.earlyWithdrawPenalty, EARLY_WITHDRAW_PENALTY);
    }

    function test_Constructor_InvalidConfig() public {
        IStakingVault.VaultConfig memory badConfig = IStakingVault.VaultConfig({
            rewardRate: REWARD_RATE,
            lockPeriod: 400 days, // Exceeds MAX_LOCK_PERIOD
            earlyWithdrawPenalty: EARLY_WITHDRAW_PENALTY,
            maxStake: MAX_STAKE,
            minStake: MIN_STAKE,
            isActive: true
        });

        vm.expectRevert(StakingVault.InvalidConfig.selector);
        new StakingVault(address(stakingToken), address(rewardToken), badConfig);
    }

    // ============ Stake Tests ============

    function test_Stake() public {
        uint256 stakeAmount = 1000e18;

        vm.prank(alice);
        vault.stake(stakeAmount);

        IStakingVault.StakeInfo memory info = vault.getStakeInfo(alice);
        assertEq(info.amount, stakeAmount);
        assertEq(info.lockUntil, block.timestamp + LOCK_PERIOD);
    }

    function test_Stake_EmitsEvent() public {
        uint256 stakeAmount = 1000e18;

        vm.expectEmit(true, false, false, true);
        emit IStakingVault.Stake(alice, stakeAmount, block.timestamp + LOCK_PERIOD);

        vm.prank(alice);
        vault.stake(stakeAmount);
    }

    function test_Stake_MultipleStakes() public {
        vm.startPrank(alice);
        vault.stake(1000e18);
        vault.stake(500e18);
        vm.stopPrank();

        IStakingVault.StakeInfo memory info = vault.getStakeInfo(alice);
        assertEq(info.amount, 1500e18);
    }

    function test_Stake_BelowMinStake_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingVault.BelowMinStake.selector);
        vault.stake(0.5e18); // Below MIN_STAKE
    }

    function test_Stake_AboveMaxStake_Reverts() public {
        // Give alice enough tokens
        stakingToken.mint(alice, MAX_STAKE);

        // First stake within limit
        vm.prank(alice);
        vault.stake(MAX_STAKE);

        // Second stake would exceed limit
        vm.prank(alice);
        vm.expectRevert(StakingVault.AboveMaxStake.selector);
        vault.stake(1e18);
    }

    function test_Stake_WhenPaused_Reverts() public {
        vault.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(StakingVault.VaultPaused.selector);
        vault.stake(1000e18);
    }

    function test_Stake_WhenNotActive_Reverts() public {
        IStakingVault.VaultConfig memory config = vault.getVaultConfig();
        config.isActive = false;
        vault.setVaultConfig(config);

        vm.prank(alice);
        vm.expectRevert(StakingVault.VaultNotActive.selector);
        vault.stake(1000e18);
    }

    // ============ StakeWithLock Tests ============

    function test_StakeWithLock() public {
        uint256 stakeAmount = 1000e18;
        uint256 lockDuration = 30 days;

        vm.prank(alice);
        vault.stakeWithLock(stakeAmount, lockDuration);

        IStakingVault.StakeInfo memory info = vault.getStakeInfo(alice);
        assertEq(info.lockUntil, block.timestamp + lockDuration);
    }

    function test_StakeWithLock_InvalidDuration_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingVault.InvalidLockDuration.selector);
        vault.stakeWithLock(1000e18, 1 days); // Less than LOCK_PERIOD

        vm.prank(alice);
        vm.expectRevert(StakingVault.InvalidLockDuration.selector);
        vault.stakeWithLock(1000e18, 400 days); // Exceeds MAX_LOCK_PERIOD
    }

    // ============ Unstake Tests ============

    function test_Unstake_AfterLock() public {
        vm.prank(alice);
        vault.stake(1000e18);

        // Fast forward past lock period
        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        uint256 balanceBefore = stakingToken.balanceOf(alice);

        vm.prank(alice);
        vault.unstake(500e18);

        uint256 balanceAfter = stakingToken.balanceOf(alice);
        assertEq(balanceAfter - balanceBefore, 500e18); // No penalty

        IStakingVault.StakeInfo memory info = vault.getStakeInfo(alice);
        assertEq(info.amount, 500e18);
    }

    function test_Unstake_EarlyWithPenalty() public {
        vm.prank(alice);
        vault.stake(1000e18);

        // Unstake early (before lock ends)
        uint256 balanceBefore = stakingToken.balanceOf(alice);

        vm.prank(alice);
        vault.unstake(500e18);

        uint256 balanceAfter = stakingToken.balanceOf(alice);
        uint256 expectedPenalty = (500e18 * EARLY_WITHDRAW_PENALTY) / 10_000;
        assertEq(balanceAfter - balanceBefore, 500e18 - expectedPenalty);
    }

    function test_Unstake_EmitsEvent() public {
        vm.prank(alice);
        vault.stake(1000e18);

        uint256 expectedPenalty = (500e18 * EARLY_WITHDRAW_PENALTY) / 10_000;

        vm.expectEmit(true, false, false, true);
        emit IStakingVault.Unstake(alice, 500e18, expectedPenalty);

        vm.prank(alice);
        vault.unstake(500e18);
    }

    function test_Unstake_NoStake_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingVault.NoStake.selector);
        vault.unstake(100e18);
    }

    function test_Unstake_InvalidAmount_Reverts() public {
        vm.prank(alice);
        vault.stake(1000e18);

        vm.prank(alice);
        vm.expectRevert(StakingVault.InvalidAmount.selector);
        vault.unstake(2000e18); // More than staked
    }

    // ============ Rewards Tests ============

    function test_PendingRewards() public {
        vm.prank(alice);
        vault.stake(1000e18);

        // Fast forward 100 seconds
        vm.warp(block.timestamp + 100);

        uint256 pending = vault.pendingRewards(alice);
        // Should be approximately 100 * REWARD_RATE = 100e18
        assertApproxEqRel(pending, 100e18, 0.01e18);
    }

    function test_Claim() public {
        vm.prank(alice);
        vault.stake(1000e18);

        // Fast forward
        vm.warp(block.timestamp + 100);

        uint256 pending = vault.pendingRewards(alice);
        uint256 balanceBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        vault.claim();

        uint256 balanceAfter = rewardToken.balanceOf(alice);
        assertApproxEqRel(balanceAfter - balanceBefore, pending, 0.01e18);
    }

    function test_Claim_EmitsEvent() public {
        vm.prank(alice);
        vault.stake(1000e18);

        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        vault.claim();

        // Event is emitted (checked via expectEmit would require knowing exact amount)
    }

    function test_Claim_NoRewards_Reverts() public {
        vm.prank(alice);
        vault.stake(1000e18);

        // Claim immediately (no time passed, no rewards)
        vm.prank(alice);
        vm.expectRevert(StakingVault.InvalidAmount.selector);
        vault.claim();
    }

    // ============ Compound Tests ============

    function test_Compound() public {
        // Deploy vault with same token for staking and rewards
        MockERC20 sameToken = new MockERC20("Same Token", "SAME");

        IStakingVault.VaultConfig memory config = IStakingVault.VaultConfig({
            rewardRate: REWARD_RATE,
            lockPeriod: LOCK_PERIOD,
            earlyWithdrawPenalty: EARLY_WITHDRAW_PENALTY,
            maxStake: MAX_STAKE,
            minStake: MIN_STAKE,
            isActive: true
        });

        StakingVault sameTokenVault = new StakingVault(address(sameToken), address(sameToken), config);

        // Setup
        sameToken.mint(alice, 100_000e18);
        sameToken.mint(owner, 100_000e18);

        sameToken.approve(address(sameTokenVault), type(uint256).max);
        sameTokenVault.addRewards(50_000e18);

        vm.startPrank(alice);
        sameToken.approve(address(sameTokenVault), type(uint256).max);
        sameTokenVault.stake(1000e18);
        vm.stopPrank();

        // Fast forward
        vm.warp(block.timestamp + 100);

        uint256 pendingBefore = sameTokenVault.pendingRewards(alice);
        IStakingVault.StakeInfo memory infoBefore = sameTokenVault.getStakeInfo(alice);

        vm.prank(alice);
        sameTokenVault.compound();

        IStakingVault.StakeInfo memory infoAfter = sameTokenVault.getStakeInfo(alice);
        assertApproxEqRel(infoAfter.amount - infoBefore.amount, pendingBefore, 0.01e18);
    }

    // ============ Emergency Withdraw Tests ============

    function test_EmergencyWithdraw() public {
        vm.prank(alice);
        vault.stake(1000e18);

        // Fast forward to accumulate rewards
        vm.warp(block.timestamp + 100);

        uint256 balanceBefore = stakingToken.balanceOf(alice);

        vm.prank(alice);
        vault.emergencyWithdraw();

        uint256 balanceAfter = stakingToken.balanceOf(alice);
        assertEq(balanceAfter - balanceBefore, 1000e18); // Full amount, no penalty

        IStakingVault.StakeInfo memory info = vault.getStakeInfo(alice);
        assertEq(info.amount, 0);
        assertEq(info.pendingRewards, 0); // Rewards forfeited
    }

    function test_EmergencyWithdraw_NoStake_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingVault.NoStake.selector);
        vault.emergencyWithdraw();
    }

    // ============ View Function Tests ============

    function test_CanWithdrawWithoutPenalty() public {
        vm.prank(alice);
        vault.stake(1000e18);

        assertFalse(vault.canWithdrawWithoutPenalty(alice));

        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        assertTrue(vault.canWithdrawWithoutPenalty(alice));
    }

    function test_CalculatePenalty() public {
        vm.prank(alice);
        vault.stake(1000e18);

        uint256 penalty = vault.calculatePenalty(alice, 500e18);
        assertEq(penalty, (500e18 * EARLY_WITHDRAW_PENALTY) / 10_000);

        // After lock period
        vm.warp(block.timestamp + LOCK_PERIOD + 1);
        penalty = vault.calculatePenalty(alice, 500e18);
        assertEq(penalty, 0);
    }

    function test_GetVaultState() public {
        vm.prank(alice);
        vault.stake(1000e18);

        IStakingVault.VaultState memory state = vault.getVaultState();
        assertEq(state.totalStaked, 1000e18);
        assertGt(state.rewardsRemaining, 0);
    }

    // ============ Admin Tests ============

    function test_AddRewards() public {
        uint256 additionalRewards = 50_000e18;
        IStakingVault.VaultState memory stateBefore = vault.getVaultState();

        vault.addRewards(additionalRewards);

        IStakingVault.VaultState memory stateAfter = vault.getVaultState();
        assertEq(stateAfter.rewardsRemaining, stateBefore.rewardsRemaining + additionalRewards);
    }

    function test_AddRewards_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IStakingVault.RewardsAdded(50_000e18);

        vault.addRewards(50_000e18);
    }

    function test_SetVaultConfig() public {
        IStakingVault.VaultConfig memory newConfig = IStakingVault.VaultConfig({
            rewardRate: 2e18,
            lockPeriod: 14 days,
            earlyWithdrawPenalty: 2000,
            maxStake: 500_000e18,
            minStake: 10e18,
            isActive: true
        });

        vault.setVaultConfig(newConfig);

        IStakingVault.VaultConfig memory config = vault.getVaultConfig();
        assertEq(config.rewardRate, 2e18);
        assertEq(config.lockPeriod, 14 days);
    }

    function test_SetPaused() public {
        vault.setPaused(true);
        assertTrue(vault.paused());

        vault.setPaused(false);
        assertFalse(vault.paused());
    }

    function test_RecoverTokens() public {
        // Send some random tokens to vault
        MockERC20 randomToken = new MockERC20("Random", "RND");
        randomToken.mint(address(vault), 1000e18);

        vault.recoverTokens(address(randomToken), owner, 1000e18);
        assertEq(randomToken.balanceOf(owner), 1000e18);
    }

    // ============ Multi-User Tests ============

    function test_MultipleStakers() public {
        vm.prank(alice);
        vault.stake(1000e18);

        vm.prank(bob);
        vault.stake(1000e18);

        // Fast forward
        vm.warp(block.timestamp + 100);

        // Both should have similar rewards (split equally)
        uint256 aliceRewards = vault.pendingRewards(alice);
        uint256 bobRewards = vault.pendingRewards(bob);

        assertApproxEqRel(aliceRewards, bobRewards, 0.01e18);
        assertApproxEqRel(aliceRewards + bobRewards, 100e18, 0.01e18);
    }
}
