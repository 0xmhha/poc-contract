// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

// ============ Tokens ============
import {StableToken} from "../src/tokens/StableToken.sol";
import {WKRW} from "../src/tokens/WKRW.sol";

// ============ Compliance ============
import {KYCRegistry} from "../src/compliance/KYCRegistry.sol";
import {RegulatoryRegistry} from "../src/compliance/RegulatoryRegistry.sol";
import {AuditLogger} from "../src/compliance/AuditLogger.sol";
import {ProofOfReserve} from "../src/compliance/ProofOfReserve.sol";

// ============ DeFi Utilities ============
import {PriceOracle} from "../src/defi/PriceOracle.sol";
import {IPriceOracle} from "../src/erc4337-paymaster/interfaces/IPriceOracle.sol";
import {DEXIntegration} from "../src/defi/DEXIntegration.sol";

// ============ Privacy ============
import {ERC6538Registry} from "../src/privacy/ERC6538Registry.sol";
import {ERC5564Announcer} from "../src/privacy/ERC5564Announcer.sol";
import {PrivateBank} from "../src/privacy/PrivateBank.sol";

// ============ Subscription ============
import {ERC7715PermissionManager} from "../src/subscription/ERC7715PermissionManager.sol";
import {SubscriptionManager} from "../src/subscription/SubscriptionManager.sol";

// ============ Bridge ============
import {BridgeValidator} from "../src/bridge/BridgeValidator.sol";
import {BridgeGuardian} from "../src/bridge/BridgeGuardian.sol";
import {BridgeRateLimiter} from "../src/bridge/BridgeRateLimiter.sol";
import {OptimisticVerifier} from "../src/bridge/OptimisticVerifier.sol";
import {FraudProofVerifier} from "../src/bridge/FraudProofVerifier.sol";
import {SecureBridge} from "../src/bridge/SecureBridge.sol";

// ============ ERC-4337 ============
import {EntryPoint} from "../src/erc4337-entrypoint/EntryPoint.sol";
import {IEntryPoint} from "../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import {BasePaymaster} from "../src/erc4337-paymaster/BasePaymaster.sol";
import {VerifyingPaymaster} from "../src/erc4337-paymaster/VerifyingPaymaster.sol";
import {ERC20Paymaster} from "../src/erc4337-paymaster/ERC20Paymaster.sol";
import {Permit2Paymaster} from "../src/erc4337-paymaster/Permit2Paymaster.sol";
import {IPermit2} from "../src/permit2/interfaces/IPermit2.sol";
import {SponsorPaymaster} from "../src/erc4337-paymaster/SponsorPaymaster.sol";

// ============ ERC-7579 ============
import {Kernel} from "../src/erc7579-smartaccount/Kernel.sol";
import {IEntryPoint as IKernelEntryPoint} from "../src/erc7579-smartaccount/interfaces/IEntryPoint.sol";
import {KernelFactory} from "../src/erc7579-smartaccount/factory/KernelFactory.sol";
import {FactoryStaker} from "../src/erc7579-smartaccount/factory/FactoryStaker.sol";

// ============ ERC-7579 Modules ============
import {ECDSAValidator} from "../src/erc7579-validators/ECDSAValidator.sol";
import {WeightedECDSAValidator} from "../src/erc7579-validators/WeightedECDSAValidator.sol";
import {MultiChainValidator} from "../src/erc7579-validators/MultiChainValidator.sol";
import {SessionKeyExecutor} from "../src/erc7579-executors/SessionKeyExecutor.sol";
import {RecurringPaymentExecutor} from "../src/erc7579-executors/RecurringPaymentExecutor.sol";
import {AuditHook} from "../src/erc7579-hooks/AuditHook.sol";
import {SpendingLimitHook} from "../src/erc7579-hooks/SpendingLimitHook.sol";
import {TokenReceiverFallback} from "../src/erc7579-fallbacks/TokenReceiverFallback.sol";
import {FlashLoanFallback} from "../src/erc7579-fallbacks/FlashLoanFallback.sol";

// ============ Plugins ============
import {AutoSwapPlugin} from "../src/erc7579-plugins/AutoSwapPlugin.sol";
import {MicroLoanPlugin} from "../src/erc7579-plugins/MicroLoanPlugin.sol";

