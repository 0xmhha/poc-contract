// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

// EntryPoint & Kernel
import {EntryPoint} from "../src/erc4337-entrypoint/EntryPoint.sol";
import {IEntryPoint as IEntryPointKernel} from "../src/erc7579-smartaccount/interfaces/IEntryPoint.sol";
import {IEntryPoint as IEntryPointPaymaster} from "../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import {Kernel} from "../src/erc7579-smartaccount/Kernel.sol";
import {KernelFactory} from "../src/erc7579-smartaccount/factory/KernelFactory.sol";

// Validators
import {ECDSAValidator} from "../src/erc7579-validators/ECDSAValidator.sol";
import {WeightedECDSAValidator} from "../src/erc7579-validators/WeightedECDSAValidator.sol";
import {MultiChainValidator} from "../src/erc7579-validators/MultiChainValidator.sol";

// Paymasters
import {VerifyingPaymaster} from "../src/erc4337-paymaster/VerifyingPaymaster.sol";

// Executors
import {SessionKeyExecutor} from "../src/erc7579-executors/SessionKeyExecutor.sol";
import {RecurringPaymentExecutor} from "../src/erc7579-executors/RecurringPaymentExecutor.sol";

// Hooks
import {AuditHook} from "../src/erc7579-hooks/AuditHook.sol";
import {SpendingLimitHook} from "../src/erc7579-hooks/SpendingLimitHook.sol";

// Fallbacks
import {TokenReceiverFallback} from "../src/erc7579-fallbacks/TokenReceiverFallback.sol";
import {FlashLoanFallback} from "../src/erc7579-fallbacks/FlashLoanFallback.sol";

// Tokens
import {WKRW} from "../src/tokens/WKRW.sol";

// DeFi
import {PriceOracle} from "../src/defi/PriceOracle.sol";

// Privacy
import {ERC5564Announcer} from "../src/privacy/ERC5564Announcer.sol";
import {ERC6538Registry} from "../src/privacy/ERC6538Registry.sol";
import {PrivateBank} from "../src/privacy/PrivateBank.sol";

// Compliance
import {KYCRegistry} from "../src/compliance/KYCRegistry.sol";
import {AuditLogger} from "../src/compliance/AuditLogger.sol";
import {ProofOfReserve} from "../src/compliance/ProofOfReserve.sol";

// Subscription
import {ERC7715PermissionManager} from "../src/subscription/ERC7715PermissionManager.sol";
import {SubscriptionManager} from "../src/subscription/SubscriptionManager.sol";

