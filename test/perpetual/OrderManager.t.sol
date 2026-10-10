// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, Vm } from "forge-std/Test.sol";
import { OrderManager } from "../../src/perpetual/core/OrderManager.sol";
import { PerpetualEngine } from "../../src/perpetual/PerpetualEngine.sol";
import { PerpetualTypes } from "../../src/perpetual/libraries/PerpetualTypes.sol";
import { PerpetualEvents } from "../../src/perpetual/libraries/PerpetualEvents.sol";
import { PerpetualErrors } from "../../src/perpetual/libraries/PerpetualErrors.sol";

/// @title OrderManager tests
/// @notice Covers the order lifecycle and pins the event signatures and getOrder()
///         return layout that indexer-go's perp_orderbook venue decodes
///         (indexer-go pkg/features/dex/events.go, pkg/features/dex/orderbook/reconcile.go).
contract OrderManagerTest is Test {
    OrderManager internal om;
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint32 internal constant MARKET = 7;

    function setUp() public {
        om = new OrderManager(admin);
    }

    // ============ Indexer conformance ============

    /// @dev Signature strings are copied verbatim from indexer-go. A failure here means
    ///      the indexer must be updated in the same change.
    function test_EventSignatures_MatchIndexer() public pure {
        assertEq(PerpetualEvents.MarketCreated.selector, keccak256("MarketCreated(uint32,address,address,uint32)"));
        assertEq(
            PerpetualEvents.OrderCreated.selector,
            keccak256("OrderCreated(bytes32,address,uint32,uint8,uint8,uint256,uint256)")
        );
        assertEq(
            PerpetualEvents.OrderPartiallyFilled.selector,
            keccak256("OrderPartiallyFilled(bytes32,uint256,uint256,uint256,uint256)")
        );
        assertEq(PerpetualEvents.OrderCancelled.selector, keccak256("OrderCancelled(bytes32,address,string)"));
        assertEq(PerpetualEvents.OrderExpired.selector, keccak256("OrderExpired(bytes32,address,uint256)"));
        assertEq(PerpetualEvents.OrderModified.selector, keccak256("OrderModified(bytes32,address,uint256,uint256)"));
        assertEq(PerpetualEvents.OrderTriggered.selector, keccak256("OrderTriggered(bytes32,uint128,uint128)"));
        assertEq(
            PerpetualEvents.MarketOrderExecuted.selector,
            keccak256("MarketOrderExecuted(address,uint32,uint8,uint128,uint128)")
        );
        assertEq(PerpetualEvents.OrdersMatched.selector, keccak256("OrdersMatched(bytes32,bytes32,uint128,uint128)"));
    }

    /// @dev The indexer reads getOrder() return words by index: status=5, size=8, filled=9, price=10.
    function test_GetOrder_ReturnLayout_MatchesIndexer() public {
        bytes32 id = _limit(alice, PerpetualTypes.PositionSide.Short, 10e18, 51e18);
        vm.prank(admin);
        om.fillOrder(id, 4e18, 51e18);

        (bool ok, bytes memory ret) = address(om).staticcall(abi.encodeWithSignature("getOrder(bytes32)", id));
        assertTrue(ok);
        assertEq(ret.length, 15 * 32, "Order must stay a 15-word static tuple");
        assertEq(_word(ret, 0), uint256(id));
        assertEq(_word(ret, 5), uint256(PerpetualTypes.OrderStatus.PartiallyFilled));
        assertEq(_word(ret, 8), 10e18);
        assertEq(_word(ret, 9), 4e18);
        assertEq(_word(ret, 10), 51e18);
    }

    function test_OrderStatusOrdinals_MatchIndexer() public pure {
        assertEq(uint8(PerpetualTypes.OrderStatus.Open), 1);
        assertEq(uint8(PerpetualTypes.OrderStatus.PartiallyFilled), 2);
        assertEq(uint8(PerpetualTypes.PositionSide.Long), 0);
        assertEq(uint8(PerpetualTypes.OrderType.TakeProfitLimit), 5);
    }

    // ============ Lifecycle ============

    function test_CreateOrder_EmitsAndStoresOpen() public {
        vm.recordLogs();
        bytes32 id = _limit(alice, PerpetualTypes.PositionSide.Long, 10e18, 50e18);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], PerpetualEvents.OrderCreated.selector);
        assertEq(logs[0].topics[1], id);

        PerpetualTypes.Order memory o = om.getOrder(id);
        assertEq(o.trader, alice);
        assertEq(uint8(o.status), uint8(PerpetualTypes.OrderStatus.Open));
    }

    function test_CreateOrder_RevertsForUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.Unauthorized.selector, alice));
        om.createOrder(alice, _params(PerpetualTypes.PositionSide.Long, PerpetualTypes.OrderType.Limit, 1e18, 1e18, 0));
    }

    /// @dev A match emits two OrderPartiallyFilled (maker then taker) followed by OrdersMatched;
    ///      the indexer folds these three logs into one trade.
    function test_MatchOrders_EmitsTwoFillsThenMatched() public {
        bytes32 maker = _limit(bob, PerpetualTypes.PositionSide.Short, 10e18, 50e18);
        bytes32 taker = _limit(alice, PerpetualTypes.PositionSide.Long, 4e18, 51e18);

        vm.recordLogs();
        vm.prank(admin);
        om.matchOrders(maker, taker, 4e18, 50e18);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        assertEq(logs[0].topics[0], PerpetualEvents.OrderPartiallyFilled.selector);
        assertEq(logs[0].topics[1], maker);
        assertEq(logs[1].topics[0], PerpetualEvents.OrderPartiallyFilled.selector);
        assertEq(logs[1].topics[1], taker);
        assertEq(logs[2].topics[0], PerpetualEvents.OrdersMatched.selector);

        assertEq(uint8(om.getOrderStatus(maker)), uint8(PerpetualTypes.OrderStatus.PartiallyFilled));
        assertEq(uint8(om.getOrderStatus(taker)), uint8(PerpetualTypes.OrderStatus.Filled));
    }

    function test_MatchOrders_RevertsOnSameSide() public {
        bytes32 a = _limit(alice, PerpetualTypes.PositionSide.Long, 1e18, 50e18);
        bytes32 b = _limit(bob, PerpetualTypes.PositionSide.Long, 1e18, 50e18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.SameSideOrders.selector, a, b));
        om.matchOrders(a, b, 1e18, 50e18);
    }

    function test_FillOrder_LimitPriceGuard() public {
        bytes32 id = _limit(alice, PerpetualTypes.PositionSide.Long, 1e18, 50e18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.PriceOutOfRange.selector, id, 51e18, 50e18));
        om.fillOrder(id, 1e18, 51e18);
    }

    function test_CancelOrder_ByTrader() public {
        bytes32 id = _limit(alice, PerpetualTypes.PositionSide.Long, 1e18, 50e18);
        vm.expectEmit(true, true, false, true);
        emit PerpetualEvents.OrderCancelled(id, alice, "user_cancelled");
        vm.prank(alice);
        om.cancelOrder(id);
        assertEq(uint8(om.getOrderStatus(id)), uint8(PerpetualTypes.OrderStatus.Cancelled));
    }

    function test_CancelOrder_RevertsForOtherTrader() public {
        bytes32 id = _limit(alice, PerpetualTypes.PositionSide.Long, 1e18, 50e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.Unauthorized.selector, bob));
        om.cancelOrder(id);
    }

    function test_ModifyOrder_Emits() public {
        bytes32 id = _limit(alice, PerpetualTypes.PositionSide.Long, 1e18, 50e18);
        vm.expectEmit(true, true, false, true);
        emit PerpetualEvents.OrderModified(id, alice, 2e18, 49e18);
        vm.prank(admin);
        om.modifyOrder(id, 2e18, 49e18);
    }

    function test_ExpireOrder_AfterExpiry() public {
        bytes32 id = _limit(alice, PerpetualTypes.PositionSide.Long, 1e18, 50e18);
        uint64 expiresAt = om.getOrder(id).expiresAt;

        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.OrderNotExpired.selector, id, expiresAt));
        om.expireOrder(id);

        vm.warp(uint256(expiresAt) + 1);
        vm.expectEmit(true, true, false, true);
        emit PerpetualEvents.OrderExpired(id, alice, expiresAt);
        om.expireOrder(id);
        assertEq(uint8(om.getOrderStatus(id)), uint8(PerpetualTypes.OrderStatus.Expired));
    }

    function test_TriggerOrder_StopLong() public {
        vm.prank(admin);
        bytes32 id = om.createOrder(
            alice, _params(PerpetualTypes.PositionSide.Long, PerpetualTypes.OrderType.Stop, 1e18, 0, 45e18)
        );
        assertEq(uint8(om.getOrderStatus(id)), uint8(PerpetualTypes.OrderStatus.Pending));

        vm.prank(admin);
        assertFalse(om.checkAndTrigger(id, 46e18));

        vm.expectEmit(true, false, false, true);
        emit PerpetualEvents.OrderTriggered(id, 44e18, 45e18);
        vm.prank(admin);
        assertTrue(om.checkAndTrigger(id, 44e18));
        assertEq(uint8(om.getOrderStatus(id)), uint8(PerpetualTypes.OrderStatus.Open));
    }

    function test_ExecuteMarketOrder_Emits() public {
        vm.recordLogs();
        vm.prank(admin);
        (uint128 price, uint128 size) =
            om.executeMarketOrder(alice, MARKET, PerpetualTypes.PositionSide.Long, 3e18, 100);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], PerpetualEvents.MarketOrderExecuted.selector);
        assertEq(size, 3e18);
        assertGt(price, 0);
    }

    // ============ PerpetualEngine market registration ============

    function test_CreateMarket_EmitsAndExposesSymbols() public {
        PerpetualEngine engine = new PerpetualEngine(admin, makeAddr("collateral"));
        PerpetualTypes.MarketConfig memory config;
        config.maxLeverage = 20;

        vm.expectEmit(true, true, true, true);
        emit PerpetualEvents.MarketCreated(1, address(0), makeAddr("collateral"), 20);
        vm.prank(admin);
        uint32 id = engine.createMarket("BTC", "USDT", config);

        (string memory base, string memory quote) = engine.getMarketSymbols(id);
        assertEq(base, "BTC");
        assertEq(quote, "USDT");
    }

    // ============ Helpers ============

    function _limit(address trader, PerpetualTypes.PositionSide side, uint128 size, uint128 price)
        internal
        returns (bytes32)
    {
        vm.prank(admin);
        return om.createOrder(trader, _params(side, PerpetualTypes.OrderType.Limit, size, price, 0));
    }

    function _params(
        PerpetualTypes.PositionSide side,
        PerpetualTypes.OrderType orderType,
        uint128 size,
        uint128 price,
        uint128 triggerPrice
    ) internal pure returns (PerpetualTypes.OrderParams memory) {
        return PerpetualTypes.OrderParams({
            marketId: MARKET,
            side: side,
            orderType: orderType,
            timeInForce: PerpetualTypes.TimeInForce.GTC,
            reduceOnly: false,
            size: size,
            price: price,
            triggerPrice: triggerPrice,
            expiration: 0,
            maxSlippage: 0
        });
    }

    function _word(bytes memory data, uint256 index) internal pure returns (uint256 w) {
        assembly ("memory-safe") {
            w := mload(add(add(data, 32), mul(index, 32)))
        }
    }
}
