// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "./utils/DeploymentAddresses.sol";

// Core
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
import {ERC20Paymaster} from "../src/erc4337-paymaster/ERC20Paymaster.sol";
import {IPriceOracle} from "../src/erc4337-paymaster/interfaces/IPriceOracle.sol";

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
 * @title DeployOrchestratorScript
 * @notice Sequential deployment orchestrator with dependency management
 * @dev Deploys all contracts in correct order, saving addresses for dependencies
 *
 * Deployment Layers:
 *   Layer 0: Independent contracts (no dependencies)
 *   Layer 1: Contracts depending on Layer 0
 *   Layer 2: Contracts depending on Layer 1
 *
 * Usage:
 *   # Deploy everything sequentially
 *   forge script script/DeployOrchestrator.s.sol:DeployOrchestratorScript --rpc-url <RPC_URL> --broadcast
 *
 *   # Deploy only specific layers
 *   DEPLOY_LAYER=0 forge script script/DeployOrchestrator.s.sol:DeployOrchestratorScript --rpc-url <RPC_URL> --broadcast
 *
 * Environment Variables:
 *   - DEPLOY_LAYER: 0, 1, 2, or all (default: all)
 *   - ADMIN_ADDRESS: Admin/owner address (default: deployer)
 *   - SKIP_EXISTING: Skip contracts that already have addresses in the deployment file (default: true)
 */
