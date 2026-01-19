// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SessionKeyExecutor} from "../src/erc7579-executors/SessionKeyExecutor.sol";
import {RecurringPaymentExecutor} from "../src/erc7579-executors/RecurringPaymentExecutor.sol";

/**
 * @title DeployExecutorsScript
 * @notice Deployment script for ERC-7579 Executor modules
 * @dev Deploys all executor modules for smart account execution
 *
 * Usage:
 *   forge script script/DeployExecutors.s.sol:DeployExecutorsScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployExecutorsScript is Script {
    SessionKeyExecutor public sessionKeyExecutor;
    RecurringPaymentExecutor public recurringPaymentExecutor;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // Deploy Session Key Executor
        sessionKeyExecutor = new SessionKeyExecutor();
        console.log("SessionKeyExecutor deployed at:", address(sessionKeyExecutor));

        // Deploy Recurring Payment Executor
        recurringPaymentExecutor = new RecurringPaymentExecutor();
        console.log("RecurringPaymentExecutor deployed at:", address(recurringPaymentExecutor));

        vm.stopBroadcast();

        // Log summary
        console.log("\n=== Executors Deployment Summary ===");
        console.log("SessionKeyExecutor:", address(sessionKeyExecutor));
        console.log("RecurringPaymentExecutor:", address(recurringPaymentExecutor));
    }
}
