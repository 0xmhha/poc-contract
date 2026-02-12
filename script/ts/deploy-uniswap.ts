#!/usr/bin/env npx ts-node
/**
 * UniswapV3 Deployment Script
 *
 * Deploys Uniswap V3 contracts and creates initial WKRC/USDC pool
 *
 * Deployed Contracts:
 *   - UniswapV3Factory: Creates and manages liquidity pools
 *   - SwapRouter: Executes token swaps
 *   - Quoter: Provides swap quotes
 *   - NonfungiblePositionManager: Manages LP positions as NFTs
 *
 * Usage:
 *   npx ts-node script/ts/deploy-uniswap.ts [--broadcast] [--create-pool] [--verify] [--force]
 *
 * Options:
 *   --broadcast    Actually broadcast transactions (otherwise dry run)
 *   --create-pool  Create WKRC/USDC pool after deployment
 *   --verify       Verify contracts on block explorer
 *   --force        Force redeploy even if contracts already exist
 *
 * Environment Variables:
 *   WKRC_ADDRESS: NativeCoinAdapter address (default: 0x1000)
 *   USDC_ADDRESS: USDC contract address (optional, auto-discovered from broadcast folder)
 *   POOL_FEE: Pool fee tier in basis points (default: 3000 = 0.3%)
 *   INITIAL_PRICE: Initial sqrt price X96 (optional, for pool initialization)
 *
 * USDC Address Discovery (in priority order):
 *   1. USDC_ADDRESS environment variable
 *   2. deployments/{chainId}/addresses.json (usdc key)
 *   3. broadcast/DeployTokens.s.sol/{chainId}/run-latest.json
 *
 * Examples:
 *   npx ts-node script/ts/deploy-uniswap.ts                      # Dry run
 *   npx ts-node script/ts/deploy-uniswap.ts --broadcast          # Deploy
 *   npx ts-node script/ts/deploy-uniswap.ts --broadcast --create-pool  # Deploy + Create Pool
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";
import { ethers } from "ethers";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

// Default addresses
const DEFAULT_WKRC_ADDRESS = "0x0000000000000000000000000000000000001000";
const DEFAULT_POOL_FEE = 3000; // 0.3%

// Contract names and artifacts
const CONTRACTS = {
  factory: {
    name: "UniswapV3Factory",
    artifact: "lib/v3-core/contracts/UniswapV3Factory.sol:UniswapV3Factory",
    jsonKey: "uniswapV3Factory",
  },
  swapRouter: {
    name: "SwapRouter",
    artifact: "lib/v3-periphery/contracts/SwapRouter.sol:SwapRouter",
    jsonKey: "uniswapV3SwapRouter",
  },
  quoter: {
    name: "Quoter",
    artifact: "lib/v3-periphery/contracts/lens/Quoter.sol:Quoter",
    jsonKey: "uniswapV3Quoter",
  },
  nftDescriptor: {
    name: "NonfungibleTokenPositionDescriptor",
    artifact: "lib/v3-periphery/contracts/NonfungibleTokenPositionDescriptor.sol:NonfungibleTokenPositionDescriptor",
    jsonKey: "uniswapV3NftDescriptor",
  },
  nftPositionManager: {
    name: "NonfungiblePositionManager",
    artifact: "lib/v3-periphery/contracts/NonfungiblePositionManager.sol:NonfungiblePositionManager",
    jsonKey: "uniswapV3NftPositionManager",
  },
};

// ============ Argument Parsing ============

function parseArgs(): { broadcast: boolean; createPool: boolean; verify: boolean; force: boolean } {
  const args = process.argv.slice(2);
  return {
    broadcast: args.includes("--broadcast"),
    createPool: args.includes("--create-pool"),
    verify: args.includes("--verify"),
    force: args.includes("--force"),
  };
}

// ============ Environment Validation ============

function validateEnv(): {
  rpcUrl: string;
  privateKey: string;
  chainId: string;
  wkrcAddress: string;
} {
  const rpcUrl = process.env.RPC_URL;
  const privateKey = process.env.PRIVATE_KEY_DEPLOYER || process.env.PRIVATE_KEY || "";
  const chainId = process.env.CHAIN_ID || "8283";
  const wkrcAddress = process.env.WKRC_ADDRESS || DEFAULT_WKRC_ADDRESS;

  if (!rpcUrl) {
    throw new Error("RPC_URL is not set in .env");
  }

  if (!privateKey) {
    throw new Error("PRIVATE_KEY_DEPLOYER (or PRIVATE_KEY) is not set in .env");
  }

  return { rpcUrl, privateKey, chainId, wkrcAddress };
}

// ============ Address Management ============

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

function saveDeployedAddresses(chainId: string, addresses: DeployedAddresses): void {
  const deploymentsDir = path.join(PROJECT_ROOT, "deployments", chainId);

  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const addressesPath = path.join(deploymentsDir, "addresses.json");
  fs.writeFileSync(addressesPath, JSON.stringify(addresses, null, 2));
  console.log(`Saved addresses to: ${addressesPath}`);
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
 * Looks for the contract in broadcast/{scriptName}/{chainId}/run-latest.json
 *
 * @param scriptName - The Foundry script name (e.g., "DeployTokens.s.sol")
 * @param chainId - The chain ID
 * @param contractName - The contract name to find (e.g., "USDC")
 * @returns The deployed contract address or undefined if not found
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
    console.log(`Broadcast file not found: ${broadcastPath}`);
    return undefined;
  }

  try {
    const content = fs.readFileSync(broadcastPath, "utf8");
    const data: BroadcastData = JSON.parse(content);

    if (!data.transactions || !Array.isArray(data.transactions)) {
      console.log(`No transactions found in broadcast file: ${broadcastPath}`);
      return undefined;
    }

    // Find the contract deployment transaction
    const deployTx = data.transactions.find(
      (tx) =>
        tx.contractName === contractName &&
        (tx.transactionType === "CREATE" || tx.transactionType === "CREATE2") &&
        tx.contractAddress
    );

    if (deployTx && deployTx.contractAddress) {
      console.log(`Found ${contractName} address from broadcast: ${deployTx.contractAddress}`);
      return deployTx.contractAddress;
    }

    console.log(`Contract ${contractName} not found in broadcast file`);
    return undefined;
  } catch (error) {
    console.log(`Error reading broadcast file: ${error}`);
    return undefined;
  }
}

/**
 * Gets USDC address from multiple sources with priority:
 * 1. Environment variable (USDC_ADDRESS)
 * 2. Saved deployment addresses
 * 3. Broadcast folder (DeployTokens.s.sol)
 */
