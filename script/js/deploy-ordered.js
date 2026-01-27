#!/usr/bin/env node

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

// ============ Project Root Path ============
// 스크립트가 어디서 실행되든 프로젝트 루트를 정확히 찾음
const PROJECT_ROOT = (() => {
    // 스크립트 파일의 위치에서 프로젝트 루트 찾기
    const scriptDir = __dirname; // script/js/
    const projectRoot = path.resolve(scriptDir, "..", "..");
    
    // 프로젝트 루트 확인 (foundry.toml 또는 package.json 존재 확인)
    const foundryToml = path.join(projectRoot, "foundry.toml");
    const packageJson = path.join(projectRoot, "package.json");
    
    if (fs.existsSync(foundryToml) || fs.existsSync(packageJson)) {
        return projectRoot;
    }
    
    // 환경 변수로 프로젝트 루트 지정 가능
    if (process.env.PROJECT_ROOT) {
        const customRoot = path.resolve(process.env.PROJECT_ROOT);
        if (fs.existsSync(customRoot)) {
            return customRoot;
        }
    }
    
    // 현재 작업 디렉토리에서 찾기
    let currentDir = process.cwd();
    while (currentDir !== path.dirname(currentDir)) {
        const foundryToml = path.join(currentDir, "foundry.toml");
        const packageJson = path.join(currentDir, "package.json");
        if (fs.existsSync(foundryToml) || fs.existsSync(packageJson)) {
            return currentDir;
        }
        currentDir = path.dirname(currentDir);
    }
    
    // 기본값: 스크립트 디렉토리의 상위
    return projectRoot;
})();

// 프로젝트 루트 경로 출력 (디버깅용)
if (process.env.DEBUG) {
    console.log(`[DEBUG] Project root: ${PROJECT_ROOT}`);
}

// ============ Path Helpers ============
function getProjectPath(...segments) {
    return path.join(PROJECT_ROOT, ...segments);
}

function getAbsolutePath(filePath) {
    if (path.isAbsolute(filePath)) {
        return filePath;
    }
    return path.resolve(PROJECT_ROOT, filePath);
}

// .env 파일 경로
const envPath = getProjectPath(".env");
require("dotenv").config({ path: envPath });

const NETWORKS = {
    local: {
        rpcUrl: process.env.RPC_URL_LOCAL || "http://localhost:8545",
        chainId: 31337,
        verify: false,
    },
    sepolia: {
        rpcUrl: process.env.RPC_URL_SEPOLIA,
        chainId: 11155111,
        verify: true,
    },
    "stablenet-testnet": {
        rpcUrl: process.env.RPC_URL_STABLENET_TESTNET,
        chainId: 8283,
        verify: true,
    },
    stablenet: {
        rpcUrl: process.env.RPC_URL_STABLENET,
        chainId: 8282,
        verify: true,
    },
};

