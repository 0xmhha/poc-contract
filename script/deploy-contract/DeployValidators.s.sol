// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";
import {ECDSAValidator} from "../../src/erc7579-validators/ECDSAValidator.sol";
import {WeightedECDSAValidator} from "../../src/erc7579-validators/WeightedECDSAValidator.sol";
import {MultiChainValidator} from "../../src/erc7579-validators/MultiChainValidator.sol";
import {MultiSigValidator} from "../../src/erc7579-validators/MultiSigValidator.sol";
import {WebAuthnValidator} from "../../src/erc7579-validators/WebAuthnValidator.sol";

/**
 * @title DeployValidatorsScript
 * @notice Deployment script for ERC-7579 Validator modules
 * @dev Deploys validator modules for smart account validation
 *
 * Deployed Contracts:
 *   - ECDSAValidator: Basic ECDSA signature validation (most common)
 *   - WeightedECDSAValidator: Multi-sig with weighted signers
 *   - MultiChainValidator: Cross-chain validation support
 *   - MultiSigValidator: Standard multi-signature validation
 *   - WebAuthnValidator: Passkey/WebAuthn validation
 *
 * Usage:
 *   forge script script/deploy-contract/DeployValidators.s.sol:DeployValidatorsScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployValidatorsScript is DeploymentHelper {
    ECDSAValidator public ecdsaValidator;
    WeightedECDSAValidator public weightedValidator;
    MultiChainValidator public multiChainValidator;
    MultiSigValidator public multiSigValidator;
    WebAuthnValidator public webAuthnValidator;

    function setUp() public {}

    function run() public {
        _initDeployment();

        vm.startBroadcast();

        // Deploy ECDSA Validator (basic, most common)
        address existing = _getAddress(DeploymentAddresses.KEY_ECDSA_VALIDATOR);
        if (existing == address(0)) {
            ecdsaValidator = new ECDSAValidator();
            _setAddress(DeploymentAddresses.KEY_ECDSA_VALIDATOR, address(ecdsaValidator));
            console.log("ECDSAValidator deployed at:", address(ecdsaValidator));
        } else {
            ecdsaValidator = ECDSAValidator(existing);
            console.log("ECDSAValidator: Using existing at", existing);
        }

        // Deploy Weighted ECDSA Validator (multi-sig)
        existing = _getAddress(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR);
        if (existing == address(0)) {
            weightedValidator = new WeightedECDSAValidator();
            _setAddress(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR, address(weightedValidator));
            console.log("WeightedECDSAValidator deployed at:", address(weightedValidator));
        } else {
            weightedValidator = WeightedECDSAValidator(existing);
            console.log("WeightedECDSAValidator: Using existing at", existing);
        }

        // Deploy Multi-Chain Validator
        existing = _getAddress(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR);
        if (existing == address(0)) {
            multiChainValidator = new MultiChainValidator();
            _setAddress(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR, address(multiChainValidator));
            console.log("MultiChainValidator deployed at:", address(multiChainValidator));
        } else {
            multiChainValidator = MultiChainValidator(existing);
            console.log("MultiChainValidator: Using existing at", existing);
        }

        // Deploy Multi-Sig Validator
        existing = _getAddress(DeploymentAddresses.KEY_MULTISIG_VALIDATOR);
        if (existing == address(0)) {
            multiSigValidator = new MultiSigValidator();
            _setAddress(DeploymentAddresses.KEY_MULTISIG_VALIDATOR, address(multiSigValidator));
            console.log("MultiSigValidator deployed at:", address(multiSigValidator));
        } else {
            multiSigValidator = MultiSigValidator(existing);
            console.log("MultiSigValidator: Using existing at", existing);
        }

        // Deploy WebAuthn Validator
        existing = _getAddress(DeploymentAddresses.KEY_WEBAUTHN_VALIDATOR);
        if (existing == address(0)) {
            webAuthnValidator = new WebAuthnValidator();
            _setAddress(DeploymentAddresses.KEY_WEBAUTHN_VALIDATOR, address(webAuthnValidator));
            console.log("WebAuthnValidator deployed at:", address(webAuthnValidator));
        } else {
            webAuthnValidator = WebAuthnValidator(existing);
            console.log("WebAuthnValidator: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        console.log("\n=== Validators Deployment Summary ===");
        console.log("ECDSAValidator:", address(ecdsaValidator));
        console.log("WeightedECDSAValidator:", address(weightedValidator));
        console.log("MultiChainValidator:", address(multiChainValidator));
        console.log("MultiSigValidator:", address(multiSigValidator));
        console.log("WebAuthnValidator:", address(webAuthnValidator));
    }
}