contract DeployOrchestratorScript is DeploymentHelper {
    // Configuration
    address public admin;
    bool public skipExisting;

    function setUp() public {}

    function run() public {
        _initDeployment();

        admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        skipExisting = vm.envOr("SKIP_EXISTING", true);
        string memory deployLayer = vm.envOr("DEPLOY_LAYER", string("all"));

        console.log("=== Deployment Orchestrator ===");
        console.log("Chain ID:", chainId);
        console.log("Admin:", admin);
        console.log("Skip Existing:", skipExisting);
        console.log("Deploy Layer:", deployLayer);
        console.log("");

        vm.startBroadcast();

        if (_shouldDeployLayer(deployLayer, "0") || _shouldDeployLayer(deployLayer, "all")) {
            _deployLayer0();
        }

        if (_shouldDeployLayer(deployLayer, "1") || _shouldDeployLayer(deployLayer, "all")) {
            _deployLayer1();
        }

        if (_shouldDeployLayer(deployLayer, "2") || _shouldDeployLayer(deployLayer, "all")) {
            _deployLayer2();
        }

        vm.stopBroadcast();

        // Save all addresses
        _saveAddresses();

        // Print summary
        _printSummary();
    }

    function _shouldDeployLayer(string memory target, string memory layer) internal pure returns (bool) {
        return keccak256(bytes(target)) == keccak256(bytes(layer));
    }

    function _shouldDeploy(string memory key) internal view returns (bool) {
        if (!skipExisting) return true;
        return _getAddress(key) == address(0);
    }

    // ============================================================
    // Layer 0: Independent Contracts (No Dependencies)
    // ============================================================
    function _deployLayer0() internal {
        console.log("--- Layer 0: Independent Contracts ---");

        // EntryPoint
        if (_shouldDeploy(DeploymentAddresses.KEY_ENTRYPOINT)) {
            EntryPoint entryPoint = new EntryPoint();
            _setAddress(DeploymentAddresses.KEY_ENTRYPOINT, address(entryPoint));
            console.log("EntryPoint:", address(entryPoint));
        } else {
            console.log("EntryPoint: SKIPPED (already deployed)");
        }

        // Validators
        if (_shouldDeploy(DeploymentAddresses.KEY_ECDSA_VALIDATOR)) {
            ECDSAValidator validator = new ECDSAValidator();
            _setAddress(DeploymentAddresses.KEY_ECDSA_VALIDATOR, address(validator));
            console.log("ECDSAValidator:", address(validator));
        } else {
            console.log("ECDSAValidator: SKIPPED");
        }

        if (_shouldDeploy(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR)) {
            WeightedECDSAValidator validator = new WeightedECDSAValidator();
            _setAddress(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR, address(validator));
            console.log("WeightedECDSAValidator:", address(validator));
        } else {
            console.log("WeightedECDSAValidator: SKIPPED");
        }

        if (_shouldDeploy(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR)) {
            MultiChainValidator validator = new MultiChainValidator();
            _setAddress(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR, address(validator));
            console.log("MultiChainValidator:", address(validator));
        } else {
            console.log("MultiChainValidator: SKIPPED");
        }

        // Executors
        if (_shouldDeploy(DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR)) {
            SessionKeyExecutor executor = new SessionKeyExecutor();
            _setAddress(DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR, address(executor));
            console.log("SessionKeyExecutor:", address(executor));
        } else {
            console.log("SessionKeyExecutor: SKIPPED");
        }

        if (_shouldDeploy(DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR)) {
            RecurringPaymentExecutor executor = new RecurringPaymentExecutor();
            _setAddress(DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR, address(executor));
            console.log("RecurringPaymentExecutor:", address(executor));
        } else {
            console.log("RecurringPaymentExecutor: SKIPPED");
        }

        // Hooks
        if (_shouldDeploy(DeploymentAddresses.KEY_AUDIT_HOOK)) {
            AuditHook hook = new AuditHook();
            _setAddress(DeploymentAddresses.KEY_AUDIT_HOOK, address(hook));
            console.log("AuditHook:", address(hook));
        } else {
            console.log("AuditHook: SKIPPED");
        }

        if (_shouldDeploy(DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK)) {
            SpendingLimitHook hook = new SpendingLimitHook();
            _setAddress(DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK, address(hook));
            console.log("SpendingLimitHook:", address(hook));
        } else {
            console.log("SpendingLimitHook: SKIPPED");
        }

        // Fallbacks
        if (_shouldDeploy(DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK)) {
            TokenReceiverFallback fallbackHandler = new TokenReceiverFallback();
            _setAddress(DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK, address(fallbackHandler));
            console.log("TokenReceiverFallback:", address(fallbackHandler));
        } else {
            console.log("TokenReceiverFallback: SKIPPED");
        }

        if (_shouldDeploy(DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK)) {
            FlashLoanFallback fallbackHandler = new FlashLoanFallback();
            _setAddress(DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK, address(fallbackHandler));
            console.log("FlashLoanFallback:", address(fallbackHandler));
        } else {
            console.log("FlashLoanFallback: SKIPPED");
        }

        // Tokens
        if (_shouldDeploy(DeploymentAddresses.KEY_WKRW)) {
            WKRW wkrw = new WKRW();
            _setAddress(DeploymentAddresses.KEY_WKRW, address(wkrw));
            console.log("WKRW:", address(wkrw));
        } else {
            console.log("WKRW: SKIPPED");
        }

        // DeFi
        if (_shouldDeploy(DeploymentAddresses.KEY_PRICE_ORACLE)) {
            PriceOracle oracle = new PriceOracle();
            _setAddress(DeploymentAddresses.KEY_PRICE_ORACLE, address(oracle));
            console.log("PriceOracle:", address(oracle));
        } else {
            console.log("PriceOracle: SKIPPED");
        }

        // Privacy (base contracts)
        if (_shouldDeploy(DeploymentAddresses.KEY_ANNOUNCER)) {
            ERC5564Announcer announcer = new ERC5564Announcer();
            _setAddress(DeploymentAddresses.KEY_ANNOUNCER, address(announcer));
            console.log("ERC5564Announcer:", address(announcer));
        } else {
            console.log("ERC5564Announcer: SKIPPED");
        }

        if (_shouldDeploy(DeploymentAddresses.KEY_REGISTRY)) {
            ERC6538Registry registry = new ERC6538Registry();
            _setAddress(DeploymentAddresses.KEY_REGISTRY, address(registry));
            console.log("ERC6538Registry:", address(registry));
        } else {
            console.log("ERC6538Registry: SKIPPED");
        }

        // Compliance
        if (_shouldDeploy(DeploymentAddresses.KEY_KYC_REGISTRY)) {
            KYCRegistry kyc = new KYCRegistry(admin);
            _setAddress(DeploymentAddresses.KEY_KYC_REGISTRY, address(kyc));
            console.log("KYCRegistry:", address(kyc));
        } else {
            console.log("KYCRegistry: SKIPPED");
        }

        if (_shouldDeploy(DeploymentAddresses.KEY_AUDIT_LOGGER)) {
            AuditLogger logger = new AuditLogger(admin, 365 days);
            _setAddress(DeploymentAddresses.KEY_AUDIT_LOGGER, address(logger));
            console.log("AuditLogger:", address(logger));
        } else {
            console.log("AuditLogger: SKIPPED");
        }

        if (_shouldDeploy(DeploymentAddresses.KEY_PROOF_OF_RESERVE)) {
            ProofOfReserve por = new ProofOfReserve(admin, 3);
            _setAddress(DeploymentAddresses.KEY_PROOF_OF_RESERVE, address(por));
            console.log("ProofOfReserve:", address(por));
        } else {
            console.log("ProofOfReserve: SKIPPED");
        }

        // Subscription (base)
        if (_shouldDeploy(DeploymentAddresses.KEY_PERMISSION_MANAGER)) {
            ERC7715PermissionManager pm = new ERC7715PermissionManager();
            _setAddress(DeploymentAddresses.KEY_PERMISSION_MANAGER, address(pm));
            console.log("ERC7715PermissionManager:", address(pm));
        } else {
            console.log("ERC7715PermissionManager: SKIPPED");
        }

        console.log("");
    }

    // ============================================================
    // Layer 1: Contracts Depending on Layer 0
    // ============================================================
    function _deployLayer1() internal {
        console.log("--- Layer 1: Dependent Contracts ---");

        // Kernel (depends on EntryPoint)
        if (_shouldDeploy(DeploymentAddresses.KEY_KERNEL)) {
            address entryPoint = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
            require(entryPoint != address(0), "EntryPoint must be deployed first");

            Kernel kernel = new Kernel(IEntryPointKernel(entryPoint));
            _setAddress(DeploymentAddresses.KEY_KERNEL, address(kernel));
            console.log("Kernel:", address(kernel));
        } else {
            console.log("Kernel: SKIPPED");
        }

        // VerifyingPaymaster (depends on EntryPoint)
        if (_shouldDeploy(DeploymentAddresses.KEY_VERIFYING_PAYMASTER)) {
            address entryPoint = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
            require(entryPoint != address(0), "EntryPoint must be deployed first");

            address verifyingSigner = vm.envOr("VERIFYING_SIGNER", admin);
            VerifyingPaymaster paymaster = new VerifyingPaymaster(
                IEntryPointPaymaster(entryPoint),
                admin,
                verifyingSigner
            );
            _setAddress(DeploymentAddresses.KEY_VERIFYING_PAYMASTER, address(paymaster));
            console.log("VerifyingPaymaster:", address(paymaster));
        } else {
            console.log("VerifyingPaymaster: SKIPPED");
        }

        // ERC20Paymaster (depends on EntryPoint and PriceOracle)
        if (_shouldDeploy(DeploymentAddresses.KEY_ERC20_PAYMASTER)) {
            address entryPoint = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
            address priceOracle = _getAddress(DeploymentAddresses.KEY_PRICE_ORACLE);

            if (entryPoint != address(0) && priceOracle != address(0)) {
                ERC20Paymaster paymaster = new ERC20Paymaster(
                    IEntryPointPaymaster(entryPoint),
                    admin,
                    IPriceOracle(priceOracle),
                    1000 // 10% markup
                );
                _setAddress(DeploymentAddresses.KEY_ERC20_PAYMASTER, address(paymaster));
                console.log("ERC20Paymaster:", address(paymaster));
            } else {
                console.log("ERC20Paymaster: SKIPPED (missing dependencies)");
            }
        } else {
            console.log("ERC20Paymaster: SKIPPED");
        }

        // PrivateBank (depends on Announcer and Registry)
        if (_shouldDeploy(DeploymentAddresses.KEY_PRIVATE_BANK)) {
            address announcer = _getAddress(DeploymentAddresses.KEY_ANNOUNCER);
            address registry = _getAddress(DeploymentAddresses.KEY_REGISTRY);

            if (announcer != address(0) && registry != address(0)) {
                PrivateBank bank = new PrivateBank(announcer, registry);
                _setAddress(DeploymentAddresses.KEY_PRIVATE_BANK, address(bank));
                console.log("PrivateBank:", address(bank));
            } else {
                console.log("PrivateBank: SKIPPED (missing dependencies)");
            }
        } else {
            console.log("PrivateBank: SKIPPED");
        }

        console.log("");
    }

    // ============================================================
    // Layer 2: Contracts Depending on Layer 1
    // ============================================================
    function _deployLayer2() internal {
        console.log("--- Layer 2: Higher-Level Contracts ---");

        // KernelFactory (depends on Kernel)
        if (_shouldDeploy(DeploymentAddresses.KEY_KERNEL_FACTORY)) {
            address kernel = _getAddress(DeploymentAddresses.KEY_KERNEL);
            require(kernel != address(0), "Kernel must be deployed first");

            KernelFactory factory = new KernelFactory(kernel);
            _setAddress(DeploymentAddresses.KEY_KERNEL_FACTORY, address(factory));
            console.log("KernelFactory:", address(factory));
        } else {
            console.log("KernelFactory: SKIPPED");
        }

        // SubscriptionManager (depends on PermissionManager)
        if (_shouldDeploy(DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER)) {
            address pm = _getAddress(DeploymentAddresses.KEY_PERMISSION_MANAGER);
            require(pm != address(0), "ERC7715PermissionManager must be deployed first");

            SubscriptionManager sm = new SubscriptionManager(pm);
            _setAddress(DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER, address(sm));
            console.log("SubscriptionManager:", address(sm));
        } else {
            console.log("SubscriptionManager: SKIPPED");
        }

        console.log("");
    }

    function _printSummary() internal view {
        console.log("");
        console.log("================================================================");
        console.log("              DEPLOYMENT SUMMARY                                ");
        console.log("================================================================");
        console.log("");

        console.log("--- CORE ---");
        _logDeployed(DeploymentAddresses.KEY_ENTRYPOINT, "EntryPoint");
        _logDeployed(DeploymentAddresses.KEY_KERNEL, "Kernel");
        _logDeployed(DeploymentAddresses.KEY_KERNEL_FACTORY, "KernelFactory");

        console.log("");
        console.log("--- VALIDATORS ---");
        _logDeployed(DeploymentAddresses.KEY_ECDSA_VALIDATOR, "ECDSAValidator");
        _logDeployed(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR, "WeightedECDSAValidator");
        _logDeployed(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR, "MultiChainValidator");

        console.log("");
        console.log("--- PAYMASTERS ---");
        _logDeployed(DeploymentAddresses.KEY_VERIFYING_PAYMASTER, "VerifyingPaymaster");
        _logDeployed(DeploymentAddresses.KEY_ERC20_PAYMASTER, "ERC20Paymaster");

        console.log("");
        console.log("--- EXECUTORS ---");
        _logDeployed(DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR, "SessionKeyExecutor");
        _logDeployed(DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR, "RecurringPaymentExecutor");

        console.log("");
        console.log("--- HOOKS ---");
        _logDeployed(DeploymentAddresses.KEY_AUDIT_HOOK, "AuditHook");
        _logDeployed(DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK, "SpendingLimitHook");

        console.log("");
        console.log("--- FALLBACKS ---");
        _logDeployed(DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK, "TokenReceiverFallback");
        _logDeployed(DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK, "FlashLoanFallback");

        console.log("");
        console.log("--- TOKENS & DEFI ---");
        _logDeployed(DeploymentAddresses.KEY_WKRW, "WKRW");
        _logDeployed(DeploymentAddresses.KEY_PRICE_ORACLE, "PriceOracle");

        console.log("");
        console.log("--- PRIVACY ---");
        _logDeployed(DeploymentAddresses.KEY_ANNOUNCER, "ERC5564Announcer");
        _logDeployed(DeploymentAddresses.KEY_REGISTRY, "ERC6538Registry");
        _logDeployed(DeploymentAddresses.KEY_PRIVATE_BANK, "PrivateBank");

        console.log("");
        console.log("--- COMPLIANCE ---");
        _logDeployed(DeploymentAddresses.KEY_KYC_REGISTRY, "KYCRegistry");
        _logDeployed(DeploymentAddresses.KEY_AUDIT_LOGGER, "AuditLogger");
        _logDeployed(DeploymentAddresses.KEY_PROOF_OF_RESERVE, "ProofOfReserve");

        console.log("");
        console.log("--- SUBSCRIPTION ---");
        _logDeployed(DeploymentAddresses.KEY_PERMISSION_MANAGER, "ERC7715PermissionManager");
        _logDeployed(DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER, "SubscriptionManager");

        console.log("");
        console.log("================================================================");
        console.log("Deployment file:", _getDeploymentPath());
        console.log("================================================================");
    }

    function _logDeployed(string memory key, string memory name) internal view {
        address addr = _getAddress(key);
        if (addr != address(0)) {
            console.log(string.concat("  ", name, ": ", vm.toString(addr)));
        } else {
            console.log(string.concat("  ", name, ": NOT DEPLOYED"));
        }
    }
}

