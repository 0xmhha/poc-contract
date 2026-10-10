// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";

/**
 * @title ILiquidator
 * @author StableNet Team
 * @notice 청산 실행 인터페이스
 */
interface ILiquidator {
    // ============ View Functions ============

    /**
     * @notice 청산 가능 여부 확인
     * @param positionKey 포지션 키
     * @return isLiquidatable 청산 가능 여부
     * @return reason 청산 불가 사유 (가능하면 빈 문자열)
     */
    function canLiquidate(bytes32 positionKey) external view returns (bool isLiquidatable, string memory reason);

    /**
     * @notice 청산 정보 조회
     * @param positionKey 포지션 키
     * @return info 청산 정보
     */
    function getLiquidationInfo(bytes32 positionKey) external view returns (PerpetualTypes.LiquidationInfo memory info);

    /**
     * @notice 청산 수수료 조회
     * @param positionSize 포지션 크기
     * @param marketId 마켓 ID
     * @return liquidatorFee 청산자 수수료
     * @return protocolFee 프로토콜 수수료
     * @return insuranceFundFee 보험 기금 수수료
     */
    function getLiquidationFees(uint256 positionSize, uint32 marketId)
        external
        view
        returns (uint256 liquidatorFee, uint256 protocolFee, uint256 insuranceFundFee);

    /**
     * @notice 청산 가격 조회
     * @param positionKey 포지션 키
     * @return liquidationPrice 청산 가격
     */
    function getLiquidationPrice(bytes32 positionKey) external view returns (uint256 liquidationPrice);

    /**
     * @notice 청산자 보상 조회
     * @param liquidator 청산자 주소
     * @return pendingReward 대기 중인 보상
     */
    function getPendingReward(address liquidator) external view returns (uint256 pendingReward);

    /**
     * @notice 청산 통계 조회
     * @param marketId 마켓 ID
     * @return totalLiquidations 총 청산 수
     * @return totalLiquidatedValue 총 청산 가치
     * @return totalFeeCollected 총 수수료
     */
    function getLiquidationStats(uint32 marketId)
        external
        view
        returns (uint256 totalLiquidations, uint256 totalLiquidatedValue, uint256 totalFeeCollected);

    // ============ State-Changing Functions ============

    /**
     * @notice 포지션 청산
     * @param positionKey 청산할 포지션 키
     * @return liquidatedSize 청산된 크기
     * @return liquidatorReward 청산자 보상
     */
    function liquidate(bytes32 positionKey) external returns (uint256 liquidatedSize, uint256 liquidatorReward);

    /**
     * @notice 부분 청산
     * @param positionKey 청산할 포지션 키
     * @param liquidateSize 청산할 크기
     * @return actualLiquidatedSize 실제 청산된 크기
     * @return liquidatorReward 청산자 보상
     */
    function partialLiquidate(bytes32 positionKey, uint128 liquidateSize)
        external
        returns (uint256 actualLiquidatedSize, uint256 liquidatorReward);

    /**
     * @notice 배치 청산 (여러 포지션 동시 청산)
     * @param positionKeys 청산할 포지션 키 배열
     * @return liquidatedCount 청산된 포지션 수
     * @return totalReward 총 청산자 보상
     */
    function batchLiquidate(bytes32[] calldata positionKeys)
        external
        returns (uint256 liquidatedCount, uint256 totalReward);

    /**
     * @notice 청산자 보상 인출
     * @return amount 인출된 금액
     */
    function claimReward() external returns (uint256 amount);

    /**
     * @notice 청산 수수료율 설정 (Admin)
     * @param liquidatorFeeBps 청산자 수수료율 (BPS)
     * @param protocolFeeBps 프로토콜 수수료율 (BPS)
     * @param insuranceFeeBps 보험 기금 수수료율 (BPS)
     */
    function setLiquidationFees(uint16 liquidatorFeeBps, uint16 protocolFeeBps, uint16 insuranceFeeBps) external;

    /**
     * @notice 최소 청산 크기 설정 (Admin)
     * @param marketId 마켓 ID
     * @param minSize 최소 청산 크기
     */
    function setMinLiquidationSize(uint32 marketId, uint128 minSize) external;
}
