#!/usr/bin/env npx ts-node
/**
 * Paymaster Configuration Script
 *
 * Configures ERC-4337 Paymasters after deployment:
 * - ERC20Paymaster: Add supported tokens
 * - SponsorPaymaster: Set whitelist, budgets, campaigns
 *
 * Usage:
 *   npx ts-node script/ts/configure-paymaster.ts [command] [options]
 *
 * Commands:
 *   # ERC20Paymaster
 *   add-token <token>           Add supported token to ERC20Paymaster
 *   remove-token <token>        Remove supported token from ERC20Paymaster
 *   set-markup <bps>            Set markup (500-5000 basis points)
 *   token-info <token>          Show token configuration and price quote
 *
 *   # SponsorPaymaster
 *   whitelist <address>         Add address to whitelist
 *   unwhitelist <address>       Remove address from whitelist
 *   whitelist-batch <file>      Add addresses from file (one per line)
 *   set-budget <user> <limit> <period>  Set user budget (limit in ETH, period in seconds)
 *   set-default-budget <limit> <period> Set default budget
 *   create-campaign             Create a new campaign (interactive)
 *   campaign-info <id>          Show campaign info
 *   budget-info <user>          Show user budget info
 *
 *   # General
 *   info                        Show all paymaster configurations
 *
 * Examples:
 *   npx ts-node script/ts/configure-paymaster.ts info
 *   npx ts-node script/ts/configure-paymaster.ts add-token 0x1234...
 *   npx ts-node script/ts/configure-paymaster.ts whitelist 0x5678...
 *   npx ts-node script/ts/configure-paymaster.ts set-budget 0x5678... 0.5 86400
 *   npx ts-node script/ts/configure-paymaster.ts set-markup 1500
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";
import * as readline from "readline";

// ============ Configuration ============

const PROJECT_ROOT = path.resolve(__dirname, "..", "..");
dotenv.config({ path: path.join(PROJECT_ROOT, ".env") });

// ============ Environment Validation ============

function validateEnv(): { rpcUrl: string; privateKey: string; chainId: string } {
  const rpcUrl = process.env.RPC_URL;
  const privateKey = process.env.PRIVATE_KEY_DEPLOYER || process.env.PRIVATE_KEY || "";
  const chainId = process.env.CHAIN_ID || "8283";

  if (!rpcUrl) {
    throw new Error("RPC_URL is not set in .env");
  }

  return { rpcUrl, privateKey, chainId };
}

// ============ Address Loading ============

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

// ============ Cast Commands ============

function execCast(args: string[], options: { rpcUrl: string; privateKey?: string }): string {
  // Quote arguments that contain parentheses (function signatures)
  const quotedArgs = args.map((arg) => (arg.includes("(") ? `"${arg}"` : arg));
  const cmd = ["cast", ...quotedArgs, "--rpc-url", options.rpcUrl];

  if (options.privateKey) {
    cmd.push("--private-key", options.privateKey);
  }

  try {
    const result = execSync(cmd.join(" "), {
      encoding: "utf8",
      cwd: PROJECT_ROOT,
      stdio: ["pipe", "pipe", "pipe"],
      shell: "/bin/bash",
    });
    return result.trim();
  } catch (error: unknown) {
    const execError = error as { stderr?: string; message?: string };
    throw new Error(`Cast command failed: ${execError.stderr || execError.message}`);
  }
}

function sendTransaction(
  to: string,
  signature: string,
  args: string[],
  rpcUrl: string,
  privateKey: string
): void {
  // Quote function signature to prevent shell from interpreting parentheses
  const quotedSignature = `"${signature}"`;
  const cmd = ["cast", "send", to, quotedSignature, ...args, "--rpc-url", rpcUrl, "--private-key", privateKey];

  execSync(cmd.join(" "), {
    cwd: PROJECT_ROOT,
    stdio: "inherit",
    shell: "/bin/bash",
  });
}

/**
 * Clean up cast call result - removes brackets and handles various formats
 */
