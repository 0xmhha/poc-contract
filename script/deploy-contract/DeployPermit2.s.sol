// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import { Script, console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "../utils/DeploymentAddresses.sol";
import { Permit2 } from "../../src/permit2/Permit2.sol";

/**
 * @title DeployPermit2Script
 * @notice Deployment script for Permit2 contract
 * @dev Deploys Uniswap's Permit2 for signature-based token transfers
 *
 * Features:
 *   - SignatureTransfer: One-time permit signatures for token transfers
 *   - AllowanceTransfer: Persistent allowances with expiration
 *   - EIP-712: Cross-chain replay protection
 *
 * Dependencies: None (Layer 0 contract)
 *
 * Usage:
 *   FOUNDRY_PROFILE=permit2 forge script script/deploy-contract/DeployPermit2.s.sol:DeployPermit2Script \
 *     --rpc-url <RPC_URL> --broadcast
 */
contract DeployPermit2Script is DeploymentHelper {
    Permit2 public permit2;

    function setUp() public { }

    function run() public {
        _initDeployment();

        vm.startBroadcast();

        // Deploy Permit2
        address existing = _getAddress(DeploymentAddresses.KEY_PERMIT2);
        if (existing == address(0)) {
            permit2 = new Permit2();
            _setAddress(DeploymentAddresses.KEY_PERMIT2, address(permit2));
            console.log("Permit2 deployed at:", address(permit2));
        } else {
            permit2 = Permit2(existing);
            console.log("Permit2: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        console.log("\n=== Permit2 Deployment Summary ===");
        console.log("Permit2:", address(permit2));
        console.log("DOMAIN_SEPARATOR:", vm.toString(permit2.DOMAIN_SEPARATOR()));
        console.log("\nPermit2 is ready for use with:");
        console.log("  - SignatureTransfer: One-time permit signatures");
        console.log("  - AllowanceTransfer: Persistent allowances with expiration");
    }
}
