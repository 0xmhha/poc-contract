#!/usr/bin/env npx ts-node
/**
 * Token Deployment Script
 *
 * Deploys wKRC and USDC tokens using forge script
 *
 * Usage:
 *   npx ts-node script/ts/deploy-tokens.ts [--broadcast] [--verify] [--force]
 *
 * Options:
 *   --broadcast  Actually broadcast transactions (otherwise dry run)
 *   --verify     Verify contracts on block explorer (runs after deployment)
 *   --force      Force redeploy even if contracts already exist
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const FORGE_SCRIPT = "script/deploy-contract/DeployTokens.s.sol:DeployTokensScript";
const FOUNDRY_PROFILE = "tokens";

// ============ Argument Parsing ============

function parseArgs(): { broadcast: boolean; verify: boolean; force: boolean } {
  const args = process.argv.slice(2);
  return {
    broadcast: args.includes("--broadcast"),
    verify: args.includes("--verify"),
    force: args.includes("--force"),
  };
}

// ============ Environment Validation ============

function validateEnv(): { rpcUrl: string; privateKey: string; chainId: string } {
  const rpcUrl = process.env.RPC_URL;
  const privateKey = process.env.PRIVATE_KEY_DEPLOYER || process.env.PRIVATE_KEY;
  const chainId = process.env.CHAIN_ID || "8283";

  if (!rpcUrl) {
    throw new Error("RPC_URL is not set in .env");
  }

  if (!privateKey) {
    throw new Error("PRIVATE_KEY_DEPLOYER (or PRIVATE_KEY) is not set in .env");
  }

  return { rpcUrl, privateKey, chainId };
}

// ============ Deployer Address ============

function getDeployerAddress(privateKey: string): string {
  try {
    const result = execSync(`cast wallet address ${privateKey}`, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    return result.trim();
  } catch {
    throw new Error("Failed to get deployer address from private key");
  }
}

// ============ Forge Command Builders ============

function buildDeployCommand(options: {
  rpcUrl: string;
  privateKey: string;
  broadcast: boolean;
}): string {
  const args = [
    "forge",
    "script",
    FORGE_SCRIPT,
    "--rpc-url",
    options.rpcUrl,
    "--private-key",
    options.privateKey,
  ];

  if (options.broadcast) {
    args.push("--broadcast");
  }

  return args.join(" ");
}

function buildVerifyCommand(options: {
  contractAddress: string;
  contractName: string;
  constructorArgs?: string;
}): string {
  const verifierUrl = process.env.VERIFIER_URL;

  if (!verifierUrl) {
    throw new Error("VERIFIER_URL is not set in .env");
  }

  // forge verify-contract usage for custom verifier:
  // forge verify-contract --verifier-url <URL>/api --verifier custom <ADDRESS> <CONTRACT_NAME>
  const args = [
    "forge",
    "verify-contract",
    "--verifier-url",
    verifierUrl,
    "--verifier",
    "custom",
    options.contractAddress,
    options.contractName,
  ];

  // Add constructor args if provided
  if (options.constructorArgs) {
    args.push("--constructor-args", options.constructorArgs);
  }

  return args.join(" ");
}

// ============ Deployment Address Loader ============

function loadDeployedAddresses(chainId: string): { wkrc?: string; usdc?: string } {
  const addressesPath = path.join(PROJECT_ROOT, "deployments", chainId, "addresses.json");

  if (!fs.existsSync(addressesPath)) {
    return {};
  }

  try {
    const content = fs.readFileSync(addressesPath, "utf8");
    const addresses = JSON.parse(content);
    return {
      wkrc: addresses.wkrc,
      usdc: addresses.usdc,
    };
  } catch {
    return {};
  }
}

// ============ Contract Verification ============

function verifyContracts(chainId: string, deployerAddress: string): void {
  const addresses = loadDeployedAddresses(chainId);

  if (!addresses.wkrc && !addresses.usdc) {
    console.log("⚠️  No deployed addresses found to verify");
    return;
  }

  console.log("\n" + "-".repeat(60));
  console.log("Starting contract verification...");
  console.log("-".repeat(60));

  // USDC constructor: constructor(address owner_)
  // Need to encode constructor args for USDC
  const usdcConstructorArgs = deployerAddress.toLowerCase().padStart(64, "0");

  const contracts = [
    { name: "wKRC", address: addresses.wkrc, constructorArgs: undefined },
    { name: "USDC", address: addresses.usdc, constructorArgs: usdcConstructorArgs },
  ];

  for (const contract of contracts) {
    if (!contract.address) {
      console.log(`⚠️  ${contract.name}: No address found, skipping`);
      continue;
    }

    console.log(`\nVerifying ${contract.name} at ${contract.address}...`);

    const verifyCmd = buildVerifyCommand({
      contractAddress: contract.address,
      contractName: contract.name,
      constructorArgs: contract.constructorArgs,
    });

    console.log(`Command: ${verifyCmd}\n`);

    try {
      execSync(verifyCmd, {
        cwd: PROJECT_ROOT,
        stdio: "inherit",
        env: {
          ...process.env,
          FOUNDRY_PROFILE: FOUNDRY_PROFILE,
        },
      });
      console.log(`✅ ${contract.name} verified successfully`);
    } catch (error) {
      console.error(`⚠️  ${contract.name} verification failed (contract may already be verified)`);
    }
  }
}

// ============ Main ============

function main(): void {
  console.log("=".repeat(60));
  console.log("  Token Deployment (wKRC, USDC)");
  console.log("=".repeat(60));

  const { broadcast, verify, force } = parseArgs();
  const { rpcUrl, privateKey, chainId } = validateEnv();

  console.log(`RPC URL: ${rpcUrl}`);
  console.log(`Chain ID: ${chainId}`);
  console.log(`Broadcast: ${broadcast ? "YES" : "NO (dry run)"}`);
  console.log(`Verify: ${verify ? "YES (after deployment)" : "NO"}`);
  console.log(`Force Redeploy: ${force ? "YES" : "NO"}`);
  console.log(`Profile: FOUNDRY_PROFILE=${FOUNDRY_PROFILE}`);
  console.log("=".repeat(60));

  // Step 1: Deploy contracts
  const deployCmd = buildDeployCommand({
    rpcUrl,
    privateKey,
    broadcast,
  });

  console.log(`\nRunning: ${deployCmd.replace(privateKey, "***")}\n`);

  try {
    execSync(deployCmd, {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
      env: {
        ...process.env,
        FOUNDRY_PROFILE: FOUNDRY_PROFILE,
        ADMIN_ADDRESS: process.env.ADMIN_ADDRESS || "",
        FORCE_REDEPLOY: force ? "true" : "",
      },
    });

    console.log("\n" + "=".repeat(60));
    if (broadcast) {
      console.log("✅ Token deployment completed!");
      console.log("\nDeployed addresses saved to: deployments/" + chainId + "/addresses.json");

      // Step 2: Verify contracts (if requested and deployment was broadcast)
      if (verify) {
        const deployerAddress = getDeployerAddress(privateKey);
        verifyContracts(chainId, deployerAddress);
      }
    } else {
      console.log("✅ Dry run completed. Use --broadcast to deploy.");
    }
    console.log("=".repeat(60));
  } catch (error) {
    console.error("\n❌ Deployment failed");
    process.exit(1);
  }
}

main();