function cleanCastResult(result: string): string {
  let cleaned = result.trim();
  // Remove brackets if present: [123] -> 123
  if (cleaned.startsWith("[") && cleaned.endsWith("]")) {
    cleaned = cleaned.slice(1, -1);
  }
  // Handle scientific notation: 1e21 -> 1000000000000000000000
  if (cleaned.includes("e") || cleaned.includes("E")) {
    try {
      cleaned = BigInt(Number(cleaned)).toString();
    } catch {
      // If conversion fails, keep original
    }
  }
  return cleaned;
}

function formatEther(wei: string): string {
  // Clean the input first
  const cleanedWei = cleanCastResult(wei);

  try {
    // Manual conversion is more reliable
    const weiNum = BigInt(cleanedWei);
    const wholePart = weiNum / BigInt(1e18);
    const fractionalPart = weiNum % BigInt(1e18);
    const fractionalStr = fractionalPart.toString().padStart(18, "0").slice(0, 6);
    return `${wholePart}.${fractionalStr}`;
  } catch {
    // Fallback to cast if BigInt fails
    try {
      const result = execSync(`cast from-wei ${cleanedWei}`, { encoding: "utf8" });
      return result.trim();
    } catch {
      return cleanedWei;
    }
  }
}

function toWei(ether: string): string {
  try {
    const result = execSync(`cast to-wei ${ether}`, { encoding: "utf8" });
    return result.trim();
  } catch {
    const etherNum = parseFloat(ether);
    return BigInt(Math.floor(etherNum * 1e18)).toString();
  }
}

// ============ ERC20Paymaster Functions ============

function addSupportedToken(
  paymaster: string,
  token: string,
  rpcUrl: string,
  privateKey: string
): void {
  console.log(`\nAdding supported token to ERC20Paymaster...`);
  console.log(`  Paymaster: ${paymaster}`);
  console.log(`  Token: ${token}`);

  sendTransaction(paymaster, "setSupportedToken(address,bool)", [token, "true"], rpcUrl, privateKey);

  console.log(`  ✅ Token added successfully!`);
}

function removeSupportedToken(
  paymaster: string,
  token: string,
  rpcUrl: string,
  privateKey: string
): void {
  console.log(`\nRemoving supported token from ERC20Paymaster...`);
  console.log(`  Paymaster: ${paymaster}`);
  console.log(`  Token: ${token}`);

  sendTransaction(paymaster, "setSupportedToken(address,bool)", [token, "false"], rpcUrl, privateKey);

  console.log(`  ✅ Token removed successfully!`);
}

function setMarkup(
  paymaster: string,
  markup: string,
  rpcUrl: string,
  privateKey: string
): void {
  console.log(`\nSetting markup on ERC20Paymaster...`);
  console.log(`  Paymaster: ${paymaster}`);
  console.log(`  Markup: ${markup} basis points (${parseInt(markup) / 100}%)`);

  sendTransaction(paymaster, "setMarkup(uint256)", [markup], rpcUrl, privateKey);

  console.log(`  ✅ Markup set successfully!`);
}

