#!/usr/bin/env npx ts-node
/**
 * Paymaster Staking Script
 *
 * Deposits ETH/KRC to EntryPoint for Paymaster gas sponsorship.
 * All paymasters need a deposit in EntryPoint to pay for user gas fees.
 *
 * Usage:
 *   npx ts-node script/ts/stake-paymaster.ts [options]
 *
 * Options:
 *   --info                    Show current deposit balances for all paymasters
 *   --deposit=<amount>        Deposit amount in ETH/KRC (e.g., --deposit=1)
 *   --paymaster=<name|addr>   Target paymaster (verifying|sponsor|erc20|permit2|all|0x...)
 *   --withdraw=<amount>       Withdraw amount from paymaster deposit
 *
 * Examples:
 *   npx ts-node script/ts/stake-paymaster.ts --info
 *   npx ts-node script/ts/stake-paymaster.ts --deposit=1 --paymaster=all
 *   npx ts-node script/ts/stake-paymaster.ts --deposit=0.5 --paymaster=verifying
 *   npx ts-node script/ts/stake-paymaster.ts --deposit=2 --paymaster=0x1234...
 *   npx ts-node script/ts/stake-paymaster.ts --withdraw=0.5 --paymaster=erc20
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

// Paymaster name to JSON key mapping
const PAYMASTER_KEYS: { [key: string]: string } = {
  verifying: "verifyingPaymaster",
  sponsor: "sponsorPaymaster",
  erc20: "erc20Paymaster",
  permit2: "permit2Paymaster",
};

// ============ Argument Parsing ============

interface Args {
  info: boolean;
  deposit: string | null;
  withdraw: string | null;
  paymaster: string;
}

function parseArgs(): Args {
  const args = process.argv.slice(2);
  const result: Args = {
    info: false,
    deposit: null,
    withdraw: null,
    paymaster: "all",
  };

  for (const arg of args) {
    if (arg === "--info") {
      result.info = true;
    } else if (arg.startsWith("--deposit=")) {
      result.deposit = arg.split("=")[1];
    } else if (arg.startsWith("--withdraw=")) {
      result.withdraw = arg.split("=")[1];
    } else if (arg.startsWith("--paymaster=")) {
      result.paymaster = arg.split("=")[1];
    }
  }

  return result;
}

// ============ Environment Validation ============

function validateEnv(): { rpcUrl: string; privateKey: string; chainId: string } {
  const rpcUrl = process.env.RPC_URL;
  const privateKey = process.env.PRIVATE_KEY_DEPLOYER || process.env.PRIVATE_KEY || "";
  const chainId = process.env.CHAIN_ID || "8283";

  if (!rpcUrl) {
    throw new Error("RPC_URL is not set in .env");
  }

  return { rpcUrl, privateKey, chainId };
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

function getDeposit(entryPoint: string, account: string, rpcUrl: string): string {
  // balanceOf(address) returns uint256
  const result = execCast(
    ["call", entryPoint, "balanceOf(address)(uint256)", account],
    { rpcUrl }
  );
  // Clean up result: remove brackets and whitespace
  return cleanCastResult(result);
}

/**
 * Clean up cast call result - removes brackets and handles various formats
 */
function cleanCastResult(result: string): string {
  let cleaned = result.trim();
  // Remove brackets if present: [123] -> 123
  if (cleaned.startsWith("[") && cleaned.endsWith("]")) {
    cleaned = cleaned.slice(1, -1);
  }
  // Handle scientific notation: 1e21 -> 1000000000000000000000
  if (cleaned.includes("e") || cleaned.includes("E")) {
    try {
      cleaned = BigInt(Number(cleaned)).toString();
    } catch {
      // If conversion fails, keep original
    }
  }
  return cleaned;
}

