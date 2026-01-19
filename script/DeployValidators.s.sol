// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ECDSAValidator} from "../src/erc7579-validators/ECDSAValidator.sol";
import {WeightedECDSAValidator} from "../src/erc7579-validators/WeightedECDSAValidator.sol";
import {MultiChainValidator} from "../src/erc7579-validators/MultiChainValidator.sol";

/**
 * @title DeployValidatorsScript
 * @notice Deployment script for ERC-7579 Validator modules
 * @dev Deploys all validator modules for smart account validation
 *
 * Usage:
 *   forge script script/DeployValidators.s.sol:DeployValidatorsScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployValidatorsScript is Script {
    ECDSAValidator public ecdsaValidator;
    WeightedECDSAValidator public weightedValidator;
    MultiChainValidator public multiChainValidator;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // Deploy ECDSA Validator
        ecdsaValidator = new ECDSAValidator();
        console.log("ECDSAValidator deployed at:", address(ecdsaValidator));

        // Deploy Weighted ECDSA Validator (multi-sig)
        weightedValidator = new WeightedECDSAValidator();
        console.log("WeightedECDSAValidator deployed at:", address(weightedValidator));

        // Deploy Multi-Chain Validator
        multiChainValidator = new MultiChainValidator();
        console.log("MultiChainValidator deployed at:", address(multiChainValidator));

        vm.stopBroadcast();

        // Log summary
        console.log("\n=== Validators Deployment Summary ===");
        console.log("ECDSAValidator:", address(ecdsaValidator));
        console.log("WeightedECDSAValidator:", address(weightedValidator));
        console.log("MultiChainValidator:", address(multiChainValidator));
    }
}