// 배포 단계 정의 - 각 단계는 개별 forge script를 실행
// target은 프로젝트 루트 기준 상대 경로로 지정 (절대 경로로 자동 변환됨)
const DEPLOYMENT_STEPS = [
    // Phase 1: 기본 토큰·컴플라이언스 레지스트리
    {
        id: "usdc",
        label: "USDC",
        target: "script/DeployOrdered.s.sol:DeployUSDC", // 프로젝트 루트 기준
        extractAddress: (output) => extractAddress(output, "USDC"),
    },
    {
        id: "wkrc",
        label: "wKRC",
        target: "script/DeployOrdered.s.sol:DeploywKRC",
        extractAddress: (output) => extractAddress(output, "wKRC"),
    },
    {
        id: "kycRegistry",
        label: "KYCRegistry",
        target: "script/DeployOrdered.s.sol:DeployKYCRegistry",
        extractAddress: (output) => extractAddress(output, "KYCRegistry"),
    },
    {
        id: "regulatoryRegistry",
        label: "RegulatoryRegistry",
        target: "script/DeployOrdered.s.sol:DeployRegulatoryRegistry",
        extractAddress: (output) => extractAddress(output, "RegulatoryRegistry"),
    },
    {
        id: "auditLogger",
        label: "AuditLogger",
        target: "script/DeployOrdered.s.sol:DeployAuditLogger",
        extractAddress: (output) => extractAddress(output, "AuditLogger"),
    },
    {
        id: "proofOfReserve",
        label: "ProofOfReserve",
        target: "script/DeployOrdered.s.sol:DeployProofOfReserve",
        extractAddress: (output) => extractAddress(output, "ProofOfReserve"),
    },
    
    // Phase 2: 유틸리티
    {
        id: "priceOracle",
        label: "PriceOracle",
        target: "script/DeployOrdered.s.sol:DeployPriceOracle",
        extractAddress: (output) => extractAddress(output, "PriceOracle"),
    },
    {
        id: "dexIntegration",
        label: "DEXIntegration",
        target: "script/DeployOrdered.s.sol:DeployDEXIntegration",
        extractAddress: (output) => extractAddress(output, "DEXIntegration"),
        optional: true,
        requires: ["wkrc", "priceOracle"],
    },
    {
        id: "erc6538Registry",
        label: "ERC6538Registry",
        target: "script/DeployOrdered.s.sol:DeployERC6538Registry",
        extractAddress: (output) => extractAddress(output, "ERC6538Registry"),
    },
    {
        id: "erc5564Announcer",
        label: "ERC5564Announcer",
        target: "script/DeployOrdered.s.sol:DeployERC5564Announcer",
        extractAddress: (output) => extractAddress(output, "ERC5564Announcer"),
    },
    
    // Phase 3: 프라이버시·구독
    {
        id: "privateBank",
        label: "PrivateBank",
        target: "script/DeployOrdered.s.sol:DeployPrivateBank",
        extractAddress: (output) => extractAddress(output, "PrivateBank"),
        requires: ["erc5564Announcer", "erc6538Registry"],
    },
    {
        id: "permissionManager",
        label: "ERC7715PermissionManager",
        target: "script/DeployOrdered.s.sol:DeployPermissionManager",
        extractAddress: (output) => extractAddress(output, "ERC7715PermissionManager"),
    },
    {
        id: "subscriptionManager",
        label: "SubscriptionManager",
        target: "script/DeployOrdered.s.sol:DeploySubscriptionManager",
        extractAddress: (output) => extractAddress(output, "SubscriptionManager"),
        requires: ["permissionManager"],
    },
    
    // Phase 4: 브리지
    {
        id: "bridgeValidator",
        label: "BridgeValidator",
        target: "script/DeployOrdered.s.sol:DeployBridgeValidator",
        extractAddress: (output) => extractAddress(output, "BridgeValidator"),
    },
    {
        id: "bridgeGuardian",
        label: "BridgeGuardian",
        target: "script/DeployOrdered.s.sol:DeployBridgeGuardian",
        extractAddress: (output) => extractAddress(output, "BridgeGuardian"),
    },
    {
        id: "bridgeRateLimiter",
        label: "BridgeRateLimiter",
        target: "script/DeployOrdered.s.sol:DeployBridgeRateLimiter",
        extractAddress: (output) => extractAddress(output, "BridgeRateLimiter"),
    },
    {
        id: "optimisticVerifier",
        label: "OptimisticVerifier",
        target: "script/DeployOrdered.s.sol:DeployOptimisticVerifier",
        extractAddress: (output) => extractAddress(output, "OptimisticVerifier"),
    },
    {
        id: "fraudProofVerifier",
        label: "FraudProofVerifier",
        target: "script/DeployOrdered.s.sol:DeployFraudProofVerifier",
        extractAddress: (output) => extractAddress(output, "FraudProofVerifier"),
    },
    {
        id: "secureBridge",
        label: "SecureBridge",
        target: "script/DeployOrdered.s.sol:DeploySecureBridge",
        extractAddress: (output) => extractAddress(output, "SecureBridge"),
        requires: ["bridgeValidator", "bridgeGuardian", "bridgeRateLimiter", "optimisticVerifier", "fraudProofVerifier"],
    },
    
    // Phase 5: ERC-4337
    {
        id: "entryPoint",
        label: "EntryPoint",
        target: "script/DeployOrdered.s.sol:DeployEntryPoint",
        extractAddress: (output) => extractAddress(output, "EntryPoint"),
    },
    {
        id: "verifyingPaymaster",
        label: "VerifyingPaymaster",
        target: "script/DeployOrdered.s.sol:DeployVerifyingPaymaster",
        extractAddress: (output) => extractAddress(output, "VerifyingPaymaster"),
        requires: ["entryPoint"],
    },
    {
        id: "erc20Paymaster",
        label: "ERC20Paymaster",
        target: "script/DeployOrdered.s.sol:DeployERC20Paymaster",
        extractAddress: (output) => extractAddress(output, "ERC20Paymaster"),
        requires: ["entryPoint", "priceOracle"],
    },
    {
        id: "permit2Paymaster",
        label: "Permit2Paymaster",
        target: "script/DeployOrdered.s.sol:DeployPermit2Paymaster",
        extractAddress: (output) => extractAddress(output, "Permit2Paymaster"),
        requires: ["entryPoint", "priceOracle"],
        optional: true,
    },
    {
        id: "sponsorPaymaster",
        label: "SponsorPaymaster",
        target: "script/DeployOrdered.s.sol:DeploySponsorPaymaster",
        extractAddress: (output) => extractAddress(output, "SponsorPaymaster"),
        requires: ["entryPoint"],
    },
    
    // Phase 6: ERC-7579
    {
        id: "kernel",
        label: "Kernel",
        target: "script/DeployOrdered.s.sol:DeployKernel",
        extractAddress: (output) => extractAddress(output, "Kernel"),
        requires: ["entryPoint"],
    },
    {
        id: "kernelFactory",
        label: "KernelFactory",
        target: "script/DeployOrdered.s.sol:DeployKernelFactory",
        extractAddress: (output) => extractAddress(output, "KernelFactory"),
        requires: ["kernel"],
    },
    {
        id: "factoryStaker",
        label: "FactoryStaker",
        target: "script/DeployOrdered.s.sol:DeployFactoryStaker",
        extractAddress: (output) => extractAddress(output, "FactoryStaker"),
        requires: ["kernelFactory"],
    },
    {
        id: "ecdsaValidator",
        label: "ECDSAValidator",
        target: "script/DeployOrdered.s.sol:DeployECDSAValidator",
        extractAddress: (output) => extractAddress(output, "ECDSAValidator"),
    },
    {
        id: "weightedValidator",
        label: "WeightedECDSAValidator",
        target: "script/DeployOrdered.s.sol:DeployWeightedValidator",
        extractAddress: (output) => extractAddress(output, "WeightedECDSAValidator"),
    },
    {
        id: "multiChainValidator",
        label: "MultiChainValidator",
        target: "script/DeployOrdered.s.sol:DeployMultiChainValidator",
        extractAddress: (output) => extractAddress(output, "MultiChainValidator"),
    },
    {
        id: "sessionKeyExecutor",
        label: "SessionKeyExecutor",
        target: "script/DeployOrdered.s.sol:DeploySessionKeyExecutor",
        extractAddress: (output) => extractAddress(output, "SessionKeyExecutor"),
    },
    {
        id: "recurringPaymentExecutor",
        label: "RecurringPaymentExecutor",
        target: "script/DeployOrdered.s.sol:DeployRecurringPaymentExecutor",
        extractAddress: (output) => extractAddress(output, "RecurringPaymentExecutor"),
    },
    {
        id: "auditHook",
        label: "AuditHook",
        target: "script/DeployOrdered.s.sol:DeployAuditHook",
        extractAddress: (output) => extractAddress(output, "AuditHook"),
    },
    {
        id: "spendingLimitHook",
        label: "SpendingLimitHook",
        target: "script/DeployOrdered.s.sol:DeploySpendingLimitHook",
        extractAddress: (output) => extractAddress(output, "SpendingLimitHook"),
    },
    {
        id: "tokenReceiverFallback",
        label: "TokenReceiverFallback",
        target: "script/DeployOrdered.s.sol:DeployTokenReceiverFallback",
        extractAddress: (output) => extractAddress(output, "TokenReceiverFallback"),
    },
    {
        id: "flashLoanFallback",
        label: "FlashLoanFallback",
        target: "script/DeployOrdered.s.sol:DeployFlashLoanFallback",
        extractAddress: (output) => extractAddress(output, "FlashLoanFallback"),
    },
    {
        id: "autoSwapPlugin",
        label: "AutoSwapPlugin",
        target: "script/DeployOrdered.s.sol:DeployAutoSwapPlugin",
        extractAddress: (output) => extractAddress(output, "AutoSwapPlugin"),
        requires: ["priceOracle"],
        optional: true,
    },
    {
        id: "microLoanPlugin",
        label: "MicroLoanPlugin",
        target: "script/DeployOrdered.s.sol:DeployMicroLoanPlugin",
        extractAddress: (output) => extractAddress(output, "MicroLoanPlugin"),
        requires: ["priceOracle"],
    },
];