function showTokenInfo(
  paymaster: string,
  token: string,
  rpcUrl: string
): void {
  console.log(`\nToken Info for ERC20Paymaster`);
  console.log("=".repeat(60));
  console.log(`Paymaster: ${paymaster}`);
  console.log(`Token: ${token}`);

  try {
    // Check if token is supported
    const isSupported = execCast(
      ["call", paymaster, "supportedTokens(address)(bool)", token],
      { rpcUrl }
    );
    console.log(`Supported: ${isSupported}`);

    // Get token decimals
    const decimals = execCast(
      ["call", paymaster, "tokenDecimals(address)(uint8)", token],
      { rpcUrl }
    );
    console.log(`Cached Decimals: ${decimals}`);

    // Get markup
    const markup = execCast(["call", paymaster, "markup()(uint256)"], { rpcUrl });
    console.log(`Current Markup: ${markup} basis points (${parseInt(markup) / 100}%)`);

    // Get oracle
    const oracle = execCast(["call", paymaster, "oracle()(address)"], { rpcUrl });
    console.log(`Oracle: ${oracle}`);

    // Get quote for 0.01 ETH worth of gas
    if (isSupported === "true") {
      try {
        const quote = execCast(
          ["call", paymaster, "getTokenAmount(address,uint256)(uint256)", token, toWei("0.01")],
          { rpcUrl }
        );
        console.log(`Quote (0.01 ETH gas): ${quote} tokens`);
      } catch {
        console.log(`Quote: Unable to fetch (oracle may not have price)`);
      }
    }
  } catch (error) {
    console.error(`Error fetching token info: ${error}`);
  }
  console.log("=".repeat(60));
}

// ============ SponsorPaymaster Functions ============

function addToWhitelist(
  paymaster: string,
  account: string,
  rpcUrl: string,
  privateKey: string
): void {
  console.log(`\nAdding to SponsorPaymaster whitelist...`);
  console.log(`  Paymaster: ${paymaster}`);
  console.log(`  Account: ${account}`);

  sendTransaction(paymaster, "setWhitelist(address,bool)", [account, "true"], rpcUrl, privateKey);

  console.log(`  ✅ Account whitelisted successfully!`);
}

function removeFromWhitelist(
  paymaster: string,
  account: string,
  rpcUrl: string,
  privateKey: string
): void {
  console.log(`\nRemoving from SponsorPaymaster whitelist...`);
  console.log(`  Paymaster: ${paymaster}`);
  console.log(`  Account: ${account}`);

  sendTransaction(paymaster, "setWhitelist(address,bool)", [account, "false"], rpcUrl, privateKey);

  console.log(`  ✅ Account removed from whitelist!`);
}

function whitelistBatch(
  paymaster: string,
  filePath: string,
  rpcUrl: string,
  privateKey: string
): void {
  console.log(`\nBatch whitelisting from file...`);

  if (!fs.existsSync(filePath)) {
    throw new Error(`File not found: ${filePath}`);
  }

  const content = fs.readFileSync(filePath, "utf8");
  const addresses = content
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.startsWith("0x") && line.length === 42);

  if (addresses.length === 0) {
    console.log("No valid addresses found in file");
    return;
  }

  console.log(`  Paymaster: ${paymaster}`);
  console.log(`  Found ${addresses.length} addresses`);

  // Convert to ABI-encoded array
  const addressArray = `[${addresses.join(",")}]`;

  sendTransaction(
    paymaster,
    "setWhitelistBatch(address[],bool)",
    [addressArray, "true"],
    rpcUrl,
    privateKey
  );

  console.log(`  ✅ ${addresses.length} addresses whitelisted!`);
}

function setUserBudget(
  paymaster: string,
  user: string,
  limit: string,
  period: string,
  rpcUrl: string,
  privateKey: string
): void {
  console.log(`\nSetting user budget on SponsorPaymaster...`);
  console.log(`  Paymaster: ${paymaster}`);
  console.log(`  User: ${user}`);
  console.log(`  Limit: ${limit} ETH`);
  console.log(`  Period: ${period} seconds (${parseInt(period) / 86400} days)`);

  const limitWei = toWei(limit);

  sendTransaction(
    paymaster,
    "setUserBudget(address,uint256,uint256)",
    [user, limitWei, period],
    rpcUrl,
    privateKey
  );

  console.log(`  ✅ User budget set successfully!`);
}

function setDefaultBudget(
  paymaster: string,
  limit: string,
  period: string,
  rpcUrl: string,
  privateKey: string
): void {
  console.log(`\nSetting default budget on SponsorPaymaster...`);
  console.log(`  Paymaster: ${paymaster}`);
  console.log(`  Default Limit: ${limit} ETH`);
  console.log(`  Default Period: ${period} seconds (${parseInt(period) / 86400} days)`);

  const limitWei = toWei(limit);

  sendTransaction(paymaster, "setDefaultBudget(uint256,uint256)", [limitWei, period], rpcUrl, privateKey);

  console.log(`  ✅ Default budget set successfully!`);
}

