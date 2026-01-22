// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {BridgeValidator} from "../src/bridge/BridgeValidator.sol";
import {BridgeGuardian} from "../src/bridge/BridgeGuardian.sol";
import {BridgeRateLimiter} from "../src/bridge/BridgeRateLimiter.sol";
import {OptimisticVerifier} from "../src/bridge/OptimisticVerifier.sol";
import {FraudProofVerifier} from "../src/bridge/FraudProofVerifier.sol";
import {SecureBridge} from "../src/bridge/SecureBridge.sol";

/**
 * @dev Shared deployment logic that can be reused by scripts and tests.
 */
abstract contract BridgeDeploymentHelper {
    Vm internal constant BRIDGE_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant DEFAULT_CHALLENGE_PERIOD = 1 days;
    uint256 internal constant DEFAULT_CHALLENGE_BOND = 1 ether;
    uint256 internal constant DEFAULT_CHALLENGER_REWARD = 0.5 ether;

    struct BridgeDeploymentConfig {
        address deployer;
        address feeRecipient;
        address[] signers;
        address[] guardians;
        uint256 signerThreshold;
        uint256 guardianThreshold;
    }

    struct BridgeDeploymentArtifacts {
        BridgeValidator bridgeValidator;
        BridgeGuardian bridgeGuardian;
        BridgeRateLimiter bridgeRateLimiter;
        OptimisticVerifier optimisticVerifier;
        FraudProofVerifier fraudProofVerifier;
        SecureBridge secureBridge;
    }

    function _deployBridge(BridgeDeploymentConfig memory config)
        internal
        returns (BridgeDeploymentArtifacts memory artifacts)
    {
        require(config.signers.length >= 3, "BridgeDeployment: not enough signers");
        require(config.guardians.length >= 3, "BridgeDeployment: not enough guardians");
        require(
            config.signerThreshold > 0 && config.signerThreshold <= config.signers.length,
            "BridgeDeployment: invalid signer threshold"
        );
        require(
            config.guardianThreshold > 0 && config.guardianThreshold <= config.guardians.length,
            "BridgeDeployment: invalid guardian threshold"
        );
        if (config.feeRecipient == address(0)) {
            config.feeRecipient = config.deployer;
        }

        artifacts.bridgeValidator = new BridgeValidator(config.signers, config.signerThreshold);
        artifacts.bridgeGuardian = new BridgeGuardian(config.guardians, config.guardianThreshold);
        artifacts.bridgeRateLimiter = new BridgeRateLimiter();
        artifacts.optimisticVerifier = new OptimisticVerifier(
            DEFAULT_CHALLENGE_PERIOD,
            DEFAULT_CHALLENGE_BOND,
            DEFAULT_CHALLENGER_REWARD
        );
        artifacts.fraudProofVerifier = new FraudProofVerifier();
        artifacts.secureBridge = new SecureBridge(
            address(artifacts.bridgeValidator),
            payable(address(artifacts.optimisticVerifier)),
            address(artifacts.bridgeRateLimiter),
            address(artifacts.bridgeGuardian),
            config.feeRecipient
        );

        // Wire dependencies between components
        artifacts.optimisticVerifier.setFraudProofVerifier(address(artifacts.fraudProofVerifier));
        artifacts.optimisticVerifier.setAuthorizedCaller(address(artifacts.secureBridge), true);

        artifacts.fraudProofVerifier.setOptimisticVerifier(address(artifacts.optimisticVerifier));
        artifacts.fraudProofVerifier.setBridgeValidator(address(artifacts.bridgeValidator));

        artifacts.bridgeRateLimiter.setAuthorizedCaller(address(artifacts.secureBridge), true);
        artifacts.bridgeGuardian.setBridgeTarget(address(artifacts.secureBridge));

        return artifacts;
    }

    function _loadConfig(address deployer)
        internal
        view
        returns (BridgeDeploymentConfig memory config)
    {
        config.deployer = deployer;
        config.signers = _parseAddresses(BRIDGE_VM.envOr("BRIDGE_SIGNERS", string("")));
        config.guardians = _parseAddresses(BRIDGE_VM.envOr("BRIDGE_GUARDIANS", string("")));

        if (config.signers.length == 0) {
            config.signers = _defaultAddresses(deployer, "signer", 3);
            console.log("Warning: Using default bridge signers (testing only)");
        }

        if (config.guardians.length == 0) {
            config.guardians = _defaultAddresses(deployer, "guardian", 3);
            console.log("Warning: Using default bridge guardians (testing only)");
        }

        config.signerThreshold = BRIDGE_VM.envOr("SIGNER_THRESHOLD", uint256(2));
        config.guardianThreshold = BRIDGE_VM.envOr("GUARDIAN_THRESHOLD", uint256(2));
        config.feeRecipient = BRIDGE_VM.envOr("FEE_RECIPIENT", deployer);
    }

    function _defaultAddresses(address deployer, string memory saltPrefix, uint256 count)
        internal
        pure
        returns (address[] memory defaultAddresses)
    {
        defaultAddresses = new address[](count);
        defaultAddresses[0] = deployer;
        for (uint256 i = 1; i < count; i++) {
            defaultAddresses[i] = address(uint160(uint256(keccak256(abi.encodePacked(saltPrefix, i)))));
        }
    }

    function _parseAddresses(string memory input) internal view returns (address[] memory parsed) {
        bytes memory inputBytes = bytes(input);
        if (inputBytes.length == 0) {
            return new address[](0);
        }

        uint256 segments = 1;
        for (uint256 i = 0; i < inputBytes.length; i++) {
            if (inputBytes[i] == ",") {
                segments++;
            }
        }

        parsed = new address[](segments);
        uint256 index;
        uint256 start;
        for (uint256 i = 0; i <= inputBytes.length; i++) {
            if (i == inputBytes.length || inputBytes[i] == ",") {
                string memory part = _trim(_substring(input, start, i));
                if (bytes(part).length != 0) {
                    parsed[index] = BRIDGE_VM.parseAddress(part);
                    index++;
                }
                start = i + 1;
            }
        }

        assembly {
            mstore(parsed, index)
        }
    }

    function _substring(string memory str, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (end <= start) {
            return "";
        }
        bytes memory result = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            result[i] = strBytes[start + i];
        }
        return string(result);
    }

    function _trim(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        uint256 start;
        uint256 end = strBytes.length;
        while (start < strBytes.length && strBytes[start] == 0x20) {
            start++;
        }
        while (end > start && strBytes[end - 1] == 0x20) {
            end--;
        }
        if (end <= start) {
            return "";
        }
        bytes memory result = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            result[i] = strBytes[start + i];
        }
        return string(result);
    }
}

