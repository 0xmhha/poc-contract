// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Constants
 * @author StableNet Team
 * @notice 시스템 전역 상수 정의
 * @dev Enterprise Stealth와 Perpetual Trading 시스템에서 공유하는 상수
 */
library Constants {
    // ============ Precision Constants ============

    /// @notice 고정 소수점 연산 정밀도 (18 decimals)
    uint256 public constant PRECISION = 1e18;

    /// @notice 베이시스 포인트 정밀도 (1 BPS = 0.01%)
    uint256 public constant BPS_PRECISION = 10_000;

    /// @notice 퍼센트 정밀도 (1% = 100)
    uint256 public constant PERCENT_PRECISION = 100;

    // ============ Time Constants ============

    /// @notice 하루 (초)
    uint256 public constant DAY = 1 days;

    /// @notice 시간 (초)
    uint256 public constant HOUR = 1 hours;

    /// @notice 분 (초)
    uint256 public constant MINUTE = 1 minutes;

    // ============ Stealth System Constants ============

    /// @notice 예치 취소 가능 기간 (24시간)
    uint256 public constant DEPOSIT_CANCEL_PERIOD = 24 hours;

    /// @notice 비상 모드 쿨다운 (24시간)
    uint256 public constant EMERGENCY_COOLDOWN = 24 hours;

    /// @notice 출금 요청 만료 기간 (7일)
    uint256 public constant WITHDRAWAL_EXPIRY = 7 days;

    /// @notice 최대 재시도 횟수
    uint256 public constant MAX_RETRY_COUNT = 3;

    /// @notice 기본 출금 지연 시간 (1시간)
    uint256 public constant DEFAULT_WITHDRAWAL_DELAY = 1 hours;

    /// @notice 소유권 증명 기본 유효 기간 (30분)
    uint256 public constant DEFAULT_PROOF_VALIDITY = 30 minutes;

    // ============ Perpetual System Constants ============

    /// @notice 기본 펀딩 주기 (8시간)
    uint256 public constant DEFAULT_FUNDING_INTERVAL = 8 hours;

    /// @notice 최대 펀딩 비율 (1% = 100 BPS)
    uint256 public constant MAX_FUNDING_RATE = 100;

    /// @notice 청산 인센티브 (0.5% = 50 BPS)
    uint256 public constant LIQUIDATION_INCENTIVE = 50;

    /// @notice ADL 활성화 임계값 (보험 기금의 10%)
    uint256 public constant ADL_ACTIVATION_THRESHOLD = 1000; // 10% in BPS

    /// @notice TWAP 스냅샷 간격 (15분)
    uint256 public constant TWAP_SNAPSHOT_INTERVAL = 15 minutes;

    /// @notice 최대 TWAP 스냅샷 수
    uint256 public constant MAX_TWAP_SNAPSHOTS = 100;

    /// @notice EMA 기간 (샘플 수)
    uint256 public constant EMA_PERIOD = 20;

    /// @notice 가격 유효 시간 (30분)
    uint256 public constant PRICE_STALENESS_THRESHOLD = 30 minutes;

    /// @notice 최대 레버리지 (100x)
    uint256 public constant MAX_LEVERAGE = 100;

    /// @notice 최소 레버리지 (1x)
    uint256 public constant MIN_LEVERAGE = 1;

    /// @notice 기본 유지 마진율 (0.5% = 50 BPS)
    uint256 public constant DEFAULT_MAINTENANCE_MARGIN = 50;

    /// @notice 기본 초기 마진율 (1% = 100 BPS)
    uint256 public constant DEFAULT_INITIAL_MARGIN = 100;

    /// @notice 기본 메이커 수수료 (0.02% = 2 BPS)
    uint256 public constant DEFAULT_MAKER_FEE = 2;

    /// @notice 기본 테이커 수수료 (0.05% = 5 BPS)
    uint256 public constant DEFAULT_TAKER_FEE = 5;

    /// @notice 청산 수수료 (0.5% = 50 BPS)
    uint256 public constant LIQUIDATION_FEE = 50;

    /// @notice 최대 수수료율 (1% = 100 BPS)
    uint256 public constant MAX_FEE_RATE = 100;

    // ============ Fee Distribution Constants ============

    /// @notice 프로토콜 수수료 비율 (30%)
    uint256 public constant PROTOCOL_FEE_SHARE = 3000;

    /// @notice 보험 기금 수수료 비율 (40%)
    uint256 public constant INSURANCE_FEE_SHARE = 4000;

    /// @notice 스테이킹 수수료 비율 (30%)
    uint256 public constant STAKING_FEE_SHARE = 3000;

    // ============ Limit Constants ============

    /// @notice 최대 오픈 포지션 수 (사용자당)
    uint256 public constant MAX_OPEN_POSITIONS = 50;

    /// @notice 최대 주문 수 (사용자당)
    uint256 public constant MAX_OPEN_ORDERS = 100;

    /// @notice 최대 서명자 수 (MultiSig)
    uint256 public constant MAX_SIGNERS = 10;

    /// @notice 최소 서명자 수 (MultiSig)
    uint256 public constant MIN_SIGNERS = 1;
}
