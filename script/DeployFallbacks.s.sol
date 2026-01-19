// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TokenReceiverFallback} from "../src/erc7579-fallbacks/TokenReceiverFallback.sol";
import {FlashLoanFallback} from "../src/erc7579-fallbacks/FlashLoanFallback.sol";

/**
 * @title DeployFallbacksScript
 * @notice Deployment script for ERC-7579 Fallback modules
 * @dev Deploys all fallback modules for smart account callback handling
 *
 * Usage:
 *   forge script script/DeployFallbacks.s.sol:DeployFallbacksScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployFallbacksScript is Script {
    TokenReceiverFallback public tokenReceiverFallback;
    FlashLoanFallback public flashLoanFallback;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // Deploy Token Receiver Fallback (ERC-721, ERC-1155, ERC-777)
        tokenReceiverFallback = new TokenReceiverFallback();
        console.log("TokenReceiverFallback deployed at:", address(tokenReceiverFallback));

        // Deploy Flash Loan Fallback (AAVE, Uniswap, Balancer, ERC-3156)
        flashLoanFallback = new FlashLoanFallback();
        console.log("FlashLoanFallback deployed at:", address(flashLoanFallback));

        vm.stopBroadcast();

        // Log summary
        console.log("\n=== Fallbacks Deployment Summary ===");
        console.log("TokenReceiverFallback:", address(tokenReceiverFallback));
        console.log("FlashLoanFallback:", address(flashLoanFallback));
    }
}
