#!/usr/bin/env npx ts-node
/**
 * StableNet Deployment Script
 *
 * Orchestrates deployment of smart contracts using forge scripts
 *
 * Usage:
 *   npx ts-node script/ts/deploy.ts [--broadcast] [--verify] [--plan] [--force] [--steps=<step1,step2,...>]
 *
 * Options:
 *   --broadcast  Actually broadcast transactions (otherwise dry run)
 *   --verify     Verify contracts on block explorer
 *   --plan       Show deployment plan without executing
 *   --force      Force redeploy even if contracts already exist
 *   --steps      Comma-separated list of steps to deploy
 *
 * Examples:
 *   npx ts-node script/ts/deploy.ts --plan                    # Show deployment plan
 *   npx ts-node script/ts/deploy.ts --broadcast               # Deploy all
 *   npx ts-node script/ts/deploy.ts --broadcast --steps=tokens,kernel
 *   npx ts-node script/ts/deploy.ts --broadcast --force       # Force redeploy all
 */

import { execSync, ExecSyncOptions } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Types ============

interface DeploymentStep {
  id: string;
  label: string;
  description: string;
  target: string;
  profile: string; // FOUNDRY_PROFILE value
  requires?: string[];
  optional?: boolean;
}

interface DeployedContract {
  name: string;
  address: string;
}

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

// ============ Deployment Steps ============

const DEPLOYMENT_STEPS: DeploymentStep[] = [
  // Phase 0: Base Infrastructure
  {
    profile: "tokens",
    id: "tokens",
    label: "Tokens",
    description: "wKRC and USDC tokens",
    target: "script/deploy-contract/DeployTokens.s.sol:DeployTokensScript",
  },
  {
    profile: "entrypoint",
    id: "entrypoint",
    label: "EntryPoint",
    description: "ERC-4337 EntryPoint",
    target: "script/deploy-contract/DeployEntryPoint.s.sol:DeployEntryPointScript",
  },

  // Phase 1: ERC-7579 Smart Account
  {
    profile: "smartaccount",
    id: "kernel",
    label: "Kernel",
    description: "Kernel smart account and factory",
    target: "script/deploy-contract/DeployKernel.s.sol:DeployKernelScript",
    requires: ["entrypoint"],
  },

  // Phase 2: ERC-7579 Modules
  {
    profile: "validators",
    id: "validators",
    label: "Validators",
    description: "ECDSA, Weighted, MultiChain, MultiSig, WebAuthn validators",
    target: "script/deploy-contract/DeployValidators.s.sol:DeployValidatorsScript",
  },
  {
    profile: "hooks",
    id: "hooks",
    label: "Hooks",
    description: "Audit and SpendingLimit hooks",
    target: "script/deploy-contract/DeployHooks.s.sol:DeployHooksScript",
  },
  {
    profile: "fallbacks",
    id: "fallbacks",
    label: "Fallbacks",
    description: "TokenReceiver and FlashLoan fallbacks",
    target: "script/deploy-contract/DeployFallbacks.s.sol:DeployFallbacksScript",
  },
  {
    profile: "executors",
    id: "executors",
    label: "Executors",
    description: "SessionKey and RecurringPayment executors",
    target: "script/deploy-contract/DeployExecutors.s.sol:DeployExecutorsScript",
  },

  // Phase 3: Feature Modules
  {
    profile: "compliance",
    id: "compliance",
    label: "Compliance",
    description: "KYC, AuditLogger, ProofOfReserve, RegulatoryRegistry",
    target: "script/deploy-contract/DeployCompliance.s.sol:DeployComplianceScript",
  },
  {
    profile: "privacy",
    id: "privacy",
    label: "Privacy",
    description: "ERC5564 Announcer, ERC6538 Registry, PrivateBank",
    target: "script/deploy-contract/DeployPrivacy.s.sol:DeployPrivacyScript",
  },
  { 
    profile: "permit2",
    id: "permit2",
    label: "Permit2",
    description: "Permit2 contract",
    target: "script/deploy-contract/DeployPermit2.s.sol:DeployPermit2Script",
  },

  // Phase 4: DeFi & Paymasters
  { 
    profile: "defi",
    id: "defi",
    label: "DeFi",
    description: "PriceOracle and DEXIntegration",
    target: "script/deploy-contract/DeployDeFi.s.sol:DeployDeFiScript",
    requires: ["tokens"],
  },
  {
    profile: "paymasters",
    id: "paymasters",
    label: "Paymasters",
    description: "Verifying, Sponsor, ERC20, Permit2 paymasters",
    target: "script/deploy-contract/DeployPaymasters.s.sol:DeployPaymastersScript",
    requires: ["entrypoint", "defi"],
  },

  // Phase 5: Plugins
  { 
    profile: "plugins",
    id: "plugins",
    label: "Plugins",
    description: "AutoSwap, MicroLoan, OnRamp plugins",
    target: "script/deploy-contract/DeployPlugins.s.sol:DeployPluginsScript",
    requires: ["defi"],
    optional: true,
  },

  // Phase 6: Subscription & Bridge
  {
    profile: "subscription",
    id: "subscription",
    label: "Subscription",
    description: "ERC7715 PermissionManager and SubscriptionManager",
    target: "script/deploy-contract/DeploySubscription.s.sol:DeploySubscriptionScript",
  },
  {
    profile: "bridge",
    id: "bridge",
    label: "Bridge",
    description: "SecureBridge with validators, guardians, rate limiter",
    target: "script/deploy-contract/DeployBridge.s.sol:DeployBridgeScript",
  },
];

