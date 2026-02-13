#!/usr/bin/env npx ts-node
/**
 * Paymasters Deployment Script
 *
 * Deploys ERC-4337 Paymaster contracts using forge script
 * - VerifyingPaymaster: Off-chain signature verification for gas sponsorship
 * - SponsorPaymaster: Budget-based gas sponsorship with daily limits
 * - ERC20Paymaster: Pay gas fees with ERC20 tokens (requires PriceOracle)
 * - Permit2Paymaster: Gasless ERC20 payments via Permit2 (requires PriceOracle + Permit2)
 *
 * Usage:
 *   npx ts-node script/ts/deploy-paymasters.ts [--broadcast] [--verify] [--force]
 *
 * Options:
 *   --broadcast  Actually broadcast transactions (otherwise dry run)
 *   --verify     Verify contracts on block explorer (can run standalone)
 *   --force      Force redeploy even if contracts already exist
 *
 * Environment Variables:
 *   OWNER_ADDRESS: Owner/admin address for paymasters (defaults to deployer)
 *   VERIFYING_SIGNER: Signer address for VerifyingPaymaster/SponsorPaymaster
 *   MARKUP: Price markup in basis points (default: 1000 = 10%)
 *
 * Dependencies (auto-loaded from addresses.json):
 *   - EntryPoint: Required for all paymasters
 *   - PriceOracle: Required for ERC20Paymaster and Permit2Paymaster
 *   - Permit2: Required for Permit2Paymaster
 *
 * Examples:
 *   npx ts-node script/ts/deploy-paymasters.ts                    # Dry run
 *   npx ts-node script/ts/deploy-paymasters.ts --broadcast        # Deploy
 *   npx ts-node script/ts/deploy-paymasters.ts --verify           # Verify only
 *   npx ts-node script/ts/deploy-paymasters.ts --broadcast --verify  # Deploy + verify
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

const FORGE_SCRIPT = "script/deploy-contract/DeployPaymasters.s.sol:DeployPaymastersScript";
const FOUNDRY_PROFILE = "paymaster";

// Contract names, artifacts, and their JSON keys
const CONTRACTS = [
  {
    name: "VerifyingPaymaster",
    artifact: "src/erc4337-paymaster/VerifyingPaymaster.sol:VerifyingPaymaster",
    jsonKey: "verifyingPaymaster",
    hasConstructorArgs: true,
  },
  {
    name: "SponsorPaymaster",
    artifact: "src/erc4337-paymaster/SponsorPaymaster.sol:SponsorPaymaster",
    jsonKey: "sponsorPaymaster",
    hasConstructorArgs: true,
  },
  {
    name: "ERC20Paymaster",
    artifact: "src/erc4337-paymaster/ERC20Paymaster.sol:ERC20Paymaster",
    jsonKey: "erc20Paymaster",
    hasConstructorArgs: true,
  },
  {
    name: "Permit2Paymaster",
    artifact: "src/erc4337-paymaster/Permit2Paymaster.sol:Permit2Paymaster",
    jsonKey: "permit2Paymaster",
    hasConstructorArgs: true,
  },
];

// Default markup: 10% (1000 basis points)
const DEFAULT_MARKUP = "1000";

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
  let addresses: DeployedAddresses = {};

  // Load from deployments/chainId/addresses.json
  if (fs.existsSync(addressesPath)) {
    try {
      const content = fs.readFileSync(addressesPath, "utf8");
      addresses = JSON.parse(content);
    } catch {
      // Ignore parse errors
    }
  }

  // Also load from broadcast folders if not found in addresses.json
  const broadcastMappings: { [key: string]: { script: string; contractName: string } } = {
    entryPoint: { script: "DeployEntryPoint.s.sol", contractName: "EntryPoint" },
    priceOracle: { script: "DeployDeFi.s.sol", contractName: "PriceOracle" },
    permit2: { script: "DeployPermit2.s.sol", contractName: "Permit2" },
    verifyingPaymaster: { script: "DeployPaymasters.s.sol", contractName: "VerifyingPaymaster" },
    sponsorPaymaster: { script: "DeployPaymasters.s.sol", contractName: "SponsorPaymaster" },
    erc20Paymaster: { script: "DeployPaymasters.s.sol", contractName: "ERC20Paymaster" },
    permit2Paymaster: { script: "DeployPaymasters.s.sol", contractName: "Permit2Paymaster" },
  };

  for (const [key, mapping] of Object.entries(broadcastMappings)) {
    if (!addresses[key]) {
      const addr = getAddressFromBroadcast(mapping.script, chainId, mapping.contractName);
      if (addr) {
        addresses[key] = addr;
      }
    }
  }

  return addresses;
}

// ============ Broadcast Folder Address Lookup ============

interface BroadcastTransaction {
  contractName?: string;
  contractAddress?: string;
  transactionType?: string;
}

interface BroadcastData {
  transactions?: BroadcastTransaction[];
}

/**
 * Reads deployed contract address from Foundry broadcast folder.
 */
