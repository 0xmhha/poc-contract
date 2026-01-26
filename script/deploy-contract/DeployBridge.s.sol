// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";
import {FraudProofVerifier} from "../../src/bridge/FraudProofVerifier.sol";
import {BridgeRateLimiter} from "../../src/bridge/BridgeRateLimiter.sol";
import {BridgeValidator} from "../../src/bridge/BridgeValidator.sol";
import {BridgeGuardian} from "../../src/bridge/BridgeGuardian.sol";
import {OptimisticVerifier} from "../../src/bridge/OptimisticVerifier.sol";
import {SecureBridge} from "../../src/bridge/SecureBridge.sol";

/**
 * @title DeployBridgeScript
 * @notice Deployment script for Bridge contracts (Defense-in-depth bridge system)
 * @dev Deploys all bridge components with proper dependency ordering
 *
 * Deployed Contracts:
 *   - FraudProofVerifier: Dispute resolution via fraud proofs
 *   - BridgeRateLimiter: Volume and rate controls
 *   - BridgeValidator: MPC signing (threshold signatures)
 *   - BridgeGuardian: Emergency response system
 *   - OptimisticVerifier: Challenge period verification
 *   - SecureBridge: Main bridge integrating all security layers
 *
 * Deployment Order:
 *   Layer 0: FraudProofVerifier, BridgeRateLimiter (no dependencies)
 *   Layer 1: BridgeValidator, BridgeGuardian, OptimisticVerifier (config params)
 *   Layer 2: SecureBridge (depends on all Layer 1 contracts)
 *
 * Environment Variables:
 *   - BRIDGE_SIGNERS: Comma-separated signer addresses for BridgeValidator
 *   - BRIDGE_SIGNER_THRESHOLD: Threshold for BridgeValidator (default: 3)
 *   - BRIDGE_GUARDIANS: Comma-separated guardian addresses for BridgeGuardian
 *   - BRIDGE_GUARDIAN_THRESHOLD: Threshold for BridgeGuardian (default: 2)
 *   - CHALLENGE_PERIOD: Challenge period in seconds (default: 6 hours)
 *   - CHALLENGE_BOND: Challenge bond in wei (default: 0.1 ether)
 *   - CHALLENGER_REWARD: Challenger reward in wei (default: 0.05 ether)
 *   - FEE_RECIPIENT: Fee recipient address (default: deployer)
 *
 * Usage:
 *   FOUNDRY_PROFILE=bridge forge script script/deploy-contract/DeployBridge.s.sol:DeployBridgeScript \
 *     --rpc-url <RPC_URL> --broadcast
 */