function formatEther(wei: string): string {
  // Clean the input first
  const cleanedWei = cleanCastResult(wei);

  try {
    // Manual conversion is more reliable
    const weiNum = BigInt(cleanedWei);
    const wholePart = weiNum / BigInt(1e18);
    const fractionalPart = weiNum % BigInt(1e18);
    const fractionalStr = fractionalPart.toString().padStart(18, "0").slice(0, 6);
    return `${wholePart}.${fractionalStr}`;
  } catch {
    // Fallback to cast if BigInt fails
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
    // Manual conversion
    const etherNum = parseFloat(ether);
    return (BigInt(Math.floor(etherNum * 1e18))).toString();
  }
}

// ============ Info Display ============

function showInfo(
  entryPoint: string,
  addresses: DeployedAddresses,
  rpcUrl: string
): void {
  console.log("=".repeat(60));
  console.log("  Paymaster Deposit Status");
  console.log("=".repeat(60));
  console.log(`EntryPoint: ${entryPoint}`);
  console.log("-".repeat(60));

  const paymasterList = [
    { name: "VerifyingPaymaster", key: "verifyingPaymaster" },
    { name: "SponsorPaymaster", key: "sponsorPaymaster" },
    { name: "ERC20Paymaster", key: "erc20Paymaster" },
    { name: "Permit2Paymaster", key: "permit2Paymaster" },
  ];

  let totalDeposit = BigInt(0);

  for (const pm of paymasterList) {
    const address = addresses[pm.key];
    if (!address) {
      console.log(`${pm.name}: NOT DEPLOYED`);
      continue;
    }

    try {
      const depositWei = getDeposit(entryPoint, address, rpcUrl);
      const depositEther = formatEther(depositWei);
      totalDeposit += BigInt(depositWei);
      console.log(`${pm.name}:`);
      console.log(`  Address: ${address}`);
      console.log(`  Deposit: ${depositEther} ETH (${depositWei} wei)`);
    } catch (error) {
      console.log(`${pm.name}: Error reading deposit`);
    }
  }

  console.log("-".repeat(60));
  console.log(`Total Deposit: ${formatEther(totalDeposit.toString())} ETH`);
  console.log("=".repeat(60));
}

// ============ Deposit ============

function deposit(
  entryPoint: string,
  paymaster: string,
  paymasterName: string,
  amount: string,
  rpcUrl: string,
  privateKey: string
): void {
  console.log(`\nDepositing ${amount} ETH to ${paymasterName}...`);
  console.log(`  Paymaster: ${paymaster}`);

  const weiAmount = toWei(amount);
  console.log(`  Amount: ${weiAmount} wei`);

  // Call depositTo(address) on EntryPoint
  // Note: Function signature must be quoted to prevent shell from interpreting parentheses
  const cmd = [
    "cast",
    "send",
    entryPoint,
    `"depositTo(address)"`,
    paymaster,
    "--value",
    `${weiAmount}`,
    "--rpc-url",
    rpcUrl,
    "--private-key",
    privateKey,
  ];

  try {
    console.log(`  Executing: cast send ${entryPoint} "depositTo(address)" ${paymaster} --value ${weiAmount}`);
    execSync(cmd.join(" "), {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
      shell: "/bin/bash",
    });
    console.log(`  ✅ Deposit successful!`);

    // Show new balance
    const newDeposit = getDeposit(entryPoint, paymaster, rpcUrl);
    console.log(`  New balance: ${formatEther(newDeposit)} ETH`);
  } catch (error) {
    console.error(`  ❌ Deposit failed`);
    throw error;
  }
}

// ============ Withdraw ============

