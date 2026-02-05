// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import { Script, console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "../utils/DeploymentAddresses.sol";
import { AutoSwapPlugin } from "../../src/erc7579-plugins/AutoSwapPlugin.sol";
import { MicroLoanPlugin } from "../../src/erc7579-plugins/MicroLoanPlugin.sol";
import { OnRampPlugin } from "../../src/erc7579-plugins/OnRampPlugin.sol";
import { IPriceOracle } from "../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";

/**
 * @title DeployPluginsScript
 * @notice Deployment script for ERC-7579 Plugin modules
 * @dev Deploys plugin modules for smart account advanced functionality
 *
 * Plugin Modules:
 *   - AutoSwapPlugin: Automated trading (DCA, limit orders, stop loss, take profit)
 *   - MicroLoanPlugin: Collateralized micro-loans with credit scoring
 *   - OnRampPlugin: Fiat on-ramp integration with KYC tracking
 *
 * Dependencies:
 *   - AutoSwapPlugin: PriceOracle, DEX Router
 *   - MicroLoanPlugin: PriceOracle, Fee Recipient
 *   - OnRampPlugin: Treasury
 *
 * Deployment Order: 8 (after Executors, requires PriceOracle and DEX)
 *
 * Environment Variables:
 *   - PRICE_ORACLE: Address of deployed PriceOracle (optional, uses saved address)
 *   - DEX_ROUTER: Address of DEX router for swaps (required for AutoSwapPlugin)
 *   - FEE_RECIPIENT: Address to receive protocol fees (defaults to deployer)
 *   - TREASURY: Address for on-ramp fees (defaults to deployer)
 *   - PROTOCOL_FEE_BPS: Protocol fee in basis points (default: 50 = 0.5%)
 *   - LIQUIDATION_BONUS_BPS: Liquidation bonus in basis points (default: 500 = 5%)
 *   - ONRAMP_FEE_BPS: On-ramp fee in basis points (default: 100 = 1%)
 *   - ORDER_EXPIRY: On-ramp order expiry in seconds (default: 86400 = 24 hours)
 *
 * Usage:
 *   forge script script/deploy-contract/DeployPlugins.s.sol:DeployPluginsScript \
 *     --rpc-url <RPC_URL> --broadcast
 *
 * With plugins profile:
 *   FOUNDRY_PROFILE=plugins forge script script/deploy-contract/DeployPlugins.s.sol:DeployPluginsScript \
 *     --rpc-url <RPC_URL> --broadcast
 */
