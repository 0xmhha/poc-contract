// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "./utils/DeploymentAddresses.sol";
import {WKRW} from "../src/tokens/WKRW.sol";
import {StableToken} from "../src/tokens/StableToken.sol";

/**
 * @title DeployTokensScript
 * @notice Deployment script for token contracts
 * @dev Deploys wrapped native token and stablecoin infrastructure
 *
 * Deployed Contracts:
 *   - WKRW: Wrapped native token (like WETH)
 *   - StableToken: USD-pegged stablecoin (USDC)
 *
 * Note: These tokens are dependencies for other contracts (DEXIntegration, Paymasters, etc.)
 *
 * Usage:
 *   forge script script/DeployTokens.s.sol:DeployTokensScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployTokensScript is DeploymentHelper {
    WKRW public wkrw;
    StableToken public stableToken;

    function setUp() public {}

    function run() public {
        _initDeployment();

        // Get deployer address for token ownership
        address deployer = vm.envOr("ADMIN_ADDRESS", msg.sender);

        console.log("=== Deploying Token Infrastructure ===");
        console.log("Deployer/Owner:", deployer);

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

        // Deploy StableToken (USDC) or use existing
        address existingStableToken = _getAddress(DeploymentAddresses.KEY_STABLE_TOKEN);
        if (existingStableToken == address(0)) {
            stableToken = new StableToken(deployer);
            _setAddress(DeploymentAddresses.KEY_STABLE_TOKEN, address(stableToken));
            console.log("StableToken (USDC) deployed at:", address(stableToken));
        } else {
            stableToken = StableToken(existingStableToken);
            console.log("StableToken: Using existing at", existingStableToken);
        }

        vm.stopBroadcast();

        // Save addresses
        _saveAddresses();

        // Log summary
        console.log("\n=== Tokens Deployment Summary ===");
        console.log("WKRW (Wrapped Native Token):", address(wkrw));
        console.log("StableToken (USDC):", address(stableToken));
        console.log("\nNext steps:");
        console.log("  - Mint USDC: cast send <STABLE_TOKEN> 'mint(address,uint256)' <TO> <AMOUNT> --rpc-url <RPC>");
    }
}