function withdraw(
  paymaster: string,
  paymasterName: string,
  amount: string,
  rpcUrl: string,
  privateKey: string
): void {
  console.log(`\nWithdrawing ${amount} ETH from ${paymasterName}...`);
  console.log(`  Paymaster: ${paymaster}`);

  const weiAmount = toWei(amount);
  console.log(`  Amount: ${weiAmount} wei`);

  // Get deployer address for withdrawal recipient
  const deployer = execSync(`cast wallet address ${privateKey}`, { encoding: "utf8" }).trim();

  // Call withdrawTo(address payable, uint256) on Paymaster
  // BasePaymaster has: function withdrawTo(address payable withdrawAddress, uint256 amount)
  // Note: Function signature must be quoted to prevent shell from interpreting parentheses
  const cmd = [
    "cast",
    "send",
    paymaster,
    `"withdrawTo(address,uint256)"`,
    deployer,
    weiAmount,
    "--rpc-url",
    rpcUrl,
    "--private-key",
    privateKey,
  ];

  try {
    console.log(`  Executing: cast send ${paymaster} "withdrawTo(address,uint256)" ${deployer} ${weiAmount}`);
    execSync(cmd.join(" "), {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
      shell: "/bin/bash",
    });
    console.log(`  ✅ Withdrawal successful!`);
  } catch (error) {
    console.error(`  ❌ Withdrawal failed (only owner can withdraw)`);
    throw error;
  }
}

// ============ Main ============

function main(): void {
  const args = parseArgs();
  const { rpcUrl, privateKey, chainId } = validateEnv();
  const addresses = loadDeployedAddresses(chainId);

  const entryPoint = addresses["entryPoint"];
  if (!entryPoint) {
    console.error("Error: EntryPoint not found in deployment addresses");
    process.exit(1);
  }

  // Info mode
  if (args.info || (!args.deposit && !args.withdraw)) {
    showInfo(entryPoint, addresses, rpcUrl);
    return;
  }

  // Require private key for deposit/withdraw
  if (!privateKey) {
    console.error("Error: PRIVATE_KEY_DEPLOYER (or PRIVATE_KEY) is not set");
    process.exit(1);
  }

  // Resolve target paymasters
  const targetPaymasters: { name: string; address: string }[] = [];

  if (args.paymaster === "all") {
    for (const [name, key] of Object.entries(PAYMASTER_KEYS)) {
      const addr = addresses[key];
      if (addr) {
        targetPaymasters.push({ name, address: addr });
      }
    }
  } else if (args.paymaster.startsWith("0x")) {
    targetPaymasters.push({ name: "Custom", address: args.paymaster });
  } else {
    const key = PAYMASTER_KEYS[args.paymaster.toLowerCase()];
    if (!key) {
      console.error(`Unknown paymaster: ${args.paymaster}`);
      console.error(`Valid options: verifying, sponsor, erc20, permit2, all, or 0x address`);
      process.exit(1);
    }
    const addr = addresses[key];
    if (!addr) {
      console.error(`${args.paymaster} paymaster not found in deployment addresses`);
      process.exit(1);
    }
    targetPaymasters.push({ name: args.paymaster, address: addr });
  }

  if (targetPaymasters.length === 0) {
    console.error("No paymasters found to process");
    process.exit(1);
  }

  console.log("=".repeat(60));
  console.log("  Paymaster Staking");
  console.log("=".repeat(60));
  console.log(`Chain ID: ${chainId}`);
  console.log(`EntryPoint: ${entryPoint}`);
  console.log(`Operation: ${args.deposit ? `Deposit ${args.deposit} ETH` : `Withdraw ${args.withdraw} ETH`}`);
  console.log(`Targets: ${targetPaymasters.map((p) => p.name).join(", ")}`);
  console.log("=".repeat(60));

  // Execute operations
  for (const pm of targetPaymasters) {
    try {
      if (args.deposit) {
        deposit(entryPoint, pm.address, pm.name, args.deposit, rpcUrl, privateKey);
      } else if (args.withdraw) {
        withdraw(pm.address, pm.name, args.withdraw, rpcUrl, privateKey);
      }
    } catch (error) {
      console.error(`Failed to process ${pm.name}`);
    }
  }

  console.log("\n" + "=".repeat(60));
  console.log("Operation completed");
  console.log("=".repeat(60));
}

main();
