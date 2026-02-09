#!/usr/bin/env npx ts-node
/**
 * USDC Transfer Script
 *
 * Transfers USDC tokens from deployer to test accounts
 *
 * Usage:
 *   npx ts-node script/ts/transfer-usdc.ts [--amount=<amount>] [--to=<address>]
 *
 * Options:
 *   --amount   Amount of USDC to transfer (default: 1000)
 *   --to       Recipient address (default: derived from PRIVATE_KEY_TEST_NO_NATIVE)
 *
 * Examples:
 *   npx ts-node script/ts/transfer-usdc.ts                    # Transfer 1000 USDC to test account
 *   npx ts-node script/ts/transfer-usdc.ts --amount=5000      # Transfer 5000 USDC
 *   npx ts-node script/ts/transfer-usdc.ts --to=0x123...      # Transfer to specific address
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const USDC_DECIMALS = 6;
const DEFAULT_AMOUNT = 1000;

// ============ Argument Parsing ============

interface Args {
  amount: number;
  to?: string;
}

function parseArgs(): Args {
  const args = process.argv.slice(2);

  const amountArg = args.find((a) => a.startsWith("--amount="));
  const toArg = args.find((a) => a.startsWith("--to="));

  return {
    amount: amountArg ? parseInt(amountArg.replace("--amount=", ""), 10) : DEFAULT_AMOUNT,
    to: toArg ? toArg.replace("--to=", "") : undefined,
  };
}

// ============ Environment Validation ============

interface EnvConfig {
  rpcUrl: string;
  privateKeyDeployer: string;
  privateKeyTestNoNative?: string;
  chainId: string;
}

function validateEnv(options: { requireTestKey: boolean }): EnvConfig {
  const rpcUrl = process.env.RPC_URL;
  const privateKeyDeployer = process.env.PRIVATE_KEY_DEPLOYER || process.env.PRIVATE_KEY;
  const privateKeyTestNoNative = process.env.PRIVATE_KEY_TEST_NO_NATIVE;
  const chainId = process.env.CHAIN_ID || "8283";

  if (!rpcUrl) {
    throw new Error("RPC_URL is not set in .env");
  }

  if (!privateKeyDeployer) {
    throw new Error("PRIVATE_KEY_DEPLOYER (or PRIVATE_KEY) is not set in .env");
  }

  if (options.requireTestKey && !privateKeyTestNoNative) {
    throw new Error("PRIVATE_KEY_TEST_NO_NATIVE is not set in .env (required when --to is not specified)");
  }

  return { rpcUrl, privateKeyDeployer, privateKeyTestNoNative, chainId };
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

function loadUsdcAddress(chainId: string): string {
  const addressesPath = path.join(PROJECT_ROOT, "deployments", chainId, "addresses.json");

  if (!fs.existsSync(addressesPath)) {
    throw new Error(`Deployment addresses not found: ${addressesPath}\nPlease deploy tokens first.`);
  }

  const content = fs.readFileSync(addressesPath, "utf8");
  const addresses = JSON.parse(content);

  if (!addresses.usdc) {
    throw new Error("USDC address not found in deployment addresses");
  }

  return addresses.usdc;
}

// ============ Balance Check ============

function getUsdcBalance(usdcAddress: string, accountAddress: string, rpcUrl: string): bigint {
  try {
    const result = execSync(
      `cast call ${usdcAddress} "balanceOf(address)(uint256)" ${accountAddress} --rpc-url ${rpcUrl}`,
      {
        encoding: "utf8",
        stdio: ["pipe", "pipe", "pipe"],
      }
    );
    // cast call returns format like "1000000000000 [1e12]" - extract just the number
    const numberPart = result.trim().split(" ")[0];
    return BigInt(numberPart);
  } catch {
    return BigInt(0);
  }
}

function formatUsdc(amount: bigint): string {
  const divisor = BigInt(10 ** USDC_DECIMALS);
  const whole = amount / divisor;
  const fraction = amount % divisor;
  return `${whole}.${fraction.toString().padStart(USDC_DECIMALS, "0")} USDC`;
}

// ============ Transfer ============

function transferUsdc(options: {
  usdcAddress: string;
  from: string;
  to: string;
  amount: bigint;
  privateKey: string;
  rpcUrl: string;
}): void {
  const { usdcAddress, from, to, amount, privateKey, rpcUrl } = options;

  console.log(`\nTransferring ${formatUsdc(amount)}...`);
  console.log(`  From: ${from}`);
  console.log(`  To:   ${to}`);

  const command = [
    "cast",
    "send",
    usdcAddress,
    '"transfer(address,uint256)"',
    to,
    amount.toString(),
    "--private-key",
    privateKey,
    "--rpc-url",
    rpcUrl,
  ].join(" ");

  console.log(`\nCommand: ${command.replace(privateKey, "***")}\n`);

  try {
    execSync(command, {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
    });
    console.log("\n✅ Transfer successful!");
  } catch (error) {
    console.error("\n❌ Transfer failed");
    throw error;
  }
}

// ============ Main ============

function main(): void {
  console.log("=".repeat(60));
  console.log("  USDC Transfer");
  console.log("=".repeat(60));

  const { amount, to } = parseArgs();
  const { rpcUrl, privateKeyDeployer, privateKeyTestNoNative, chainId } = validateEnv({
    requireTestKey: !to,
  });

  // Get addresses
  const fromAddress = getAddressFromPrivateKey(privateKeyDeployer);
  const toAddress = to || getAddressFromPrivateKey(privateKeyTestNoNative!);
  const usdcAddress = loadUsdcAddress(chainId);

  // Calculate amount with decimals
  const amountWithDecimals = BigInt(amount) * BigInt(10 ** USDC_DECIMALS);

  console.log(`\nConfiguration:`);
  console.log(`  RPC URL:      ${rpcUrl}`);
  console.log(`  Chain ID:     ${chainId}`);
  console.log(`  USDC Address: ${usdcAddress}`);
  console.log(`  Amount:       ${amount} USDC (${amountWithDecimals} raw)`);

  // Check balances before
  console.log(`\nBalances (before):`);
  const fromBalanceBefore = getUsdcBalance(usdcAddress, fromAddress, rpcUrl);
  const toBalanceBefore = getUsdcBalance(usdcAddress, toAddress, rpcUrl);
  console.log(`  From (${fromAddress}): ${formatUsdc(fromBalanceBefore)}`);
  console.log(`  To   (${toAddress}): ${formatUsdc(toBalanceBefore)}`);

  // Validate sufficient balance
  if (fromBalanceBefore < amountWithDecimals) {
    throw new Error(
      `Insufficient USDC balance. Have: ${formatUsdc(fromBalanceBefore)}, Need: ${formatUsdc(amountWithDecimals)}`
    );
  }

  // Execute transfer
  transferUsdc({
    usdcAddress,
    from: fromAddress,
    to: toAddress,
    amount: amountWithDecimals,
    privateKey: privateKeyDeployer,
    rpcUrl,
  });

  // Check balances after
  console.log(`\nBalances (after):`);
  const fromBalanceAfter = getUsdcBalance(usdcAddress, fromAddress, rpcUrl);
  const toBalanceAfter = getUsdcBalance(usdcAddress, toAddress, rpcUrl);
  console.log(`  From (${fromAddress}): ${formatUsdc(fromBalanceAfter)}`);
  console.log(`  To   (${toAddress}): ${formatUsdc(toBalanceAfter)}`);

  console.log("\n" + "=".repeat(60));
}

main();
