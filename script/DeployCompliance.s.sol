// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {KYCRegistry} from "../src/compliance/KYCRegistry.sol";
import {AuditLogger} from "../src/compliance/AuditLogger.sol";
import {ProofOfReserve} from "../src/compliance/ProofOfReserve.sol";
import {RegulatoryRegistry} from "../src/compliance/RegulatoryRegistry.sol";

/**
 * @title DeployComplianceScript
 * @notice Deployment script for compliance infrastructure
 * @dev Deploys KYC, audit, and regulatory compliance contracts
 *
 * Deployment Order:
 *   1. KYCRegistry - KYC verification
 *   2. AuditLogger - Audit trail logging
 *   3. ProofOfReserve - Reserve attestation
 *   4. RegulatoryRegistry - Regulatory framework
 *
 * Environment Variables:
 *   - ADMIN_ADDRESS: Admin address (default: deployer)
 *   - RETENTION_PERIOD: Audit log retention in seconds (default: 365 days)
 *   - AUTO_PAUSE_THRESHOLD: Proof of reserve failures before auto-pause (default: 3)
 *   - APPROVERS: Comma-separated list of 3 approver addresses for RegulatoryRegistry
 *
 * Usage:
 *   forge script script/DeployCompliance.s.sol:DeployComplianceScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployComplianceScript is Script {
    KYCRegistry public kycRegistry;
    AuditLogger public auditLogger;
    ProofOfReserve public proofOfReserve;
    RegulatoryRegistry public regulatoryRegistry;

    // Defaults
    uint256 constant DEFAULT_RETENTION_PERIOD = 365 days;
    uint256 constant DEFAULT_AUTO_PAUSE_THRESHOLD = 3;

    function setUp() public {}

    function run() public {
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        uint256 retentionPeriod = vm.envOr("RETENTION_PERIOD", DEFAULT_RETENTION_PERIOD);
        uint256 autoPauseThreshold = vm.envOr("AUTO_PAUSE_THRESHOLD", DEFAULT_AUTO_PAUSE_THRESHOLD);

        // Parse approvers for RegulatoryRegistry (requires exactly 3)
        address[] memory approvers = new address[](3);
        approvers[0] = vm.envOr("APPROVER_1", admin);
        approvers[1] = vm.envOr("APPROVER_2", address(uint160(uint256(keccak256("approver2")))));
        approvers[2] = vm.envOr("APPROVER_3", address(uint160(uint256(keccak256("approver3")))));

        vm.startBroadcast();

        // 1. Deploy KYC Registry
        kycRegistry = new KYCRegistry(admin);
        console.log("KYCRegistry deployed at:", address(kycRegistry));

        // 2. Deploy Audit Logger
        auditLogger = new AuditLogger(admin, retentionPeriod);
        console.log("AuditLogger deployed at:", address(auditLogger));

        // 3. Deploy Proof of Reserve
        proofOfReserve = new ProofOfReserve(admin, autoPauseThreshold);
        console.log("ProofOfReserve deployed at:", address(proofOfReserve));

        // 4. Deploy Regulatory Registry
        regulatoryRegistry = new RegulatoryRegistry(approvers);
        console.log("RegulatoryRegistry deployed at:", address(regulatoryRegistry));

        vm.stopBroadcast();

        // Log summary
        console.log("\n=== Compliance Deployment Summary ===");
        console.log("Admin:", admin);
        console.log("KYCRegistry:", address(kycRegistry));
        console.log("AuditLogger:", address(auditLogger));
        console.log("ProofOfReserve:", address(proofOfReserve));
        console.log("RegulatoryRegistry:", address(regulatoryRegistry));
    }
}

/**
 * @title DeployKYCRegistryScript
 * @notice Deployment script for only KYCRegistry
 *
 * Usage:
 *   ADMIN_ADDRESS=0x... forge script script/DeployCompliance.s.sol:DeployKYCRegistryScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployKYCRegistryScript is Script {
    function run() public {
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);

        vm.startBroadcast();

        KYCRegistry kycRegistry = new KYCRegistry(admin);

        vm.stopBroadcast();

        console.log("KYCRegistry deployed at:", address(kycRegistry));
        console.log("Admin:", admin);
    }
}
