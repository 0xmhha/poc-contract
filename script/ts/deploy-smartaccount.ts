#!/usr/bin/env npx ts-node
/**
 * Smart Account (Kernel) Deployment Script
 *
 * Deploys ERC-7579 Smart Account system using forge script
 * - Kernel (implementation)
 * - KernelFactory
 * - FactoryStaker
 *
 * Usage:
 *   npx ts-node script/ts/deploy-smartaccount.ts [--broadcast] [--verify] [--force]
 *
 * Options:
 *   --broadcast  Actually broadcast transactions (otherwise dry run)
 *   --verify     Verify contracts on block explorer (can run standalone)
 *   --force      Force redeploy even if contracts already exist
 *
 * Prerequisites:
 *   - EntryPoint must be deployed first (Phase 0)
 *
 * Examples:
 *   npx ts-node script/ts/deploy-smartaccount.ts                    # Dry run
 *   npx ts-node script/ts/deploy-smartaccount.ts --broadcast        # Deploy
 *   npx ts-node script/ts/deploy-smartaccount.ts --verify           # Verify only
 *   npx ts-node script/ts/deploy-smartaccount.ts --broadcast --verify  # Deploy + verify
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const FORGE_SCRIPT = "script/deploy-contract/DeployKernel.s.sol:DeployKernelScript";
const FOUNDRY_PROFILE = "smartaccount";

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
  entryPoint?: string;
  kernel?: string;
  kernelFactory?: string;
  factoryStaker?: string;
}

function loadDeployedAddresses(chainId: string): DeployedAddresses {
  const addressesPath = path.join(PROJECT_ROOT, "deployments", chainId, "addresses.json");

  if (!fs.existsSync(addressesPath)) {
    return {};
  }

  try {
    const content = fs.readFileSync(addressesPath, "utf8");
    const addresses = JSON.parse(content);
    return {
      entryPoint: addresses.entryPoint,
      kernel: addresses.kernel,
      kernelFactory: addresses.kernelFactory,
      factoryStaker: addresses.factoryStaker,
    };
  } catch {
    return {};
  }
}

// ============ Contract Verification ============

function verifyContracts(chainId: string, deployerAddress: string): void {
  const addresses = loadDeployedAddresses(chainId);

  if (!addresses.kernel && !addresses.kernelFactory && !addresses.factoryStaker) {
    console.log("No deployed Smart Account addresses found to verify");
    return;
  }

  console.log("\n" + "-".repeat(60));
  console.log("Starting contract verification...");
  console.log("-".repeat(60));

  // Constructor args (ABI-encoded, 32 bytes each)
  // Kernel: constructor(IEntryPoint _entrypoint)
  const kernelConstructorArgs = addresses.entryPoint
    ? addresses.entryPoint.toLowerCase().replace("0x", "").padStart(64, "0")
    : undefined;

  // KernelFactory: constructor(address _impl)
  const kernelFactoryConstructorArgs = addresses.kernel
    ? addresses.kernel.toLowerCase().replace("0x", "").padStart(64, "0")
    : undefined;

  // FactoryStaker: constructor(address _owner)
  const factoryStakerConstructorArgs = deployerAddress.toLowerCase().replace("0x", "").padStart(64, "0");

  const contracts = [
    {
      name: "Kernel",
      artifact: "src/erc7579-smartaccount/Kernel.sol:Kernel",
      address: addresses.kernel,
      constructorArgs: kernelConstructorArgs,
    },
    {
      name: "KernelFactory",
      artifact: "src/erc7579-smartaccount/factory/KernelFactory.sol:KernelFactory",
      address: addresses.kernelFactory,
      constructorArgs: kernelFactoryConstructorArgs,
    },
    {
      name: "FactoryStaker",
      artifact: "src/erc7579-smartaccount/factory/FactoryStaker.sol:FactoryStaker",
      address: addresses.factoryStaker,
      constructorArgs: factoryStakerConstructorArgs,
    },
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
      constructorArgs: contract.constructorArgs,
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
    } catch (error) {
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
  console.log("  Smart Account Deployment (Kernel, ERC-7579)");
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

  // Check EntryPoint dependency
  const addresses = loadDeployedAddresses(chainId);
  if (!addresses.entryPoint) {
    console.error("\n❌ Error: EntryPoint not deployed");
    console.error("Please deploy EntryPoint first: ./script/deploy-entrypoint.sh --broadcast");
    process.exit(1);
  }

  console.log(`RPC URL: ${rpcUrl}`);
  console.log(`Chain ID: ${chainId}`);
  console.log(`Broadcast: ${broadcast ? "YES" : "NO (dry run)"}`);
  console.log(`Verify: ${verify ? "YES (after deployment)" : "NO"}`);
  console.log(`Force Redeploy: ${force ? "YES" : "NO"}`);
  console.log(`Profile: FOUNDRY_PROFILE=${FOUNDRY_PROFILE}`);
  console.log("-".repeat(60));
  console.log(`EntryPoint: ${addresses.entryPoint}`);
  console.log("=".repeat(60));

  // Get deployer/owner address
  const deployerAddress = getDeployerAddress(privateKey);
  const ownerAddress = process.env.OWNER_ADDRESS || deployerAddress;

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
        ENTRYPOINT_ADDRESS: addresses.entryPoint,
        OWNER_ADDRESS: ownerAddress,
        FORCE_REDEPLOY: force ? "true" : "",
      },
    });

    console.log("\n" + "=".repeat(60));
    if (broadcast) {
      console.log("✅ Smart Account deployment completed!");
      console.log("\nDeployed addresses saved to: deployments/" + chainId + "/addresses.json");

      // Step 2: Verify contracts (if requested and deployment was broadcast)
      if (verify) {
        verifyContracts(chainId, deployerAddress);
      }

      console.log("\nNext steps:");
      console.log("  1. Deploy validators: ./script/deploy-validators.sh --broadcast");
      console.log("  2. Stake FactoryStaker in EntryPoint (for reputation)");
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
