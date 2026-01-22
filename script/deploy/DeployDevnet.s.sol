// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";

// Core
import {EntryPoint} from "../../src/erc4337-entrypoint/EntryPoint.sol";
import {IEntryPoint as IEntryPointKernel} from "../../src/erc7579-smartaccount/interfaces/IEntryPoint.sol";
import {IEntryPoint as IEntryPointPaymaster} from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import {Kernel} from "../../src/erc7579-smartaccount/Kernel.sol";
import {KernelFactory} from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";

// Validators
import {ECDSAValidator} from "../../src/erc7579-validators/ECDSAValidator.sol";

// Paymasters
import {VerifyingPaymaster} from "../../src/erc4337-paymaster/VerifyingPaymaster.sol";

// Privacy
import {ERC5564Announcer} from "../../src/privacy/ERC5564Announcer.sol";
import {ERC6538Registry} from "../../src/privacy/ERC6538Registry.sol";

/**
 * @title DeployDevnetScript
 * @notice One-click deployment script for local development (Anvil)
 * @dev Deploys essential contracts only:
 *   - EntryPoint (ERC-4337)
 *   - Kernel + KernelFactory (ERC-7579 Smart Account)
 *   - ECDSAValidator (default validator)
 *   - VerifyingPaymaster (gas sponsorship)
 *   - ERC5564Announcer + ERC6538Registry (stealth addresses)
 *
 * Usage:
 *   forge script script/deploy/DeployDevnet.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * For full deployment with all contracts, use DeployOrchestrator.s.sol
 */
contract DeployDevnetScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        address deployer = msg.sender;
        address verifyingSigner = vm.envOr("VERIFYING_SIGNER", deployer);

        console.log("=== Devnet Deployment (Essential Contracts) ===");
        console.log("Chain ID:", chainId);
        console.log("Deployer:", deployer);
        console.log("Verifying Signer:", verifyingSigner);
        console.log("");

        vm.startBroadcast();

        // 1. EntryPoint (ERC-4337)
        EntryPoint entryPoint = new EntryPoint();
        _setAddress(DeploymentAddresses.KEY_ENTRYPOINT, address(entryPoint));
        console.log("EntryPoint:", address(entryPoint));

        // 2. Kernel (ERC-7579 Smart Account implementation)
        Kernel kernel = new Kernel(IEntryPointKernel(address(entryPoint)));
        _setAddress(DeploymentAddresses.KEY_KERNEL, address(kernel));
        console.log("Kernel:", address(kernel));

        // 3. KernelFactory (account deployment factory)
        KernelFactory kernelFactory = new KernelFactory(address(kernel));
        _setAddress(DeploymentAddresses.KEY_KERNEL_FACTORY, address(kernelFactory));
        console.log("KernelFactory:", address(kernelFactory));

        // 4. ECDSAValidator (default validator)
        ECDSAValidator ecdsaValidator = new ECDSAValidator();
        _setAddress(DeploymentAddresses.KEY_ECDSA_VALIDATOR, address(ecdsaValidator));
        console.log("ECDSAValidator:", address(ecdsaValidator));

        // 5. VerifyingPaymaster (gas sponsorship)
        VerifyingPaymaster paymaster = new VerifyingPaymaster(
            IEntryPointPaymaster(address(entryPoint)),
            deployer,
            verifyingSigner
        );
        _setAddress(DeploymentAddresses.KEY_VERIFYING_PAYMASTER, address(paymaster));
        console.log("VerifyingPaymaster:", address(paymaster));

        // 6. Stealth Address contracts
        ERC5564Announcer announcer = new ERC5564Announcer();
        _setAddress(DeploymentAddresses.KEY_ANNOUNCER, address(announcer));
        console.log("ERC5564Announcer:", address(announcer));

        ERC6538Registry registry = new ERC6538Registry();
        _setAddress(DeploymentAddresses.KEY_REGISTRY, address(registry));
        console.log("ERC6538Registry:", address(registry));

        vm.stopBroadcast();

        // Save addresses
        _saveAddresses();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Addresses saved to:", _getDeploymentPath());
        console.log("");
        console.log("Next steps:");
        console.log("  1. Fund paymaster: cast send", address(paymaster), "--value 10ether --rpc-url http://127.0.0.1:8545");
        console.log("  2. Generate TypeScript: pnpm --filter @stablenet/contracts generate");
        console.log("  3. Start services: make docker-dev");
    }
}

/**
 * @title FundPaymasterScript
 * @notice Helper script to fund the paymaster with ETH
 */
contract FundPaymasterScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        address paymasterAddr = _getAddress(DeploymentAddresses.KEY_VERIFYING_PAYMASTER);
        require(paymasterAddr != address(0), "Paymaster not deployed. Run DeployDevnetScript first.");

        uint256 amount = vm.envOr("FUND_AMOUNT", uint256(10 ether));
        address entryPoint = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);

        console.log("Funding paymaster deposit...");
        console.log("Paymaster:", paymasterAddr);
        console.log("EntryPoint:", entryPoint);
        console.log("Amount:", amount / 1 ether, "ETH");

        vm.startBroadcast();

        // Deposit to EntryPoint for the paymaster
        (bool success,) = entryPoint.call{value: amount}(
            abi.encodeWithSignature("depositTo(address)", paymasterAddr)
        );
        require(success, "Deposit failed");

        vm.stopBroadcast();

        console.log("Paymaster funded successfully.");
    }
}