function showBudgetInfo(paymaster: string, user: string, rpcUrl: string): void {
  console.log(`\nUser Budget Info`);
  console.log("=".repeat(60));
  console.log(`Paymaster: ${paymaster}`);
  console.log(`User: ${user}`);

  try {
    // Get remaining budget
    const remaining = execCast(
      ["call", paymaster, "getRemainingBudget(address)(uint256)", user],
      { rpcUrl }
    );
    console.log(`Remaining Budget: ${formatEther(remaining)} ETH`);

    // Get whitelist status
    const isWhitelisted = execCast(
      ["call", paymaster, "whitelist(address)(bool)", user],
      { rpcUrl }
    );
    console.log(`Whitelisted: ${isWhitelisted}`);

    // Get default budget
    const defaultLimit = execCast(
      ["call", paymaster, "defaultBudgetLimit()(uint256)"],
      { rpcUrl }
    );
    const defaultPeriod = execCast(
      ["call", paymaster, "defaultBudgetPeriod()(uint256)"],
      { rpcUrl }
    );
    console.log(`\nDefault Budget:`);
    console.log(`  Limit: ${formatEther(defaultLimit)} ETH`);
    console.log(`  Period: ${defaultPeriod} seconds (${parseInt(defaultPeriod) / 86400} days)`);
  } catch (error) {
    console.error(`Error fetching budget info: ${error}`);
  }
  console.log("=".repeat(60));
}

function showCampaignInfo(paymaster: string, campaignId: string, rpcUrl: string): void {
  console.log(`\nCampaign Info`);
  console.log("=".repeat(60));
  console.log(`Paymaster: ${paymaster}`);
  console.log(`Campaign ID: ${campaignId}`);

  try {
    // Check if campaign is valid
    const isValid = execCast(
      ["call", paymaster, "isCampaignValid(uint256)(bool)", campaignId],
      { rpcUrl }
    );
    console.log(`Currently Valid: ${isValid}`);

    // Get campaign details - this returns a tuple, need to parse it
    // For simplicity, let's call individual fields
    // Note: In a real implementation, we'd need to decode the tuple properly
    console.log(`\n(Use contract read functions for detailed campaign info)`);
  } catch (error) {
    console.error(`Error fetching campaign info: ${error}`);
  }
  console.log("=".repeat(60));
}

// ============ Info Display ============

