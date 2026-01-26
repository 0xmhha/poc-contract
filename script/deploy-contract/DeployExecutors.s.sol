// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";
import {SessionKeyExecutor} from "../../src/erc7579-executors/SessionKeyExecutor.sol";
import {RecurringPaymentExecutor} from "../../src/erc7579-executors/RecurringPaymentExecutor.sol";

/**
 * @title DeployExecutorsScript
 * @notice Deployment script for ERC-7579 Executor modules
 * @dev Deploys executor modules for smart account automation
 *
 * Executor Modules:
 *   - SessionKeyExecutor: Temporary session keys with time/target/function restrictions
 *   - RecurringPaymentExecutor: Automated recurring payments (subscriptions, salary, etc.)
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

    function setUp() public {}

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

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        console.log("\n=== Executors Deployment Summary ===");
        console.log("SessionKeyExecutor:", address(sessionKeyExecutor));
        console.log("RecurringPaymentExecutor:", address(recurringPaymentExecutor));
        console.log("\nNote: Executors are installed on SmartAccounts via installModule()");
        console.log("  - SessionKeyExecutor: Use for gaming dApps, DeFi automation, delegated execution");
        console.log("  - RecurringPaymentExecutor: Use for subscriptions, salary, donations, rent");
    }
}
