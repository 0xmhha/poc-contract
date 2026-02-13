#!/usr/bin/env npx ts-node
/**
 * DeFi Contracts Deployment Script
 *
 * Deploys DeFi modules using forge script
 * - PriceOracle: Unified price oracle supporting Chainlink feeds and Uniswap V3 TWAP
 * - LendingPool: Collateral-based lending pool with variable interest rates
 * - StakingVault: Staking vault with time-locked rewards
 *
 * Usage:
 *   npx ts-node script/ts/deploy-defi.ts [--broadcast] [--verify] [--force]
 *
 * Options:
 *   --broadcast  Actually broadcast transactions (otherwise dry run)
 *   --verify     Verify contracts on block explorer (can run standalone)
 *   --force      Force redeploy even if contracts already exist
 *
 * Environment Variables:
 *   STAKING_TOKEN: Token to stake (defaults to WKRC/NativeCoinAdapter at 0x1000)
 *   REWARD_TOKEN: Token for rewards (defaults to same as staking token)
 *   REWARD_RATE: Rewards per second (default: 1e15 = 0.001 tokens/sec)
 *   LOCK_PERIOD: Lock period in seconds (default: 7 days)
 *   EARLY_WITHDRAW_PENALTY: Penalty in basis points (default: 1000 = 10%)
 *   MIN_STAKE: Minimum stake amount (default: 1e18 = 1 token)
 *   MAX_STAKE: Maximum stake amount (default: 0 = unlimited)
 *
 * Examples:
 *   npx ts-node script/ts/deploy-defi.ts                    # Dry run
 *   npx ts-node script/ts/deploy-defi.ts --broadcast        # Deploy
 *   npx ts-node script/ts/deploy-defi.ts --verify           # Verify only
 *   npx ts-node script/ts/deploy-defi.ts --broadcast --verify  # Deploy + verify
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const FORGE_SCRIPT = "script/deploy-contract/DeployDeFi.s.sol:DeployDeFiScript";
const FOUNDRY_PROFILE = "defi";

// Contract names, paths, and their JSON keys
const CONTRACTS = [
  {
    name: "PriceOracle",
    artifact: "src/defi/PriceOracle.sol:PriceOracle",
    jsonKey: "priceOracle",
    hasConstructorArgs: false,
  },
  {
    name: "LendingPool",
    artifact: "src/defi/LendingPool.sol:LendingPool",
    jsonKey: "lendingPool",
    hasConstructorArgs: true,
  },
  {
    name: "StakingVault",
    artifact: "src/defi/StakingVault.sol:StakingVault",
    jsonKey: "stakingVault",
    hasConstructorArgs: true,
  },
];

// Default NativeCoinAdapter address (precompiled)
const NATIVE_COIN_ADAPTER = "0x0000000000000000000000000000000000001000";

// Default StakingVault config values (must match deployment script)
const DEFAULT_STAKING_CONFIG = {
  rewardRate: process.env.REWARD_RATE || "1000000000000000", // 1e15
  lockPeriod: process.env.LOCK_PERIOD || String(7 * 24 * 60 * 60), // 7 days
  earlyWithdrawPenalty: process.env.EARLY_WITHDRAW_PENALTY || "1000", // 10%
  maxStake: process.env.MAX_STAKE || "0", // unlimited
  minStake: process.env.MIN_STAKE || "1000000000000000000", // 1e18
  isActive: true,
};

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
  contractArtifact: string; // Full path like "src/defi/PriceOracle.sol:PriceOracle"
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

// ============ Constructor Args Builder ============

/**
 * Encode a uint256 value to 32-byte hex string (no 0x prefix)
 */
function encodeUint256(value: string | number | bigint): string {
  return BigInt(value).toString(16).padStart(64, "0");
}

/**
 * Encode an address to 32-byte hex string (no 0x prefix)
 */
function encodeAddress(address: string): string {
  return address.toLowerCase().replace("0x", "").padStart(64, "0");
}

/**
 * Encode a boolean to 32-byte hex string (no 0x prefix)
 */
function encodeBool(value: boolean): string {
  return value ? "1".padStart(64, "0") : "0".padStart(64, "0");
}

