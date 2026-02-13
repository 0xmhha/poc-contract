#!/usr/bin/env npx ts-node
/**
 * EntryPoint Deployment Script (CREATE2)
 *
 * Deploys ERC-4337 EntryPoint contract via CREATE2 for deterministic cross-chain addresses.
 * Requires Nick's Deterministic Deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C).
 *
 * Usage:
 *   npx ts-node script/ts/deploy-entrypoint.ts [--broadcast] [--verify] [--force]
 *
 * Options:
 *   --broadcast  Actually broadcast transactions (otherwise dry run)
 *   --verify     Verify contracts on block explorer (can run standalone)
 *   --force      Force redeploy even if contracts already exist
 *
 * Examples:
 *   npx ts-node script/ts/deploy-entrypoint.ts                    # Dry run
 *   npx ts-node script/ts/deploy-entrypoint.ts --broadcast        # Deploy
 *   npx ts-node script/ts/deploy-entrypoint.ts --verify           # Verify only
 *   npx ts-node script/ts/deploy-entrypoint.ts --broadcast --verify  # Deploy + verify
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";
import { ensureCREATE2Deployer } from "./ensure-create2-deployer";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const FORGE_SCRIPT = "script/deploy-contract/DeployEntryPoint.s.sol:DeployEntryPointScript";
const FOUNDRY_PROFILE = "entrypoint";

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

function loadDeployedAddresses(chainId: string): { entryPoint?: string } {
  const addressesPath = path.join(PROJECT_ROOT, "deployments", chainId, "addresses.json");

  if (!fs.existsSync(addressesPath)) {
    return {};
  }

  try {
    const content = fs.readFileSync(addressesPath, "utf8");
    const addresses = JSON.parse(content);
    return {
      entryPoint: addresses.entryPoint,
    };
  } catch {
    return {};
  }
}

// ============ Contract Verification ============

function verifyContracts(chainId: string): void {
  const addresses = loadDeployedAddresses(chainId);

  if (!addresses.entryPoint) {
    console.log("No deployed EntryPoint address found to verify");
    return;
  }

  console.log("\n" + "-".repeat(60));
  console.log("Starting contract verification...");
  console.log("-".repeat(60));

  const contracts = [
    { name: "EntryPoint", artifact: "src/erc4337-entrypoint/EntryPoint.sol:EntryPoint", address: addresses.entryPoint },
  ];

  for (const contract of contracts) {
    if (!contract.address) {
      console.log(`${contract.name}: No address found, skipping`);
      continue;
    }

    console.log(`\nVerifying ${contract.name} at ${contract.address}...`);

    const verifyCmd = buildVerifyCommand({
      contractAddress: contract.address,
      contractArtifact: contract.artifact,
    });

    if (!verifyCmd) {
      return; // VERIFIER_URL not set
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
      console.log(`${contract.name} verified successfully`);
    } catch (error) {
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
  console.log("  EntryPoint Deployment (ERC-4337 via CREATE2)");
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
  console.log(`Deploy Salt: ${process.env.ENTRYPOINT_DEPLOY_SALT || "(default: stable-net-entrypoint-v1)"}`);
  console.log(`Profile: FOUNDRY_PROFILE=${FOUNDRY_PROFILE}`);
  console.log("=".repeat(60));

  // Step 0: Check CREATE2 deployer availability (fallback to regular CREATE)
  let useCreate2 = false;
  if (broadcast) {
    console.log("\n[Step 0] Checking CREATE2 deployer on chain...");
    useCreate2 = ensureCREATE2Deployer();
    if (useCreate2) {
      console.log("  CREATE2 deployer available - using deterministic deployment");
    } else {
      console.log("  CREATE2 deployer unavailable - falling back to regular CREATE");
    }
  }

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
        USE_CREATE2: useCreate2 ? "true" : "",
      },
    });

    console.log("\n" + "=".repeat(60));
    if (broadcast) {
      console.log("EntryPoint deployment completed!");
      console.log("\nDeployed addresses saved to: deployments/" + chainId + "/addresses.json");

      // Step 2: Verify contracts (if requested and deployment was broadcast)
      if (verify) {
        verifyContracts(chainId);
      }
    } else {
      console.log("Dry run completed. Use --broadcast to deploy.");
    }
    console.log("=".repeat(60));
  } catch (error) {
    console.error("\nDeployment failed");
    process.exit(1);
  }
}

main();
