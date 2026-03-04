#!/usr/bin/env npx ts-node
/**
 * Bridge Contracts Deployment Script
 *
 * Deploys Bridge contracts using forge script
 * - FraudProofVerifier: Dispute resolution via fraud proofs
 * - BridgeRateLimiter: Volume and rate controls
 * - BridgeValidator: MPC signing (threshold signatures)
 * - BridgeGuardian: Emergency response system
 * - OptimisticVerifier: Challenge period verification
 * - SecureBridge: Main bridge integrating all security layers
 *
 * Usage:
 *   npx ts-node script/ts/deploy-bridge.ts [--broadcast] [--verify] [--force]
 *
 * Options:
 *   --broadcast  Actually broadcast transactions (otherwise dry run)
 *   --verify     Verify contracts on block explorer (can run standalone)
 *   --force      Force redeploy even if contracts already exist
 *
 * Examples:
 *   npx ts-node script/ts/deploy-bridge.ts                    # Dry run
 *   npx ts-node script/ts/deploy-bridge.ts --broadcast        # Deploy
 *   npx ts-node script/ts/deploy-bridge.ts --verify           # Verify only
 *   npx ts-node script/ts/deploy-bridge.ts --broadcast --verify  # Deploy + verify
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const FORGE_SCRIPT = "script/deploy-contract/DeployBridge.s.sol:DeployBridgeScript";
const FOUNDRY_PROFILE = "bridge";

// Contract names, artifacts, and their JSON keys
const CONTRACTS = [
  { name: "FraudProofVerifier", artifact: "src/bridge/FraudProofVerifier.sol:FraudProofVerifier", jsonKey: "fraudProofVerifier" },
  { name: "BridgeRateLimiter", artifact: "src/bridge/BridgeRateLimiter.sol:BridgeRateLimiter", jsonKey: "bridgeRateLimiter" },
  { name: "BridgeValidator", artifact: "src/bridge/BridgeValidator.sol:BridgeValidator", jsonKey: "bridgeValidator" },
  { name: "BridgeGuardian", artifact: "src/bridge/BridgeGuardian.sol:BridgeGuardian", jsonKey: "bridgeGuardian" },
  { name: "OptimisticVerifier", artifact: "src/bridge/OptimisticVerifier.sol:OptimisticVerifier", jsonKey: "optimisticVerifier" },
  { name: "SecureBridge", artifact: "src/bridge/SecureBridge.sol:SecureBridge", jsonKey: "secureBridge" },
];

// NOTE: This script uses execSync for forge CLI invocations with controlled inputs only.
// All command arguments are hardcoded or derived from validated environment variables,
// not from user-supplied input, so shell injection is not a concern here.

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

function validateEnv(options: { requirePrivateKey?: boolean } = {}): {
  rpcUrl: string;
  privateKey: string;
  chainId: string;
} {
  const { requirePrivateKey = true } = options;

  const rpcUrl = process.env.RPC_URL;
  const privateKey = process.env.PRIVATE_KEY_DEPLOYER || process.env.PRIVATE_KEY || "";
  const chainId = process.env.CHAIN_ID || "8283";

  if (!rpcUrl) {
    throw new Error("RPC_URL is not set in .env");
  }

  if (requirePrivateKey && !privateKey) {
    throw new Error("PRIVATE_KEY_DEPLOYER (or PRIVATE_KEY) is not set in .env");
  }

  return { rpcUrl, privateKey, chainId };
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
    "--non-interactive",
  ];

  if (options.broadcast) {
    args.push("--broadcast");
  }

  return args.join(" ");
}

function buildVerifyCommand(options: {
  contractAddress: string;
  contractArtifact: string;
}): string | null {
  const verifierUrl = process.env.VERIFIER_URL;

  if (!verifierUrl) {
    console.log("VERIFIER_URL is not set in .env, skipping verification");
    return null;
  }

  const args = [
    "forge",
    "verify-contract",
    "--verifier-url",
    verifierUrl,
    "--verifier",
    "custom",
    "--chain-id",
    process.env.CHAIN_ID || "8283",
    options.contractAddress,
    options.contractArtifact,
  ];

  return args.join(" ");
}

// ============ Deployment Address Loader ============

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

// ============ Contract Verification ============

function verifyContracts(chainId: string): void {
  const addresses = loadDeployedAddresses(chainId);

  const hasAnyAddress = CONTRACTS.some((c) => addresses[c.jsonKey]);
  if (!hasAnyAddress) {
    console.log("No deployed Bridge addresses found to verify");
    return;
  }

  console.log("\n" + "-".repeat(60));
  console.log("Starting contract verification...");
  console.log("-".repeat(60));

  for (const contract of CONTRACTS) {
    const address = addresses[contract.jsonKey];

    if (!address) {
      console.log(`${contract.name}: No address found, skipping`);
      continue;
    }

    console.log(`\nVerifying ${contract.name} at ${address}...`);

    const verifyCmd = buildVerifyCommand({
      contractAddress: address,
      contractArtifact: contract.artifact,
    });

    if (!verifyCmd) {
      return;
    }

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
    } catch {
      console.error(`${contract.name} verification failed (contract may already be verified)`);
    }
  }
}

// ============ Main ============

function main(): void {
  const { broadcast, verify, force } = parseArgs();

  // Verify-only mode: skip deployment, just verify existing contracts
  const verifyOnly = verify && !broadcast && !force;

  console.log("=".repeat(60));
  console.log("  Bridge Contracts Deployment");
  console.log("=".repeat(60));

  if (verifyOnly) {
    const { chainId } = validateEnv({ requirePrivateKey: false });

    console.log(`Chain ID: ${chainId}`);
    console.log(`Mode: VERIFY ONLY`);
    console.log(`Profile: FOUNDRY_PROFILE=${FOUNDRY_PROFILE}`);
    console.log("=".repeat(60));

    verifyContracts(chainId);

    console.log("\n" + "=".repeat(60));
    return;
  }

  const { rpcUrl, privateKey, chainId } = validateEnv();

  console.log(`RPC URL: ${rpcUrl}`);
  console.log(`Chain ID: ${chainId}`);
  console.log(`Broadcast: ${broadcast ? "YES" : "NO (dry run)"}`);
  console.log(`Verify: ${verify ? "YES (after deployment)" : "NO"}`);
  console.log(`Force Redeploy: ${force ? "YES" : "NO"}`);
  console.log(`Profile: FOUNDRY_PROFILE=${FOUNDRY_PROFILE}`);
  console.log("-".repeat(60));
  console.log("Contracts to deploy:");
  CONTRACTS.forEach((c) => console.log(`  - ${c.name}`));
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
        FORCE_REDEPLOY: force ? "true" : "",
      },
    });

    console.log("\n" + "=".repeat(60));
    if (broadcast) {
      console.log("✅ Bridge deployment completed!");
      console.log("\nDeployed addresses saved to: deployments/" + chainId + "/addresses.json");

      // Step 2: Verify contracts (if requested and deployment was broadcast)
      if (verify) {
        verifyContracts(chainId);
      }

      console.log("\nSecurity Layers:");
      console.log("  1. MPC Signing (BridgeValidator)");
      console.log("  2. Optimistic Verification (OptimisticVerifier)");
      console.log("  3. Fraud Proofs (FraudProofVerifier)");
      console.log("  4. Rate Limiting (BridgeRateLimiter)");
      console.log("  5. Guardian System (BridgeGuardian)");
    } else {
      console.log("✅ Dry run completed. Use --broadcast to deploy.");
    }
    console.log("=".repeat(60));
  } catch {
    console.error("\n❌ Deployment failed");
    process.exit(1);
  }
}

main();