/**
 * @title DeployLayer0Script
 * @notice Deploy only Layer 0 (independent) contracts
 */
contract DeployLayer0Script is DeploymentHelper {
    function run() public {
        _initDeployment();
        vm.startBroadcast();

        // Deploy all Layer 0 contracts
        _setAddress(DeploymentAddresses.KEY_ENTRYPOINT, address(new EntryPoint()));
        _setAddress(DeploymentAddresses.KEY_ECDSA_VALIDATOR, address(new ECDSAValidator()));
        _setAddress(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR, address(new WeightedECDSAValidator()));
        _setAddress(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR, address(new MultiChainValidator()));
        _setAddress(DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR, address(new SessionKeyExecutor()));
        _setAddress(DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR, address(new RecurringPaymentExecutor()));
        _setAddress(DeploymentAddresses.KEY_AUDIT_HOOK, address(new AuditHook()));
        _setAddress(DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK, address(new SpendingLimitHook()));
        _setAddress(DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK, address(new TokenReceiverFallback()));
        _setAddress(DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK, address(new FlashLoanFallback()));
        _setAddress(DeploymentAddresses.KEY_WKRW, address(new WKRW()));
        _setAddress(DeploymentAddresses.KEY_PRICE_ORACLE, address(new PriceOracle()));
        _setAddress(DeploymentAddresses.KEY_ANNOUNCER, address(new ERC5564Announcer()));
        _setAddress(DeploymentAddresses.KEY_REGISTRY, address(new ERC6538Registry()));

        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        _setAddress(DeploymentAddresses.KEY_KYC_REGISTRY, address(new KYCRegistry(admin)));
        _setAddress(DeploymentAddresses.KEY_AUDIT_LOGGER, address(new AuditLogger(admin, 365 days)));
        _setAddress(DeploymentAddresses.KEY_PROOF_OF_RESERVE, address(new ProofOfReserve(admin, 3)));
        _setAddress(DeploymentAddresses.KEY_PERMISSION_MANAGER, address(new ERC7715PermissionManager()));

        vm.stopBroadcast();
        _saveAddresses();

        console.log("Layer 0 deployment complete. Addresses saved to:", _getDeploymentPath());
    }
}