// 배포된 주소 저장소
const deployedAddresses = {};

function extractAddress(output, contractName) {
    const patterns = [
        new RegExp(`${contractName}\\s+deployed\\s+at:\\s+(0x[a-fA-F0-9]{40})`, "i"),
        new RegExp(`${contractName}:\\s+(0x[a-fA-F0-9]{40})`, "i"),
        new RegExp(`${contractName}\\s+deployed\\s+to:\\s+(0x[a-fA-F0-9]{40})`, "i"),
        new RegExp(`Deployed\\s+${contractName}\\s+at\\s+(0x[a-fA-F0-9]{40})`, "i"),
    ];
    
    for (const pattern of patterns) {
        const match = output.match(pattern);
        if (match) {
            return match[1];
        }
    }
    
    // Try generic pattern
    const genericPattern = /(0x[a-fA-F0-9]{40})/g;
    const matches = output.match(genericPattern);
    if (matches && matches.length > 0) {
        // Return the last address (usually the deployed contract)
        return matches[matches.length - 1];
    }
    
    return null;
}

function validateEnvironment(networkKey) {
    const config = NETWORKS[networkKey];
    
    if (!config) {
        throw new Error(`Unknown network "${networkKey}". Available: ${Object.keys(NETWORKS).join(", ")}`);
    }
    
    if (!config.rpcUrl) {
        throw new Error(`RPC URL not configured for network "${networkKey}"`);
    }
    
    if (!process.env.PRIVATE_KEY) {
        throw new Error("PRIVATE_KEY not set in environment/.env file");
    }
    
    return config;
}

