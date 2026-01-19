// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "./utils/DeploymentAddresses.sol";
import {ERC7715PermissionManager} from "../src/subscription/ERC7715PermissionManager.sol";
import {SubscriptionManager} from "../src/subscription/SubscriptionManager.sol";

/**
 * @title DeploySubscriptionScript
 * @notice Deployment script for subscription infrastructure (ERC-7715)
 * @dev Deploys permission and subscription management contracts
 *
 * Deployment Order:
 *   1. ERC7715PermissionManager - Permission delegation management
 *   2. SubscriptionManager - Recurring subscription payments (depends on PermissionManager)
 *
 * Dependencies:
 *   - SubscriptionManager requires ERC7715PermissionManager address
 *
 * Usage:
 *   forge script script/DeploySubscription.s.sol:DeploySubscriptionScript --rpc-url <RPC_URL> --broadcast
 */
contract DeploySubscriptionScript is DeploymentHelper {
    ERC7715PermissionManager public permissionManager;
    SubscriptionManager public subscriptionManager;

    function setUp() public {}

    function run() public {
        _initDeployment();

        console.log("=== Deploying Subscription Infrastructure ===");

        vm.startBroadcast();

        // 1. Deploy ERC-7715 Permission Manager (or use existing)
        address existingPm = _getAddress(DeploymentAddresses.KEY_PERMISSION_MANAGER);
        if (existingPm == address(0)) {
            permissionManager = new ERC7715PermissionManager();
            _setAddress(DeploymentAddresses.KEY_PERMISSION_MANAGER, address(permissionManager));
            console.log("ERC7715PermissionManager deployed at:", address(permissionManager));
        } else {
            permissionManager = ERC7715PermissionManager(existingPm);
            console.log("ERC7715PermissionManager: Using existing at", existingPm);
        }

        // 2. Deploy Subscription Manager (depends on PermissionManager)
        subscriptionManager = new SubscriptionManager(address(permissionManager));
        _setAddress(DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER, address(subscriptionManager));
        console.log("SubscriptionManager deployed at:", address(subscriptionManager));

        vm.stopBroadcast();

        // Save addresses
        _saveAddresses();

        // Log summary
        console.log("\n=== Subscription Deployment Summary ===");
        console.log("ERC7715PermissionManager:", address(permissionManager));
        console.log("SubscriptionManager:", address(subscriptionManager));
    }
}

/**
 * @title DeploySubscriptionWithExistingScript
 * @notice Deployment script for SubscriptionManager with existing PermissionManager
 *
 * Environment Variables:
 *   - PERMISSION_MANAGER: Existing ERC7715PermissionManager address
 *
 * Usage:
 *   PERMISSION_MANAGER=0x... forge script script/DeploySubscription.s.sol:DeploySubscriptionWithExistingScript --rpc-url <RPC_URL> --broadcast
 */
contract DeploySubscriptionWithExistingScript is Script {
    function run() public {
        address permissionManager = vm.envAddress("PERMISSION_MANAGER");

        vm.startBroadcast();

        SubscriptionManager subscriptionManager = new SubscriptionManager(permissionManager);

        vm.stopBroadcast();

        console.log("SubscriptionManager deployed at:", address(subscriptionManager));
        console.log("Using PermissionManager:", permissionManager);
    }
}
