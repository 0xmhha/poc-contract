// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "./utils/DeploymentAddresses.sol";
import {PriceOracle} from "../src/defi/PriceOracle.sol";
import {DEXIntegration} from "../src/defi/DEXIntegration.sol";

/**
 * @title DeployDeFiScript
 * @notice Deployment script for DeFi infrastructure
 * @dev Deploys price oracle and DEX integration contracts
 *
 * Deployment Order:
 *   1. PriceOracle - Token price feeds
 *   2. DEXIntegration - Uniswap V3 integration (depends on WKRW and external DEX addresses)
 *
 * Dependencies:
 *   - DEXIntegration requires WKRW token address (auto-loaded from deployment file)
 *
 * Environment Variables (for DEXIntegration):
 *   - SWAP_ROUTER: Uniswap V3 SwapRouter address
 *   - QUOTER: Uniswap V3 Quoter address
 *   - WKRW_ADDRESS: Override WKRW token address (optional if already deployed)
 *
 * Usage:
 *   forge script script/DeployDeFi.s.sol:DeployDeFiScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployDeFiScript is DeploymentHelper {
    PriceOracle public priceOracle;
    DEXIntegration public dexIntegration;

    function setUp() public {}

    function run() public {
        _initDeployment();

        // DEX Integration requires external addresses
        address swapRouter = vm.envOr("SWAP_ROUTER", address(0));
        address quoter = vm.envOr("QUOTER", address(0));
        // Load WKRW from deployment file or env var
        address wkrw = _getAddressOrEnv(DeploymentAddresses.KEY_WKRW, "WKRW_ADDRESS");

        console.log("=== Deploying DeFi Infrastructure ===");

        vm.startBroadcast();

        // 1. Deploy Price Oracle (or use existing)
        address existingOracle = _getAddress(DeploymentAddresses.KEY_PRICE_ORACLE);
        if (existingOracle == address(0)) {
            priceOracle = new PriceOracle();
            _setAddress(DeploymentAddresses.KEY_PRICE_ORACLE, address(priceOracle));
            console.log("PriceOracle deployed at:", address(priceOracle));
        } else {
            priceOracle = PriceOracle(existingOracle);
            console.log("PriceOracle: Using existing at", existingOracle);
        }

        // 2. Deploy DEX Integration (only if all addresses provided)
        if (swapRouter != address(0) && quoter != address(0) && wkrw != address(0)) {
            dexIntegration = new DEXIntegration(swapRouter, quoter, wkrw);
            _setAddress(DeploymentAddresses.KEY_DEX_INTEGRATION, address(dexIntegration));
            console.log("DEXIntegration deployed at:", address(dexIntegration));
        } else {
            console.log("DEXIntegration: Skipped (SWAP_ROUTER, QUOTER, or WKRW not available)");
        }

        vm.stopBroadcast();

        // Save addresses
        _saveAddresses();

        // Log summary
        console.log("\n=== DeFi Deployment Summary ===");
        console.log("PriceOracle:", address(priceOracle));
        if (address(dexIntegration) != address(0)) {
            console.log("DEXIntegration:", address(dexIntegration));
        }
    }
}

/**
 * @title DeployPriceOracleScript
 * @notice Deployment script for only PriceOracle
 *
 * Usage:
 *   forge script script/DeployDeFi.s.sol:DeployPriceOracleScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployPriceOracleScript is Script {
    function run() public {
        vm.startBroadcast();

        PriceOracle priceOracle = new PriceOracle();

        vm.stopBroadcast();

        console.log("PriceOracle deployed at:", address(priceOracle));
    }
}

/**
 * @title DeployDEXIntegrationScript
 * @notice Deployment script for DEXIntegration with existing infrastructure
 *
 * Environment Variables:
 *   - SWAP_ROUTER: Uniswap V3 SwapRouter address
 *   - QUOTER: Uniswap V3 Quoter address
 *   - WKRW_ADDRESS: WKRW token address
 *
 * Usage:
 *   SWAP_ROUTER=0x... QUOTER=0x... WKRW_ADDRESS=0x... forge script script/DeployDeFi.s.sol:DeployDEXIntegrationScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployDEXIntegrationScript is Script {
    function run() public {
        address swapRouter = vm.envAddress("SWAP_ROUTER");
        address quoter = vm.envAddress("QUOTER");
        address wkrw = vm.envAddress("WKRW_ADDRESS");

        vm.startBroadcast();

        DEXIntegration dexIntegration = new DEXIntegration(swapRouter, quoter, wkrw);

        vm.stopBroadcast();

        console.log("DEXIntegration deployed at:", address(dexIntegration));
        console.log("SwapRouter:", swapRouter);
        console.log("Quoter:", quoter);
        console.log("WKRW:", wkrw);
    }
}
