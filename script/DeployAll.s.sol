// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "./utils/DeploymentAddresses.sol";

// ============ Tokens ============
import { wKRC } from "../src/tokens/wKRC.sol";
import { USDC } from "../src/tokens/USDC.sol";

// ============ ERC-4337 EntryPoint ============
import { EntryPoint } from "../src/erc4337-entrypoint/EntryPoint.sol";
import { IEntryPoint } from "../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";

// ============ ERC-4337 Paymasters ============
import { VerifyingPaymaster } from "../src/erc4337-paymaster/VerifyingPaymaster.sol";
import { SponsorPaymaster } from "../src/erc4337-paymaster/SponsorPaymaster.sol";
import { ERC20Paymaster } from "../src/erc4337-paymaster/ERC20Paymaster.sol";
import { Permit2Paymaster } from "../src/erc4337-paymaster/Permit2Paymaster.sol";
import { IPriceOracle } from "../src/erc4337-paymaster/interfaces/IPriceOracle.sol";
import { IPermit2 } from "../src/permit2/interfaces/IPermit2.sol";

// ============ ERC-7579 Smart Account ============
import { IEntryPoint as IKernelEntryPoint } from "../src/erc7579-smartaccount/interfaces/IEntryPoint.sol";
import { Kernel } from "../src/erc7579-smartaccount/Kernel.sol";
import { KernelFactory } from "../src/erc7579-smartaccount/factory/KernelFactory.sol";
import { FactoryStaker } from "../src/erc7579-smartaccount/factory/FactoryStaker.sol";

// ============ ERC-7579 Validators ============
import { ECDSAValidator } from "../src/erc7579-validators/ECDSAValidator.sol";
import { WeightedECDSAValidator } from "../src/erc7579-validators/WeightedECDSAValidator.sol";
import { MultiChainValidator } from "../src/erc7579-validators/MultiChainValidator.sol";
import { MultiSigValidator } from "../src/erc7579-validators/MultiSigValidator.sol";
import { WebAuthnValidator } from "../src/erc7579-validators/WebAuthnValidator.sol";

// ============ ERC-7579 Hooks ============
import { AuditHook } from "../src/erc7579-hooks/AuditHook.sol";
import { SpendingLimitHook } from "../src/erc7579-hooks/SpendingLimitHook.sol";

// ============ ERC-7579 Fallbacks ============
import { TokenReceiverFallback } from "../src/erc7579-fallbacks/TokenReceiverFallback.sol";
import { FlashLoanFallback } from "../src/erc7579-fallbacks/FlashLoanFallback.sol";

// ============ ERC-7579 Executors ============
import { SessionKeyExecutor } from "../src/erc7579-executors/SessionKeyExecutor.sol";
import { RecurringPaymentExecutor } from "../src/erc7579-executors/RecurringPaymentExecutor.sol";

// ============ ERC-7579 Plugins ============
import { AutoSwapPlugin } from "../src/erc7579-plugins/AutoSwapPlugin.sol";
import { MicroLoanPlugin } from "../src/erc7579-plugins/MicroLoanPlugin.sol";
import { OnRampPlugin } from "../src/erc7579-plugins/OnRampPlugin.sol";

// ============ Compliance ============
import { KYCRegistry } from "../src/compliance/KYCRegistry.sol";
import { AuditLogger } from "../src/compliance/AuditLogger.sol";
import { ProofOfReserve } from "../src/compliance/ProofOfReserve.sol";
import { RegulatoryRegistry } from "../src/compliance/RegulatoryRegistry.sol";

// ============ Privacy ============
import { ERC5564Announcer } from "../src/privacy/ERC5564Announcer.sol";
import { ERC6538Registry } from "../src/privacy/ERC6538Registry.sol";
import { PrivateBank } from "../src/privacy/PrivateBank.sol";

// ============ Permit2 ============
import { Permit2 } from "../src/permit2/Permit2.sol";

// ============ DeFi ============
import { PriceOracle } from "../src/defi/PriceOracle.sol";
import { DEXIntegration } from "../src/defi/DEXIntegration.sol";

// ============ Subscription ============
import { ERC7715PermissionManager } from "../src/subscription/ERC7715PermissionManager.sol";
import { SubscriptionManager } from "../src/subscription/SubscriptionManager.sol";

// ============ Bridge ============
import { FraudProofVerifier } from "../src/bridge/FraudProofVerifier.sol";
import { BridgeRateLimiter } from "../src/bridge/BridgeRateLimiter.sol";
import { BridgeValidator } from "../src/bridge/BridgeValidator.sol";
import { BridgeGuardian } from "../src/bridge/BridgeGuardian.sol";
import { OptimisticVerifier } from "../src/bridge/OptimisticVerifier.sol";
import { SecureBridge } from "../src/bridge/SecureBridge.sol";