/**
 * @title DeployOrderedScript
 * @notice 배포 순서 검토에 따른 체계적인 컨트랙트 배포 스크립트
 * @dev 의존성 순서를 엄격히 준수하여 배포합니다.
 *
 * 배포 순서:
 * 1. 기본 토큰·컴플라이언스 레지스트리
 * 2. 유틸리티 (PriceOracle, DEXIntegration, Privacy Registry)
 * 3. 프라이버시·구독
 * 4. 브리지 (Validator → Guardian → RateLimiter → OptimisticVerifier → FraudProofVerifier → SecureBridge)
 * 5. ERC-4337 EntryPoint 및 Paymaster 파생들
 * 6. ERC-7579 Kernel/Factory/모듈 세트
 * 7. 나머지 DeFi·DEX 컨트랙트
 *
 * Environment Variables:
 *   - ADMIN_ADDRESS: 관리자 주소 (기본값: deployer)
 *   - VERIFYING_SIGNER: VerifyingPaymaster 서명자 (기본값: deployer)
 *   - BRIDGE_SIGNERS: 콤마로 구분된 브리지 서명자 주소 목록
 *   - BRIDGE_GUARDIANS: 콤마로 구분된 브리지 가디언 주소 목록
 *   - SIGNER_THRESHOLD: 브리지 서명자 임계값 (기본값: 2)
 *   - GUARDIAN_THRESHOLD: 브리지 가디언 임계값 (기본값: 2)
 *   - FEE_RECIPIENT: 수수료 수신자 (기본값: deployer)
 *   - SWAP_ROUTER: Uniswap SwapRouter 주소
 *   - QUOTER: Uniswap Quoter 주소
 *   - PERMIT2_ADDRESS: Permit2 컨트랙트 주소
 *   - RETENTION_PERIOD: AuditLogger 보관 기간 (기본값: 365 days)
 *   - AUTO_PAUSE_THRESHOLD: ProofOfReserve 자동 일시정지 임계값 (기본값: 3)
 *   - APPROVER_1, APPROVER_2, APPROVER_3: RegulatoryRegistry 승인자 주소
 *
 * Usage:
 *   forge script script/DeployOrdered.s.sol:DeployOrderedScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployOrderedScript is Script {
    // ============ State Variables ============
    
    // Phase 1: Tokens & Compliance
    StableToken public stableToken;
    WKRW public wkrw;
    KYCRegistry public kycRegistry;
    RegulatoryRegistry public regulatoryRegistry;
    AuditLogger public auditLogger;
    ProofOfReserve public proofOfReserve;
    
    // Phase 2: Utilities
    PriceOracle public priceOracle;
    DEXIntegration public dexIntegration;
    ERC6538Registry public erc6538Registry;
    ERC5564Announcer public erc5564Announcer;
    
    // Phase 3: Privacy & Subscription
    PrivateBank public privateBank;
    ERC7715PermissionManager public permissionManager;
    SubscriptionManager public subscriptionManager;
    
    // Phase 4: Bridge
    BridgeValidator public bridgeValidator;
    BridgeGuardian public bridgeGuardian;
    BridgeRateLimiter public bridgeRateLimiter;
    OptimisticVerifier public optimisticVerifier;
    FraudProofVerifier public fraudProofVerifier;
    SecureBridge public secureBridge;
    
    // Phase 5: ERC-4337
    EntryPoint public entryPoint;
    VerifyingPaymaster public verifyingPaymaster;
    ERC20Paymaster public erc20Paymaster;
    Permit2Paymaster public permit2Paymaster;
    SponsorPaymaster public sponsorPaymaster;
    
    // Phase 6: ERC-7579
    Kernel public kernel;
    KernelFactory public kernelFactory;
    FactoryStaker public factoryStaker;
    
    // ERC-7579 Modules
    ECDSAValidator public ecdsaValidator;
    WeightedECDSAValidator public weightedValidator;
    MultiChainValidator public multiChainValidator;
    SessionKeyExecutor public sessionKeyExecutor;
    RecurringPaymentExecutor public recurringPaymentExecutor;
    AuditHook public auditHook;
    SpendingLimitHook public spendingLimitHook;
    TokenReceiverFallback public tokenReceiverFallback;
    FlashLoanFallback public flashLoanFallback;
    
    // Plugins
    AutoSwapPlugin public autoSwapPlugin;
    MicroLoanPlugin public microLoanPlugin;

    // ============ Constants ============
    uint256 constant DEFAULT_RETENTION_PERIOD = 365 days;
    uint256 constant DEFAULT_AUTO_PAUSE_THRESHOLD = 3;
    uint256 constant DEFAULT_CHALLENGE_PERIOD = 1 days;
    uint256 constant DEFAULT_CHALLENGE_BOND = 1 ether;
    uint256 constant DEFAULT_CHALLENGER_REWARD = 0.5 ether;
    uint256 constant DEFAULT_SIGNER_THRESHOLD = 2;
    uint256 constant DEFAULT_GUARDIAN_THRESHOLD = 2;
    uint256 constant DEFAULT_MARKUP = 1000; // 10%

    function setUp() public {}

    function run() public {
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        address verifyingSigner = vm.envOr("VERIFYING_SIGNER", msg.sender);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", msg.sender);

        console.log("================================================================");
        console.log("         ORDERED DEPLOYMENT SCRIPT                              ");
        console.log("================================================================");
        console.log("Admin:", admin);
        console.log("Deployer:", msg.sender);
        console.log("Chain ID:", block.chainid);
        console.log("================================================================");

        vm.startBroadcast();

        // ============ Phase 1: 기본 토큰·컴플라이언스 레지스트리 ============
        console.log("\n=== Phase 1: Tokens & Compliance ===");
        
        // 1.1 StableToken
        console.log("\n[1.1] Deploying StableToken...");
        stableToken = new StableToken(admin);
        console.log("StableToken deployed at:", address(stableToken));
        
        // 1.2 WKRW
        console.log("\n[1.2] Deploying WKRW...");
        wkrw = new WKRW();
        console.log("WKRW deployed at:", address(wkrw));
        
        // 1.3 KYCRegistry
        console.log("\n[1.3] Deploying KYCRegistry...");
        kycRegistry = new KYCRegistry(admin);
        console.log("KYCRegistry deployed at:", address(kycRegistry));
        
        // 1.4 RegulatoryRegistry
        console.log("\n[1.4] Deploying RegulatoryRegistry...");
        address[] memory approvers = new address[](3);
        approvers[0] = vm.envOr("APPROVER_1", admin);
        approvers[1] = vm.envOr("APPROVER_2", address(uint160(uint256(keccak256("approver2")))));
        approvers[2] = vm.envOr("APPROVER_3", address(uint160(uint256(keccak256("approver3")))));
        regulatoryRegistry = new RegulatoryRegistry(approvers);
        console.log("RegulatoryRegistry deployed at:", address(regulatoryRegistry));
        
        // 1.5 AuditLogger
        console.log("\n[1.5] Deploying AuditLogger...");
        uint256 retentionPeriod = vm.envOr("RETENTION_PERIOD", DEFAULT_RETENTION_PERIOD);
        auditLogger = new AuditLogger(admin, retentionPeriod);
        console.log("AuditLogger deployed at:", address(auditLogger));
        
        // 1.6 ProofOfReserve
        console.log("\n[1.6] Deploying ProofOfReserve...");
        uint256 autoPauseThreshold = vm.envOr("AUTO_PAUSE_THRESHOLD", DEFAULT_AUTO_PAUSE_THRESHOLD);
        proofOfReserve = new ProofOfReserve(admin, autoPauseThreshold);
        console.log("ProofOfReserve deployed at:", address(proofOfReserve));

        // ============ Phase 2: 유틸리티 ============
        console.log("\n=== Phase 2: Utilities ===");
        
        // 2.1 PriceOracle
        console.log("\n[2.1] Deploying PriceOracle...");
        priceOracle = new PriceOracle();
        console.log("PriceOracle deployed at:", address(priceOracle));
        
        // 2.2 DEXIntegration
        console.log("\n[2.2] Deploying DEXIntegration...");
        address swapRouter = vm.envOr("SWAP_ROUTER", address(0));
        address quoter = vm.envOr("QUOTER", address(0));
        if (swapRouter == address(0) || quoter == address(0)) {
            console.log("Warning: SWAP_ROUTER or QUOTER not set, skipping DEXIntegration");
        } else {
            dexIntegration = new DEXIntegration(swapRouter, quoter, address(wkrw));
            console.log("DEXIntegration deployed at:", address(dexIntegration));
        }
        
        // 2.3 ERC6538Registry
        console.log("\n[2.3] Deploying ERC6538Registry...");
        erc6538Registry = new ERC6538Registry();
        console.log("ERC6538Registry deployed at:", address(erc6538Registry));
        
        // 2.4 ERC5564Announcer
        console.log("\n[2.4] Deploying ERC5564Announcer...");
        erc5564Announcer = new ERC5564Announcer();
        console.log("ERC5564Announcer deployed at:", address(erc5564Announcer));

        // ============ Phase 3: 프라이버시·구독 ============
        console.log("\n=== Phase 3: Privacy & Subscription ===");
        
        // 3.1 PrivateBank
        console.log("\n[3.1] Deploying PrivateBank...");
        privateBank = new PrivateBank(address(erc5564Announcer), address(erc6538Registry));
        console.log("PrivateBank deployed at:", address(privateBank));
        
        // 3.2 ERC7715PermissionManager
        console.log("\n[3.2] Deploying ERC7715PermissionManager...");
        permissionManager = new ERC7715PermissionManager();
        console.log("ERC7715PermissionManager deployed at:", address(permissionManager));
        
        // 3.3 SubscriptionManager
        console.log("\n[3.3] Deploying SubscriptionManager...");
        subscriptionManager = new SubscriptionManager(address(permissionManager));
        console.log("SubscriptionManager deployed at:", address(subscriptionManager));

        // ============ Phase 4: 브리지 ============
        console.log("\n=== Phase 4: Bridge Infrastructure ===");
        
        // 4.1 BridgeValidator
        console.log("\n[4.1] Deploying BridgeValidator...");
        address[] memory signers = _parseAddresses(vm.envOr("BRIDGE_SIGNERS", string("")));
        if (signers.length == 0) {
            signers = _defaultAddresses(admin, "signer", 3);
            console.log("Warning: Using default bridge signers (testing only)");
        }
        uint256 signerThreshold = vm.envOr("SIGNER_THRESHOLD", DEFAULT_SIGNER_THRESHOLD);
        bridgeValidator = new BridgeValidator(signers, signerThreshold);
        console.log("BridgeValidator deployed at:", address(bridgeValidator));
        
        // 4.2 BridgeGuardian
        console.log("\n[4.2] Deploying BridgeGuardian...");
        address[] memory guardians = _parseAddresses(vm.envOr("BRIDGE_GUARDIANS", string("")));
        if (guardians.length == 0) {
            guardians = _defaultAddresses(admin, "guardian", 3);
            console.log("Warning: Using default bridge guardians (testing only)");
        }
        uint256 guardianThreshold = vm.envOr("GUARDIAN_THRESHOLD", DEFAULT_GUARDIAN_THRESHOLD);
        bridgeGuardian = new BridgeGuardian(guardians, guardianThreshold);
        console.log("BridgeGuardian deployed at:", address(bridgeGuardian));
        
        // 4.3 BridgeRateLimiter
        console.log("\n[4.3] Deploying BridgeRateLimiter...");
        bridgeRateLimiter = new BridgeRateLimiter();
        console.log("BridgeRateLimiter deployed at:", address(bridgeRateLimiter));
        
        // 4.4 OptimisticVerifier
        console.log("\n[4.4] Deploying OptimisticVerifier...");
        optimisticVerifier = new OptimisticVerifier(
            DEFAULT_CHALLENGE_PERIOD,
            DEFAULT_CHALLENGE_BOND,
            DEFAULT_CHALLENGER_REWARD
        );
        console.log("OptimisticVerifier deployed at:", address(optimisticVerifier));
        
        // 4.5 FraudProofVerifier
        console.log("\n[4.5] Deploying FraudProofVerifier...");
        fraudProofVerifier = new FraudProofVerifier();
        console.log("FraudProofVerifier deployed at:", address(fraudProofVerifier));
        
        // 4.6 SecureBridge
        console.log("\n[4.6] Deploying SecureBridge...");
        secureBridge = new SecureBridge(
            address(bridgeValidator),
            payable(address(optimisticVerifier)),
            address(bridgeRateLimiter),
            address(bridgeGuardian),
            feeRecipient
        );
        console.log("SecureBridge deployed at:", address(secureBridge));
        
        // Wire bridge dependencies
        console.log("\n[4.7] Wiring bridge dependencies...");
        optimisticVerifier.setFraudProofVerifier(address(fraudProofVerifier));
        optimisticVerifier.setAuthorizedCaller(address(secureBridge), true);
        fraudProofVerifier.setOptimisticVerifier(address(optimisticVerifier));
        fraudProofVerifier.setBridgeValidator(address(bridgeValidator));
        bridgeRateLimiter.setAuthorizedCaller(address(secureBridge), true);
        bridgeGuardian.setBridgeTarget(address(secureBridge));
        console.log("Bridge dependencies wired successfully");

        // ============ Phase 5: ERC-4337 EntryPoint 및 Paymaster ============
        console.log("\n=== Phase 5: ERC-4337 Infrastructure ===");
        
        // 5.1 EntryPoint
        console.log("\n[5.1] Deploying EntryPoint...");
        entryPoint = new EntryPoint();
        console.log("EntryPoint deployed at:", address(entryPoint));
        
        // 5.2 VerifyingPaymaster
        console.log("\n[5.2] Deploying VerifyingPaymaster...");
        verifyingPaymaster = new VerifyingPaymaster(
            IEntryPoint(address(entryPoint)),
            admin,
            verifyingSigner
        );
        console.log("VerifyingPaymaster deployed at:", address(verifyingPaymaster));
        
        // 5.3 ERC20Paymaster
        console.log("\n[5.3] Deploying ERC20Paymaster...");
        erc20Paymaster = new ERC20Paymaster(
            IEntryPoint(address(entryPoint)),
            admin,
            IPriceOracle(address(priceOracle)),
            DEFAULT_MARKUP
        );
        console.log("ERC20Paymaster deployed at:", address(erc20Paymaster));
        
        // 5.4 Permit2Paymaster
        console.log("\n[5.4] Deploying Permit2Paymaster...");
        address permit2Addr = vm.envOr("PERMIT2_ADDRESS", address(0));
        if (permit2Addr == address(0)) {
            console.log("Warning: PERMIT2_ADDRESS not set, skipping Permit2Paymaster");
        } else {
            permit2Paymaster = new Permit2Paymaster(
                IEntryPoint(address(entryPoint)),
                admin,
                IPermit2(permit2Addr),
                IPriceOracle(address(priceOracle)),
                DEFAULT_MARKUP
            );
            console.log("Permit2Paymaster deployed at:", address(permit2Paymaster));
        }
        
        // 5.5 SponsorPaymaster
        console.log("\n[5.5] Deploying SponsorPaymaster...");
        sponsorPaymaster = new SponsorPaymaster(
            IEntryPoint(address(entryPoint)),
            admin,
            verifyingSigner
        );
        console.log("SponsorPaymaster deployed at:", address(sponsorPaymaster));

        // ============ Phase 6: ERC-7579 스마트어카운트 ============
        console.log("\n=== Phase 6: ERC-7579 Smart Account ===");
        
        // 6.1 Kernel
        console.log("\n[6.1] Deploying Kernel...");
        kernel = new Kernel(IKernelEntryPoint(address(entryPoint)));
        console.log("Kernel deployed at:", address(kernel));
        
        // 6.2 KernelFactory
        console.log("\n[6.2] Deploying KernelFactory...");
        kernelFactory = new KernelFactory(address(kernel));
        console.log("KernelFactory deployed at:", address(kernelFactory));
        
        // 6.3 FactoryStaker
        console.log("\n[6.3] Deploying FactoryStaker...");
        factoryStaker = new FactoryStaker(address(kernelFactory));
        console.log("FactoryStaker deployed at:", address(factoryStaker));
        
        // 6.4 Validators
        console.log("\n[6.4] Deploying Validators...");
        ecdsaValidator = new ECDSAValidator();
        console.log("ECDSAValidator deployed at:", address(ecdsaValidator));
        
        weightedValidator = new WeightedECDSAValidator();
        console.log("WeightedECDSAValidator deployed at:", address(weightedValidator));
        
        multiChainValidator = new MultiChainValidator();
        console.log("MultiChainValidator deployed at:", address(multiChainValidator));
        
        // 6.5 Executors
        console.log("\n[6.5] Deploying Executors...");
        sessionKeyExecutor = new SessionKeyExecutor();
        console.log("SessionKeyExecutor deployed at:", address(sessionKeyExecutor));
        
        recurringPaymentExecutor = new RecurringPaymentExecutor();
        console.log("RecurringPaymentExecutor deployed at:", address(recurringPaymentExecutor));
        
        // 6.6 Hooks
        console.log("\n[6.6] Deploying Hooks...");
        auditHook = new AuditHook();
        console.log("AuditHook deployed at:", address(auditHook));
        
        spendingLimitHook = new SpendingLimitHook();
        console.log("SpendingLimitHook deployed at:", address(spendingLimitHook));
        
        // 6.7 Fallbacks
        console.log("\n[6.7] Deploying Fallbacks...");
        tokenReceiverFallback = new TokenReceiverFallback();
        console.log("TokenReceiverFallback deployed at:", address(tokenReceiverFallback));
        
        flashLoanFallback = new FlashLoanFallback();
        console.log("FlashLoanFallback deployed at:", address(flashLoanFallback));
        
        // 6.8 Plugins
        console.log("\n[6.8] Deploying Plugins...");
        // AutoSwapPlugin requires oracle and DEX router (not DEXIntegration)
        address swapRouterAddr = vm.envOr("SWAP_ROUTER", address(0));
        if (swapRouterAddr != address(0)) {
            autoSwapPlugin = new AutoSwapPlugin(
                IPriceOracle(address(priceOracle)),
                swapRouterAddr
            );
            console.log("AutoSwapPlugin deployed at:", address(autoSwapPlugin));
        } else {
            console.log("Warning: SWAP_ROUTER not set, skipping AutoSwapPlugin");
        }
        
        // MicroLoanPlugin requires additional parameters
        uint256 protocolFeeBps = vm.envOr("PROTOCOL_FEE_BPS", uint256(50)); // 0.5%
        uint256 liquidationBonusBps = vm.envOr("LIQUIDATION_BONUS_BPS", uint256(500)); // 5%
        microLoanPlugin = new MicroLoanPlugin(
            IPriceOracle(address(priceOracle)),
            feeRecipient,
            protocolFeeBps,
            liquidationBonusBps
        );
        console.log("MicroLoanPlugin deployed at:", address(microLoanPlugin));

        vm.stopBroadcast();

        // ============ Final Summary ============
        _printSummary(admin, feeRecipient);
    }

    function _parseAddresses(string memory input) internal pure returns (address[] memory parsed) {
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
                    parsed[index] = vm.parseAddress(part);
                    index++;
                }
                start = i + 1;
            }
        }

        assembly {
            mstore(parsed, index)
        }
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

    function _printSummary(address admin, address feeRecipient) internal view {
        console.log("\n");
        console.log("================================================================");
        console.log("         DEPLOYMENT SUMMARY                                      ");
        console.log("================================================================");
        
        console.log("\n--- Phase 1: Tokens & Compliance ---");
        _logAddress("StableToken", address(stableToken));
        _logAddress("WKRW", address(wkrw));
        _logAddress("KYCRegistry", address(kycRegistry));
        _logAddress("RegulatoryRegistry", address(regulatoryRegistry));
        _logAddress("AuditLogger", address(auditLogger));
        _logAddress("ProofOfReserve", address(proofOfReserve));
        
        console.log("\n--- Phase 2: Utilities ---");
        _logAddress("PriceOracle", address(priceOracle));
        if (address(dexIntegration) != address(0)) {
            _logAddress("DEXIntegration", address(dexIntegration));
        }
        _logAddress("ERC6538Registry", address(erc6538Registry));
        _logAddress("ERC5564Announcer", address(erc5564Announcer));
        
        console.log("\n--- Phase 3: Privacy & Subscription ---");
        _logAddress("PrivateBank", address(privateBank));
        _logAddress("ERC7715PermissionManager", address(permissionManager));
        _logAddress("SubscriptionManager", address(subscriptionManager));
        
        console.log("\n--- Phase 4: Bridge ---");
        _logAddress("BridgeValidator", address(bridgeValidator));
        _logAddress("BridgeGuardian", address(bridgeGuardian));
        _logAddress("BridgeRateLimiter", address(bridgeRateLimiter));
        _logAddress("OptimisticVerifier", address(optimisticVerifier));
        _logAddress("FraudProofVerifier", address(fraudProofVerifier));
        _logAddress("SecureBridge", address(secureBridge));
        
        console.log("\n--- Phase 5: ERC-4337 ---");
        _logAddress("EntryPoint", address(entryPoint));
        _logAddress("VerifyingPaymaster", address(verifyingPaymaster));
        _logAddress("ERC20Paymaster", address(erc20Paymaster));
        if (address(permit2Paymaster) != address(0)) {
            _logAddress("Permit2Paymaster", address(permit2Paymaster));
        }
        _logAddress("SponsorPaymaster", address(sponsorPaymaster));
        
        console.log("\n--- Phase 6: ERC-7579 ---");
        _logAddress("Kernel", address(kernel));
        _logAddress("KernelFactory", address(kernelFactory));
        _logAddress("FactoryStaker", address(factoryStaker));
        _logAddress("ECDSAValidator", address(ecdsaValidator));
        _logAddress("WeightedECDSAValidator", address(weightedValidator));
        _logAddress("MultiChainValidator", address(multiChainValidator));
        _logAddress("SessionKeyExecutor", address(sessionKeyExecutor));
        _logAddress("RecurringPaymentExecutor", address(recurringPaymentExecutor));
        _logAddress("AuditHook", address(auditHook));
        _logAddress("SpendingLimitHook", address(spendingLimitHook));
        _logAddress("TokenReceiverFallback", address(tokenReceiverFallback));
        _logAddress("FlashLoanFallback", address(flashLoanFallback));
        if (address(autoSwapPlugin) != address(0)) {
            _logAddress("AutoSwapPlugin", address(autoSwapPlugin));
        }
        _logAddress("MicroLoanPlugin", address(microLoanPlugin));
        
        console.log("\n--- Configuration ---");
        _logAddress("Admin", admin);
        _logAddress("Fee Recipient", feeRecipient);
        
        console.log("\n================================================================");
    }

    function _logAddress(string memory name, address addr) internal pure {
        console.log(string.concat("  ", name, ": ", vm.toString(addr)));
    }
}

// ============================================================================
// Individual Deployment Scripts
// ============================================================================
// These scripts deploy individual contracts and can be called sequentially
// by the deploy-ordered.js script. Each script reads required addresses from
// environment variables set by previous deployments.

// Phase 1: Tokens & Compliance
contract DeployStableToken is Script {
    function run() public {
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        vm.startBroadcast();
        StableToken token = new StableToken(admin);
        console.log("StableToken deployed at:", address(token));
        vm.stopBroadcast();
    }
}

contract DeployWKRW is Script {
    function run() public {
        vm.startBroadcast();
        WKRW wkrw = new WKRW();
        console.log("WKRW deployed at:", address(wkrw));
        vm.stopBroadcast();
    }
}

contract DeployKYCRegistry is Script {
    function run() public {
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        vm.startBroadcast();
        KYCRegistry registry = new KYCRegistry(admin);
        console.log("KYCRegistry deployed at:", address(registry));
        vm.stopBroadcast();
    }
}

contract DeployRegulatoryRegistry is Script {
    function run() public {
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        address[] memory approvers = new address[](3);
        approvers[0] = vm.envOr("APPROVER_1", admin);
        approvers[1] = vm.envOr("APPROVER_2", address(uint160(uint256(keccak256("approver2")))));
        approvers[2] = vm.envOr("APPROVER_3", address(uint160(uint256(keccak256("approver3")))));
        vm.startBroadcast();
        RegulatoryRegistry registry = new RegulatoryRegistry(approvers);
        console.log("RegulatoryRegistry deployed at:", address(registry));
        vm.stopBroadcast();
    }
}

contract DeployAuditLogger is Script {
    uint256 constant DEFAULT_RETENTION_PERIOD = 365 days;
    
    function run() public {
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        uint256 retentionPeriod = vm.envOr("RETENTION_PERIOD", DEFAULT_RETENTION_PERIOD);
        vm.startBroadcast();
        AuditLogger logger = new AuditLogger(admin, retentionPeriod);
        console.log("AuditLogger deployed at:", address(logger));
        vm.stopBroadcast();
    }
}

contract DeployProofOfReserve is Script {
    uint256 constant DEFAULT_AUTO_PAUSE_THRESHOLD = 3;
    
    function run() public {
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        uint256 autoPauseThreshold = vm.envOr("AUTO_PAUSE_THRESHOLD", DEFAULT_AUTO_PAUSE_THRESHOLD);
        vm.startBroadcast();
        ProofOfReserve por = new ProofOfReserve(admin, autoPauseThreshold);
        console.log("ProofOfReserve deployed at:", address(por));
        vm.stopBroadcast();
    }
}

// Phase 2: Utilities
contract DeployPriceOracle is Script {
    function run() public {
        vm.startBroadcast();
        PriceOracle oracle = new PriceOracle();
        console.log("PriceOracle deployed at:", address(oracle));
        vm.stopBroadcast();
    }
}

contract DeployDEXIntegration is Script {
    function run() public {
        address swapRouter = vm.envOr("SWAP_ROUTER", address(0));
        address quoter = vm.envOr("QUOTER", address(0));
        address wkrwAddr = vm.envOr("WKRW_ADDRESS", address(0));
        
        if (swapRouter == address(0) || quoter == address(0) || wkrwAddr == address(0)) {
            revert("SWAP_ROUTER, QUOTER, and WKRW_ADDRESS are required");
        }
        
        vm.startBroadcast();
        DEXIntegration dex = new DEXIntegration(swapRouter, quoter, wkrwAddr);
        console.log("DEXIntegration deployed at:", address(dex));
        vm.stopBroadcast();
    }
}

contract DeployERC6538Registry is Script {
    function run() public {
        vm.startBroadcast();
        ERC6538Registry registry = new ERC6538Registry();
        console.log("ERC6538Registry deployed at:", address(registry));
        vm.stopBroadcast();
    }
}

contract DeployERC5564Announcer is Script {
    function run() public {
        vm.startBroadcast();
        ERC5564Announcer announcer = new ERC5564Announcer();
        console.log("ERC5564Announcer deployed at:", address(announcer));
        vm.stopBroadcast();
    }
}

// Phase 3: Privacy & Subscription
contract DeployPrivateBank is Script {
    function run() public {
        address announcer = vm.envOr("ERC5564_ANNOUNCER_ADDRESS", address(0));
        address registry = vm.envOr("ERC6538_REGISTRY_ADDRESS", address(0));
        
        if (announcer == address(0) || registry == address(0)) {
            revert("ERC5564_ANNOUNCER_ADDRESS and ERC6538_REGISTRY_ADDRESS are required");
        }
        
        vm.startBroadcast();
        PrivateBank bank = new PrivateBank(announcer, registry);
        console.log("PrivateBank deployed at:", address(bank));
        vm.stopBroadcast();
    }
}

contract DeployPermissionManager is Script {
    function run() public {
        vm.startBroadcast();
        ERC7715PermissionManager manager = new ERC7715PermissionManager();
        console.log("ERC7715PermissionManager deployed at:", address(manager));
        vm.stopBroadcast();
    }
}

contract DeploySubscriptionManager is Script {
    function run() public {
        address permissionManager = vm.envOr("PERMISSION_MANAGER_ADDRESS", address(0));
        
        if (permissionManager == address(0)) {
            revert("PERMISSION_MANAGER_ADDRESS is required");
        }
        
        vm.startBroadcast();
        SubscriptionManager manager = new SubscriptionManager(permissionManager);
        console.log("SubscriptionManager deployed at:", address(manager));
        vm.stopBroadcast();
    }
}

// Phase 4: Bridge
contract DeployBridgeValidator is Script {
    uint256 constant DEFAULT_SIGNER_THRESHOLD = 2;
    
    function run() public {
        address[] memory signers = _parseAddresses(vm.envOr("BRIDGE_SIGNERS", string("")));
        if (signers.length == 0) {
            address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
            signers = _defaultAddresses(admin, "signer", 3);
        }
        uint256 threshold = vm.envOr("SIGNER_THRESHOLD", DEFAULT_SIGNER_THRESHOLD);
        
        vm.startBroadcast();
        BridgeValidator validator = new BridgeValidator(signers, threshold);
        console.log("BridgeValidator deployed at:", address(validator));
        vm.stopBroadcast();
    }
    
    function _parseAddresses(string memory input) internal pure returns (address[] memory parsed) {
        bytes memory inputBytes = bytes(input);
        if (inputBytes.length == 0) {
            return new address[](0);
        }
        uint256 segments = 1;
        for (uint256 i = 0; i < inputBytes.length; i++) {
            if (inputBytes[i] == ",") segments++;
        }
        parsed = new address[](segments);
        uint256 index;
        uint256 start;
        for (uint256 i = 0; i <= inputBytes.length; i++) {
            if (i == inputBytes.length || inputBytes[i] == ",") {
                string memory part = _trim(_substring(input, start, i));
                if (bytes(part).length != 0) {
                    parsed[index] = vm.parseAddress(part);
                    index++;
                }
                start = i + 1;
            }
        }
        assembly {
            mstore(parsed, index)
        }
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
    
    function _substring(string memory str, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (end <= start) return "";
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
        while (start < strBytes.length && strBytes[start] == 0x20) start++;
        while (end > start && strBytes[end - 1] == 0x20) end--;
        if (end <= start) return "";
        bytes memory result = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            result[i] = strBytes[start + i];
        }
        return string(result);
    }
}

contract DeployBridgeGuardian is Script {
    uint256 constant DEFAULT_GUARDIAN_THRESHOLD = 2;
    
    function run() public {
        address[] memory guardians = _parseAddresses(vm.envOr("BRIDGE_GUARDIANS", string("")));
        if (guardians.length == 0) {
            address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
            guardians = _defaultAddresses(admin, "guardian", 3);
        }
        uint256 threshold = vm.envOr("GUARDIAN_THRESHOLD", DEFAULT_GUARDIAN_THRESHOLD);
        
        vm.startBroadcast();
        BridgeGuardian guardian = new BridgeGuardian(guardians, threshold);
        console.log("BridgeGuardian deployed at:", address(guardian));
        vm.stopBroadcast();
    }
    
    function _parseAddresses(string memory input) internal pure returns (address[] memory parsed) {
        bytes memory inputBytes = bytes(input);
        if (inputBytes.length == 0) return new address[](0);
        uint256 segments = 1;
        for (uint256 i = 0; i < inputBytes.length; i++) {
            if (inputBytes[i] == ",") segments++;
        }
        parsed = new address[](segments);
        uint256 index;
        uint256 start;
        for (uint256 i = 0; i <= inputBytes.length; i++) {
            if (i == inputBytes.length || inputBytes[i] == ",") {
                string memory part = _trim(_substring(input, start, i));
                if (bytes(part).length != 0) {
                    parsed[index] = vm.parseAddress(part);
                    index++;
                }
                start = i + 1;
            }
        }
        assembly {
            mstore(parsed, index)
        }
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
    
    function _substring(string memory str, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (end <= start) return "";
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
        while (start < strBytes.length && strBytes[start] == 0x20) start++;
        while (end > start && strBytes[end - 1] == 0x20) end--;
        if (end <= start) return "";
        bytes memory result = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            result[i] = strBytes[start + i];
        }
        return string(result);
    }
}

contract DeployBridgeRateLimiter is Script {
    function run() public {
        vm.startBroadcast();
        BridgeRateLimiter limiter = new BridgeRateLimiter();
        console.log("BridgeRateLimiter deployed at:", address(limiter));
        vm.stopBroadcast();
    }
}

contract DeployOptimisticVerifier is Script {
    uint256 constant DEFAULT_CHALLENGE_PERIOD = 1 days;
    uint256 constant DEFAULT_CHALLENGE_BOND = 1 ether;
    uint256 constant DEFAULT_CHALLENGER_REWARD = 0.5 ether;
    
    function run() public {
        vm.startBroadcast();
        OptimisticVerifier verifier = new OptimisticVerifier(
            DEFAULT_CHALLENGE_PERIOD,
            DEFAULT_CHALLENGE_BOND,
            DEFAULT_CHALLENGER_REWARD
        );
        console.log("OptimisticVerifier deployed at:", address(verifier));
        vm.stopBroadcast();
    }
}

contract DeployFraudProofVerifier is Script {
    function run() public {
        vm.startBroadcast();
        FraudProofVerifier verifier = new FraudProofVerifier();
        console.log("FraudProofVerifier deployed at:", address(verifier));
        vm.stopBroadcast();
    }
}

contract DeploySecureBridge is Script {
    function run() public {
        address validator = vm.envOr("BRIDGE_VALIDATOR_ADDRESS", address(0));
        address optimisticVerifier = vm.envOr("OPTIMISTIC_VERIFIER_ADDRESS", address(0));
        address rateLimiter = vm.envOr("BRIDGE_RATE_LIMITER_ADDRESS", address(0));
        address guardian = vm.envOr("BRIDGE_GUARDIAN_ADDRESS", address(0));
        address fraudVerifier = vm.envOr("FRAUD_PROOF_VERIFIER_ADDRESS", address(0));
        address feeRecipient = vm.envOr("FEE_RECIPIENT", msg.sender);
        
        if (validator == address(0) || optimisticVerifier == address(0) || 
            rateLimiter == address(0) || guardian == address(0) || fraudVerifier == address(0)) {
            revert("All bridge component addresses are required");
        }
        
        vm.startBroadcast();
        SecureBridge bridge = new SecureBridge(
            validator,
            payable(optimisticVerifier),
            rateLimiter,
            guardian,
            feeRecipient
        );
        console.log("SecureBridge deployed at:", address(bridge));
        
        // Wire dependencies
        OptimisticVerifier(payable(optimisticVerifier)).setFraudProofVerifier(fraudVerifier);
        OptimisticVerifier(payable(optimisticVerifier)).setAuthorizedCaller(address(bridge), true);
        FraudProofVerifier(fraudVerifier).setOptimisticVerifier(optimisticVerifier);
        FraudProofVerifier(fraudVerifier).setBridgeValidator(validator);
        BridgeRateLimiter(rateLimiter).setAuthorizedCaller(address(bridge), true);
        BridgeGuardian(guardian).setBridgeTarget(address(bridge));
        
        vm.stopBroadcast();
    }
}

// Phase 5: ERC-4337
contract DeployEntryPoint is Script {
    function run() public {
        vm.startBroadcast();
        EntryPoint entryPoint = new EntryPoint();
        console.log("EntryPoint deployed at:", address(entryPoint));
        vm.stopBroadcast();
    }
}

contract DeployVerifyingPaymaster is Script {
    function run() public {
        address entryPointAddr = vm.envOr("ENTRYPOINT_ADDRESS", address(0));
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        address signer = vm.envOr("VERIFYING_SIGNER", msg.sender);
        
        if (entryPointAddr == address(0)) {
            revert("ENTRYPOINT_ADDRESS is required");
        }
        
        vm.startBroadcast();
        VerifyingPaymaster paymaster = new VerifyingPaymaster(
            IEntryPoint(entryPointAddr),
            admin,
            signer
        );
        console.log("VerifyingPaymaster deployed at:", address(paymaster));
        vm.stopBroadcast();
    }
}

contract DeployERC20Paymaster is Script {
    uint256 constant DEFAULT_MARKUP = 1000; // 10%
    
    function run() public {
        address entryPointAddr = vm.envOr("ENTRYPOINT_ADDRESS", address(0));
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        address oracleAddr = vm.envOr("PRICE_ORACLE_ADDRESS", address(0));
        uint256 markup = vm.envOr("MARKUP", DEFAULT_MARKUP);
        
        if (entryPointAddr == address(0) || oracleAddr == address(0)) {
            revert("ENTRYPOINT_ADDRESS and PRICE_ORACLE_ADDRESS are required");
        }
        
        vm.startBroadcast();
        ERC20Paymaster paymaster = new ERC20Paymaster(
            IEntryPoint(entryPointAddr),
            admin,
            IPriceOracle(oracleAddr),
            markup
        );
        console.log("ERC20Paymaster deployed at:", address(paymaster));
        vm.stopBroadcast();
    }
}

contract DeployPermit2Paymaster is Script {
    uint256 constant DEFAULT_MARKUP = 1000; // 10%
    
    function run() public {
        address entryPointAddr = vm.envOr("ENTRYPOINT_ADDRESS", address(0));
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        address permit2Addr = vm.envOr("PERMIT2_ADDRESS", address(0));
        address oracleAddr = vm.envOr("PRICE_ORACLE_ADDRESS", address(0));
        uint256 markup = vm.envOr("MARKUP", DEFAULT_MARKUP);
        
        if (entryPointAddr == address(0) || permit2Addr == address(0) || oracleAddr == address(0)) {
            revert("ENTRYPOINT_ADDRESS, PERMIT2_ADDRESS, and PRICE_ORACLE_ADDRESS are required");
        }
        
        vm.startBroadcast();
        Permit2Paymaster paymaster = new Permit2Paymaster(
            IEntryPoint(entryPointAddr),
            admin,
            IPermit2(permit2Addr),
            IPriceOracle(oracleAddr),
            markup
        );
        console.log("Permit2Paymaster deployed at:", address(paymaster));
        vm.stopBroadcast();
    }
}

contract DeploySponsorPaymaster is Script {
    function run() public {
        address entryPointAddr = vm.envOr("ENTRYPOINT_ADDRESS", address(0));
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        address signer = vm.envOr("VERIFYING_SIGNER", msg.sender);
        
        if (entryPointAddr == address(0)) {
            revert("ENTRYPOINT_ADDRESS is required");
        }
        
        vm.startBroadcast();
        SponsorPaymaster paymaster = new SponsorPaymaster(
            IEntryPoint(entryPointAddr),
            admin,
            signer
        );
        console.log("SponsorPaymaster deployed at:", address(paymaster));
        vm.stopBroadcast();
    }
}

// Phase 6: ERC-7579
contract DeployKernel is Script {
    function run() public {
        address entryPointAddr = vm.envOr("ENTRYPOINT_ADDRESS", address(0));
        
        if (entryPointAddr == address(0)) {
            revert("ENTRYPOINT_ADDRESS is required");
        }
        
        vm.startBroadcast();
        Kernel kernel = new Kernel(IKernelEntryPoint(entryPointAddr));
        console.log("Kernel deployed at:", address(kernel));
        vm.stopBroadcast();
    }
}

contract DeployKernelFactory is Script {
    function run() public {
        address kernelAddr = vm.envOr("KERNEL_ADDRESS", address(0));
        
        if (kernelAddr == address(0)) {
            revert("KERNEL_ADDRESS is required");
        }
        
        vm.startBroadcast();
        KernelFactory factory = new KernelFactory(kernelAddr);
        console.log("KernelFactory deployed at:", address(factory));
        vm.stopBroadcast();
    }
}

contract DeployFactoryStaker is Script {
    function run() public {
        address factoryAddr = vm.envOr("KERNEL_FACTORY_ADDRESS", address(0));
        
        if (factoryAddr == address(0)) {
            revert("KERNEL_FACTORY_ADDRESS is required");
        }
        
        vm.startBroadcast();
        FactoryStaker staker = new FactoryStaker(factoryAddr);
        console.log("FactoryStaker deployed at:", address(staker));
        vm.stopBroadcast();
    }
}

contract DeployECDSAValidator is Script {
    function run() public {
        vm.startBroadcast();
        ECDSAValidator validator = new ECDSAValidator();
        console.log("ECDSAValidator deployed at:", address(validator));
        vm.stopBroadcast();
    }
}

contract DeployWeightedValidator is Script {
    function run() public {
        vm.startBroadcast();
        WeightedECDSAValidator validator = new WeightedECDSAValidator();
        console.log("WeightedECDSAValidator deployed at:", address(validator));
        vm.stopBroadcast();
    }
}

contract DeployMultiChainValidator is Script {
    function run() public {
        vm.startBroadcast();
        MultiChainValidator validator = new MultiChainValidator();
        console.log("MultiChainValidator deployed at:", address(validator));
        vm.stopBroadcast();
    }
}

contract DeploySessionKeyExecutor is Script {
    function run() public {
        vm.startBroadcast();
        SessionKeyExecutor executor = new SessionKeyExecutor();
        console.log("SessionKeyExecutor deployed at:", address(executor));
        vm.stopBroadcast();
    }
}

contract DeployRecurringPaymentExecutor is Script {
    function run() public {
        vm.startBroadcast();
        RecurringPaymentExecutor executor = new RecurringPaymentExecutor();
        console.log("RecurringPaymentExecutor deployed at:", address(executor));
        vm.stopBroadcast();
    }
}

contract DeployAuditHook is Script {
    function run() public {
        vm.startBroadcast();
        AuditHook hook = new AuditHook();
        console.log("AuditHook deployed at:", address(hook));
        vm.stopBroadcast();
    }
}

contract DeploySpendingLimitHook is Script {
    function run() public {
        vm.startBroadcast();
        SpendingLimitHook hook = new SpendingLimitHook();
        console.log("SpendingLimitHook deployed at:", address(hook));
        vm.stopBroadcast();
    }
}

contract DeployTokenReceiverFallback is Script {
    function run() public {
        vm.startBroadcast();
        TokenReceiverFallback tokenReceiver = new TokenReceiverFallback();
        console.log("TokenReceiverFallback deployed at:", address(tokenReceiver));
        vm.stopBroadcast();
    }
}

contract DeployFlashLoanFallback is Script {
    function run() public {
        vm.startBroadcast();
        FlashLoanFallback flashLoan = new FlashLoanFallback();
        console.log("FlashLoanFallback deployed at:", address(flashLoan));
        vm.stopBroadcast();
    }
}

contract DeployAutoSwapPlugin is Script {
    function run() public {
        address oracleAddr = vm.envOr("PRICE_ORACLE_ADDRESS", address(0));
        address swapRouter = vm.envOr("SWAP_ROUTER", address(0));
        
        if (oracleAddr == address(0) || swapRouter == address(0)) {
            revert("PRICE_ORACLE_ADDRESS and SWAP_ROUTER are required");
        }
        
        vm.startBroadcast();
        AutoSwapPlugin plugin = new AutoSwapPlugin(
            IPriceOracle(oracleAddr),
            swapRouter
        );
        console.log("AutoSwapPlugin deployed at:", address(plugin));
        vm.stopBroadcast();
    }
}

contract DeployMicroLoanPlugin is Script {
    function run() public {
        address oracleAddr = vm.envOr("PRICE_ORACLE_ADDRESS", address(0));
        address feeRecipient = vm.envOr("FEE_RECIPIENT", msg.sender);
        uint256 protocolFeeBps = vm.envOr("PROTOCOL_FEE_BPS", uint256(50));
        uint256 liquidationBonusBps = vm.envOr("LIQUIDATION_BONUS_BPS", uint256(500));
        
        if (oracleAddr == address(0)) {
            revert("PRICE_ORACLE_ADDRESS is required");
        }
        
        vm.startBroadcast();
        MicroLoanPlugin plugin = new MicroLoanPlugin(
            IPriceOracle(oracleAddr),
            feeRecipient,
            protocolFeeBps,
            liquidationBonusBps
        );
        console.log("MicroLoanPlugin deployed at:", address(plugin));
        vm.stopBroadcast();
    }
}
