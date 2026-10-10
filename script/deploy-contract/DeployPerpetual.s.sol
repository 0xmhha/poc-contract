// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// forge-lint: disable-next-line(unused-import)
import { Script, console } from "forge-std/Script.sol";
import { DeploymentHelper, DeploymentAddresses } from "../utils/DeploymentAddresses.sol";
import { PerpetualEngine } from "../../src/perpetual/PerpetualEngine.sol";
import { OrderManager } from "../../src/perpetual/core/OrderManager.sol";
import { PositionManager } from "../../src/perpetual/core/PositionManager.sol";
import { MarginManager } from "../../src/perpetual/core/MarginManager.sol";

/**
 * @title DeployPerpetualScript
 * @notice Deploys the perpetual order book used as indexer-go's perp_orderbook venue
 * @dev TESTNET ONLY. Prices are placeholders and liquidation is not implemented.
 *      Not part of DeployAll on purpose.
 *
 * Deployed Contracts:
 *   - PerpetualEngine: market registry (emits MarketCreated)
 *   - OrderManager: order book (emits Order* / OrdersMatched events)
 *   - PositionManager, MarginManager: engine components
 *
 * Environment Variables:
 *   - PERP_COLLATERAL: collateral token (default: deployed USDC)
 *
 * The broadcaster becomes admin of every component so it can wire them.
 *
 * Usage:
 *   forge script script/deploy-contract/DeployPerpetual.s.sol:DeployPerpetualScript --rpc-url <RPC_URL> --broadcast
 */
contract DeployPerpetualScript is DeploymentHelper {
    PerpetualEngine public engine;
    OrderManager public orderManager;
    PositionManager public positionManager;
    MarginManager public marginManager;

    function setUp() public { }

    function run() public {
        _initDeployment();

        address collateral = vm.envOr("PERP_COLLATERAL", _addresses[DeploymentAddresses.KEY_USDC]);
        require(collateral != address(0), "DeployPerpetual: set PERP_COLLATERAL or deploy USDC first");

        console.log("=== Deploying Perpetual (testnet only) ===");
        console.log("Collateral:", collateral);

        vm.startBroadcast();
        address admin = msg.sender;

        address existing = _getAddress(DeploymentAddresses.KEY_PERP_ENGINE);
        if (existing == address(0)) {
            engine = new PerpetualEngine(admin, collateral);
            orderManager = new OrderManager(admin);
            positionManager = new PositionManager(admin);
            marginManager = new MarginManager(admin, collateral);

            // Liquidator, InsuranceFund and ADLEngine are not deployed: their logic is placeholder.
            engine.setComponents(
                address(positionManager),
                address(marginManager),
                address(orderManager),
                address(0),
                address(0),
                address(0)
            );
            orderManager.setEngine(address(engine));
            positionManager.setEngine(address(engine));
            marginManager.setEngine(address(engine));

            _setAddress(DeploymentAddresses.KEY_PERP_ENGINE, address(engine));
            _setAddress(DeploymentAddresses.KEY_PERP_ORDER_MANAGER, address(orderManager));
            _setAddress(DeploymentAddresses.KEY_PERP_POSITION_MANAGER, address(positionManager));
            _setAddress(DeploymentAddresses.KEY_PERP_MARGIN_MANAGER, address(marginManager));
        } else {
            console.log("PerpetualEngine: Using existing at", existing);
        }

        vm.stopBroadcast();

        _saveAddresses();

        console.log("\n=== Perpetual Deployment Summary ===");
        console.log("PerpetualEngine:", _addresses[DeploymentAddresses.KEY_PERP_ENGINE]);
        console.log("OrderManager:", _addresses[DeploymentAddresses.KEY_PERP_ORDER_MANAGER]);
        console.log("\nindexer-go venue config (features.dex.pools.venues):");
        console.log("  type: perp_orderbook, engine: <PerpetualEngine>, order_manager: <OrderManager>");
    }
}