function formatCommand(target, config, envVars = {}) {
    // target은 "script/DeployOrdered.s.sol:DeployUSDC" 형식
    // forge script는 프로젝트 루트에서 실행되므로 상대 경로 그대로 사용
    // 단, 절대 경로가 제공되면 그대로 사용
    let scriptTarget = target;
    if (path.isAbsolute(target.split(":")[0])) {
        // 절대 경로인 경우, 프로젝트 루트 기준 상대 경로로 변환 시도
        const absolutePath = target.split(":")[0];
        const relativePath = path.relative(PROJECT_ROOT, absolutePath);
        if (!relativePath.startsWith("..")) {
            scriptTarget = relativePath + (target.includes(":") ? ":" + target.split(":")[1] : "");
        }
    }
    
    const args = [
        "forge",
        "script",
        scriptTarget,
        "--rpc-url",
        config.rpcUrl,
        "--private-key",
        process.env.PRIVATE_KEY,
        "--broadcast",
    ];
    
    if (config.verify && process.env.EXPLORER_API_KEY) {
        args.push("--verify", "--etherscan-api-key", process.env.EXPLORER_API_KEY);
    }
    
    // Add environment variables
    const env = { 
        ...process.env, 
        ...envVars,
        PROJECT_ROOT: PROJECT_ROOT, // 프로젝트 루트를 환경 변수로 전달
    };
    
    return { command: args.join(" "), env };
}

