#!/usr/bin/env npx ts-node
/**
 * Ensure CREATE2 Deterministic Deployer
 *
 * Checks if Nick's Deterministic Deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C)
 * exists on the target chain. If not, deploys it using a keyless pre-signed transaction.
 *
 * This deployer is required by Foundry's `forge script --broadcast` for any CREATE2 operations,
 * including CREATE3 (which uses CREATE2 internally).
 *
 * Can be used as:
 *   - Standalone: npx ts-node script/ts/ensure-create2-deployer.ts
 *   - Module:     import { ensureCREATE2Deployer } from "./ensure-create2-deployer"
 *
 * Reference: https://github.com/Arachnid/deterministic-deployment-proxy
 */

import { execSync } from "child_process";
import * as path from "path";
import * as dotenv from "dotenv";

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

// Nick's Deterministic Deployer constants
const DEPLOYER_ADDRESS = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
const DEPLOYER_SIGNER = "0x3fab184622dc19b6109349b94811493bf2a45362";
const DEPLOYER_FUNDING = "100000000000000000"; // 0.1 ETH (generous buffer for varying gas prices)
const DEPLOYER_RUNTIME_CODE = "0x60003681823780368234f58015156014578182fd5b80825250506014600cf3";

// The pre-signed tx has gasPrice = 100 Gwei (0x174876e800). If the chain's baseFee
// exceeds this, the tx will never be mined regardless of EIP-155 settings.
const PRESIGNED_GAS_PRICE = BigInt("100000000000"); // 100 Gwei

// Pre-signed deployment transaction (chainId=0, no EIP-155 replay protection)
const DEPLOYER_RAW_TX =
  "0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe" +
  "7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0" +
  "3601600081602082378035828234f58015156039578182fd5b808252505050" +
  "6014600cf31ba02222222222222222222222222222222222222222222222222222" +
  "222222222222a02222222222222222222222222222222222222222222222222222" +
  "222222222222";

function printGenesisAllocGuide(): void {
  console.error("  Add the CREATE2 deployer to your chain's genesis alloc:\n");
  console.error("  genesis.json:");
  console.error("  {");
  console.error('    "alloc": {');
  console.error(`      "${DEPLOYER_ADDRESS.slice(2)}": {`);
  console.error(`        "code": "${DEPLOYER_RUNTIME_CODE}",`);
  console.error('        "balance": "0x0"');
  console.error("      }");
  console.error("    }");
  console.error("  }\n");
  console.error("  Then re-initialize the chain and restart the node.");
  console.error("-".repeat(60));
}

function getRpcUrl(): string {
  const rpcUrl = process.env.RPC_URL;
  if (!rpcUrl) {
    throw new Error("RPC_URL is not set in .env");
  }
  return rpcUrl;
}

function getPrivateKey(): string {
  const pk = process.env.PRIVATE_KEY_DEPLOYER || process.env.PRIVATE_KEY || "";
  if (!pk) {
    throw new Error("PRIVATE_KEY_DEPLOYER (or PRIVATE_KEY) is not set in .env");
  }
  return pk;
}

function castCommand(args: string): string {
  return execSync(`cast ${args}`, { encoding: "utf8", cwd: PROJECT_ROOT }).trim();
}

/**
 * Check if the CREATE2 deployer exists on the chain and deploy if missing.
 * Returns true if the deployer is available (already existed or was just deployed).
 */
