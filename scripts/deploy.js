#!/usr/bin/env node

const { execSync } = require("child_process");
const path = require("path");
const fs = require("fs");

// Load environment variables from .env file
require("dotenv").config({ path: path.join(__dirname, "..", ".env") });

// Network configuration
const NETWORKS = {
    local: {
        rpcUrl: process.env.RPC_URL_LOCAL || "http://localhost:8545",
        chainId: 31337,
        verify: false,
    },
    sepolia: {
        rpcUrl: process.env.RPC_URL_SEPOLIA,
        chainId: 11155111,
        verify: true,
    },
    "stablenet-testnet": {
        rpcUrl: process.env.RPC_URL_STABLENET_TESTNET,
        chainId: 8283,
        verify: true,
    },
    stablenet: {
        rpcUrl: process.env.RPC_URL_STABLENET,
        chainId: 8282,
        verify: true,
    },
};

// Get network from environment or command line argument
const network = process.env.NETWORK || process.argv[2] || "local";

function validateEnvironment() {
    const config = NETWORKS[network];

    if (!config) {
        console.error(`Error: Unknown network "${network}"`);
        console.error(`Available networks: ${Object.keys(NETWORKS).join(", ")}`);
        process.exit(1);
    }

    if (!config.rpcUrl) {
        console.error(`Error: RPC URL not configured for network "${network}"`);
        console.error(`Please set RPC_URL_${network.toUpperCase()} in your .env file`);
        process.exit(1);
    }

    if (!process.env.PRIVATE_KEY) {
        console.error("Error: PRIVATE_KEY not set in .env file");
        process.exit(1);
    }

    return config;
}

function buildForgeCommand(config) {
    const scriptPath = "script/DeployEntryPoint.s.sol:DeployEntryPointScript";

    let cmd = [
        "forge",
        "script",
        scriptPath,
        "--rpc-url",
        config.rpcUrl,
        "--private-key",
        process.env.PRIVATE_KEY,
        "--broadcast",
    ];

    // Add verification for non-local networks
    if (config.verify && process.env.EXPLORER_API_KEY) {
        cmd.push("--verify");
        cmd.push("--etherscan-api-key");
        cmd.push(process.env.EXPLORER_API_KEY);
    }

    return cmd.join(" ");
}

function saveDeployment(network, output) {
    const deploymentsDir = path.join(__dirname, "..", "deployments");

    if (!fs.existsSync(deploymentsDir)) {
        fs.mkdirSync(deploymentsDir, { recursive: true });
    }

    // Extract deployed addresses from output
    const entryPointMatch = output.match(/EntryPoint deployed at: (0x[a-fA-F0-9]{40})/);
    const senderCreatorMatch = output.match(/SenderCreator deployed at: (0x[a-fA-F0-9]{40})/);

    if (entryPointMatch) {
        const deployment = {
            network,
            chainId: NETWORKS[network].chainId,
            timestamp: new Date().toISOString(),
            contracts: {
                EntryPoint: entryPointMatch[1],
                SenderCreator: senderCreatorMatch ? senderCreatorMatch[1] : null,
            },
        };

        const filename = `${network}.json`;
        const filepath = path.join(deploymentsDir, filename);

        fs.writeFileSync(filepath, JSON.stringify(deployment, null, 2));
        console.log(`\nDeployment info saved to: deployments/${filename}`);
    }
}

async function main() {
    console.log("=".repeat(60));
    console.log(`Deploying EntryPoint to ${network}`);
    console.log("=".repeat(60));

    const config = validateEnvironment();

    console.log(`\nNetwork: ${network}`);
    console.log(`Chain ID: ${config.chainId}`);
    console.log(`RPC URL: ${config.rpcUrl.replace(/\/[^/]*$/, "/***")}`);
    console.log(`Verification: ${config.verify ? "enabled" : "disabled"}`);
    console.log("");

    const command = buildForgeCommand(config);

    console.log("Executing forge script...\n");

    try {
        const output = execSync(command, {
            cwd: path.join(__dirname, ".."),
            encoding: "utf-8",
            stdio: ["inherit", "pipe", "pipe"],
        });

        console.log(output);
        saveDeployment(network, output);

        console.log("\n" + "=".repeat(60));
        console.log("Deployment completed successfully!");
        console.log("=".repeat(60));
    } catch (error) {
        console.error("\nDeployment failed!");
        if (error.stdout) console.log(error.stdout);
        if (error.stderr) console.error(error.stderr);
        process.exit(1);
    }
}

main();
