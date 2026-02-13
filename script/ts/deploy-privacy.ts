#!/usr/bin/env npx ts-node
/**
 * Privacy Contracts Deployment Script (ERC-5564/6538 Stealth Addresses)
 *
 * Deploys Privacy modules using forge script
 * - ERC5564Announcer: Stealth address announcement system
 * - ERC6538Registry: Stealth meta-address registry
 * - PrivateBank: Privacy-preserving deposit/withdrawal system
 *
 * Usage:
 *   npx ts-node script/ts/deploy-privacy.ts [--broadcast] [--verify] [--force]
 *
 * Options:
 *   --broadcast  Actually broadcast transactions (otherwise dry run)
 *   --verify     Verify contracts on block explorer (can run standalone)
 *   --force      Force redeploy even if contracts already exist
 *
 * Examples:
 *   npx ts-node script/ts/deploy-privacy.ts                    # Dry run
 *   npx ts-node script/ts/deploy-privacy.ts --broadcast        # Deploy
 *   npx ts-node script/ts/deploy-privacy.ts --verify           # Verify only
 *   npx ts-node script/ts/deploy-privacy.ts --broadcast --verify  # Deploy + verify
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const FORGE_SCRIPT = "script/deploy-contract/DeployPrivacy.s.sol:DeployPrivacyScript";
const FOUNDRY_PROFILE = "privacy";

// Contract names, artifacts, and their JSON keys
const CONTRACTS = [
  { name: "ERC5564Announcer", artifact: "src/privacy/ERC5564Announcer.sol:ERC5564Announcer", jsonKey: "erc5564Announcer", hasConstructorArgs: false },
  { name: "ERC6538Registry", artifact: "src/privacy/ERC6538Registry.sol:ERC6538Registry", jsonKey: "erc6538Registry", hasConstructorArgs: false },
  { name: "PrivateBank", artifact: "src/privacy/PrivateBank.sol:PrivateBank", jsonKey: "privateBank", hasConstructorArgs: true },
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
  constructorArgs?: string;
}): string | null {
  const verifierUrl = process.env.VERIFIER_URL;

  if (!verifierUrl) {
    console.log("⚠️  VERIFIER_URL is not set in .env, skipping verification");
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
  addresses: DeployedAddresses
): string | undefined {
  switch (contractName) {
    case "PrivateBank":
      // constructor(address announcer, address registry)
      const announcerAddr = addresses["erc5564Announcer"];
      const registryAddr = addresses["erc6538Registry"];

      if (!announcerAddr || !registryAddr) {
        console.log("Warning: Missing announcer or registry address for PrivateBank verification");
        return undefined;
      }

      const announcerArg = announcerAddr.toLowerCase().replace("0x", "").padStart(64, "0");
      const registryArg = registryAddr.toLowerCase().replace("0x", "").padStart(64, "0");
      return announcerArg + registryArg;

    default:
      return undefined;
  }
}

// ============ Contract Verification ============

function verifyContracts(chainId: string): void {
  const addresses = loadDeployedAddresses(chainId);

  const hasAnyAddress = CONTRACTS.some((c) => addresses[c.jsonKey]);
  if (!hasAnyAddress) {
    console.log("No deployed Privacy addresses found to verify");
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
      ? buildConstructorArgs(contract.name, addresses)
      : undefined;

    const verifyCmd = buildVerifyCommand({
      contractAddress: address,
      contractArtifact: contract.artifact,
      constructorArgs,
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
      console.log(`✅ ${contract.name} verified successfully`);
    } catch {
      console.error(`⚠️  ${contract.name} verification failed (contract may already be verified)`);
    }
  }
}

// ============ Main ============

function main(): void {
  const { broadcast, verify, force } = parseArgs();

  // Verify-only mode: skip deployment, just verify existing contracts
  const verifyOnly = verify && !broadcast && !force;

  console.log("=".repeat(60));
  console.log("  Privacy Contracts Deployment (ERC-5564/6538)");
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
      console.log("✅ Privacy deployment completed!");
      console.log("\nDeployed addresses saved to: deployments/" + chainId + "/addresses.json");

      // Step 2: Verify contracts (if requested and deployment was broadcast)
      if (verify) {
        verifyContracts(chainId);
      }

      console.log("\nNext steps:");
      console.log("  1. Deploy Permit2: ./script/deploy-permit2.sh --broadcast");
      console.log("  2. Configure privacy contracts for your use case");
      console.log("\nPrivacy System Usage:");
      console.log("  1. Users register stealth meta-address in ERC6538Registry");
      console.log("  2. Senders deposit to PrivateBank with computed stealth address");
      console.log("  3. Recipients scan ERC5564 announcements and withdraw");
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
