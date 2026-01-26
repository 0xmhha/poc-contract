// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";
import {SpendingLimitHook} from "../../src/erc7579-hooks/SpendingLimitHook.sol";
import {AuditHook} from "../../src/erc7579-hooks/AuditHook.sol";

/**
 * @title DeployHooksScript
 * @notice Deployment script for ERC-7579 Hook modules
 * @dev Deploys hook modules for smart account transaction validation and auditing
 *
 * Hook Modules:
 *   - SpendingLimitHook: Enforces spending limits per token with time-based windows
 *   - AuditHook: Logs all transactions for compliance and audit purposes
 *
 * Deployment Order: 5 (after Validators)
 *
 * Usage:
 *   forge script script/deploy-contract/DeployHooks.s.sol:DeployHooksScript \
 *     --rpc-url <RPC_URL> --broadcast
 *
 * With hooks profile:
 *   FOUNDRY_PROFILE=hooks forge script script/deploy-contract/DeployHooks.s.sol:DeployHooksScript \
 *     --rpc-url <RPC_URL> --broadcast
 */
contract DeployHooksScript is DeploymentHelper {
    SpendingLimitHook public spendingLimitHook;
    AuditHook public auditHook;

    function setUp() public {}

    function run() public {
        _initDeployment();

        vm.startBroadcast();

        // Deploy SpendingLimitHook
        address existing = _getAddress(DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK);
        if (existing == address(0)) {
            spendingLimitHook = new SpendingLimitHook();
            _setAddress(DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK, address(spendingLimitHook));
            console.log("SpendingLimitHook deployed at:", address(spendingLimitHook));
        } else {
            spendingLimitHook = SpendingLimitHook(existing);
            console.log("SpendingLimitHook: Using existing at", existing);
        }

        // Deploy AuditHook
        existing = _getAddress(DeploymentAddresses.KEY_AUDIT_HOOK);
        if (existing == address(0)) {
            auditHook = new AuditHook();
            _setAddress(DeploymentAddresses.KEY_AUDIT_HOOK, address(auditHook));
            console.log("AuditHook deployed at:", address(auditHook));
        } else {
            auditHook = AuditHook(existing);
            console.log("AuditHook: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        console.log("\n=== Hooks Deployment Summary ===");
        console.log("SpendingLimitHook:", address(spendingLimitHook));
        console.log("AuditHook:", address(auditHook));
        console.log("\nNote: Hooks are installed on SmartAccounts via installModule()");
        console.log("  - SpendingLimitHook: Use for spending limits, corporate policies, allowances");
        console.log("  - AuditHook: Use for compliance, governance, security monitoring");
    }
}
