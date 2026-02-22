// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import { Script, console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "../utils/DeploymentAddresses.sol";
import { IEntryPoint } from "../../src/erc7579-smartaccount/interfaces/IEntryPoint.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { KernelFactory } from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";
import { FactoryStaker } from "../../src/erc7579-smartaccount/factory/FactoryStaker.sol";

/**
 * @title DeployKernelScript
 * @notice Deployment script for Kernel smart account system
 * @dev Deploys Kernel implementation, KernelFactory, and FactoryStaker
 *
 * Note: Validators (ECDSAValidator, etc.) are deployed separately via DeployValidators.s.sol
 *
 * Usage:
 *   forge script script/deploy-contract/DeployKernel.s.sol:DeployKernelScript --rpc-url <RPC_URL> --broadcast
 *
 * With existing EntryPoint:
 *   ENTRYPOINT_ADDRESS=0x... forge script script/deploy-contract/DeployKernel.s.sol:DeployKernelScript --rpc-url
 * <RPC_URL> --broadcast
 */
contract DeployKernelScript is DeploymentHelper {
    Kernel public kernelImpl;
    KernelFactory public kernelFactory;
    FactoryStaker public factoryStaker;

    function setUp() public { }

    function run() public {
        _initDeployment();

        // Get EntryPoint address from cache, env, or revert
        address entryPointAddress = _getAddressOrEnv(DeploymentAddresses.KEY_ENTRYPOINT, "ENTRYPOINT_ADDRESS");

        if (entryPointAddress == address(0)) {
            revert("ENTRYPOINT_ADDRESS not found in deployment cache or environment variable");
        }

        vm.startBroadcast();

        // Deploy Kernel implementation
        address existing = _getAddress(DeploymentAddresses.KEY_KERNEL);
        if (existing == address(0)) {
            kernelImpl = new Kernel(IEntryPoint(entryPointAddress));
            _setAddress(DeploymentAddresses.KEY_KERNEL, address(kernelImpl));
            console.log("Kernel implementation deployed at:", address(kernelImpl));
        } else {
            kernelImpl = Kernel(payable(existing));
            console.log("Kernel: Using existing at", existing);
        }

        // Deploy KernelFactory
        existing = _getAddress(DeploymentAddresses.KEY_KERNEL_FACTORY);
        if (existing == address(0)) {
            kernelFactory = new KernelFactory(address(kernelImpl));
            _setAddress(DeploymentAddresses.KEY_KERNEL_FACTORY, address(kernelFactory));
            console.log("KernelFactory deployed at:", address(kernelFactory));
        } else {
            kernelFactory = KernelFactory(existing);
            console.log("KernelFactory: Using existing at", existing);
        }

        // Deploy FactoryStaker (infra contract — owned by deployer/admin, not paymaster)
        address owner = vm.envOr("ADMIN_ADDRESS", msg.sender);
        existing = _getAddress(DeploymentAddresses.KEY_FACTORY_STAKER);
        if (existing == address(0)) {
            factoryStaker = new FactoryStaker(owner);
            _setAddress(DeploymentAddresses.KEY_FACTORY_STAKER, address(factoryStaker));
            console.log("FactoryStaker deployed at:", address(factoryStaker));
        } else {
            factoryStaker = FactoryStaker(existing);
            console.log("FactoryStaker: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        console.log("\n=== Kernel Deployment Summary ===");
        console.log("Using EntryPoint:", entryPointAddress);
        console.log("Kernel Implementation:", address(kernelImpl));
        console.log("KernelFactory:", address(kernelFactory));
        console.log("FactoryStaker:", address(factoryStaker));
        console.log("\nNext: Deploy validators with DeployValidators.s.sol");
    }
}

/**
 * @title DeployKernelWithEntryPointScript
 * @notice Deployment script that deploys EntryPoint first, then Kernel system
 * @dev Use this when deploying to a fresh network without existing EntryPoint
 *
 * Usage:
 *   forge script script/deploy-contract/DeployKernel.s.sol:DeployKernelWithEntryPointScript --rpc-url <RPC_URL>
 * --broadcast
 */
contract DeployKernelWithEntryPointScript is Script {
    function setUp() public { }

    function run() public {
        vm.startBroadcast();

        // Import and deploy EntryPoint
        // Note: This requires importing EntryPoint from erc4337-entrypoint
        // For production, use the canonical EntryPoint address
        console.log(
            "Use script/deploy-contract/DeployEntryPoint.s.sol first, then run DeployKernel.s.sol with ENTRYPOINT_ADDRESS env var"
        );

        vm.stopBroadcast();
    }
}