function getUsdcAddress(chainId: string, addresses: DeployedAddresses): string | undefined {
  // Priority 1: Environment variable
  if (process.env.USDC_ADDRESS) {
    console.log(`Using USDC address from environment: ${process.env.USDC_ADDRESS}`);
    return process.env.USDC_ADDRESS;
  }

  // Priority 2: Saved deployment addresses
  if (addresses["usdc"]) {
    console.log(`Using USDC address from deployments: ${addresses["usdc"]}`);
    return addresses["usdc"];
  }

  // Priority 3: Broadcast folder
  const broadcastAddress = getAddressFromBroadcast("DeployTokens.s.sol", chainId, "USDC");
  if (broadcastAddress) {
    return broadcastAddress;
  }

  return undefined;
}

// ============ Contract Deployment ============

async function deployContract(
  provider: ethers.JsonRpcProvider,
  wallet: ethers.Wallet,
  artifactPath: string,
  constructorArgs: unknown[],
  broadcast: boolean
): Promise<string> {
  // Get bytecode and ABI from forge artifacts (built by shell script)
  const contractName = artifactPath.split(":")[1];
  const artifactFile = path.join(PROJECT_ROOT, "out/uniswap", `${contractName}.sol`, `${contractName}.json`);

  if (!fs.existsSync(artifactFile)) {
    throw new Error(`Artifact not found: ${artifactFile}. Build may have failed - check the build output above.`);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactFile, "utf8"));
  const bytecode = artifact.bytecode.object;
  const abi = artifact.abi;

  if (!broadcast) {
    console.log(`[DRY RUN] Would deploy ${contractName} with args:`, constructorArgs);
    return ethers.ZeroAddress;
  }

  // Deploy
  const factory = new ethers.ContractFactory(abi, bytecode, wallet);
  console.log(`Deploying ${contractName}...`);

  const contract = await factory.deploy(...constructorArgs);
  await contract.waitForDeployment();

  const address = await contract.getAddress();
  console.log(`${contractName} deployed at: ${address}`);

  return address;
}

