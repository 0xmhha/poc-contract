// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AutoSwapPlugin} from "../../src/erc7579-plugins/AutoSwapPlugin.sol";
import {IPriceOracle} from "../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";
import {MODULE_TYPE_EXECUTOR} from "../../src/erc7579-smartaccount/types/Constants.sol";

contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view override returns (uint256) {
        return prices[token];
    }

    function getPriceWithTimestamp(address token) external view override returns (uint256 price, uint256 timestamp) {
        return (prices[token], block.timestamp);
    }

    function hasValidPrice(address token) external view override returns (bool) {
        return prices[token] > 0;
    }
}

contract AutoSwapPluginTest is Test {
    AutoSwapPlugin public plugin;
    MockPriceOracle public oracle;

    address public dexRouter;
    address public smartAccount;
    address public tokenIn;
    address public tokenOut;

    event OrderCreated(
        address indexed account,
        uint256 indexed orderId,
        AutoSwapPlugin.OrderType orderType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    );
    event OrderCancelled(address indexed account, uint256 indexed orderId);
    event TrailingStopUpdated(address indexed account, uint256 indexed orderId, uint256 newPeakPrice);

    function setUp() public {
        oracle = new MockPriceOracle();
        dexRouter = makeAddr("dexRouter");
        smartAccount = makeAddr("smartAccount");
        tokenIn = makeAddr("tokenIn");
        tokenOut = makeAddr("tokenOut");

        plugin = new AutoSwapPlugin(oracle, dexRouter);

        // Set up prices (1 tokenIn = 2 tokenOut)
        oracle.setPrice(tokenIn, 2e18);
        oracle.setPrice(tokenOut, 1e18);
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertEq(address(plugin.ORACLE()), address(oracle));
        assertEq(plugin.DEX_ROUTER(), dexRouter);
        assertEq(plugin.BASIS_POINTS(), 10000);
        assertEq(plugin.PRICE_PRECISION(), 1e18);
    }

    // ============ IModule Tests ============

    function test_IsModuleType_Executor() public view {
        assertTrue(plugin.isModuleType(MODULE_TYPE_EXECUTOR));
        assertFalse(plugin.isModuleType(1)); // Not validator
        assertFalse(plugin.isModuleType(3)); // Not fallback
    }

    function test_IsInitialized_ReturnsFalseInitially() public view {
        assertFalse(plugin.isInitialized(smartAccount));
    }

    function test_OnInstall_Succeeds() public {
        vm.prank(smartAccount);
        plugin.onInstall("");
        // No revert means success
    }

    function test_OnUninstall_CancelsAllOrders() public {
        vm.startPrank(smartAccount);

        // Create some orders
        plugin.createDcaOrder(tokenIn, tokenOut, 1 ether, 1 hours, 10, 0);
        plugin.createDcaOrder(tokenIn, tokenOut, 2 ether, 2 hours, 5, 0);

        uint256[] memory activeOrders = plugin.getActiveOrders(smartAccount);
        assertEq(activeOrders.length, 2);

        // Uninstall should cancel all
        plugin.onUninstall("");

        activeOrders = plugin.getActiveOrders(smartAccount);
        assertEq(activeOrders.length, 0);

        vm.stopPrank();
    }

    // ============ DCA Order Tests ============

    function test_CreateDcaOrder_Success() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createDcaOrder(
            tokenIn,
            tokenOut,
            1 ether,      // amountPerExecution
            1 hours,      // interval
            10,           // executionCount
            0             // no expiry
        );

        assertEq(orderId, 0);

        AutoSwapPlugin.Order memory order = plugin.getOrder(smartAccount, orderId);
        assertEq(uint8(order.orderType), uint8(AutoSwapPlugin.OrderType.DCA));
        assertEq(uint8(order.status), uint8(AutoSwapPlugin.OrderStatus.ACTIVE));
        assertEq(order.tokenIn, tokenIn);
        assertEq(order.tokenOut, tokenOut);
        assertEq(order.amountIn, 1 ether);
        assertEq(order.interval, 1 hours);
        assertEq(order.executionsRemaining, 10);
    }

    function test_CreateDcaOrder_EmitsEvent() public {
        vm.prank(smartAccount);
        vm.expectEmit(true, true, false, true);
        emit OrderCreated(smartAccount, 0, AutoSwapPlugin.OrderType.DCA, tokenIn, tokenOut, 1 ether);
        plugin.createDcaOrder(tokenIn, tokenOut, 1 ether, 1 hours, 10, 0);
    }

    function test_CreateDcaOrder_RevertsOnZeroAmount() public {
        vm.prank(smartAccount);
        vm.expectRevert(AutoSwapPlugin.InvalidAmount.selector);
        plugin.createDcaOrder(tokenIn, tokenOut, 0, 1 hours, 10, 0);
    }

    function test_CreateDcaOrder_RevertsOnZeroInterval() public {
        vm.prank(smartAccount);
        vm.expectRevert(AutoSwapPlugin.InvalidInterval.selector);
        plugin.createDcaOrder(tokenIn, tokenOut, 1 ether, 0, 10, 0);
    }

    // ============ Limit Buy Order Tests ============

    function test_CreateLimitBuyOrder_Success() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createLimitBuyOrder(
            tokenIn,
            tokenOut,
            100 ether,    // amountIn
            1.5e18,       // targetPrice
            90 ether,     // amountOutMin
            block.timestamp + 1 days
        );

        AutoSwapPlugin.Order memory order = plugin.getOrder(smartAccount, orderId);
        assertEq(uint8(order.orderType), uint8(AutoSwapPlugin.OrderType.LIMIT_BUY));
        assertEq(order.targetPrice, 1.5e18);
        assertEq(order.amountOutMin, 90 ether);
    }

    function test_CreateLimitBuyOrder_RevertsOnZeroAmount() public {
        vm.prank(smartAccount);
        vm.expectRevert(AutoSwapPlugin.InvalidAmount.selector);
        plugin.createLimitBuyOrder(tokenIn, tokenOut, 0, 1.5e18, 0, 0);
    }

    function test_CreateLimitBuyOrder_RevertsOnZeroPrice() public {
        vm.prank(smartAccount);
        vm.expectRevert(AutoSwapPlugin.InvalidPrice.selector);
        plugin.createLimitBuyOrder(tokenIn, tokenOut, 100 ether, 0, 0, 0);
    }

    // ============ Limit Sell Order Tests ============

    function test_CreateLimitSellOrder_Success() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createLimitSellOrder(
            tokenIn,
            tokenOut,
            50 ether,
            3e18,         // targetPrice (sell when price >= 3)
            140 ether,    // amountOutMin
            0
        );

        AutoSwapPlugin.Order memory order = plugin.getOrder(smartAccount, orderId);
        assertEq(uint8(order.orderType), uint8(AutoSwapPlugin.OrderType.LIMIT_SELL));
        assertEq(order.targetPrice, 3e18);
    }

    function test_CreateLimitSellOrder_RevertsOnZeroAmount() public {
        vm.prank(smartAccount);
        vm.expectRevert(AutoSwapPlugin.InvalidAmount.selector);
        plugin.createLimitSellOrder(tokenIn, tokenOut, 0, 3e18, 0, 0);
    }

    function test_CreateLimitSellOrder_RevertsOnZeroPrice() public {
        vm.prank(smartAccount);
        vm.expectRevert(AutoSwapPlugin.InvalidPrice.selector);
        plugin.createLimitSellOrder(tokenIn, tokenOut, 50 ether, 0, 0, 0);
    }

    // ============ Stop Loss Order Tests ============

    function test_CreateStopLossOrder_Success() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createStopLossOrder(
            tokenIn,
            tokenOut,
            100 ether,
            1.5e18,       // triggerPrice (sell if price <= 1.5)
            140 ether,    // amountOutMin
            0
        );

        AutoSwapPlugin.Order memory order = plugin.getOrder(smartAccount, orderId);
        assertEq(uint8(order.orderType), uint8(AutoSwapPlugin.OrderType.STOP_LOSS));
        assertEq(order.targetPrice, 1.5e18);
    }

    function test_CreateStopLossOrder_RevertsOnZeroAmount() public {
        vm.prank(smartAccount);
        vm.expectRevert(AutoSwapPlugin.InvalidAmount.selector);
        plugin.createStopLossOrder(tokenIn, tokenOut, 0, 1.5e18, 0, 0);
    }

    function test_CreateStopLossOrder_RevertsOnZeroPrice() public {
        vm.prank(smartAccount);
        vm.expectRevert(AutoSwapPlugin.InvalidPrice.selector);
        plugin.createStopLossOrder(tokenIn, tokenOut, 100 ether, 0, 0, 0);
    }

    // ============ Take Profit Order Tests ============

    function test_CreateTakeProfitOrder_Success() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createTakeProfitOrder(
            tokenIn,
            tokenOut,
            100 ether,
            4e18,         // targetPrice (sell when price >= 4)
            380 ether,
            0
        );

        AutoSwapPlugin.Order memory order = plugin.getOrder(smartAccount, orderId);
        assertEq(uint8(order.orderType), uint8(AutoSwapPlugin.OrderType.TAKE_PROFIT));
        assertEq(order.targetPrice, 4e18);
    }

    function test_CreateTakeProfitOrder_RevertsOnZeroAmount() public {
        vm.prank(smartAccount);
        vm.expectRevert(AutoSwapPlugin.InvalidAmount.selector);
        plugin.createTakeProfitOrder(tokenIn, tokenOut, 0, 4e18, 0, 0);
    }

    function test_CreateTakeProfitOrder_RevertsOnZeroPrice() public {
        vm.prank(smartAccount);
        vm.expectRevert(AutoSwapPlugin.InvalidPrice.selector);
        plugin.createTakeProfitOrder(tokenIn, tokenOut, 100 ether, 0, 0, 0);
    }

    // ============ Trailing Stop Order Tests ============

    function test_CreateTrailingStopOrder_Success() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createTrailingStopOrder(
            tokenIn,
            tokenOut,
            100 ether,
            500,          // 5% trailing
            0,
            0
        );

        AutoSwapPlugin.Order memory order = plugin.getOrder(smartAccount, orderId);
        assertEq(uint8(order.orderType), uint8(AutoSwapPlugin.OrderType.TRAILING_STOP));
        assertEq(order.trailingPercent, 500);
        assertEq(order.peakPrice, 2e18); // Current price
    }

    function test_CreateTrailingStopOrder_RevertsOnZeroAmount() public {
        vm.prank(smartAccount);
        vm.expectRevert(AutoSwapPlugin.InvalidAmount.selector);
        plugin.createTrailingStopOrder(tokenIn, tokenOut, 0, 500, 0, 0);
    }

    function test_CreateTrailingStopOrder_RevertsOnZeroPercent() public {
        vm.prank(smartAccount);
        vm.expectRevert(AutoSwapPlugin.InvalidPrice.selector);
        plugin.createTrailingStopOrder(tokenIn, tokenOut, 100 ether, 0, 0, 0);
    }

    function test_CreateTrailingStopOrder_RevertsOnPercentTooHigh() public {
        vm.prank(smartAccount);
        vm.expectRevert(AutoSwapPlugin.InvalidPrice.selector);
        plugin.createTrailingStopOrder(tokenIn, tokenOut, 100 ether, 10000, 0, 0); // 100%
    }

    // ============ Cancel Order Tests ============

    function test_CancelOrder_Success() public {
        vm.startPrank(smartAccount);
        uint256 orderId = plugin.createDcaOrder(tokenIn, tokenOut, 1 ether, 1 hours, 10, 0);

        vm.expectEmit(true, true, false, false);
        emit OrderCancelled(smartAccount, orderId);
        plugin.cancelOrder(orderId);

        AutoSwapPlugin.Order memory order = plugin.getOrder(smartAccount, orderId);
        assertEq(uint8(order.status), uint8(AutoSwapPlugin.OrderStatus.CANCELLED));
        vm.stopPrank();
    }

    function test_CancelOrder_RevertsOnNotActive() public {
        vm.startPrank(smartAccount);
        uint256 orderId = plugin.createDcaOrder(tokenIn, tokenOut, 1 ether, 1 hours, 10, 0);
        plugin.cancelOrder(orderId);

        vm.expectRevert(AutoSwapPlugin.OrderNotActive.selector);
        plugin.cancelOrder(orderId);
        vm.stopPrank();
    }

    // ============ Update Trailing Stop Tests ============

    function test_UpdateTrailingStop_Success() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createTrailingStopOrder(tokenIn, tokenOut, 100 ether, 500, 0, 0);

        // Price increases
        oracle.setPrice(tokenIn, 3e18);

        vm.expectEmit(true, true, false, true);
        emit TrailingStopUpdated(smartAccount, orderId, 3e18);
        plugin.updateTrailingStop(smartAccount, orderId);

        AutoSwapPlugin.Order memory order = plugin.getOrder(smartAccount, orderId);
        assertEq(order.peakPrice, 3e18);
    }

    function test_UpdateTrailingStop_NoUpdateIfPriceLower() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createTrailingStopOrder(tokenIn, tokenOut, 100 ether, 500, 0, 0);

        // Price decreases
        oracle.setPrice(tokenIn, 1.5e18);

        plugin.updateTrailingStop(smartAccount, orderId);

        AutoSwapPlugin.Order memory order = plugin.getOrder(smartAccount, orderId);
        assertEq(order.peakPrice, 2e18); // Still original
    }

    function test_UpdateTrailingStop_RevertsOnNotActive() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createTrailingStopOrder(tokenIn, tokenOut, 100 ether, 500, 0, 0);

        vm.prank(smartAccount);
        plugin.cancelOrder(orderId);

        vm.expectRevert(AutoSwapPlugin.OrderNotActive.selector);
        plugin.updateTrailingStop(smartAccount, orderId);
    }

    function test_UpdateTrailingStop_RevertsOnWrongOrderType() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createDcaOrder(tokenIn, tokenOut, 1 ether, 1 hours, 10, 0);

        vm.expectRevert(AutoSwapPlugin.InvalidOrderType.selector);
        plugin.updateTrailingStop(smartAccount, orderId);
    }

    // ============ View Function Tests ============

    function test_GetActiveOrders() public {
        vm.startPrank(smartAccount);
        plugin.createDcaOrder(tokenIn, tokenOut, 1 ether, 1 hours, 10, 0);
        plugin.createLimitBuyOrder(tokenIn, tokenOut, 100 ether, 1.5e18, 0, 0);
        plugin.createStopLossOrder(tokenIn, tokenOut, 50 ether, 1e18, 0, 0);
        vm.stopPrank();

        uint256[] memory activeOrders = plugin.getActiveOrders(smartAccount);
        assertEq(activeOrders.length, 3);
    }

    function test_IsTriggered_DCA_FirstExecution() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createDcaOrder(tokenIn, tokenOut, 1 ether, 1 hours, 10, 0);

        // First execution should be triggered immediately
        assertTrue(plugin.isTriggered(smartAccount, orderId));
    }

    function test_IsTriggered_LimitBuy() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createLimitBuyOrder(tokenIn, tokenOut, 100 ether, 1.5e18, 0, 0);

        // Current price is 2, target is 1.5 - not triggered
        assertFalse(plugin.isTriggered(smartAccount, orderId));

        // Price drops to 1.5
        oracle.setPrice(tokenIn, 1.5e18);
        assertTrue(plugin.isTriggered(smartAccount, orderId));
    }

    function test_IsTriggered_LimitSell() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createLimitSellOrder(tokenIn, tokenOut, 100 ether, 3e18, 0, 0);

        // Current price is 2, target is 3 - not triggered
        assertFalse(plugin.isTriggered(smartAccount, orderId));

        // Price rises to 3
        oracle.setPrice(tokenIn, 3e18);
        assertTrue(plugin.isTriggered(smartAccount, orderId));
    }

    function test_IsTriggered_StopLoss() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createStopLossOrder(tokenIn, tokenOut, 100 ether, 1.5e18, 0, 0);

        // Current price is 2, trigger is 1.5 - not triggered
        assertFalse(plugin.isTriggered(smartAccount, orderId));

        // Price drops to 1.5
        oracle.setPrice(tokenIn, 1.5e18);
        assertTrue(plugin.isTriggered(smartAccount, orderId));
    }

    function test_IsTriggered_TakeProfit() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createTakeProfitOrder(tokenIn, tokenOut, 100 ether, 3e18, 0, 0);

        // Current price is 2, target is 3 - not triggered
        assertFalse(plugin.isTriggered(smartAccount, orderId));

        // Price rises to 3
        oracle.setPrice(tokenIn, 3e18);
        assertTrue(plugin.isTriggered(smartAccount, orderId));
    }

    function test_IsTriggered_TrailingStop() public {
        vm.prank(smartAccount);
        uint256 orderId = plugin.createTrailingStopOrder(tokenIn, tokenOut, 100 ether, 1000, 0, 0); // 10%

        // Current price is 2, peak is 2, trigger at 1.8 (10% below) - not triggered
        assertFalse(plugin.isTriggered(smartAccount, orderId));

        // Price drops to 1.8
        oracle.setPrice(tokenIn, 1.8e18);
        assertTrue(plugin.isTriggered(smartAccount, orderId));
    }

    function test_IsTriggered_ReturnsFalseForCancelled() public {
        vm.startPrank(smartAccount);
        uint256 orderId = plugin.createDcaOrder(tokenIn, tokenOut, 1 ether, 1 hours, 10, 0);
        plugin.cancelOrder(orderId);
        vm.stopPrank();

        assertFalse(plugin.isTriggered(smartAccount, orderId));
    }

    function test_GetCurrentPrice() public view {
        uint256 price = plugin.getCurrentPrice(tokenIn, tokenOut);
        // tokenIn price = 2e18, tokenOut price = 1e18
        // price = (2e18 * 1e18) / 1e18 = 2e18
        assertEq(price, 2e18);
    }

    // ============ Multiple Orders Tests ============

    function test_MultipleOrdersTracking() public {
        vm.startPrank(smartAccount);

        uint256 orderId1 = plugin.createDcaOrder(tokenIn, tokenOut, 1 ether, 1 hours, 10, 0);
        uint256 orderId2 = plugin.createLimitBuyOrder(tokenIn, tokenOut, 100 ether, 1.5e18, 0, 0);
        uint256 orderId3 = plugin.createStopLossOrder(tokenIn, tokenOut, 50 ether, 1e18, 0, 0);

        assertEq(orderId1, 0);
        assertEq(orderId2, 1);
        assertEq(orderId3, 2);

        uint256[] memory activeOrders = plugin.getActiveOrders(smartAccount);
        assertEq(activeOrders.length, 3);

        // Cancel one
        plugin.cancelOrder(orderId2);

        activeOrders = plugin.getActiveOrders(smartAccount);
        assertEq(activeOrders.length, 2);

        vm.stopPrank();
    }

    function test_IsInitialized_AfterOrderCreation() public {
        assertFalse(plugin.isInitialized(smartAccount));

        vm.prank(smartAccount);
        plugin.createDcaOrder(tokenIn, tokenOut, 1 ether, 1 hours, 10, 0);

        assertTrue(plugin.isInitialized(smartAccount));
    }
}
