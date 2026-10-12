// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IInsuranceFund
 * @author StableNet Team
 * @notice 보험 기금 관리 인터페이스
 */
interface IInsuranceFund {
    // ============ View Functions ============

    /**
     * @notice 총 보험 기금 잔액 조회
     * @return balance 총 잔액
     */
    function getTotalBalance() external view returns (uint256 balance);

    /**
     * @notice 마켓별 보험 기금 잔액 조회
     * @param marketId 마켓 ID
     * @return balance 마켓별 잔액
     */
    function getMarketBalance(uint32 marketId) external view returns (uint256 balance);

    /**
     * @notice 보험 기금 사용 가능 금액 조회
     * @return available 사용 가능 금액
     */
    function getAvailableBalance() external view returns (uint256 available);

    /**
     * @notice 보험 기금 사용 이력 조회
     * @param startTime 시작 시간
     * @param endTime 종료 시간
     * @return totalUsed 총 사용량
     * @return totalDeposited 총 입금량
     */
    function getUsageHistory(uint64 startTime, uint64 endTime)
        external
        view
        returns (uint256 totalUsed, uint256 totalDeposited);

    /**
     * @notice 보험 기금 목표 금액 조회
     * @return targetAmount 목표 금액
     */
    function getTargetAmount() external view returns (uint256 targetAmount);

    /**
     * @notice 보험 기금 달성률 조회
     * @return ratio 달성률 (BPS)
     */
    function getFundingRatio() external view returns (uint256 ratio);

    /**
     * @notice ADL 트리거 임계값 조회
     * @return threshold ADL 트리거 임계값
     */
    function getADLThreshold() external view returns (uint256 threshold);

    /**
     * @notice ADL 트리거 여부 확인
     * @return shouldTrigger ADL 트리거 필요 여부
     */
    function shouldTriggerADL() external view returns (bool shouldTrigger);

    // ============ State-Changing Functions ============

    /**
     * @notice 보험 기금 입금 (청산 수익 등)
     * @param marketId 마켓 ID
     * @param amount 입금 금액
     */
    function deposit(uint32 marketId, uint256 amount) external;

    /**
     * @notice 보험 기금 사용 (청산 손실 보전)
     * @param marketId 마켓 ID
     * @param amount 사용 금액
     * @return actualUsed 실제 사용된 금액
     */
    /// @dev Transfers the covered collateral to the authorized caller.
    function coverLoss(uint32 marketId, uint256 amount) external returns (uint256 actualUsed);

    /**
     * @notice 보험 기금 수동 입금 (Admin)
     * @param amount 입금 금액
     */
    function adminDeposit(uint256 amount) external;

    /**
     * @notice 보험 기금 인출 (Admin, 긴급 상황)
     * @param amount 인출 금액
     * @param recipient 수령자 주소
     */
    function adminWithdraw(uint256 amount, address recipient) external;

    /**
     * @notice 목표 금액 설정 (Admin)
     * @param newTarget 새 목표 금액
     */
    function setTargetAmount(uint256 newTarget) external;

    /**
     * @notice ADL 임계값 설정 (Admin)
     * @param newThreshold 새 임계값
     */
    function setADLThreshold(uint256 newThreshold) external;

    /**
     * @notice 마켓간 기금 재분배 (Admin)
     * @param fromMarketId 출금 마켓 ID
     * @param toMarketId 입금 마켓 ID
     * @param amount 이동 금액
     */
    function reallocate(uint32 fromMarketId, uint32 toMarketId, uint256 amount) external;
}
