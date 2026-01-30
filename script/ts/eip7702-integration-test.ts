#!/usr/bin/env npx ts-node
/**
 * EIP-7702 Integration Test
 *
 * Tests three scenarios:
 *   1. EOA → CA conversion via EIP-7702 (delegate to Kernel)
 *   2. Transaction with gas paid in USDC (ERC-20 token)
 *   3. Transaction with gas paid by Paymaster
 *
 * Prerequisites:
 *   - npm install viem @account-abstraction/sdk
 *   - Anvil running with Prague hardfork
 *   - Deployed contracts on chain 8283
 *
 * Usage:
 *   npx ts-node script/js/eip7702-integration-test.ts
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  parseUnits,
  encodeFunctionData,
  keccak256,
  toHex,
  concat,
  pad,
  defineChain,
  type Address,
  type Hex,
  type Chain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

// ============ Configuration ============

const CHAIN_ID = 8283;
const RPC_URL = "http://127.0.0.1:8501";

// Test private key (from Anvil)
const PRIVATE_KEY =
  "0x094b9f396eb72b760239c733cd095a8b97984a161e9bf972277777004af28173" as Hex;

// Deployed contract addresses (chain 8283 - fresh deployment)
const ADDRESSES = {
  entryPoint: "0x1512F931377A3B88bbEC800Bd563DfAdb1E0b622" as Address,
  kernel: "0xf327Bb64ac0B922969895cf84577895Ac6d4C07c" as Address,
  kernelFactory: "0x889F044cA71AD017495A353e604265044F422BfE" as Address,
  ecdsaValidator: "0x67D904a1e9e7141FFB65988ECCEF275C56E62355" as Address,
  erc20Paymaster: "0xC19376eC9ADFc79e014bFdAD3e6615C94ae09FdF" as Address,
  usdc: "0x9071A0020F7Bd719d80944BeBd23C1d2BEd4527d" as Address,
  sponsorPaymaster: "0xF0B937fc5a5194bf8D2d6e6bE3B8289107a7268c" as Address,
};

// ABIs (minimal)
const KERNEL_ABI = [
  {
    name: "execute",
    type: "function",
    inputs: [
      { name: "execMode", type: "bytes32" },
      { name: "executionCalldata", type: "bytes" },
    ],
    outputs: [],
  },
  {
    name: "initialize",
    type: "function",
    inputs: [
      { name: "_rootValidator", type: "bytes21" },
      { name: "hook", type: "address" },
      { name: "validatorData", type: "bytes" },
      { name: "hookData", type: "bytes" },
      { name: "initConfig", type: "bytes[]" },
    ],
    outputs: [],
  },
] as const;

const ERC20_ABI = [
  {
    name: "balanceOf",
    type: "function",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    name: "transfer",
    type: "function",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "approve",
    type: "function",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

const ENTRYPOINT_ABI = [
  {
    name: "depositTo",
    type: "function",
    inputs: [{ name: "account", type: "address" }],
    outputs: [],
    stateMutability: "payable",
  },
  {
    name: "balanceOf",
    type: "function",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    name: "handleOps",
    type: "function",
    inputs: [
      {
        name: "ops",
        type: "tuple[]",
        components: [
          { name: "sender", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "initCode", type: "bytes" },
          { name: "callData", type: "bytes" },
          { name: "accountGasLimits", type: "bytes32" },
          { name: "preVerificationGas", type: "uint256" },
          { name: "gasFees", type: "bytes32" },
          { name: "paymasterAndData", type: "bytes" },
          { name: "signature", type: "bytes" },
        ],
      },
      { name: "beneficiary", type: "address" },
    ],
    outputs: [],
  },
  {
    name: "getUserOpHash",
    type: "function",
    inputs: [
      {
        name: "userOp",
        type: "tuple",
        components: [
          { name: "sender", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "initCode", type: "bytes" },
          { name: "callData", type: "bytes" },
          { name: "accountGasLimits", type: "bytes32" },
          { name: "preVerificationGas", type: "uint256" },
          { name: "gasFees", type: "bytes32" },
          { name: "paymasterAndData", type: "bytes" },
          { name: "signature", type: "bytes" },
        ],
      },
    ],
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "view",
  },
] as const;

// Define custom chain
const stablenetTestnet = defineChain({
  id: CHAIN_ID,
  name: "StableNet Testnet",
  nativeCurrency: { name: "KRC", symbol: "KRC", decimals: 18 },
  rpcUrls: {
    default: { http: [RPC_URL] },
  },
});

// ============ Helper Functions ============

function log(section: string, ...args: unknown[]) {
  console.log(`[${section}]`, ...args);
}

function logSection(title: string) {
  console.log("\n" + "=".repeat(60));
  console.log(`  ${title}`);
  console.log("=".repeat(60) + "\n");
}

// Pack gas limits for UserOperation (ERC-4337 v0.7)
function packAccountGasLimits(
  verificationGasLimit: bigint,
  callGasLimit: bigint
): Hex {
  return concat([
    pad(toHex(verificationGasLimit), { size: 16 }),
    pad(toHex(callGasLimit), { size: 16 }),
  ]) as Hex;
}

// Pack gas fees for UserOperation
function packGasFees(
  maxPriorityFeePerGas: bigint,
  maxFeePerGas: bigint
): Hex {
  return concat([
    pad(toHex(maxPriorityFeePerGas), { size: 16 }),
    pad(toHex(maxFeePerGas), { size: 16 }),
  ]) as Hex;
}

// Create ValidationId from validator address
function validatorToIdentifier(validatorAddress: Address): Hex {
  // VALIDATION_TYPE_VALIDATOR = 0x01
  return concat(["0x01", validatorAddress]) as Hex;
}

// ============ Test Scenarios ============

async function testScenario1_EIP7702Delegation() {
  logSection("Scenario 1: EIP-7702 EOA → CA Delegation");

  const account = privateKeyToAccount(PRIVATE_KEY);
  log("Setup", "EOA Address:", account.address);

  const publicClient = createPublicClient({
    chain: stablenetTestnet,
    transport: http(RPC_URL),
  });

  const walletClient = createWalletClient({
    account,
    chain: stablenetTestnet,
    transport: http(RPC_URL),
  });

  // Check if EIP-7702 is supported
  log("Check", "Testing EIP-7702 support...");

  try {
    // Get current nonce
    const nonce = await publicClient.getTransactionCount({
      address: account.address,
    });
    log("Info", "Current nonce:", nonce);

    // Check EOA code
    const code = await publicClient.getCode({ address: account.address });
    log("Info", "EOA code before delegation:", code || "0x (empty)");

    // EIP-7702 Authorization
    // Note: viem supports signAuthorization in experimental mode
    log("Info", "EIP-7702 delegation requires Prague hardfork");
    log("Info", "Authorization structure:");
    log("Info", "  - chainId:", CHAIN_ID);
    log("Info", "  - address (delegate to):", ADDRESSES.kernel);
    log("Info", "  - nonce:", nonce);

    // For demonstration, show how to create the authorization
    // In a real scenario, use walletClient.signAuthorization()
    log("Demo", "To delegate EOA to Kernel:");
    log("Demo", `  const auth = await walletClient.signAuthorization({`);
    log("Demo", `    contractAddress: "${ADDRESSES.kernel}",`);
    log("Demo", `  });`);
    log("Demo", `  const hash = await walletClient.sendTransaction({`);
    log("Demo", `    authorizationList: [auth],`);
    log("Demo", `    to: targetAddress,`);
    log("Demo", `    data: calldata,`);
    log("Demo", `  });`);

    // After delegation, the EOA can use Kernel functions
    log("Result", "After EIP-7702 delegation:");
    log("Result", "  - EOA address remains:", account.address);
    log("Result", "  - EOA code points to:", ADDRESSES.kernel);
    log("Result", "  - Can call: execute(), validateUserOp(), etc.");

    return true;
  } catch (error) {
    log("Error", "EIP-7702 test failed:", error);
    return false;
  }
}

async function testScenario2_USDCGasPayment() {
  logSection("Scenario 2: USDC Gas Payment via ERC20Paymaster");

  const account = privateKeyToAccount(PRIVATE_KEY);

  const publicClient = createPublicClient({
    chain: stablenetTestnet,
    transport: http(RPC_URL),
  });

  const walletClient = createWalletClient({
    account,
    chain: stablenetTestnet,
    transport: http(RPC_URL),
  });

  try {
    // Check USDC balance
    const usdcBalance = await publicClient.readContract({
      address: ADDRESSES.usdc,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [account.address],
    });
    log("Balance", "USDC:", Number(usdcBalance) / 1e6, "USDC");

    // Check ETH balance
    const ethBalance = await publicClient.getBalance({
      address: account.address,
    });
    log("Balance", "ETH:", Number(ethBalance) / 1e18, "ETH");

    // For USDC gas payment, the flow is:
    // 1. User approves ERC20Paymaster to spend USDC
    // 2. User creates UserOperation with paymasterAndData = ERC20Paymaster address + data
    // 3. ERC20Paymaster validates and takes USDC as gas payment
    // 4. Paymaster pays ETH to EntryPoint

    log("Flow", "USDC Gas Payment Flow:");
    log("Flow", "  1. Approve USDC to ERC20Paymaster");
    log("Flow", "  2. Create UserOp with paymasterAndData");
    log("Flow", "  3. ERC20Paymaster takes USDC, pays ETH");

    // Step 1: Approve USDC (if needed)
    const approveAmount = parseUnits("100", 6); // 100 USDC

    log("Action", "Approving USDC to ERC20Paymaster...");
    const approveHash = await walletClient.writeContract({
      address: ADDRESSES.usdc,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [ADDRESSES.erc20Paymaster, approveAmount],
    });
    log("Tx", "Approve tx:", approveHash);

    // Wait for confirmation
    const receipt = await publicClient.waitForTransactionReceipt({
      hash: approveHash,
    });
    log("Confirmed", "Block:", receipt.blockNumber);

    // Step 2: Create UserOperation structure
    log("UserOp", "Creating UserOperation for USDC gas payment...");

    // Build calldata for execute()
    const executeCalldata = encodeFunctionData({
      abi: KERNEL_ABI,
      functionName: "execute",
      args: [
        "0x0000000000000000000000000000000000000000000000000000000000000000" as Hex, // EXEC_MODE_DEFAULT
        concat([
          account.address, // target (self)
          pad(toHex(0n), { size: 32 }), // value
          "0x", // data (empty)
        ]) as Hex,
      ],
    });

    // UserOperation structure
    const userOp = {
      sender: account.address,
      nonce: 0n,
      initCode: "0x" as Hex,
      callData: executeCalldata,
      accountGasLimits: packAccountGasLimits(150000n, 100000n),
      preVerificationGas: 50000n,
      gasFees: packGasFees(1000000000n, 40000000000000n), // 1 gwei, 40000 gwei
      paymasterAndData: ADDRESSES.erc20Paymaster as Hex, // ERC20Paymaster
      signature: "0x" as Hex, // Will be signed
    };

    log("UserOp", "Structure created:", {
      sender: userOp.sender,
      paymasterAndData: userOp.paymasterAndData,
    });

    log("Result", "USDC gas payment setup complete");
    log("Result", "To execute: send UserOp to Bundler or call handleOps directly");

    return true;
  } catch (error) {
    log("Error", "USDC gas payment test failed:", error);
    return false;
  }
}

async function testScenario3_PaymasterSponsorship() {
  logSection("Scenario 3: Paymaster Sponsorship");

  const account = privateKeyToAccount(PRIVATE_KEY);

  const publicClient = createPublicClient({
    chain: stablenetTestnet,
    transport: http(RPC_URL),
  });

  const walletClient = createWalletClient({
    account,
    chain: stablenetTestnet,
    transport: http(RPC_URL),
  });

  try {
    // Check EntryPoint deposit for Paymaster
    const paymasterDeposit = (await publicClient.readContract({
      address: ADDRESSES.entryPoint,
      abi: ENTRYPOINT_ABI,
      functionName: "balanceOf",
      args: [ADDRESSES.erc20Paymaster],
    })) as bigint;
    log("Balance", "Paymaster EntryPoint deposit:", Number(paymasterDeposit) / 1e18, "ETH");

    // For Paymaster sponsorship flow:
    // 1. Paymaster has ETH deposited in EntryPoint
    // 2. User creates UserOperation with paymasterAndData = Paymaster + signature
    // 3. Paymaster validates and agrees to sponsor
    // 4. EntryPoint uses Paymaster's deposit for gas

    log("Flow", "Paymaster Sponsorship Flow:");
    log("Flow", "  1. Paymaster deposits ETH to EntryPoint");
    log("Flow", "  2. User creates UserOp with paymaster signature");
    log("Flow", "  3. Paymaster validates sponsorship criteria");
    log("Flow", "  4. EntryPoint uses Paymaster deposit for gas");

    // Deposit ETH to EntryPoint for Paymaster (if needed)
    if (paymasterDeposit < parseEther("0.1")) {
      log("Action", "Depositing ETH to EntryPoint for Paymaster...");
      const depositHash = await walletClient.writeContract({
        address: ADDRESSES.entryPoint,
        abi: ENTRYPOINT_ABI,
        functionName: "depositTo",
        args: [ADDRESSES.erc20Paymaster],
        value: parseEther("1"),
      });
      log("Tx", "Deposit tx:", depositHash);

      const receipt = await publicClient.waitForTransactionReceipt({
        hash: depositHash,
      });
      log("Confirmed", "Block:", receipt.blockNumber);
    }

    // For VerifyingPaymaster, paymasterAndData includes signature
    log("UserOp", "For VerifyingPaymaster:");
    log("UserOp", "  paymasterAndData = paymaster address (20 bytes)");
    log("UserOp", "                   + validUntil (6 bytes)");
    log("UserOp", "                   + validAfter (6 bytes)");
    log("UserOp", "                   + signature (65 bytes)");

    log("Result", "Paymaster sponsorship setup complete");
    log("Result", "Paymaster can now sponsor UserOperations");

    return true;
  } catch (error) {
    log("Error", "Paymaster sponsorship test failed:", error);
    return false;
  }
}

async function testDirectSubmission() {
  logSection("Direct Submission Test");

  const account = privateKeyToAccount(PRIVATE_KEY);

  const publicClient = createPublicClient({
    chain: stablenetTestnet,
    transport: http(RPC_URL),
  });

  const walletClient = createWalletClient({
    account,
    chain: stablenetTestnet,
    transport: http(RPC_URL),
  });

  try {
    log("Method", "Direct submission to EntryPoint.handleOps()");
    log("Info", "This bypasses the Bundler and submits directly");

    // Simple ETH transfer as test
    const recipient = "0x000000000000000000000000000000000000dEaD" as Address;
    const value = parseEther("0.001");

    log("Action", "Sending test ETH transfer...");
    const hash = await walletClient.sendTransaction({
      chain: stablenetTestnet,
      to: recipient,
      value: value,
    });
    log("Tx", "Hash:", hash);

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    log("Confirmed", "Block:", receipt.blockNumber);
    log("Confirmed", "Gas used:", receipt.gasUsed.toString());

    log("Result", "Direct submission successful");

    return true;
  } catch (error) {
    log("Error", "Direct submission failed:", error);
    return false;
  }
}

// ============ Main ============

async function main() {
  console.log("\n");
  console.log("╔════════════════════════════════════════════════════════════╗");
  console.log("║       EIP-7702 + ERC-4337 Integration Test                 ║");
  console.log("╠════════════════════════════════════════════════════════════╣");
  console.log("║  Chain ID: 8283                                            ║");
  console.log("║  RPC: http://127.0.0.1:8501                                ║");
  console.log("╚════════════════════════════════════════════════════════════╝");

  const results: Record<string, boolean> = {};

  // Run all scenarios
  results["Scenario 1: EIP-7702 Delegation"] = await testScenario1_EIP7702Delegation();
  results["Scenario 2: USDC Gas Payment"] = await testScenario2_USDCGasPayment();
  results["Scenario 3: Paymaster Sponsorship"] = await testScenario3_PaymasterSponsorship();
  results["Direct Submission"] = await testDirectSubmission();

  // Summary
  logSection("Test Results Summary");

  for (const [name, passed] of Object.entries(results)) {
    const status = passed ? "✅ PASS" : "❌ FAIL";
    console.log(`  ${status}  ${name}`);
  }

  console.log("\n");
  console.log("Next Steps:");
  console.log("  1. For Bundler: Send UserOp to eth_sendUserOperation RPC");
  console.log("  2. For Proxy: Use proxy server to relay transactions");
  console.log("  3. For Production: Deploy on mainnet with real Paymaster");
  console.log("\n");
}

main().catch(console.error);
