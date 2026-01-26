// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";
import {IEntryPoint} from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import {ERC20Paymaster} from "../../src/erc4337-paymaster/ERC20Paymaster.sol";
import {VerifyingPaymaster} from "../../src/erc4337-paymaster/VerifyingPaymaster.sol";
import {SponsorPaymaster} from "../../src/erc4337-paymaster/SponsorPaymaster.sol";
import {Permit2Paymaster} from "../../src/erc4337-paymaster/Permit2Paymaster.sol";
import {IPriceOracle} from "../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";
import {IPermit2} from "../../src/permit2/interfaces/IPermit2.sol";

/**
 * @title DeployPaymastersScript
 * @notice Deployment script for ERC-4337 Paymaster contracts
 * @dev Deploys all paymaster modules for gas sponsorship
 *
 * Dependencies (auto-loaded from deployment file or env vars):
 *   - EntryPoint: Required for all paymasters
 *   - PriceOracle: Required for ERC20Paymaster and Permit2Paymaster
 *
 * Environment Variables:
 *   - ENTRYPOINT_ADDRESS: Override EntryPoint address (optional if already deployed)
 *   - OWNER_ADDRESS: Owner/admin address for paymasters
 *   - VERIFYING_SIGNER: Signer address for VerifyingPaymaster
 *   - PRICE_ORACLE: Override PriceOracle address (optional if already deployed)
 *   - PERMIT2_ADDRESS: Permit2 address for Permit2Paymaster
 *
 * Usage:
 *   forge script script/deploy-contract/DeployPaymasters.s.sol:DeployPaymastersScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployPaymastersScript is DeploymentHelper {
    VerifyingPaymaster public verifyingPaymaster;
    SponsorPaymaster public sponsorPaymaster;
    ERC20Paymaster public erc20Paymaster;
    Permit2Paymaster public permit2Paymaster;

    // Default markup: 10% (10000 = 100%, so 1000 = 10%)
    uint256 constant DEFAULT_MARKUP = 1000;

    function setUp() public {}

    function run() public {
        _initDeployment();

        // Load dependencies (from deployment file or env vars)
        address entryPointAddress = _getAddressOrEnv(DeploymentAddresses.KEY_ENTRYPOINT, "ENTRYPOINT_ADDRESS");
        require(entryPointAddress != address(0), "EntryPoint required: deploy it first or set ENTRYPOINT_ADDRESS");

        address owner = vm.envOr("OWNER_ADDRESS", msg.sender);
        address verifyingSigner = vm.envOr("VERIFYING_SIGNER", msg.sender);

        // Optional dependencies
        address priceOracle = _getAddressOrEnv(DeploymentAddresses.KEY_PRICE_ORACLE, "PRICE_ORACLE");
        address permit2Address = vm.envOr("PERMIT2_ADDRESS", address(0));
        uint256 markup = vm.envOr("MARKUP", DEFAULT_MARKUP);

        console.log("=== Deploying Paymasters ===");
        console.log("Using EntryPoint:", entryPointAddress);

        vm.startBroadcast();

        // 1. Deploy VerifyingPaymaster (always deployable)
        verifyingPaymaster = new VerifyingPaymaster(
            IEntryPoint(entryPointAddress),
            owner,
            verifyingSigner
        );
        _setAddress(DeploymentAddresses.KEY_VERIFYING_PAYMASTER, address(verifyingPaymaster));
        console.log("VerifyingPaymaster deployed at:", address(verifyingPaymaster));

        // 2. Deploy SponsorPaymaster (always deployable)
        sponsorPaymaster = new SponsorPaymaster(
            IEntryPoint(entryPointAddress),
            owner,
            verifyingSigner
        );
        _setAddress(DeploymentAddresses.KEY_SPONSOR_PAYMASTER, address(sponsorPaymaster));
        console.log("SponsorPaymaster deployed at:", address(sponsorPaymaster));

        // 3. Deploy ERC20Paymaster (requires price oracle)
        if (priceOracle != address(0)) {
            erc20Paymaster = new ERC20Paymaster(
                IEntryPoint(entryPointAddress),
                owner,
                IPriceOracle(priceOracle),
                markup
            );
            _setAddress(DeploymentAddresses.KEY_ERC20_PAYMASTER, address(erc20Paymaster));
            console.log("ERC20Paymaster deployed at:", address(erc20Paymaster));
        } else {
            console.log("ERC20Paymaster: Skipped (PriceOracle not available)");
        }

        // 4. Deploy Permit2Paymaster (requires permit2 and price oracle)
        if (permit2Address != address(0) && priceOracle != address(0)) {
            permit2Paymaster = new Permit2Paymaster(
                IEntryPoint(entryPointAddress),
                owner,
                IPermit2(permit2Address),
                IPriceOracle(priceOracle),
                markup
            );
            _setAddress(DeploymentAddresses.KEY_PERMIT2_PAYMASTER, address(permit2Paymaster));
            console.log("Permit2Paymaster deployed at:", address(permit2Paymaster));
        } else {
            console.log("Permit2Paymaster: Skipped (PERMIT2_ADDRESS or PriceOracle not available)");
        }

        vm.stopBroadcast();

        // Save addresses
        _saveAddresses();

        // Log summary
        console.log("\n=== Paymasters Deployment Summary ===");
        console.log("Using EntryPoint:", entryPointAddress);
        console.log("Owner:", owner);
        console.log("VerifyingPaymaster:", address(verifyingPaymaster));
        console.log("SponsorPaymaster:", address(sponsorPaymaster));
        if (address(erc20Paymaster) != address(0)) {
            console.log("ERC20Paymaster:", address(erc20Paymaster));
        }
        if (address(permit2Paymaster) != address(0)) {
            console.log("Permit2Paymaster:", address(permit2Paymaster));
        }
    }
}

/**
 * @title DeployVerifyingPaymasterScript
 * @notice Deployment script for only VerifyingPaymaster
 *
 * Usage:
 *   ENTRYPOINT_ADDRESS=0x... VERIFYING_SIGNER=0x... forge script script/deploy-contract/DeployPaymasters.s.sol:DeployVerifyingPaymasterScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployVerifyingPaymasterScript is Script {
    function run() public {
        address entryPointAddress = vm.envAddress("ENTRYPOINT_ADDRESS");
        address owner = vm.envOr("OWNER_ADDRESS", msg.sender);
        address verifyingSigner = vm.envOr("VERIFYING_SIGNER", msg.sender);

        vm.startBroadcast();

        VerifyingPaymaster paymaster = new VerifyingPaymaster(
            IEntryPoint(entryPointAddress),
            owner,
            verifyingSigner
        );

        vm.stopBroadcast();

        console.log("VerifyingPaymaster deployed at:", address(paymaster));
    }
}
