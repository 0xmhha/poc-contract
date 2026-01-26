// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IExecutor } from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { IERC7579Account } from "../erc7579-smartaccount/interfaces/IERC7579Account.sol";
import { MODULE_TYPE_EXECUTOR } from "../erc7579-smartaccount/types/Constants.sol";
import { ExecMode } from "../erc7579-smartaccount/types/Types.sol";
import { IPriceOracle } from "../erc4337-paymaster/interfaces/IPriceOracle.sol";

/**
 * @title AutoSwapPlugin
 * @notice ERC-7579 Plugin for automated token swaps
 * @dev Enables smart accounts to set up automated trading strategies
 *
 * Features:
 * - Dollar Cost Averaging (DCA): Regular purchases at intervals
 * - Limit Orders: Execute swap when price reaches target
 * - Stop Loss: Sell tokens when price drops below threshold
 * - Take Profit: Sell tokens when price reaches profit target
 * - Trailing Stop: Dynamic stop loss that follows price up
 *
 * Use Cases:
 * - Automated investment strategies
 * - Risk management with stop losses
 * - Profit taking automation
 * - Portfolio rebalancing
 *
 * DEX Integration:
 * - Uses DEXIntegration contract for actual swaps
 * - Supports Uniswap V3 style swaps
 */
