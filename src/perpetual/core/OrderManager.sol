// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IOrderManager } from "../interfaces/IOrderManager.sol";
import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";
import { PerpetualMath } from "../libraries/PerpetualMath.sol";
import { PerpetualErrors } from "../libraries/PerpetualErrors.sol";
import { PerpetualEvents } from "../libraries/PerpetualEvents.sol";
import { PerpetualPrice } from "../libraries/PerpetualPrice.sol";
import { Constants } from "../../common/libraries/Constants.sol";

/**
 * @title OrderManager
 * @author StableNet Team
 * @notice 주문 관리 컨트랙트
 * @dev
 * - 주문 생성/취소/수정
 * - 시장가/지정가 주문 처리
 * - 트리거 주문 (스탑/TP) 관리
 * - 주문 매칭 및 체결
 * @custom:status TESTNET ONLY. Reference implementation for indexer trading venues; not audited.
 *      Event signatures and the getOrder() return layout are consumed by indexer-go's
 *      perp_orderbook venue; changing them is a breaking change for the indexer.
 */
contract OrderManager is IOrderManager {
    using PerpetualMath for uint256;

    // ============ Constants ============

    uint256 private constant PRECISION = Constants.PRECISION;
    uint256 private constant BPS_PRECISION = Constants.BPS_PRECISION;

    /// @notice 최대 오픈 주문 수 (트레이더당)
    uint256 public constant MAX_OPEN_ORDERS_PER_TRADER = 50;

    /// @notice 기본 주문 만료 시간 (7일)
    uint64 public constant DEFAULT_ORDER_EXPIRY = 7 days;

    /// @notice 최대 주문 만료 시간 (90일)
    uint64 public constant MAX_ORDER_EXPIRY = 90 days;

    // ============ State Variables ============

    /// @notice 주문 저장소
    mapping(bytes32 => PerpetualTypes.Order) private _orders;

    /// @notice 트레이더별 오픈 주문 목록
    mapping(address => bytes32[]) private _traderOpenOrders;

    /// @notice 마켓별 오픈 주문 수
    mapping(uint32 => uint256) private _marketOrderCounts;

    /// @notice 주문 nonce (유일성 보장)
    uint256 private _orderNonce;

    /// @notice 관리자 주소
    address private _admin;

    /// @notice PerpetualEngine 주소
    address private _engine;

    /// @notice 가격 피드 주소 (시장가 주문용)
    address private _priceFeed;
    mapping(uint32 => address) private _marketPriceOracles;

    // ============ Modifiers ============

    modifier onlyAuthorized() {
        if (msg.sender != _admin && msg.sender != _engine) {
            revert PerpetualErrors.Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != _admin) {
            revert PerpetualErrors.Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyExistingOrder(bytes32 orderId) {
        if (_orders[orderId].createdAt == 0) {
            revert PerpetualErrors.OrderNotFound(orderId);
        }
        _;
    }

    // ============ Constructor ============

    /**
     * @notice 컨트랙트 초기화
     * @param admin 관리자 주소
     */
    constructor(address admin) {
        if (admin == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        _admin = admin;
    }

    // ============ View Functions ============

    /// @inheritdoc IOrderManager
    function getOrder(bytes32 orderId) external view override returns (PerpetualTypes.Order memory order) {
        return _orders[orderId];
    }

    /// @inheritdoc IOrderManager
    function orderExists(bytes32 orderId) external view override returns (bool exists) {
        return _orders[orderId].createdAt != 0;
    }

    /// @inheritdoc IOrderManager
    function getOrderStatus(bytes32 orderId) external view override returns (PerpetualTypes.OrderStatus status) {
        PerpetualTypes.Order storage order = _orders[orderId];
        if (order.createdAt == 0) {
            revert PerpetualErrors.OrderNotFound(orderId);
        }
        return order.status;
    }

    /// @inheritdoc IOrderManager
    function getTraderOpenOrders(address trader) external view override returns (bytes32[] memory orderIds) {
        return _traderOpenOrders[trader];
    }

    /// @inheritdoc IOrderManager
    function getMarketOrderCount(uint32 marketId) external view override returns (uint256 count) {
        return _marketOrderCounts[marketId];
    }

    /// @inheritdoc IOrderManager
    function getTraderOrderCount(address trader) external view override returns (uint256 count) {
        return _traderOpenOrders[trader].length;
    }

    // ============ State-Changing Functions ============

    /// @inheritdoc IOrderManager
    function createOrder(address trader, PerpetualTypes.OrderParams calldata params)
        external
        override
        onlyAuthorized
        returns (bytes32 orderId)
    {
        // 입력 검증
        _validateOrderParams(trader, params);

        // 오픈 주문 수 확인
        if (_traderOpenOrders[trader].length >= MAX_OPEN_ORDERS_PER_TRADER) {
            revert PerpetualErrors.MaxOpenOrdersReached(trader, MAX_OPEN_ORDERS_PER_TRADER);
        }

        // 주문 ID 생성
        orderId = _generateOrderId(trader, params.marketId);

        // 만료 시간 설정
        uint64 expiresAt = params.expiration;
        if (expiresAt == 0) {
            expiresAt = uint64(block.timestamp) + DEFAULT_ORDER_EXPIRY;
        } else if (expiresAt > block.timestamp + MAX_ORDER_EXPIRY) {
            expiresAt = uint64(block.timestamp) + MAX_ORDER_EXPIRY;
        }

        // 주문 생성
        PerpetualTypes.Order storage order = _orders[orderId];
        order.orderId = orderId;
        order.trader = trader;
        order.marketId = params.marketId;
        order.side = params.side;
        order.orderType = params.orderType;
        order.status = PerpetualTypes.OrderStatus.Open;
        order.timeInForce = params.timeInForce;
        order.reduceOnly = params.reduceOnly;
        order.size = params.size;
        order.filledSize = 0;
        order.price = params.price;
        order.triggerPrice = params.triggerPrice;
        order.averagePrice = 0;
        order.createdAt = uint64(block.timestamp);
        order.expiresAt = expiresAt;

        // 트리거 주문은 Pending 상태로 시작
        if (_isTriggerOrder(params.orderType)) {
            order.status = PerpetualTypes.OrderStatus.Pending;
        }

        // 트레이더 주문 목록에 추가
        _traderOpenOrders[trader].push(orderId);

        // 마켓 주문 수 증가
        _marketOrderCounts[params.marketId]++;

        emit PerpetualEvents.OrderCreated(
            orderId, trader, params.marketId, params.side, params.orderType, params.size, params.price
        );

        return orderId;
    }

    /// @inheritdoc IOrderManager
    function cancelOrder(bytes32 orderId) external override onlyExistingOrder(orderId) {
        PerpetualTypes.Order storage order = _orders[orderId];

        // 권한 확인 (트레이더 또는 관리자)
        if (msg.sender != order.trader && msg.sender != _admin && msg.sender != _engine) {
            revert PerpetualErrors.Unauthorized(msg.sender);
        }

        // 취소 가능 상태 확인
        if (!_isCancellable(order.status)) {
            revert PerpetualErrors.OrderNotCancellable(orderId, order.status);
        }

        // 주문 취소
        _cancelOrderInternal(orderId, order);
    }

    /// @inheritdoc IOrderManager
    function modifyOrder(bytes32 orderId, uint128 newSize, uint128 newPrice)
        external
        override
        onlyExistingOrder(orderId)
        onlyAuthorized
    {
        PerpetualTypes.Order storage order = _orders[orderId];

        // 수정 가능 상태 확인
        if (order.status != PerpetualTypes.OrderStatus.Open && order.status != PerpetualTypes.OrderStatus.Pending) {
            revert PerpetualErrors.OrderNotModifiable(orderId, order.status);
        }

        // 수량 검증
        if (newSize == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        // 부분 체결된 주문은 체결 수량보다 작게 수정 불가
        if (newSize < order.filledSize) {
            revert PerpetualErrors.InvalidOrderSize(orderId, newSize, order.filledSize);
        }

        uint128 oldSize = order.size;
        uint128 oldPrice = order.price;

        order.size = newSize;
        order.price = newPrice;

        emit PerpetualEvents.OrderModified(orderId, order.trader, newSize, newPrice);
    }

    /// @inheritdoc IOrderManager
    function executeMarketOrder(
        address trader,
        uint32 marketId,
        PerpetualTypes.PositionSide side,
        uint128 size,
        uint128 maxSlippage
    ) external override onlyAuthorized returns (uint128 fillPrice, uint128 fillSize) {
        if (size == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        if (maxSlippage > BPS_PRECISION) revert PerpetualErrors.InvalidParameter("invalid slippage");
        address oracle = _marketPriceOracles[marketId];
        // This reference venue fills at the mark; tolerance is not an execution surcharge.
        fillPrice = PerpetualPrice.read(oracle == address(0) ? _priceFeed : oracle, marketId);

        fillSize = size;

        emit PerpetualEvents.MarketOrderExecuted(trader, marketId, side, fillSize, fillPrice);

        return (fillPrice, fillSize);
    }

    /// @inheritdoc IOrderManager
    function fillOrder(bytes32 orderId, uint128 fillSize, uint128 fillPrice)
        external
        override
        onlyAuthorized
        onlyExistingOrder(orderId)
        returns (uint128 remaining)
    {
        PerpetualTypes.Order storage order = _orders[orderId];

        // 체결 가능 상태 확인
        if (
            order.status != PerpetualTypes.OrderStatus.Open
                && order.status != PerpetualTypes.OrderStatus.PartiallyFilled
        ) {
            revert PerpetualErrors.OrderNotFillable(orderId, order.status);
        }

        // 잔여 수량 확인
        uint128 remainingSize = order.size - order.filledSize;
        if (fillSize > remainingSize) {
            fillSize = remainingSize;
        }

        // 가격 검증 (지정가 주문)
        if (order.orderType == PerpetualTypes.OrderType.Limit) {
            if (order.side == PerpetualTypes.PositionSide.Long && fillPrice > order.price) {
                revert PerpetualErrors.PriceOutOfRange(orderId, fillPrice, order.price);
            }
            if (order.side == PerpetualTypes.PositionSide.Short && fillPrice < order.price) {
                revert PerpetualErrors.PriceOutOfRange(orderId, fillPrice, order.price);
            }
        }

        // 평균 체결가 계산
        uint256 totalValue = uint256(order.averagePrice) * order.filledSize + uint256(fillPrice) * fillSize;
        uint128 newFilledSize = order.filledSize + fillSize;
        order.averagePrice = uint128(totalValue / newFilledSize);
        order.filledSize = newFilledSize;

        // 상태 업데이트
        if (order.filledSize == order.size) {
            order.status = PerpetualTypes.OrderStatus.Filled;
            _removeFromOpenOrders(order.trader, orderId);
            _marketOrderCounts[order.marketId]--;
        } else {
            order.status = PerpetualTypes.OrderStatus.PartiallyFilled;
        }

        emit PerpetualEvents.OrderPartiallyFilled(
            orderId, fillSize, order.filledSize, order.size - order.filledSize, fillPrice
        );

        return order.size - order.filledSize;
    }

    /// @inheritdoc IOrderManager
    function matchOrders(bytes32 makerOrderId, bytes32 takerOrderId, uint128 matchSize, uint128 matchPrice)
        external
        override
        onlyAuthorized
    {
        PerpetualTypes.Order storage makerOrder = _orders[makerOrderId];
        PerpetualTypes.Order storage takerOrder = _orders[takerOrderId];

        // 주문 존재 확인
        if (makerOrder.createdAt == 0) {
            revert PerpetualErrors.OrderNotFound(makerOrderId);
        }
        if (takerOrder.createdAt == 0) {
            revert PerpetualErrors.OrderNotFound(takerOrderId);
        }

        // 매칭 가능 상태 확인
        if (!_isMatchable(makerOrder.status)) {
            revert PerpetualErrors.OrderNotMatchable(makerOrderId, makerOrder.status);
        }
        if (!_isMatchable(takerOrder.status)) {
            revert PerpetualErrors.OrderNotMatchable(takerOrderId, takerOrder.status);
        }

        // 같은 마켓인지 확인
        if (makerOrder.marketId != takerOrder.marketId) {
            revert PerpetualErrors.MarketMismatch(makerOrder.marketId, takerOrder.marketId);
        }

        // 반대 방향인지 확인
        if (makerOrder.side == takerOrder.side) {
            revert PerpetualErrors.SameSideOrders(makerOrderId, takerOrderId);
        }

        // 각 주문 체결 처리
        _fillOrderInternal(makerOrder, matchSize, matchPrice, true);
        _fillOrderInternal(takerOrder, matchSize, matchPrice, false);

        emit PerpetualEvents.OrdersMatched(makerOrderId, takerOrderId, matchSize, matchPrice);
    }

    /// @inheritdoc IOrderManager
    function expireOrder(bytes32 orderId) external override onlyExistingOrder(orderId) {
        PerpetualTypes.Order storage order = _orders[orderId];

        // 만료 가능 상태 확인
        if (
            order.status != PerpetualTypes.OrderStatus.Open && order.status != PerpetualTypes.OrderStatus.Pending
                && order.status != PerpetualTypes.OrderStatus.PartiallyFilled
        ) {
            revert PerpetualErrors.OrderAlreadyFinalized(orderId, order.status);
        }

        // 만료 시간 확인
        if (block.timestamp <= order.expiresAt) {
            revert PerpetualErrors.OrderNotExpired(orderId, order.expiresAt);
        }

        // 만료 처리
        order.status = PerpetualTypes.OrderStatus.Expired;
        _removeFromOpenOrders(order.trader, orderId);
        _marketOrderCounts[order.marketId]--;

        emit PerpetualEvents.OrderExpired(orderId, order.trader, order.expiresAt);
    }

    /// @inheritdoc IOrderManager
    function checkAndTrigger(bytes32 orderId, uint128 currentPrice)
        external
        override
        onlyAuthorized
        onlyExistingOrder(orderId)
        returns (bool triggered)
    {
        PerpetualTypes.Order storage order = _orders[orderId];

        // Pending 상태만 트리거 가능
        if (order.status != PerpetualTypes.OrderStatus.Pending) {
            return false;
        }

        // 트리거 주문인지 확인
        if (!_isTriggerOrder(order.orderType)) {
            return false;
        }

        // 트리거 조건 확인
        bool shouldTrigger = _checkTriggerCondition(order, currentPrice);

        if (shouldTrigger) {
            // 트리거되면 Open 상태로 변경
            order.status = PerpetualTypes.OrderStatus.Open;
            emit PerpetualEvents.OrderTriggered(orderId, currentPrice, order.triggerPrice);
            return true;
        }

        return false;
    }

    function setMarketPriceOracle(uint32 marketId, address oracle) external override onlyAuthorized {
        if (oracle == address(0)) revert PerpetualErrors.ZeroAddress();
        _marketPriceOracles[marketId] = oracle;
    }

    // ============ Admin Functions ============

    /**
     * @notice 엔진 주소 설정
     * @param engine 엔진 주소
     */
    function setEngine(address engine) external onlyAdmin {
        if (engine == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        _engine = engine;
    }

    /**
     * @notice 가격 피드 설정
     * @param priceFeed 가격 피드 주소
     */
    function setPriceFeed(address priceFeed) external onlyAdmin {
        if (priceFeed == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        _priceFeed = priceFeed;
    }

    // ============ Internal Functions ============

    /**
     * @notice 주문 파라미터 검증
     * @param trader 트레이더 주소
     * @param params 주문 파라미터
     */
    function _validateOrderParams(address trader, PerpetualTypes.OrderParams calldata params) internal pure {
        if (trader == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        if (params.size == 0) {
            revert PerpetualErrors.ZeroAmount();
        }
        // 지정가 주문은 가격 필요
        if (
            (params.orderType == PerpetualTypes.OrderType.Limit
                    || params.orderType == PerpetualTypes.OrderType.StopLimit
                    || params.orderType == PerpetualTypes.OrderType.TakeProfitLimit) && params.price == 0
        ) {
            revert PerpetualErrors.InvalidPrice(params.price);
        }
        // 트리거 주문은 트리거 가격 필요
        if (_isTriggerOrderType(params.orderType) && params.triggerPrice == 0) {
            revert PerpetualErrors.InvalidTriggerPrice(params.triggerPrice);
        }
    }

    /**
     * @notice 주문 ID 생성
     * @param trader 트레이더 주소
     * @param marketId 마켓 ID
     * @return orderId 주문 ID
     */
    function _generateOrderId(address trader, uint32 marketId) internal returns (bytes32 orderId) {
        return keccak256(abi.encodePacked(trader, marketId, block.timestamp, ++_orderNonce));
    }

    /**
     * @notice 트리거 주문 여부 확인
     * @param orderType 주문 유형
     * @return 트리거 주문 여부
     */
    function _isTriggerOrder(PerpetualTypes.OrderType orderType) internal pure returns (bool) {
        return _isTriggerOrderType(orderType);
    }

    /**
     * @notice 트리거 주문 타입 확인 (pure 버전)
     * @param orderType 주문 유형
     * @return 트리거 주문 여부
     */
    function _isTriggerOrderType(PerpetualTypes.OrderType orderType) internal pure returns (bool) {
        return orderType == PerpetualTypes.OrderType.Stop || orderType == PerpetualTypes.OrderType.StopLimit
            || orderType == PerpetualTypes.OrderType.TakeProfit || orderType == PerpetualTypes.OrderType.TakeProfitLimit;
    }

    /**
     * @notice 취소 가능 상태 확인
     * @param status 주문 상태
     * @return 취소 가능 여부
     */
    function _isCancellable(PerpetualTypes.OrderStatus status) internal pure returns (bool) {
        return status == PerpetualTypes.OrderStatus.Pending || status == PerpetualTypes.OrderStatus.Open
            || status == PerpetualTypes.OrderStatus.PartiallyFilled;
    }

    /**
     * @notice 매칭 가능 상태 확인
     * @param status 주문 상태
     * @return 매칭 가능 여부
     */
    function _isMatchable(PerpetualTypes.OrderStatus status) internal pure returns (bool) {
        return status == PerpetualTypes.OrderStatus.Open || status == PerpetualTypes.OrderStatus.PartiallyFilled;
    }

    /**
     * @notice 주문 취소 내부 처리
     * @param orderId 주문 ID
     * @param order 주문 정보
     */
    function _cancelOrderInternal(bytes32 orderId, PerpetualTypes.Order storage order) internal {
        order.status = PerpetualTypes.OrderStatus.Cancelled;
        _removeFromOpenOrders(order.trader, orderId);
        _marketOrderCounts[order.marketId]--;

        emit PerpetualEvents.OrderCancelled(orderId, order.trader, "user_cancelled");
    }

    /**
     * @notice 오픈 주문 목록에서 제거
     * @param trader 트레이더 주소
     * @param orderId 주문 ID
     */
    function _removeFromOpenOrders(address trader, bytes32 orderId) internal {
        bytes32[] storage orders = _traderOpenOrders[trader];
        uint256 length = orders.length;

        for (uint256 i = 0; i < length; i++) {
            if (orders[i] == orderId) {
                // 마지막 요소와 교체 후 삭제
                orders[i] = orders[length - 1];
                orders.pop();
                break;
            }
        }
    }

    /**
     * @notice 주문 체결 내부 처리
     * @param order 주문 정보
     * @param fillSize 체결 수량
     * @param fillPrice 체결 가격
     * @param isMaker 메이커 여부
     */
    function _fillOrderInternal(PerpetualTypes.Order storage order, uint128 fillSize, uint128 fillPrice, bool isMaker)
        internal
    {
        uint128 remainingSize = order.size - order.filledSize;
        if (fillSize > remainingSize) {
            fillSize = remainingSize;
        }

        // 평균 체결가 계산
        uint256 totalValue = uint256(order.averagePrice) * order.filledSize + uint256(fillPrice) * fillSize;
        uint128 newFilledSize = order.filledSize + fillSize;
        order.averagePrice = uint128(totalValue / newFilledSize);
        order.filledSize = newFilledSize;

        // 상태 업데이트
        if (order.filledSize == order.size) {
            order.status = PerpetualTypes.OrderStatus.Filled;
            _removeFromOpenOrders(order.trader, order.orderId);
            _marketOrderCounts[order.marketId]--;
        } else {
            order.status = PerpetualTypes.OrderStatus.PartiallyFilled;
        }

        emit PerpetualEvents.OrderPartiallyFilled(
            order.orderId, fillSize, order.filledSize, order.size - order.filledSize, fillPrice
        );
    }

    /**
     * @notice 트리거 조건 확인
     * @param order 주문 정보
     * @param currentPrice 현재 가격
     * @return shouldTrigger 트리거 여부
     */
    function _checkTriggerCondition(PerpetualTypes.Order storage order, uint128 currentPrice)
        internal
        view
        returns (bool shouldTrigger)
    {
        // Stop 주문: 롱은 가격 하락 시, 숏은 가격 상승 시 트리거
        if (order.orderType == PerpetualTypes.OrderType.Stop || order.orderType == PerpetualTypes.OrderType.StopLimit) {
            if (order.side == PerpetualTypes.PositionSide.Long) {
                // 롱 포지션 보호: 가격이 트리거 이하로 하락
                return currentPrice <= order.triggerPrice;
            } else {
                // 숏 포지션 보호: 가격이 트리거 이상으로 상승
                return currentPrice >= order.triggerPrice;
            }
        }

        // TakeProfit 주문: 롱은 가격 상승 시, 숏은 가격 하락 시 트리거
        if (
            order.orderType == PerpetualTypes.OrderType.TakeProfit
                || order.orderType == PerpetualTypes.OrderType.TakeProfitLimit
        ) {
            if (order.side == PerpetualTypes.PositionSide.Long) {
                // 롱 포지션 익절: 가격이 트리거 이상으로 상승
                return currentPrice >= order.triggerPrice;
            } else {
                // 숏 포지션 익절: 가격이 트리거 이하로 하락
                return currentPrice <= order.triggerPrice;
            }
        }

        return false;
    }
}
