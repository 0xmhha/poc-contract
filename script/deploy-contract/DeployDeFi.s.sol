// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import { Script, console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "../utils/DeploymentAddresses.sol";
import { PriceOracle } from "../../src/defi/PriceOracle.sol";
import { LendingPool } from "../../src/defi/LendingPool.sol";
import { StakingVault, IStakingVault } from "../../src/defi/StakingVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployDeFiScript
 * @notice Deployment script for DeFi contracts (PriceOracle, LendingPool, StakingVault)
 * @dev Deploys core DeFi infrastructure contracts
 *
 * Deployed Contracts:
 *   - PriceOracle: Unified price oracle supporting Chainlink feeds and Uniswap V3 TWAP
 *   - LendingPool: Collateral-based lending pool with variable interest rates
 *   - StakingVault: Staking vault with time-locked rewards
 *
 * Deployment Order:
 *   1. PriceOracle (Layer 0 - no dependencies)
 *   2. LendingPool (Layer 1 - depends on PriceOracle)
 *   3. StakingVault (Layer 0 - no dependencies, but needs token addresses)
 *
 * Environment Variables:
 *   - STAKING_TOKEN: Token to stake (defaults to WKRC from deployment or 0x1000)
 *   - REWARD_TOKEN: Token for rewards (defaults to same as staking token)
 *   - REWARD_RATE: Rewards per second (default: 1e15 = 0.001 tokens/sec)
 *   - LOCK_PERIOD: Lock period in seconds (default: 7 days)
 *   - EARLY_WITHDRAW_PENALTY: Penalty in basis points (default: 1000 = 10%)
 *   - MIN_STAKE: Minimum stake amount (default: 1e18 = 1 token)
 *   - MAX_STAKE: Maximum stake amount (default: 0 = unlimited)
 *
 * Usage:
 *   FOUNDRY_PROFILE=defi forge script script/deploy-contract/DeployDeFi.s.sol:DeployDeFiScript \
 *     --rpc-url <RPC_URL> --broadcast
 */
contract DeployDeFiScript is DeploymentHelper {
    PriceOracle public priceOracle;
    LendingPool public lendingPool;
    StakingVault public stakingVault;

    // Default NativeCoinAdapter address (precompiled)
    address constant NATIVE_COIN_ADAPTER = address(0x1000);

    function setUp() public { }

    function run() public {
        _initDeployment();

        vm.startBroadcast();

        // ============ Layer 0: No Dependencies ============

        // Deploy PriceOracle
        address existing = _getAddress(DeploymentAddresses.KEY_PRICE_ORACLE);
        if (existing == address(0)) {
            priceOracle = new PriceOracle();
            _setAddress(DeploymentAddresses.KEY_PRICE_ORACLE, address(priceOracle));
            console.log("PriceOracle deployed at:", address(priceOracle));
        } else {
            priceOracle = PriceOracle(existing);
            console.log("PriceOracle: Using existing at", existing);
        }

        // ============ Layer 1: Depends on PriceOracle ============

        // Deploy LendingPool
        existing = _getAddress(DeploymentAddresses.KEY_LENDING_POOL);
        if (existing == address(0)) {
            lendingPool = new LendingPool(address(priceOracle));
            _setAddress(DeploymentAddresses.KEY_LENDING_POOL, address(lendingPool));
            console.log("LendingPool deployed at:", address(lendingPool));
            console.log("  PriceOracle:", address(priceOracle));
        } else {
            lendingPool = LendingPool(existing);
            console.log("LendingPool: Using existing at", existing);
        }

        // ============ Layer 0: StakingVault (Independent) ============

        // Deploy StakingVault
        existing = _getAddress(DeploymentAddresses.KEY_STAKING_VAULT);
        if (existing == address(0)) {
            // Get staking token (default to WKRC/NativeCoinAdapter)
            address stakingToken = _getAddressOrEnv(DeploymentAddresses.KEY_WKRC, "STAKING_TOKEN");
            if (stakingToken == address(0)) {
                stakingToken = NATIVE_COIN_ADAPTER;
                console.log("StakingVault: Using NativeCoinAdapter as staking token");
            }

            // Get reward token (default to same as staking token)
            address rewardToken = vm.envOr("REWARD_TOKEN", stakingToken);

            // Build vault config
            IStakingVault.VaultConfig memory config = IStakingVault.VaultConfig({
                rewardRate: vm.envOr("REWARD_RATE", uint256(1e15)), // 0.001 tokens/sec
                lockPeriod: vm.envOr("LOCK_PERIOD", uint256(7 days)),
                earlyWithdrawPenalty: vm.envOr("EARLY_WITHDRAW_PENALTY", uint256(1000)), // 10%
                minStake: vm.envOr("MIN_STAKE", uint256(1e18)), // 1 token
                maxStake: vm.envOr("MAX_STAKE", uint256(0)), // unlimited
                isActive: true
            });

            stakingVault = new StakingVault(stakingToken, rewardToken, config);
            _setAddress(DeploymentAddresses.KEY_STAKING_VAULT, address(stakingVault));
            console.log("StakingVault deployed at:", address(stakingVault));
            console.log("  Staking Token:", stakingToken);
            console.log("  Reward Token:", rewardToken);
            console.log("  Reward Rate:", config.rewardRate, "per second");
            console.log("  Lock Period:", config.lockPeriod / 1 days, "days");
            console.log("  Early Withdraw Penalty:", config.earlyWithdrawPenalty / 100, "%");
        } else {
            stakingVault = StakingVault(existing);
            console.log("StakingVault: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        console.log("\n=== DeFi Deployment Summary ===");
        console.log("PriceOracle:", address(priceOracle));
        console.log("  Staleness Threshold:", priceOracle.stalenessThreshold() / 1 hours, "hours");
        console.log("  Supports: Chainlink feeds, Uniswap V3 TWAP");

        console.log("LendingPool:", address(lendingPool));
        console.log("  Oracle:", address(lendingPool.oracle()));
        console.log("  Flash Loan Fee:", lendingPool.FLASH_LOAN_FEE(), "bps");

        console.log("StakingVault:", address(stakingVault));
        console.log("  Staking Token:", address(stakingVault.stakingToken()));
        console.log("  Reward Token:", address(stakingVault.rewardToken()));

        console.log("\nDeFi contracts are ready for configuration:");
        console.log("  1. PriceOracle: Add Chainlink feeds or Uniswap pools for price data");
        console.log("  2. LendingPool: Configure assets with configureAsset()");
        console.log("  3. StakingVault: Add rewards with addRewards()");
        console.log("\nNote: Deploy UniswapV3 first for full DeFi functionality:");
        console.log("  ./script/deploy-uniswap.sh --broadcast");
    }
}