function showInfo(addresses: DeployedAddresses, rpcUrl: string): void {
  console.log("=".repeat(60));
  console.log("  Paymaster Configuration Status");
  console.log("=".repeat(60));

  // ERC20Paymaster
  const erc20Paymaster = addresses["erc20Paymaster"];
  if (erc20Paymaster) {
    console.log("\n[ERC20Paymaster]");
    console.log(`Address: ${erc20Paymaster}`);

    try {
      const oracle = execCast(["call", erc20Paymaster, "oracle()(address)"], { rpcUrl });
      const markup = execCast(["call", erc20Paymaster, "markup()(uint256)"], { rpcUrl });
      console.log(`Oracle: ${oracle}`);
      console.log(`Markup: ${markup} basis points (${parseInt(markup) / 100}%)`);

      // Check if USDC is supported
      const usdc = addresses["usdc"];
      if (usdc) {
        const usdcSupported = execCast(
          ["call", erc20Paymaster, "supportedTokens(address)(bool)", usdc],
          { rpcUrl }
        );
        console.log(`USDC (${usdc}) Supported: ${usdcSupported}`);
      }
    } catch (error) {
      console.log(`Error reading config: ${error}`);
    }
  } else {
    console.log("\n[ERC20Paymaster]: NOT DEPLOYED");
  }

  // SponsorPaymaster
  const sponsorPaymaster = addresses["sponsorPaymaster"];
  if (sponsorPaymaster) {
    console.log("\n[SponsorPaymaster]");
    console.log(`Address: ${sponsorPaymaster}`);

    try {
      const signer = execCast(["call", sponsorPaymaster, "signer()(address)"], { rpcUrl });
      const defaultLimit = execCast(
        ["call", sponsorPaymaster, "defaultBudgetLimit()(uint256)"],
        { rpcUrl }
      );
      const defaultPeriod = execCast(
        ["call", sponsorPaymaster, "defaultBudgetPeriod()(uint256)"],
        { rpcUrl }
      );
      const nextCampaignId = execCast(
        ["call", sponsorPaymaster, "nextCampaignId()(uint256)"],
        { rpcUrl }
      );

      console.log(`Signer: ${signer}`);
      console.log(`Default Budget Limit: ${formatEther(defaultLimit)} ETH`);
      console.log(`Default Budget Period: ${defaultPeriod} seconds (${parseInt(defaultPeriod) / 86400} days)`);
      console.log(`Total Campaigns: ${nextCampaignId}`);
    } catch (error) {
      console.log(`Error reading config: ${error}`);
    }
  } else {
    console.log("\n[SponsorPaymaster]: NOT DEPLOYED");
  }

  // VerifyingPaymaster
  const verifyingPaymaster = addresses["verifyingPaymaster"];
  if (verifyingPaymaster) {
    console.log("\n[VerifyingPaymaster]");
    console.log(`Address: ${verifyingPaymaster}`);

    try {
      const signer = execCast(["call", verifyingPaymaster, "verifyingSigner()(address)"], { rpcUrl });
      console.log(`Verifying Signer: ${signer}`);
    } catch (error) {
      console.log(`Error reading config: ${error}`);
    }
  } else {
    console.log("\n[VerifyingPaymaster]: NOT DEPLOYED");
  }

  // Permit2Paymaster
  const permit2Paymaster = addresses["permit2Paymaster"];
  if (permit2Paymaster) {
    console.log("\n[Permit2Paymaster]");
    console.log(`Address: ${permit2Paymaster}`);

    try {
      const markup = execCast(["call", permit2Paymaster, "markup()(uint256)"], { rpcUrl });
      console.log(`Markup: ${markup} basis points (${parseInt(markup) / 100}%)`);
    } catch (error) {
      console.log(`Error reading config: ${error}`);
    }
  } else {
    console.log("\n[Permit2Paymaster]: NOT DEPLOYED");
  }

  console.log("\n" + "=".repeat(60));
}

// ============ Interactive Campaign Creation ============

