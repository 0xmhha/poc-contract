// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";

// Core
import {IEntryPoint} from "../../src/erc7579-smartaccount/interfaces/IEntryPoint.sol";
import {Kernel} from "../../src/erc7579-smartaccount/Kernel.sol";
import {KernelFactory} from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";

// Validators
import {ECDSAValidator} from "../../src/erc7579-validators/ECDSAValidator.sol";
import {WeightedECDSAValidator} from "../../src/erc7579-validators/WeightedECDSAValidator.sol";
import {MultiChainValidator} from "../../src/erc7579-validators/MultiChainValidator.sol";

// Executors
import {SessionKeyExecutor} from "../../src/erc7579-executors/SessionKeyExecutor.sol";
import {RecurringPaymentExecutor} from "../../src/erc7579-executors/RecurringPaymentExecutor.sol";

// Hooks
import {AuditHook} from "../../src/erc7579-hooks/AuditHook.sol";
import {SpendingLimitHook} from "../../src/erc7579-hooks/SpendingLimitHook.sol";

// Fallbacks
import {TokenReceiverFallback} from "../../src/erc7579-fallbacks/TokenReceiverFallback.sol";
import {FlashLoanFallback} from "../../src/erc7579-fallbacks/FlashLoanFallback.sol";

/**
 * @title DeployERC7579Script
 * @notice ERC-7579 Modular Smart Account 컨트랙트 배포
 * @dev 배포되는 컨트랙트:
 *   - Kernel: 모듈러 스마트 계정 구현체
 *   - KernelFactory: Kernel 계정 생성 팩토리
 *   - Validators: ECDSAValidator, WeightedECDSAValidator, MultiChainValidator
 *   - Executors: SessionKeyExecutor, RecurringPaymentExecutor
 *   - Hooks: AuditHook, SpendingLimitHook
 *   - Fallbacks: TokenReceiverFallback, FlashLoanFallback
 *
 * 의존성:
 *   - Kernel은 EntryPoint가 필요
 *   - KernelFactory는 Kernel이 필요
 *
 * Usage:
 *   forge script script/deploy/DeployERC7579.s.sol:DeployERC7579Script \
 *     --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * Environment Variables:
 *   - SKIP_EXISTING: 이미 배포된 컨트랙트 스킵 (기본값: true)
 */
