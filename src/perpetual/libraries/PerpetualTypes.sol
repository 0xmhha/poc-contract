// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PerpetualTypes
 * @author StableNet Team
 * @notice Perpetual Trading 시스템 타입 정의
 * @dev 모든 struct, enum, type alias 포함
 */
library PerpetualTypes {
    // ============ Enums ============

    /// @notice 마켓 상태
    enum MarketStatus {
        Inactive, // 0: 비활성화
        Active, // 1: 활성화 (거래 가능)
        Paused, // 2: 일시중지 (긴급)
        SettleOnly, // 3: 정산 전용 (포지션 정리만)
        Delisted // 4: 상장폐지 (최종)
    }

    /// @notice 포지션 방향
    enum PositionSide {
        Long, // 0: 롱 (매수)
        Short // 1: 숏 (매도)
    }

    /// @notice 포지션 상태
    enum PositionStatus {
        Open, // 0: 오픈
        Closed, // 1: 종료 (최종)
        Liquidated // 2: 청산됨 (최종)
    }

    /// @notice 주문 유형
    enum OrderType {
        Market, // 0: 시장가
        Limit, // 1: 지정가
        Stop, // 2: 스탑
        StopLimit, // 3: 스탑 리밋
        TakeProfit, // 4: 익절
        TakeProfitLimit // 5: 익절 리밋
    }

    /// @notice 주문 상태
    enum OrderStatus {
        Pending, // 0: 대기 중
        Open, // 1: 오더북에 등록됨
        PartiallyFilled, // 2: 부분 체결
        Filled, // 3: 전체 체결 (최종)
        Cancelled, // 4: 취소됨 (최종)
        Expired, // 5: 만료됨 (최종)
        Rejected // 6: 거절됨 (최종)
    }

    /// @notice 주문 실행 정책
    enum TimeInForce {
        GTC, // 0: Good Till Cancel
        IOC, // 1: Immediate Or Cancel
        FOK, // 2: Fill Or Kill
        PostOnly // 3: 메이커만 허용
    }

    /// @notice 마진 모드
    enum MarginMode {
        Isolated, // 0: 격리 마진
        Cross // 1: 교차 마진
    }

    // ============ Market Structs ============

    /// @notice 마켓 정보
    /// @dev 가스 최적화: 여러 슬롯 사용
    struct Market {
        uint256 marketId; // 마켓 ID
        address baseToken; // 기초 자산 (예: BTC)
        address quoteToken; // 결제 토큰 (예: USDC)
        uint64 createdAt; // 생성 시간
        MarketStatus status; // 마켓 상태
        MarketConfig config; // 마켓 설정
        MarketStats stats; // 마켓 통계
    }

    /// @notice 마켓 설정
    struct MarketConfig {
        uint32 maxLeverage; // 최대 레버리지 (1-100)
        uint32 maintenanceMarginBps; // 유지 마진율 (BPS)
        uint32 initialMarginBps; // 초기 마진율 (BPS)
        uint32 makerFeeBps; // 메이커 수수료 (BPS)
        uint32 takerFeeBps; // 테이커 수수료 (BPS)
        uint32 liquidationFeeBps; // 청산 수수료 (BPS)
        uint128 maxPositionSize; // 최대 포지션 크기
        uint128 maxOpenInterest; // 최대 OI
        uint64 fundingInterval; // 펀딩 주기 (초)
        uint32 maxFundingRateBps; // 최대 펀딩비율 (BPS)
    }

    /// @notice 마켓 통계 (실시간)
    struct MarketStats {
        uint128 openInterestLong; // 롱 OI
        uint128 openInterestShort; // 숏 OI
        uint128 totalVolume24h; // 24시간 거래량
        uint128 totalFees24h; // 24시간 수수료
        int64 cumulativeFundingIndex; // 누적 펀딩 인덱스
        uint64 lastFundingTime; // 마지막 펀딩 시간
        uint64 lastPriceUpdateTime; // 마지막 가격 업데이트 시간
    }

    // ============ Position Structs ============

    /// @notice 포지션 정보
    /// @dev 가스 최적화: slot 0 (160+32+8+8+8+8+32), slot 1 (128+128), slot 2 (128+64+64)
    struct Position {
        address trader; // 트레이더 주소
        uint32 marketId; // 마켓 ID
        PositionSide side; // 포지션 방향
        PositionStatus status; // 포지션 상태
        MarginMode marginMode; // 마진 모드
        uint8 leverage; // 레버리지 (1-100)
        uint32 reserved; // 예약
        uint128 size; // 포지션 크기 (base token)
        uint128 margin; // 마진 금액 (quote token)
        uint128 entryPrice; // 평균 진입가
        int64 lastFundingIndex; // 마지막 펀딩 인덱스
        uint64 openedAt; // 오픈 시간
    }

    /// @notice 포지션 ID 정보
    struct PositionId {
        address trader;
        uint32 marketId;
        PositionSide side;
    }

    /// @notice 포지션 결과 (계산된 값)
    struct PositionResult {
        int256 unrealizedPnL; // 미실현 손익
        int256 accumulatedFunding; // 누적 펀딩비
        uint256 marginRatio; // 마진 비율 (BPS)
        uint256 liquidationPrice; // 청산가
        uint256 equity; // 순자산
        bool isLiquidatable; // 청산 가능 여부
    }

    // ============ Order Structs ============

    /// @notice 주문 정보
    struct Order {
        bytes32 orderId; // 주문 ID
        address trader; // 트레이더 주소
        uint32 marketId; // 마켓 ID
        PositionSide side; // 주문 방향
        OrderType orderType; // 주문 유형
        OrderStatus status; // 주문 상태
        TimeInForce timeInForce; // 실행 정책
        bool reduceOnly; // 포지션 감소만 허용
        uint128 size; // 주문 수량
        uint128 filledSize; // 체결된 수량
        uint128 price; // 지정 가격 (시장가 주문은 0)
        uint128 triggerPrice; // 트리거 가격 (스탑/TP)
        uint128 averagePrice; // 평균 체결가
        uint64 createdAt; // 생성 시간
        uint64 expiresAt; // 만료 시간 (0 = GTC)
    }

    /// @notice 주문 생성 파라미터
    struct OrderParams {
        uint32 marketId;
        PositionSide side;
        OrderType orderType;
        TimeInForce timeInForce;
        bool reduceOnly;
        uint128 size;
        uint128 price;
        uint128 triggerPrice;
        uint64 expiration;
        uint128 maxSlippage; // 최대 슬리피지 (BPS)
    }

    /// @notice 주문 체결 정보
    struct Fill {
        bytes32 orderId;
        uint128 size;
        uint128 price;
        uint128 fee;
        bool isMaker;
        uint64 timestamp;
    }

    // ============ Margin Structs ============

    /// @notice 교차 마진 계정
    struct CrossMarginAccount {
        address trader;
        uint256 balance; // 가용 잔액
        uint256 lockedMargin; // 포지션에 락된 마진
        uint256 unrealizedPnL; // 총 미실현 손익
        uint256 totalEquity; // 총 순자산
    }

    /// @notice 격리 마진 계정 (포지션별)
    struct IsolatedMarginAccount {
        uint256 margin; // 격리된 마진
        uint256 additionalMargin; // 추가 마진
    }

    // ============ Funding Structs ============

    /// @notice 펀딩 스냅샷 (TWAP용)
    struct FundingSnapshot {
        int64 fundingRate; // 펀딩비율 (BPS, 부호 있음)
        uint64 timestamp; // 스냅샷 시간
        uint128 markPrice; // 마크 가격
        uint128 indexPrice; // 인덱스 가격
    }

    /// @notice 펀딩 정산 결과
    struct FundingSettlementResult {
        int256 fundingPayment; // 펀딩 지불액 (양수: 지불, 음수: 수령)
        int64 newFundingIndex; // 새 펀딩 인덱스
        uint64 settledAt; // 정산 시간
    }

    /// @notice 펀딩 히스토리
    struct FundingHistory {
        uint32 marketId;
        int64 fundingRate; // 펀딩비율
        int64 cumulativeFundingIndex; // 누적 펀딩 인덱스
        uint64 timestamp;
        uint128 markPrice;
        uint128 indexPrice;
    }

    // ============ Price Structs ============

    /// @notice 가격 데이터
    struct PriceData {
        uint128 price; // 가격
        uint64 timestamp; // 업데이트 시간
        uint8 decimals; // 소수점 자릿수
        uint8 source; // 가격 소스 (0: Chainlink, 1: Custom)
    }

    /// @notice TWAP 데이터
    struct TWAPData {
        uint128 twapPrice; // TWAP 가격
        uint64 startTime; // 시작 시간
        uint64 endTime; // 종료 시간
        uint32 sampleCount; // 샘플 수
    }

    /// @notice 마크 가격 데이터
    struct MarkPriceData {
        uint128 markPrice; // 마크 가격
        uint128 indexPrice; // 인덱스 가격
        int128 basis; // Basis (Mark - Index)
        int128 emaBasis; // EMA Basis
        uint64 timestamp; // 업데이트 시간
    }

    // ============ Liquidation Structs ============

    /// @notice 청산 정보
    struct LiquidationInfo {
        bytes32 positionKey; // 포지션 키
        address trader; // 트레이더
        uint32 marketId; // 마켓 ID
        PositionSide side; // 포지션 방향
        uint128 size; // 청산 크기
        uint128 price; // 청산 가격
        int256 pnl; // 실현 손익
        uint256 liquidationFee; // 청산 수수료
        uint256 remainingMargin; // 잔여 마진
        bool isPartial; // 부분 청산 여부
        address liquidator; // 청산자
        uint64 timestamp; // 청산 시간
    }

    /// @notice ADL 정보
    struct ADLInfo {
        bytes32 positionKey; // 포지션 키
        address trader; // 트레이더
        uint256 priority; // ADL 우선순위 (높을수록 먼저)
        int256 unrealizedPnL; // 미실현 손익
        uint256 leverage; // 현재 레버리지
    }

    // ============ Insurance Fund Structs ============

    /// @notice 보험 기금 상태
    struct InsuranceFundState {
        uint256 balance; // 기금 잔액
        uint256 totalDeposits; // 총 입금액
        uint256 totalWithdrawals; // 총 출금액
        uint256 totalLossCovered; // 총 보전 손실
        uint64 lastUpdateTime; // 마지막 업데이트 시간
    }

    // ============ Fee Structs ============

    /// @notice 수수료 정보
    struct FeeInfo {
        uint256 tradingFee; // 거래 수수료
        uint256 fundingFee; // 펀딩 수수료
        uint256 liquidationFee; // 청산 수수료
        bool isMaker; // 메이커 여부
    }

    /// @notice 수수료 분배 설정
    struct FeeDistribution {
        uint32 protocolShareBps; // 프로토콜 비율 (BPS)
        uint32 insuranceShareBps; // 보험 기금 비율 (BPS)
        uint32 stakingShareBps; // 스테이킹 비율 (BPS)
    }

    // ============ Risk Structs ============

    /// @notice 리스크 파라미터
    struct RiskParams {
        uint128 maxPositionSize; // 최대 포지션 크기
        uint128 maxAccountOpenInterest; // 계정당 최대 OI
        uint128 maxMarketOpenInterest; // 마켓 최대 OI
        uint32 maxLeverage; // 최대 레버리지
        uint32 priceDeviationThreshold; // 가격 편차 임계값 (BPS)
        bool circuitBreakerEnabled; // 서킷 브레이커 활성화
    }

    // ============ Type Aliases ============

    /// @notice 포지션 키 타입 (trader + marketId + side의 해시)
    type PositionKey is bytes32;

    /// @notice 주문 ID 타입
    type OrderId is bytes32;

    /// @notice 마켓 ID 타입
    type MarketId is uint32;
}
