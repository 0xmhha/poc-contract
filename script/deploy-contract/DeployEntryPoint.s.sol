// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import { Script, console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "../utils/DeploymentAddresses.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";

/// @title DeployEntryPointScript
/// @notice Deploys EntryPoint via CREATE2 (deterministic) or CREATE (fallback).
///         CREATE2 requires Nick's Deterministic Deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C).
///         Set USE_CREATE2=true to enable CREATE2 mode (TypeScript wrapper detects this automatically).
contract DeployEntryPointScript is DeploymentHelper {
    EntryPoint public entryPoint;

    bytes32 constant DEFAULT_SALT = keccak256("stable-net-entrypoint-v1");

    function setUp() public { }

    function run() public {
        _initDeployment();

        address existing = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
        if (existing != address(0)) {
            entryPoint = EntryPoint(payable(existing));
            console.log("EntryPoint: Using existing at", existing);
            _saveAddresses();
            return;
        }

        bool useCreate2 = vm.envOr("USE_CREATE2", false);

        vm.startBroadcast();

        if (useCreate2) {
            bytes32 salt = _getDeploySalt();
            entryPoint = new EntryPoint{ salt: salt }();
            console.log("EntryPoint deployed via CREATE2 at:", address(entryPoint));
            console.log("CREATE2 salt:", vm.toString(salt));
        } else {
            entryPoint = new EntryPoint();
            console.log("EntryPoint deployed via CREATE at:", address(entryPoint));
        }

        vm.stopBroadcast();

        _setAddress(DeploymentAddresses.KEY_ENTRYPOINT, address(entryPoint));
        console.log("SenderCreator deployed at:", address(entryPoint.senderCreator()));

        _saveAddresses();
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