contract AutoSwapPlugin is IExecutor {
    /// @notice Order types
    enum OrderType {
        DCA, // 0: Dollar Cost Averaging
        LIMIT_BUY, // 1: Buy when price drops to target
        LIMIT_SELL, // 2: Sell when price rises to target
        STOP_LOSS, // 3: Sell when price drops below threshold
        TAKE_PROFIT, // 4: Sell when price reaches profit target
        TRAILING_STOP // 5: Dynamic stop loss
    }

    /// @notice Order status
    enum OrderStatus {
        ACTIVE,
        EXECUTED,
        CANCELLED,
        EXPIRED
    }

    /// @notice Order configuration
    struct Order {
        OrderType orderType;
        OrderStatus status;
        address tokenIn;
        address tokenOut;
        uint256 amountIn; // Amount per execution (for DCA) or total (for others)
        uint256 amountOutMin; // Minimum output (slippage protection)
        uint256 targetPrice; // Price trigger (in tokenOut per tokenIn, 18 decimals)
        uint256 interval; // For DCA: time between executions
        uint256 lastExecutionTime;
        uint256 executionsRemaining; // For DCA: remaining executions (0 = unlimited)
        uint256 expiry; // Order expiration timestamp (0 = no expiry)
        uint256 trailingPercent; // For trailing stop: percentage below peak (basis points)
        uint256 peakPrice; // For trailing stop: highest observed price
    }

    /// @notice Account storage
    struct AccountStorage {
        mapping(uint256 => Order) orders;
        uint256[] activeOrderIds;
        uint256 nextOrderId;
    }

    /// @notice Price oracle
    IPriceOracle public immutable ORACLE;

    /// @notice DEX router for swaps
    address public immutable DEX_ROUTER;

    /// @notice Account storage
    mapping(address => AccountStorage) internal accountStorage;

    /// @notice Basis points
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Price precision
    uint256 public constant PRICE_PRECISION = 1e18;

    // Events
    event OrderCreated(
        address indexed account,
        uint256 indexed orderId,
        OrderType orderType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    );
    event OrderExecuted(
        address indexed account, uint256 indexed orderId, uint256 amountIn, uint256 amountOut, uint256 price
    );
    event OrderCancelled(address indexed account, uint256 indexed orderId);
    event OrderExpired(address indexed account, uint256 indexed orderId);
    event TrailingStopUpdated(address indexed account, uint256 indexed orderId, uint256 newPeakPrice);

    // Errors
    error OrderNotActive();
    error OrderNotTriggered();
    error OrderHasExpired();
    error InvalidOrderType();
    error InvalidAmount();
    error InvalidPrice();
    error InvalidInterval();
    error ExecutionFailed();
    error SlippageExceeded();

    /**
     * @notice Constructor
     * @param _oracle Price oracle address
     * @param _dexRouter DEX router address
     */
    constructor(IPriceOracle _oracle, address _dexRouter) {
        ORACLE = _oracle;
        DEX_ROUTER = _dexRouter;
    }

    // ============ IModule Implementation ============

    function onInstall(bytes calldata) external payable override {
        // No initialization needed
    }

    function onUninstall(bytes calldata) external payable override {
        AccountStorage storage store = accountStorage[msg.sender];

        // Cancel all active orders
        for (uint256 i = 0; i < store.activeOrderIds.length; i++) {
            store.orders[store.activeOrderIds[i]].status = OrderStatus.CANCELLED;
        }
        delete store.activeOrderIds;
    }

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    function isInitialized(address smartAccount) external view override returns (bool) {
        return accountStorage[smartAccount].nextOrderId > 0;
    }

    // ============ Order Creation ============

    /**
     * @notice Create a DCA (Dollar Cost Averaging) order
     * @param tokenIn Token to sell
     * @param tokenOut Token to buy
     * @param amountPerExecution Amount to swap each time
     * @param interval Time between executions
     * @param executionCount Total number of executions (0 = unlimited)
     * @param expiry Order expiration (0 = no expiry)
     */
    function createDcaOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountPerExecution,
        uint256 interval,
        uint256 executionCount,
        uint256 expiry
    ) external returns (uint256 orderId) {
        if (amountPerExecution == 0) revert InvalidAmount();
        if (interval == 0) revert InvalidInterval();

        return _createOrder(
            msg.sender,
            OrderType.DCA,
            tokenIn,
            tokenOut,
            amountPerExecution,
            0, // No minimum output for DCA
            0, // No target price
            interval,
            executionCount,
            expiry,
            0 // No trailing percent
        );
    }

    /**
     * @notice Create a limit buy order
     * @param tokenIn Token to sell (usually stablecoin)
     * @param tokenOut Token to buy
     * @param amountIn Total amount to spend
     * @param targetPrice Price at which to buy (tokenOut per tokenIn)
     * @param amountOutMin Minimum output expected
     * @param expiry Order expiration
     */
    function createLimitBuyOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 targetPrice,
        uint256 amountOutMin,
        uint256 expiry
    ) external returns (uint256 orderId) {
        if (amountIn == 0) revert InvalidAmount();
        if (targetPrice == 0) revert InvalidPrice();

        return _createOrder(
            msg.sender,
            OrderType.LIMIT_BUY,
            tokenIn,
            tokenOut,
            amountIn,
            amountOutMin,
            targetPrice,
            0, // No interval
            1, // Single execution
            expiry,
            0 // No trailing percent
        );
    }

    /**
     * @notice Create a limit sell order
     * @param tokenIn Token to sell
     * @param tokenOut Token to receive (usually stablecoin)
     * @param amountIn Amount to sell
     * @param targetPrice Price at which to sell
     * @param amountOutMin Minimum output expected
     * @param expiry Order expiration
     */
    function createLimitSellOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 targetPrice,
        uint256 amountOutMin,
        uint256 expiry
    ) external returns (uint256 orderId) {
        if (amountIn == 0) revert InvalidAmount();
        if (targetPrice == 0) revert InvalidPrice();

        return _createOrder(
            msg.sender,
            OrderType.LIMIT_SELL,
            tokenIn,
            tokenOut,
            amountIn,
            amountOutMin,
            targetPrice,
            0, // No interval
            1, // Single execution
            expiry,
            0 // No trailing percent
        );
    }

    /**
     * @notice Create a stop loss order
     * @param tokenIn Token to sell if price drops
     * @param tokenOut Token to receive
     * @param amountIn Amount to sell
     * @param triggerPrice Price below which to trigger
     * @param amountOutMin Minimum output expected
     * @param expiry Order expiration
     */
    function createStopLossOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 triggerPrice,
        uint256 amountOutMin,
        uint256 expiry
    ) external returns (uint256 orderId) {
        if (amountIn == 0) revert InvalidAmount();
        if (triggerPrice == 0) revert InvalidPrice();

        return _createOrder(
            msg.sender,
            OrderType.STOP_LOSS,
            tokenIn,
            tokenOut,
            amountIn,
            amountOutMin,
            triggerPrice,
            0, // No interval
            1, // Single execution
            expiry,
            0 // No trailing percent
        );
    }

    /**
     * @notice Create a take profit order
     * @param tokenIn Token to sell
     * @param tokenOut Token to receive
     * @param amountIn Amount to sell
     * @param targetPrice Price at which to take profit
     * @param amountOutMin Minimum output expected
     * @param expiry Order expiration
     */
    function createTakeProfitOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 targetPrice,
        uint256 amountOutMin,
        uint256 expiry
    ) external returns (uint256 orderId) {
        if (amountIn == 0) revert InvalidAmount();
        if (targetPrice == 0) revert InvalidPrice();

        return _createOrder(
            msg.sender,
            OrderType.TAKE_PROFIT,
            tokenIn,
            tokenOut,
            amountIn,
            amountOutMin,
            targetPrice,
            0, // No interval
            1, // Single execution
            expiry,
            0 // No trailing percent
        );
    }

    /**
     * @notice Create a trailing stop order
     * @param tokenIn Token to sell
     * @param tokenOut Token to receive
     * @param amountIn Amount to sell
     * @param trailingPercent Percentage below peak to trigger (basis points)
     * @param amountOutMin Minimum output expected
     * @param expiry Order expiration
     */
    function createTrailingStopOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 trailingPercent,
        uint256 amountOutMin,
        uint256 expiry
    ) external returns (uint256 orderId) {
        if (amountIn == 0) revert InvalidAmount();
        if (trailingPercent == 0 || trailingPercent >= BASIS_POINTS) revert InvalidPrice();

        // Get current price as initial peak
        uint256 currentPrice = _getCurrentPrice(tokenIn, tokenOut);

        orderId = _createOrder(
            msg.sender,
            OrderType.TRAILING_STOP,
            tokenIn,
            tokenOut,
            amountIn,
            amountOutMin,
            0, // Target price calculated dynamically
            0, // No interval
            1, // Single execution
            expiry,
            trailingPercent
        );

        // Set initial peak price
        accountStorage[msg.sender].orders[orderId].peakPrice = currentPrice;
    }

    /**
     * @notice Cancel an order
     * @param orderId The order ID to cancel
     */
    function cancelOrder(uint256 orderId) external {
        AccountStorage storage store = accountStorage[msg.sender];
        Order storage order = store.orders[orderId];

        if (order.status != OrderStatus.ACTIVE) revert OrderNotActive();

        order.status = OrderStatus.CANCELLED;
        _removeFromActiveList(msg.sender, orderId);

        emit OrderCancelled(msg.sender, orderId);
    }

    // ============ Order Execution ============

    /**
     * @notice Execute a triggered order (callable by anyone)
     * @param account The smart account
     * @param orderId The order ID to execute
     */
    function executeOrder(address account, uint256 orderId) external returns (bytes[] memory) {
        AccountStorage storage store = accountStorage[account];
        Order storage order = store.orders[orderId];

        // Validate order is active
        if (order.status != OrderStatus.ACTIVE) revert OrderNotActive();

        // Check expiry
        if (order.expiry > 0 && block.timestamp > order.expiry) {
            order.status = OrderStatus.EXPIRED;
            _removeFromActiveList(account, orderId);
            emit OrderExpired(account, orderId);
            revert OrderHasExpired();
        }

        // Check if order is triggered
        if (!_isOrderTriggered(order)) revert OrderNotTriggered();

        // Execute the swap
        uint256 amountOut = _executeSwap(account, order);

        // Update order state
        order.lastExecutionTime = block.timestamp;

        if (order.orderType == OrderType.DCA) {
            if (order.executionsRemaining > 0) {
                order.executionsRemaining--;
                if (order.executionsRemaining == 0) {
                    order.status = OrderStatus.EXECUTED;
                    _removeFromActiveList(account, orderId);
                }
            }
        } else {
            order.status = OrderStatus.EXECUTED;
            _removeFromActiveList(account, orderId);
        }

        uint256 currentPrice = _getCurrentPrice(order.tokenIn, order.tokenOut);
        emit OrderExecuted(account, orderId, order.amountIn, amountOut, currentPrice);

        return new bytes[](0);
    }

    /**
     * @notice Update trailing stop peak price
     * @param account The smart account
     * @param orderId The order ID
     */
    function updateTrailingStop(address account, uint256 orderId) external {
        Order storage order = accountStorage[account].orders[orderId];

        if (order.status != OrderStatus.ACTIVE) revert OrderNotActive();
        if (order.orderType != OrderType.TRAILING_STOP) revert InvalidOrderType();

        uint256 currentPrice = _getCurrentPrice(order.tokenIn, order.tokenOut);

        if (currentPrice > order.peakPrice) {
            order.peakPrice = currentPrice;
            emit TrailingStopUpdated(account, orderId, currentPrice);
        }
    }

    /**
     * @notice Execute multiple orders in batch
     * @param account The smart account
     * @param orderIds Array of order IDs
     */
    function executeOrderBatch(address account, uint256[] calldata orderIds) external returns (uint256 successCount) {
        for (uint256 i = 0; i < orderIds.length; i++) {
            try this.executeOrder(account, orderIds[i]) {
                successCount++;
            } catch {
                // Continue with next order
            }
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get order details
     * @param account The smart account
     * @param orderId The order ID
     */
    function getOrder(address account, uint256 orderId) external view returns (Order memory) {
        return accountStorage[account].orders[orderId];
    }

    /**
     * @notice Get all active order IDs
     * @param account The smart account
     */
    function getActiveOrders(address account) external view returns (uint256[] memory) {
        return accountStorage[account].activeOrderIds;
    }

    /**
     * @notice Check if an order is triggered
     * @param account The smart account
     * @param orderId The order ID
     */
    function isTriggered(address account, uint256 orderId) external view returns (bool) {
        Order storage order = accountStorage[account].orders[orderId];
        if (order.status != OrderStatus.ACTIVE) return false;
        return _isOrderTriggered(order);
    }

    /**
     * @notice Get current price for a token pair
     * @param tokenIn Input token
     * @param tokenOut Output token
     */
    function getCurrentPrice(address tokenIn, address tokenOut) external view returns (uint256) {
        return _getCurrentPrice(tokenIn, tokenOut);
    }

    // ============ Internal Functions ============

    function _createOrder(
        address account,
        OrderType orderType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 targetPrice,
        uint256 interval,
        uint256 executionCount,
        uint256 expiry,
        uint256 trailingPercent
    ) internal returns (uint256 orderId) {
        AccountStorage storage store = accountStorage[account];
        orderId = store.nextOrderId++;

        store.orders[orderId] = Order({
            orderType: orderType,
            status: OrderStatus.ACTIVE,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            targetPrice: targetPrice,
            interval: interval,
            lastExecutionTime: 0,
            executionsRemaining: executionCount,
            expiry: expiry,
            trailingPercent: trailingPercent,
            peakPrice: 0
        });

        store.activeOrderIds.push(orderId);

        emit OrderCreated(account, orderId, orderType, tokenIn, tokenOut, amountIn);
    }

    function _isOrderTriggered(Order storage order) internal view returns (bool) {
        uint256 currentPrice = _getCurrentPrice(order.tokenIn, order.tokenOut);

        if (order.orderType == OrderType.DCA) {
            // DCA triggers based on time interval
            if (order.lastExecutionTime == 0) return true;
            return block.timestamp >= order.lastExecutionTime + order.interval;
        }

        if (order.orderType == OrderType.LIMIT_BUY) {
            // Buy when price drops to or below target
            return currentPrice <= order.targetPrice;
        }

        if (order.orderType == OrderType.LIMIT_SELL || order.orderType == OrderType.TAKE_PROFIT) {
            // Sell when price rises to or above target
            return currentPrice >= order.targetPrice;
        }

        if (order.orderType == OrderType.STOP_LOSS) {
            // Sell when price drops to or below trigger
            return currentPrice <= order.targetPrice;
        }

        if (order.orderType == OrderType.TRAILING_STOP) {
            // Sell when price drops trailingPercent below peak
            uint256 triggerPrice = (order.peakPrice * (BASIS_POINTS - order.trailingPercent)) / BASIS_POINTS;
            return currentPrice <= triggerPrice;
        }

        return false;
    }

    function _getCurrentPrice(address tokenIn, address tokenOut) internal view returns (uint256) {
        (uint256 priceIn,) = ORACLE.getPriceWithTimestamp(tokenIn);
        (uint256 priceOut,) = ORACLE.getPriceWithTimestamp(tokenOut);

        // Price = how much tokenOut you get per tokenIn
        // = priceIn / priceOut (normalized to 18 decimals)
        return (priceIn * PRICE_PRECISION) / priceOut;
    }

    function _executeSwap(address account, Order storage order) internal returns (uint256 amountOut) {
        // Build swap call data for DEX router
        // This is a simplified example - actual implementation would use the DEXIntegration contract
        bytes memory swapCall = abi.encodeWithSignature(
            "swap(address,address,uint256,uint256,address)",
            order.tokenIn,
            order.tokenOut,
            order.amountIn,
            order.amountOutMin,
            account
        );

        // Execute via smart account
        bytes memory execData = abi.encodePacked(DEX_ROUTER, uint256(0), swapCall);

        ExecMode execMode = ExecMode.wrap(bytes32(0));
        bytes[] memory results = IERC7579Account(account).executeFromExecutor(execMode, execData);

        // Decode result (assuming swap returns amountOut)
        if (results.length > 0 && results[0].length >= 32) {
            amountOut = abi.decode(results[0], (uint256));
        }

        // Verify slippage
        if (order.amountOutMin > 0 && amountOut < order.amountOutMin) {
            revert SlippageExceeded();
        }
    }

    function _removeFromActiveList(address account, uint256 orderId) internal {
        AccountStorage storage store = accountStorage[account];
        uint256 length = store.activeOrderIds.length;

        for (uint256 i = 0; i < length; i++) {
            if (store.activeOrderIds[i] == orderId) {
                store.activeOrderIds[i] = store.activeOrderIds[length - 1];
                store.activeOrderIds.pop();
                break;
            }
        }
    }
}
