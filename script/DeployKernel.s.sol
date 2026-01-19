// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IEntryPoint } from "../src/erc7579-smartaccount/interfaces/IEntryPoint.sol";
import { Kernel } from "../src/erc7579-smartaccount/Kernel.sol";
import { KernelFactory } from "../src/erc7579-smartaccount/factory/KernelFactory.sol";
import { ECDSAValidator } from "../src/erc7579-validators/ECDSAValidator.sol";

/**
 * @title DeployKernelScript
 * @notice Deployment script for Kernel smart account system
 * @dev Deploys Kernel implementation, KernelFactory, and ECDSAValidator
 *
 * Usage:
 *   forge script script/DeployKernel.s.sol:DeployKernelScript --rpc-url <RPC_URL> --broadcast
 *
 * With existing EntryPoint:
 *   ENTRYPOINT_ADDRESS=0x... forge script script/DeployKernel.s.sol:DeployKernelScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployKernelScript is Script {
    Kernel public kernelImpl;
    KernelFactory public kernelFactory;
    ECDSAValidator public ecdsaValidator;

    function setUp() public {}

    function run() public {
        // Get EntryPoint address from environment or use default
        address entryPointAddress = vm.envOr("ENTRYPOINT_ADDRESS", address(0));

        if (entryPointAddress == address(0)) {
            revert("ENTRYPOINT_ADDRESS environment variable is required");
        }

        vm.startBroadcast();

        // Deploy Kernel implementation
        kernelImpl = new Kernel(IEntryPoint(entryPointAddress));
        console.log("Kernel implementation deployed at:", address(kernelImpl));

        // Deploy KernelFactory
        kernelFactory = new KernelFactory(address(kernelImpl));
        console.log("KernelFactory deployed at:", address(kernelFactory));

        // Deploy ECDSAValidator
        ecdsaValidator = new ECDSAValidator();
        console.log("ECDSAValidator deployed at:", address(ecdsaValidator));

        vm.stopBroadcast();

        // Log summary
        console.log("\n=== Deployment Summary ===");
        console.log("EntryPoint:", entryPointAddress);
        console.log("Kernel Implementation:", address(kernelImpl));
        console.log("KernelFactory:", address(kernelFactory));
        console.log("ECDSAValidator:", address(ecdsaValidator));
    }
}

/**
 * @title DeployKernelWithEntryPointScript
 * @notice Deployment script that deploys EntryPoint first, then Kernel system
 * @dev Use this when deploying to a fresh network without existing EntryPoint
 *
 * Usage:
 *   forge script script/DeployKernel.s.sol:DeployKernelWithEntryPointScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployKernelWithEntryPointScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // Import and deploy EntryPoint
        // Note: This requires importing EntryPoint from erc4337-entrypoint
        // For production, use the canonical EntryPoint address
        console.log("Use DeployEntryPoint.s.sol first, then run DeployKernel.s.sol with ENTRYPOINT_ADDRESS env var");

        vm.stopBroadcast();
    }
}