// ============ Argument Parsing ============

interface Args {
  broadcast: boolean;
  verify: boolean;
  showPlan: boolean;
  force: boolean;
  steps: string[];
}

function parseArgs(): Args {
  const args = process.argv.slice(2);
  const stepsArg = args.find((a) => a.startsWith("--steps="));

  return {
    broadcast: args.includes("--broadcast"),
    verify: args.includes("--verify"),
    showPlan: args.includes("--plan"),
    force: args.includes("--force"),
    steps: stepsArg ? stepsArg.replace("--steps=", "").split(",") : [],
  };
}

// ============ Environment Validation ============

function validateEnv(): { rpcUrl: string; privateKey: string; chainId: string } {
  const rpcUrl = process.env.RPC_URL;
  const privateKey = process.env.PRIVATE_KEY_DEPLOYER || process.env.PRIVATE_KEY;
  const chainId = process.env.CHAIN_ID || "auto";

  if (!rpcUrl) {
    throw new Error("RPC_URL is not set in .env");
  }

  if (!privateKey) {
    throw new Error("PRIVATE_KEY_DEPLOYER (or PRIVATE_KEY) is not set in .env");
  }

  return { rpcUrl, privateKey, chainId };
}

// ============ Helper Functions ============

function printPlan(): void {
  console.log("\nDeployment Plan:");
  console.log("=".repeat(60));

  DEPLOYMENT_STEPS.forEach((step, idx) => {
    const deps = step.requires ? ` (requires: ${step.requires.join(", ")})` : "";
    const opt = step.optional ? " [OPTIONAL]" : "";
    console.log(`${(idx + 1).toString().padStart(2)}. [${step.id.padEnd(12)}] ${step.label}${deps}${opt}`);
    console.log(`      ${step.description}`);
  });

  console.log("=".repeat(60));
}

function resolveSteps(requestedIds: string[]): DeploymentStep[] {
  if (requestedIds.length === 0) {
    return DEPLOYMENT_STEPS;
  }

  return requestedIds.map((id) => {
    const step = DEPLOYMENT_STEPS.find((s) => s.id === id);
    if (!step) {
      throw new Error(`Unknown step: ${id}`);
    }
    return step;
  });
}

function checkDependencies(step: DeploymentStep, completed: Set<string>): void {
  if (!step.requires) return;

  const missing = step.requires.filter((dep) => !completed.has(dep));
  if (missing.length > 0) {
    throw new Error(`Step "${step.id}" requires: ${missing.join(", ")}`);
  }
}

function buildForgeCommand(
  target: string,
  rpcUrl: string,
  privateKey: string,
  broadcast: boolean
): string {
  const args = ["forge", "script", target, "--rpc-url", rpcUrl, "--private-key", privateKey];

  if (broadcast) {
    args.push("--broadcast");
  }

  // Note: --verify is not supported for custom chains (Chain not supported error)
  // Use `forge verify-contract` separately after deployment

  return args.join(" ");
}