contract DeployBridgeScript is DeploymentHelper {
    // Contracts
    FraudProofVerifier public fraudProofVerifier;
    BridgeRateLimiter public rateLimiter;
    BridgeValidator public bridgeValidator;
    BridgeGuardian public bridgeGuardian;
    OptimisticVerifier public optimisticVerifier;
    SecureBridge public secureBridge;

    // Default values
    uint256 constant DEFAULT_SIGNER_THRESHOLD = 3;
    uint256 constant DEFAULT_GUARDIAN_THRESHOLD = 2;
    uint256 constant DEFAULT_CHALLENGE_PERIOD = 6 hours;
    uint256 constant DEFAULT_CHALLENGE_BOND = 0.1 ether;
    uint256 constant DEFAULT_CHALLENGER_REWARD = 0.05 ether;

    function setUp() public {}

    function run() public {
        _initDeployment();

        vm.startBroadcast();

        // ============ Layer 0: No Dependencies ============

        // Deploy FraudProofVerifier
        address existing = _getAddress(DeploymentAddresses.KEY_FRAUD_PROOF_VERIFIER);
        if (existing == address(0)) {
            fraudProofVerifier = new FraudProofVerifier();
            _setAddress(DeploymentAddresses.KEY_FRAUD_PROOF_VERIFIER, address(fraudProofVerifier));
            console.log("FraudProofVerifier deployed at:", address(fraudProofVerifier));
        } else {
            fraudProofVerifier = FraudProofVerifier(existing);
            console.log("FraudProofVerifier: Using existing at", existing);
        }

        // Deploy BridgeRateLimiter
        existing = _getAddress(DeploymentAddresses.KEY_BRIDGE_RATE_LIMITER);
        if (existing == address(0)) {
            rateLimiter = new BridgeRateLimiter();
            _setAddress(DeploymentAddresses.KEY_BRIDGE_RATE_LIMITER, address(rateLimiter));
            console.log("BridgeRateLimiter deployed at:", address(rateLimiter));
        } else {
            rateLimiter = BridgeRateLimiter(existing);
            console.log("BridgeRateLimiter: Using existing at", existing);
        }

        // ============ Layer 1: Configuration Required ============

        // Deploy BridgeValidator
        existing = _getAddress(DeploymentAddresses.KEY_BRIDGE_VALIDATOR);
        if (existing == address(0)) {
            address[] memory signers = _getSigners();
            uint256 threshold = vm.envOr("BRIDGE_SIGNER_THRESHOLD", DEFAULT_SIGNER_THRESHOLD);

            bridgeValidator = new BridgeValidator(signers, threshold);
            _setAddress(DeploymentAddresses.KEY_BRIDGE_VALIDATOR, address(bridgeValidator));
            console.log("BridgeValidator deployed at:", address(bridgeValidator));
            console.log("  Signers:", signers.length);
            console.log("  Threshold:", threshold);
        } else {
            bridgeValidator = BridgeValidator(existing);
            console.log("BridgeValidator: Using existing at", existing);
        }

        // Deploy BridgeGuardian
        existing = _getAddress(DeploymentAddresses.KEY_BRIDGE_GUARDIAN);
        if (existing == address(0)) {
            address[] memory guardians = _getGuardians();
            uint256 threshold = vm.envOr("BRIDGE_GUARDIAN_THRESHOLD", DEFAULT_GUARDIAN_THRESHOLD);

            bridgeGuardian = new BridgeGuardian(guardians, threshold);
            _setAddress(DeploymentAddresses.KEY_BRIDGE_GUARDIAN, address(bridgeGuardian));
            console.log("BridgeGuardian deployed at:", address(bridgeGuardian));
            console.log("  Guardians:", guardians.length);
            console.log("  Threshold:", threshold);
        } else {
            bridgeGuardian = BridgeGuardian(existing);
            console.log("BridgeGuardian: Using existing at", existing);
        }

        // Deploy OptimisticVerifier
        existing = _getAddress(DeploymentAddresses.KEY_OPTIMISTIC_VERIFIER);
        if (existing == address(0)) {
            uint256 challengePeriod = vm.envOr("CHALLENGE_PERIOD", DEFAULT_CHALLENGE_PERIOD);
            uint256 challengeBond = vm.envOr("CHALLENGE_BOND", DEFAULT_CHALLENGE_BOND);
            uint256 challengerReward = vm.envOr("CHALLENGER_REWARD", DEFAULT_CHALLENGER_REWARD);

            optimisticVerifier = new OptimisticVerifier(challengePeriod, challengeBond, challengerReward);
            _setAddress(DeploymentAddresses.KEY_OPTIMISTIC_VERIFIER, address(optimisticVerifier));
            console.log("OptimisticVerifier deployed at:", address(optimisticVerifier));
            console.log("  Challenge Period:", challengePeriod / 1 hours, "hours");
            console.log("  Challenge Bond:", challengeBond / 1 ether, "ETH");
            console.log("  Challenger Reward:", challengerReward / 1 ether, "ETH");
        } else {
            optimisticVerifier = OptimisticVerifier(payable(existing));
            console.log("OptimisticVerifier: Using existing at", existing);
        }

        // ============ Layer 2: Depends on All Layer 1 Contracts ============

        // Deploy SecureBridge
        existing = _getAddress(DeploymentAddresses.KEY_SECURE_BRIDGE);
        if (existing == address(0)) {
            address feeRecipient = vm.envOr("FEE_RECIPIENT", msg.sender);

            secureBridge = new SecureBridge(
                address(bridgeValidator),
                payable(address(optimisticVerifier)),
                address(rateLimiter),
                address(bridgeGuardian),
                feeRecipient
            );
            _setAddress(DeploymentAddresses.KEY_SECURE_BRIDGE, address(secureBridge));
            console.log("SecureBridge deployed at:", address(secureBridge));
            console.log("  Fee Recipient:", feeRecipient);
        } else {
            secureBridge = SecureBridge(payable(existing));
            console.log("SecureBridge: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        _printSummary();
    }

    /**
     * @notice Get signer addresses from env or generate test addresses
     */
    function _getSigners() internal returns (address[] memory) {
        string memory signersEnv = vm.envOr("BRIDGE_SIGNERS", string(""));

        if (bytes(signersEnv).length > 0) {
            // Parse comma-separated addresses from env
            // For simplicity, we'll use a fixed array for production
            // In a real scenario, you'd parse the string
            revert("BRIDGE_SIGNERS parsing not implemented - use test mode or set individual addresses");
        }

        // Test mode: generate deterministic addresses
        console.log("Warning: Using test signers (set BRIDGE_SIGNERS for production)");
        address[] memory signers = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            signers[i] = address(uint160(uint256(keccak256(abi.encodePacked("signer", i)))));
        }
        return signers;
    }

    /**
     * @notice Get guardian addresses from env or generate test addresses
     */
    function _getGuardians() internal returns (address[] memory) {
        string memory guardiansEnv = vm.envOr("BRIDGE_GUARDIANS", string(""));

        if (bytes(guardiansEnv).length > 0) {
            revert("BRIDGE_GUARDIANS parsing not implemented - use test mode or set individual addresses");
        }

        // Test mode: generate deterministic addresses
        console.log("Warning: Using test guardians (set BRIDGE_GUARDIANS for production)");
        address[] memory guardians = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            guardians[i] = address(uint160(uint256(keccak256(abi.encodePacked("guardian", i)))));
        }
        return guardians;
    }

    /**
     * @notice Print deployment summary
     */
    function _printSummary() internal view {
        console.log("\n=== Bridge Deployment Summary ===");
        console.log("\nLayer 0 (No Dependencies):");
        console.log("  FraudProofVerifier:", address(fraudProofVerifier));
        console.log("  BridgeRateLimiter:", address(rateLimiter));

        console.log("\nLayer 1 (Configuration):");
        console.log("  BridgeValidator:", address(bridgeValidator));
        console.log("    Signers:", bridgeValidator.getSignerCount());
        (, uint256 validatorThreshold,) = bridgeValidator.getCurrentSignerSet();
        console.log("    Threshold:", validatorThreshold);
        console.log("  BridgeGuardian:", address(bridgeGuardian));
        console.log("    Guardians:", bridgeGuardian.getGuardianCount());
        console.log("    Threshold:", bridgeGuardian.threshold());
        console.log("  OptimisticVerifier:", address(optimisticVerifier));
        console.log("    Challenge Period:", optimisticVerifier.challengePeriod() / 1 hours, "hours");

        console.log("\nLayer 2 (Main Bridge):");
        console.log("  SecureBridge:", address(secureBridge));
        console.log("    Chain ID:", secureBridge.CHAIN_ID());
        console.log("    Bridge Fee:", secureBridge.bridgeFeeBps(), "bps");

        console.log("\nSecurity Layers:");
        console.log("  1. MPC Signing (BridgeValidator)");
        console.log("  2. Optimistic Verification (OptimisticVerifier)");
        console.log("  3. Fraud Proofs (FraudProofVerifier)");
        console.log("  4. Rate Limiting (BridgeRateLimiter)");
        console.log("  5. Guardian System (BridgeGuardian)");
    }
}

