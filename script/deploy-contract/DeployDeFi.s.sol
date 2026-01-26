// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper, DeploymentAddresses} from "../utils/DeploymentAddresses.sol";
import {PriceOracle} from "../../src/defi/PriceOracle.sol";
import {DEXIntegration} from "../../src/defi/DEXIntegration.sol";

/**
 * @title DeployDeFiScript
 * @notice Deployment script for DeFi contracts (PriceOracle, DEXIntegration)
 * @dev Deploys PriceOracle and optionally DEXIntegration
 *
 * Deployed Contracts:
 *   - PriceOracle: Unified price oracle supporting Chainlink feeds and Uniswap V3 TWAP
 *   - DEXIntegration: Integration layer for Uniswap V3 swaps with native token support
 *
 * Deployment Order:
 *   1. PriceOracle (Layer 0 - no dependencies)
 *   2. DEXIntegration (Layer 1+ - depends on wKRC and external Uniswap V3 contracts)
 *
 * Environment Variables:
 *   - SWAP_ROUTER: Uniswap V3 SwapRouter address (required for DEXIntegration)
 *   - QUOTER: Uniswap V3 Quoter address (optional, can be address(0))
 *   - WKRC_ADDRESS: Override for wKRC address (optional, loads from deployment file by default)
 *
 * Usage:
 *   FOUNDRY_PROFILE=defi forge script script/deploy-contract/DeployDeFi.s.sol:DeployDeFiScript \
 *     --rpc-url <RPC_URL> --broadcast
 */
contract DeployDeFiScript is DeploymentHelper {
    PriceOracle public priceOracle;
    DEXIntegration public dexIntegration;

    function setUp() public {}

    function run() public {
        _initDeployment();

        vm.startBroadcast();

        // ============ Layer 0: No Dependencies ============

        // Deploy PriceOracle
        address existing = _getAddress(DeploymentAddresses.KEY_PRICE_ORACLE);
        if (existing == address(0)) {
            priceOracle = new PriceOracle();
            _setAddress(DeploymentAddresses.KEY_PRICE_ORACLE, address(priceOracle));
            console.log("PriceOracle deployed at:", address(priceOracle));
        } else {
            priceOracle = PriceOracle(existing);
            console.log("PriceOracle: Using existing at", existing);
        }

        // ============ Layer 1+: Depends on External Contracts ============

        // Deploy DEXIntegration (requires wKRC and Uniswap V3 contracts)
        existing = _getAddress(DeploymentAddresses.KEY_DEX_INTEGRATION);
        if (existing == address(0)) {
            // Get wKRC address from deployment file or env var
            address wkrcAddr = _getAddressOrEnv(DeploymentAddresses.KEY_WKRC, "WKRC_ADDRESS");

            // Get Uniswap V3 addresses from env vars
            address swapRouter = vm.envOr("SWAP_ROUTER", address(0));
            address quoter = vm.envOr("QUOTER", address(0));

            if (swapRouter != address(0) && wkrcAddr != address(0)) {
                dexIntegration = new DEXIntegration(swapRouter, quoter, wkrcAddr);
                _setAddress(DeploymentAddresses.KEY_DEX_INTEGRATION, address(dexIntegration));
                console.log("DEXIntegration deployed at:", address(dexIntegration));
                console.log("  SwapRouter:", swapRouter);
                console.log("  Quoter:", quoter);
                console.log("  wKRC:", wkrcAddr);
            } else {
                console.log("DEXIntegration: Skipped (missing dependencies)");
                if (swapRouter == address(0)) {
                    console.log("  - Set SWAP_ROUTER env var to deploy DEXIntegration");
                }
                if (wkrcAddr == address(0)) {
                    console.log("  - Deploy wKRC first or set WKRC_ADDRESS env var");
                }
            }
        } else {
            dexIntegration = DEXIntegration(payable(existing));
            console.log("DEXIntegration: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        console.log("\n=== DeFi Deployment Summary ===");
        console.log("PriceOracle:", address(priceOracle));
        console.log("  Staleness Threshold:", priceOracle.stalenessThreshold() / 1 hours, "hours");
        console.log("  Supports: Chainlink feeds, Uniswap V3 TWAP");
        if (address(dexIntegration) != address(0)) {
            console.log("DEXIntegration:", address(dexIntegration));
            console.log("  SwapRouter:", address(dexIntegration.swapRouter()));
            console.log("  wKRC:", address(dexIntegration.wkrc()));
        }
        console.log("\nDeFi contracts are ready for use:");
        console.log("  - PriceOracle: Configure Chainlink feeds or Uniswap pools");
        console.log("  - DEXIntegration: Execute swaps with native token support");
    }
}