contract DeployPluginsScript is DeploymentHelper {
    AutoSwapPlugin public autoSwapPlugin;
    MicroLoanPlugin public microLoanPlugin;
    OnRampPlugin public onRampPlugin;

    function setUp() public { }

    function run() public {
        _initDeployment();

        // Get configuration from environment or use defaults
        address priceOracle = _getAddressOrEnv(DeploymentAddresses.KEY_PRICE_ORACLE, "PRICE_ORACLE");
        address dexRouter = _getAddressOrEnv(DeploymentAddresses.KEY_UNISWAP_SWAP_ROUTER, "DEX_ROUTER");
        address feeRecipient = vm.envOr("FEE_RECIPIENT", msg.sender);
        address treasury = vm.envOr("TREASURY", msg.sender);

        // Plugin configuration
        uint256 protocolFeeBps = vm.envOr("PROTOCOL_FEE_BPS", uint256(50)); // 0.5%
        uint256 liquidationBonusBps = vm.envOr("LIQUIDATION_BONUS_BPS", uint256(500)); //5%
        uint256 onRampFeeBps = vm.envOr("ONRAMP_FEE_BPS", uint256(100)); //1%
        uint256 orderExpiry = vm.envOr("ORDER_EXPIRY", uint256(24 hours));

        vm.startBroadcast();

        // 1. Deploy AutoSwapPlugin (requires PriceOracle and DEX Router)
        address existing = _getAddress(DeploymentAddresses.KEY_AUTO_SWAP_PLUGIN);
        if (existing == address(0)) {
            if (priceOracle == address(0)) {
                console.log("Warning: PriceOracle not found. Skipping AutoSwapPlugin deployment.");
                console.log("  Set PRICE_ORACLE env var or deploy PriceOracle first.");
            } else if (dexRouter == address(0)) {
                console.log("Warning: DEX Router not found. Skipping AutoSwapPlugin deployment.");
                console.log("  Set DEX_ROUTER env var or deploy DEXIntegration first.");
            } else {
                autoSwapPlugin = new AutoSwapPlugin(IPriceOracle(priceOracle), dexRouter);
                _setAddress(DeploymentAddresses.KEY_AUTO_SWAP_PLUGIN, address(autoSwapPlugin));
                console.log("AutoSwapPlugin deployed at:", address(autoSwapPlugin));
            }
        } else {
            autoSwapPlugin = AutoSwapPlugin(existing);
            console.log("AutoSwapPlugin: Using existing at", existing);
        }

        // 2. Deploy MicroLoanPlugin (requires PriceOracle)
        existing = _getAddress(DeploymentAddresses.KEY_MICRO_LOAN_PLUGIN);
        if (existing == address(0)) {
            if (priceOracle == address(0)) {
                console.log("Warning: PriceOracle not found. Skipping MicroLoanPlugin deployment.");
                console.log("  Set PRICE_ORACLE env var or deploy PriceOracle first.");
            } else {
                microLoanPlugin =
                    new MicroLoanPlugin(IPriceOracle(priceOracle), feeRecipient, protocolFeeBps, liquidationBonusBps);
                _setAddress(DeploymentAddresses.KEY_MICRO_LOAN_PLUGIN, address(microLoanPlugin));
                console.log("MicroLoanPlugin deployed at:", address(microLoanPlugin));
            }
        } else {
            microLoanPlugin = MicroLoanPlugin(existing);
            console.log("MicroLoanPlugin: Using existing at", existing);
        }

        // 3. Deploy OnRampPlugin (no external dependencies required)
        existing = _getAddress(DeploymentAddresses.KEY_ONRAMP_PLUGIN);
        if (existing == address(0)) {
            onRampPlugin = new OnRampPlugin(treasury, onRampFeeBps, orderExpiry);
            _setAddress(DeploymentAddresses.KEY_ONRAMP_PLUGIN, address(onRampPlugin));
            console.log("OnRampPlugin deployed at:", address(onRampPlugin));
        } else {
            onRampPlugin = OnRampPlugin(existing);
            console.log("OnRampPlugin: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        // Log summary
        console.log("\n=== Plugins Deployment Summary ===");
        if (address(autoSwapPlugin) != address(0)) {
            console.log("AutoSwapPlugin:", address(autoSwapPlugin));
        } else {
            console.log("AutoSwapPlugin: NOT DEPLOYED (missing dependencies)");
        }
        if (address(microLoanPlugin) != address(0)) {
            console.log("MicroLoanPlugin:", address(microLoanPlugin));
        } else {
            console.log("MicroLoanPlugin: NOT DEPLOYED (missing dependencies)");
        }
        console.log("OnRampPlugin:", address(onRampPlugin));

        console.log("\nConfiguration:");
        console.log("  PriceOracle:", priceOracle);
        console.log("  DEX Router:", dexRouter);
        console.log("  Fee Recipient:", feeRecipient);
        console.log("  Treasury:", treasury);
        console.log("  Protocol Fee:", protocolFeeBps, "bps");
        console.log("  Liquidation Bonus:", liquidationBonusBps, "bps");
        console.log("  OnRamp Fee:", onRampFeeBps, "bps");
        console.log("  Order Expiry:", orderExpiry, "seconds");

        console.log("\nNote: Plugins are installed on SmartAccounts via installModule()");
        console.log("  - AutoSwapPlugin: Use for DCA, limit orders, stop loss, take profit");
        console.log("  - MicroLoanPlugin: Use for collateralized micro-loans, credit scoring");
        console.log("  - OnRampPlugin: Use for fiat on-ramp integration, KYC management");
    }
}
