// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import { Script, console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "../utils/DeploymentAddresses.sol";
import { ERC7715PermissionManager } from "../../src/subscription/ERC7715PermissionManager.sol";
import { SubscriptionManager } from "../../src/subscription/SubscriptionManager.sol";

/**
 * @title DeploySubscriptionScript
 * @notice Deployment script for Subscription contracts (ERC-7715 Permission System)
 * @dev Deploys ERC7715PermissionManager and SubscriptionManager
 *
 * Deployed Contracts:
 *   - ERC7715PermissionManager: On-chain permission management based on ERC-7715
 *   - SubscriptionManager: Recurring subscription payments using ERC-7715 permissions
 *
 * Deployment Order:
 *   1. ERC7715PermissionManager (Layer 0 - no dependencies)
 *   2. SubscriptionManager (Layer 1 - depends on PermissionManager)
 *
 * Post-Deployment Configuration:
 *   - Add SubscriptionManager as authorized executor in PermissionManager
 *
 * Usage:
 *   FOUNDRY_PROFILE=subscription forge script script/deploy-contract/DeploySubscription.s.sol:DeploySubscriptionScript
 * \
 *     --rpc-url <RPC_URL> --broadcast
 */
contract DeploySubscriptionScript is DeploymentHelper {
    ERC7715PermissionManager public permissionManager;
    SubscriptionManager public subscriptionManager;

    function setUp() public { }

    function run() public {
        _initDeployment();

        vm.startBroadcast();

        // ============ Layer 0: No Dependencies ============

        // Deploy ERC7715PermissionManager
        address existing = _getAddress(DeploymentAddresses.KEY_PERMISSION_MANAGER);
        if (existing == address(0)) {
            permissionManager = new ERC7715PermissionManager();
            _setAddress(DeploymentAddresses.KEY_PERMISSION_MANAGER, address(permissionManager));
            console.log("ERC7715PermissionManager deployed at:", address(permissionManager));
        } else {
            permissionManager = ERC7715PermissionManager(existing);
            console.log("ERC7715PermissionManager: Using existing at", existing);
        }

        // ============ Layer 1: Depends on PermissionManager ============

        // Deploy SubscriptionManager
        existing = _getAddress(DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER);
        if (existing == address(0)) {
            subscriptionManager = new SubscriptionManager(address(permissionManager));
            _setAddress(DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER, address(subscriptionManager));
            console.log("SubscriptionManager deployed at:", address(subscriptionManager));

            // Configure PermissionManager: Add SubscriptionManager as authorized executor
            permissionManager.addAuthorizedExecutor(address(subscriptionManager));
            console.log("  Added SubscriptionManager as authorized executor");
        } else {
            subscriptionManager = SubscriptionManager(payable(existing));
            console.log("SubscriptionManager: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        console.log("\n=== Subscription Deployment Summary ===");
        console.log("ERC7715PermissionManager:", address(permissionManager));
        console.log("  DOMAIN_SEPARATOR:", vm.toString(permissionManager.DOMAIN_SEPARATOR()));
        console.log("  Supported permission types:");
        console.log("    - native-token-recurring-allowance");
        console.log("    - erc20-recurring-allowance");
        console.log("    - session-key");
        console.log("    - subscription");
        console.log("    - spending-limit");
        console.log("SubscriptionManager:", address(subscriptionManager));
        console.log("  Protocol Fee:", subscriptionManager.protocolFeeBps(), "bps");
        console.log("  Fee Recipient:", subscriptionManager.feeRecipient());
        console.log("\nSubscription system is ready for use:");
        console.log("  1. Merchants create subscription plans");
        console.log("  2. Users grant permission via PermissionManager");
        console.log("  3. Users subscribe to plans, linking the permission");
        console.log("  4. Payments are processed automatically");
    }
}
