// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import { Script, console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "../utils/DeploymentAddresses.sol";
import { TokenReceiverFallback } from "../../src/erc7579-fallbacks/TokenReceiverFallback.sol";
import { FlashLoanFallback } from "../../src/erc7579-fallbacks/FlashLoanFallback.sol";

/**
 * @title DeployFallbacksScript
 * @notice Deployment script for ERC-7579 Fallback modules
 * @dev Deploys fallback modules for smart account callback handling
 *
 * Fallback Modules:
 *   - TokenReceiverFallback: Handles ERC-721/1155/777 token receive callbacks
 *   - FlashLoanFallback: Handles flash loan callbacks (AAVE, Uniswap, Balancer, ERC-3156)
 *
 * Deployment Order: 6 (after Hooks)
 *
 * Usage:
 *   forge script script/deploy-contract/DeployFallbacks.s.sol:DeployFallbacksScript \
 *     --rpc-url <RPC_URL> --broadcast
 *
 * With fallbacks profile:
 *   FOUNDRY_PROFILE=fallbacks forge script script/deploy-contract/DeployFallbacks.s.sol:DeployFallbacksScript \
 *     --rpc-url <RPC_URL> --broadcast
 */
contract DeployFallbacksScript is DeploymentHelper {
    TokenReceiverFallback public tokenReceiverFallback;
    FlashLoanFallback public flashLoanFallback;

    function setUp() public { }

    function run() public {
        _initDeployment();

        vm.startBroadcast();

        // Deploy TokenReceiverFallback
        address existing = _getAddress(DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK);
        if (existing == address(0)) {
            tokenReceiverFallback = new TokenReceiverFallback();
            _setAddress(DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK, address(tokenReceiverFallback));
            console.log("TokenReceiverFallback deployed at:", address(tokenReceiverFallback));
        } else {
            tokenReceiverFallback = TokenReceiverFallback(existing);
            console.log("TokenReceiverFallback: Using existing at", existing);
        }

        // Deploy FlashLoanFallback
        existing = _getAddress(DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK);
        if (existing == address(0)) {
            flashLoanFallback = new FlashLoanFallback();
            _setAddress(DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK, address(flashLoanFallback));
            console.log("FlashLoanFallback deployed at:", address(flashLoanFallback));
        } else {
            flashLoanFallback = FlashLoanFallback(existing);
            console.log("FlashLoanFallback: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        console.log("\n=== Fallbacks Deployment Summary ===");
        console.log("TokenReceiverFallback:", address(tokenReceiverFallback));
        console.log("FlashLoanFallback:", address(flashLoanFallback));
        console.log("\nNote: Fallbacks are installed on SmartAccounts via installModule()");
        console.log("  - TokenReceiverFallback: Use for NFT marketplace, airdrops, DeFi LP tokens");
        console.log("  - FlashLoanFallback: Use for arbitrage, liquidations, collateral swaps");
    }
}
