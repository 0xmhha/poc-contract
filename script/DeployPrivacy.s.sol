// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "./utils/DeploymentAddresses.sol";
import {ERC5564Announcer} from "../src/privacy/ERC5564Announcer.sol";
import {ERC6538Registry} from "../src/privacy/ERC6538Registry.sol";
import {PrivateBank} from "../src/privacy/PrivateBank.sol";

/**
 * @title DeployPrivacyScript
 * @notice Deployment script for privacy infrastructure (ERC-5564/6538)
 * @dev Deploys stealth address infrastructure for private transactions
 *
 * Deployment Order:
 *   1. ERC5564Announcer - Stealth address announcements
 *   2. ERC6538Registry - Stealth meta-address registry
 *   3. PrivateBank - Private token transfers (depends on Announcer and Registry)
 *
 * Dependencies:
 *   - PrivateBank requires ERC5564Announcer and ERC6538Registry addresses
 *
 * Usage:
 *   forge script script/DeployPrivacy.s.sol:DeployPrivacyScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployPrivacyScript is DeploymentHelper {
    ERC5564Announcer public announcer;
    ERC6538Registry public registry;
    PrivateBank public privateBank;

    function setUp() public {}

    function run() public {
        _initDeployment();

        console.log("=== Deploying Privacy Infrastructure ===");

        vm.startBroadcast();

        // 1. Deploy ERC-5564 Announcer (or use existing)
        address existingAnnouncer = _getAddress(DeploymentAddresses.KEY_ANNOUNCER);
        if (existingAnnouncer == address(0)) {
            announcer = new ERC5564Announcer();
            _setAddress(DeploymentAddresses.KEY_ANNOUNCER, address(announcer));
            console.log("ERC5564Announcer deployed at:", address(announcer));
        } else {
            announcer = ERC5564Announcer(existingAnnouncer);
            console.log("ERC5564Announcer: Using existing at", existingAnnouncer);
        }

        // 2. Deploy ERC-6538 Registry (or use existing)
        address existingRegistry = _getAddress(DeploymentAddresses.KEY_REGISTRY);
        if (existingRegistry == address(0)) {
            registry = new ERC6538Registry();
            _setAddress(DeploymentAddresses.KEY_REGISTRY, address(registry));
            console.log("ERC6538Registry deployed at:", address(registry));
        } else {
            registry = ERC6538Registry(existingRegistry);
            console.log("ERC6538Registry: Using existing at", existingRegistry);
        }

        // 3. Deploy Private Bank (depends on Announcer and Registry)
        privateBank = new PrivateBank(
            address(announcer),
            address(registry)
        );
        _setAddress(DeploymentAddresses.KEY_PRIVATE_BANK, address(privateBank));
        console.log("PrivateBank deployed at:", address(privateBank));

        vm.stopBroadcast();

        // Save addresses
        _saveAddresses();

        // Log summary
        console.log("\n=== Privacy Deployment Summary ===");
        console.log("ERC5564Announcer:", address(announcer));
        console.log("ERC6538Registry:", address(registry));
        console.log("PrivateBank:", address(privateBank));
    }
}

/**
 * @title DeployPrivacyWithExistingScript
 * @notice Deployment script for PrivateBank with existing infrastructure
 *
 * Environment Variables:
 *   - ANNOUNCER_ADDRESS: Existing ERC5564Announcer address
 *   - REGISTRY_ADDRESS: Existing ERC6538Registry address
 *
 * Usage:
 *   ANNOUNCER_ADDRESS=0x... REGISTRY_ADDRESS=0x... forge script script/DeployPrivacy.s.sol:DeployPrivacyWithExistingScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployPrivacyWithExistingScript is Script {
    function run() public {
        address announcer = vm.envAddress("ANNOUNCER_ADDRESS");
        address registry = vm.envAddress("REGISTRY_ADDRESS");

        vm.startBroadcast();

        PrivateBank privateBank = new PrivateBank(announcer, registry);

        vm.stopBroadcast();

        console.log("PrivateBank deployed at:", address(privateBank));
        console.log("Using Announcer:", announcer);
        console.log("Using Registry:", registry);
    }
}
