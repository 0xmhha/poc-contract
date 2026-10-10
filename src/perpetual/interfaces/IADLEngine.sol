// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";

/**
 * @title IADLEngine
 * @author StableNet Team
 * @notice 자동 디레버리징(ADL) 엔진 인터페이스
 */
interface IADLEngine {
    // ============ View Functions ============

    /**
     * @notice ADL 활성화 상태 조회
     * @param marketId 마켓 ID
     * @return isActive ADL 활성화 여부
     */
    function isADLActive(uint32 marketId) external view returns (bool isActive);

    /**
     * @notice ADL 우선순위 조회
     * @param positionKey 포지션 키
     * @return priority ADL 우선순위 (높을수록 먼저 ADL됨)
     */
    function getADLPriority(bytes32 positionKey) external view returns (uint256 priority);

    /**
     * @notice ADL 대상 포지션 목록 조회
     * @param marketId 마켓 ID
     * @param side 포지션 방향
     * @param limit 최대 조회 수
     * @return positionKeys ADL 대상 포지션 키 배열 (우선순위순)
     */
    function getADLTargets(uint32 marketId, PerpetualTypes.PositionSide side, uint256 limit)
        external
        view
        returns (bytes32[] memory positionKeys);

    /**
     * @notice ADL 정보 조회
     * @param positionKey 포지션 키
     * @return info ADL 정보
     */
    function getADLInfo(bytes32 positionKey) external view returns (PerpetualTypes.ADLInfo memory info);

    /**
     * @notice ADL 트리거 조건 충족 여부
     * @param marketId 마켓 ID
     * @return shouldTrigger ADL 트리거 필요 여부
     * @return deficit 보험 기금 부족액
     */
    function shouldTriggerADL(uint32 marketId) external view returns (bool shouldTrigger, uint256 deficit);

    /**
     * @notice ADL 레벨 조회 (1-5, 높을수록 더 많은 포지션 ADL 대상)
     * @param marketId 마켓 ID
     * @return level ADL 레벨
     */
    function getADLLevel(uint32 marketId) external view returns (uint8 level);

    /**
     * @notice ADL 통계 조회
     * @param marketId 마켓 ID
     * @return totalADLEvents 총 ADL 이벤트 수
     * @return totalADLVolume 총 ADL 거래량
     * @return lastADLTime 마지막 ADL 시간
     */
    function getADLStats(uint32 marketId)
        external
        view
        returns (uint256 totalADLEvents, uint256 totalADLVolume, uint256 lastADLTime);

    // ============ State-Changing Functions ============

    /**
     * @notice ADL 실행 (단일 포지션)
     * @param bankruptPositionKey 파산 포지션 키
     * @param counterpartyPositionKey 상대방 포지션 키 (ADL 대상)
     * @param adlSize ADL 크기
     * @return executedSize 실행된 크기
     */
    function executeADL(bytes32 bankruptPositionKey, bytes32 counterpartyPositionKey, uint128 adlSize)
        external
        returns (uint128 executedSize);

    /**
     * @notice ADL 배치 실행
     * @param bankruptPositionKey 파산 포지션 키
     * @param counterpartyPositionKeys 상대방 포지션 키 배열
     * @param adlSizes ADL 크기 배열
     * @return totalExecuted 총 실행된 크기
     */
    function batchExecuteADL(
        bytes32 bankruptPositionKey,
        bytes32[] calldata counterpartyPositionKeys,
        uint128[] calldata adlSizes
    ) external returns (uint128 totalExecuted);

    /**
     * @notice 자동 ADL 실행 (Keeper 호출)
     * @param bankruptPositionKey 파산 포지션 키
     * @return totalExecuted 총 실행된 크기
     * @return adlCount ADL된 포지션 수
     */
    function autoExecuteADL(bytes32 bankruptPositionKey) external returns (uint128 totalExecuted, uint256 adlCount);

    /**
     * @notice ADL 활성화/비활성화 (Admin)
     * @param marketId 마켓 ID
     * @param active 활성화 여부
     */
    function setADLActive(uint32 marketId, bool active) external;

    /**
     * @notice ADL 레벨 임계값 설정 (Admin)
     * @param level ADL 레벨 (1-5)
     * @param threshold 임계값 (보험 기금 비율, BPS)
     */
    function setADLLevelThreshold(uint8 level, uint256 threshold) external;

    /**
     * @notice 우선순위 큐 업데이트 (Keeper 호출)
     * @param marketId 마켓 ID
     * @param side 포지션 방향
     */
    function updatePriorityQueue(uint32 marketId, PerpetualTypes.PositionSide side) external;
}