/**
 * @title DeployAllScript
 * @notice Unified deployment script for all StableNet contracts
 * @dev Deploys all contracts in correct dependency order with address caching
 *
 * Deployment Order (based on dependencies):
 *   Phase 0 - Base Infrastructure:
 *     1. Tokens (wKRC, USDC) - No dependencies
 *     2. EntryPoint - No dependencies
 *
 *   Phase 1 - Core Smart Account:
 *     3. Kernel - Depends on EntryPoint
 *     4. KernelFactory - Depends on Kernel
 *
 *   Phase 2 - ERC-7579 Modules (no external dependencies):
 *     5. Validators (ECDSA, Weighted, MultiChain, MultiSig, WebAuthn)
 *     6. Hooks (Audit, SpendingLimit)
 *     7. Fallbacks (TokenReceiver, FlashLoan)
 *     8. Executors (SessionKey, RecurringPayment)
 *
 *   Phase 3 - Feature Modules:
 *     9. Compliance (KYCRegistry, AuditLogger, ProofOfReserve, RegulatoryRegistry)
 *     10. Privacy (ERC5564Announcer, ERC6538Registry, PrivateBank)
 *     11. Permit2
 *
 *   Phase 4 - DeFi & Paymasters:
 *     12. DeFi (PriceOracle, DEXIntegration)
 *     13. Paymasters (Verifying, Sponsor, ERC20, Permit2)
 *
 *   Phase 5 - Plugins:
 *     14. Plugins (AutoSwap, MicroLoan, OnRamp)
 *
 *   Phase 6 - Subscription & Bridge:
 *     15. Subscription (PermissionManager, SubscriptionManager)
 *     16. Bridge (all bridge contracts)
 *
 * Environment Variables:
 *   - ADMIN_ADDRESS: Admin/owner address (default: deployer)
 *   - VERIFYING_SIGNER: Signer for VerifyingPaymaster (default: admin)
 *   - SWAP_ROUTER: Uniswap V3 SwapRouter (optional, for DEXIntegration)
 *   - QUOTER: Uniswap V3 Quoter (optional)
 *
 * Usage:
 *   forge script script/DeployAll.s.sol:DeployAllScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployAllScript is DeploymentHelper {
    // Configuration
    address public admin;
    address public verifyingSigner;

    // Default constants
    uint256 constant DEFAULT_RETENTION_PERIOD = 365 days;
    uint256 constant DEFAULT_AUTO_PAUSE_THRESHOLD = 3;
    uint256 constant DEFAULT_MARKUP = 1000; // 10%
    uint256 constant DEFAULT_CHALLENGE_PERIOD = 6 hours;
    uint256 constant DEFAULT_CHALLENGE_BOND = 0.1 ether;
    uint256 constant DEFAULT_CHALLENGER_REWARD = 0.05 ether;

    function setUp() public { }

    function run() public {
        _initDeployment();

        admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        verifyingSigner = vm.envOr("VERIFYING_SIGNER", admin);

        console.log("========================================");
        console.log("  StableNet Full Deployment");
        console.log("========================================");
        console.log("Chain ID:", chainId);
        console.log("Admin:", admin);
        console.log("Verifying Signer:", verifyingSigner);
        console.log("");

        vm.startBroadcast();

        // ========================================
        // Phase 0: Base Infrastructure
        // ========================================
        _deployPhase0_BaseInfrastructure();

        // ========================================
        // Phase 1: Core Smart Account
        // ========================================
        _deployPhase1_CoreSmartAccount();

        // ========================================
        // Phase 2: ERC-7579 Modules
        // ========================================
        _deployPhase2_ERC7579Modules();

        // ========================================
        // Phase 3: Feature Modules
        // ========================================
        _deployPhase3_FeatureModules();

        // ========================================
        // Phase 4: DeFi & Paymasters
        // ========================================
        _deployPhase4_DeFiAndPaymasters();

        // ========================================
        // Phase 5: Plugins
        // ========================================
        _deployPhase5_Plugins();

        // ========================================
        // Phase 6: Subscription & Bridge
        // ========================================
        _deployPhase6_SubscriptionAndBridge();

        vm.stopBroadcast();

        _saveAddresses();

        _printDeploymentSummary();
    }

    // ============================================================
    // Phase 0: Base Infrastructure (Tokens, EntryPoint)
    // ============================================================
    function _deployPhase0_BaseInfrastructure() internal {
        console.log(">>> Phase 0: Base Infrastructure");

        // 1. wKRC (Wrapped Native Token)
        if (_getAddress(DeploymentAddresses.KEY_WKRC) == address(0)) {
            wKRC wkrc = new wKRC();
            _setAddress(DeploymentAddresses.KEY_WKRC, address(wkrc));
            console.log("  [NEW] wKRC:", address(wkrc));
        } else {
            console.log("  [SKIP] wKRC:", _getAddress(DeploymentAddresses.KEY_WKRC));
        }

        // 2. USDC (Stablecoin)
        if (_getAddress(DeploymentAddresses.KEY_USDC) == address(0)) {
            USDC usdc = new USDC(admin);
            _setAddress(DeploymentAddresses.KEY_USDC, address(usdc));
            // Initial mint: 1,000,000 USDC
            usdc.mint(admin, 1_000_000 * 10 ** 6);
            console.log("  [NEW] USDC:", address(usdc));
        } else {
            console.log("  [SKIP] USDC:", _getAddress(DeploymentAddresses.KEY_USDC));
        }

        // 3. EntryPoint (ERC-4337)
        if (_getAddress(DeploymentAddresses.KEY_ENTRYPOINT) == address(0)) {
            EntryPoint entryPoint = new EntryPoint();
            _setAddress(DeploymentAddresses.KEY_ENTRYPOINT, address(entryPoint));
            console.log("  [NEW] EntryPoint:", address(entryPoint));
        } else {
            console.log("  [SKIP] EntryPoint:", _getAddress(DeploymentAddresses.KEY_ENTRYPOINT));
        }

        console.log("");
    }

    // ============================================================
    // Phase 1: Core Smart Account (Kernel, Factory)
    // ============================================================
    function _deployPhase1_CoreSmartAccount() internal {
        console.log(">>> Phase 1: Core Smart Account");

        address entryPointAddr = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
        require(entryPointAddr != address(0), "EntryPoint must be deployed first");

        // 1. Kernel Implementation
        if (_getAddress(DeploymentAddresses.KEY_KERNEL) == address(0)) {
            Kernel kernel = new Kernel(IKernelEntryPoint(entryPointAddr));
            _setAddress(DeploymentAddresses.KEY_KERNEL, address(kernel));
            console.log("  [NEW] Kernel:", address(kernel));
        } else {
            console.log("  [SKIP] Kernel:", _getAddress(DeploymentAddresses.KEY_KERNEL));
        }

        // 2. KernelFactory (depends on Kernel)
        address kernelAddr = _getAddress(DeploymentAddresses.KEY_KERNEL);
        if (_getAddress(DeploymentAddresses.KEY_KERNEL_FACTORY) == address(0)) {
            KernelFactory factory = new KernelFactory(kernelAddr);
            _setAddress(DeploymentAddresses.KEY_KERNEL_FACTORY, address(factory));
            console.log("  [NEW] KernelFactory:", address(factory));
        } else {
            console.log("  [SKIP] KernelFactory:", _getAddress(DeploymentAddresses.KEY_KERNEL_FACTORY));
        }

        // 3. FactoryStaker
        if (_getAddress(DeploymentAddresses.KEY_FACTORY_STAKER) == address(0)) {
            FactoryStaker staker = new FactoryStaker(admin);
            _setAddress(DeploymentAddresses.KEY_FACTORY_STAKER, address(staker));
            console.log("  [NEW] FactoryStaker:", address(staker));
        } else {
            console.log("  [SKIP] FactoryStaker:", _getAddress(DeploymentAddresses.KEY_FACTORY_STAKER));
        }

        console.log("");
    }

    // ============================================================
    // Phase 2: ERC-7579 Modules (Validators, Hooks, Fallbacks, Executors)
    // ============================================================
    function _deployPhase2_ERC7579Modules() internal {
        console.log(">>> Phase 2: ERC-7579 Modules");

        // --- Validators ---
        console.log("  --- Validators ---");

        if (_getAddress(DeploymentAddresses.KEY_ECDSA_VALIDATOR) == address(0)) {
            ECDSAValidator validator = new ECDSAValidator();
            _setAddress(DeploymentAddresses.KEY_ECDSA_VALIDATOR, address(validator));
            console.log("    [NEW] ECDSAValidator:", address(validator));
        } else {
            console.log("    [SKIP] ECDSAValidator:", _getAddress(DeploymentAddresses.KEY_ECDSA_VALIDATOR));
        }

        if (_getAddress(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR) == address(0)) {
            WeightedECDSAValidator weighted = new WeightedECDSAValidator();
            _setAddress(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR, address(weighted));
            console.log("    [NEW] WeightedECDSAValidator:", address(weighted));
        } else {
            console.log("    [SKIP] WeightedECDSAValidator:", _getAddress(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR));
        }

        if (_getAddress(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR) == address(0)) {
            MultiChainValidator multichain = new MultiChainValidator();
            _setAddress(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR, address(multichain));
            console.log("    [NEW] MultiChainValidator:", address(multichain));
        } else {
            console.log("    [SKIP] MultiChainValidator:", _getAddress(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR));
        }

        if (_getAddress(DeploymentAddresses.KEY_MULTISIG_VALIDATOR) == address(0)) {
            MultiSigValidator multisig = new MultiSigValidator();
            _setAddress(DeploymentAddresses.KEY_MULTISIG_VALIDATOR, address(multisig));
            console.log("    [NEW] MultiSigValidator:", address(multisig));
        } else {
            console.log("    [SKIP] MultiSigValidator:", _getAddress(DeploymentAddresses.KEY_MULTISIG_VALIDATOR));
        }

        if (_getAddress(DeploymentAddresses.KEY_WEBAUTHN_VALIDATOR) == address(0)) {
            WebAuthnValidator webauthn = new WebAuthnValidator();
            _setAddress(DeploymentAddresses.KEY_WEBAUTHN_VALIDATOR, address(webauthn));
            console.log("    [NEW] WebAuthnValidator:", address(webauthn));
        } else {
            console.log("    [SKIP] WebAuthnValidator:", _getAddress(DeploymentAddresses.KEY_WEBAUTHN_VALIDATOR));
        }

        // --- Hooks ---
        console.log("  --- Hooks ---");

        if (_getAddress(DeploymentAddresses.KEY_AUDIT_HOOK) == address(0)) {
            AuditHook auditHook = new AuditHook();
            _setAddress(DeploymentAddresses.KEY_AUDIT_HOOK, address(auditHook));
            console.log("    [NEW] AuditHook:", address(auditHook));
        } else {
            console.log("    [SKIP] AuditHook:", _getAddress(DeploymentAddresses.KEY_AUDIT_HOOK));
        }

        if (_getAddress(DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK) == address(0)) {
            SpendingLimitHook spendingHook = new SpendingLimitHook();
            _setAddress(DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK, address(spendingHook));
            console.log("    [NEW] SpendingLimitHook:", address(spendingHook));
        } else {
            console.log("    [SKIP] SpendingLimitHook:", _getAddress(DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK));
        }

        // --- Fallbacks ---
        console.log("  --- Fallbacks ---");

        if (_getAddress(DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK) == address(0)) {
            TokenReceiverFallback tokenReceiver = new TokenReceiverFallback();
            _setAddress(DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK, address(tokenReceiver));
            console.log("    [NEW] TokenReceiverFallback:", address(tokenReceiver));
        } else {
            console.log(
                "    [SKIP] TokenReceiverFallback:", _getAddress(DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK)
            );
        }

        if (_getAddress(DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK) == address(0)) {
            FlashLoanFallback flashLoan = new FlashLoanFallback();
            _setAddress(DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK, address(flashLoan));
            console.log("    [NEW] FlashLoanFallback:", address(flashLoan));
        } else {
            console.log("    [SKIP] FlashLoanFallback:", _getAddress(DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK));
        }

        // --- Executors ---
        console.log("  --- Executors ---");

        if (_getAddress(DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR) == address(0)) {
            SessionKeyExecutor sessionKey = new SessionKeyExecutor();
            _setAddress(DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR, address(sessionKey));
            console.log("    [NEW] SessionKeyExecutor:", address(sessionKey));
        } else {
            console.log("    [SKIP] SessionKeyExecutor:", _getAddress(DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR));
        }

        if (_getAddress(DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR) == address(0)) {
            RecurringPaymentExecutor recurring = new RecurringPaymentExecutor();
            _setAddress(DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR, address(recurring));
            console.log("    [NEW] RecurringPaymentExecutor:", address(recurring));
        } else {
            console.log(
                "    [SKIP] RecurringPaymentExecutor:", _getAddress(DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR)
            );
        }

        console.log("");
    }

    // ============================================================
    // Phase 3: Feature Modules (Compliance, Privacy, Permit2)
    // ============================================================
    function _deployPhase3_FeatureModules() internal {
        console.log(">>> Phase 3: Feature Modules");

        // --- Compliance ---
        console.log("  --- Compliance ---");

        if (_getAddress(DeploymentAddresses.KEY_KYC_REGISTRY) == address(0)) {
            KYCRegistry kyc = new KYCRegistry(admin);
            _setAddress(DeploymentAddresses.KEY_KYC_REGISTRY, address(kyc));
            console.log("    [NEW] KYCRegistry:", address(kyc));
        } else {
            console.log("    [SKIP] KYCRegistry:", _getAddress(DeploymentAddresses.KEY_KYC_REGISTRY));
        }

        if (_getAddress(DeploymentAddresses.KEY_AUDIT_LOGGER) == address(0)) {
            AuditLogger auditLogger = new AuditLogger(admin, DEFAULT_RETENTION_PERIOD);
            _setAddress(DeploymentAddresses.KEY_AUDIT_LOGGER, address(auditLogger));
            console.log("    [NEW] AuditLogger:", address(auditLogger));
        } else {
            console.log("    [SKIP] AuditLogger:", _getAddress(DeploymentAddresses.KEY_AUDIT_LOGGER));
        }

        if (_getAddress(DeploymentAddresses.KEY_PROOF_OF_RESERVE) == address(0)) {
            ProofOfReserve por = new ProofOfReserve(admin, DEFAULT_AUTO_PAUSE_THRESHOLD);
            _setAddress(DeploymentAddresses.KEY_PROOF_OF_RESERVE, address(por));
            console.log("    [NEW] ProofOfReserve:", address(por));
        } else {
            console.log("    [SKIP] ProofOfReserve:", _getAddress(DeploymentAddresses.KEY_PROOF_OF_RESERVE));
        }

        if (_getAddress(DeploymentAddresses.KEY_REGULATORY_REGISTRY) == address(0)) {
            // RegulatoryRegistry requires exactly 3 approvers (MAX_APPROVERS = 3)
            address[] memory approvers = new address[](3);
            approvers[0] = admin;
            approvers[1] = address(uint160(uint256(keccak256(abi.encodePacked("approver1", admin)))));
            approvers[2] = address(uint160(uint256(keccak256(abi.encodePacked("approver2", admin)))));

            RegulatoryRegistry regulatory = new RegulatoryRegistry(approvers);
            _setAddress(DeploymentAddresses.KEY_REGULATORY_REGISTRY, address(regulatory));
            console.log("    [NEW] RegulatoryRegistry:", address(regulatory));
        } else {
            console.log("    [SKIP] RegulatoryRegistry:", _getAddress(DeploymentAddresses.KEY_REGULATORY_REGISTRY));
        }

        // --- Privacy ---
        console.log("  --- Privacy ---");

        if (_getAddress(DeploymentAddresses.KEY_ANNOUNCER) == address(0)) {
            ERC5564Announcer announcer = new ERC5564Announcer();
            _setAddress(DeploymentAddresses.KEY_ANNOUNCER, address(announcer));
            console.log("    [NEW] ERC5564Announcer:", address(announcer));
        } else {
            console.log("    [SKIP] ERC5564Announcer:", _getAddress(DeploymentAddresses.KEY_ANNOUNCER));
        }

        if (_getAddress(DeploymentAddresses.KEY_REGISTRY) == address(0)) {
            ERC6538Registry registry = new ERC6538Registry();
            _setAddress(DeploymentAddresses.KEY_REGISTRY, address(registry));
            console.log("    [NEW] ERC6538Registry:", address(registry));
        } else {
            console.log("    [SKIP] ERC6538Registry:", _getAddress(DeploymentAddresses.KEY_REGISTRY));
        }

        // PrivateBank (depends on Announcer and Registry)
        address announcerAddr = _getAddress(DeploymentAddresses.KEY_ANNOUNCER);
        address registryAddr = _getAddress(DeploymentAddresses.KEY_REGISTRY);
        if (_getAddress(DeploymentAddresses.KEY_PRIVATE_BANK) == address(0)) {
            if (announcerAddr != address(0) && registryAddr != address(0)) {
                PrivateBank privateBank = new PrivateBank(announcerAddr, registryAddr);
                _setAddress(DeploymentAddresses.KEY_PRIVATE_BANK, address(privateBank));
                console.log("    [NEW] PrivateBank:", address(privateBank));
            } else {
                console.log("    [SKIP] PrivateBank: Missing dependencies");
            }
        } else {
            console.log("    [SKIP] PrivateBank:", _getAddress(DeploymentAddresses.KEY_PRIVATE_BANK));
        }

        // --- Permit2 ---
        console.log("  --- Permit2 ---");

        if (_getAddress(DeploymentAddresses.KEY_PERMIT2) == address(0)) {
            Permit2 permit2 = new Permit2();
            _setAddress(DeploymentAddresses.KEY_PERMIT2, address(permit2));
            console.log("    [NEW] Permit2:", address(permit2));
        } else {
            console.log("    [SKIP] Permit2:", _getAddress(DeploymentAddresses.KEY_PERMIT2));
        }

        console.log("");
    }

    // ============================================================
    // Phase 4: DeFi & Paymasters
    // ============================================================
    function _deployPhase4_DeFiAndPaymasters() internal {
        console.log(">>> Phase 4: DeFi & Paymasters");

        // --- DeFi ---
        console.log("  --- DeFi ---");

        // PriceOracle (no dependencies)
        if (_getAddress(DeploymentAddresses.KEY_PRICE_ORACLE) == address(0)) {
            PriceOracle priceOracle = new PriceOracle();
            _setAddress(DeploymentAddresses.KEY_PRICE_ORACLE, address(priceOracle));
            console.log("    [NEW] PriceOracle:", address(priceOracle));
        } else {
            console.log("    [SKIP] PriceOracle:", _getAddress(DeploymentAddresses.KEY_PRICE_ORACLE));
        }

        // DEXIntegration (depends on wKRC and optional external DEX)
        address wkrcAddr = _getAddress(DeploymentAddresses.KEY_WKRC);
        address swapRouter = vm.envOr("SWAP_ROUTER", address(0));
        address quoter = vm.envOr("QUOTER", address(0));

        if (_getAddress(DeploymentAddresses.KEY_DEX_INTEGRATION) == address(0)) {
            if (swapRouter != address(0) && wkrcAddr != address(0)) {
                DEXIntegration dex = new DEXIntegration(swapRouter, quoter, wkrcAddr);
                _setAddress(DeploymentAddresses.KEY_DEX_INTEGRATION, address(dex));
                console.log("    [NEW] DEXIntegration:", address(dex));
            } else {
                console.log("    [SKIP] DEXIntegration: Missing SWAP_ROUTER or wKRC");
            }
        } else {
            console.log("    [SKIP] DEXIntegration:", _getAddress(DeploymentAddresses.KEY_DEX_INTEGRATION));
        }

        // --- Paymasters ---
        console.log("  --- Paymasters ---");

        address entryPointAddr = _getAddress(DeploymentAddresses.KEY_ENTRYPOINT);
        address priceOracleAddr = _getAddress(DeploymentAddresses.KEY_PRICE_ORACLE);
        address permit2Addr = _getAddress(DeploymentAddresses.KEY_PERMIT2);

        // VerifyingPaymaster (depends on EntryPoint)
        if (_getAddress(DeploymentAddresses.KEY_VERIFYING_PAYMASTER) == address(0)) {
            VerifyingPaymaster verifying = new VerifyingPaymaster(IEntryPoint(entryPointAddr), admin, verifyingSigner);
            _setAddress(DeploymentAddresses.KEY_VERIFYING_PAYMASTER, address(verifying));
            console.log("    [NEW] VerifyingPaymaster:", address(verifying));
        } else {
            console.log("    [SKIP] VerifyingPaymaster:", _getAddress(DeploymentAddresses.KEY_VERIFYING_PAYMASTER));
        }

        // SponsorPaymaster (depends on EntryPoint)
        if (_getAddress(DeploymentAddresses.KEY_SPONSOR_PAYMASTER) == address(0)) {
            SponsorPaymaster sponsor = new SponsorPaymaster(IEntryPoint(entryPointAddr), admin, verifyingSigner);
            _setAddress(DeploymentAddresses.KEY_SPONSOR_PAYMASTER, address(sponsor));
            console.log("    [NEW] SponsorPaymaster:", address(sponsor));
        } else {
            console.log("    [SKIP] SponsorPaymaster:", _getAddress(DeploymentAddresses.KEY_SPONSOR_PAYMASTER));
        }

        // ERC20Paymaster (depends on EntryPoint, PriceOracle)
        if (_getAddress(DeploymentAddresses.KEY_ERC20_PAYMASTER) == address(0)) {
            if (priceOracleAddr != address(0)) {
                ERC20Paymaster erc20Paymaster = new ERC20Paymaster(
                    IEntryPoint(entryPointAddr), admin, IPriceOracle(priceOracleAddr), DEFAULT_MARKUP
                );
                _setAddress(DeploymentAddresses.KEY_ERC20_PAYMASTER, address(erc20Paymaster));
                console.log("    [NEW] ERC20Paymaster:", address(erc20Paymaster));
            } else {
                console.log("    [SKIP] ERC20Paymaster: Missing PriceOracle");
            }
        } else {
            console.log("    [SKIP] ERC20Paymaster:", _getAddress(DeploymentAddresses.KEY_ERC20_PAYMASTER));
        }

        // Permit2Paymaster (depends on EntryPoint, PriceOracle, Permit2)
        if (_getAddress(DeploymentAddresses.KEY_PERMIT2_PAYMASTER) == address(0)) {
            if (priceOracleAddr != address(0) && permit2Addr != address(0)) {
                Permit2Paymaster permit2Paymaster = new Permit2Paymaster(
                    IEntryPoint(entryPointAddr),
                    admin,
                    IPermit2(permit2Addr),
                    IPriceOracle(priceOracleAddr),
                    DEFAULT_MARKUP
                );
                _setAddress(DeploymentAddresses.KEY_PERMIT2_PAYMASTER, address(permit2Paymaster));
                console.log("    [NEW] Permit2Paymaster:", address(permit2Paymaster));
            } else {
                console.log("    [SKIP] Permit2Paymaster: Missing PriceOracle or Permit2");
            }
        } else {
            console.log("    [SKIP] Permit2Paymaster:", _getAddress(DeploymentAddresses.KEY_PERMIT2_PAYMASTER));
        }

        console.log("");
    }

    // ============================================================
    // Phase 5: Plugins
    // ============================================================
    function _deployPhase5_Plugins() internal {
        console.log(">>> Phase 5: Plugins");

        address priceOracleAddr = _getAddress(DeploymentAddresses.KEY_PRICE_ORACLE);
        address dexAddr = _getAddress(DeploymentAddresses.KEY_DEX_INTEGRATION);

        // AutoSwapPlugin (depends on PriceOracle, DEXIntegration)
        if (_getAddress(DeploymentAddresses.KEY_AUTO_SWAP_PLUGIN) == address(0)) {
            if (priceOracleAddr != address(0) && dexAddr != address(0)) {
                AutoSwapPlugin autoSwap = new AutoSwapPlugin(IPriceOracle(priceOracleAddr), dexAddr);
                _setAddress(DeploymentAddresses.KEY_AUTO_SWAP_PLUGIN, address(autoSwap));
                console.log("  [NEW] AutoSwapPlugin:", address(autoSwap));
            } else {
                console.log("  [SKIP] AutoSwapPlugin: Missing PriceOracle or DEXIntegration");
            }
        } else {
            console.log("  [SKIP] AutoSwapPlugin:", _getAddress(DeploymentAddresses.KEY_AUTO_SWAP_PLUGIN));
        }

        // MicroLoanPlugin (depends on PriceOracle)
        if (_getAddress(DeploymentAddresses.KEY_MICRO_LOAN_PLUGIN) == address(0)) {
            if (priceOracleAddr != address(0)) {
                MicroLoanPlugin microLoan = new MicroLoanPlugin(
                    IPriceOracle(priceOracleAddr),
                    admin, // feeRecipient
                    50, // 0.5% protocol fee
                    500 // 5% liquidation bonus
                );
                _setAddress(DeploymentAddresses.KEY_MICRO_LOAN_PLUGIN, address(microLoan));
                console.log("  [NEW] MicroLoanPlugin:", address(microLoan));
            } else {
                console.log("  [SKIP] MicroLoanPlugin: Missing PriceOracle");
            }
        } else {
            console.log("  [SKIP] MicroLoanPlugin:", _getAddress(DeploymentAddresses.KEY_MICRO_LOAN_PLUGIN));
        }

        // OnRampPlugin (no external dependencies)
        if (_getAddress(DeploymentAddresses.KEY_ONRAMP_PLUGIN) == address(0)) {
            OnRampPlugin onRamp = new OnRampPlugin(
                admin, // treasury
                100, // 1% fee
                24 hours // order expiry
            );
            _setAddress(DeploymentAddresses.KEY_ONRAMP_PLUGIN, address(onRamp));
            console.log("  [NEW] OnRampPlugin:", address(onRamp));
        } else {
            console.log("  [SKIP] OnRampPlugin:", _getAddress(DeploymentAddresses.KEY_ONRAMP_PLUGIN));
        }

        console.log("");
    }

    // ============================================================
    // Phase 6: Subscription & Bridge
    // ============================================================
    function _deployPhase6_SubscriptionAndBridge() internal {
        console.log(">>> Phase 6: Subscription & Bridge");

        // --- Subscription ---
        console.log("  --- Subscription ---");

        // ERC7715PermissionManager
        if (_getAddress(DeploymentAddresses.KEY_PERMISSION_MANAGER) == address(0)) {
            ERC7715PermissionManager permissionMgr = new ERC7715PermissionManager();
            _setAddress(DeploymentAddresses.KEY_PERMISSION_MANAGER, address(permissionMgr));
            console.log("    [NEW] ERC7715PermissionManager:", address(permissionMgr));
        } else {
            console.log("    [SKIP] ERC7715PermissionManager:", _getAddress(DeploymentAddresses.KEY_PERMISSION_MANAGER));
        }

        // SubscriptionManager (depends on PermissionManager)
        address permissionMgrAddr = _getAddress(DeploymentAddresses.KEY_PERMISSION_MANAGER);
        if (_getAddress(DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER) == address(0)) {
            if (permissionMgrAddr != address(0)) {
                SubscriptionManager subMgr = new SubscriptionManager(permissionMgrAddr);
                _setAddress(DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER, address(subMgr));
                console.log("    [NEW] SubscriptionManager:", address(subMgr));

                // Configure: Add SubscriptionManager as authorized executor
                ERC7715PermissionManager(permissionMgrAddr).addAuthorizedExecutor(address(subMgr));
                console.log("    [CONFIG] Added SubscriptionManager as authorized executor");
            } else {
                console.log("    [SKIP] SubscriptionManager: Missing PermissionManager");
            }
        } else {
            console.log("    [SKIP] SubscriptionManager:", _getAddress(DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER));
        }

        // --- Bridge ---
        console.log("  --- Bridge ---");
        _deployBridgeContracts();

        console.log("");
    }

    // ============================================================
    // Bridge Deployment Helper
    // ============================================================
    function _deployBridgeContracts() internal {
        // Layer 0: No dependencies
        if (_getAddress(DeploymentAddresses.KEY_FRAUD_PROOF_VERIFIER) == address(0)) {
            FraudProofVerifier fpv = new FraudProofVerifier();
            _setAddress(DeploymentAddresses.KEY_FRAUD_PROOF_VERIFIER, address(fpv));
            console.log("    [NEW] FraudProofVerifier:", address(fpv));
        } else {
            console.log("    [SKIP] FraudProofVerifier:", _getAddress(DeploymentAddresses.KEY_FRAUD_PROOF_VERIFIER));
        }

        if (_getAddress(DeploymentAddresses.KEY_BRIDGE_RATE_LIMITER) == address(0)) {
            BridgeRateLimiter brl = new BridgeRateLimiter();
            _setAddress(DeploymentAddresses.KEY_BRIDGE_RATE_LIMITER, address(brl));
            console.log("    [NEW] BridgeRateLimiter:", address(brl));
        } else {
            console.log("    [SKIP] BridgeRateLimiter:", _getAddress(DeploymentAddresses.KEY_BRIDGE_RATE_LIMITER));
        }

        // Layer 1: Configuration required
        if (_getAddress(DeploymentAddresses.KEY_BRIDGE_VALIDATOR) == address(0)) {
            address[] memory signers = _generateTestSigners(5);
            BridgeValidator bv = new BridgeValidator(signers, 3);
            _setAddress(DeploymentAddresses.KEY_BRIDGE_VALIDATOR, address(bv));
            console.log("    [NEW] BridgeValidator:", address(bv));
        } else {
            console.log("    [SKIP] BridgeValidator:", _getAddress(DeploymentAddresses.KEY_BRIDGE_VALIDATOR));
        }

        if (_getAddress(DeploymentAddresses.KEY_BRIDGE_GUARDIAN) == address(0)) {
            address[] memory guardians = _generateTestGuardians(3);
            BridgeGuardian bg = new BridgeGuardian(guardians, 2);
            _setAddress(DeploymentAddresses.KEY_BRIDGE_GUARDIAN, address(bg));
            console.log("    [NEW] BridgeGuardian:", address(bg));
        } else {
            console.log("    [SKIP] BridgeGuardian:", _getAddress(DeploymentAddresses.KEY_BRIDGE_GUARDIAN));
        }

        if (_getAddress(DeploymentAddresses.KEY_OPTIMISTIC_VERIFIER) == address(0)) {
            OptimisticVerifier ov =
                new OptimisticVerifier(DEFAULT_CHALLENGE_PERIOD, DEFAULT_CHALLENGE_BOND, DEFAULT_CHALLENGER_REWARD);
            _setAddress(DeploymentAddresses.KEY_OPTIMISTIC_VERIFIER, address(ov));
            console.log("    [NEW] OptimisticVerifier:", address(ov));
        } else {
            console.log("    [SKIP] OptimisticVerifier:", _getAddress(DeploymentAddresses.KEY_OPTIMISTIC_VERIFIER));
        }

        // Layer 2: Main Bridge (depends on all above)
        if (_getAddress(DeploymentAddresses.KEY_SECURE_BRIDGE) == address(0)) {
            address validatorAddr = _getAddress(DeploymentAddresses.KEY_BRIDGE_VALIDATOR);
            address ovAddr = _getAddress(DeploymentAddresses.KEY_OPTIMISTIC_VERIFIER);
            address brlAddr = _getAddress(DeploymentAddresses.KEY_BRIDGE_RATE_LIMITER);
            address bgAddr = _getAddress(DeploymentAddresses.KEY_BRIDGE_GUARDIAN);

            if (validatorAddr != address(0) && ovAddr != address(0) && brlAddr != address(0) && bgAddr != address(0)) {
                SecureBridge sb = new SecureBridge(
                    validatorAddr,
                    payable(ovAddr),
                    brlAddr,
                    bgAddr,
                    admin // feeRecipient
                );
                _setAddress(DeploymentAddresses.KEY_SECURE_BRIDGE, address(sb));
                console.log("    [NEW] SecureBridge:", address(sb));
            } else {
                console.log("    [SKIP] SecureBridge: Missing dependencies");
            }
        } else {
            console.log("    [SKIP] SecureBridge:", _getAddress(DeploymentAddresses.KEY_SECURE_BRIDGE));
        }
    }

    // ============================================================
    // Helper Functions
    // ============================================================
    function _generateTestSigners(uint256 count) internal pure returns (address[] memory) {
        address[] memory signers = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            signers[i] = address(uint160(uint256(keccak256(abi.encodePacked("signer", i)))));
        }
        return signers;
    }

    function _generateTestGuardians(uint256 count) internal pure returns (address[] memory) {
        address[] memory guardians = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            guardians[i] = address(uint160(uint256(keccak256(abi.encodePacked("guardian", i)))));
        }
        return guardians;
    }

    function _printDeploymentSummary() internal view {
        console.log("");
        console.log("========================================");
        console.log("  Deployment Summary");
        console.log("========================================");
        console.log("");

        console.log("Phase 0 - Base Infrastructure:");
        console.log("  wKRC:", _getAddress(DeploymentAddresses.KEY_WKRC));
        console.log("  USDC:", _getAddress(DeploymentAddresses.KEY_USDC));
        console.log("  EntryPoint:", _getAddress(DeploymentAddresses.KEY_ENTRYPOINT));

        console.log("");
        console.log("Phase 1 - Core Smart Account:");
        console.log("  Kernel:", _getAddress(DeploymentAddresses.KEY_KERNEL));
        console.log("  KernelFactory:", _getAddress(DeploymentAddresses.KEY_KERNEL_FACTORY));
        console.log("  FactoryStaker:", _getAddress(DeploymentAddresses.KEY_FACTORY_STAKER));

        console.log("");
        console.log("Phase 2 - ERC-7579 Modules:");
        console.log("  ECDSAValidator:", _getAddress(DeploymentAddresses.KEY_ECDSA_VALIDATOR));
        console.log("  WeightedECDSAValidator:", _getAddress(DeploymentAddresses.KEY_WEIGHTED_VALIDATOR));
        console.log("  MultiChainValidator:", _getAddress(DeploymentAddresses.KEY_MULTICHAIN_VALIDATOR));
        console.log("  MultiSigValidator:", _getAddress(DeploymentAddresses.KEY_MULTISIG_VALIDATOR));
        console.log("  WebAuthnValidator:", _getAddress(DeploymentAddresses.KEY_WEBAUTHN_VALIDATOR));
        console.log("  AuditHook:", _getAddress(DeploymentAddresses.KEY_AUDIT_HOOK));
        console.log("  SpendingLimitHook:", _getAddress(DeploymentAddresses.KEY_SPENDING_LIMIT_HOOK));
        console.log("  TokenReceiverFallback:", _getAddress(DeploymentAddresses.KEY_TOKEN_RECEIVER_FALLBACK));
        console.log("  FlashLoanFallback:", _getAddress(DeploymentAddresses.KEY_FLASH_LOAN_FALLBACK));
        console.log("  SessionKeyExecutor:", _getAddress(DeploymentAddresses.KEY_SESSION_KEY_EXECUTOR));
        console.log("  RecurringPaymentExecutor:", _getAddress(DeploymentAddresses.KEY_RECURRING_PAYMENT_EXECUTOR));

        console.log("");
        console.log("Phase 3 - Feature Modules:");
        console.log("  KYCRegistry:", _getAddress(DeploymentAddresses.KEY_KYC_REGISTRY));
        console.log("  AuditLogger:", _getAddress(DeploymentAddresses.KEY_AUDIT_LOGGER));
        console.log("  ProofOfReserve:", _getAddress(DeploymentAddresses.KEY_PROOF_OF_RESERVE));
        console.log("  RegulatoryRegistry:", _getAddress(DeploymentAddresses.KEY_REGULATORY_REGISTRY));
        console.log("  ERC5564Announcer:", _getAddress(DeploymentAddresses.KEY_ANNOUNCER));
        console.log("  ERC6538Registry:", _getAddress(DeploymentAddresses.KEY_REGISTRY));
        console.log("  PrivateBank:", _getAddress(DeploymentAddresses.KEY_PRIVATE_BANK));
        console.log("  Permit2:", _getAddress(DeploymentAddresses.KEY_PERMIT2));

        console.log("");
        console.log("Phase 4 - DeFi & Paymasters:");
        console.log("  PriceOracle:", _getAddress(DeploymentAddresses.KEY_PRICE_ORACLE));
        console.log("  DEXIntegration:", _getAddress(DeploymentAddresses.KEY_DEX_INTEGRATION));
        console.log("  VerifyingPaymaster:", _getAddress(DeploymentAddresses.KEY_VERIFYING_PAYMASTER));
        console.log("  SponsorPaymaster:", _getAddress(DeploymentAddresses.KEY_SPONSOR_PAYMASTER));
        console.log("  ERC20Paymaster:", _getAddress(DeploymentAddresses.KEY_ERC20_PAYMASTER));
        console.log("  Permit2Paymaster:", _getAddress(DeploymentAddresses.KEY_PERMIT2_PAYMASTER));

        console.log("");
        console.log("Phase 5 - Plugins:");
        console.log("  AutoSwapPlugin:", _getAddress(DeploymentAddresses.KEY_AUTO_SWAP_PLUGIN));
        console.log("  MicroLoanPlugin:", _getAddress(DeploymentAddresses.KEY_MICRO_LOAN_PLUGIN));
        console.log("  OnRampPlugin:", _getAddress(DeploymentAddresses.KEY_ONRAMP_PLUGIN));

        console.log("");
        console.log("Phase 6 - Subscription & Bridge:");
        console.log("  ERC7715PermissionManager:", _getAddress(DeploymentAddresses.KEY_PERMISSION_MANAGER));
        console.log("  SubscriptionManager:", _getAddress(DeploymentAddresses.KEY_SUBSCRIPTION_MANAGER));
        console.log("  FraudProofVerifier:", _getAddress(DeploymentAddresses.KEY_FRAUD_PROOF_VERIFIER));
        console.log("  BridgeRateLimiter:", _getAddress(DeploymentAddresses.KEY_BRIDGE_RATE_LIMITER));
        console.log("  BridgeValidator:", _getAddress(DeploymentAddresses.KEY_BRIDGE_VALIDATOR));
        console.log("  BridgeGuardian:", _getAddress(DeploymentAddresses.KEY_BRIDGE_GUARDIAN));
        console.log("  OptimisticVerifier:", _getAddress(DeploymentAddresses.KEY_OPTIMISTIC_VERIFIER));
        console.log("  SecureBridge:", _getAddress(DeploymentAddresses.KEY_SECURE_BRIDGE));

        console.log("");
        console.log("Addresses saved to:", _getDeploymentPath());
        console.log("========================================");
    }
}