async function createCampaignInteractive(
  paymaster: string,
  rpcUrl: string,
  privateKey: string
): Promise<void> {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  const question = (prompt: string): Promise<string> => {
    return new Promise((resolve) => {
      rl.question(prompt, (answer) => resolve(answer));
    });
  };

  try {
    console.log("\n=== Create New Campaign ===\n");

    const name = await question("Campaign Name: ");
    const startTimeStr = await question("Start Time (Unix timestamp or 'now'): ");
    const durationStr = await question("Duration in days: ");
    const totalBudgetStr = await question("Total Budget (ETH): ");
    const maxPerUserStr = await question("Max per User (ETH, 0 for unlimited): ");
    const targetContract = await question("Target Contract (0x... or empty): ");
    const targetSelectorStr = await question("Target Function Selector (0x... or empty): ");

    const startTime =
      startTimeStr.toLowerCase() === "now"
        ? Math.floor(Date.now() / 1000).toString()
        : startTimeStr;

    const endTime = (parseInt(startTime) + parseInt(durationStr) * 86400).toString();
    const totalBudget = toWei(totalBudgetStr);
    const maxPerUser = maxPerUserStr === "0" ? "0" : toWei(maxPerUserStr);
    const targetSelector = targetSelectorStr || "0x00000000";
    const targetContractAddr = targetContract || "0x0000000000000000000000000000000000000000";

    console.log("\nCampaign Configuration:");
    console.log(`  Name: ${name}`);
    console.log(`  Start: ${new Date(parseInt(startTime) * 1000).toISOString()}`);
    console.log(`  End: ${new Date(parseInt(endTime) * 1000).toISOString()}`);
    console.log(`  Total Budget: ${totalBudgetStr} ETH`);
    console.log(`  Max Per User: ${maxPerUserStr} ETH`);
    console.log(`  Target Contract: ${targetContractAddr}`);
    console.log(`  Target Selector: ${targetSelector}`);

    const confirm = await question("\nCreate campaign? (y/n): ");

    if (confirm.toLowerCase() === "y") {
      sendTransaction(
        paymaster,
        "createCampaign(string,uint256,uint256,uint256,uint256,bytes4,address)",
        [
          `"${name}"`,
          startTime,
          endTime,
          totalBudget,
          maxPerUser,
          targetSelector,
          targetContractAddr,
        ],
        rpcUrl,
        privateKey
      );
      console.log("\n✅ Campaign created successfully!");
    } else {
      console.log("\nCampaign creation cancelled.");
    }
  } finally {
    rl.close();
  }
}

