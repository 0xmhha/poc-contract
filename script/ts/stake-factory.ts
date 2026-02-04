#!/usr/bin/env npx ts-node
/**
 * FactoryStaker Staking Script
 *
 * Stakes FactoryStaker in EntryPoint for reputation (Factory needs stake for bundler trust)
 * Also approves KernelFactory in FactoryStaker
 *
 * Usage:
 *   npx ts-node script/ts/stake-factory.ts [--stake=<amount>] [--unstake-delay=<seconds>] [--approve] [--info]
 *
 * Options:
 *   --stake           Amount of native token to stake (in ETH/KRC, default: 1)
 *   --unstake-delay   Unstake delay in seconds (default: 86400 = 1 day)
 *   --approve         Approve KernelFactory in FactoryStaker
 *   --info            Show stake info only, no transactions
 *
 * Examples:
 *   npx ts-node script/ts/stake-factory.ts --info                  # Check current stake
 *   npx ts-node script/ts/stake-factory.ts --stake=1               # Stake 1 ETH/KRC
 *   npx ts-node script/ts/stake-factory.ts --approve               # Approve KernelFactory
 *   npx ts-node script/ts/stake-factory.ts --stake=1 --approve     # Stake + Approve
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const DEFAULT_STAKE = "1";
const DEFAULT_UNSTAKE_DELAY = 86400; // 1 day

// ============ Argument Parsing ============

interface Args {
  stake: string;
  unstakeDelay: number;
  approve: boolean;
  infoOnly: boolean;
}

function parseArgs(): Args {
  const args = process.argv.slice(2);

  const stakeArg = args.find((a) => a.startsWith("--stake="));
  const unstakeDelayArg = args.find((a) => a.startsWith("--unstake-delay="));
  const approve = args.includes("--approve");
  const infoOnly = args.includes("--info");

  return {
    stake: stakeArg ? stakeArg.replace("--stake=", "") : (infoOnly ? "0" : DEFAULT_STAKE),
    unstakeDelay: unstakeDelayArg ? parseInt(unstakeDelayArg.replace("--unstake-delay=", ""), 10) : DEFAULT_UNSTAKE_DELAY,
    approve,
    infoOnly,
  };
}

// ============ Environment Validation ============

interface EnvConfig {
  rpcUrl: string;
  privateKey: string;
  chainId: string;
}

function validateEnv(requireKey: boolean = true): EnvConfig {
  const rpcUrl = process.env.RPC_URL;
  const privateKey = process.env.PRIVATE_KEY_DEPLOYER || process.env.PRIVATE_KEY || "";
  const chainId = process.env.CHAIN_ID || "8283";

  if (!rpcUrl) {
    throw new Error("RPC_URL is not set in .env");
  }

  if (requireKey && !privateKey) {
    throw new Error("PRIVATE_KEY_DEPLOYER (or PRIVATE_KEY) is not set in .env");
  }

  return { rpcUrl, privateKey, chainId };
}

// ============ Address Helpers ============

interface DeployedAddresses {
  entryPoint?: string;
  factoryStaker?: string;
  kernelFactory?: string;
}

function loadDeployedAddresses(chainId: string): DeployedAddresses {
  const addressesPath = path.join(PROJECT_ROOT, "deployments", chainId, "addresses.json");

  if (!fs.existsSync(addressesPath)) {
    throw new Error(`Deployment addresses not found: ${addressesPath}\nPlease deploy contracts first.`);
  }

  const content = fs.readFileSync(addressesPath, "utf8");
  const addresses = JSON.parse(content);

  return {
    entryPoint: addresses.entryPoint,
    factoryStaker: addresses.factoryStaker,
    kernelFactory: addresses.kernelFactory,
  };
}

// ============ Balance & Info Helpers ============

function getNativeBalance(address: string, rpcUrl: string): bigint {
  try {
    const result = execSync(`cast balance ${address} --rpc-url ${rpcUrl}`, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
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

function isFactoryApproved(factoryStakerAddress: string, kernelFactoryAddress: string, rpcUrl: string): boolean {
  try {
    const result = execSync(
      `cast call ${factoryStakerAddress} "approved(address)(bool)" ${kernelFactoryAddress} --rpc-url ${rpcUrl}`,
      {
        encoding: "utf8",
        stdio: ["pipe", "pipe", "pipe"],
      }
    );
    return result.trim() === "true";
  } catch {
    return false;
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

// ============ Staking Functions ============

function stakeFactory(options: {
  factoryStakerAddress: string;
  entryPointAddress: string;
  amount: bigint;
  unstakeDelay: number;
  privateKey: string;
  rpcUrl: string;
}): void {
  const { factoryStakerAddress, entryPointAddress, amount, unstakeDelay, privateKey, rpcUrl } = options;

  console.log(`\nStaking ${formatEther(amount)} with ${unstakeDelay}s delay via FactoryStaker...`);

  // FactoryStaker.stake(IEntryPoint entryPoint, uint32 unstakeDelay) payable
  const command = [
    "cast",
    "send",
    factoryStakerAddress,
    '"stake(address,uint32)"',
    entryPointAddress,
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

function approveFactory(options: {
  factoryStakerAddress: string;
  kernelFactoryAddress: string;
  privateKey: string;
  rpcUrl: string;
}): void {
  const { factoryStakerAddress, kernelFactoryAddress, privateKey, rpcUrl } = options;

  console.log(`\nApproving KernelFactory in FactoryStaker...`);

  // FactoryStaker.approveFactory(KernelFactory factory, bool approval) payable
  const command = [
    "cast",
    "send",
    factoryStakerAddress,
    '"approveFactory(address,bool)"',
    kernelFactoryAddress,
    "true",
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
    console.log("✅ Factory approved!");
  } catch (error) {
    console.error("❌ Factory approval failed");
    throw error;
  }
}

// ============ Main ============

function main(): void {
  console.log("=".repeat(60));
  console.log("  FactoryStaker Staking");
  console.log("=".repeat(60));

  const { stake, unstakeDelay, approve, infoOnly } = parseArgs();
  const { rpcUrl, privateKey, chainId } = validateEnv(!infoOnly);

  // Load deployed addresses
  const addresses = loadDeployedAddresses(chainId);

  if (!addresses.entryPoint) {
    throw new Error("EntryPoint address not found. Please deploy EntryPoint first.");
  }
  if (!addresses.factoryStaker) {
    throw new Error("FactoryStaker address not found. Please deploy Smart Account first.");
  }
  if (!addresses.kernelFactory) {
    throw new Error("KernelFactory address not found. Please deploy Smart Account first.");
  }

  console.log(`\nConfiguration:`);
  console.log(`  RPC URL:         ${rpcUrl}`);
  console.log(`  Chain ID:        ${chainId}`);
  console.log(`  EntryPoint:      ${addresses.entryPoint}`);
  console.log(`  FactoryStaker:   ${addresses.factoryStaker}`);
  console.log(`  KernelFactory:   ${addresses.kernelFactory}`);

  if (!infoOnly) {
    console.log(`  Stake Amount:    ${stake} ETH/KRC`);
    if (parseFloat(stake) > 0) {
      console.log(`  Unstake Delay:   ${unstakeDelay} seconds`);
    }
    console.log(`  Approve Factory: ${approve ? "YES" : "NO"}`);
  }

  // Get current info
  console.log(`\n${"─".repeat(60)}`);
  console.log("Current Status:");
  console.log("─".repeat(60));

  const factoryStakerBalance = getNativeBalance(addresses.factoryStaker, rpcUrl);
  const depositInfo = getDepositInfo(addresses.entryPoint, addresses.factoryStaker, rpcUrl);
  const factoryApproved = isFactoryApproved(addresses.factoryStaker, addresses.kernelFactory, rpcUrl);

  console.log(`  FactoryStaker Balance: ${formatEther(factoryStakerBalance)} ETH/KRC`);
  console.log(`  EP Deposit:            ${formatEther(depositInfo.deposit)} ETH/KRC`);
  console.log(`  EP Staked:             ${depositInfo.staked ? "Yes" : "No"}`);
  console.log(`  EP Stake Amount:       ${formatEther(depositInfo.stake)} ETH/KRC`);
  if (depositInfo.staked) {
    console.log(`  Unstake Delay:         ${depositInfo.unstakeDelaySec} seconds`);
  }
  console.log(`  KernelFactory Approved: ${factoryApproved ? "Yes" : "No"}`);

  if (infoOnly) {
    console.log("\n" + "=".repeat(60));
    return;
  }

  // Execute transactions
  const stakeAmount = parseEther(stake);

  // Stake
  if (stakeAmount > BigInt(0)) {
    stakeFactory({
      factoryStakerAddress: addresses.factoryStaker,
      entryPointAddress: addresses.entryPoint,
      amount: stakeAmount,
      unstakeDelay,
      privateKey,
      rpcUrl,
    });
  }

  // Approve factory
  if (approve && !factoryApproved) {
    approveFactory({
      factoryStakerAddress: addresses.factoryStaker,
      kernelFactoryAddress: addresses.kernelFactory,
      privateKey,
      rpcUrl,
    });
  } else if (approve && factoryApproved) {
    console.log("\nKernelFactory is already approved, skipping...");
  }

  // Show updated info
  console.log(`\n${"─".repeat(60)}`);
  console.log("Updated Status:");
  console.log("─".repeat(60));

  const newDepositInfo = getDepositInfo(addresses.entryPoint, addresses.factoryStaker, rpcUrl);
  const newFactoryApproved = isFactoryApproved(addresses.factoryStaker, addresses.kernelFactory, rpcUrl);

  console.log(`  EP Deposit:            ${formatEther(newDepositInfo.deposit)} ETH/KRC`);
  console.log(`  EP Staked:             ${newDepositInfo.staked ? "Yes" : "No"}`);
  console.log(`  EP Stake Amount:       ${formatEther(newDepositInfo.stake)} ETH/KRC`);
  if (newDepositInfo.staked) {
    console.log(`  Unstake Delay:         ${newDepositInfo.unstakeDelaySec} seconds`);
  }
  console.log(`  KernelFactory Approved: ${newFactoryApproved ? "Yes" : "No"}`);

  console.log("\n" + "=".repeat(60));
  console.log("✅ FactoryStaker setup completed!");
  console.log("=".repeat(60));
}

main();
