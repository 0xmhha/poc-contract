#!/usr/bin/env npx ts-node
/**
 * Quick Start Deployment Script
 *
 * Deploys the MINIMUM contracts needed for "asset transfer via ERC-4337 + ERC-7579
 * smart account with ERC-20 gas payment" PoC.
 *
 * Deployed Contracts (12):
 *   Phase 0: USDC (test token)
 *   Phase 1: EntryPoint (ERC-4337)
 *   Phase 2: Kernel, KernelFactory, FactoryStaker (ERC-7579 Smart Account)
 *   Phase 3: ECDSAValidator (+ other validators — module deploys all)
 *   Phase 4: PriceOracle (+ LendingPool, StakingVault — module deploys all)
 *   Phase 5: ERC20Paymaster (+ other paymasters — module deploys all)
 *   Config: FixedPriceAggregator + oracle price setup + paymaster setup
 *
 * Usage:
 *   npx ts-node script/ts/deploy-quick-start.ts [options]
 *
 * Options:
 *   --dry-run              Show what would be executed without running
 *   --verify               Enable contract verification
 *   --force                Force redeploy even if contracts exist
 *   --from=<step>          Start from specific step
 *   --addresses            Show deployed contract addresses only
 *   --skip-config          Skip configuration, only run deployment
 *
 * Examples:
 *   npx ts-node script/ts/deploy-quick-start.ts                  # Full quick start
 *   npx ts-node script/ts/deploy-quick-start.ts --dry-run        # Show plan
 *   npx ts-node script/ts/deploy-quick-start.ts --from=defi      # Resume from defi
 *   npx ts-node script/ts/deploy-quick-start.ts --addresses      # Show addresses
 *
 * Available Steps:
 *   tokens, transfer-usdc, entrypoint, smartaccount,
 *   validators, defi, paymasters,
 *   setup-oracle-price, setup-paymaster
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const PAYMASTER_DEPOSIT = "100000";

// ============ Quick Start Steps ============

interface DeploymentStep {
  name: string;
  description: string;
  command: string;
  phase: "deploy" | "utility" | "config";
}

const DEPLOYMENT_STEPS: DeploymentStep[] = [
  // Phase 0: Token
  {
    name: "tokens",
    description: "Deploy USDC token",
    command: "./script/deploy-tokens.sh --broadcast",
    phase: "deploy",
  },
  {
    name: "transfer-usdc",
    description: "Transfer USDC to test accounts",
    command: "./script/transfer-usdc.sh",
    phase: "utility",
  },

  // Phase 1: ERC-4337 Core
  {
    name: "entrypoint",
    description: "Deploy ERC-4337 EntryPoint",
    command: "./script/deploy-entrypoint.sh --broadcast",
    phase: "deploy",
  },

  // Phase 2: ERC-7579 Smart Account
  {
    name: "smartaccount",
    description: "Deploy Kernel, KernelFactory, FactoryStaker",
    command: "./script/deploy-smartaccount.sh --broadcast",
    phase: "deploy",
  },

  // Phase 3: Validator (ECDSAValidator needed, module deploys all)
  {
    name: "validators",
    description: "Deploy ERC-7579 Validators (ECDSAValidator + others)",
    command: "./script/deploy-validators.sh --broadcast",
    phase: "deploy",
  },

  // Phase 4: DeFi (PriceOracle needed for ERC20Paymaster)
  {
    name: "defi",
    description: "Deploy DeFi contracts (PriceOracle needed for ERC20Paymaster)",
    command: "./script/deploy-defi.sh --broadcast",
    phase: "deploy",
  },

  // Phase 5: Paymasters (ERC20Paymaster for USDC gas payment)
  {
    name: "paymasters",
    description: "Deploy ERC-4337 Paymasters (ERC20Paymaster for USDC gas)",
    command: "./script/deploy-paymasters.sh --broadcast",
    phase: "deploy",
  },

  // Configuration
  {
    name: "setup-oracle-price",
    description: "Deploy FixedPriceAggregator and register USDC/KRWC price",
    command: "./script/setup-oracle-price.sh",
    phase: "config",
  },
  {
    name: "setup-paymaster",
    description: "Configure paymasters (deposit, token, bundler, factory stake)",
    command: `./script/setup-paymaster.sh --deposit=${PAYMASTER_DEPOSIT}`,
    phase: "config",
  },
];

// ============ Argument Parsing ============

interface Args {
  dryRun: boolean;
  skipConfig: boolean;
  from: string | null;
  verify: boolean;
  force: boolean;
  addresses: boolean;
}

function parseArgs(): Args {
  const args = process.argv.slice(2);
  const result: Args = {
    dryRun: false,
    skipConfig: false,
    from: null,
    verify: false,
    force: false,
    addresses: false,
  };

  for (const arg of args) {
    if (arg === "--dry-run") {
      result.dryRun = true;
    } else if (arg === "--skip-config") {
      result.skipConfig = true;
    } else if (arg === "--verify") {
      result.verify = true;
    } else if (arg === "--force") {
      result.force = true;
    } else if (arg === "--addresses") {
      result.addresses = true;
    } else if (arg.startsWith("--from=")) {
      result.from = arg.split("=")[1];
    }
  }

  return result;
}

// ============ Address Loading ============

interface DeployedAddresses {
  [key: string]: string | undefined;
}

const CONTRACT_NAME_TO_KEY: { [name: string]: string } = {
  USDC: "usdc",
  Create2Deployer: "create2Deployer",
  EntryPoint: "entryPoint",
  Kernel: "kernel",
  KernelFactory: "kernelFactory",
  FactoryStaker: "factoryStaker",
  ECDSAValidator: "ecdsaValidator",
  WeightedECDSAValidator: "weightedEcdsaValidator",
  MultiChainValidator: "multiChainValidator",
  MultiSigValidator: "multiSigValidator",
  WebAuthnValidator: "webAuthnValidator",
  PriceOracle: "priceOracle",
  LendingPool: "lendingPool",
  StakingVault: "stakingVault",
  VerifyingPaymaster: "verifyingPaymaster",
  SponsorPaymaster: "sponsorPaymaster",
  ERC20Paymaster: "erc20Paymaster",
  Permit2Paymaster: "permit2Paymaster",
  FixedPriceAggregator: "fixedPriceAggregator",
};

interface BroadcastTransaction {
  contractName: string | null;
  contractAddress: string;
  transactionType: string;
}

interface BroadcastFile {
  transactions: BroadcastTransaction[];
  timestamp: number;
}

function loadDeployedAddresses(chainId: string): DeployedAddresses {
  const addresses: DeployedAddresses = {};

  const broadcastDir = path.join(PROJECT_ROOT, "broadcast");

  if (fs.existsSync(broadcastDir)) {
    const scriptDirs = fs.readdirSync(broadcastDir).filter((dir) => dir.endsWith(".s.sol"));

    for (const scriptDir of scriptDirs) {
      const runLatestPath = path.join(broadcastDir, scriptDir, chainId, "run-latest.json");

      if (fs.existsSync(runLatestPath)) {
        try {
          const content = fs.readFileSync(runLatestPath, "utf8");
          const broadcast: BroadcastFile = JSON.parse(content);

          for (const tx of broadcast.transactions) {
            if ((tx.transactionType === "CREATE" || tx.transactionType === "CREATE2") && tx.contractName && tx.contractAddress) {
              const key = CONTRACT_NAME_TO_KEY[tx.contractName];
              if (key) {
                addresses[key] = tx.contractAddress;
              }
            }
          }
        } catch {
          // Skip invalid files
        }
      }
    }
  }

  const addressesPath = path.join(PROJECT_ROOT, "deployments", chainId, "addresses.json");

  if (fs.existsSync(addressesPath)) {
    try {
      const content = fs.readFileSync(addressesPath, "utf8");
      const fallbackAddresses = JSON.parse(content);

      for (const [key, value] of Object.entries(fallbackAddresses)) {
        if (key !== "_chainId" && value && !addresses[key]) {
          addresses[key] = value as string;
        }
      }
    } catch {
      // Skip invalid file
    }
  }

  return addresses;
}

// ============ Address Display ============

const QUICK_START_CATEGORIES: { [category: string]: { [key: string]: string } } = {
  "Tokens": {
    usdc: "USDC",
  },
  "ERC-4337 Core": {
    entryPoint: "EntryPoint",
  },
  "Smart Account (ERC-7579)": {
    kernel: "Kernel",
    kernelFactory: "KernelFactory",
    factoryStaker: "FactoryStaker",
  },
  "Validators": {
    ecdsaValidator: "ECDSAValidator",
  },
  "DeFi (Oracle)": {
    priceOracle: "PriceOracle",
    fixedPriceAggregator: "FixedPriceAggregator",
  },
  "Paymasters": {
    erc20Paymaster: "ERC20Paymaster",
    verifyingPaymaster: "VerifyingPaymaster",
    sponsorPaymaster: "SponsorPaymaster",
  },
};

function displayDeployedAddresses(chainId: string): void {
  const addresses = loadDeployedAddresses(chainId);

  if (Object.keys(addresses).length === 0) {
    console.log("\n  No deployed addresses found.");
    return;
  }

  console.log("\n" + "=".repeat(70));
  console.log("  Quick Start - Deployed Contract Addresses");
  console.log("=".repeat(70));
  console.log(`Chain ID: ${chainId}\n`);

  for (const [category, contracts] of Object.entries(QUICK_START_CATEGORIES)) {
    const found: { name: string; address: string }[] = [];

    for (const [key, displayName] of Object.entries(contracts)) {
      if (addresses[key]) {
        found.push({ name: displayName, address: addresses[key]! });
      }
    }

    if (found.length > 0) {
      console.log(`  [${category}]`);
      for (const { name, address } of found) {
        console.log(`    ${name.padEnd(28)} ${address}`);
      }
      console.log("");
    }
  }

  // JSON export
  console.log("-".repeat(70));
  console.log("  Export (JSON)");
  console.log("-".repeat(70));

  const exportObj: { [key: string]: string } = {};
  for (const [, contracts] of Object.entries(QUICK_START_CATEGORIES)) {
    for (const key of Object.keys(contracts)) {
      if (addresses[key]) {
        exportObj[key] = addresses[key]!;
      }
    }
  }
  console.log(JSON.stringify(exportObj, null, 2));

  console.log("\n" + "=".repeat(70));
}

// ============ Execution ============

const INTER_STEP_DELAY_MS = 3000;

function sleep(ms: number): void {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    // busy-wait (synchronous sleep for child_process workflow)
  }
}

function runCommand(command: string, description: string, dryRun: boolean): boolean {
  console.log(`\n${"─".repeat(60)}`);
  console.log(`  ${description}`);
  console.log(`${"─".repeat(60)}`);
  console.log(`   Command: ${command}`);

  if (dryRun) {
    console.log("   [DRY RUN] Skipping execution");
    return true;
  }

  try {
    execSync(command, {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
      shell: "/bin/bash",
    });
    console.log(`   Done`);
    return true;
  } catch {
    console.error(`   Failed`);
    return false;
  }
}

function addVerifyFlag(command: string, verify: boolean): string {
  if (verify && !command.includes("--verify")) {
    return command + " --verify";
  }
  return command;
}

function addForceFlag(command: string, force: boolean): string {
  if (force && !command.includes("--force")) {
    return command + " --force";
  }
  return command;
}

// ============ Main ============

function main(): void {
  const args = parseArgs();
  const chainId = process.env.CHAIN_ID || "8283";

  if (args.addresses) {
    displayDeployedAddresses(chainId);
    return;
  }

  if (args.verify && !args.dryRun) {
    if (!process.env.VERIFIER_URL) {
      console.error("Error: --verify flag requires VERIFIER_URL to be set in .env");
      process.exit(1);
    }
  }

  console.log("=".repeat(60));
  console.log("  StableNet Quick Start Deployment");
  console.log("  (ERC-4337 + ERC-7579 + ERC-20 Gas Payment)");
  console.log("=".repeat(60));
  console.log(`Chain ID:    ${chainId}`);
  console.log(`Dry Run:     ${args.dryRun ? "YES" : "NO"}`);
  console.log(`Verify:      ${args.verify ? "YES" : "NO"}`);
  console.log(`Skip Config: ${args.skipConfig ? "YES" : "NO"}`);
  if (args.from) {
    console.log(`From:        ${args.from}`);
  }
  console.log("=".repeat(60));

  let steps = [...DEPLOYMENT_STEPS];
  let startIndex = 0;

  if (args.from) {
    const fromIndex = steps.findIndex((s) => s.name === args.from);
    if (fromIndex === -1) {
      console.error(`Unknown step: ${args.from}`);
      console.error(`Available steps: ${steps.map((s) => s.name).join(", ")}`);
      process.exit(1);
    }
    startIndex = fromIndex;
  }

  steps = steps.slice(startIndex);

  if (args.skipConfig) {
    steps = steps.filter((s) => s.phase !== "config" && s.phase !== "utility");
  }

  // Show plan
  console.log("\n  Deployment Plan:");
  steps.forEach((step, i) => {
    console.log(`   ${i + 1}. [${step.phase}] ${step.name}: ${step.description}`);
  });

  if (args.dryRun) {
    console.log("\n[DRY RUN MODE] Commands will be shown but not executed.\n");
  }

  // Execute
  const failedSteps: string[] = [];

  for (const step of steps) {
    let command = step.command;

    if (step.phase === "deploy") {
      command = addForceFlag(command, args.force);
      command = addVerifyFlag(command, args.verify);
    }

    const success = runCommand(command, step.description, args.dryRun);
    if (!success) {
      failedSteps.push(step.name);

      if (!args.dryRun) {
        console.log(`\n  Step "${step.name}" failed. Continuing with remaining steps...`);
      }
    }

    if (!args.dryRun && step.phase === "deploy" && steps.indexOf(step) < steps.length - 1) {
      console.log(`   Waiting ${INTER_STEP_DELAY_MS / 1000}s for node to process transactions...`);
      sleep(INTER_STEP_DELAY_MS);
    }
  }

  // Summary
  console.log("\n" + "=".repeat(60));
  console.log("  Quick Start Deployment Summary");
  console.log("=".repeat(60));

  if (failedSteps.length === 0) {
    console.log("  All steps completed successfully!");
  } else {
    console.log(`  ${failedSteps.length} step(s) failed:`);
    failedSteps.forEach((s) => console.log(`   - ${s}`));
  }

  if (!args.dryRun && !args.skipConfig) {
    console.log("\n  Check paymaster status:");
    console.log("   ./script/setup-paymaster.sh --info");
  }

  console.log("\n" + "=".repeat(60));

  if (!args.dryRun) {
    displayDeployedAddresses(chainId);
  }

  if (failedSteps.length > 0) {
    process.exit(1);
  }
}

main();