// ============ Main ============

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const command = args[0];

  const { rpcUrl, privateKey, chainId } = validateEnv();
  const addresses = loadDeployedAddresses(chainId);

  if (!command || command === "info") {
    showInfo(addresses, rpcUrl);
    return;
  }

  // Commands that require private key
  const writeCommands = [
    "add-token",
    "remove-token",
    "set-markup",
    "whitelist",
    "unwhitelist",
    "whitelist-batch",
    "set-budget",
    "set-default-budget",
    "create-campaign",
  ];

  if (writeCommands.includes(command) && !privateKey) {
    console.error("Error: PRIVATE_KEY_DEPLOYER (or PRIVATE_KEY) is not set");
    process.exit(1);
  }

  const erc20Paymaster = addresses["erc20Paymaster"];
  const sponsorPaymaster = addresses["sponsorPaymaster"];

  switch (command) {
    // ERC20Paymaster commands
    case "add-token": {
      if (!erc20Paymaster) {
        console.error("ERC20Paymaster not deployed");
        process.exit(1);
      }
      const token = args[1];
      if (!token) {
        console.error("Usage: add-token <token-address>");
        process.exit(1);
      }
      addSupportedToken(erc20Paymaster, token, rpcUrl, privateKey);
      break;
    }

    case "remove-token": {
      if (!erc20Paymaster) {
        console.error("ERC20Paymaster not deployed");
        process.exit(1);
      }
      const token = args[1];
      if (!token) {
        console.error("Usage: remove-token <token-address>");
        process.exit(1);
      }
      removeSupportedToken(erc20Paymaster, token, rpcUrl, privateKey);
      break;
    }

    case "set-markup": {
      if (!erc20Paymaster) {
        console.error("ERC20Paymaster not deployed");
        process.exit(1);
      }
      const markup = args[1];
      if (!markup) {
        console.error("Usage: set-markup <basis-points>");
        process.exit(1);
      }
      setMarkup(erc20Paymaster, markup, rpcUrl, privateKey);
      break;
    }

    case "token-info": {
      if (!erc20Paymaster) {
        console.error("ERC20Paymaster not deployed");
        process.exit(1);
      }
      const token = args[1];
      if (!token) {
        console.error("Usage: token-info <token-address>");
        process.exit(1);
      }
      showTokenInfo(erc20Paymaster, token, rpcUrl);
      break;
    }

    // SponsorPaymaster commands
    case "whitelist": {
      if (!sponsorPaymaster) {
        console.error("SponsorPaymaster not deployed");
        process.exit(1);
      }
      const account = args[1];
      if (!account) {
        console.error("Usage: whitelist <address>");
        process.exit(1);
      }
      addToWhitelist(sponsorPaymaster, account, rpcUrl, privateKey);
      break;
    }

    case "unwhitelist": {
      if (!sponsorPaymaster) {
        console.error("SponsorPaymaster not deployed");
        process.exit(1);
      }
      const account = args[1];
      if (!account) {
        console.error("Usage: unwhitelist <address>");
        process.exit(1);
      }
      removeFromWhitelist(sponsorPaymaster, account, rpcUrl, privateKey);
      break;
    }

    case "whitelist-batch": {
      if (!sponsorPaymaster) {
        console.error("SponsorPaymaster not deployed");
        process.exit(1);
      }
      const filePath = args[1];
      if (!filePath) {
        console.error("Usage: whitelist-batch <file-path>");
        process.exit(1);
      }
      whitelistBatch(sponsorPaymaster, filePath, rpcUrl, privateKey);
      break;
    }

    case "set-budget": {
      if (!sponsorPaymaster) {
        console.error("SponsorPaymaster not deployed");
        process.exit(1);
      }
      const [, user, limit, period] = args;
      if (!user || !limit || !period) {
        console.error("Usage: set-budget <user-address> <limit-eth> <period-seconds>");
        process.exit(1);
      }
      setUserBudget(sponsorPaymaster, user, limit, period, rpcUrl, privateKey);
      break;
    }

    case "set-default-budget": {
      if (!sponsorPaymaster) {
        console.error("SponsorPaymaster not deployed");
        process.exit(1);
      }
      const [, limit, period] = args;
      if (!limit || !period) {
        console.error("Usage: set-default-budget <limit-eth> <period-seconds>");
        process.exit(1);
      }
      setDefaultBudget(sponsorPaymaster, limit, period, rpcUrl, privateKey);
      break;
    }

    case "create-campaign": {
      if (!sponsorPaymaster) {
        console.error("SponsorPaymaster not deployed");
        process.exit(1);
      }
      await createCampaignInteractive(sponsorPaymaster, rpcUrl, privateKey);
      break;
    }

    case "campaign-info": {
      if (!sponsorPaymaster) {
        console.error("SponsorPaymaster not deployed");
        process.exit(1);
      }
      const campaignId = args[1];
      if (!campaignId) {
        console.error("Usage: campaign-info <campaign-id>");
        process.exit(1);
      }
      showCampaignInfo(sponsorPaymaster, campaignId, rpcUrl);
      break;
    }

    case "budget-info": {
      if (!sponsorPaymaster) {
        console.error("SponsorPaymaster not deployed");
        process.exit(1);
      }
      const user = args[1];
      if (!user) {
        console.error("Usage: budget-info <user-address>");
        process.exit(1);
      }
      showBudgetInfo(sponsorPaymaster, user, rpcUrl);
      break;
    }

    default:
      console.error(`Unknown command: ${command}`);
      console.error("\nAvailable commands:");
      console.error("  info                          - Show all paymaster configurations");
      console.error("\n  ERC20Paymaster:");
      console.error("    add-token <token>           - Add supported token");
      console.error("    remove-token <token>        - Remove supported token");
      console.error("    set-markup <bps>            - Set markup (500-5000 basis points)");
      console.error("    token-info <token>          - Show token info");
      console.error("\n  SponsorPaymaster:");
      console.error("    whitelist <address>         - Add to whitelist");
      console.error("    unwhitelist <address>       - Remove from whitelist");
      console.error("    whitelist-batch <file>      - Batch whitelist from file");
      console.error("    set-budget <user> <limit> <period> - Set user budget");
      console.error("    set-default-budget <limit> <period> - Set default budget");
      console.error("    create-campaign             - Create campaign (interactive)");
      console.error("    campaign-info <id>          - Show campaign info");
      console.error("    budget-info <user>          - Show user budget info");
      process.exit(1);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