function getAddressFromBroadcast(
  scriptName: string,
  chainId: string,
  contractName: string
): string | undefined {
  const broadcastPath = path.join(
    PROJECT_ROOT,
    "broadcast",
    scriptName,
    chainId,
    "run-latest.json"
  );

  if (!fs.existsSync(broadcastPath)) {
    return undefined;
  }

  try {
    const content = fs.readFileSync(broadcastPath, "utf8");
    const data: BroadcastData = JSON.parse(content);

    if (!data.transactions || !Array.isArray(data.transactions)) {
      return undefined;
    }

    const deployTx = data.transactions.find(
      (tx) =>
        tx.contractName === contractName &&
        (tx.transactionType === "CREATE" || tx.transactionType === "CREATE2") &&
        tx.contractAddress
    );

    return deployTx?.contractAddress;
  } catch {
    return undefined;
  }
}

// ============ Constructor Args Encoding ============

/**
 * Encode an address to 32-byte hex string (no 0x prefix)
 */
function encodeAddress(address: string): string {
  return address.toLowerCase().replace("0x", "").padStart(64, "0");
}

/**
 * Encode a uint256 value to 32-byte hex string (no 0x prefix)
 */
function encodeUint256(value: string | number | bigint): string {
  return BigInt(value).toString(16).padStart(64, "0");
}

// ============ Constructor Args Builder ============

