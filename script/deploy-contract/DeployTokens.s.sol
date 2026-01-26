// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import { Script, console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "../utils/DeploymentAddresses.sol";
import { wKRC } from "../../src/tokens/wKRC.sol";
import { USDC } from "../../src/tokens/USDC.sol";

/**
 * @title DeployTokensScript
 * @notice Deployment script for token contracts
 * @dev Deploys wrapped native token and stablecoin infrastructure
 *
 * Deployed Contracts:
 *   - wKRC: Wrapped native token (like WETH)
 *   - USDC: USD-pegged stablecoin (initial mint: 1,000,000 USDC to owner)
 *
 * Note: These tokens are dependencies for other contracts (DEXIntegration, Paymasters, etc.)
 *
 * Environment Variables:
 *   - ADMIN_ADDRESS: Owner address for USDC (default: deployer)
 *
 * Usage:
 *   forge script script/deploy-contract/DeployTokens.s.sol:DeployTokensScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployTokensScript is DeploymentHelper {
    wKRC public wkrc;
    USDC public usdc;

    function setUp() public { }

    function run() public {
        _initDeployment();

        // Get deployer address for token ownership
        address deployer = vm.envOr("ADMIN_ADDRESS", msg.sender);

        console.log("=== Deploying Token Infrastructure ===");
        console.log("Deployer/Owner:", deployer);

        vm.startBroadcast();

        // Deploy Wrapped Native Token (wKRC) or use existing
        address existingWkrc = _getAddress(DeploymentAddresses.KEY_WKRC);
        if (existingWkrc == address(0)) {
            wkrc = new wKRC();
            _setAddress(DeploymentAddresses.KEY_WKRC, address(wkrc));
            console.log("wKRC deployed at:", address(wkrc));
        } else {
            wkrc = wKRC(payable(existingWkrc));
            console.log("wKRC: Using existing at", existingWkrc);
        }

        // Deploy USDC or use existing
        address existingUsdc = _getAddress(DeploymentAddresses.KEY_USDC);
        if (existingUsdc == address(0)) {
            usdc = new USDC(deployer);
            _setAddress(DeploymentAddresses.KEY_USDC, address(usdc));
            console.log("USDC deployed at:", address(usdc));

            // Initial mint: 1,000,000 USDC (6 decimals)
            uint256 initialMint = 1_000_000 * 10 ** 6;
            usdc.mint(deployer, initialMint);
            console.log("USDC initial mint:", initialMint, "to", deployer);
        } else {
            usdc = USDC(existingUsdc);
            console.log("USDC: Using existing at", existingUsdc);
        }

        vm.stopBroadcast();

        // Save addresses
        _saveAddresses();

        // Log summary
        console.log("\n=== Tokens Deployment Summary ===");
        console.log("wKRC (Wrapped Native Token):", address(wkrc));
        console.log("USDC:", address(usdc));
        console.log("USDC Owner:", deployer);
        console.log("\nNext steps:");
        console.log(
            "  - (Optional) Mint more USDC: cast send <USDC> 'mint(address,uint256)' <TO> <AMOUNT> --rpc-url <RPC>"
        );
    }
}
