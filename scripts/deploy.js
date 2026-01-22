#!/usr/bin/env node

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

require("dotenv").config({ path: path.join(__dirname, "..", ".env") });

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

const DEPLOYMENT_STEPS = [
    {
        id: "layer0",
        label: "Layer 0 – Base Modules",
        description: "EntryPoint, validators, executors, hooks, fallbacks, tokens, privacy/compliance base, permission manager",
        target: "script/DeployOrchestrator.s.sol:DeployOrchestratorScript",
        env: { DEPLOY_LAYER: "0" },
        passthroughEnv: ["ADMIN_ADDRESS", "VERIFYING_SIGNER"],
    },
    {
        id: "layer1",
        label: "Layer 1 – Dependent Modules",
        description: "Kernel, paymasters, PrivateBank (depends on layer 0) via orchestrator",
        target: "script/DeployOrchestrator.s.sol:DeployOrchestratorScript",
        env: { DEPLOY_LAYER: "1" },
        passthroughEnv: ["ADMIN_ADDRESS", "VERIFYING_SIGNER"],
    },
    {
        id: "layer2",
        label: "Layer 2 – Higher Level",
        description: "KernelFactory and SubscriptionManager",
        target: "script/DeployOrchestrator.s.sol:DeployOrchestratorScript",
        env: { DEPLOY_LAYER: "2" },
        passthroughEnv: ["ADMIN_ADDRESS"],
    },
    {
        id: "defi",
        label: "DeFi Integration",
        description: "Price oracle confirmation and optional Uniswap integration (requires SWAP_ROUTER/QUOTER/WKRW_ADDRESS)",
        target: "script/DeployDeFi.s.sol:DeployDeFiScript",
        passthroughEnv: ["SWAP_ROUTER", "QUOTER", "WKRW_ADDRESS"],
    },
    {
        id: "privacy",
        label: "Privacy Stack",
        description: "ERC5564 announcer, ERC6538 registry, and PrivateBank persistence",
        target: "script/DeployPrivacy.s.sol:DeployPrivacyScript",
    },
    {
        id: "subscription",
        label: "Subscription Stack",
        description: "ERC7715 permission + subscription manager persistence",
        target: "script/DeploySubscription.s.sol:DeploySubscriptionScript",
    },
    {
        id: "compliance",
        label: "Compliance Suite",
        description: "KYC registry, audit logger, proof of reserve, regulatory registry",
        target: "script/DeployCompliance.s.sol:DeployComplianceScript",
        passthroughEnv: [
            "ADMIN_ADDRESS",
            "RETENTION_PERIOD",
            "AUTO_PAUSE_THRESHOLD",
            "APPROVER_1",
            "APPROVER_2",
            "APPROVER_3",
        ],
    },
    {
        id: "tokens",
        label: "Token Infrastructure",
        description: "WKRW deployment and persistence for downstream dependencies",
        target: "script/DeployTokens.s.sol:DeployTokensScript",
    },
    {
        id: "validators",
        label: "Validator Modules",
        description: "ECDSA/Weighted/MultiChain validators",
        target: "script/DeployValidators.s.sol:DeployValidatorsScript",
    },
    {
        id: "executors",
        label: "Executor Modules",
        description: "SessionKey and RecurringPayment executors",
        target: "script/DeployExecutors.s.sol:DeployExecutorsScript",
    },
    {
        id: "hooks",
        label: "Hook Modules",
        description: "Audit and spending limit hooks",
        target: "script/DeployHooks.s.sol:DeployHooksScript",
    },
    {
        id: "fallbacks",
        label: "Fallback Modules",
        description: "Token receiver and flash loan fallbacks",
        target: "script/DeployFallbacks.s.sol:DeployFallbacksScript",
    },
    {
        id: "kernel",
        label: "Kernel Stack",
        description: "Kernel + factory deployment for an existing EntryPoint",
        target: "script/DeployKernel.s.sol:DeployKernelScript",
        passthroughEnv: ["ENTRYPOINT_ADDRESS"],
        requires: ["layer0"],
    },
    {
        id: "paymasters",
        label: "Paymaster Suite",
        description: "Verifying + ERC20 + Permit2 paymasters",
        target: "script/DeployPaymasters.s.sol:DeployPaymastersScript",
        passthroughEnv: [
            "ENTRYPOINT_ADDRESS",
            "OWNER_ADDRESS",
            "VERIFYING_SIGNER",
            "PRICE_ORACLE",
            "PERMIT2_ADDRESS",
            "MARKUP",
        ],
        requires: ["layer0", "defi"],
    },
    {
        id: "bridge",
        label: "Cross-Chain Bridge",
        description: "Bridge validator/guardian/rate limiter/verifiers and SecureBridge",
        target: "script/DeployBridge.s.sol:DeployBridgeScript",
        passthroughEnv: [
            "BRIDGE_SIGNERS",
            "BRIDGE_GUARDIANS",
            "SIGNER_THRESHOLD",
            "GUARDIAN_THRESHOLD",
            "FEE_RECIPIENT",
        ],
    },
];

