// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StakingExecutor} from "../../src/erc7579-executors/StakingExecutor.sol";
import {IModule} from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import {MODULE_TYPE_EXECUTOR} from "../../src/erc7579-smartaccount/types/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title StakingExecutor Test
 * @notice TDD RED Phase - Tests for ERC-7579 StakingExecutor module
 * @dev Tests staking operations from Smart Account via Executor
 */
contract StakingExecutorTest is Test {
    StakingExecutor public executor;

    // Mock contracts
    MockSmartAccount public smartAccount;
    MockStakingPool public stakingPool;
    MockStakingPool public stakingPool2;
    MockERC20 public stakingToken;
    MockERC20 public rewardToken;

    // Test addresses
    address public owner;
    address public user;

    // Constants
    uint256 public constant DEFAULT_MAX_STAKE = 1000e18;
    uint256 public constant DEFAULT_DAILY_LIMIT = 500e18;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");

        // Deploy mock tokens
        stakingToken = new MockERC20("Staking Token", "STK");
        rewardToken = new MockERC20("Reward Token", "RWD");

        // Deploy mock staking pools
        stakingPool = new MockStakingPool(address(stakingToken), address(rewardToken));
        stakingPool2 = new MockStakingPool(address(stakingToken), address(rewardToken));

        // Deploy executor
        executor = new StakingExecutor();

        // Deploy mock smart account
        smartAccount = new MockSmartAccount(address(executor));

        // Fund smart account
        stakingToken.mint(address(smartAccount), 10000e18);
        rewardToken.mint(address(stakingPool), 10000e18); // Rewards in pool
        rewardToken.mint(address(stakingPool2), 10000e18);
    }

    // =========================================================================
    // Module Interface Tests
    // =========================================================================

    function test_isModuleType_ReturnsTrue_ForExecutor() public view {
        assertTrue(executor.isModuleType(MODULE_TYPE_EXECUTOR));
    }

    function test_isModuleType_ReturnsFalse_ForOtherTypes() public view {
        assertFalse(executor.isModuleType(1)); // Validator
        assertFalse(executor.isModuleType(3)); // Fallback
        assertFalse(executor.isModuleType(4)); // Hook
    }

    function test_onInstall_WithEmptyData_SetsDefaults() public {
        vm.prank(address(smartAccount));
        executor.onInstall(bytes(""));

        assertTrue(executor.isInitialized(address(smartAccount)));
    }

    function test_onInstall_WithConfig_SetsValues() public {
        bytes memory installData = abi.encode(DEFAULT_MAX_STAKE, DEFAULT_DAILY_LIMIT);

        vm.prank(address(smartAccount));
        executor.onInstall(installData);

        (uint256 maxStake, uint256 dailyLimit, , , ) = executor.getAccountConfig(address(smartAccount));
        assertEq(maxStake, DEFAULT_MAX_STAKE);
        assertEq(dailyLimit, DEFAULT_DAILY_LIMIT);
    }

    function test_onInstall_RevertsIf_AlreadyInstalled() public {
        vm.prank(address(smartAccount));
        executor.onInstall(bytes(""));

        vm.prank(address(smartAccount));
        vm.expectRevert(abi.encodeWithSelector(IModule.AlreadyInitialized.selector, address(smartAccount)));
        executor.onInstall(bytes(""));
    }

    function test_onUninstall_ClearsState() public {
        _installExecutor();

        vm.prank(address(smartAccount));
        executor.onUninstall(bytes(""));

        assertFalse(executor.isInitialized(address(smartAccount)));
    }

    function test_isInitialized_ReturnsFalse_BeforeInstall() public view {
        assertFalse(executor.isInitialized(address(smartAccount)));
    }

    // =========================================================================
    // Pool Registry Tests
    // =========================================================================

    function test_addAllowedPool_AddsPool() public {
        _installExecutor();

        vm.prank(address(smartAccount));
        executor.addAllowedPool(address(stakingPool));

        assertTrue(executor.isPoolAllowed(address(smartAccount), address(stakingPool)));
    }

    function test_addAllowedPool_RevertsIf_ZeroAddress() public {
        _installExecutor();

        vm.prank(address(smartAccount));
        vm.expectRevert(StakingExecutor.InvalidPool.selector);
        executor.addAllowedPool(address(0));
    }

    function test_addAllowedPool_RevertsIf_AlreadyAllowed() public {
        _installExecutor();

        vm.prank(address(smartAccount));
        executor.addAllowedPool(address(stakingPool));

        vm.prank(address(smartAccount));
        vm.expectRevert(StakingExecutor.PoolAlreadyAllowed.selector);
        executor.addAllowedPool(address(stakingPool));
    }

    function test_removeAllowedPool_RemovesPool() public {
        _installExecutor();

        vm.prank(address(smartAccount));
        executor.addAllowedPool(address(stakingPool));

        vm.prank(address(smartAccount));
        executor.removeAllowedPool(address(stakingPool));

        assertFalse(executor.isPoolAllowed(address(smartAccount), address(stakingPool)));
    }

    function test_removeAllowedPool_RevertsIf_NotAllowed() public {
        _installExecutor();

        vm.prank(address(smartAccount));
        vm.expectRevert(StakingExecutor.PoolNotAllowed.selector);
        executor.removeAllowedPool(address(stakingPool));
    }

    function test_getAllowedPools_ReturnsAllPools() public {
        _installExecutor();

        vm.prank(address(smartAccount));
        executor.addAllowedPool(address(stakingPool));

        vm.prank(address(smartAccount));
        executor.addAllowedPool(address(stakingPool2));

        address[] memory pools = executor.getAllowedPools(address(smartAccount));
        assertEq(pools.length, 2);
    }

    // =========================================================================
    // Configuration Tests
    // =========================================================================

    function test_setMaxStakePerPool_UpdatesValue() public {
        _installExecutor();

        uint256 newMax = 2000e18;

        vm.prank(address(smartAccount));
        executor.setMaxStakePerPool(newMax);

        (uint256 maxStake, , , , ) = executor.getAccountConfig(address(smartAccount));
        assertEq(maxStake, newMax);
    }

    function test_setDailyStakeLimit_UpdatesValue() public {
        _installExecutor();

        uint256 newLimit = 1000e18;

        vm.prank(address(smartAccount));
        executor.setDailyStakeLimit(newLimit);

        (, uint256 dailyLimit, , , ) = executor.getAccountConfig(address(smartAccount));
        assertEq(dailyLimit, newLimit);
    }

    function test_setPaused_PausesExecutor() public {
        _installExecutor();

        vm.prank(address(smartAccount));
        executor.setPaused(true);

        (, , , , bool isPaused) = executor.getAccountConfig(address(smartAccount));
        assertTrue(isPaused);
    }

    function test_setMaxStakePerPool_RevertsIf_NotInitialized() public {
        vm.prank(address(smartAccount));
        vm.expectRevert(abi.encodeWithSelector(IModule.NotInitialized.selector, address(smartAccount)));
        executor.setMaxStakePerPool(1000e18);
    }

    // =========================================================================
    // Stake Tests
    // =========================================================================

    function test_stake_Success() public {
        _installExecutorAndAllowPool();

        uint256 amount = 100e18;

        // Approve via smart account
        smartAccount.approveToken(address(stakingToken), address(stakingPool), amount);

        vm.prank(address(smartAccount));
        executor.stake(address(stakingPool), amount);

        assertEq(stakingPool.stakedAmount(address(smartAccount)), amount);
    }

    function test_stake_RevertsIf_PoolNotAllowed() public {
        _installExecutor();

        vm.prank(address(smartAccount));
        vm.expectRevert(StakingExecutor.PoolNotAllowed.selector);
        executor.stake(address(stakingPool), 100e18);
    }

    function test_stake_RevertsIf_Paused() public {
        _installExecutorAndAllowPool();

        vm.prank(address(smartAccount));
        executor.setPaused(true);

        vm.prank(address(smartAccount));
        vm.expectRevert(StakingExecutor.ExecutorPaused.selector);
        executor.stake(address(stakingPool), 100e18);
    }

    function test_stake_RevertsIf_ExceedsMaxStake() public {
        bytes memory installData = abi.encode(100e18, DEFAULT_DAILY_LIMIT); // max 100
        vm.prank(address(smartAccount));
        executor.onInstall(installData);

        vm.prank(address(smartAccount));
        executor.addAllowedPool(address(stakingPool));

        smartAccount.approveToken(address(stakingToken), address(stakingPool), 200e18);

        vm.prank(address(smartAccount));
        vm.expectRevert(StakingExecutor.ExceedsMaxStake.selector);
        executor.stake(address(stakingPool), 200e18);
    }

    function test_stake_RevertsIf_ExceedsDailyLimit() public {
        bytes memory installData = abi.encode(DEFAULT_MAX_STAKE, 100e18); // daily limit 100
        vm.prank(address(smartAccount));
        executor.onInstall(installData);

        vm.prank(address(smartAccount));
        executor.addAllowedPool(address(stakingPool));

        smartAccount.approveToken(address(stakingToken), address(stakingPool), 200e18);

        vm.prank(address(smartAccount));
        vm.expectRevert(StakingExecutor.ExceedsDailyLimit.selector);
        executor.stake(address(stakingPool), 200e18);
    }

    function test_stake_ResetsDailyLimit_AfterDay() public {
        bytes memory installData = abi.encode(DEFAULT_MAX_STAKE, 100e18);
        vm.prank(address(smartAccount));
        executor.onInstall(installData);

        vm.prank(address(smartAccount));
        executor.addAllowedPool(address(stakingPool));

        smartAccount.approveToken(address(stakingToken), address(stakingPool), 200e18);

        // First stake
        vm.prank(address(smartAccount));
        executor.stake(address(stakingPool), 100e18);

        // Advance time by 1 day
        vm.warp(block.timestamp + 1 days + 1);

        // Second stake should succeed
        vm.prank(address(smartAccount));
        executor.stake(address(stakingPool), 100e18);

        assertEq(stakingPool.stakedAmount(address(smartAccount)), 200e18);
    }

    function test_stakeWithLock_Success() public {
        _installExecutorAndAllowPool();

        uint256 amount = 100e18;
        uint256 lockDuration = 30 days;

        smartAccount.approveToken(address(stakingToken), address(stakingPool), amount);

        vm.prank(address(smartAccount));
        executor.stakeWithLock(address(stakingPool), amount, lockDuration);

        assertEq(stakingPool.stakedAmount(address(smartAccount)), amount);
    }

    // =========================================================================
    // Unstake Tests
    // =========================================================================

    function test_unstake_Success() public {
        _installExecutorAndAllowPool();

        uint256 amount = 100e18;
        smartAccount.approveToken(address(stakingToken), address(stakingPool), amount);

        vm.prank(address(smartAccount));
        executor.stake(address(stakingPool), amount);

        // Advance time past lock
        vm.warp(block.timestamp + 30 days);

        vm.prank(address(smartAccount));
        executor.unstake(address(stakingPool), amount);

        assertEq(stakingPool.stakedAmount(address(smartAccount)), 0);
    }

    function test_unstake_RevertsIf_PoolNotAllowed() public {
        _installExecutor();

        vm.prank(address(smartAccount));
        vm.expectRevert(StakingExecutor.PoolNotAllowed.selector);
        executor.unstake(address(stakingPool), 100e18);
    }

    function test_unstake_RevertsIf_Paused() public {
        _installExecutorAndAllowPool();

        vm.prank(address(smartAccount));
        executor.setPaused(true);

        vm.prank(address(smartAccount));
        vm.expectRevert(StakingExecutor.ExecutorPaused.selector);
        executor.unstake(address(stakingPool), 100e18);
    }

    // =========================================================================
    // Claim Rewards Tests
    // =========================================================================

    function test_claimRewards_Success() public {
        _installExecutorAndAllowPool();

        uint256 amount = 100e18;
        smartAccount.approveToken(address(stakingToken), address(stakingPool), amount);

        vm.prank(address(smartAccount));
        executor.stake(address(stakingPool), amount);

        // Set pending rewards in mock
        stakingPool.setPendingRewards(address(smartAccount), 10e18);

        uint256 balanceBefore = rewardToken.balanceOf(address(smartAccount));

        vm.prank(address(smartAccount));
        executor.claimRewards(address(stakingPool));

        uint256 balanceAfter = rewardToken.balanceOf(address(smartAccount));
        assertEq(balanceAfter - balanceBefore, 10e18);
    }

    function test_claimRewards_RevertsIf_PoolNotAllowed() public {
        _installExecutor();

        vm.prank(address(smartAccount));
        vm.expectRevert(StakingExecutor.PoolNotAllowed.selector);
        executor.claimRewards(address(stakingPool));
    }

    // =========================================================================
    // Compound Rewards Tests
    // =========================================================================

    function test_compoundRewards_Success() public {
        _installExecutorAndAllowPool();

        uint256 amount = 100e18;
        smartAccount.approveToken(address(stakingToken), address(stakingPool), amount);

        vm.prank(address(smartAccount));
        executor.stake(address(stakingPool), amount);

        // Set pending rewards (must be same token as staking for compound)
        stakingPool.setCompoundable(true);
        stakingPool.setPendingRewards(address(smartAccount), 10e18);

        vm.prank(address(smartAccount));
        executor.compoundRewards(address(stakingPool));

        // Staked amount should increase by rewards
        assertEq(stakingPool.stakedAmount(address(smartAccount)), amount + 10e18);
    }

    function test_compoundRewards_RevertsIf_PoolNotAllowed() public {
        _installExecutor();

        vm.prank(address(smartAccount));
        vm.expectRevert(StakingExecutor.PoolNotAllowed.selector);
        executor.compoundRewards(address(stakingPool));
    }

    // =========================================================================
    // View Functions Tests
    // =========================================================================

    function test_getStakedAmount_ReturnsCorrectAmount() public {
        _installExecutorAndAllowPool();

        uint256 amount = 100e18;
        smartAccount.approveToken(address(stakingToken), address(stakingPool), amount);

        vm.prank(address(smartAccount));
        executor.stake(address(stakingPool), amount);

        uint256 staked = executor.getStakedAmount(address(smartAccount), address(stakingPool));
        assertEq(staked, amount);
    }

    function test_getPendingRewards_ReturnsCorrectAmount() public {
        _installExecutorAndAllowPool();

        uint256 amount = 100e18;
        smartAccount.approveToken(address(stakingToken), address(stakingPool), amount);

        vm.prank(address(smartAccount));
        executor.stake(address(stakingPool), amount);

        stakingPool.setPendingRewards(address(smartAccount), 10e18);

        uint256 pending = executor.getPendingRewards(address(smartAccount), address(stakingPool));
        assertEq(pending, 10e18);
    }

    function test_getDailyUsed_ReturnsCorrectAmount() public {
        _installExecutorAndAllowPool();

        uint256 amount = 100e18;
        smartAccount.approveToken(address(stakingToken), address(stakingPool), amount);

        vm.prank(address(smartAccount));
        executor.stake(address(stakingPool), amount);

        uint256 used = executor.getDailyUsed(address(smartAccount));
        assertEq(used, amount);
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_stake_ValidAmounts(uint256 amount) public {
        vm.assume(amount > 0 && amount <= DEFAULT_MAX_STAKE && amount <= DEFAULT_DAILY_LIMIT);

        _installExecutorAndAllowPool();

        stakingToken.mint(address(smartAccount), amount);
        smartAccount.approveToken(address(stakingToken), address(stakingPool), amount);

        vm.prank(address(smartAccount));
        executor.stake(address(stakingPool), amount);

        assertEq(stakingPool.stakedAmount(address(smartAccount)), amount);
    }

    function testFuzz_unstake_ValidAmounts(uint256 stakeAmount, uint256 unstakeAmount) public {
        vm.assume(stakeAmount > 0 && stakeAmount <= DEFAULT_MAX_STAKE && stakeAmount <= DEFAULT_DAILY_LIMIT);
        vm.assume(unstakeAmount > 0 && unstakeAmount <= stakeAmount);

        _installExecutorAndAllowPool();

        stakingToken.mint(address(smartAccount), stakeAmount);
        smartAccount.approveToken(address(stakingToken), address(stakingPool), stakeAmount);

        vm.prank(address(smartAccount));
        executor.stake(address(stakingPool), stakeAmount);

        // Advance time
        vm.warp(block.timestamp + 30 days);

        vm.prank(address(smartAccount));
        executor.unstake(address(stakingPool), unstakeAmount);

        assertEq(stakingPool.stakedAmount(address(smartAccount)), stakeAmount - unstakeAmount);
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _installExecutor() internal {
        bytes memory installData = abi.encode(DEFAULT_MAX_STAKE, DEFAULT_DAILY_LIMIT);
        vm.prank(address(smartAccount));
        executor.onInstall(installData);
    }

    function _installExecutorAndAllowPool() internal {
        _installExecutor();

        vm.prank(address(smartAccount));
        executor.addAllowedPool(address(stakingPool));
    }
}

// =========================================================================
// Mock Contracts
// =========================================================================

contract MockSmartAccount {
    address public executor;

    constructor(address _executor) {
        executor = _executor;
    }

    function executeFromExecutor(
        bytes32 mode,
        bytes calldata executionCalldata
    ) external returns (bytes[] memory returnData) {
        require(msg.sender == executor, "Not executor");
        (mode); // Silence unused

        // Decode single call: (target, value, data)
        (address target, uint256 value, bytes memory data) = abi.decode(executionCalldata, (address, uint256, bytes));

        returnData = new bytes[](1);
        (bool success, bytes memory result) = target.call{value: value}(data);
        require(success, "Execution failed");
        returnData[0] = result;
    }

    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    receive() external payable {}
}

contract MockStakingPool {
    address public stakingToken;
    address public rewardToken;

    mapping(address => uint256) public stakedAmounts;
    mapping(address => uint256) public pendingRewardsMap;
    mapping(address => uint256) public lockUntil;
    bool public compoundable;

    constructor(address _stakingToken, address _rewardToken) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
    }

    function stake(uint256 amount) external {
        IERC20(stakingToken).transferFrom(msg.sender, address(this), amount);
        stakedAmounts[msg.sender] += amount;
        lockUntil[msg.sender] = block.timestamp + 7 days;
    }

    function stakeWithLock(uint256 amount, uint256 lockDuration) external {
        IERC20(stakingToken).transferFrom(msg.sender, address(this), amount);
        stakedAmounts[msg.sender] += amount;
        lockUntil[msg.sender] = block.timestamp + lockDuration;
    }

    function unstake(uint256 amount) external {
        require(stakedAmounts[msg.sender] >= amount, "Insufficient stake");
        stakedAmounts[msg.sender] -= amount;
        IERC20(stakingToken).transfer(msg.sender, amount);
    }

    function claim() external {
        uint256 rewards = pendingRewardsMap[msg.sender];
        pendingRewardsMap[msg.sender] = 0;
        IERC20(rewardToken).transfer(msg.sender, rewards);
    }

    function compound() external {
        require(compoundable, "Not compoundable");
        uint256 rewards = pendingRewardsMap[msg.sender];
        pendingRewardsMap[msg.sender] = 0;
        stakedAmounts[msg.sender] += rewards;
    }

    function stakedAmount(address user) external view returns (uint256) {
        return stakedAmounts[user];
    }

    function pendingRewards(address user) external view returns (uint256) {
        return pendingRewardsMap[user];
    }

    function setPendingRewards(address user, uint256 amount) external {
        pendingRewardsMap[user] = amount;
    }

    function setCompoundable(bool _compoundable) external {
        compoundable = _compoundable;
    }
}

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
}