export function ensureCREATE2Deployer(): boolean {
  const rpcUrl = getRpcUrl();

  console.log("-".repeat(60));
  console.log("CREATE2 Deterministic Deployer Check");
  console.log("-".repeat(60));
  console.log(`  Target: ${DEPLOYER_ADDRESS}`);

  // Check if already deployed
  const code = castCommand(`code ${DEPLOYER_ADDRESS} --rpc-url ${rpcUrl}`);
  if (code !== "0x" && code !== "0x0" && code.length > 2) {
    console.log("  Status: Already deployed");
    console.log("-".repeat(60));
    return true;
  }

  console.log("  Status: Not found — attempting deployment...");

  // Pre-check: compare chain baseFee vs pre-signed tx gasPrice
  const baseFee = BigInt(castCommand(`base-fee --rpc-url ${rpcUrl}`));
  if (baseFee > PRESIGNED_GAS_PRICE) {
    console.error(`\n  ERROR: Chain baseFeePerGas (${baseFee}) exceeds pre-signed tx gasPrice (${PRESIGNED_GAS_PRICE}).`);
    console.error("  The keyless deployment transaction will never be mined on this chain.\n");
    printGenesisAllocGuide();
    return false;
  }

  const privateKey = getPrivateKey();

  // Step 1: Fund the pre-determined signer address
  console.log(`\n  [1/3] Funding signer ${DEPLOYER_SIGNER}...`);
  try {
    execSync(
      `cast send ${DEPLOYER_SIGNER} --value ${DEPLOYER_FUNDING} --rpc-url ${rpcUrl} --private-key ${privateKey}`,
      { cwd: PROJECT_ROOT, stdio: "pipe" },
    );
    console.log(`         Sent ${DEPLOYER_FUNDING} wei`);
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error);
    // Might fail if signer already has funds — check balance
    const balance = castCommand(`balance ${DEPLOYER_SIGNER} --rpc-url ${rpcUrl}`);
    if (BigInt(balance) > 0n) {
      console.log(`         Signer already funded (balance: ${balance})`);
    } else {
      console.error(`         Failed to fund signer: ${msg}`);
      return false;
    }
  }

  // Step 2: Broadcast the pre-signed deployment transaction
  console.log("\n  [2/3] Broadcasting pre-signed deployment transaction...");
  try {
    execSync(`cast publish --rpc-url ${rpcUrl} "${DEPLOYER_RAW_TX}"`, {
      cwd: PROJECT_ROOT,
      stdio: "pipe",
    });
    console.log("         Transaction sent");
  } catch (error: unknown) {
    // Extract actual error from stderr (execSync error wraps stderr output)
    const stderr =
      error && typeof error === "object" && "stderr" in error
        ? (error as { stderr: Buffer }).stderr.toString()
        : "";
    const stdout =
      error && typeof error === "object" && "stdout" in error
        ? (error as { stdout: Buffer }).stdout.toString()
        : "";
    const fullError = stderr || stdout || (error instanceof Error ? error.message : String(error));

    if (fullError.includes("replay-protected") || fullError.includes("EIP-155") || fullError.includes("protected")) {
      console.error(`\n  ERROR: ${fullError.trim()}`);
      console.error("\n  The keyless deployment uses a legacy (non-EIP-155) transaction,");
      console.error("  but this chain enforces EIP-155 replay protection.\n");
      console.error("  Option A: Restart the node with legacy tx support:");
      console.error("    gstable --rpc.allow-unprotected-txs ...other-flags...\n");
      console.error("  Option B: Use genesis alloc (recommended):\n");
      printGenesisAllocGuide();
      return false;
    }
    console.error(`         Failed to publish tx: ${fullError}`);
    return false;
  }

  // Step 3: Verify deployment
  console.log("\n  [3/3] Verifying deployment...");

  // Brief wait for block inclusion
  try {
    execSync("sleep 2");
  } catch {
    // ignore
  }

  const newCode = castCommand(`code ${DEPLOYER_ADDRESS} --rpc-url ${rpcUrl}`);
  if (newCode !== "0x" && newCode !== "0x0" && newCode.length > 2) {
    console.log(`         Deployed at ${DEPLOYER_ADDRESS}`);
    console.log("-".repeat(60));
    return true;
  }

  console.error("         Deployment verification failed — code not found at expected address");
  return false;
}

// Run standalone
if (require.main === module) {
  const success = ensureCREATE2Deployer();
  process.exit(success ? 0 : 1);
}
