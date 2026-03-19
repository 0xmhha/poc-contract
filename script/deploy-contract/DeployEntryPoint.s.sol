// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import { Script, console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "../utils/DeploymentAddresses.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";
import { Create2Deployer } from "../../src/erc4337-entrypoint/Create2Deployer.sol";

/// @title DeployEntryPointScript
/// @notice Deploys EntryPoint via our own Create2Deployer for deterministic addresses.
///
///         Flow:
///           1. Deploy Create2Deployer (regular CREATE — address depends on deployer nonce)
///           2. Deploy EntryPoint via Create2Deployer.deploy() (CREATE2 — deterministic)
///
///         As long as the deployment order is consistent (same EOA, same nonce),
///         Create2Deployer gets the same address, and EntryPoint gets the same address.
///         No dependency on Nick's Deterministic Deployer or genesis modification.
contract DeployEntryPointScript is DeploymentHelper {
    EntryPoint public entryPoint;

    bytes32 constant DEFAULT_SALT = keccak256("stable-net-entrypoint-v1");

    function setUp() public { }

    function run() public {
        _initDeployment();

        // Check if EntryPoint already exists
        address existingEntryPoint = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
        if (existingEntryPoint != address(0)) {
            entryPoint = EntryPoint(payable(existingEntryPoint));
            console.log("EntryPoint: Using existing at", existingEntryPoint);
            _saveAddresses();
            return;
        }

        bytes32 salt = _getDeploySalt();

        vm.startBroadcast();

        // Step 1: Deploy or reuse Create2Deployer
        Create2Deployer factory = _ensureCreate2Deployer();

        // Step 2: Deploy EntryPoint via CREATE2
        bytes memory initCode = type(EntryPoint).creationCode;
        address predicted = factory.computeAddress(initCode, salt);

        if (predicted.code.length > 0) {
            // Already deployed at the predicted address (e.g., chain wasn't fully reset)
            entryPoint = EntryPoint(payable(predicted));
            console.log("EntryPoint: Already at CREATE2 address:", predicted);
        } else {
            address deployed = factory.deploy(initCode, salt);
            entryPoint = EntryPoint(payable(deployed));
            console.log("EntryPoint deployed via CREATE2 at:", deployed);
            console.log("  Factory:", address(factory));
            console.log("  Salt:", vm.toString(salt));
        }

        vm.stopBroadcast();

        _setAddress(DeploymentAddresses.KEY_ENTRYPOINT, address(entryPoint));
        console.log("SenderCreator deployed at:", address(entryPoint.senderCreator()));

        _saveAddresses();
    }

    /// @notice Deploy Create2Deployer if not already deployed, or reuse existing
    function _ensureCreate2Deployer() internal returns (Create2Deployer) {
        address existing = _addresses[DeploymentAddresses.KEY_CREATE2_DEPLOYER];

        if (existing != address(0) && existing.code.length > 0) {
            console.log("Create2Deployer: Using existing at", existing);
            return Create2Deployer(existing);
        }

        // Deploy fresh Create2Deployer via regular CREATE
        Create2Deployer factory = new Create2Deployer();
        _setAddress(DeploymentAddresses.KEY_CREATE2_DEPLOYER, address(factory));
        console.log("Create2Deployer deployed at:", address(factory));

        return factory;
    }

    /// @notice Reads salt from ENTRYPOINT_DEPLOY_SALT env var, or uses default
    function _getDeploySalt() internal view returns (bytes32) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory saltOverride = vm.envOr("ENTRYPOINT_DEPLOY_SALT", string(""));
        if (bytes(saltOverride).length > 0) {
            return keccak256(abi.encodePacked(saltOverride));
        }
        return DEFAULT_SALT;
    }
}