function checkDependencies(step, deployedSet) {
    if (!step.requires) return true;
    
    const missing = step.requires.filter((dep) => !deployedSet.has(dep));
    if (missing.length) {
        throw new Error(
            `Step "${step.id}" requires steps [${missing.join(", ")}] to be executed first.`
        );
    }
    return true;
}

function buildEnvVars(step) {
    const env = {};
    
    // 기본 환경 변수 전달 (사용자가 .env에 설정한 것들만)
    const passthroughVars = [
        "ADMIN_ADDRESS",
        "VERIFYING_SIGNER", 
        "FEE_RECIPIENT",
        "SWAP_ROUTER",
        "QUOTER",
        "PERMIT2_ADDRESS",
        "BRIDGE_SIGNERS",
        "BRIDGE_GUARDIANS",
        "SIGNER_THRESHOLD",
        "GUARDIAN_THRESHOLD",
        "RETENTION_PERIOD",
        "AUTO_PAUSE_THRESHOLD",
        "APPROVER_1",
        "APPROVER_2",
        "APPROVER_3",
        "MARKUP",
        "PROTOCOL_FEE_BPS",
        "LIQUIDATION_BONUS_BPS",
    ];
    
    passthroughVars.forEach((key) => {
        if (process.env[key]) {
            env[key] = process.env[key];
        }
    });
    
    // 의존성 주소 자동 전달 - 모든 requires에 대해 자동으로 매핑
    if (step.requires) {
        step.requires.forEach((depId) => {
            const address = deployedAddresses[depId];
            if (address) {
                const envVarName = getEnvVarName(depId);
                if (envVarName) {
                    env[envVarName] = address;
                    console.log(`  Auto-setting ${envVarName}=${address} from ${depId}`);
                }
            } else {
                console.warn(`  Warning: Required dependency "${depId}" not found in deployed addresses`);
            }
        });
    }
    
    return env;
}

