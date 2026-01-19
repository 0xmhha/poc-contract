// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "./utils/DeploymentAddresses.sol";
import {WKRW} from "../src/tokens/WKRW.sol";

/**
 * @title DeployTokensScript
 * @notice Deployment script for token contracts
 * @dev Deploys wrapped native token and other token infrastructure
 *
 * Note: WKRW is a dependency for other contracts (DEXIntegration, etc.)
 * This script saves the WKRW address for use by dependent scripts.
 *
 * Usage:
 *   forge script script/DeployTokens.s.sol:DeployTokensScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployTokensScript is DeploymentHelper {
    WKRW public wkrw;

    function setUp() public {}

    function run() public {
        _initDeployment();

        console.log("=== Deploying Token Infrastructure ===");

        vm.startBroadcast();

        // Deploy Wrapped Native Token (WKRW) or use existing
        address existingWkrw = _getAddress(DeploymentAddresses.KEY_WKRW);
        if (existingWkrw == address(0)) {
            wkrw = new WKRW();
            _setAddress(DeploymentAddresses.KEY_WKRW, address(wkrw));
            console.log("WKRW deployed at:", address(wkrw));
        } else {
            wkrw = WKRW(payable(existingWkrw));
            console.log("WKRW: Using existing at", existingWkrw);
        }

        vm.stopBroadcast();

        // Save addresses
        _saveAddresses();

        // Log summary
        console.log("\n=== Tokens Deployment Summary ===");
        console.log("WKRW (Wrapped Native Token):", address(wkrw));
    }
}