// ============ Pool Creation ============

async function createPool(
  provider: ethers.JsonRpcProvider,
  wallet: ethers.Wallet,
  factoryAddress: string,
  token0: string,
  token1: string,
  fee: number,
  broadcast: boolean
): Promise<string> {
  // Sort tokens
  const [sortedToken0, sortedToken1] =
    token0.toLowerCase() < token1.toLowerCase() ? [token0, token1] : [token1, token0];

  console.log(`\nCreating pool: ${sortedToken0} / ${sortedToken1} (fee: ${fee / 10000}%)`);

  if (!broadcast) {
    console.log("[DRY RUN] Would create pool");
    return ethers.ZeroAddress;
  }

  // Get factory contract
  const factoryAbi = [
    "function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool)",
    "function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool)",
  ];

  const factory = new ethers.Contract(factoryAddress, factoryAbi, wallet);

  // Check if pool already exists
  const existingPool = await factory.getPool(sortedToken0, sortedToken1, fee);
  if (existingPool !== ethers.ZeroAddress) {
    console.log(`Pool already exists at: ${existingPool}`);

    // Check if pool needs initialization (may have been created but not initialized)
    const poolCheckAbi = [
      "function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)",
    ];
    const existingPoolContract = new ethers.Contract(existingPool, poolCheckAbi, provider);
    const slot0 = await existingPoolContract.slot0();
    if (BigInt(slot0.sqrtPriceX96.toString()) === BigInt(0)) {
      console.log("Pool exists but is not initialized, initializing now...");
      const defaultSqrtPriceX96 = "79228162514264337593543950336";
      const sqrtPriceX96 = process.env.INITIAL_PRICE || defaultSqrtPriceX96;
      const poolInitAbi = ["function initialize(uint160 sqrtPriceX96) external"];
      const poolContractToInit = new ethers.Contract(existingPool, poolInitAbi, wallet);
      const initTx = await poolContractToInit.initialize(sqrtPriceX96);
      await initTx.wait();
      console.log("Pool initialized successfully");
    } else {
      console.log("Pool is already initialized");
    }

    return existingPool;
  }

  // Create pool
  const tx = await factory.createPool(sortedToken0, sortedToken1, fee);
  await tx.wait();

  // Get pool address from event
  const poolAddress = await factory.getPool(sortedToken0, sortedToken1, fee);
  console.log(`Pool created at: ${poolAddress}`);

  // Initialize the pool with sqrtPriceX96
  // Default: 2^96 = 79228162514264337593543950336 (raw-unit 1:1 ratio)
  // NOTE: For tokens with different decimals (e.g., wKRC=18, USDC=6), the
  // human-readable price will NOT be 1:1. Override via INITIAL_PRICE env var.
  const defaultSqrtPriceX96 = "79228162514264337593543950336";
  const sqrtPriceX96 = process.env.INITIAL_PRICE || defaultSqrtPriceX96;

  console.log(`Initializing pool with sqrtPriceX96: ${sqrtPriceX96}`);
  const poolAbi = ["function initialize(uint160 sqrtPriceX96) external"];
  const poolContract = new ethers.Contract(poolAddress, poolAbi, wallet);
  const initTx = await poolContract.initialize(sqrtPriceX96);
  await initTx.wait();
  console.log("Pool initialized successfully");

  return poolAddress;
}

// ============ Contract Verification ============