function getEnvVarName(stepId) {
    // 자동 매핑: stepId를 기반으로 환경 변수 이름 생성
    const mapping = {
        // Phase 1: Tokens & Compliance
        usdc: "USDC_ADDRESS",
        wkrc: "WKRC_ADDRESS",
        kycRegistry: "KYC_REGISTRY_ADDRESS",
        regulatoryRegistry: "REGULATORY_REGISTRY_ADDRESS",
        auditLogger: "AUDIT_LOGGER_ADDRESS",
        proofOfReserve: "PROOF_OF_RESERVE_ADDRESS",
        
        // Phase 2: Utilities
        priceOracle: "PRICE_ORACLE_ADDRESS",
        dexIntegration: "DEX_INTEGRATION_ADDRESS",
        erc6538Registry: "ERC6538_REGISTRY_ADDRESS",
        erc5564Announcer: "ERC5564_ANNOUNCER_ADDRESS",
        
        // Phase 3: Privacy & Subscription
        privateBank: "PRIVATE_BANK_ADDRESS",
        permissionManager: "PERMISSION_MANAGER_ADDRESS",
        subscriptionManager: "SUBSCRIPTION_MANAGER_ADDRESS",
        
        // Phase 4: Bridge
        bridgeValidator: "BRIDGE_VALIDATOR_ADDRESS",
        bridgeGuardian: "BRIDGE_GUARDIAN_ADDRESS",
        bridgeRateLimiter: "BRIDGE_RATE_LIMITER_ADDRESS",
        optimisticVerifier: "OPTIMISTIC_VERIFIER_ADDRESS",
        fraudProofVerifier: "FRAUD_PROOF_VERIFIER_ADDRESS",
        secureBridge: "SECURE_BRIDGE_ADDRESS",
        
        // Phase 5: ERC-4337
        entryPoint: "ENTRYPOINT_ADDRESS",
        verifyingPaymaster: "VERIFYING_PAYMASTER_ADDRESS",
        erc20Paymaster: "ERC20_PAYMASTER_ADDRESS",
        permit2Paymaster: "PERMIT2_PAYMASTER_ADDRESS",
        sponsorPaymaster: "SPONSOR_PAYMASTER_ADDRESS",
        
        // Phase 6: ERC-7579
        kernel: "KERNEL_ADDRESS",
        kernelFactory: "KERNEL_FACTORY_ADDRESS",
        factoryStaker: "FACTORY_STAKER_ADDRESS",
        ecdsaValidator: "ECDSA_VALIDATOR_ADDRESS",
        weightedValidator: "WEIGHTED_VALIDATOR_ADDRESS",
        multiChainValidator: "MULTICHAIN_VALIDATOR_ADDRESS",
        sessionKeyExecutor: "SESSION_KEY_EXECUTOR_ADDRESS",
        recurringPaymentExecutor: "RECURRING_PAYMENT_EXECUTOR_ADDRESS",
        auditHook: "AUDIT_HOOK_ADDRESS",
        spendingLimitHook: "SPENDING_LIMIT_HOOK_ADDRESS",
        tokenReceiverFallback: "TOKEN_RECEIVER_FALLBACK_ADDRESS",
        flashLoanFallback: "FLASH_LOAN_FALLBACK_ADDRESS",
        autoSwapPlugin: "AUTO_SWAP_PLUGIN_ADDRESS",
        microLoanPlugin: "MICRO_LOAN_PLUGIN_ADDRESS",
    };
    
    return mapping[stepId] || null;
}

function runStep(step, config) {
    console.log("\n" + "=".repeat(60));
    console.log(`Deploying: ${step.label} [${step.id}]`);
    console.log("=".repeat(60));
    
    const envVars = buildEnvVars(step);
    const { command, env } = formatCommand(step.target, config, envVars);
    
    console.log(`Command: ${command}`);
    if (Object.keys(envVars).length > 0) {
        console.log("Environment variables:");
        Object.entries(envVars).forEach(([key, value]) => {
            console.log(`  ${key}=${value}`);
        });
    }
    
    try {
        const output = execSync(command, {
            cwd: PROJECT_ROOT, // 프로젝트 루트에서 실행
            encoding: "utf8",
            stdio: "pipe",
            env,
        });
        
        console.log(output);
        
        const address = step.extractAddress(output);
        if (address) {
            deployedAddresses[step.id] = address;
            console.log(`\n✅ ${step.label} deployed at: ${address}`);
            return address;
        } else {
            console.log(`\n⚠️  Could not extract address for ${step.label}`);
            return null;
        }
    } catch (error) {
        if (error.output) {
            const stdout = error.output[1] ? error.output[1].toString() : "";
            const stderr = error.output[2] ? error.output[2].toString() : "";
            console.error(stdout);
            console.error(stderr);
            
            // Try to extract address even from error output
            const output = stdout + stderr;
            const address = step.extractAddress(output);
            if (address) {
                deployedAddresses[step.id] = address;
                console.log(`\n✅ ${step.label} deployed at: ${address} (extracted from error output)`);
                return address;
            }
        }
        
        if (step.optional) {
            console.log(`\n⚠️  Optional step "${step.id}" failed, continuing...`);
            return null;
        }
        
        throw error;
    }
}

