// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";
import {KYCRegistry} from "../../src/compliance/KYCRegistry.sol";
import {AuditLogger} from "../../src/compliance/AuditLogger.sol";
import {ProofOfReserve} from "../../src/compliance/ProofOfReserve.sol";
import {RegulatoryRegistry} from "../../src/compliance/RegulatoryRegistry.sol";

/**
 * @title DeployComplianceScript
 * @notice Deployment script for Compliance contracts
 * @dev Deploys KYCRegistry, AuditLogger, ProofOfReserve, and RegulatoryRegistry
 *
 * Deployed Contracts:
 *   - KYCRegistry: KYC status management with multi-jurisdiction support
 *   - AuditLogger: Immutable audit logging for regulatory compliance
 *   - ProofOfReserve: 100% reserve verification using Chainlink PoR
 *   - RegulatoryRegistry: Regulator management with 2-of-3 multi-sig trace approval
 *
 * Dependencies: None (Layer 0 contracts)
 *
 * Environment Variables:
 *   - ADMIN_ADDRESS: Admin address for contracts (defaults to deployer)
 *   - RETENTION_PERIOD: AuditLogger retention period in seconds (default: 7 years)
 *   - AUTO_PAUSE_THRESHOLD: ProofOfReserve auto-pause threshold (default: 3)
 *   - APPROVER_1, APPROVER_2, APPROVER_3: RegulatoryRegistry approvers (defaults to deployer for all)
 *
 * Usage:
 *   FOUNDRY_PROFILE=compliance forge script script/deploy-contract/DeployCompliance.s.sol:DeployComplianceScript \
 *     --rpc-url <RPC_URL> --broadcast
 */
contract DeployComplianceScript is DeploymentHelper {
    KYCRegistry public kycRegistry;
    AuditLogger public auditLogger;
    ProofOfReserve public proofOfReserve;
    RegulatoryRegistry public regulatoryRegistry;

    // Default values
    uint256 constant DEFAULT_RETENTION_PERIOD = 7 * 365 days; // 7 years
    uint256 constant DEFAULT_AUTO_PAUSE_THRESHOLD = 3;

    function setUp() public {}

    function run() public {
        _initDeployment();

        // Get configuration from environment
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        uint256 retentionPeriod = vm.envOr("RETENTION_PERIOD", DEFAULT_RETENTION_PERIOD);
        uint256 autoPauseThreshold = vm.envOr("AUTO_PAUSE_THRESHOLD", DEFAULT_AUTO_PAUSE_THRESHOLD);

        // Get approvers for RegulatoryRegistry (defaults to deployer for testing)
        address approver1 = vm.envOr("APPROVER_1", msg.sender);
        address approver2 = vm.envOr("APPROVER_2", msg.sender);
        address approver3 = vm.envOr("APPROVER_3", msg.sender);

        vm.startBroadcast();

        // Deploy KYCRegistry
        address existing = _getAddress(DeploymentAddresses.KEY_KYC_REGISTRY);
        if (existing == address(0)) {
            kycRegistry = new KYCRegistry(admin);
            _setAddress(DeploymentAddresses.KEY_KYC_REGISTRY, address(kycRegistry));
            console.log("KYCRegistry deployed at:", address(kycRegistry));
        } else {
            kycRegistry = KYCRegistry(existing);
            console.log("KYCRegistry: Using existing at", existing);
        }

        // Deploy AuditLogger
        existing = _getAddress(DeploymentAddresses.KEY_AUDIT_LOGGER);
        if (existing == address(0)) {
            auditLogger = new AuditLogger(admin, retentionPeriod);
            _setAddress(DeploymentAddresses.KEY_AUDIT_LOGGER, address(auditLogger));
            console.log("AuditLogger deployed at:", address(auditLogger));
        } else {
            auditLogger = AuditLogger(existing);
            console.log("AuditLogger: Using existing at", existing);
        }

        // Deploy ProofOfReserve
        existing = _getAddress(DeploymentAddresses.KEY_PROOF_OF_RESERVE);
        if (existing == address(0)) {
            proofOfReserve = new ProofOfReserve(admin, autoPauseThreshold);
            _setAddress(DeploymentAddresses.KEY_PROOF_OF_RESERVE, address(proofOfReserve));
            console.log("ProofOfReserve deployed at:", address(proofOfReserve));
        } else {
            proofOfReserve = ProofOfReserve(existing);
            console.log("ProofOfReserve: Using existing at", existing);
        }

        // Deploy RegulatoryRegistry
        existing = _getAddress(DeploymentAddresses.KEY_REGULATORY_REGISTRY);
        if (existing == address(0)) {
            address[] memory approvers = new address[](3);
            approvers[0] = approver1;
            approvers[1] = approver2;
            approvers[2] = approver3;

            // For testing: if all approvers are the same (deployer), create unique addresses
            if (approver1 == approver2 && approver2 == approver3) {
                console.log("Warning: Using same address for all approvers (test mode)");
                console.log("For production, set APPROVER_1, APPROVER_2, APPROVER_3 env vars");
                // Create deterministic addresses for testing
                approvers[1] = address(uint160(uint256(keccak256(abi.encodePacked(approver1, uint256(1))))));
                approvers[2] = address(uint160(uint256(keccak256(abi.encodePacked(approver1, uint256(2))))));
            }

            regulatoryRegistry = new RegulatoryRegistry(approvers);
            _setAddress(DeploymentAddresses.KEY_REGULATORY_REGISTRY, address(regulatoryRegistry));
            console.log("RegulatoryRegistry deployed at:", address(regulatoryRegistry));
            console.log("  Approver 1:", approvers[0]);
            console.log("  Approver 2:", approvers[1]);
            console.log("  Approver 3:", approvers[2]);
        } else {
            regulatoryRegistry = RegulatoryRegistry(existing);
            console.log("RegulatoryRegistry: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        console.log("\n=== Compliance Deployment Summary ===");
        console.log("Admin:", admin);
        console.log("KYCRegistry:", address(kycRegistry));
        console.log("AuditLogger:", address(auditLogger));
        console.log("  Retention Period:", retentionPeriod / 1 days, "days");
        console.log("ProofOfReserve:", address(proofOfReserve));
        console.log("  Auto-Pause Threshold:", autoPauseThreshold);
        console.log("RegulatoryRegistry:", address(regulatoryRegistry));
        console.log("\nCompliance contracts are ready for use:");
        console.log("  - KYCRegistry: KYC status and sanctions management");
        console.log("  - AuditLogger: Immutable audit trail");
        console.log("  - ProofOfReserve: Reserve verification (configure oracle)");
        console.log("  - RegulatoryRegistry: 2-of-3 trace request approval");
    }
}
