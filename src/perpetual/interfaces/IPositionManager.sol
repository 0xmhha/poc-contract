// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";

/**
 * @title IPositionManager
 * @author StableNet Team
 * @notice 포지션 관리 인터페이스
 */
interface IPositionManager {
    // ============ View Functions ============

    /**
     * @notice 포지션 조회
     * @param positionKey 포지션 키
     * @return position 포지션 정보
     */
    function getPosition(bytes32 positionKey) external view returns (PerpetualTypes.Position memory position);

    /**
     * @notice 포지션 키 생성
     * @param trader 트레이더 주소
     * @param marketId 마켓 ID
     * @param side 포지션 방향
     * @return positionKey 포지션 키
     */
    function getPositionKey(address trader, uint32 marketId, PerpetualTypes.PositionSide side)
        external
        pure
        returns (bytes32 positionKey);

    /**
     * @notice 포지션 존재 여부 확인
     * @param positionKey 포지션 키
     * @return exists 존재 여부
     */
    function positionExists(bytes32 positionKey) external view returns (bool exists);

    /**
     * @notice 포지션 결과 조회 (PnL, 마진율 등)
     * @param positionKey 포지션 키
     * @return result 포지션 결과
     */
    function getPositionResult(bytes32 positionKey) external view returns (PerpetualTypes.PositionResult memory result);

    /**
     * @notice 미실현 PnL 조회
     * @param positionKey 포지션 키
     * @return pnl 미실현 손익
     */
    function getUnrealizedPnL(bytes32 positionKey) external view returns (int256 pnl);

    /**
     * @notice 마진 비율 조회
     * @param positionKey 포지션 키
     * @return ratio 마진 비율 (BPS)
     */
    function getMarginRatio(bytes32 positionKey) external view returns (uint256 ratio);

    /**
     * @notice 청산가 조회
     * @param positionKey 포지션 키
     * @return liquidationPrice 청산가
     */
    function getLiquidationPrice(bytes32 positionKey) external view returns (uint256 liquidationPrice);

    /**
     * @notice 청산 가능 여부 확인
     * @param positionKey 포지션 키
     * @return isLiquidatable 청산 가능 여부
     */
    function isLiquidatable(bytes32 positionKey) external view returns (bool);

    /**
     * @notice 트레이더 포지션 목록 조회
     * @param trader 트레이더 주소
     * @return positionKeys 포지션 키 목록
     */
    function getTraderPositions(address trader) external view returns (bytes32[] memory positionKeys);

    /**
     * @notice 마켓 Open Interest 조회
     * @param marketId 마켓 ID
     * @param side 포지션 방향
     * @return oi Open Interest
     */
    function getOpenInterest(uint32 marketId, PerpetualTypes.PositionSide side) external view returns (uint256 oi);

    // ============ State-Changing Functions ============

    /**
     * @notice 포지션 오픈
     * @param trader 트레이더 주소
     * @param marketId 마켓 ID
     * @param side 포지션 방향
     * @param size 포지션 크기
     * @param margin 마진 금액
     * @param leverage 레버리지
     * @param entryPrice 진입가
     * @return positionKey 포지션 키
     */
    function openPosition(
        address trader,
        uint32 marketId,
        PerpetualTypes.PositionSide side,
        uint128 size,
        uint128 margin,
        uint8 leverage,
        uint128 entryPrice
    ) external returns (bytes32 positionKey);

    /**
     * @notice 포지션 증가
     * @param positionKey 포지션 키
     * @param addSize 추가 크기
     * @param addMargin 추가 마진
     * @param price 추가 가격
     */
    function increasePosition(bytes32 positionKey, uint128 addSize, uint128 addMargin, uint128 price) external;

    /**
     * @notice 포지션 감소
     * @param positionKey 포지션 키
     * @param reduceSize 감소 크기
     * @param exitPrice 청산가
     * @return realizedPnL 실현 손익
     */
    function decreasePosition(bytes32 positionKey, uint128 reduceSize, uint128 exitPrice)
        external
        returns (int256 realizedPnL);

    /**
     * @notice 포지션 종료
     * @param positionKey 포지션 키
     * @param exitPrice 청산가
     * @return realizedPnL 실현 손익
     */
    function closePosition(bytes32 positionKey, uint128 exitPrice) external returns (int256 realizedPnL);

    /**
     * @notice 마진 추가
     * @param positionKey 포지션 키
     * @param addMargin 추가 마진
     */
    function addMargin(bytes32 positionKey, uint128 addMargin) external;

    /**
     * @notice 마진 제거
     * @param positionKey 포지션 키
     * @param removeMargin 제거 마진
     */
    function removeMargin(bytes32 positionKey, uint128 removeMargin) external;

    /**
     * @notice 펀딩비 정산
     * @param positionKey 포지션 키
     * @param cumulativeFundingIndex 현재 누적 펀딩 인덱스
     * @return fundingPayment 펀딩 지불액
     */
    function settleFunding(bytes32 positionKey, int64 cumulativeFundingIndex) external returns (int256 fundingPayment);

    /**
     * @notice 포지션 청산 (Liquidator only)
     * @param positionKey 포지션 키
     * @param liquidationPrice 청산가
     * @return remainingMargin 잔여 마진
     */
    function liquidatePosition(bytes32 positionKey, uint128 liquidationPrice) external returns (int256 remainingMargin);
}