function saveDeploymentAddresses(chainId) {
    const deploymentsDir = getProjectPath("deployments");
    const chainDir = getProjectPath("deployments", chainId.toString());
    
    if (!fs.existsSync(chainDir)) {
        fs.mkdirSync(chainDir, { recursive: true });
    }
    
    const addressesFile = getProjectPath("deployments", chainId.toString(), "addresses.json");
    const data = {
        chainId,
        deployedAt: new Date().toISOString(),
        projectRoot: PROJECT_ROOT, // 디버깅용
        contracts: deployedAddresses,
    };
    
    fs.writeFileSync(addressesFile, JSON.stringify(data, null, 2));
    console.log(`\n💾 Deployment addresses saved to: ${path.relative(PROJECT_ROOT, addressesFile)}`);
    if (process.env.DEBUG) {
        console.log(`[DEBUG] Full path: ${addressesFile}`);
    }
}

function main() {
    const rawArgs = process.argv.slice(2);
    const positional = rawArgs.filter((arg) => !arg.startsWith("--"));
    const showPlan = rawArgs.includes("--plan");
    
    if (showPlan) {
        console.log("\nDeployment plan:");
        DEPLOYMENT_STEPS.forEach((step, idx) => {
            const deps = step.requires ? ` (requires: ${step.requires.join(", ")})` : "";
            const opt = step.optional ? " [OPTIONAL]" : "";
            console.log(`${idx + 1}. [${step.id}] ${step.label}${deps}${opt}`);
        });
        return;
    }
    
    const network = process.env.NETWORK || positional[0] || "local";
    const requestedSteps = process.env.STEPS || positional[1] || "all";
    
    const config = validateEnvironment(network);
    
    let steps = DEPLOYMENT_STEPS;
    if (requestedSteps !== "all") {
        const ids = requestedSteps.split(",").map((id) => id.trim()).filter(Boolean);
        steps = DEPLOYMENT_STEPS.filter((step) => ids.includes(step.id));
        if (steps.length === 0) {
            throw new Error(`No valid step ids found in: ${requestedSteps}`);
        }
    }
    
    console.log("=".repeat(60));
    console.log(`Deploying StableNet contracts to ${network}`);
    console.log("=".repeat(60));
    console.log(`Project Root: ${PROJECT_ROOT}`);
    console.log(`Network: ${network}`);
    console.log(`Chain ID: ${config.chainId}`);
    console.log(`RPC URL: ${config.rpcUrl}`);
    console.log(`Verification: ${config.verify && process.env.EXPLORER_API_KEY ? "enabled" : "disabled"}`);
    console.log(`Steps to deploy: ${steps.length}`);
    console.log("=".repeat(60));
    
    const deployedSet = new Set();
    
    for (const step of steps) {
        // Skip optional steps if dependencies are missing
        if (step.optional && step.requires) {
            const hasAllDeps = step.requires.every((dep) => deployedSet.has(dep));
            if (!hasAllDeps) {
                console.log(`\n⏭️  Skipping optional step "${step.id}" (missing dependencies)`);
                continue;
            }
        }
        
        checkDependencies(step, deployedSet);
        const address = runStep(step, config);
        
        if (address) {
            deployedSet.add(step.id);
        } else if (!step.optional) {
            throw new Error(`Failed to deploy ${step.id} and it's not optional`);
        }
    }
    
    // Save all deployed addresses
    saveDeploymentAddresses(config.chainId);
    
    // Print final summary
    console.log("\n" + "=".repeat(60));
    console.log("Deployment Summary");
    console.log("=".repeat(60));
    Object.entries(deployedAddresses).forEach(([id, address]) => {
        const step = DEPLOYMENT_STEPS.find((s) => s.id === id);
        const label = step ? step.label : id;
        console.log(`${label.padEnd(30)} ${address}`);
    });
    console.log("=".repeat(60));
}

try {
    main();
} catch (error) {
    console.error("\n❌ Deployment failed:");
    console.error(error.message || error);
    if (error.stack) {
        console.error(error.stack);
    }
    process.exit(1);
}
