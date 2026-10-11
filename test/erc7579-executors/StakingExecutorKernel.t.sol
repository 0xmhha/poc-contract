// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { KernelModuleTestBase } from "../utils/KernelModuleTestBase.sol";
import { StakingExecutor } from "../../src/erc7579-executors/StakingExecutor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockStakingPool, MockERC20 } from "./StakingExecutor.t.sol";

/// @notice StakingExecutor driven through a real Kernel account.
/// @dev Regression: the executor used to build single-execution calldata with abi.encode, which Kernel
///      decodes as packed target || value || callData, so every stake/unstake/claim reverted.
contract StakingExecutorKernelTest is KernelModuleTestBase {
    StakingExecutor internal executor;
    MockStakingPool internal pool;
    MockERC20 internal stakingToken;
    MockERC20 internal rewardToken;
    address internal account;

    function setUp() public {
        _deployKernel();
        account = _createAccount(0);

        stakingToken = new MockERC20("Staking Token", "STK");
        rewardToken = new MockERC20("Reward Token", "RWD");
        pool = new MockStakingPool(address(stakingToken), address(rewardToken));
        executor = new StakingExecutor();

        stakingToken.mint(account, 1000e18);
        rewardToken.mint(address(pool), 1000e18);

        _installExecutor(account, address(executor), "");
        _execAsAccount(account, address(executor), abi.encodeCall(StakingExecutor.addAllowedPool, (address(pool))));
        _execAsAccount(account, address(stakingToken), abi.encodeCall(IERC20.approve, (address(pool), 1000e18)));
    }

    function test_Stake_ThroughKernel() public {
        _execAsAccount(account, address(executor), abi.encodeCall(StakingExecutor.stake, (address(pool), 100e18)));

        assertEq(pool.stakedAmount(account), 100e18);
        assertEq(stakingToken.balanceOf(account), 900e18);
        assertEq(executor.getStakedAmount(account, address(pool)), 100e18);
    }

    function test_Unstake_ThroughKernel() public {
        _execAsAccount(account, address(executor), abi.encodeCall(StakingExecutor.stake, (address(pool), 100e18)));
        _execAsAccount(account, address(executor), abi.encodeCall(StakingExecutor.unstake, (address(pool), 40e18)));

        assertEq(pool.stakedAmount(account), 60e18);
        assertEq(stakingToken.balanceOf(account), 940e18);
    }

    function test_Claim_ThroughKernel() public {
        pool.setPendingRewards(account, 5e18);

        _execAsAccount(account, address(executor), abi.encodeCall(StakingExecutor.claimRewards, (address(pool))));

        assertEq(rewardToken.balanceOf(account), 5e18);
        assertEq(pool.pendingRewards(account), 0);
    }
}