function verifyContract(
  contractAddress: string,
  contractPath: string,
  constructorArgs?: string
): void {
  const verifierUrl = process.env.VERIFIER_URL;

  if (!verifierUrl) {
    console.log("VERIFIER_URL not set, skipping verification");
    return;
  }

  const args = [
    "forge",
    "verify-contract",
    "--verifier-url",
    verifierUrl,
    "--verifier",
    "custom",
    contractAddress,
    contractPath,
  ];

  if (constructorArgs) {
    args.push("--constructor-args", constructorArgs);
  }

  const cmd = args.join(" ");
  console.log(`Verifying: ${cmd}`);

  try {
    execSync(cmd, {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
      env: {
        ...process.env,
        FOUNDRY_PROFILE: "uniswap",
      },
    });
    console.log(`Verification successful`);
  } catch {
    console.error(`Verification failed (contract may already be verified)`);
  }
}

function verifyContracts(addresses: DeployedAddresses, wkrcAddress: string): void {
  console.log("\n" + "-".repeat(60));
  console.log("Contract Verification");
  console.log("-".repeat(60));
  console.log("\nPreparing isolated Uniswap verify environment...");
  try {
    execSync("forge clean", {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
      env: {
        ...process.env,
        FOUNDRY_PROFILE: "uniswap",
      },
    });
    execSync("forge build", {
      cwd: PROJECT_ROOT,
      stdio: "inherit",
      env: {
        ...process.env,
        FOUNDRY_PROFILE: "uniswap",
      },
    });
  } catch {
    console.error("Failed to prepare Uniswap profile build for verification");
    return;
  }

  const factoryAddr = addresses[CONTRACTS.factory.jsonKey];
  const swapRouterAddr = addresses[CONTRACTS.swapRouter.jsonKey];
  const quoterAddr = addresses[CONTRACTS.quoter.jsonKey];
  const nftManagerAddr = addresses[CONTRACTS.nftPositionManager.jsonKey];

  // UniswapV3Factory - no constructor args
  if (factoryAddr) {
    console.log(`\nVerifying UniswapV3Factory at ${factoryAddr}...`);
    verifyContract(factoryAddr, CONTRACTS.factory.artifact);
  }

  // SwapRouter - constructor(address factory, address WETH9)
  if (swapRouterAddr && factoryAddr) {
    console.log(`\nVerifying SwapRouter at ${swapRouterAddr}...`);
    const args = factoryAddr.toLowerCase().replace("0x", "").padStart(64, "0") +
                 wkrcAddress.toLowerCase().replace("0x", "").padStart(64, "0");
    verifyContract(swapRouterAddr, CONTRACTS.swapRouter.artifact, args);
  }

  // Quoter - constructor(address factory, address WETH9)
  if (quoterAddr && factoryAddr) {
    console.log(`\nVerifying Quoter at ${quoterAddr}...`);
    const args = factoryAddr.toLowerCase().replace("0x", "").padStart(64, "0") +
                 wkrcAddress.toLowerCase().replace("0x", "").padStart(64, "0");
    verifyContract(quoterAddr, CONTRACTS.quoter.artifact, args);
  }

  // NonfungiblePositionManager - constructor(address factory, address WETH9, address tokenDescriptor)
  if (nftManagerAddr && factoryAddr) {
    console.log(`\nVerifying NonfungiblePositionManager at ${nftManagerAddr}...`);
    const tokenDescriptor = addresses[CONTRACTS.nftDescriptor.jsonKey] || ethers.ZeroAddress;
    const args = factoryAddr.toLowerCase().replace("0x", "").padStart(64, "0") +
                 wkrcAddress.toLowerCase().replace("0x", "").padStart(64, "0") +
                 tokenDescriptor.toLowerCase().replace("0x", "").padStart(64, "0");
    verifyContract(nftManagerAddr, CONTRACTS.nftPositionManager.artifact, args);
  }
}

// ============ Main ============

