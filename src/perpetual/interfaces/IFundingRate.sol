// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";

/**
 * @title IFundingRate
 * @author StableNet Team
 * @notice 펀딩비 계산 및 정산 인터페이스
 */
interface IFundingRate {
    // ============ View Functions ============

    /**
     * @notice 현재 펀딩 비율 조회
     * @param marketId 마켓 ID
     * @return fundingRate 펀딩 비율 (BPS, 부호 있음)
     */
    function getCurrentFundingRate(uint32 marketId) external view returns (int64 fundingRate);

    /**
     * @notice TWAP 펀딩 비율 조회
     * @param marketId 마켓 ID
     * @return twapFundingRate TWAP 펀딩 비율 (BPS, 부호 있음)
     */
    function getTWAPFundingRate(uint32 marketId) external view returns (int64 twapFundingRate);

    /**
     * @notice 누적 펀딩 인덱스 조회
     * @param marketId 마켓 ID
     * @return cumulativeFundingIndex 누적 펀딩 인덱스
     */
    function getCumulativeFundingIndex(uint32 marketId) external view returns (int64 cumulativeFundingIndex);

    /**
     * @notice 다음 펀딩 시간 조회
     * @param marketId 마켓 ID
     * @return nextFundingTime 다음 펀딩 시간
     */
    function getNextFundingTime(uint32 marketId) external view returns (uint256 nextFundingTime);

    /**
     * @notice 마지막 펀딩 시간 조회
     * @param marketId 마켓 ID
     * @return lastFundingTime 마지막 펀딩 시간
     */
    function getLastFundingTime(uint32 marketId) external view returns (uint256 lastFundingTime);

    /**
     * @notice 예상 펀딩 지불액 조회
     * @param positionKey 포지션 키
     * @return estimatedPayment 예상 펀딩 지불액
     */
    function getEstimatedFundingPayment(bytes32 positionKey) external view returns (int256 estimatedPayment);

    /**
     * @notice 펀딩 히스토리 조회
     * @param marketId 마켓 ID
     * @param startTime 시작 시간
     * @param endTime 종료 시간
     * @return history 펀딩 히스토리 배열
     */
    function getFundingHistory(uint32 marketId, uint64 startTime, uint64 endTime)
        external
        view
        returns (PerpetualTypes.FundingHistory[] memory history);

    /**
     * @notice 펀딩 스냅샷 수 조회
     * @param marketId 마켓 ID
     * @return count 스냅샷 수
     */
    function getFundingSnapshotCount(uint32 marketId) external view returns (uint256 count);

    /**
     * @notice 펀딩 정산 가능 여부 확인
     * @param marketId 마켓 ID
     * @return canSettle 정산 가능 여부
     */
    function canSettleFunding(uint32 marketId) external view returns (bool canSettle);

    // ============ State-Changing Functions ============

    /**
     * @notice 펀딩비 정산 (Keeper 호출)
     * @param marketId 마켓 ID
     * @return newFundingRate 새 펀딩 비율
     * @return newCumulativeFundingIndex 새 누적 펀딩 인덱스
     */
    function settleFunding(uint32 marketId) external returns (int64 newFundingRate, int64 newCumulativeFundingIndex);

    /**
     * @notice 펀딩 스냅샷 기록 (Keeper 호출)
     * @param marketId 마켓 ID
     */
    function recordFundingSnapshot(uint32 marketId) external;

    /**
     * @notice 포지션 펀딩비 정산
     * @param positionKey 포지션 키
     * @return fundingPayment 펀딩 지불액
     */
    function settlePositionFunding(bytes32 positionKey) external returns (int256 fundingPayment);

    /**
     * @notice 펀딩 주기 설정
     * @param marketId 마켓 ID
     * @param interval 새 펀딩 주기 (초)
     */
    function setFundingInterval(uint32 marketId, uint64 interval) external;

    /**
     * @notice 최대 펀딩 비율 설정
     * @param marketId 마켓 ID
     * @param maxRate 새 최대 펀딩 비율 (BPS)
     */
    function setMaxFundingRate(uint32 marketId, uint32 maxRate) external;
}
