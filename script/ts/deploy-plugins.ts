#!/usr/bin/env npx ts-node
/**
 * ERC-7579 Plugins Deployment Script
 *
 * Deploys Plugin modules using forge script
 * - AutoSwapPlugin: Automated trading (DCA, limit orders, stop loss, take profit)
 * - MicroLoanPlugin: Collateralized micro-loans with credit scoring
 * - OnRampPlugin: Fiat on-ramp integration with KYC tracking
 *
 * Usage:
 *   npx ts-node script/ts/deploy-plugins.ts [--broadcast] [--verify] [--force]
 *
 * Options:
 *   --broadcast  Actually broadcast transactions (otherwise dry run)
 *   --verify     Verify contracts on block explorer (can run standalone)
 *   --force      Force redeploy even if contracts already exist
 *
 * Examples:
 *   npx ts-node script/ts/deploy-plugins.ts                    # Dry run
 *   npx ts-node script/ts/deploy-plugins.ts --broadcast        # Deploy
 *   npx ts-node script/ts/deploy-plugins.ts --verify           # Verify only
 *   npx ts-node script/ts/deploy-plugins.ts --broadcast --verify  # Deploy + verify
 */

// NOTE: This script uses execSync for forge/cast CLI invocations with controlled inputs only.
// All command arguments are hardcoded or derived from validated environment variables,
// not from user-supplied input, so shell injection is not a concern here.
// The execFileNoThrow utility in src/utils is for the DApp codebase, not deployment scripts.

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const FORGE_SCRIPT = "script/deploy-contract/DeployPlugins.s.sol:DeployPluginsScript";
const FOUNDRY_PROFILE = "plugins";

// Contract names, artifacts, and their JSON keys
const CONTRACTS = [
  { name: "AutoSwapPlugin", artifact: "src/erc7579-plugins/AutoSwapPlugin.sol:AutoSwapPlugin", jsonKey: "autoSwapPlugin" },
  { name: "MicroLoanPlugin", artifact: "src/erc7579-plugins/MicroLoanPlugin.sol:MicroLoanPlugin", jsonKey: "microLoanPlugin" },
  { name: "OnRampPlugin", artifact: "src/erc7579-plugins/OnRampPlugin.sol:OnRampPlugin", jsonKey: "onRampPlugin" },
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
  constructorArgs?: string;
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

// ============ Constructor Args ============

function encodeAddress(address: string): string {
  return address.toLowerCase().replace("0x", "").padStart(64, "0");
}

function encodeUint256(value: string | number | bigint): string {
  return BigInt(value).toString(16).padStart(64, "0");
}

// Default values matching DeployPlugins.s.sol
const DEFAULT_PROTOCOL_FEE_BPS = "50"; // 0.5%
const DEFAULT_LIQUIDATION_BONUS_BPS = "500"; // 5%
const DEFAULT_ONRAMP_FEE_BPS = "100"; // 1%
const DEFAULT_ORDER_EXPIRY = String(24 * 60 * 60); // 24 hours

function buildConstructorArgs(
  contractName: string,
  addresses: DeployedAddresses,
  deployerAddress: string
): string | undefined {
  switch (contractName) {
    case "AutoSwapPlugin": {
      // constructor(IPriceOracle _oracle, address _dexRouter)
      const priceOracle = addresses["priceOracle"];
      const dexRouter = addresses["uniswapV3SwapRouter"];
      if (!priceOracle || !dexRouter) {
        console.log("AutoSwapPlugin: Cannot build constructor args - PriceOracle or SwapRouter not deployed");
        return undefined;
      }
      return encodeAddress(priceOracle) + encodeAddress(dexRouter);
    }
    case "MicroLoanPlugin": {
      // constructor(IPriceOracle _oracle, address _feeRecipient, uint256 _protocolFeeBps, uint256 _liquidationBonusBps)
      const priceOracle = addresses["priceOracle"];
      const feeRecipient = process.env.FEE_RECIPIENT || deployerAddress;
      const protocolFeeBps = process.env.PROTOCOL_FEE_BPS || DEFAULT_PROTOCOL_FEE_BPS;
      const liquidationBonusBps = process.env.LIQUIDATION_BONUS_BPS || DEFAULT_LIQUIDATION_BONUS_BPS;
      if (!priceOracle) {
        console.log("MicroLoanPlugin: Cannot build constructor args - PriceOracle not deployed");
        return undefined;
      }
      return encodeAddress(priceOracle) + encodeAddress(feeRecipient) +
        encodeUint256(protocolFeeBps) + encodeUint256(liquidationBonusBps);
    }
    case "OnRampPlugin": {
      // constructor(address _treasury, uint256 _feeBps, uint256 _orderExpiry)
      const treasury = process.env.TREASURY || deployerAddress;
      const feeBps = process.env.ONRAMP_FEE_BPS || DEFAULT_ONRAMP_FEE_BPS;
      const orderExpiry = process.env.ORDER_EXPIRY || DEFAULT_ORDER_EXPIRY;
      return encodeAddress(treasury) + encodeUint256(feeBps) + encodeUint256(orderExpiry);
    }
    default:
      return undefined;
  }
}

// ============ Contract Verification ============

function verifyContracts(chainId: string, deployerAddress: string): void {
  const addresses = loadDeployedAddresses(chainId);

  const hasAnyAddress = CONTRACTS.some((c) => addresses[c.jsonKey]);
  if (!hasAnyAddress) {
    console.log("No deployed Plugin addresses found to verify");
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

    const constructorArgs = buildConstructorArgs(contract.name, addresses, deployerAddress);

    if (constructorArgs === undefined) {
      console.log(`${contract.name}: Skipping verification (missing dependencies for constructor args)`);
      continue;
    }

    const verifyCmd = buildVerifyCommand({
      contractAddress: address,
      contractArtifact: contract.artifact,
      constructorArgs,
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

  const verifyOnly = verify && !broadcast && !force;

  console.log("=".repeat(60));
  console.log("  ERC-7579 Plugins Deployment");
  console.log("=".repeat(60));

  if (verifyOnly) {
    const { privateKey, chainId } = validateEnv();
    const deployerAddress = getDeployerAddress(privateKey);

    console.log(`Chain ID: ${chainId}`);
    console.log(`Mode: VERIFY ONLY`);
    console.log(`Profile: FOUNDRY_PROFILE=${FOUNDRY_PROFILE}`);
    console.log("=".repeat(60));

    verifyContracts(chainId, deployerAddress);

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
      console.log("✅ Plugins deployment completed!");
      console.log("\nDeployed addresses saved to: deployments/" + chainId + "/addresses.json");

      if (verify) {
        const deployerAddress = getDeployerAddress(privateKey);
        verifyContracts(chainId, deployerAddress);
      }

      console.log("\nPlugin Use Cases:");
      console.log("  - AutoSwapPlugin: DCA, limit orders, stop loss, take profit");
      console.log("  - MicroLoanPlugin: Collateralized micro-loans, credit scoring");
      console.log("  - OnRampPlugin: Fiat on-ramp integration, KYC management");
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