async function main(): Promise<void> {
  const { broadcast, createPool: shouldCreatePool, verify, force } = parseArgs();
  const { rpcUrl, privateKey, chainId, wkrcAddress } = validateEnv();

  // Verify-only mode
  const verifyOnly = verify && !broadcast && !force;

  console.log("=".repeat(60));
  console.log("  UniswapV3 Deployment");
  console.log("=".repeat(60));

  if (verifyOnly) {
    console.log(`Chain ID: ${chainId}`);
    console.log(`Mode: VERIFY ONLY`);
    console.log("=".repeat(60));

    const addresses = loadDeployedAddresses(chainId);
    verifyContracts(addresses, wkrcAddress);
    console.log("\n" + "=".repeat(60));
    return;
  }

  console.log(`RPC URL: ${rpcUrl}`);
  console.log(`Chain ID: ${chainId}`);
  console.log(`Broadcast: ${broadcast ? "YES" : "NO (dry run)"}`);
  console.log(`Create Pool: ${shouldCreatePool ? "YES" : "NO"}`);
  console.log(`Verify: ${verify ? "YES (after deployment)" : "NO"}`);
  console.log(`Force Redeploy: ${force ? "YES" : "NO"}`);
  console.log(`WKRC Address: ${wkrcAddress}`);
  console.log("=".repeat(60));

  // Setup provider and wallet
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(privateKey, provider);
  console.log(`Deployer: ${wallet.address}`);

  // Note: Uniswap contracts are built by the shell wrapper (deploy-uniswap.sh)
  // which handles remappings.txt correctly before calling this script.

  // Load existing addresses (always load to preserve non-Uniswap addresses)
  const addresses = loadDeployedAddresses(chainId);
  if (force) {
    // Clear only Uniswap-specific addresses to force redeploy
    for (const contract of Object.values(CONTRACTS)) {
      delete addresses[contract.jsonKey];
    }
    delete addresses["uniswapV3WkrcUsdcPool"];
  }

  // Get USDC address from multiple sources
  const usdcAddress = getUsdcAddress(chainId, addresses);
  if (shouldCreatePool && !usdcAddress) {
    console.warn("Warning: USDC address not found. Pool creation will be skipped.");
    console.warn("USDC address is searched in order:");
    console.warn("  1. USDC_ADDRESS environment variable");
    console.warn("  2. deployments/{chainId}/addresses.json");
    console.warn("  3. broadcast/DeployTokens.s.sol/{chainId}/run-latest.json");
  }

  // ============ Deploy Contracts ============

  console.log("\n" + "-".repeat(60));
  console.log("Step 1: Deploy UniswapV3Factory");
  console.log("-".repeat(60));

  let factoryAddress = addresses[CONTRACTS.factory.jsonKey];
  if (!factoryAddress) {
    factoryAddress = await deployContract(
      provider,
      wallet,
      CONTRACTS.factory.artifact,
      [], // No constructor args
      broadcast
    );
    addresses[CONTRACTS.factory.jsonKey] = factoryAddress;
  } else {
    console.log(`UniswapV3Factory: Using existing at ${factoryAddress}`);
  }

  console.log("\n" + "-".repeat(60));
  console.log("Step 2: Deploy SwapRouter");
  console.log("-".repeat(60));

  let swapRouterAddress = addresses[CONTRACTS.swapRouter.jsonKey];
  if (!swapRouterAddress && (factoryAddress !== ethers.ZeroAddress || !broadcast)) {
    swapRouterAddress = await deployContract(
      provider,
      wallet,
      CONTRACTS.swapRouter.artifact,
      [factoryAddress, wkrcAddress], // factory, WETH
      broadcast
    );
    addresses[CONTRACTS.swapRouter.jsonKey] = swapRouterAddress;
  } else if (swapRouterAddress) {
    console.log(`SwapRouter: Using existing at ${swapRouterAddress}`);
  }

  console.log("\n" + "-".repeat(60));
  console.log("Step 3: Deploy Quoter");
  console.log("-".repeat(60));

  let quoterAddress = addresses[CONTRACTS.quoter.jsonKey];
  if (!quoterAddress && (factoryAddress !== ethers.ZeroAddress || !broadcast)) {
    quoterAddress = await deployContract(
      provider,
      wallet,
      CONTRACTS.quoter.artifact,
      [factoryAddress, wkrcAddress], // factory, WETH
      broadcast
    );
    addresses[CONTRACTS.quoter.jsonKey] = quoterAddress;
  } else if (quoterAddress) {
    console.log(`Quoter: Using existing at ${quoterAddress}`);
  }

  console.log("\n" + "-".repeat(60));
  console.log("Step 4: Deploy NonfungiblePositionManager");
  console.log("-".repeat(60));

  let nftPositionManagerAddress = addresses[CONTRACTS.nftPositionManager.jsonKey];
  if (!nftPositionManagerAddress && (factoryAddress !== ethers.ZeroAddress || !broadcast)) {
    // NonfungibleTokenPositionDescriptor is not deployed in this PoC (requires NFTDescriptor
    // library linking). Passing address(0) disables tokenURI() metadata rendering for LP NFTs.
    const tokenDescriptor = addresses[CONTRACTS.nftDescriptor.jsonKey] || ethers.ZeroAddress;

    nftPositionManagerAddress = await deployContract(
      provider,
      wallet,
      CONTRACTS.nftPositionManager.artifact,
      [factoryAddress, wkrcAddress, tokenDescriptor], // factory, WETH, tokenDescriptor
      broadcast
    );
    addresses[CONTRACTS.nftPositionManager.jsonKey] = nftPositionManagerAddress;
  } else if (nftPositionManagerAddress) {
    console.log(`NonfungiblePositionManager: Using existing at ${nftPositionManagerAddress}`);
  }

  // ============ Create Pool ============

  if (shouldCreatePool && factoryAddress && (factoryAddress !== ethers.ZeroAddress || !broadcast) && usdcAddress) {
    console.log("\n" + "-".repeat(60));
    console.log("Step 5: Create WKRC/USDC Pool");
    console.log("-".repeat(60));

    const poolFee = parseInt(process.env.POOL_FEE || String(DEFAULT_POOL_FEE));
    const poolAddress = await createPool(
      provider,
      wallet,
      factoryAddress,
      wkrcAddress,
      usdcAddress,
      poolFee,
      broadcast
    );

    if (poolAddress !== ethers.ZeroAddress) {
      addresses["uniswapV3WkrcUsdcPool"] = poolAddress;
    }
  }

  // Save addresses
  if (broadcast) {
    saveDeployedAddresses(chainId, addresses);

    // Verify contracts if requested
    if (verify) {
      verifyContracts(addresses, wkrcAddress);
    }
  }

  // ============ Summary ============

  console.log("\n" + "=".repeat(60));
  console.log("  UniswapV3 Deployment Summary");
  console.log("=".repeat(60));
  console.log(`UniswapV3Factory: ${addresses[CONTRACTS.factory.jsonKey] || "Not deployed"}`);
  console.log(`SwapRouter: ${addresses[CONTRACTS.swapRouter.jsonKey] || "Not deployed"}`);
  console.log(`Quoter: ${addresses[CONTRACTS.quoter.jsonKey] || "Not deployed"}`);
  console.log(`NonfungiblePositionManager: ${addresses[CONTRACTS.nftPositionManager.jsonKey] || "Not deployed"}`);
  if (addresses["uniswapV3WkrcUsdcPool"]) {
    console.log(`WKRC/USDC Pool: ${addresses["uniswapV3WkrcUsdcPool"]}`);
  }

  if (!broadcast) {
    console.log("\n✅ Dry run completed. Use --broadcast to deploy.");
  } else {
    console.log("\n✅ UniswapV3 deployment completed!");
    console.log("\nNext steps:");
    console.log("  1. Deploy DeFi contracts: ./script/deploy-defi.sh --broadcast");
    console.log("  2. Configure PriceOracle with Uniswap pools");
    console.log("  3. Add initial liquidity to pools");
  }
  console.log("=".repeat(60));
}

main().catch((error) => {
  console.error("Deployment failed:", error);
  process.exit(1);
});