function buildConstructorArgs(
  contractName: string,
  addresses: DeployedAddresses,
  deployerAddress: string
): string | undefined {
  const entryPointAddress = addresses["entryPoint"];
  const ownerAddress = process.env.OWNER_ADDRESS || deployerAddress;
  const verifyingSigner = process.env.VERIFYING_SIGNER || deployerAddress;
  const priceOracleAddress = addresses["priceOracle"];
  const permit2Address = addresses["permit2"];
  const markup = process.env.MARKUP || DEFAULT_MARKUP;

  if (!entryPointAddress) {
    console.log(`${contractName}: Cannot build constructor args - EntryPoint not deployed`);
    return undefined;
  }

  switch (contractName) {
    case "VerifyingPaymaster": {
      // constructor(IEntryPoint _entryPoint, address _owner, address _verifyingSigner)
      return [
        encodeAddress(entryPointAddress),
        encodeAddress(ownerAddress),
        encodeAddress(verifyingSigner),
      ].join("");
    }

    case "SponsorPaymaster": {
      // constructor(IEntryPoint _entryPoint, address _owner, address _signer)
      return [
        encodeAddress(entryPointAddress),
        encodeAddress(ownerAddress),
        encodeAddress(verifyingSigner),
      ].join("");
    }

    case "ERC20Paymaster": {
      // constructor(IEntryPoint _entryPoint, address _owner, IPriceOracle _oracle, uint256 _markup)
      if (!priceOracleAddress) {
        console.log(`${contractName}: Cannot build constructor args - PriceOracle not deployed`);
        return undefined;
      }
      return [
        encodeAddress(entryPointAddress),
        encodeAddress(ownerAddress),
        encodeAddress(priceOracleAddress),
        encodeUint256(markup),
      ].join("");
    }

    case "Permit2Paymaster": {
      // constructor(IEntryPoint _entryPoint, address _owner, IPermit2 _permit2, IPriceOracle _oracle, uint256 _markup)
      if (!permit2Address) {
        console.log(`${contractName}: Cannot build constructor args - Permit2 not deployed`);
        return undefined;
      }
      if (!priceOracleAddress) {
        console.log(`${contractName}: Cannot build constructor args - PriceOracle not deployed`);
        return undefined;
      }
      return [
        encodeAddress(entryPointAddress),
        encodeAddress(ownerAddress),
        encodeAddress(permit2Address),
        encodeAddress(priceOracleAddress),
        encodeUint256(markup),
      ].join("");
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
    console.log("No deployed Paymaster addresses found to verify");
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
      ? buildConstructorArgs(contract.name, addresses, deployerAddress)
      : undefined;

    if (constructorArgs === undefined && contract.hasConstructorArgs) {
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
  console.log("  Paymasters Deployment");
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
  const ownerAddress = process.env.OWNER_ADDRESS || deployerAddress;
  const verifyingSigner = process.env.VERIFYING_SIGNER || deployerAddress;
  const markup = process.env.MARKUP || DEFAULT_MARKUP;

  // Load dependencies
  const addresses = loadDeployedAddresses(chainId);
  const entryPointAddress = addresses["entryPoint"];
  const priceOracleAddress = addresses["priceOracle"];
  const permit2Address = addresses["permit2"];

  console.log(`RPC URL: ${rpcUrl}`);
  console.log(`Chain ID: ${chainId}`);
  console.log(`Deployer: ${deployerAddress}`);
  console.log(`Broadcast: ${broadcast ? "YES" : "NO (dry run)"}`);
  console.log(`Verify: ${verify ? "YES (after deployment)" : "NO"}`);
  console.log(`Force Redeploy: ${force ? "YES" : "NO"}`);
  console.log(`Profile: FOUNDRY_PROFILE=${FOUNDRY_PROFILE}`);
  console.log("-".repeat(60));
  console.log("Configuration:");
  console.log(`  Owner: ${ownerAddress}`);
  console.log(`  Verifying Signer: ${verifyingSigner}`);
  console.log(`  Markup: ${markup} basis points (${parseInt(markup) / 100}%)`);
  console.log("-".repeat(60));
  console.log("Dependencies:");
  console.log(`  EntryPoint: ${entryPointAddress || "NOT FOUND - Required!"}`);
  console.log(`  PriceOracle: ${priceOracleAddress || "NOT FOUND - ERC20/Permit2 Paymaster will be skipped"}`);
  console.log(`  Permit2: ${permit2Address || "NOT FOUND - Permit2Paymaster will be skipped"}`);
  console.log("-".repeat(60));
  console.log("Contracts to deploy:");
  console.log("  - VerifyingPaymaster (always)");
  console.log("  - SponsorPaymaster (always)");
  console.log(`  - ERC20Paymaster (${priceOracleAddress ? "YES" : "SKIP - needs PriceOracle"})`);
  console.log(`  - Permit2Paymaster (${priceOracleAddress && permit2Address ? "YES" : "SKIP - needs PriceOracle + Permit2"})`);
  console.log("=".repeat(60));

  if (!entryPointAddress) {
    console.error("\nError: EntryPoint not deployed. Deploy it first:");
    console.error("  ./script/deploy-entrypoint.sh --broadcast");
    process.exit(1);
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
        // Pass discovered dependency addresses for --force mode
        // (Forge skips loading addresses.json when FORCE_REDEPLOY=true,
        // so we pass dependencies via env vars as fallback)
        ENTRYPOINT_ADDRESS: entryPointAddress || "",
        PRICE_ORACLE: priceOracleAddress || "",
        PERMIT2_ADDRESS: permit2Address || "",
      },
    });

    console.log("\n" + "=".repeat(60));
    if (broadcast) {
      console.log("Paymasters deployment completed!");
      console.log("\nDeployed addresses saved to: deployments/" + chainId + "/addresses.json");

      // Step 2: Verify contracts (if requested and deployment was broadcast)
      if (verify) {
        verifyContracts(chainId, deployerAddress);
      }

      console.log("\nNext steps:");
      console.log("  1. Deposit funds to paymasters in EntryPoint:");
      console.log("     cast send <PAYMASTER> 'deposit()' --value 1ether");
      console.log("  2. For ERC20Paymaster, configure supported tokens:");
      console.log("     cast send <ERC20_PAYMASTER> 'setTokenOracle(address,address)' <TOKEN> <ORACLE>");
      console.log("  3. For SponsorPaymaster, set up sponsor budgets");
      console.log("\nPaymaster Usage:");
      console.log("  - VerifyingPaymaster: Off-chain signature for gas sponsorship");
      console.log("  - SponsorPaymaster: Budget-based sponsorship with daily limits");
      console.log("  - ERC20Paymaster: Pay gas with ERC20 tokens");
      console.log("  - Permit2Paymaster: Gasless ERC20 via Permit2 signatures");
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
