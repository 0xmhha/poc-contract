// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "../utils/DeploymentAddresses.sol";
import { FixedPriceAggregator } from "../../src/defi/FixedPriceAggregator.sol";

// Minimal interfaces (avoid importing full contracts)
interface IPriceOracleAdmin {
    function setChainlinkFeed(address token, address feed) external;
    function hasPriceFeed(address token) external view returns (bool);
    function getPrice(address token) external view returns (uint256);
    function owner() external view returns (address);
}

interface IERC20PaymasterAdmin {
    function setSupportedToken(address token, bool supported) external;
    function isTokenSupported(address token) external view returns (bool);
    function owner() external view returns (address);
    function getTokenAmount(address token, uint256 ethCost) external view returns (uint256);
}

/**
 * @title SetupOraclePriceScript
 * @notice Sets up a fixed USDC/KRWC price on the PriceOracle for PoC/testnet use.
 *
 * Deploys a FixedPriceAggregator and registers it as a Chainlink feed
 * for USDC on the existing PriceOracle contract.
 * Also ensures USDC is registered as a supported token on the ERC20Paymaster.
 *
 * Reads deployed addresses from deployments/<chainId>/addresses.json automatically.
 *
 * Usage:
 *   forge script script/deploy-contract/SetupOraclePrice.s.sol:SetupOraclePriceScript \
 *     --rpc-url $RPC_URL --broadcast -vvv
 *
 * Environment:
 *   PRIVATE_KEY_DEPLOYER  - Deployer private key (must be PriceOracle & ERC20Paymaster owner)
 *   USDC_KRWC_PRICE       - Price in KRWC per USDC (defaults to 1500)
 */
contract SetupOraclePriceScript is DeploymentHelper {
    // Chainlink standard decimals
    uint8 constant CHAINLINK_DECIMALS = 8;

    function run() external {
        _initDeployment();

        address usdc = _getAddress(DeploymentAddresses.KEY_USDC);
        address oracleAddr = _getAddress(DeploymentAddresses.KEY_PRICE_ORACLE);
        address paymasterAddr = _getAddress(DeploymentAddresses.KEY_ERC20_PAYMASTER);

        require(usdc != address(0), "USDC address not found in addresses.json");
        require(oracleAddr != address(0), "PriceOracle address not found in addresses.json");
        require(paymasterAddr != address(0), "ERC20Paymaster address not found in addresses.json");

        uint256 usdcKrcPrice = vm.envOr("USDC_KRWC_PRICE", uint256(1500));

        IPriceOracleAdmin oracle = IPriceOracleAdmin(oracleAddr);
        IERC20PaymasterAdmin paymaster = IERC20PaymasterAdmin(paymasterAddr);

        console.log("=== Setup Oracle Price ===");
        console.log("USDC:", usdc);
        console.log("PriceOracle:", oracleAddr);
        console.log("ERC20Paymaster:", paymasterAddr);
        console.log("Price: 1 USDC =", usdcKrcPrice, "KRWC");

        // Calculate Chainlink answer: price * 10^decimals
        // e.g., 1500 * 1e8 = 150_000_000_000
        int256 chainlinkAnswer = int256(usdcKrcPrice * (10 ** CHAINLINK_DECIMALS));
        console.log("Chainlink answer (8 decimals):", uint256(chainlinkAnswer));

        vm.startBroadcast();

        // Step 1: Deploy FixedPriceAggregator
        FixedPriceAggregator aggregator = new FixedPriceAggregator(chainlinkAnswer, CHAINLINK_DECIMALS);
        console.log("FixedPriceAggregator deployed at:", address(aggregator));

        // Step 2: Register as Chainlink feed on PriceOracle
        console.log("Setting Chainlink feed on PriceOracle...");
        oracle.setChainlinkFeed(usdc, address(aggregator));

        // Step 3: Ensure USDC is a supported token on ERC20Paymaster
        bool alreadySupported = paymaster.isTokenSupported(usdc);
        if (!alreadySupported) {
            console.log("Adding USDC as supported token on ERC20Paymaster...");
            paymaster.setSupportedToken(usdc, true);
        } else {
            console.log("USDC already supported on ERC20Paymaster");
        }

        vm.stopBroadcast();

        // Verify
        console.log("\n=== Verification ===");

        bool hasFeed = oracle.hasPriceFeed(usdc);
        console.log("Oracle has price feed for USDC:", hasFeed);

        if (hasFeed) {
            uint256 price = oracle.getPrice(usdc);
            console.log("Oracle price (18 decimals):", price);
            // Expected: 1500 * 1e18 = 1500000000000000000000

            // Test getTokenAmount: 1 KRWC (1e18 wei) should cost ~0.000667 USDC
            uint256 tokenAmount = paymaster.getTokenAmount(usdc, 1 ether);
            console.log("1 KRWC gas cost in USDC units:", tokenAmount);
            // Expected: ~733 (0.000733 USDC with 10% markup)
        }

        bool supported = paymaster.isTokenSupported(usdc);
        console.log("ERC20Paymaster supports USDC:", supported);

        console.log("\n=== Setup Complete ===");
    }
}
