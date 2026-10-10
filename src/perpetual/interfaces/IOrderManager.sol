// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";

/**
 * @title IOrderManager
 * @author StableNet Team
 * @notice 주문 관리 인터페이스
 */
interface IOrderManager {
    // ============ View Functions ============

    /**
     * @notice 주문 조회
     * @param orderId 주문 ID
     * @return order 주문 정보
     */
    function getOrder(bytes32 orderId) external view returns (PerpetualTypes.Order memory order);

    /**
     * @notice 주문 존재 여부 확인
     * @param orderId 주문 ID
     * @return exists 존재 여부
     */
    function orderExists(bytes32 orderId) external view returns (bool exists);

    /**
     * @notice 주문 상태 조회
     * @param orderId 주문 ID
     * @return status 주문 상태
     */
    function getOrderStatus(bytes32 orderId) external view returns (PerpetualTypes.OrderStatus status);

    /**
     * @notice 트레이더 오픈 주문 목록 조회
     * @param trader 트레이더 주소
     * @return orderIds 주문 ID 목록
     */
    function getTraderOpenOrders(address trader) external view returns (bytes32[] memory orderIds);

    /**
     * @notice 마켓별 오픈 주문 수 조회
     * @param marketId 마켓 ID
     * @return count 오픈 주문 수
     */
    function getMarketOrderCount(uint32 marketId) external view returns (uint256 count);

    /**
     * @notice 트레이더 오픈 주문 수 조회
     * @param trader 트레이더 주소
     * @return count 오픈 주문 수
     */
    function getTraderOrderCount(address trader) external view returns (uint256 count);

    // ============ State-Changing Functions ============

    /**
     * @notice 주문 생성
     * @param trader 트레이더 주소
     * @param params 주문 파라미터
     * @return orderId 주문 ID
     */
    function createOrder(address trader, PerpetualTypes.OrderParams calldata params) external returns (bytes32 orderId);

    /**
     * @notice 주문 취소
     * @param orderId 주문 ID
     */
    function cancelOrder(bytes32 orderId) external;

    /**
     * @notice 주문 수정
     * @param orderId 주문 ID
     * @param newSize 새 수량
     * @param newPrice 새 가격
     */
    function modifyOrder(bytes32 orderId, uint128 newSize, uint128 newPrice) external;

    /**
     * @notice 시장가 주문 실행
     * @param trader 트레이더 주소
     * @param marketId 마켓 ID
     * @param side 주문 방향
     * @param size 주문 수량
     * @param maxSlippage 최대 슬리피지 (BPS)
     * @return fillPrice 체결 가격
     * @return fillSize 체결 수량
     */
    function executeMarketOrder(
        address trader,
        uint32 marketId,
        PerpetualTypes.PositionSide side,
        uint128 size,
        uint128 maxSlippage
    ) external returns (uint128 fillPrice, uint128 fillSize);

    /**
     * @notice 지정가 주문 체결
     * @param orderId 주문 ID
     * @param fillSize 체결 수량
     * @param fillPrice 체결 가격
     * @return remaining 잔여 수량
     */
    function fillOrder(bytes32 orderId, uint128 fillSize, uint128 fillPrice) external returns (uint128 remaining);

    /**
     * @notice 주문 매칭 (오더북)
     * @param makerOrderId 메이커 주문 ID
     * @param takerOrderId 테이커 주문 ID
     * @param matchSize 매칭 수량
     * @param matchPrice 매칭 가격
     */
    function matchOrders(bytes32 makerOrderId, bytes32 takerOrderId, uint128 matchSize, uint128 matchPrice) external;

    /**
     * @notice 만료된 주문 처리
     * @param orderId 주문 ID
     */
    function expireOrder(bytes32 orderId) external;

    /**
     * @notice 트리거 조건 확인 및 실행 (스탑/TP 주문)
     * @param orderId 주문 ID
     * @param currentPrice 현재 가격
     * @return triggered 트리거 여부
     */
    function checkAndTrigger(bytes32 orderId, uint128 currentPrice) external returns (bool triggered);
}