/**
 * @title DeployBridgeScript
 * @notice Deployment script for cross-chain bridge infrastructure
 * @dev Deploys complete bridge system with security components and post-deployment wiring
 *
 * Deployment Order:
 *   1. BridgeValidator - Multi-sig validation
 *   2. BridgeGuardian - Emergency controls
 *   3. BridgeRateLimiter - Rate limiting
 *   4. OptimisticVerifier - Challenge/response layer
 *   5. FraudProofVerifier - Fraud proof system
 *   6. SecureBridge - Main bridge contract (wired to all above)
 *
 * Environment Variables:
 *   - BRIDGE_SIGNERS: Comma-separated signer addresses (min 3)
 *   - BRIDGE_GUARDIANS: Comma-separated guardian addresses (min 3)
 *   - SIGNER_THRESHOLD: Required MPC signatures (default 2)
 *   - GUARDIAN_THRESHOLD: Guardian approvals (default 2)
 *   - FEE_RECIPIENT: Address to receive bridge fees (default deployer)
 *
 * Usage:
 *   forge script script/DeployBridge.s.sol:DeployBridgeScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployBridgeScript is Script, BridgeDeploymentHelper {
    function setUp() public {}

    function run() public {
        BridgeDeploymentConfig memory config = _loadConfig(msg.sender);

        vm.startBroadcast();
        BridgeDeploymentArtifacts memory artifacts = _deployBridge(config);
        vm.stopBroadcast();

        _logSummary(artifacts, config);
    }

    function _logSummary(BridgeDeploymentArtifacts memory artifacts, BridgeDeploymentConfig memory config) internal view {
        console.log("\n=== Bridge Deployment Summary ===");
        console.log("BridgeValidator:", address(artifacts.bridgeValidator));
        console.log("BridgeGuardian:", address(artifacts.bridgeGuardian));
        console.log("BridgeRateLimiter:", address(artifacts.bridgeRateLimiter));
        console.log("OptimisticVerifier:", address(artifacts.optimisticVerifier));
        console.log("FraudProofVerifier:", address(artifacts.fraudProofVerifier));
        console.log("SecureBridge:", address(artifacts.secureBridge));
        console.log("Fee Recipient:", config.feeRecipient);
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
