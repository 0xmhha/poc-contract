#!/usr/bin/env npx ts-node
/**
 * Permit2 Contract Deployment Script
 *
 * Deploys Uniswap's Permit2 for signature-based token transfers
 * - SignatureTransfer: One-time permit signatures for token transfers
 * - AllowanceTransfer: Persistent allowances with expiration
 * - EIP-712: Cross-chain replay protection
 *
 * Usage:
 *   npx ts-node script/ts/deploy-permit2.ts [--broadcast] [--verify] [--force]
 *
 * Options:
 *   --broadcast  Actually broadcast transactions (otherwise dry run)
 *   --verify     Verify contracts on block explorer (can run standalone)
 *   --force      Force redeploy even if contracts already exist
 *
 * Examples:
 *   npx ts-node script/ts/deploy-permit2.ts                    # Dry run
 *   npx ts-node script/ts/deploy-permit2.ts --broadcast        # Deploy
 *   npx ts-node script/ts/deploy-permit2.ts --verify           # Verify only
 *   npx ts-node script/ts/deploy-permit2.ts --broadcast --verify  # Deploy + verify
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const FORGE_SCRIPT = "script/deploy-contract/DeployPermit2.s.sol:DeployPermit2Script";
const FOUNDRY_PROFILE = "permit2";

// Contract names, artifacts, and their JSON keys
const CONTRACTS = [
  { name: "Permit2", artifact: "src/permit2/Permit2.sol:Permit2", jsonKey: "permit2" },
];

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
    console.log("No deployed Permit2 address found to verify");
    return;
  }

  console.log("\n" + "-".repeat(60));
  console.log("Starting contract verification...");
  console.log("-".repeat(60));

  // Permit2 has no constructor arguments
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
  console.log("  Permit2 Contract Deployment");
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
      console.log("✅ Permit2 deployment completed!");
      console.log("\nDeployed addresses saved to: deployments/" + chainId + "/addresses.json");

      // Step 2: Verify contracts (if requested and deployment was broadcast)
      if (verify) {
        verifyContracts(chainId);
      }

      console.log("\n🎉 Feature Modules deployment complete!");
      console.log("\nAll Feature modules deployed:");
      console.log("  - Compliance: KYCRegistry, AuditLogger, ProofOfReserve, RegulatoryRegistry");
      console.log("  - Privacy: ERC5564Announcer, ERC6538Registry, PrivateBank");
      console.log("  - Permit2: Signature-based token transfers");
      console.log("\nNext steps:");
      console.log("  1. Deploy DeFi modules: ./script/deploy-defi.sh --broadcast");
      console.log("  2. Integrate Permit2 with your token contracts");
      console.log("\nPermit2 Features:");
      console.log("  - SignatureTransfer: One-time permit signatures");
      console.log("  - AllowanceTransfer: Persistent allowances with expiration");
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