contract DeployERC7579Script is DeploymentHelper {
    function run() public {
        _initDeployment();

        bool skipExisting = vm.envOr("SKIP_EXISTING", true);

        console.log("=== ERC-7579 Modular Smart Account Deployment ===");
        console.log("Chain ID:", chainId);
        console.log("Skip Existing:", skipExisting);
        console.log("");

        // EntryPoint 의존성 확인
        address entryPointAddr = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
        require(entryPointAddr != address(0), "EntryPoint must be deployed first. Run DeployERC4337Script.");

        vm.startBroadcast();

        // ============================================
        // Core: Kernel & KernelFactory
        // ============================================
        console.log("--- Core ---");

        // Kernel - 모듈러 스마트 계정 구현체
        address kernelAddr = _getAddress(DeploymentAddresses.KEY_KERNEL);
        if (!skipExisting || kernelAddr == address(0)) {
            Kernel kernel = new Kernel(IEntryPoint(entryPointAddr));
            _setAddress(DeploymentAddresses.KEY_KERNEL, address(kernel));
            kernelAddr = address(kernel);
            console.log("[NEW] Kernel:", kernelAddr);
        } else {
            console.log("[SKIP] Kernel:", kernelAddr);
        }

        // KernelFactory - Kernel 계정 생성 팩토리
        address kernelFactoryAddr = _getAddress(DeploymentAddresses.KEY_KERNEL_FACTORY);
        if (!skipExisting || kernelFactoryAddr == address(0)) {
            KernelFactory kernelFactory = new KernelFactory(kernelAddr);
            _setAddress(DeploymentAddresses.KEY_KERNEL_FACTORY, address(kernelFactory));
            console.log("[NEW] KernelFactory:", address(kernelFactory));
        } else {
            console.log("[SKIP] KernelFactory:", kernelFactoryAddr);
        }

        // ============================================
        // Validators: 트랜잭션 서명 검증 모듈
        // ============================================
        console.log("");
        console.log("--- Validators ---");

        // ECDSAValidator
        if (!skipExisting || _getAddress(DeploymentAddresses.KEY_ECDSA_VALIDATOR) == address(0)) {
            ECDSAValidator ecdsaValidator = new ECDSAValidator();
            _setAddress(DeploymentAddresses.KEY_ECDSA_VALIDATOR, address(ecdsaValidator));
            console.log("[NEW] ECDSAValidator:", address(ecdsaValidator));
        } else {
            console.log("[SKIP] ECDSAValidator:", _getAddress(DeploymentAddresses.KEY_ECDSA_VALIDATOR));
        }

        // WeightedECDSAValidator
        if (!skipExisting || _getAddress(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR) == address(0)) {
            WeightedECDSAValidator weightedValidator = new WeightedECDSAValidator();
            _setAddress(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR, address(weightedValidator));
            console.log("[NEW] WeightedECDSAValidator:", address(weightedValidator));
        } else {
            console.log("[SKIP] WeightedECDSAValidator:", _getAddress(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR));
        }

        // MultiChainValidator
        if (!skipExisting || _getAddress(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR) == address(0)) {
            MultiChainValidator multiChainValidator = new MultiChainValidator();
            _setAddress(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR, address(multiChainValidator));
            console.log("[NEW] MultiChainValidator:", address(multiChainValidator));
        } else {
            console.log("[SKIP] MultiChainValidator:", _getAddress(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR));
        }

        // ============================================
        // Executors: 트랜잭션 실행 모듈
        // ============================================
        console.log("");
        console.log("--- Executors ---");

        // SessionKeyExecutor
        if (!skipExisting || _getAddress(DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR) == address(0)) {
            SessionKeyExecutor sessionKeyExecutor = new SessionKeyExecutor();
            _setAddress(DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR, address(sessionKeyExecutor));
            console.log("[NEW] SessionKeyExecutor:", address(sessionKeyExecutor));
        } else {
            console.log("[SKIP] SessionKeyExecutor:", _getAddress(DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR));
        }

        // RecurringPaymentExecutor
        if (!skipExisting || _getAddress(DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR) == address(0)) {
            RecurringPaymentExecutor recurringPaymentExecutor = new RecurringPaymentExecutor();
            _setAddress(DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR, address(recurringPaymentExecutor));
            console.log("[NEW] RecurringPaymentExecutor:", address(recurringPaymentExecutor));
        } else {
            console.log("[SKIP] RecurringPaymentExecutor:", _getAddress(DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR));
        }

        // ============================================
        // Hooks: 실행 전/후 훅 모듈
        // ============================================
        console.log("");
        console.log("--- Hooks ---");

        // AuditHook
        if (!skipExisting || _getAddress(DeploymentAddresses.KEY_AUDIT_HOOK) == address(0)) {
            AuditHook auditHook = new AuditHook();
            _setAddress(DeploymentAddresses.KEY_AUDIT_HOOK, address(auditHook));
            console.log("[NEW] AuditHook:", address(auditHook));
        } else {
            console.log("[SKIP] AuditHook:", _getAddress(DeploymentAddresses.KEY_AUDIT_HOOK));
        }

        // SpendingLimitHook
        if (!skipExisting || _getAddress(DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK) == address(0)) {
            SpendingLimitHook spendingLimitHook = new SpendingLimitHook();
            _setAddress(DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK, address(spendingLimitHook));
            console.log("[NEW] SpendingLimitHook:", address(spendingLimitHook));
        } else {
            console.log("[SKIP] SpendingLimitHook:", _getAddress(DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK));
        }

        // ============================================
        // Fallbacks: fallback 함수 처리 모듈
        // ============================================
        console.log("");
        console.log("--- Fallbacks ---");

        // TokenReceiverFallback
        if (!skipExisting || _getAddress(DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK) == address(0)) {
            TokenReceiverFallback tokenReceiverFallback = new TokenReceiverFallback();
            _setAddress(DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK, address(tokenReceiverFallback));
            console.log("[NEW] TokenReceiverFallback:", address(tokenReceiverFallback));
        } else {
            console.log("[SKIP] TokenReceiverFallback:", _getAddress(DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK));
        }

        // FlashLoanFallback
        if (!skipExisting || _getAddress(DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK) == address(0)) {
            FlashLoanFallback flashLoanFallback = new FlashLoanFallback();
            _setAddress(DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK, address(flashLoanFallback));
            console.log("[NEW] FlashLoanFallback:", address(flashLoanFallback));
        } else {
            console.log("[SKIP] FlashLoanFallback:", _getAddress(DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK));
        }

        vm.stopBroadcast();

        _saveAddresses();

        console.log("");
        console.log("=== ERC-7579 Deployment Complete ===");
        console.log("Addresses saved to:", _getDeploymentPath());
    }
}

/**
 * @title DeployKernelOnlyScript
 * @notice Kernel + KernelFactory만 단독 배포
 */
contract DeployKernelOnlyScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        address entryPointAddr = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
        require(entryPointAddr != address(0), "EntryPoint must be deployed first");

        console.log("=== Kernel Only Deployment ===");

        vm.startBroadcast();

        Kernel kernel = new Kernel(IEntryPoint(entryPointAddr));
        _setAddress(DeploymentAddresses.KEY_KERNEL, address(kernel));
        console.log("Kernel:", address(kernel));

        KernelFactory kernelFactory = new KernelFactory(address(kernel));
        _setAddress(DeploymentAddresses.KEY_KERNEL_FACTORY, address(kernelFactory));
        console.log("KernelFactory:", address(kernelFactory));

        vm.stopBroadcast();

        _saveAddresses();
    }
}

/**
 * @title DeployValidatorsOnlyScript
 * @notice Validator 모듈만 단독 배포
 */
contract DeployValidatorsOnlyScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        console.log("=== Validators Only Deployment ===");

        vm.startBroadcast();

        ECDSAValidator ecdsaValidator = new ECDSAValidator();
        _setAddress(DeploymentAddresses.KEY_ECDSA_VALIDATOR, address(ecdsaValidator));
        console.log("ECDSAValidator:", address(ecdsaValidator));

        WeightedECDSAValidator weightedValidator = new WeightedECDSAValidator();
        _setAddress(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR, address(weightedValidator));
        console.log("WeightedECDSAValidator:", address(weightedValidator));

        MultiChainValidator multiChainValidator = new MultiChainValidator();
        _setAddress(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR, address(multiChainValidator));
        console.log("MultiChainValidator:", address(multiChainValidator));

        vm.stopBroadcast();

        _saveAddresses();
    }
}
