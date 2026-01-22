// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";

// Compliance
import {KYCRegistry} from "../../src/compliance/KYCRegistry.sol";
import {AuditLogger} from "../../src/compliance/AuditLogger.sol";
import {ProofOfReserve} from "../../src/compliance/ProofOfReserve.sol";

/**
 * @title DeployComplianceScript
 * @notice Compliance (규제 준수) 컨트랙트 배포
 * @dev 배포되는 컨트랙트:
 *   - KYCRegistry: KYC 상태 관리 (고객 신원 확인)
 *   - AuditLogger: 감사 로그 기록 (거래 추적)
 *   - ProofOfReserve: 준비금 증명 (자산 검증)
 *
 * 의존성:
 *   - 모든 컨트랙트가 admin 주소 필요
 *
 * Usage:
 *   forge script script/deploy/DeployCompliance.s.sol:DeployComplianceScript \
 *     --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * Environment Variables:
 *   - ADMIN_ADDRESS: 관리자 주소 (기본값: 배포자)
 *   - AUDIT_RETENTION_PERIOD: 감사 로그 보관 기간 (기본값: 365일)
 *   - POR_REQUIRED_CONFIRMATIONS: 준비금 증명 필요 확인 수 (기본값: 3)
 *   - SKIP_EXISTING: 이미 배포된 컨트랙트 스킵 (기본값: true)
 */
contract DeployComplianceScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        uint256 auditRetentionPeriod = vm.envOr("AUDIT_RETENTION_PERIOD", uint256(365 days));
        uint256 porRequiredConfirmations = vm.envOr("POR_REQUIRED_CONFIRMATIONS", uint256(3));
        bool skipExisting = vm.envOr("SKIP_EXISTING", true);

        console.log("=== Compliance Deployment ===");
        console.log("Chain ID:", chainId);
        console.log("Admin:", admin);
        console.log("Audit Retention Period:", auditRetentionPeriod / 1 days, "days");
        console.log("PoR Required Confirmations:", porRequiredConfirmations);
        console.log("Skip Existing:", skipExisting);
        console.log("");

        vm.startBroadcast();

        // ============================================
        // KYCRegistry: KYC 상태 관리
        // ============================================
        console.log("--- KYC Registry ---");

        address kycRegistryAddr = _getAddress(DeploymentAddresses.KEY_KYC_REGISTRY);
        if (!skipExisting || kycRegistryAddr == address(0)) {
            KYCRegistry kycRegistry = new KYCRegistry(admin);
            _setAddress(DeploymentAddresses.KEY_KYC_REGISTRY, address(kycRegistry));
            console.log("[NEW] KYCRegistry:", address(kycRegistry));
        } else {
            console.log("[SKIP] KYCRegistry:", kycRegistryAddr);
        }

        // ============================================
        // AuditLogger: 감사 로그 기록
        // ============================================
        console.log("");
        console.log("--- Audit Logger ---");

        address auditLoggerAddr = _getAddress(DeploymentAddresses.KEY_AUDIT_LOGGER);
        if (!skipExisting || auditLoggerAddr == address(0)) {
            AuditLogger auditLogger = new AuditLogger(admin, auditRetentionPeriod);
            _setAddress(DeploymentAddresses.KEY_AUDIT_LOGGER, address(auditLogger));
            console.log("[NEW] AuditLogger:", address(auditLogger));
        } else {
            console.log("[SKIP] AuditLogger:", auditLoggerAddr);
        }

        // ============================================
        // ProofOfReserve: 준비금 증명
        // ============================================
        console.log("");
        console.log("--- Proof of Reserve ---");

        address proofOfReserveAddr = _getAddress(DeploymentAddresses.KEY_PROOF_OF_RESERVE);
        if (!skipExisting || proofOfReserveAddr == address(0)) {
            ProofOfReserve proofOfReserve = new ProofOfReserve(admin, porRequiredConfirmations);
            _setAddress(DeploymentAddresses.KEY_PROOF_OF_RESERVE, address(proofOfReserve));
            console.log("[NEW] ProofOfReserve:", address(proofOfReserve));
        } else {
            console.log("[SKIP] ProofOfReserve:", proofOfReserveAddr);
        }

        vm.stopBroadcast();

        _saveAddresses();

        console.log("");
        console.log("=== Compliance Deployment Complete ===");
        console.log("Addresses saved to:", _getDeploymentPath());
        console.log("");
        console.log("Compliance Features:");
        console.log("  - KYCRegistry: Manage customer identity verification status");
        console.log("  - AuditLogger: Record immutable audit logs for transactions");
        console.log("  - ProofOfReserve: Verify and prove asset reserves on-chain");
    }
}

/**
 * @title DeployKYCRegistryOnlyScript
 * @notice KYCRegistry만 단독 배포
 */
contract DeployKYCRegistryOnlyScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);

        console.log("=== KYCRegistry Only Deployment ===");
        console.log("Admin:", admin);

        vm.startBroadcast();

        KYCRegistry kycRegistry = new KYCRegistry(admin);
        _setAddress(DeploymentAddresses.KEY_KYC_REGISTRY, address(kycRegistry));
        console.log("KYCRegistry:", address(kycRegistry));

        vm.stopBroadcast();

        _saveAddresses();
    }
}

/**
 * @title DeployAuditLoggerOnlyScript
 * @notice AuditLogger만 단독 배포
 */
contract DeployAuditLoggerOnlyScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        uint256 retentionPeriod = vm.envOr("AUDIT_RETENTION_PERIOD", uint256(365 days));

        console.log("=== AuditLogger Only Deployment ===");
        console.log("Admin:", admin);
        console.log("Retention Period:", retentionPeriod / 1 days, "days");

        vm.startBroadcast();

        AuditLogger auditLogger = new AuditLogger(admin, retentionPeriod);
        _setAddress(DeploymentAddresses.KEY_AUDIT_LOGGER, address(auditLogger));
        console.log("AuditLogger:", address(auditLogger));

        vm.stopBroadcast();

        _saveAddresses();
    }
}

/**
 * @title DeployProofOfReserveOnlyScript
 * @notice ProofOfReserve만 단독 배포
 */
contract DeployProofOfReserveOnlyScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        uint256 requiredConfirmations = vm.envOr("POR_REQUIRED_CONFIRMATIONS", uint256(3));

        console.log("=== ProofOfReserve Only Deployment ===");
        console.log("Admin:", admin);
        console.log("Required Confirmations:", requiredConfirmations);

        vm.startBroadcast();

        ProofOfReserve proofOfReserve = new ProofOfReserve(admin, requiredConfirmations);
        _setAddress(DeploymentAddresses.KEY_PROOF_OF_RESERVE, address(proofOfReserve));
        console.log("ProofOfReserve:", address(proofOfReserve));

        vm.stopBroadcast();

        _saveAddresses();
    }
}