function buildConstructorArgs(
  contractName: string,
  addresses: DeployedAddresses
): string | undefined {
  switch (contractName) {
    case "PriceOracle":
      // constructor() - no args
      return undefined;

    case "LendingPool": {
      // constructor(address _oracle)
      const oracleAddress = addresses["priceOracle"];
      if (!oracleAddress) {
        console.log("LendingPool: Cannot build constructor args - PriceOracle not deployed");
        return undefined;
      }
      return encodeAddress(oracleAddress);
    }

    case "StakingVault": {
      // constructor(address _stakingToken, address _rewardToken, VaultConfig memory _config)
      // VaultConfig: (rewardRate, lockPeriod, earlyWithdrawPenalty, maxStake, minStake, isActive)
      const stakingToken = process.env.STAKING_TOKEN || NATIVE_COIN_ADAPTER;
      const rewardToken = process.env.REWARD_TOKEN || stakingToken;

      const args = [
        encodeAddress(stakingToken),
        encodeAddress(rewardToken),
        encodeUint256(DEFAULT_STAKING_CONFIG.rewardRate),
        encodeUint256(DEFAULT_STAKING_CONFIG.lockPeriod),
        encodeUint256(DEFAULT_STAKING_CONFIG.earlyWithdrawPenalty),
        encodeUint256(DEFAULT_STAKING_CONFIG.maxStake),
        encodeUint256(DEFAULT_STAKING_CONFIG.minStake),
        encodeBool(DEFAULT_STAKING_CONFIG.isActive),
      ].join("");

      return args;
    }

    default:
      return undefined;
  }
}

// ============ Contract Verification ============

function verifyContracts(chainId: string): void {
  const addresses = loadDeployedAddresses(chainId);

  const hasAnyAddress = CONTRACTS.some((c) => addresses[c.jsonKey]);
  if (!hasAnyAddress) {
    console.log("No deployed DeFi addresses found to verify");
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
      console.log(`${contract.name} verified successfully`);
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
  console.log("  DeFi Contracts Deployment");
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
  const deployerAddress = getDeployerAddress(privateKey);

  // Get staking token info
  const stakingToken = process.env.STAKING_TOKEN || NATIVE_COIN_ADAPTER;
  const rewardToken = process.env.REWARD_TOKEN || stakingToken;
  const rewardRate = process.env.REWARD_RATE || "1000000000000000"; // 1e15
  const lockPeriod = process.env.LOCK_PERIOD || String(7 * 24 * 60 * 60); // 7 days
  const earlyWithdrawPenalty = process.env.EARLY_WITHDRAW_PENALTY || "1000"; // 10%

  console.log(`RPC URL: ${rpcUrl}`);
  console.log(`Chain ID: ${chainId}`);
  console.log(`Deployer: ${deployerAddress}`);
  console.log(`Broadcast: ${broadcast ? "YES" : "NO (dry run)"}`);
  console.log(`Verify: ${verify ? "YES (after deployment)" : "NO"}`);
  console.log(`Force Redeploy: ${force ? "YES" : "NO"}`);
  console.log(`Profile: FOUNDRY_PROFILE=${FOUNDRY_PROFILE}`);
  console.log("-".repeat(60));
  console.log("StakingVault Configuration:");
  console.log(`  Staking Token: ${stakingToken}`);
  console.log(`  Reward Token: ${rewardToken}`);
  console.log(`  Reward Rate: ${rewardRate} per second`);
  console.log(`  Lock Period: ${parseInt(lockPeriod) / 86400} days`);
  console.log(`  Early Withdraw Penalty: ${parseInt(earlyWithdrawPenalty) / 100}%`);
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
      console.log("DeFi deployment completed!");
      console.log("\nDeployed addresses saved to: deployments/" + chainId + "/addresses.json");

      // Step 2: Verify contracts (if requested and deployment was broadcast)
      if (verify) {
        verifyContracts(chainId);
      }

      console.log("\nNext steps:");
      console.log("  1. Deploy UniswapV3: ./script/deploy-uniswap.sh --broadcast");
      console.log("  2. Configure PriceOracle with Chainlink feeds or Uniswap pools");
      console.log("  3. Configure LendingPool assets with configureAsset()");
      console.log("  4. Add rewards to StakingVault with addRewards()");
      console.log("\nDeFi Contract Usage:");
      console.log("  - PriceOracle: Add price feeds for supported tokens");
      console.log("  - LendingPool: Deposit collateral, borrow assets, flash loans");
      console.log("  - StakingVault: Stake tokens for time-locked rewards");
    } else {
      console.log("Dry run completed. Use --broadcast to deploy.");
    }
    console.log("=".repeat(60));
  } catch {
    console.error("\nDeployment failed");
    process.exit(1);
  }
}

main();