function parseDeployedContracts(output: string): DeployedContract[] {
  const contracts: DeployedContract[] = [];
  const seen = new Set<string>();

  const patterns = [
    /(\w+)\s+deployed\s+at:\s+(0x[a-fA-F0-9]{40})/gi,
    /(\w+):\s+(0x[a-fA-F0-9]{40})/g,
  ];

  for (const pattern of patterns) {
    let match;
    while ((match = pattern.exec(output)) !== null) {
      const name = match[1];
      const address = match[2];
      const key = `${name}:${address.toLowerCase()}`;

      if (!seen.has(key)) {
        seen.add(key);
        contracts.push({ name, address });
      }
    }
  }

  return contracts;
}

function runStep(
  step: DeploymentStep,
  rpcUrl: string,
  privateKey: string,
  broadcast: boolean,
  force: boolean
): DeployedContract[] {
  console.log("\n" + "-".repeat(60));
  console.log(`Deploying: ${step.label} [${step.id}]`);
  console.log(`  ${step.description}`);
  console.log("-".repeat(60));

  const command = buildForgeCommand(step.target, rpcUrl, privateKey, broadcast);
  console.log(`Command: ${command.replace(privateKey, "***")}\n`);

  console.log(`Profile: FOUNDRY_PROFILE=${step.profile}`);
  if (force) {
    console.log(`Force: FORCE_REDEPLOY=true`);
  }

  const execOptions: ExecSyncOptions = {
    cwd: PROJECT_ROOT,
    encoding: "utf8",
    stdio: "pipe",
    env: {
      ...process.env,
      FOUNDRY_PROFILE: step.profile,
      FORCE_REDEPLOY: force ? "true" : "",
    } as NodeJS.ProcessEnv,
  };

  try {
    const output = execSync(command, execOptions) as string;
    console.log(output);

    const contracts = parseDeployedContracts(output);
    if (contracts.length > 0) {
      console.log(`\n✅ Deployed ${contracts.length} contract(s):`);
      contracts.forEach((c) => console.log(`   ${c.name}: ${c.address}`));
    }

    return contracts;
  } catch (error: unknown) {
    const execError = error as { stdout?: Buffer; stderr?: Buffer };

    if (execError.stdout) console.log(execError.stdout.toString());
    if (execError.stderr) console.error(execError.stderr.toString());

    if (step.optional) {
      console.log(`\n⚠️  Optional step "${step.id}" failed, continuing...`);
      return [];
    }

    throw error;
  }
}

// ============ Main ============

function main(): void {
  const { broadcast, verify, showPlan, force, steps } = parseArgs();

  if (showPlan) {
    printPlan();
    return;
  }

  const { rpcUrl, privateKey, chainId } = validateEnv();

  console.log("=".repeat(60));
  console.log("  StableNet Contract Deployment");
  console.log("=".repeat(60));
  console.log(`RPC URL: ${rpcUrl}`);
  console.log(`Chain ID: ${chainId}`);
  console.log(`Broadcast: ${broadcast ? "YES" : "NO (dry run)"}`);
  if (verify) {
    console.log(`Verify: ⚠️  Not supported for custom chains. Use 'forge verify-contract' after deployment.`);
  }
  console.log(`Force Redeploy: ${force ? "YES" : "NO"}`);

  const stepsToRun = resolveSteps(steps);
  console.log(`Steps: ${stepsToRun.map((s) => s.id).join(", ")}`);
  console.log("=".repeat(60));

  const completed = new Set<string>();
  const allContracts: DeployedContract[] = [];

  for (const step of stepsToRun) {
    checkDependencies(step, completed);

    const contracts = runStep(step, rpcUrl, privateKey, broadcast, force);
    allContracts.push(...contracts);
    completed.add(step.id);
  }

  // Summary
  console.log("\n" + "=".repeat(60));
  console.log("  Deployment Summary");
  console.log("=".repeat(60));

  if (allContracts.length > 0) {
    allContracts.forEach((c) => {
      console.log(`${c.name.padEnd(30)} ${c.address}`);
    });
  } else {
    console.log("No contracts deployed (dry run or already deployed)");
  }

  console.log("=".repeat(60));

  if (broadcast) {
    console.log("\n✅ Deployment completed!");
    console.log("Addresses saved to: deployments/<chainId>/addresses.json");
  } else {
    console.log("\n✅ Dry run completed. Use --broadcast to deploy.");
  }
}

try {
  main();
} catch (error: unknown) {
  const err = error as Error;
  console.error("\n❌ Deployment failed:", err.message);
  process.exit(1);
}
