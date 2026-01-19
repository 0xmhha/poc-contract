// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AuditHook} from "../src/erc7579-hooks/AuditHook.sol";
import {SpendingLimitHook} from "../src/erc7579-hooks/SpendingLimitHook.sol";

/**
 * @title DeployHooksScript
 * @notice Deployment script for ERC-7579 Hook modules
 * @dev Deploys all hook modules for smart account pre/post execution hooks
 *
 * Usage:
 *   forge script script/DeployHooks.s.sol:DeployHooksScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployHooksScript is Script {
    AuditHook public auditHook;
    SpendingLimitHook public spendingLimitHook;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // Deploy Audit Hook
        auditHook = new AuditHook();
        console.log("AuditHook deployed at:", address(auditHook));

        // Deploy Spending Limit Hook
        spendingLimitHook = new SpendingLimitHook();
        console.log("SpendingLimitHook deployed at:", address(spendingLimitHook));

        vm.stopBroadcast();

        // Log summary
        console.log("\n=== Hooks Deployment Summary ===");
        console.log("AuditHook:", address(auditHook));
        console.log("SpendingLimitHook:", address(spendingLimitHook));
    }
}
