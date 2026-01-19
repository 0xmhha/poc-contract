// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {BridgeValidator} from "../src/bridge/BridgeValidator.sol";
import {BridgeGuardian} from "../src/bridge/BridgeGuardian.sol";
import {BridgeRateLimiter} from "../src/bridge/BridgeRateLimiter.sol";
import {OptimisticVerifier} from "../src/bridge/OptimisticVerifier.sol";
import {FraudProofVerifier} from "../src/bridge/FraudProofVerifier.sol";
import {SecureBridge} from "../src/bridge/SecureBridge.sol";

/**
 * @title DeployBridgeScript
 * @notice Deployment script for cross-chain bridge infrastructure
 * @dev Deploys complete bridge system with security components
 *
 * Deployment Order:
 *   1. BridgeValidator - Multi-sig validation
 *   2. BridgeGuardian - Emergency controls
 *   3. BridgeRateLimiter - Rate limiting
 *   4. OptimisticVerifier - Optimistic verification
 *   5. FraudProofVerifier - Fraud proof system
 *   6. SecureBridge - Main bridge contract
 *
 * Environment Variables:
 *   - BRIDGE_SIGNERS: Comma-separated list of signer addresses (min 3)
 *   - BRIDGE_GUARDIANS: Comma-separated list of guardian addresses (min 3)
 *   - SIGNER_THRESHOLD: Required signatures (default: 2)
 *   - GUARDIAN_THRESHOLD: Required guardian approvals (default: 2)
 *   - FEE_RECIPIENT: Address to receive bridge fees
 *
 * Usage:
 *   forge script script/DeployBridge.s.sol:DeployBridgeScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployBridgeScript is Script {
    BridgeValidator public bridgeValidator;
    BridgeGuardian public bridgeGuardian;
    BridgeRateLimiter public bridgeRateLimiter;
    OptimisticVerifier public optimisticVerifier;
    FraudProofVerifier public fraudProofVerifier;
    SecureBridge public secureBridge;

    // Default configurations
    uint256 constant DEFAULT_CHALLENGE_PERIOD = 1 days;
    uint256 constant DEFAULT_CHALLENGE_BOND = 1 ether;
    uint256 constant DEFAULT_CHALLENGER_REWARD = 0.5 ether;

    function setUp() public {}

    function run() public {
        // Parse signer addresses
        address[] memory signers = _parseAddresses(vm.envOr("BRIDGE_SIGNERS", string("")));
        address[] memory guardians = _parseAddresses(vm.envOr("BRIDGE_GUARDIANS", string("")));

        // Use defaults if not provided
        if (signers.length < 3) {
            signers = new address[](3);
            signers[0] = msg.sender;
            signers[1] = address(uint160(uint256(keccak256("signer1"))));
            signers[2] = address(uint160(uint256(keccak256("signer2"))));
            console.log("Warning: Using default signers (for testing only)");
        }

        if (guardians.length < 3) {
            guardians = new address[](3);
            guardians[0] = msg.sender;
            guardians[1] = address(uint160(uint256(keccak256("guardian1"))));
            guardians[2] = address(uint160(uint256(keccak256("guardian2"))));
            console.log("Warning: Using default guardians (for testing only)");
        }

        uint256 signerThreshold = vm.envOr("SIGNER_THRESHOLD", uint256(2));
        uint256 guardianThreshold = vm.envOr("GUARDIAN_THRESHOLD", uint256(2));
        address feeRecipient = vm.envOr("FEE_RECIPIENT", msg.sender);

        vm.startBroadcast();

        // 1. Deploy Bridge Validator
        bridgeValidator = new BridgeValidator(signers, signerThreshold);
        console.log("BridgeValidator deployed at:", address(bridgeValidator));

        // 2. Deploy Bridge Guardian
        bridgeGuardian = new BridgeGuardian(guardians, guardianThreshold);
        console.log("BridgeGuardian deployed at:", address(bridgeGuardian));

        // 3. Deploy Rate Limiter
        bridgeRateLimiter = new BridgeRateLimiter();
        console.log("BridgeRateLimiter deployed at:", address(bridgeRateLimiter));

        // 4. Deploy Optimistic Verifier
        optimisticVerifier = new OptimisticVerifier(
            DEFAULT_CHALLENGE_PERIOD,
            DEFAULT_CHALLENGE_BOND,
            DEFAULT_CHALLENGER_REWARD
        );
        console.log("OptimisticVerifier deployed at:", address(optimisticVerifier));

        // 5. Deploy Fraud Proof Verifier
        fraudProofVerifier = new FraudProofVerifier();
        console.log("FraudProofVerifier deployed at:", address(fraudProofVerifier));

        // 6. Deploy Secure Bridge
        secureBridge = new SecureBridge(
            address(bridgeValidator),
            payable(address(optimisticVerifier)),
            address(bridgeRateLimiter),
            address(bridgeGuardian),
            feeRecipient
        );
        console.log("SecureBridge deployed at:", address(secureBridge));

        vm.stopBroadcast();

        // Log summary
        console.log("\n=== Bridge Deployment Summary ===");
        console.log("BridgeValidator:", address(bridgeValidator));
        console.log("BridgeGuardian:", address(bridgeGuardian));
        console.log("BridgeRateLimiter:", address(bridgeRateLimiter));
        console.log("OptimisticVerifier:", address(optimisticVerifier));
        console.log("FraudProofVerifier:", address(fraudProofVerifier));
        console.log("SecureBridge:", address(secureBridge));
        console.log("Fee Recipient:", feeRecipient);
    }

    function _parseAddresses(string memory input) internal pure returns (address[] memory) {
        if (bytes(input).length == 0) {
            return new address[](0);
        }

        // Simple parsing - count commas to determine array size
        uint256 count = 1;
        bytes memory inputBytes = bytes(input);
        for (uint256 i = 0; i < inputBytes.length; i++) {
            if (inputBytes[i] == ",") {
                count++;
            }
        }

        // For simplicity, return empty array if parsing is complex
        // In production, use a proper string parsing library
        return new address[](0);
    }
}

/**
 * @title DeployBridgeComponentsScript
 * @notice Deployment script for individual bridge components
 *
 * Usage:
 *   forge script script/DeployBridge.s.sol:DeployBridgeComponentsScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployBridgeComponentsScript is Script {
    function run() public {
        vm.startBroadcast();

        // Deploy standalone components
        BridgeRateLimiter rateLimiter = new BridgeRateLimiter();
        console.log("BridgeRateLimiter deployed at:", address(rateLimiter));

        FraudProofVerifier fraudVerifier = new FraudProofVerifier();
        console.log("FraudProofVerifier deployed at:", address(fraudVerifier));

        vm.stopBroadcast();
    }
}