function printPlan() {
    console.log("\nDeployment plan:");
    DEPLOYMENT_STEPS.forEach((step, idx) => {
        console.log(`${idx + 1}. [${step.id}] ${step.label} - ${step.description}`);
    });
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

function formatCommand(target, config) {
    const args = [
        "forge",
        "script",
        target,
        "--rpc-url",
        config.rpcUrl,
        "--private-key",
        process.env.PRIVATE_KEY,
        "--broadcast",
    ];

    if (config.verify && process.env.EXPLORER_API_KEY) {
        args.push("--verify", "--etherscan-api-key", process.env.EXPLORER_API_KEY);
    }

    return args.join(" ");
}

function resolveSteps(requestedIds) {
    if (!requestedIds || requestedIds === "all") {
        return DEPLOYMENT_STEPS;
    }

    const ids = requestedIds.split(",").map((id) => id.trim()).filter(Boolean);
    if (!ids.length) {
        throw new Error("No valid step ids provided");
    }

    return ids.map((id) => {
        const step = DEPLOYMENT_STEPS.find((item) => item.id === id);
        if (!step) {
            throw new Error(`Unknown deployment step "${id}"`);
        }
        return step;
    });
}

function ensureDependencies(step, completedSet) {
    if (!step.requires) return;
    const missing = step.requires.filter((dep) => !completedSet.has(dep));
    if (missing.length) {
        throw new Error(`Step "${step.id}" requires steps [${missing.join(", ")}] to be executed first.`);
    }
}

function collectEnv(step, baseEnv) {
    const env = { ...baseEnv };
    if (step.env) {
        Object.entries(step.env).forEach(([key, value]) => {
            env[key] = value;
        });
    }
    if (step.passthroughEnv) {
        step.passthroughEnv.forEach((key) => {
            if (process.env[key]) {
                env[key] = process.env[key];
            }
        });
    }
    return env;
}

function parseDeployedContracts(output) {
    const contracts = [];
    const seen = new Set(); // Avoid duplicates
    const lines = output.split("\n");
    
    // Pattern 1: "ContractName deployed at: 0x..."
    const deployedAtPattern = /(\w+(?:\s+\w+)*)\s+deployed\s+at:\s+(0x[a-fA-F0-9]{40})/i;
    
    // Pattern 2: "ContractName: 0x..." (in summary sections)
    const summaryPattern = /^(\w+(?:\s+\w+)*):\s+(0x[a-fA-F0-9]{40})$/;
    
    // Pattern 3: "Contract deployed to: 0x..."
    const deployedToPattern = /(\w+)\s+deployed\s+to:\s+(0x[a-fA-F0-9]{40})/i;
    
    // Pattern 4: "Deployed ContractName at 0x..."
    const deployedAtPattern2 = /Deployed\s+(\w+(?:\s+\w+)*)\s+at\s+(0x[a-fA-F0-9]{40})/i;
    
    let inSummary = false;
    
    for (const line of lines) {
        // Check for summary section start
        if (line.includes("=== Deployment Summary ===") || 
            line.includes("Deployment Summary") ||
            line.includes("Summary:")) {
            inSummary = true;
            continue;
        }
        
        // Stop summary section at empty line or next section
        if (inSummary && (line.trim() === "" || line.startsWith("==="))) {
            inSummary = false;
        }
        
        // Try all patterns
        let match = null;
        if (inSummary) {
            match = line.match(summaryPattern);
        }
        
        if (!match) {
            match = line.match(deployedAtPattern) || 
                   line.match(deployedToPattern) || 
                   line.match(deployedAtPattern2);
        }
        
        if (match) {
            const name = match[1].trim();
            const address = match[2].toLowerCase();
            const key = `${name}:${address}`;
            
            if (!seen.has(key)) {
                seen.add(key);
                contracts.push({ name, address: match[2] }); // Keep original case for address
            }
        }
    }
    
    return contracts;
}

function getDeploymentFilePath(chainId) {
    const deploymentsDir = path.join(__dirname, "..", "deployments");
    const chainDir = path.join(deploymentsDir, chainId.toString());
    const addressesFile = path.join(chainDir, "addresses.json");
    return addressesFile;
}

function readDeploymentFile(chainId) {
    const filePath = getDeploymentFilePath(chainId);
    try {
        if (fs.existsSync(filePath)) {
            const content = fs.readFileSync(filePath, "utf8");
            const data = JSON.parse(content);
            
            // Handle two different JSON structures:
            // 1. Direct key-value: {"entryPoint": "0x...", "kernel": "0x..."}
            // 2. Nested with contracts: {"contracts": {"EntryPoint": "0x..."}, ...}
            
            if (data.contracts) {
                // Convert to flat structure for easier comparison
                return { contracts: data.contracts };
            } else {
                // Already flat, wrap it
                return { contracts: data };
            }
        }
    } catch (error) {
        // File doesn't exist or invalid JSON, that's okay
    }
    return null;
}

function displayDeployedContracts(contracts, stepLabel) {
    if (contracts.length === 0) {
        console.log("  ⚠️  No contracts detected in output");
        return;
    }
    
    console.log(`\n  📦 Deployed Contracts (${contracts.length}):`);
    contracts.forEach((contract, idx) => {
        console.log(`     ${idx + 1}. ${contract.name.padEnd(30)} ${contract.address}`);
    });
}

function runStep(step, config, baseEnv) {
    const env = collectEnv(step, baseEnv);
    const command = formatCommand(step.target, config);

    console.log("\n" + "-".repeat(60));
    console.log(`Running step: ${step.label} [${step.id}]`);
    console.log(step.description);
    console.log("Command:", command);

    // Read deployment file before step (if exists)
    const deploymentBefore = readDeploymentFile(config.chainId);
    
    let output = "";
    let deployedContracts = [];
    
    try {
        // Capture output while still showing it in real-time
        // Use stdio: 'pipe' to capture, but we'll also inherit to show output
        output = execSync(command, {
            cwd: path.join(__dirname, ".."),
            encoding: "utf8",
            stdio: 'pipe', // Capture output
            env,
        });
        
        // Display the captured output
        console.log(output);
        
        // Parse deployed contracts from output
        deployedContracts = parseDeployedContracts(output);
        
        // Also check deployment file for new contracts
        const deploymentAfter = readDeploymentFile(config.chainId);
        if (deploymentAfter && deploymentAfter.contracts) {
            const newContracts = [];
            for (const [name, address] of Object.entries(deploymentAfter.contracts)) {
                if (!address || typeof address !== 'string') continue;
                
                // Check if this is a new contract
                const beforeAddr = deploymentBefore?.contracts?.[name];
                const isNew = !beforeAddr || 
                             beforeAddr.toLowerCase() !== address.toLowerCase();
                
                if (isNew) {
                    // Avoid duplicates by checking both name and address
                    const addrLower = address.toLowerCase();
                    const isDuplicate = deployedContracts.some(
                        c => c.name === name || c.address.toLowerCase() === addrLower
                    );
                    
                    if (!isDuplicate) {
                        newContracts.push({ name, address });
                    }
                }
            }
            deployedContracts.push(...newContracts);
        }
        
    } catch (error) {
        // execSync puts output in error.output array: [stdin, stdout, stderr]
        if (error.output) {
            const stdout = error.output[1] ? error.output[1].toString() : '';
            const stderr = error.output[2] ? error.output[2].toString() : '';
            output = stdout + stderr;
            
            // Display output even on error
            if (stdout) console.log(stdout);
            if (stderr) console.error(stderr);
            
            // Try to parse contracts from output
            deployedContracts = parseDeployedContracts(output);
        } else {
            // Fallback: show error message
            console.error(error.message || error);
        }
        // Re-throw to maintain error behavior
        throw error;
    }
    
    // Display deployed contracts summary
    if (deployedContracts.length > 0) {
        displayDeployedContracts(deployedContracts, step.label);
    } else {
        console.log("\n  ℹ️  No new contracts detected (may already be deployed)");
    }
    
    return deployedContracts;
}

function main() {
    const rawArgs = process.argv.slice(2);
    const positional = rawArgs.filter((arg) => !arg.startsWith("--"));
    const showPlan = rawArgs.includes("--plan");

    if (showPlan) {
        printPlan();
        return;
    }

    const network = process.env.NETWORK || positional[0] || "local";
    const requestedSteps = process.env.STEPS || positional[1] || "all";

    const config = validateEnvironment(network);
    const steps = resolveSteps(requestedSteps);

    console.log("=".repeat(60));
    console.log(`Deploying StableNet contracts to ${network}`);
    console.log("=".repeat(60));
    console.log(`Network: ${network}`);
    console.log(`Chain ID: ${config.chainId}`);
    console.log(`RPC URL: ${config.rpcUrl}`);
    console.log(`Verification: ${config.verify && process.env.EXPLORER_API_KEY ? "enabled" : "disabled"}`);
    console.log(`Selected steps: ${steps.map((step) => step.id).join(", ")}`);
    console.log("=".repeat(60));

    const baseEnv = { ...process.env, NETWORK: network };
    const completed = new Set();

    const allDeployedContracts = [];
    
    steps.forEach((step) => {
        ensureDependencies(step, completed);
        const contracts = runStep(step, config, baseEnv);
        if (contracts && contracts.length > 0) {
            allDeployedContracts.push({ step: step.label, contracts });
        }
        completed.add(step.id);
    });

    console.log("\n" + "=".repeat(60));
    console.log("Deployment plan completed successfully");
    console.log("=".repeat(60));
    
    // Final summary of all deployed contracts
    if (allDeployedContracts.length > 0) {
        console.log("\n📋 Final Deployment Summary:");
        console.log("-".repeat(60));
        
        let totalContracts = 0;
        allDeployedContracts.forEach(({ step, contracts }) => {
            console.log(`\n${step}:`);
            contracts.forEach((contract) => {
                console.log(`  • ${contract.name.padEnd(30)} ${contract.address}`);
                totalContracts++;
            });
        });
        
        console.log("\n" + "-".repeat(60));
        console.log(`Total contracts deployed: ${totalContracts}`);
        
        // Also show deployment file location if it exists
        const deploymentFile = getDeploymentFilePath(config.chainId);
        if (fs.existsSync(deploymentFile)) {
            console.log(`\n💾 Deployment addresses saved to: ${path.relative(process.cwd(), deploymentFile)}`);
        }
    }
    
    console.log("=".repeat(60));
}

try {
    main();
} catch (error) {
    console.error("\nDeployment failed:");
    console.error(error.message || error);
    process.exit(1);
}
