// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { PerpetualEngine } from "../../src/perpetual/PerpetualEngine.sol";
import { PositionManager } from "../../src/perpetual/core/PositionManager.sol";
import { MarginManager } from "../../src/perpetual/core/MarginManager.sol";
import { OrderManager } from "../../src/perpetual/core/OrderManager.sol";
import { Liquidator } from "../../src/perpetual/core/Liquidator.sol";
import { InsuranceFund } from "../../src/perpetual/core/InsuranceFund.sol";
import { ADLEngine } from "../../src/perpetual/core/ADLEngine.sol";
import { PerpetualTypes } from "../../src/perpetual/libraries/PerpetualTypes.sol";

/// @notice Deploys and exercises isolated-margin liquidation/ADL on local Anvil 31337.
/// @dev Uses public Anvil dev accounts 1 and 2. Refuses other clients or chain IDs.
///      The 18-decimal collateral and mark-price feed below are local-only fixtures.
contract AnvilPerpetualSmokeScript is Script {
    PerpetualEngine private _engine;
    PositionManager private _positions;
    MarginManager private _margin;
    OrderManager private _orders;
    Liquidator private _liquidator;
    InsuranceFund private _insurance;
    ADLEngine private _adl;
    AnvilPerpetualCollateral private _collateral;
    AnvilPerpetualOracle private _oracle;

    function run() external {
        require(block.chainid == 31337 && _isAnvil(), "Anvil 31337 only");
        uint256 aliceKey = vm.deriveKey("test test test test test test test test test test test junk", 1);
        uint256 bobKey = vm.deriveKey("test test test test test test test test test test test junk", 2);
        address alice = vm.addr(aliceKey);
        address bob = vm.addr(bobKey);
        address admin = msg.sender;
        vm.startBroadcast();
        _deploy(admin);
        uint32 market = _engine.createMarket("SMOKE", "COL", _config());
        _engine.setOracles(market, address(_oracle), address(_oracle));
        _oracle.setPrice(market, 100e18);
        _collateral.mint(alice, 100e18);
        _collateral.mint(bob, 100e18);
        // Only half the liquidation deficit is covered by insurance.
        _collateral.mint(admin, 50e18);
        _collateral.approve(address(_insurance), 50e18);
        _insurance.adminDeposit(50e18);
        vm.stopBroadcast();

        bytes32 longKey = _open(aliceKey, market, PerpetualTypes.PositionSide.Long);
        bytes32 shortKey = _open(bobKey, market, PerpetualTypes.PositionSide.Short);
        vm.startBroadcast();
        _oracle.setPrice(market, 80e18);
        (uint256 size, uint256 reward) = _liquidator.liquidate(longKey);
        require(size == 10e18 && reward == 0, "bankrupt liquidation");
        require(_positions.getPosition(longKey).status == PerpetualTypes.PositionStatus.Liquidated, "position status");
        require(_margin.getLockedMargin(alice) == 0, "liquidated margin remains locked");
        require(_insurance.getTotalBalance() == 0, "insurance coverage");
        require(_adl.getMarketDeficit(market) == 50e18, "uncovered debt");
        require(_collateral.balanceOf(address(_margin)) == 250e18, "insurance assets not transferred");
        // Move the live market again; the registered settlement must not inflate the payout.
        _oracle.setPrice(market, 70e18);
        (uint128 executed, uint256 count) = _adl.autoExecuteADL(longKey);
        require(executed == 10e18 && count == 1, "automatic ADL");
        require(_positions.getPosition(shortKey).status == PerpetualTypes.PositionStatus.Closed, "counterparty status");
        require(_adl.getMarketDeficit(market) == 0 && !_adl.isADLActive(market), "debt remains");
        require(_margin.getLockedMargin(bob) == 0, "ADL margin remains locked");
        require(_margin.getAvailableMargin(bob) == 250e18, "ADL payout");
        require(_positions.getOpenInterest(market, PerpetualTypes.PositionSide.Long) == 0, "long open interest");
        require(_positions.getOpenInterest(market, PerpetualTypes.PositionSide.Short) == 0, "short open interest");
        vm.stopBroadcast();
        vm.startBroadcast(bobKey);
        _engine.withdrawMargin(250e18);
        vm.stopBroadcast();
        require(_collateral.balanceOf(bob) == 250e18, "withdrawal not backed by assets");
        require(_collateral.balanceOf(address(_margin)) == 0, "margin assets remain");
        require(_margin.getAvailableMargin(bob) == 0, "margin liability remains");
        _save(market, alice, bob, longKey, shortKey);
        console.log("engine:", address(_engine));
        console.log("PERPETUAL SMOKE OK");
    }

    function _deploy(address admin) internal {
        _collateral = new AnvilPerpetualCollateral(admin);
        _oracle = new AnvilPerpetualOracle(admin);
        _engine = new PerpetualEngine(admin, address(_collateral));
        _positions = new PositionManager(admin);
        _margin = new MarginManager(admin, address(_collateral));
        _orders = new OrderManager(admin);
        _liquidator = new Liquidator(admin, address(_collateral));
        _insurance = new InsuranceFund(admin, address(_collateral), 1000e18);
        _adl = new ADLEngine(admin);
        _positions.setEngine(address(_engine));
        _margin.setEngine(address(_engine));
        _orders.setEngine(address(_engine));
        _positions.setLiquidator(address(_liquidator));
        _positions.setADLEngine(address(_adl));
        _margin.setLiquidator(address(_liquidator));
        _margin.setADLEngine(address(_adl));
        _liquidator.setPositionManager(address(_positions));
        _liquidator.setMarginManager(address(_margin));
        _liquidator.setInsuranceFund(address(_insurance));
        _liquidator.setADLEngine(address(_adl));
        _adl.setPositionManager(address(_positions));
        _adl.setMarginManager(address(_margin));
        _adl.setInsuranceFund(address(_insurance));
        _adl.setLiquidator(address(_liquidator));
        _insurance.setLiquidator(address(_liquidator));
        _engine.setComponents(
            address(_positions),
            address(_margin),
            address(_orders),
            address(_liquidator),
            address(_insurance),
            address(_adl)
        );
    }

    function _open(uint256 key, uint32 market, PerpetualTypes.PositionSide side)
        internal
        returns (bytes32 positionKey)
    {
        vm.startBroadcast(key);
        _collateral.approve(address(_engine), 100e18);
        _engine.depositMargin(100e18);
        uint128 price;
        (positionKey, price) = _engine.openMarketPosition(market, side, 10e18, 100);
        require(price == 100e18, "entry price");
        vm.stopBroadcast();
    }

    function _config() internal pure returns (PerpetualTypes.MarketConfig memory config) {
        config.maxLeverage = 100;
        config.maintenanceMarginBps = 500;
        config.initialMarginBps = 1000;
        config.liquidationFeeBps = 100;
        config.maxPositionSize = 1000e18;
        config.maxOpenInterest = 10000e18;
    }

    function _save(uint32 market, address alice, address bob, bytes32 longKey, bytes32 shortKey) internal {
        string memory object = "perpetualSmoke";
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeUint(object, "marketId", market);
        vm.serializeAddress(object, "engine", address(_engine));
        vm.serializeAddress(object, "positionManager", address(_positions));
        vm.serializeAddress(object, "marginManager", address(_margin));
        vm.serializeAddress(object, "orderManager", address(_orders));
        vm.serializeAddress(object, "liquidator", address(_liquidator));
        vm.serializeAddress(object, "insuranceFund", address(_insurance));
        vm.serializeAddress(object, "adlEngine", address(_adl));
        vm.serializeAddress(object, "collateral", address(_collateral));
        vm.serializeAddress(object, "oracle", address(_oracle));
        vm.serializeAddress(object, "alice", alice);
        vm.serializeAddress(object, "bob", bob);
        vm.serializeBytes32(object, "longPositionKey", longKey);
        string memory json = vm.serializeBytes32(object, "shortPositionKey", shortKey);
        vm.writeJson(json, "deployments/31337/perpetual-smoke.json");
    }

    function _isAnvil() internal returns (bool) {
        bytes memory version = vm.rpc("web3_clientVersion", "[]");
        if (version.length >= 64 && uint256(bytes32(version)) == 0x20) version = bytes(abi.decode(version, (string)));
        bytes memory prefix = bytes("anvil/");
        if (version.length < prefix.length) return false;
        for (uint256 i = 0; i < prefix.length; i++) {
            if (version[i] != prefix[i]) return false;
        }
        return true;
    }
}

/// @dev Local-only, 18-decimal collateral fixture. Never use for real assets.
contract AnvilPerpetualCollateral is ERC20 {
    address private immutable _admin;

    constructor(address admin) ERC20("Anvil Perpetual Collateral", "APCOL") {
        require(block.chainid == 31337, "local fixture only");
        _admin = admin;
    }

    function mint(address recipient, uint256 amount) external {
        require(msg.sender == _admin, "admin only");
        _mint(recipient, amount);
    }
}

contract AnvilPerpetualOracle {
    address private immutable _admin;
    mapping(uint32 => PerpetualTypes.MarkPriceData) private _prices;

    constructor(address admin) {
        require(block.chainid == 31337, "local fixture only");
        _admin = admin;
    }

    function setPrice(uint32 market, uint128 price) external {
        require(msg.sender == _admin, "admin only");
        _prices[market] = PerpetualTypes.MarkPriceData(price, price, 0, 0, uint64(block.timestamp));
    }

    function getMarkPriceData(uint32 market) external view returns (PerpetualTypes.MarkPriceData memory) {
        return _prices[market];
    }
}
