#!/usr/bin/env npx ts-node
/**
 * Compliance Contracts Deployment Script
 *
 * Deploys Compliance modules using forge script
 * - KYCRegistry: KYC status management with multi-jurisdiction support
 * - AuditLogger: Immutable audit logging for regulatory compliance
 * - ProofOfReserve: 100% reserve verification using Chainlink PoR
 * - RegulatoryRegistry: Regulator management with 2-of-3 multi-sig trace approval
 *
 * Usage:
 *   npx ts-node script/ts/deploy-compliance.ts [--broadcast] [--verify] [--force]
 *
 * Options:
 *   --broadcast  Actually broadcast transactions (otherwise dry run)
 *   --verify     Verify contracts on block explorer (can run standalone)
 *   --force      Force redeploy even if contracts already exist
 *
 * Environment Variables:
 *   ADMIN_ADDRESS: Admin address for contracts (defaults to deployer)
 *   RETENTION_PERIOD: AuditLogger retention period in seconds (default: 7 years)
 *   AUTO_PAUSE_THRESHOLD: ProofOfReserve auto-pause threshold (default: 3)
 *   APPROVER_1, APPROVER_2, APPROVER_3: RegulatoryRegistry approvers
 *
 * Examples:
 *   npx ts-node script/ts/deploy-compliance.ts                    # Dry run
 *   npx ts-node script/ts/deploy-compliance.ts --broadcast        # Deploy
 *   npx ts-node script/ts/deploy-compliance.ts --verify           # Verify only
 *   npx ts-node script/ts/deploy-compliance.ts --broadcast --verify  # Deploy + verify
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const FORGE_SCRIPT = "script/deploy-contract/DeployCompliance.s.sol:DeployComplianceScript";
const FOUNDRY_PROFILE = "compliance";

// Contract names and their JSON keys
const CONTRACTS = [
  { name: "KYCRegistry", jsonKey: "kycRegistry", hasConstructorArgs: true },
  { name: "AuditLogger", jsonKey: "auditLogger", hasConstructorArgs: true },
  { name: "ProofOfReserve", jsonKey: "proofOfReserve", hasConstructorArgs: true },
  { name: "RegulatoryRegistry", jsonKey: "regulatoryRegistry", hasConstructorArgs: true },
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

  if (options.constructorArgs) {
    args.push("--constructor-args", options.constructorArgs);
  }

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

// ============ Constructor Args Builder ============

function buildConstructorArgs(
  contractName: string,
  deployerAddress: string
): string | undefined {
  const adminAddress = process.env.ADMIN_ADDRESS || deployerAddress;
  const retentionPeriod = process.env.RETENTION_PERIOD || String(7 * 365 * 24 * 60 * 60); // 7 years in seconds
  const autoPauseThreshold = process.env.AUTO_PAUSE_THRESHOLD || "3";

  switch (contractName) {
    case "KYCRegistry":
      // constructor(address admin)
      return adminAddress.toLowerCase().replace("0x", "").padStart(64, "0");

    case "AuditLogger":
      // constructor(address admin, uint256 retentionPeriod)
      const adminArg = adminAddress.toLowerCase().replace("0x", "").padStart(64, "0");
      const retentionArg = BigInt(retentionPeriod).toString(16).padStart(64, "0");
      return adminArg + retentionArg;

    case "ProofOfReserve":
      // constructor(address admin, uint256 autoPauseThreshold)
      const adminArg2 = adminAddress.toLowerCase().replace("0x", "").padStart(64, "0");
      const thresholdArg = BigInt(autoPauseThreshold).toString(16).padStart(64, "0");
      return adminArg2 + thresholdArg;

    case "RegulatoryRegistry":
      // constructor(address[] memory approvers) - dynamic array encoding is complex
      // Skip verification for this contract or use manual verification
      return undefined;

    default:
      return undefined;
  }
}

// ============ Contract Verification ============

function verifyContracts(chainId: string, deployerAddress: string): void {
  const addresses = loadDeployedAddresses(chainId);

  const hasAnyAddress = CONTRACTS.some((c) => addresses[c.jsonKey]);
  if (!hasAnyAddress) {
    console.log("No deployed Compliance addresses found to verify");
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

    const constructorArgs = contract.hasConstructorArgs
      ? buildConstructorArgs(contract.name, deployerAddress)
      : undefined;

    if (contract.name === "RegulatoryRegistry") {
      console.log(`${contract.name}: Skipping verification (dynamic array constructor args)`);
      console.log("  Use manual verification: forge verify-contract --constructor-args-path <file>");
      continue;
    }

    const verifyCmd = buildVerifyCommand({
      contractAddress: address,
      contractName: contract.name,
      constructorArgs,
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
  console.log("  Compliance Contracts Deployment");
  console.log("=".repeat(60));

  if (verifyOnly) {
    const { chainId, privateKey } = validateEnv({ requirePrivateKey: true });

    console.log(`Chain ID: ${chainId}`);
    console.log(`Mode: VERIFY ONLY`);
    console.log(`Profile: FOUNDRY_PROFILE=${FOUNDRY_PROFILE}`);
    console.log("=".repeat(60));

    const deployerAddress = getDeployerAddress(privateKey);
    verifyContracts(chainId, deployerAddress);

    console.log("\n" + "=".repeat(60));
    return;
  }

  const { rpcUrl, privateKey, chainId } = validateEnv();
  const deployerAddress = getDeployerAddress(privateKey);
  const adminAddress = process.env.ADMIN_ADDRESS || deployerAddress;

  console.log(`RPC URL: ${rpcUrl}`);
  console.log(`Chain ID: ${chainId}`);
  console.log(`Broadcast: ${broadcast ? "YES" : "NO (dry run)"}`);
  console.log(`Verify: ${verify ? "YES (after deployment)" : "NO"}`);
  console.log(`Force Redeploy: ${force ? "YES" : "NO"}`);
  console.log(`Profile: FOUNDRY_PROFILE=${FOUNDRY_PROFILE}`);
  console.log("-".repeat(60));
  console.log(`Admin Address: ${adminAddress}`);
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
      console.log("✅ Compliance deployment completed!");
      console.log("\nDeployed addresses saved to: deployments/" + chainId + "/addresses.json");

      // Step 2: Verify contracts (if requested and deployment was broadcast)
      if (verify) {
        verifyContracts(chainId, deployerAddress);
      }

      console.log("\nNext steps:");
      console.log("  1. Deploy privacy modules: ./script/deploy-privacy.sh --broadcast");
      console.log("  2. Configure compliance contracts for your use case");
      console.log("\nCompliance Use Cases:");
      console.log("  - KYCRegistry: KYC status and sanctions management");
      console.log("  - AuditLogger: Immutable audit trail for compliance");
      console.log("  - ProofOfReserve: Reserve verification (configure oracle)");
      console.log("  - RegulatoryRegistry: 2-of-3 trace request approval");
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