/**
 * @title DeployLayer1Script
 * @notice Deploy Layer 1 contracts (requires Layer 0)
 */
contract DeployLayer1Script is DeploymentHelper {
    function run() public {
        _initDeployment();

        // Verify Layer 0 dependencies
        _requireDependency(DeploymentAddresses.KEY_ENTRYPOINT, "EntryPoint");
        _requireDependency(DeploymentAddresses.KEY_PRICE_ORACLE, "PriceOracle");
        _requireDependency(DeploymentAddresses.KEY_ANNOUNCER, "ERC5564Announcer");
        _requireDependency(DeploymentAddresses.KEY_REGISTRY, "ERC6538Registry");

        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        address verifyingSigner = vm.envOr("VERIFYING_SIGNER", admin);
        address entryPoint = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
        address priceOracle = _getAddress(DeploymentAddresses.KEY_PRICE_ORACLE);
        address announcer = _getAddress(DeploymentAddresses.KEY_ANNOUNCER);
        address registry = _getAddress(DeploymentAddresses.KEY_REGISTRY);

        vm.startBroadcast();

        // Kernel
        Kernel kernel = new Kernel(IEntryPointKernel(entryPoint));
        _setAddress(DeploymentAddresses.KEY_KERNEL, address(kernel));
        console.log("Kernel:", address(kernel));

        // Paymasters
        VerifyingPaymaster vp = new VerifyingPaymaster(
            IEntryPointPaymaster(entryPoint),
            admin,
            verifyingSigner
        );
        _setAddress(DeploymentAddresses.KEY_VERIFYING_PAYMASTER, address(vp));
        console.log("VerifyingPaymaster:", address(vp));

        ERC20Paymaster ep = new ERC20Paymaster(
            IEntryPointPaymaster(entryPoint),
            admin,
            IPriceOracle(priceOracle),
            1000
        );
        _setAddress(DeploymentAddresses.KEY_ERC20_PAYMASTER, address(ep));
        console.log("ERC20Paymaster:", address(ep));

        // PrivateBank
        PrivateBank bank = new PrivateBank(announcer, registry);
        _setAddress(DeploymentAddresses.KEY_PRIVATE_BANK, address(bank));
        console.log("PrivateBank:", address(bank));

        vm.stopBroadcast();
        _saveAddresses();

        console.log("Layer 1 deployment complete. Addresses saved to:", _getDeploymentPath());
    }
}

/**
 * @title DeployLayer2Script
 * @notice Deploy Layer 2 contracts (requires Layer 1)
 */
contract DeployLayer2Script is DeploymentHelper {
    function run() public {
        _initDeployment();

        // Verify Layer 1 dependencies
        _requireDependency(DeploymentAddresses.KEY_KERNEL, "Kernel");
        _requireDependency(DeploymentAddresses.KEY_PERMISSION_MANAGER, "ERC7715PermissionManager");

        address kernel = _getAddress(DeploymentAddresses.KEY_KERNEL);
        address pm = _getAddress(DeploymentAddresses.KEY_PERMISSION_MANAGER);

        vm.startBroadcast();

        // KernelFactory
        KernelFactory factory = new KernelFactory(kernel);
        _setAddress(DeploymentAddresses.KEY_KERNEL_FACTORY, address(factory));
        console.log("KernelFactory:", address(factory));

        // SubscriptionManager
        SubscriptionManager sm = new SubscriptionManager(pm);
        _setAddress(DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER, address(sm));
        console.log("SubscriptionManager:", address(sm));

        vm.stopBroadcast();
        _saveAddresses();

        console.log("Layer 2 deployment complete. Addresses saved to:", _getDeploymentPath());
    }
}
