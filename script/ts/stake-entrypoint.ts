#!/usr/bin/env npx ts-node
/**
 * EntryPoint Staking Script
 *
 * Deposits and stakes native tokens to EntryPoint for bundler operations
 *
 * Usage:
 *   npx ts-node script/ts/stake-entrypoint.ts [--deposit=<amount>] [--stake=<amount>] [--unstake-delay=<seconds>]
 *
 * Options:
 *   --deposit         Amount of native token to deposit (in ETH/KRC, default: 1)
 *   --stake           Amount of native token to stake (in ETH/KRC, default: 0)
 *   --unstake-delay   Unstake delay in seconds (default: 86400 = 1 day)
 *   --info            Show deposit info only, no transactions
 *
 * Examples:
 *   npx ts-node script/ts/stake-entrypoint.ts --info                    # Check current deposit
 *   npx ts-node script/ts/stake-entrypoint.ts --deposit=10              # Deposit 10 ETH/KRC
 *   npx ts-node script/ts/stake-entrypoint.ts --stake=1                 # Stake 1 ETH/KRC
 *   npx ts-node script/ts/stake-entrypoint.ts --deposit=5 --stake=1     # Deposit 5 + Stake 1
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const DEFAULT_DEPOSIT = "1";
const DEFAULT_UNSTAKE_DELAY = 86400; // 1 day

// ============ Argument Parsing ============

interface Args {
  deposit: string;
  stake: string;
  unstakeDelay: number;
  infoOnly: boolean;
}

function parseArgs(): Args {
  const args = process.argv.slice(2);

  const depositArg = args.find((a) => a.startsWith("--deposit="));
  const stakeArg = args.find((a) => a.startsWith("--stake="));
  const unstakeDelayArg = args.find((a) => a.startsWith("--unstake-delay="));
  const infoOnly = args.includes("--info");

  return {
    deposit: depositArg ? depositArg.replace("--deposit=", "") : (stakeArg || infoOnly ? "0" : DEFAULT_DEPOSIT),
    stake: stakeArg ? stakeArg.replace("--stake=", "") : "0",
    unstakeDelay: unstakeDelayArg ? parseInt(unstakeDelayArg.replace("--unstake-delay=", ""), 10) : DEFAULT_UNSTAKE_DELAY,
    infoOnly,
  };
}

// ============ Environment Validation ============

interface EnvConfig {
  rpcUrl: string;
  privateKeyBundler: string;
  chainId: string;
}

function validateEnv(requireKey: boolean = true): EnvConfig {
  const rpcUrl = process.env.RPC_URL;
  const privateKeyBundler = process.env.PRIVATE_KEY_BUNDLER || "";
  const chainId = process.env.CHAIN_ID || "8283";

  if (!rpcUrl) {
    throw new Error("RPC_URL is not set in .env");
  }

  if (requireKey && !privateKeyBundler) {
    throw new Error("PRIVATE_KEY_BUNDLER is not set in .env");
  }

  return { rpcUrl, privateKeyBundler, chainId };
}

// ============ Address Helpers ============

function getAddressFromPrivateKey(privateKey: string): string {
  try {
    const result = execSync(`cast wallet address ${privateKey}`, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    return result.trim();
  } catch {
    throw new Error("Failed to derive address from private key");
  }
}

function loadEntryPointAddress(chainId: string): string {
  const addressesPath = path.join(PROJECT_ROOT, "deployments", chainId, "addresses.json");

  if (!fs.existsSync(addressesPath)) {
    throw new Error(`Deployment addresses not found: ${addressesPath}\nPlease deploy EntryPoint first.`);
  }

  const content = fs.readFileSync(addressesPath, "utf8");
  const addresses = JSON.parse(content);

  if (!addresses.entryPoint) {
    throw new Error("EntryPoint address not found in deployment addresses");
  }

  return addresses.entryPoint;
}

// ============ Balance & Info Helpers ============

function getNativeBalance(address: string, rpcUrl: string): bigint {
  try {
    const result = execSync(`cast balance ${address} --rpc-url ${rpcUrl}`, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    // Output format: "1000000000000000000" or "1000000000000000000 [1e18]"
    const numberPart = result.trim().split(" ")[0];
    return BigInt(numberPart);
  } catch {
    return BigInt(0);
  }
}

interface DepositInfo {
  deposit: bigint;
  staked: boolean;
  stake: bigint;
  unstakeDelaySec: number;
  withdrawTime: bigint;
}

function getDepositInfo(entryPointAddress: string, account: string, rpcUrl: string): DepositInfo {
  try {
    const result = execSync(
      `cast call ${entryPointAddress} "getDepositInfo(address)((uint256,bool,uint112,uint32,uint48))" ${account} --rpc-url ${rpcUrl}`,
      {
        encoding: "utf8",
        stdio: ["pipe", "pipe", "pipe"],
      }
    );

    // Parse the tuple result: (deposit, staked, stake, unstakeDelaySec, withdrawTime)
    const cleaned = result.trim().replace(/[\[\]()]/g, "");
    const parts = cleaned.split(",").map((p) => p.trim());

    return {
      deposit: BigInt(parts[0] || "0"),
      staked: parts[1] === "true",
      stake: BigInt(parts[2] || "0"),
      unstakeDelaySec: parseInt(parts[3] || "0", 10),
      withdrawTime: BigInt(parts[4] || "0"),
    };
  } catch (error) {
    return {
      deposit: BigInt(0),
      staked: false,
      stake: BigInt(0),
      unstakeDelaySec: 0,
      withdrawTime: BigInt(0),
    };
  }
}

function formatEther(wei: bigint): string {
  const divisor = BigInt(10 ** 18);
  const whole = wei / divisor;
  const fraction = wei % divisor;
  const fractionStr = fraction.toString().padStart(18, "0").slice(0, 6);
  return `${whole}.${fractionStr}`;
}

function parseEther(ether: string): bigint {
  const [whole, fraction = ""] = ether.split(".");
  const paddedFraction = fraction.padEnd(18, "0").slice(0, 18);
  return BigInt(whole) * BigInt(10 ** 18) + BigInt(paddedFraction);
}

// ============ Deposit & Stake ============

function depositTo(options: {
  entryPointAddress: string;
  bundlerAddress: string;
  amount: bigint;
  privateKey: string;
  rpcUrl: string;
}): void {
  const { entryPointAddress, bundlerAddress, amount, privateKey, rpcUrl } = options;

  console.log(`\nDepositing ${formatEther(amount)} to EntryPoint...`);

  const command = [
    "cast",
    "send",
    entryPointAddress,
    '"depositTo(address)"',
    bundlerAddress,
    "--value",
    amount.toString(),
    "--private-key",
    privateKey,
    "--rpc-url",
    rpcUrl,
  ].join(" ");

  console.log(`Command: ${command.replace(privateKey, "***")}\n`);

  try {
    execSync(command, {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
    });
    console.log("✅ Deposit successful!");
  } catch (error) {
    console.error("❌ Deposit failed");
    throw error;
  }
}

function addStake(options: {
  entryPointAddress: string;
  amount: bigint;
  unstakeDelay: number;
  privateKey: string;
  rpcUrl: string;
}): void {
  const { entryPointAddress, amount, unstakeDelay, privateKey, rpcUrl } = options;

  console.log(`\nStaking ${formatEther(amount)} with ${unstakeDelay}s delay...`);

  const command = [
    "cast",
    "send",
    entryPointAddress,
    '"addStake(uint32)"',
    unstakeDelay.toString(),
    "--value",
    amount.toString(),
    "--private-key",
    privateKey,
    "--rpc-url",
    rpcUrl,
  ].join(" ");

  console.log(`Command: ${command.replace(privateKey, "***")}\n`);

  try {
    execSync(command, {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
    });
    console.log("✅ Stake successful!");
  } catch (error) {
    console.error("❌ Stake failed");
    throw error;
  }
}

// ============ Main ============

function main(): void {
  console.log("=".repeat(60));
  console.log("  EntryPoint Staking (Bundler)");
  console.log("=".repeat(60));

  const { deposit, stake, unstakeDelay, infoOnly } = parseArgs();
  const { rpcUrl, privateKeyBundler, chainId } = validateEnv(!infoOnly);

  // Get addresses
  const entryPointAddress = loadEntryPointAddress(chainId);
  const bundlerAddress = infoOnly && !privateKeyBundler
    ? process.env.BUNDLER_BENEFICIARY || "0x0000000000000000000000000000000000000000"
    : getAddressFromPrivateKey(privateKeyBundler);

  console.log(`\nConfiguration:`);
  console.log(`  RPC URL:         ${rpcUrl}`);
  console.log(`  Chain ID:        ${chainId}`);
  console.log(`  EntryPoint:      ${entryPointAddress}`);
  console.log(`  Bundler Address: ${bundlerAddress}`);

  if (!infoOnly) {
    console.log(`  Deposit Amount:  ${deposit} ETH/KRC`);
    console.log(`  Stake Amount:    ${stake} ETH/KRC`);
    if (parseFloat(stake) > 0) {
      console.log(`  Unstake Delay:   ${unstakeDelay} seconds`);
    }
  }

  // Get current info
  console.log(`\n${"─".repeat(60)}`);
  console.log("Current Status:");
  console.log("─".repeat(60));

  const nativeBalance = getNativeBalance(bundlerAddress, rpcUrl);
  const depositInfo = getDepositInfo(entryPointAddress, bundlerAddress, rpcUrl);

  console.log(`  Native Balance:  ${formatEther(nativeBalance)} ETH/KRC`);
  console.log(`  EP Deposit:      ${formatEther(depositInfo.deposit)} ETH/KRC`);
  console.log(`  EP Staked:       ${depositInfo.staked ? "Yes" : "No"}`);
  console.log(`  EP Stake Amount: ${formatEther(depositInfo.stake)} ETH/KRC`);
  if (depositInfo.staked) {
    console.log(`  Unstake Delay:   ${depositInfo.unstakeDelaySec} seconds`);
  }

  if (infoOnly) {
    console.log("\n" + "=".repeat(60));
    return;
  }

  // Execute transactions
  const depositAmount = parseEther(deposit);
  const stakeAmount = parseEther(stake);

  // Validate sufficient balance
  const totalNeeded = depositAmount + stakeAmount;
  if (nativeBalance < totalNeeded) {
    throw new Error(
      `Insufficient balance. Have: ${formatEther(nativeBalance)}, Need: ${formatEther(totalNeeded)}`
    );
  }

  // Deposit
  if (depositAmount > BigInt(0)) {
    depositTo({
      entryPointAddress,
      bundlerAddress,
      amount: depositAmount,
      privateKey: privateKeyBundler,
      rpcUrl,
    });
  }

  // Stake
  if (stakeAmount > BigInt(0)) {
    addStake({
      entryPointAddress,
      amount: stakeAmount,
      unstakeDelay,
      privateKey: privateKeyBundler,
      rpcUrl,
    });
  }

  // Show updated info
  console.log(`\n${"─".repeat(60)}`);
  console.log("Updated Status:");
  console.log("─".repeat(60));

  const newNativeBalance = getNativeBalance(bundlerAddress, rpcUrl);
  const newDepositInfo = getDepositInfo(entryPointAddress, bundlerAddress, rpcUrl);

  console.log(`  Native Balance:  ${formatEther(newNativeBalance)} ETH/KRC`);
  console.log(`  EP Deposit:      ${formatEther(newDepositInfo.deposit)} ETH/KRC`);
  console.log(`  EP Staked:       ${newDepositInfo.staked ? "Yes" : "No"}`);
  console.log(`  EP Stake Amount: ${formatEther(newDepositInfo.stake)} ETH/KRC`);

  console.log("\n" + "=".repeat(60));
  console.log("✅ Staking completed!");
  console.log("=".repeat(60));
}

main();
