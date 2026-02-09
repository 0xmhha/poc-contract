#!/usr/bin/env npx ts-node
/**
 * Paymaster Post-Deployment Setup Script
 *
 * Runs ALL paymaster setup tasks after contract deployment:
 *   1. Deposit native token (KRC/ETH) to EntryPoint for all paymasters
 *   2. Add USDC as supported token for ERC20Paymaster
 *   3. Whitelist addresses for SponsorPaymaster
 *   4. Set default budget for SponsorPaymaster
 *   5. Stake bundler in EntryPoint (deposit + addStake)
 *   6. Stake factory in EntryPoint
 *   7. Show final configuration
 *
 * Usage:
 *   npx ts-node script/ts/setup-paymaster.ts [options]
 *
 * Options:
 *   --dry-run                 Show what would be executed without running
 *   --skip-deposit            Skip paymaster EntryPoint deposits
 *   --skip-token              Skip ERC20Paymaster token setup
 *   --skip-whitelist          Skip SponsorPaymaster whitelist
 *   --skip-budget             Skip SponsorPaymaster default budget
 *   --skip-bundler            Skip bundler EntryPoint staking
 *   --skip-factory            Skip factory EntryPoint staking
 *   --deposit=<amount>        Override deposit amount per paymaster (default: 10)
 *   --info                    Show current status only (no changes)
 *   --from=<step>             Start from specific step
 *
 * Examples:
 *   npx ts-node script/ts/setup-paymaster.ts                  # Full setup
 *   npx ts-node script/ts/setup-paymaster.ts --dry-run        # Show plan
 *   npx ts-node script/ts/setup-paymaster.ts --info           # Status only
 *   npx ts-node script/ts/setup-paymaster.ts --deposit=1      # Small deposit
 *   npx ts-node script/ts/setup-paymaster.ts --from=whitelist # Start from whitelist
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

// Default deposit amount per paymaster (in ETH/KRC)
const DEFAULT_DEPOSIT = "10";

// Default SponsorPaymaster budget
const DEFAULT_BUDGET_LIMIT = "1"; // 1 ETH per user
const DEFAULT_BUDGET_PERIOD = "86400"; // 24 hours

// Default bundler stake
const DEFAULT_BUNDLER_DEPOSIT = "10";
const DEFAULT_BUNDLER_STAKE = "1";
const DEFAULT_UNSTAKE_DELAY = "86400";

// Default factory stake
const DEFAULT_FACTORY_STAKE = "1";

// Whitelist addresses for SponsorPaymaster
const WHITELIST_ADDRESSES = [
  "0x056DB290F8Ba3250ca64a45D16284D04Bc6f5FBf", // deployer
  "0x1D828C255Fa0E158371155e08BAdd836412b8e69", // test user
];

// Paymaster name to JSON key mapping
const PAYMASTER_KEYS: { [key: string]: string } = {
  verifying: "verifyingPaymaster",
  sponsor: "sponsorPaymaster",
  erc20: "erc20Paymaster",
  permit2: "permit2Paymaster",
};

// ============ Setup Steps ============

interface SetupStep {
  name: string;
  description: string;
  category: string;
}

const SETUP_STEPS: SetupStep[] = [
  { name: "deposit", description: "Deposit native token to EntryPoint for all paymasters", category: "paymaster" },
  { name: "token", description: "Add USDC as supported token for ERC20Paymaster", category: "erc20" },
  { name: "whitelist", description: "Whitelist addresses for SponsorPaymaster", category: "sponsor" },
  { name: "budget", description: "Set default budget for SponsorPaymaster", category: "sponsor" },
  { name: "bundler", description: "Stake bundler in EntryPoint (deposit + addStake)", category: "infra" },
  { name: "factory", description: "Stake factory in EntryPoint", category: "infra" },
  { name: "info", description: "Show final paymaster configuration", category: "info" },
];

// ============ Argument Parsing ============

interface Args {
  dryRun: boolean;
  info: boolean;
  deposit: string;
  skipDeposit: boolean;
  skipToken: boolean;
  skipWhitelist: boolean;
  skipBudget: boolean;
  skipBundler: boolean;
  skipFactory: boolean;
  from: string | null;
}

function parseArgs(): Args {
  const args = process.argv.slice(2);
  const result: Args = {
    dryRun: false,
    info: false,
    deposit: DEFAULT_DEPOSIT,
    skipDeposit: false,
    skipToken: false,
    skipWhitelist: false,
    skipBudget: false,
    skipBundler: false,
    skipFactory: false,
    from: null,
  };

  for (const arg of args) {
    if (arg === "--dry-run") result.dryRun = true;
    else if (arg === "--info") result.info = true;
    else if (arg.startsWith("--deposit=")) result.deposit = arg.split("=")[1];
    else if (arg === "--skip-deposit") result.skipDeposit = true;
    else if (arg === "--skip-token") result.skipToken = true;
    else if (arg === "--skip-whitelist") result.skipWhitelist = true;
    else if (arg === "--skip-budget") result.skipBudget = true;
    else if (arg === "--skip-bundler") result.skipBundler = true;
    else if (arg === "--skip-factory") result.skipFactory = true;
    else if (arg.startsWith("--from=")) result.from = arg.split("=")[1];
  }

  return result;
}

// ============ Environment Validation ============

interface EnvConfig {
  rpcUrl: string;
  chainId: string;
  privateKeyDeployer: string;
  privateKeyBundler: string;
  privateKeyPaymaster: string;
}

function validateEnv(requireKeys: boolean): EnvConfig {
  const rpcUrl = process.env.RPC_URL;
  const chainId = process.env.CHAIN_ID || "8283";
  const privateKeyDeployer = process.env.PRIVATE_KEY_DEPLOYER || process.env.PRIVATE_KEY || "";
  const privateKeyBundler = process.env.PRIVATE_KEY_BUNDLER || "";
  const privateKeyPaymaster = process.env.PRIVATE_KEY_PAYMASTER || "";

  if (!rpcUrl) {
    throw new Error("RPC_URL is not set in .env");
  }

  if (requireKeys) {
    if (!privateKeyDeployer) {
      throw new Error("PRIVATE_KEY_DEPLOYER is not set in .env");
    }
  }

  return { rpcUrl, chainId, privateKeyDeployer, privateKeyBundler, privateKeyPaymaster };
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

// ============ Cast Commands ============

function execCast(args: string[], options: { rpcUrl: string; privateKey?: string }): string {
  // Quote arguments that contain parentheses (function signatures)
  const quotedArgs = args.map((arg) => (arg.includes("(") ? `"${arg}"` : arg));
  const cmd = ["cast", ...quotedArgs, "--rpc-url", options.rpcUrl];

  if (options.privateKey) {
    cmd.push("--private-key", options.privateKey);
  }

  try {
    const result = execSync(cmd.join(" "), {
      encoding: "utf8",
      cwd: PROJECT_ROOT,
      stdio: ["pipe", "pipe", "pipe"],
      shell: "/bin/bash",
    });
    return result.trim();
  } catch (error: unknown) {
    const execError = error as { stderr?: string; message?: string };
    throw new Error(`Cast command failed: ${execError.stderr || execError.message}`);
  }
}

function cleanCastResult(result: string): string {
  let cleaned = result.trim();

  // Cast returns format like: "10000000000000000000 [1e19]"
  // Take only the first part (the actual number) before the bracket annotation
  if (cleaned.includes(" [")) {
    cleaned = cleaned.split(" [")[0].trim();
  }

  // Remove standalone brackets: [123] -> 123
  if (cleaned.startsWith("[") && cleaned.endsWith("]")) {
    cleaned = cleaned.slice(1, -1).trim();
  }

  // Handle scientific notation: 1e19 -> 10000000000000000000
  if (/[eE]/.test(cleaned) && /^[\d.]+[eE][+\-]?\d+$/.test(cleaned)) {
    try {
      const [mantissa, exp] = cleaned.toLowerCase().split("e");
      const expNum = parseInt(exp);
      const parts = mantissa.split(".");
      const intPart = parts[0];
      const decPart = parts[1] || "";
      const totalDigits = intPart + decPart;
      const zerosNeeded = expNum - decPart.length;
      if (zerosNeeded >= 0) {
        cleaned = totalDigits + "0".repeat(zerosNeeded);
      }
    } catch {
      // Keep original
    }
  }

  return cleaned;
}

function formatEther(wei: string): string {
  const cleanedWei = cleanCastResult(wei);

  try {
    const weiNum = BigInt(cleanedWei);
    const wholePart = weiNum / BigInt(1e18);
    const fractionalPart = weiNum % BigInt(1e18);
    const fractionalStr = fractionalPart.toString().padStart(18, "0").slice(0, 6);
    return `${wholePart}.${fractionalStr}`;
  } catch {
    try {
      const result = execSync(`cast from-wei ${cleanedWei}`, { encoding: "utf8" });
      return result.trim();
    } catch {
      return cleanedWei;
    }
  }
}

function toWei(ether: string): string {
  try {
    const result = execSync(`cast to-wei ${ether}`, { encoding: "utf8" });
    return result.trim();
  } catch {
    const etherNum = parseFloat(ether);
    return BigInt(Math.floor(etherNum * 1e18)).toString();
  }
}

function getDeposit(entryPoint: string, account: string, rpcUrl: string): string {
  const result = execCast(
    ["call", entryPoint, "balanceOf(address)(uint256)", account],
    { rpcUrl }
  );
  return cleanCastResult(result);
}

function getWalletAddress(privateKey: string): string {
  const result = execSync(`cast wallet address ${privateKey}`, { encoding: "utf8" });
  return result.trim();
}

// ============ Step Execution ============

function runShellCommand(command: string, description: string, dryRun: boolean): boolean {
  console.log(`\n${"─".repeat(60)}`);
  console.log(`  ${description}`);
  console.log(`${"─".repeat(60)}`);
  console.log(`  Command: ${command}`);

  if (dryRun) {
    console.log("  [DRY RUN] Skipping execution");
    return true;
  }

  try {
    execSync(command, {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
      shell: "/bin/bash",
    });
    console.log(`  ✅ Success`);
    return true;
  } catch {
    console.error(`  ❌ Failed`);
    return false;
  }
}

// ============ Step: Deposit to EntryPoint ============

function stepDeposit(
  entryPoint: string,
  addresses: DeployedAddresses,
  amount: string,
  rpcUrl: string,
  privateKey: string,
  dryRun: boolean
): boolean {
  console.log(`\n${"─".repeat(60)}`);
  console.log(`  Step 1: Deposit ${amount} KRC to EntryPoint for all paymasters`);
  console.log(`${"─".repeat(60)}`);

  if (dryRun) {
    console.log(`  [DRY RUN] Would deposit ${amount} KRC to each paymaster`);
    for (const [name, key] of Object.entries(PAYMASTER_KEYS)) {
      const addr = addresses[key];
      if (addr) console.log(`    - ${name}: ${addr}`);
    }
    return true;
  }

  const weiAmount = toWei(amount);
  let allSuccess = true;

  for (const [name, key] of Object.entries(PAYMASTER_KEYS)) {
    const paymasterAddr = addresses[key];
    if (!paymasterAddr) {
      console.log(`  ⚠️  ${name}: NOT DEPLOYED (skipping)`);
      continue;
    }

    // Check current deposit
    try {
      const currentDeposit = getDeposit(entryPoint, paymasterAddr, rpcUrl);
      const currentEther = formatEther(currentDeposit);
      console.log(`\n  ${name} (${paymasterAddr})`);
      console.log(`    Current deposit: ${currentEther} KRC`);

      if (BigInt(currentDeposit) > BigInt(0)) {
        console.log(`    Already has deposit, skipping...`);
        continue;
      }

      // Deposit
      console.log(`    Depositing ${amount} KRC...`);
      const cmd = [
        "cast", "send", entryPoint,
        `"depositTo(address)"`, paymasterAddr,
        "--value", weiAmount,
        "--rpc-url", rpcUrl,
        "--private-key", privateKey,
      ];

      execSync(cmd.join(" "), {
        cwd: PROJECT_ROOT,
        stdio: "inherit",
        shell: "/bin/bash",
      });

      const newDeposit = getDeposit(entryPoint, paymasterAddr, rpcUrl);
      console.log(`    ✅ New deposit: ${formatEther(newDeposit)} KRC`);
    } catch (error) {
      console.error(`    ❌ Failed to deposit for ${name}`);
      allSuccess = false;
    }
  }

  return allSuccess;
}

// ============ Step: Add USDC Token ============

function stepAddToken(
  addresses: DeployedAddresses,
  rpcUrl: string,
  privateKey: string,
  dryRun: boolean
): boolean {
  console.log(`\n${"─".repeat(60)}`);
  console.log(`  Step 2: Add USDC as supported token for ERC20Paymaster`);
  console.log(`${"─".repeat(60)}`);

  const erc20Paymaster = addresses["erc20Paymaster"];
  const usdc = addresses["usdc"];

  if (!erc20Paymaster) {
    console.log("  ⚠️  ERC20Paymaster not deployed, skipping...");
    return true;
  }

  if (!usdc) {
    console.log("  ⚠️  USDC not deployed, skipping...");
    return true;
  }

  if (dryRun) {
    console.log(`  [DRY RUN] Would add USDC (${usdc}) to ERC20Paymaster (${erc20Paymaster})`);
    return true;
  }

  // Check if already supported
  try {
    const isSupported = execCast(
      ["call", erc20Paymaster, "supportedTokens(address)(bool)", usdc],
      { rpcUrl }
    );

    if (isSupported.includes("true")) {
      console.log(`  USDC already supported, skipping...`);
      return true;
    }
  } catch {
    // Proceed to add
  }

  try {
    console.log(`  Adding USDC (${usdc}) to ERC20Paymaster...`);
    const cmd = [
      "cast", "send", erc20Paymaster,
      `"setSupportedToken(address,bool)"`, usdc, "true",
      "--rpc-url", rpcUrl,
      "--private-key", privateKey,
    ];

    execSync(cmd.join(" "), {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
      shell: "/bin/bash",
    });

    console.log(`  ✅ USDC added to ERC20Paymaster`);
    return true;
  } catch {
    console.error(`  ❌ Failed to add USDC`);
    return false;
  }
}

// ============ Step: Whitelist ============

function stepWhitelist(
  addresses: DeployedAddresses,
  rpcUrl: string,
  privateKey: string,
  dryRun: boolean
): boolean {
  console.log(`\n${"─".repeat(60)}`);
  console.log(`  Step 3: Whitelist addresses for SponsorPaymaster`);
  console.log(`${"─".repeat(60)}`);

  const sponsorPaymaster = addresses["sponsorPaymaster"];

  if (!sponsorPaymaster) {
    console.log("  ⚠️  SponsorPaymaster not deployed, skipping...");
    return true;
  }

  if (dryRun) {
    console.log(`  [DRY RUN] Would whitelist ${WHITELIST_ADDRESSES.length} addresses:`);
    for (const addr of WHITELIST_ADDRESSES) {
      console.log(`    - ${addr}`);
    }
    return true;
  }

  let allSuccess = true;

  for (const addr of WHITELIST_ADDRESSES) {
    try {
      // Check if already whitelisted
      const isWhitelisted = execCast(
        ["call", sponsorPaymaster, "whitelist(address)(bool)", addr],
        { rpcUrl }
      );

      if (isWhitelisted.includes("true")) {
        console.log(`  ${addr}: already whitelisted, skipping...`);
        continue;
      }

      console.log(`  Whitelisting ${addr}...`);
      const cmd = [
        "cast", "send", sponsorPaymaster,
        `"setWhitelist(address,bool)"`, addr, "true",
        "--rpc-url", rpcUrl,
        "--private-key", privateKey,
      ];

      execSync(cmd.join(" "), {
        cwd: PROJECT_ROOT,
        stdio: "inherit",
        shell: "/bin/bash",
      });

      console.log(`  ✅ ${addr} whitelisted`);
    } catch {
      console.error(`  ❌ Failed to whitelist ${addr}`);
      allSuccess = false;
    }
  }

  return allSuccess;
}

// ============ Step: Default Budget ============

function stepDefaultBudget(
  addresses: DeployedAddresses,
  rpcUrl: string,
  privateKey: string,
  dryRun: boolean
): boolean {
  console.log(`\n${"─".repeat(60)}`);
  console.log(`  Step 4: Set default budget for SponsorPaymaster`);
  console.log(`${"─".repeat(60)}`);

  const sponsorPaymaster = addresses["sponsorPaymaster"];

  if (!sponsorPaymaster) {
    console.log("  ⚠️  SponsorPaymaster not deployed, skipping...");
    return true;
  }

  console.log(`  Limit: ${DEFAULT_BUDGET_LIMIT} KRC`);
  console.log(`  Period: ${DEFAULT_BUDGET_PERIOD} seconds (${parseInt(DEFAULT_BUDGET_PERIOD) / 86400} days)`);

  if (dryRun) {
    console.log(`  [DRY RUN] Would set default budget`);
    return true;
  }

  // Check current default budget
  try {
    const currentLimit = execCast(
      ["call", sponsorPaymaster, "defaultBudgetLimit()(uint256)"],
      { rpcUrl }
    );
    const cleanedLimit = cleanCastResult(currentLimit);

    if (BigInt(cleanedLimit) > BigInt(0)) {
      console.log(`  Default budget already set (${formatEther(cleanedLimit)} KRC), skipping...`);
      return true;
    }
  } catch {
    // Proceed to set
  }

  try {
    const limitWei = toWei(DEFAULT_BUDGET_LIMIT);

    const cmd = [
      "cast", "send", sponsorPaymaster,
      `"setDefaultBudget(uint256,uint256)"`, limitWei, DEFAULT_BUDGET_PERIOD,
      "--rpc-url", rpcUrl,
      "--private-key", privateKey,
    ];

    execSync(cmd.join(" "), {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
      shell: "/bin/bash",
    });

    console.log(`  ✅ Default budget set`);
    return true;
  } catch {
    console.error(`  ❌ Failed to set default budget`);
    return false;
  }
}

// ============ Step: Bundler Staking ============

function stepBundlerStake(
  entryPoint: string,
  rpcUrl: string,
  privateKeyBundler: string,
  dryRun: boolean
): boolean {
  console.log(`\n${"─".repeat(60)}`);
  console.log(`  Step 5: Stake bundler in EntryPoint`);
  console.log(`${"─".repeat(60)}`);

  if (!privateKeyBundler) {
    console.log("  ⚠️  PRIVATE_KEY_BUNDLER not set, skipping...");
    return true;
  }

  const bundlerAddress = getWalletAddress(privateKeyBundler);
  console.log(`  Bundler: ${bundlerAddress}`);

  if (dryRun) {
    console.log(`  [DRY RUN] Would deposit ${DEFAULT_BUNDLER_DEPOSIT} KRC and stake ${DEFAULT_BUNDLER_STAKE} KRC`);
    return true;
  }

  let success = true;

  // Check current deposit
  try {
    const currentDeposit = getDeposit(entryPoint, bundlerAddress, rpcUrl);
    console.log(`  Current deposit: ${formatEther(currentDeposit)} KRC`);

    if (BigInt(currentDeposit) === BigInt(0)) {
      console.log(`  Depositing ${DEFAULT_BUNDLER_DEPOSIT} KRC...`);
      const depositWei = toWei(DEFAULT_BUNDLER_DEPOSIT);
      const cmd = [
        "cast", "send", entryPoint,
        `"depositTo(address)"`, bundlerAddress,
        "--value", depositWei,
        "--rpc-url", rpcUrl,
        "--private-key", privateKeyBundler,
      ];

      execSync(cmd.join(" "), {
        cwd: PROJECT_ROOT,
        stdio: "inherit",
        shell: "/bin/bash",
      });

      const newDeposit = getDeposit(entryPoint, bundlerAddress, rpcUrl);
      console.log(`  ✅ Deposit: ${formatEther(newDeposit)} KRC`);
    } else {
      console.log(`  Already has deposit, skipping...`);
    }
  } catch {
    console.error(`  ❌ Bundler deposit failed`);
    success = false;
  }

  // AddStake
  try {
    console.log(`  Adding stake (${DEFAULT_BUNDLER_STAKE} KRC, delay=${DEFAULT_UNSTAKE_DELAY}s)...`);
    const stakeWei = toWei(DEFAULT_BUNDLER_STAKE);
    const cmd = [
      "cast", "send", entryPoint,
      `"addStake(uint32)"`, DEFAULT_UNSTAKE_DELAY,
      "--value", stakeWei,
      "--rpc-url", rpcUrl,
      "--private-key", privateKeyBundler,
    ];

    execSync(cmd.join(" "), {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
      shell: "/bin/bash",
    });

    console.log(`  ✅ Bundler staked`);
  } catch {
    console.error(`  ❌ Bundler stake failed (may already be staked)`);
  }

  return success;
}

// ============ Step: Factory Staking ============

function stepFactoryStake(
  addresses: DeployedAddresses,
  rpcUrl: string,
  privateKeyDeployer: string,
  dryRun: boolean
): boolean {
  console.log(`\n${"─".repeat(60)}`);
  console.log(`  Step 6: Stake factory in EntryPoint`);
  console.log(`${"─".repeat(60)}`);

  const factoryStaker = addresses["factoryStaker"];
  const entryPoint = addresses["entryPoint"];

  if (!factoryStaker) {
    console.log("  ⚠️  FactoryStaker not deployed, skipping...");
    return true;
  }

  if (!entryPoint) {
    console.log("  ⚠️  EntryPoint not deployed, skipping...");
    return true;
  }

  if (dryRun) {
    console.log(`  [DRY RUN] Would stake ${DEFAULT_FACTORY_STAKE} KRC via FactoryStaker`);
    return true;
  }

  return runShellCommand(
    `./script/stake-factory.sh --stake=${DEFAULT_FACTORY_STAKE} --approve`,
    "Staking factory via stake-factory.sh",
    dryRun
  );
}

// ============ Step: Show Info ============

function stepInfo(
  entryPoint: string,
  addresses: DeployedAddresses,
  rpcUrl: string
): void {
  console.log(`\n${"═".repeat(60)}`);
  console.log(`  Paymaster Setup Status`);
  console.log(`${"═".repeat(60)}`);

  // Paymaster deposits
  console.log("\n[Paymaster EntryPoint Deposits]");
  console.log("-".repeat(60));

  const paymasterList = [
    { name: "VerifyingPaymaster", key: "verifyingPaymaster" },
    { name: "SponsorPaymaster", key: "sponsorPaymaster" },
    { name: "ERC20Paymaster", key: "erc20Paymaster" },
    { name: "Permit2Paymaster", key: "permit2Paymaster" },
  ];

  for (const pm of paymasterList) {
    const address = addresses[pm.key];
    if (!address) {
      console.log(`  ${pm.name}: NOT DEPLOYED`);
      continue;
    }

    try {
      const depositWei = getDeposit(entryPoint, address, rpcUrl);
      const depositEther = formatEther(depositWei);
      const status = BigInt(depositWei) > BigInt(0) ? "✅" : "❌";
      console.log(`  ${status} ${pm.name}: ${depositEther} KRC (${address})`);
    } catch {
      console.log(`  ❌ ${pm.name}: Error reading deposit`);
    }
  }

  // VerifyingPaymaster signer
  const verifyingPaymaster = addresses["verifyingPaymaster"];
  if (verifyingPaymaster) {
    console.log("\n[VerifyingPaymaster]");
    console.log("-".repeat(60));
    try {
      const signer = execCast(["call", verifyingPaymaster, "verifyingSigner()(address)"], { rpcUrl });
      console.log(`  Signer: ${signer}`);
    } catch {
      console.log(`  Error reading signer`);
    }
  }

  // ERC20Paymaster config
  const erc20Paymaster = addresses["erc20Paymaster"];
  if (erc20Paymaster) {
    console.log("\n[ERC20Paymaster]");
    console.log("-".repeat(60));
    try {
      const oracle = execCast(["call", erc20Paymaster, "oracle()(address)"], { rpcUrl });
      const markup = execCast(["call", erc20Paymaster, "markup()(uint256)"], { rpcUrl });
      console.log(`  Oracle: ${oracle}`);
      console.log(`  Markup: ${markup} bps (${parseInt(markup) / 100}%)`);

      const usdc = addresses["usdc"];
      if (usdc) {
        const isSupported = execCast(
          ["call", erc20Paymaster, "supportedTokens(address)(bool)", usdc],
          { rpcUrl }
        );
        const status = isSupported.includes("true") ? "✅" : "❌";
        console.log(`  ${status} USDC (${usdc}): ${isSupported}`);
      }
    } catch {
      console.log(`  Error reading config`);
    }
  }

  // SponsorPaymaster config
  const sponsorPaymaster = addresses["sponsorPaymaster"];
  if (sponsorPaymaster) {
    console.log("\n[SponsorPaymaster]");
    console.log("-".repeat(60));
    try {
      const signer = execCast(["call", sponsorPaymaster, "signer()(address)"], { rpcUrl });
      const defaultLimit = execCast(["call", sponsorPaymaster, "defaultBudgetLimit()(uint256)"], { rpcUrl });
      const defaultPeriod = execCast(["call", sponsorPaymaster, "defaultBudgetPeriod()(uint256)"], { rpcUrl });
      console.log(`  Signer: ${signer}`);
      const cleanedPeriod = cleanCastResult(defaultPeriod);
      console.log(`  Default Budget: ${formatEther(defaultLimit)} KRC / ${cleanedPeriod}s (${parseInt(cleanedPeriod) / 86400} days)`);

      // Check whitelist status for known addresses
      for (const addr of WHITELIST_ADDRESSES) {
        const isWhitelisted = execCast(
          ["call", sponsorPaymaster, "whitelist(address)(bool)", addr],
          { rpcUrl }
        );
        const status = isWhitelisted.includes("true") ? "✅" : "❌";
        console.log(`  ${status} Whitelist ${addr}: ${isWhitelisted}`);
      }
    } catch {
      console.log(`  Error reading config`);
    }
  }

  // Bundler info
  console.log("\n[Bundler]");
  console.log("-".repeat(60));
  const privateKeyBundler = process.env.PRIVATE_KEY_BUNDLER || "";
  if (privateKeyBundler) {
    try {
      const bundlerAddress = getWalletAddress(privateKeyBundler);
      const bundlerDeposit = getDeposit(entryPoint, bundlerAddress, rpcUrl);
      const status = BigInt(bundlerDeposit) > BigInt(0) ? "✅" : "❌";
      console.log(`  ${status} Address: ${bundlerAddress}`);
      console.log(`    Deposit: ${formatEther(bundlerDeposit)} KRC`);
    } catch {
      console.log(`  Error reading bundler info`);
    }
  } else {
    console.log("  PRIVATE_KEY_BUNDLER not set");
  }

  // Factory info
  const factoryStaker = addresses["factoryStaker"];
  if (factoryStaker) {
    console.log("\n[FactoryStaker]");
    console.log("-".repeat(60));
    try {
      const factoryDeposit = getDeposit(entryPoint, factoryStaker, rpcUrl);
      const status = BigInt(factoryDeposit) > BigInt(0) ? "✅" : "❌";
      console.log(`  ${status} Address: ${factoryStaker}`);
      console.log(`    Deposit: ${formatEther(factoryDeposit)} KRC`);
    } catch {
      console.log(`  Error reading factory info`);
    }
  }

  console.log("\n" + "═".repeat(60));
}

// ============ Main ============

function main(): void {
  const args = parseArgs();
  const env = validateEnv(!args.info && !args.dryRun);
  const addresses = loadDeployedAddresses(env.chainId);

  const entryPoint = addresses["entryPoint"];
  if (!entryPoint) {
    console.error("Error: EntryPoint not found in deployment addresses");
    console.error(`Check: deployments/${env.chainId}/addresses.json`);
    process.exit(1);
  }

  // Info-only mode
  if (args.info) {
    stepInfo(entryPoint, addresses, env.rpcUrl);
    return;
  }

  // Show header
  console.log("═".repeat(60));
  console.log("  StableNet Paymaster Post-Deployment Setup");
  console.log("═".repeat(60));
  console.log(`Chain ID: ${env.chainId}`);
  console.log(`RPC URL: ${env.rpcUrl}`);
  console.log(`EntryPoint: ${entryPoint}`);
  console.log(`Dry Run: ${args.dryRun ? "YES" : "NO"}`);
  if (args.from) console.log(`Starting from: ${args.from}`);
  console.log("═".repeat(60));

  // Determine which steps to run
  const skipMap: { [key: string]: boolean } = {
    deposit: args.skipDeposit,
    token: args.skipToken,
    whitelist: args.skipWhitelist,
    budget: args.skipBudget,
    bundler: args.skipBundler,
    factory: args.skipFactory,
    info: false,
  };

  let steps = [...SETUP_STEPS];

  // Handle --from
  if (args.from) {
    const fromIndex = steps.findIndex((s) => s.name === args.from);
    if (fromIndex === -1) {
      console.error(`Unknown step: ${args.from}`);
      console.error(`Available steps: ${steps.map((s) => s.name).join(", ")}`);
      process.exit(1);
    }
    steps = steps.slice(fromIndex);
  }

  // Filter skipped steps
  steps = steps.filter((s) => !skipMap[s.name]);

  // Show plan
  console.log("\nSetup Plan:");
  steps.forEach((step, i) => {
    console.log(`  ${i + 1}. [${step.category}] ${step.name}: ${step.description}`);
  });

  if (args.dryRun) {
    console.log("\n[DRY RUN MODE] Commands will be shown but not executed.\n");
  }

  // Execute steps
  const failedSteps: string[] = [];

  for (const step of steps) {
    let success = true;

    switch (step.name) {
      case "deposit":
        success = stepDeposit(entryPoint, addresses, args.deposit, env.rpcUrl, env.privateKeyDeployer, args.dryRun);
        break;
      case "token":
        success = stepAddToken(addresses, env.rpcUrl, env.privateKeyDeployer, args.dryRun);
        break;
      case "whitelist":
        success = stepWhitelist(addresses, env.rpcUrl, env.privateKeyDeployer, args.dryRun);
        break;
      case "budget":
        success = stepDefaultBudget(addresses, env.rpcUrl, env.privateKeyDeployer, args.dryRun);
        break;
      case "bundler":
        success = stepBundlerStake(entryPoint, env.rpcUrl, env.privateKeyBundler, args.dryRun);
        break;
      case "factory":
        success = stepFactoryStake(addresses, env.rpcUrl, env.privateKeyDeployer, args.dryRun);
        break;
      case "info":
        stepInfo(entryPoint, addresses, env.rpcUrl);
        break;
    }

    if (!success) {
      failedSteps.push(step.name);
      console.log(`\n  ⚠️  Step "${step.name}" failed. Continuing with remaining steps...`);
    }
  }

  // Summary
  console.log("\n" + "═".repeat(60));
  console.log("  Setup Summary");
  console.log("═".repeat(60));

  if (failedSteps.length === 0) {
    console.log("✅ All steps completed successfully!");
  } else {
    console.log(`⚠️  ${failedSteps.length} step(s) failed:`);
    failedSteps.forEach((s) => console.log(`   - ${s}`));
  }

  console.log("═".repeat(60));

  if (failedSteps.length > 0) {
    process.exit(1);
  }
}

main();
