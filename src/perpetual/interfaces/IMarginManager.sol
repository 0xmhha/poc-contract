// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";

/**
 * @title IMarginManager
 * @author StableNet Team
 * @notice 마진 관리 인터페이스
 */
interface IMarginManager {
    // ============ View Functions ============

    /**
     * @notice 교차 마진 계정 조회
     * @param trader 트레이더 주소
     * @return account 교차 마진 계정 정보
     */
    function getCrossMarginAccount(address trader)
        external
        view
        returns (PerpetualTypes.CrossMarginAccount memory account);

    /**
     * @notice 가용 마진 조회
     * @param trader 트레이더 주소
     * @return available 가용 마진
     */
    function getAvailableMargin(address trader) external view returns (uint256 available);

    /**
     * @notice 락된 마진 조회
     * @param trader 트레이더 주소
     * @return locked 락된 마진
     */
    function getLockedMargin(address trader) external view returns (uint256 locked);

    /**
     * @notice 총 자본 조회 (잔액 + 미실현 PnL)
     * @param trader 트레이더 주소
     * @return equity 총 자본
     */
    function getTotalEquity(address trader) external view returns (uint256 equity);

    /**
     * @notice 교차 마진 비율 조회
     * @param trader 트레이더 주소
     * @return ratio 마진 비율 (BPS)
     */
    function getCrossMarginRatio(address trader) external view returns (uint256 ratio);

    /**
     * @notice 격리 마진 조회
     * @param positionKey 포지션 키
     * @return margin 격리 마진
     */
    function getIsolatedMargin(bytes32 positionKey) external view returns (uint256 margin);

    /**
     * @notice 마진 모드 조회
     * @param trader 트레이더 주소
     * @param marketId 마켓 ID
     * @return mode 마진 모드
     */
    function getMarginMode(address trader, uint32 marketId) external view returns (PerpetualTypes.MarginMode mode);

    /**
     * @notice 필요 마진 계산
     * @param size 포지션 크기
     * @param price 가격
     * @param leverage 레버리지
     * @return required 필요 마진
     */
    function calculateRequiredMargin(uint256 size, uint256 price, uint256 leverage)
        external
        pure
        returns (uint256 required);

    /**
     * @notice 추가 가능 마진 조회
     * @param trader 트레이더 주소
     * @param positionKey 포지션 키 (격리 마진인 경우)
     * @return removable 제거 가능 마진
     */
    function getRemovableMargin(address trader, bytes32 positionKey) external view returns (uint256 removable);

    // ============ State-Changing Functions ============

    /**
     * @notice 마진 입금
     * @param trader 트레이더 주소
     * @param amount 입금 금액
     */
    function depositMargin(address trader, uint256 amount) external;

    /**
     * @notice 마진 출금
     * @param trader 트레이더 주소
     * @param amount 출금 금액
     */
    function withdrawMargin(address trader, uint256 amount) external;

    /**
     * @notice 마진 락
     * @param trader 트레이더 주소
     * @param amount 락 금액
     */
    function lockMargin(address trader, uint256 amount) external;

    /**
     * @notice 마진 언락
     * @param trader 트레이더 주소
     * @param amount 언락 금액
     */
    function unlockMargin(address trader, uint256 amount) external;

    /**
     * @notice 포지션 마진 추가 (격리 마진)
     * @param positionKey 포지션 키
     * @param amount 추가 금액
     */
    function addPositionMargin(bytes32 positionKey, uint256 amount) external;

    /**
     * @notice 포지션 마진 제거 (격리 마진)
     * @param positionKey 포지션 키
     * @param amount 제거 금액
     */
    function removePositionMargin(bytes32 positionKey, uint256 amount) external;

    /**
     * @notice 마진 모드 설정
     * @param trader 트레이더 주소
     * @param marketId 마켓 ID
     * @param mode 새 마진 모드
     */
    function setMarginMode(address trader, uint32 marketId, PerpetualTypes.MarginMode mode) external;

    /**
     * @notice PnL 반영 (정산 시)
     * @param trader 트레이더 주소
     * @param pnl 실현 손익
     */
    function realizePnL(address trader, int256 pnl) external;

    /**
     * @notice 미실현 PnL 업데이트
     * @param trader 트레이더 주소
     * @param unrealizedPnL 새 미실현 손익
     */
    function updateUnrealizedPnL(address trader, int256 unrealizedPnL) external;
}
