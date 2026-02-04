#!/usr/bin/env npx ts-node
/**
 * Full Deployment Script
 *
 * Deploys all contracts and configures paymasters in the correct order.
 *
 * Usage:
 *   npx ts-node script/ts/deploy-all.ts [options]
 *
 * Options:
 *   --dry-run              Show what would be executed without running
 *   --skip-deploy          Skip deployment, only run configuration
 *   --skip-config          Skip configuration, only run deployment
 *   --from=<step>          Start from specific step (e.g., --from=defi)
 *   --verify               Enable contract verification
 *   --force                Force redeploy even if contracts exist
 *   --addresses            Show deployed contract addresses only (no deployment)
 *
 * Examples:
 *   npx ts-node script/ts/deploy-all.ts                    # Full deployment
 *   npx ts-node script/ts/deploy-all.ts --dry-run          # Show plan
 *   npx ts-node script/ts/deploy-all.ts --from=paymasters  # Start from paymasters
 *   npx ts-node script/ts/deploy-all.ts --skip-deploy      # Config only
 *   npx ts-node script/ts/deploy-all.ts --addresses        # Show addresses only
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

// Whitelist addresses for SponsorPaymaster
const WHITELIST_ADDRESSES = [
  "0x056DB290F8Ba3250ca64a45D16284D04Bc6f5FBf",
  "0x1D828C255Fa0E158371155e08BAdd836412b8e69",
];

// Paymaster deposit amount in ETH
const PAYMASTER_DEPOSIT = "1000";

// ============ Deployment Steps ============

interface DeploymentStep {
  name: string;
  description: string;
  command: string;
  phase: "deploy" | "utility" | "config";
}

const DEPLOYMENT_STEPS: DeploymentStep[] = [
  // Phase 0: Base Infrastructure
  {
    name: "tokens",
    description: "Deploy wKRC and USDC tokens",
    command: "./script/deploy-tokens.sh --broadcast --force",
    phase: "deploy",
  },
  {
    name: "transfer-usdc",
    description: "Transfer USDC to test accounts",
    command: "./script/transfer-usdc.sh",
    phase: "utility",
  },
  {
    name: "entrypoint",
    description: "Deploy ERC-4337 EntryPoint",
    command: "./script/deploy-entrypoint.sh --broadcast --force",
    phase: "deploy",
  },

  // Phase 1: Smart Account
  {
    name: "smartaccount",
    description: "Deploy Kernel, KernelFactory, FactoryStaker",
    command: "./script/deploy-smartaccount.sh --broadcast --force",
    phase: "deploy",
  },

  // Phase 2: ERC-7579 Modules
  {
    name: "validators",
    description: "Deploy ERC-7579 Validators",
    command: "./script/deploy-validators.sh --broadcast --force",
    phase: "deploy",
  },
  {
    name: "hooks",
    description: "Deploy ERC-7579 Hooks",
    command: "./script/deploy-hooks.sh --broadcast --force",
    phase: "deploy",
  },
  {
    name: "fallbacks",
    description: "Deploy ERC-7579 Fallbacks",
    command: "./script/deploy-fallbacks.sh --broadcast --force",
    phase: "deploy",
  },
  {
    name: "executors",
    description: "Deploy ERC-7579 Executors",
    command: "./script/deploy-executors.sh --broadcast --force",
    phase: "deploy",
  },

  // Phase 3: Feature Modules
  {
    name: "compliance",
    description: "Deploy Compliance contracts",
    command: "./script/deploy-compliance.sh --broadcast --force",
    phase: "deploy",
  },
  {
    name: "privacy",
    description: "Deploy Privacy (ERC-5564/6538) contracts",
    command: "./script/deploy-privacy.sh --broadcast --force",
    phase: "deploy",
  },
  {
    name: "permit2",
    description: "Deploy Permit2",
    command: "./script/deploy-permit2.sh --broadcast --force",
    phase: "deploy",
  },

  // Phase 4: DeFi & Paymasters
  {
    name: "uniswap",
    description: "Deploy UniswapV3 and create WKRC/USDC pool",
    command: "./script/deploy-uniswap.sh --broadcast --force --create-pool",
    phase: "deploy",
  },
  {
    name: "defi",
    description: "Deploy DeFi contracts (PriceOracle, LendingPool, StakingVault)",
    command: "./script/deploy-defi.sh --broadcast --force",
    phase: "deploy",
  },
  {
    name: "paymasters",
    description: "Deploy ERC-4337 Paymasters",
    command: "./script/deploy-paymasters.sh --broadcast --force",
    phase: "deploy",
  },

  // Configuration
  {
    name: "stake-paymaster",
    description: `Deposit ${PAYMASTER_DEPOSIT} ETH to all paymasters`,
    command: `./script/stake-paymaster.sh --deposit=${PAYMASTER_DEPOSIT} --paymaster=all`,
    phase: "config",
  },
  {
    name: "add-token",
    description: "Add USDC as supported token for ERC20Paymaster",
    command: "__DYNAMIC_USDC__", // Will be replaced with actual USDC address
    phase: "config",
  },
  {
    name: "whitelist",
    description: "Add addresses to SponsorPaymaster whitelist",
    command: "__DYNAMIC_WHITELIST__", // Will be replaced with actual commands
    phase: "config",
  },
  {
    name: "info",
    description: "Show final configuration",
    command: "./script/configure-paymaster.sh info",
    phase: "config",
  },
];

// ============ Argument Parsing ============

interface Args {
  dryRun: boolean;
  skipDeploy: boolean;
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
    skipDeploy: false,
    skipConfig: false,
    from: null,
    verify: false,
    force: false,
    addresses: false,
  };

  for (const arg of args) {
    if (arg === "--dry-run") {
      result.dryRun = true;
    } else if (arg === "--skip-deploy") {
      result.skipDeploy = true;
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

function loadDeployedAddresses(chainId: string): DeployedAddresses {
  const addressesPath = path.join(PROJECT_ROOT, "deployments", chainId, "addresses.json");

  if (!fs.existsSync(addressesPath)) {
    return {};
  }

  try {
    const content = fs.readFileSync(addressesPath, "utf8");
    return JSON.parse(content);
  } catch {
    return {};
  }
}

// ============ Contract Address Display ============

// Contract display names and categories
const CONTRACT_CATEGORIES: { [category: string]: { [key: string]: string } } = {
  "Tokens": {
    wkrc: "WKRC (Wrapped KRC)",
    usdc: "USDC",
  },
  "ERC-4337 Core": {
    entryPoint: "EntryPoint",
  },
  "Smart Account": {
    kernel: "Kernel",
    kernelFactory: "KernelFactory",
    factoryStaker: "FactoryStaker",
  },
  "ERC-7579 Validators": {
    ecdsaValidator: "ECDSAValidator",
    webAuthnValidator: "WebAuthnValidator",
    multiChainValidator: "MultiChainValidator",
    sessionKeyValidator: "SessionKeyValidator",
    permissionValidator: "PermissionValidator",
  },
  "ERC-7579 Hooks": {
    spendingLimitHook: "SpendingLimitHook",
  },
  "ERC-7579 Fallbacks": {
    erc165Handler: "ERC165Handler",
    tokenReceiver: "TokenReceiver",
  },
  "ERC-7579 Executors": {
    recurringPaymentExecutor: "RecurringPaymentExecutor",
    subscriptionManager: "SubscriptionManager",
    erc7715PermissionManager: "ERC7715PermissionManager",
  },
  "Compliance": {
    kycRegistry: "KYCRegistry",
    sanctionsList: "SanctionsList",
    complianceModule: "ComplianceModule",
  },
  "Privacy (ERC-5564/6538)": {
    stealthRegistry: "StealthRegistry (ERC-6538)",
    stealthAnnouncer: "StealthAnnouncer (ERC-5564)",
  },
  "Permit2": {
    permit2: "Permit2",
  },
  "UniswapV3": {
    uniswapV3Factory: "UniswapV3Factory",
    swapRouter: "SwapRouter",
    nftPositionManager: "NFTPositionManager",
    quoterV2: "QuoterV2",
    wkrcUsdcPool: "WKRC/USDC Pool",
  },
  "DeFi": {
    priceOracle: "PriceOracle",
    lendingPool: "LendingPool",
    stakingVault: "StakingVault",
    swapExecutor: "SwapExecutor",
  },
  "Paymasters": {
    verifyingPaymaster: "VerifyingPaymaster",
    sponsorPaymaster: "SponsorPaymaster",
    erc20Paymaster: "ERC20Paymaster",
    permit2Paymaster: "Permit2Paymaster",
  },
};

function displayDeployedAddresses(chainId: string): void {
  const addresses = loadDeployedAddresses(chainId);

  if (Object.keys(addresses).length === 0) {
    console.log("\n⚠️  No deployed addresses found.");
    return;
  }

  console.log("\n" + "═".repeat(70));
  console.log("  📋 Deployed Contract Addresses (for DApp Integration)");
  console.log("═".repeat(70));
  console.log(`Chain ID: ${chainId}\n`);

  const displayedKeys = new Set<string>();

  // Display by category
  for (const [category, contracts] of Object.entries(CONTRACT_CATEGORIES)) {
    const categoryAddresses: { name: string; key: string; address: string }[] = [];

    for (const [key, displayName] of Object.entries(contracts)) {
      if (addresses[key]) {
        categoryAddresses.push({ name: displayName, key, address: addresses[key]! });
        displayedKeys.add(key);
      }
    }

    if (categoryAddresses.length > 0) {
      console.log(`┌─ ${category} ${"─".repeat(Math.max(0, 65 - category.length))}`);
      for (const { name, address } of categoryAddresses) {
        const paddedName = name.padEnd(30);
        console.log(`│  ${paddedName} ${address}`);
      }
      console.log("│");
    }
  }

  // Display uncategorized addresses
  const uncategorized: { key: string; address: string }[] = [];
  for (const [key, address] of Object.entries(addresses)) {
    if (key !== "_chainId" && !displayedKeys.has(key) && address) {
      uncategorized.push({ key, address });
    }
  }

  if (uncategorized.length > 0) {
    console.log(`┌─ Other ${"─".repeat(60)}`);
    for (const { key, address } of uncategorized) {
      const paddedKey = key.padEnd(30);
      console.log(`│  ${paddedKey} ${address}`);
    }
    console.log("│");
  }

  console.log("└" + "─".repeat(69));

  // Export format for easy copy-paste
  console.log("\n" + "─".repeat(70));
  console.log("  📦 Export Format (JSON)");
  console.log("─".repeat(70));

  const exportObj: { [key: string]: string } = {};
  for (const [key, address] of Object.entries(addresses)) {
    if (key !== "_chainId" && address) {
      exportObj[key] = address;
    }
  }
  console.log(JSON.stringify(exportObj, null, 2));

  // .env format
  console.log("\n" + "─".repeat(70));
  console.log("  📦 Export Format (.env)");
  console.log("─".repeat(70));

  for (const [key, address] of Object.entries(addresses)) {
    if (key !== "_chainId" && address) {
      const envKey = key.replace(/([A-Z])/g, "_$1").toUpperCase();
      console.log(`CONTRACT_${envKey}=${address}`);
    }
  }

  console.log("\n" + "═".repeat(70));
}

// ============ Execution ============

function runCommand(command: string, description: string, dryRun: boolean): boolean {
  console.log(`\n${"─".repeat(60)}`);
  console.log(`📦 ${description}`);
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
    console.log(`   ✅ Success`);
    return true;
  } catch (error) {
    console.error(`   ❌ Failed`);
    return false;
  }
}

function addVerifyFlag(command: string, verify: boolean): string {
  if (verify && command.includes("--broadcast") && !command.includes("--verify")) {
    return command + " --verify";
  }
  return command;
}

// ============ Main ============

function main(): void {
  const args = parseArgs();
  const chainId = process.env.CHAIN_ID || "8283";

  // Handle --addresses flag: show addresses only and exit
  if (args.addresses) {
    displayDeployedAddresses(chainId);
    return;
  }

  console.log("═".repeat(60));
  console.log("  StableNet Full Deployment");
  console.log("═".repeat(60));
  console.log(`Chain ID: ${chainId}`);
  console.log(`Dry Run: ${args.dryRun ? "YES" : "NO"}`);
  console.log(`Skip Deploy: ${args.skipDeploy ? "YES" : "NO"}`);
  console.log(`Skip Config: ${args.skipConfig ? "YES" : "NO"}`);
  console.log(`Verify: ${args.verify ? "YES" : "NO"}`);
  if (args.from) {
    console.log(`Starting from: ${args.from}`);
  }
  console.log("═".repeat(60));

  // Filter steps based on arguments
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

  if (args.skipDeploy) {
    steps = steps.filter((s) => s.phase !== "deploy");
  }

  if (args.skipConfig) {
    steps = steps.filter((s) => s.phase !== "config" && s.phase !== "utility");
  }

  // Show plan
  console.log("\n📋 Deployment Plan:");
  steps.forEach((step, i) => {
    console.log(`   ${i + 1}. [${step.phase}] ${step.name}: ${step.description}`);
  });

  if (args.dryRun) {
    console.log("\n[DRY RUN MODE] Commands will be shown but not executed.\n");
  }

  // Execute steps
  let failedSteps: string[] = [];

  for (const step of steps) {
    let command = step.command;

    // Handle dynamic commands
    if (command === "__DYNAMIC_USDC__") {
      const addresses = loadDeployedAddresses(chainId);
      const usdcAddress = addresses["usdc"];
      if (!usdcAddress) {
        console.log(`\n⚠️  USDC address not found, skipping add-token`);
        continue;
      }
      command = `./script/configure-paymaster.sh add-token ${usdcAddress}`;
    } else if (command === "__DYNAMIC_WHITELIST__") {
      // Execute whitelist for each address
      for (const addr of WHITELIST_ADDRESSES) {
        const whitelistCmd = `./script/configure-paymaster.sh whitelist ${addr}`;
        const success = runCommand(whitelistCmd, `Whitelist ${addr}`, args.dryRun);
        if (!success) {
          failedSteps.push(`whitelist-${addr}`);
        }
      }
      continue;
    }

    // Add verify flag if requested
    command = addVerifyFlag(command, args.verify);

    const success = runCommand(command, step.description, args.dryRun);
    if (!success) {
      failedSteps.push(step.name);

      // Ask whether to continue on failure (skip in dry run)
      if (!args.dryRun) {
        console.log(`\n⚠️  Step "${step.name}" failed. Continuing with remaining steps...`);
      }
    }
  }

  // Summary
  console.log("\n" + "═".repeat(60));
  console.log("  Deployment Summary");
  console.log("═".repeat(60));

  if (failedSteps.length === 0) {
    console.log("✅ All steps completed successfully!");
  } else {
    console.log(`⚠️  ${failedSteps.length} step(s) failed:`);
    failedSteps.forEach((s) => console.log(`   - ${s}`));
  }

  if (!args.dryRun && !args.skipConfig) {
    console.log("\n📊 Final Configuration:");
    console.log("   Run: ./script/configure-paymaster.sh info");
    console.log("   Run: ./script/stake-paymaster.sh --info");
  }

  console.log("\n" + "═".repeat(60));

  // Display all deployed contract addresses
  if (!args.dryRun) {
    displayDeployedAddresses(chainId);
  }

  if (failedSteps.length > 0) {
    process.exit(1);
  }
}

main();
