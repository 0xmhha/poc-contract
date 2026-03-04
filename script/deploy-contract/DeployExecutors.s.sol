// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import { Script, console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "../utils/DeploymentAddresses.sol";
import { SessionKeyExecutor } from "../../src/erc7579-executors/SessionKeyExecutor.sol";
import { RecurringPaymentExecutor } from "../../src/erc7579-executors/RecurringPaymentExecutor.sol";
import { SwapExecutor } from "../../src/erc7579-executors/SwapExecutor.sol";
import { StakingExecutor } from "../../src/erc7579-executors/StakingExecutor.sol";
import { LendingExecutor } from "../../src/erc7579-executors/LendingExecutor.sol";

/**
 * @title DeployExecutorsScript
 * @notice Deployment script for ERC-7579 Executor modules
 * @dev Deploys executor modules for smart account automation
 *
 * Executor Modules:
 *   - SessionKeyExecutor: Temporary session keys with time/target/function restrictions
 *   - RecurringPaymentExecutor: Automated recurring payments (subscriptions, salary, etc.)
 *   - SwapExecutor: DEX swap execution with slippage protection
 *   - StakingExecutor: Staking pool management and delegation
 *   - LendingExecutor: Lending pool interactions (supply, borrow, repay)
 *
 * Deployment Order: 7 (after Fallbacks)
 *
 * Usage:
 *   forge script script/deploy-contract/DeployExecutors.s.sol:DeployExecutorsScript \
 *     --rpc-url <RPC_URL> --broadcast
 *
 * With executors profile:
 *   FOUNDRY_PROFILE=executors forge script script/deploy-contract/DeployExecutors.s.sol:DeployExecutorsScript \
 *     --rpc-url <RPC_URL> --broadcast
 */
contract DeployExecutorsScript is DeploymentHelper {
    SessionKeyExecutor public sessionKeyExecutor;
    RecurringPaymentExecutor public recurringPaymentExecutor;
    SwapExecutor public swapExecutor;
    StakingExecutor public stakingExecutor;
    LendingExecutor public lendingExecutor;

    function setUp() public { }

    function run() public {
        _initDeployment();

        vm.startBroadcast();

        // Deploy SessionKeyExecutor
        address existing = _getAddress(DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR);
        if (existing == address(0)) {
            sessionKeyExecutor = new SessionKeyExecutor();
            _setAddress(DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR, address(sessionKeyExecutor));
            console.log("SessionKeyExecutor deployed at:", address(sessionKeyExecutor));
        } else {
            sessionKeyExecutor = SessionKeyExecutor(existing);
            console.log("SessionKeyExecutor: Using existing at", existing);
        }

        // Deploy RecurringPaymentExecutor
        existing = _getAddress(DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR);
        if (existing == address(0)) {
            recurringPaymentExecutor = new RecurringPaymentExecutor();
            _setAddress(DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR, address(recurringPaymentExecutor));
            console.log("RecurringPaymentExecutor deployed at:", address(recurringPaymentExecutor));
        } else {
            recurringPaymentExecutor = RecurringPaymentExecutor(existing);
            console.log("RecurringPaymentExecutor: Using existing at", existing);
        }

        // Deploy SwapExecutor (requires SwapRouter and Quoter from UniswapV3)
        existing = _getAddress(DeploymentAddresses.KEY_SWAP_EXECUTOR);
        if (existing == address(0)) {
            address swapRouter = _addresses[DeploymentAddresses.KEY_UNISWAP_SWAP_ROUTER];
            address quoter = _addresses[DeploymentAddresses.KEY_UNISWAP_QUOTER];
            if (swapRouter == address(0)) {
                console.log("Warning: SwapRouter not found. Skipping SwapExecutor deployment.");
                console.log("  Deploy UniswapV3 first or set uniswapV3SwapRouter in addresses.");
            } else if (quoter == address(0)) {
                console.log("Warning: Quoter not found. Skipping SwapExecutor deployment.");
                console.log("  Deploy UniswapV3 first or set uniswapV3Quoter in addresses.");
            } else {
                swapExecutor = new SwapExecutor(swapRouter, quoter);
                _setAddress(DeploymentAddresses.KEY_SWAP_EXECUTOR, address(swapExecutor));
                console.log("SwapExecutor deployed at:", address(swapExecutor));
            }
        } else {
            swapExecutor = SwapExecutor(existing);
            console.log("SwapExecutor: Using existing at", existing);
        }

        // Deploy StakingExecutor
        existing = _getAddress(DeploymentAddresses.KEY_STAKING_EXECUTOR);
        if (existing == address(0)) {
            stakingExecutor = new StakingExecutor();
            _setAddress(DeploymentAddresses.KEY_STAKING_EXECUTOR, address(stakingExecutor));
            console.log("StakingExecutor deployed at:", address(stakingExecutor));
        } else {
            stakingExecutor = StakingExecutor(existing);
            console.log("StakingExecutor: Using existing at", existing);
        }

        // Deploy LendingExecutor (requires LendingPool)
        existing = _getAddress(DeploymentAddresses.KEY_LENDING_EXECUTOR);
        if (existing == address(0)) {
            address lendingPool = _addresses[DeploymentAddresses.KEY_LENDING_POOL];
            if (lendingPool == address(0)) {
                console.log("Warning: LendingPool not found. Skipping LendingExecutor deployment.");
                console.log("  Deploy DeFi contracts first or set lendingPool in addresses.");
            } else {
                lendingExecutor = new LendingExecutor(lendingPool);
                _setAddress(DeploymentAddresses.KEY_LENDING_EXECUTOR, address(lendingExecutor));
                console.log("LendingExecutor deployed at:", address(lendingExecutor));
            }
        } else {
            lendingExecutor = LendingExecutor(existing);
            console.log("LendingExecutor: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        console.log("\n=== Executors Deployment Summary ===");
        console.log("SessionKeyExecutor:", address(sessionKeyExecutor));
        console.log("RecurringPaymentExecutor:", address(recurringPaymentExecutor));
        if (address(swapExecutor) != address(0)) {
            console.log("SwapExecutor:", address(swapExecutor));
        } else {
            console.log("SwapExecutor: NOT DEPLOYED (missing UniswapV3 dependency)");
        }
        console.log("StakingExecutor:", address(stakingExecutor));
        if (address(lendingExecutor) != address(0)) {
            console.log("LendingExecutor:", address(lendingExecutor));
        } else {
            console.log("LendingExecutor: NOT DEPLOYED (missing LendingPool dependency)");
        }
        console.log("\nNote: Executors are installed on SmartAccounts via installModule()");
        console.log("  - SessionKeyExecutor: Use for gaming dApps, DeFi automation, delegated execution");
        console.log("  - RecurringPaymentExecutor: Use for subscriptions, salary, donations, rent");
        console.log("  - SwapExecutor: Use for DEX swaps with slippage protection");
        console.log("  - StakingExecutor: Use for staking pool management");
        console.log("  - LendingExecutor: Use for lending pool interactions");
    }
}