/**
 * @title BridgeDeploymentHelper
 * @notice Test-friendly helper for deploying bridge contracts in test environments
 * @dev Provides configuration structs and deployment function for use in tests
 */
contract BridgeDeploymentHelper {
    struct BridgeDeploymentConfig {
        address deployer;
        address feeRecipient;
        address[] signers;
        uint256 signerThreshold;
        address[] guardians;
        uint256 guardianThreshold;
        uint256 challengePeriod;
        uint256 challengeBond;
        uint256 challengerReward;
    }

    struct BridgeDeploymentArtifacts {
        FraudProofVerifier fraudProofVerifier;
        BridgeRateLimiter bridgeRateLimiter;
        BridgeValidator bridgeValidator;
        BridgeGuardian bridgeGuardian;
        OptimisticVerifier optimisticVerifier;
        SecureBridge secureBridge;
    }

    /**
     * @notice Deploy all bridge contracts with the given configuration
     * @param config Deployment configuration
     * @return artifacts Deployed contract instances
     */
    function _deployBridge(BridgeDeploymentConfig memory config) internal returns (BridgeDeploymentArtifacts memory artifacts) {
        // Set defaults if not provided
        if (config.challengePeriod == 0) {
            config.challengePeriod = 6 hours;
        }
        if (config.challengeBond == 0) {
            config.challengeBond = 0.1 ether;
        }
        if (config.challengerReward == 0) {
            config.challengerReward = 0.05 ether;
        }

        // Layer 0: No Dependencies
        artifacts.fraudProofVerifier = new FraudProofVerifier();
        artifacts.bridgeRateLimiter = new BridgeRateLimiter();

        // Layer 1: Configuration Required
        artifacts.bridgeValidator = new BridgeValidator(config.signers, config.signerThreshold);
        artifacts.bridgeGuardian = new BridgeGuardian(config.guardians, config.guardianThreshold);
        artifacts.optimisticVerifier = new OptimisticVerifier(
            config.challengePeriod,
            config.challengeBond,
            config.challengerReward
        );

        // Layer 2: Main Bridge
        artifacts.secureBridge = new SecureBridge(
            address(artifacts.bridgeValidator),
            payable(address(artifacts.optimisticVerifier)),
            address(artifacts.bridgeRateLimiter),
            address(artifacts.bridgeGuardian),
            config.feeRecipient
        );

        // Post-deployment configuration: Set up cross-contract authorizations
        artifacts.bridgeRateLimiter.setAuthorizedCaller(address(artifacts.secureBridge), true);
        artifacts.optimisticVerifier.setAuthorizedCaller(address(artifacts.secureBridge), true);
        artifacts.bridgeGuardian.setBridgeTarget(address(artifacts.secureBridge));

        // Link fraud proof verifier with optimistic verifier
        artifacts.optimisticVerifier.setFraudProofVerifier(address(artifacts.fraudProofVerifier));
        artifacts.fraudProofVerifier.setOptimisticVerifier(address(artifacts.optimisticVerifier));
        artifacts.fraudProofVerifier.setBridgeValidator(address(artifacts.bridgeValidator));

        return artifacts;
    }
}