/**
 * @title DeployAllScript
 * @notice Master deployment script for the entire protocol
 * @dev Deploys all core infrastructure in the correct order
 *
 * This script deploys:
 * - Core: EntryPoint, Kernel, KernelFactory
 * - Validators: ECDSA, WeightedECDSA, MultiChain
 * - Paymaster: VerifyingPaymaster
 * - Executors: SessionKey, RecurringPayment
 * - Hooks: Audit, SpendingLimit
 * - Fallbacks: TokenReceiver, FlashLoan
 * - Tokens: WKRW
 * - DeFi: PriceOracle
 * - Privacy: ERC5564Announcer, ERC6538Registry, PrivateBank
 * - Compliance: KYCRegistry, AuditLogger, ProofOfReserve
 * - Subscription: ERC7715PermissionManager, SubscriptionManager
 *
 * Environment Variables:
 *   - ADMIN_ADDRESS: Admin/owner address (default: deployer)
 *   - VERIFYING_SIGNER: Signer for VerifyingPaymaster (default: deployer)
 *
 * Usage:
 *   forge script script/DeployAll.s.sol:DeployAllScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployAllScript is Script {
    // Core
    EntryPoint public entryPoint;
    Kernel public kernelImpl;
    KernelFactory public kernelFactory;

    // Validators
    ECDSAValidator public ecdsaValidator;
    WeightedECDSAValidator public weightedValidator;
    MultiChainValidator public multiChainValidator;

    // Paymaster
    VerifyingPaymaster public verifyingPaymaster;

    // Executors
    SessionKeyExecutor public sessionKeyExecutor;
    RecurringPaymentExecutor public recurringPaymentExecutor;

    // Hooks
    AuditHook public auditHook;
    SpendingLimitHook public spendingLimitHook;

    // Fallbacks
    TokenReceiverFallback public tokenReceiverFallback;
    FlashLoanFallback public flashLoanFallback;

    // Tokens
    WKRW public wkrw;

    // DeFi
    PriceOracle public priceOracle;

    // Privacy
    ERC5564Announcer public announcer;
    ERC6538Registry public registry;
    PrivateBank public privateBank;

    // Compliance
    KYCRegistry public kycRegistry;
    AuditLogger public auditLogger;
    ProofOfReserve public proofOfReserve;

    // Subscription
    ERC7715PermissionManager public permissionManager;
    SubscriptionManager public subscriptionManager;

    function setUp() public {}

    function run() public {
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        address verifyingSigner = vm.envOr("VERIFYING_SIGNER", msg.sender);

        vm.startBroadcast();

        console.log("=== Starting Full Protocol Deployment ===\n");

        // ============ 1. Core Infrastructure ============
        console.log("--- Deploying Core Infrastructure ---");

        entryPoint = new EntryPoint();
        console.log("EntryPoint:", address(entryPoint));

        kernelImpl = new Kernel(IEntryPointKernel(address(entryPoint)));
        console.log("Kernel Implementation:", address(kernelImpl));

        kernelFactory = new KernelFactory(address(kernelImpl));
        console.log("KernelFactory:", address(kernelFactory));

        // ============ 2. Validators ============
        console.log("\n--- Deploying Validators ---");

        ecdsaValidator = new ECDSAValidator();
        console.log("ECDSAValidator:", address(ecdsaValidator));

        weightedValidator = new WeightedECDSAValidator();
        console.log("WeightedECDSAValidator:", address(weightedValidator));

        multiChainValidator = new MultiChainValidator();
        console.log("MultiChainValidator:", address(multiChainValidator));

        // ============ 3. Paymaster ============
        console.log("\n--- Deploying Paymaster ---");

        verifyingPaymaster = new VerifyingPaymaster(
            IEntryPointPaymaster(address(entryPoint)),
            admin,
            verifyingSigner
        );
        console.log("VerifyingPaymaster:", address(verifyingPaymaster));

        // ============ 4. Executors ============
        console.log("\n--- Deploying Executors ---");

        sessionKeyExecutor = new SessionKeyExecutor();
        console.log("SessionKeyExecutor:", address(sessionKeyExecutor));

        recurringPaymentExecutor = new RecurringPaymentExecutor();
        console.log("RecurringPaymentExecutor:", address(recurringPaymentExecutor));

        // ============ 5. Hooks ============
        console.log("\n--- Deploying Hooks ---");

        auditHook = new AuditHook();
        console.log("AuditHook:", address(auditHook));

        spendingLimitHook = new SpendingLimitHook();
        console.log("SpendingLimitHook:", address(spendingLimitHook));

        // ============ 6. Fallbacks ============
        console.log("\n--- Deploying Fallbacks ---");

        tokenReceiverFallback = new TokenReceiverFallback();
        console.log("TokenReceiverFallback:", address(tokenReceiverFallback));

        flashLoanFallback = new FlashLoanFallback();
        console.log("FlashLoanFallback:", address(flashLoanFallback));

        // ============ 7. Tokens ============
        console.log("\n--- Deploying Tokens ---");

        wkrw = new WKRW();
        console.log("WKRW:", address(wkrw));

        // ============ 8. DeFi ============
        console.log("\n--- Deploying DeFi ---");

        priceOracle = new PriceOracle();
        console.log("PriceOracle:", address(priceOracle));

        // ============ 9. Privacy ============
        console.log("\n--- Deploying Privacy Infrastructure ---");

        announcer = new ERC5564Announcer();
        console.log("ERC5564Announcer:", address(announcer));

        registry = new ERC6538Registry();
        console.log("ERC6538Registry:", address(registry));

        privateBank = new PrivateBank(address(announcer), address(registry));
        console.log("PrivateBank:", address(privateBank));

        // ============ 10. Compliance ============
        console.log("\n--- Deploying Compliance ---");

        kycRegistry = new KYCRegistry(admin);
        console.log("KYCRegistry:", address(kycRegistry));

        auditLogger = new AuditLogger(admin, 365 days);
        console.log("AuditLogger:", address(auditLogger));

        proofOfReserve = new ProofOfReserve(admin, 3);
        console.log("ProofOfReserve:", address(proofOfReserve));

        // ============ 11. Subscription ============
        console.log("\n--- Deploying Subscription ---");

        permissionManager = new ERC7715PermissionManager();
        console.log("ERC7715PermissionManager:", address(permissionManager));

        subscriptionManager = new SubscriptionManager(address(permissionManager));
        console.log("SubscriptionManager:", address(subscriptionManager));

        vm.stopBroadcast();

        // ============ Final Summary ============
        _printSummary(admin);
    }

    function _printSummary(address admin) internal view {
        console.log("\n");
        console.log("================================================================");
        console.log("         FULL PROTOCOL DEPLOYMENT COMPLETE                      ");
        console.log("================================================================");
        console.log("\n--- CORE ---");
        _logAddress("EntryPoint", address(entryPoint));
        _logAddress("Kernel Implementation", address(kernelImpl));
        _logAddress("KernelFactory", address(kernelFactory));
        console.log("\n--- VALIDATORS ---");
        _logAddress("ECDSAValidator", address(ecdsaValidator));
        _logAddress("WeightedECDSAValidator", address(weightedValidator));
        _logAddress("MultiChainValidator", address(multiChainValidator));
        console.log("\n--- PAYMASTER ---");
        _logAddress("VerifyingPaymaster", address(verifyingPaymaster));
        console.log("\n--- EXECUTORS ---");
        _logAddress("SessionKeyExecutor", address(sessionKeyExecutor));
        _logAddress("RecurringPaymentExecutor", address(recurringPaymentExecutor));
        console.log("\n--- HOOKS ---");
        _logAddress("AuditHook", address(auditHook));
        _logAddress("SpendingLimitHook", address(spendingLimitHook));
        console.log("\n--- FALLBACKS ---");
        _logAddress("TokenReceiverFallback", address(tokenReceiverFallback));
        _logAddress("FlashLoanFallback", address(flashLoanFallback));
        console.log("\n--- TOKENS & DEFI ---");
        _logAddress("WKRW", address(wkrw));
        _logAddress("PriceOracle", address(priceOracle));
        console.log("\n--- PRIVACY ---");
        _logAddress("ERC5564Announcer", address(announcer));
        _logAddress("ERC6538Registry", address(registry));
        _logAddress("PrivateBank", address(privateBank));
        console.log("\n--- COMPLIANCE ---");
        _logAddress("KYCRegistry", address(kycRegistry));
        _logAddress("AuditLogger", address(auditLogger));
        _logAddress("ProofOfReserve", address(proofOfReserve));
        console.log("\n--- SUBSCRIPTION ---");
        _logAddress("ERC7715PermissionManager", address(permissionManager));
        _logAddress("SubscriptionManager", address(subscriptionManager));
        console.log("\n--- ADMIN ---");
        _logAddress("Admin/Owner", admin);
        console.log("\n================================================================");
    }

    function _logAddress(string memory name, address addr) internal pure {
        console.log(string.concat("  ", name, ": ", vm.toString(addr)));
    }
}

/**
 * @title DeployCoreScript
 * @notice Minimal deployment for core smart account infrastructure
 *
 * Deploys only:
 * - EntryPoint
 * - Kernel Implementation
 * - KernelFactory
 * - ECDSAValidator
 * - VerifyingPaymaster
 *
 * Usage:
 *   forge script script/DeployAll.s.sol:DeployCoreScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployCoreScript is Script {
    function run() public {
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);

        vm.startBroadcast();

        // EntryPoint
        EntryPoint entryPoint = new EntryPoint();
        console.log("EntryPoint:", address(entryPoint));

        // Kernel
        Kernel kernelImpl = new Kernel(IEntryPointKernel(address(entryPoint)));
        console.log("Kernel:", address(kernelImpl));

        // Factory
        KernelFactory factory = new KernelFactory(address(kernelImpl));
        console.log("KernelFactory:", address(factory));

        // Validator
        ECDSAValidator validator = new ECDSAValidator();
        console.log("ECDSAValidator:", address(validator));

        // Paymaster
        VerifyingPaymaster paymaster = new VerifyingPaymaster(
            IEntryPointPaymaster(address(entryPoint)),
            admin,
            admin
        );
        console.log("VerifyingPaymaster:", address(paymaster));

        vm.stopBroadcast();
    }
}

/**
 * @title DeployModulesScript
 * @notice Deploy all ERC-7579 modules (validators, executors, hooks, fallbacks)
 *
 * Usage:
 *   forge script script/DeployAll.s.sol:DeployModulesScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployModulesScript is Script {
    function run() public {
        vm.startBroadcast();

        console.log("=== Deploying ERC-7579 Modules ===\n");

        // Validators
        console.log("Validators:");
        ECDSAValidator ecdsa = new ECDSAValidator();
        console.log("  ECDSAValidator:", address(ecdsa));

        WeightedECDSAValidator weighted = new WeightedECDSAValidator();
        console.log("  WeightedECDSAValidator:", address(weighted));

        MultiChainValidator multiChain = new MultiChainValidator();
        console.log("  MultiChainValidator:", address(multiChain));

        // Executors
        console.log("\nExecutors:");
        SessionKeyExecutor sessionKey = new SessionKeyExecutor();
        console.log("  SessionKeyExecutor:", address(sessionKey));

        RecurringPaymentExecutor recurring = new RecurringPaymentExecutor();
        console.log("  RecurringPaymentExecutor:", address(recurring));

        // Hooks
        console.log("\nHooks:");
        AuditHook audit = new AuditHook();
        console.log("  AuditHook:", address(audit));

        SpendingLimitHook spending = new SpendingLimitHook();
        console.log("  SpendingLimitHook:", address(spending));

        // Fallbacks
        console.log("\nFallbacks:");
        TokenReceiverFallback tokenReceiver = new TokenReceiverFallback();
        console.log("  TokenReceiverFallback:", address(tokenReceiver));

        FlashLoanFallback flashLoan = new FlashLoanFallback();
        console.log("  FlashLoanFallback:", address(flashLoan));

        vm.stopBroadcast();
    }
}
