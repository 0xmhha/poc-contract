// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PerpetualTypes } from "./PerpetualTypes.sol";

/**
 * @title PerpetualEvents
 * @author StableNet Team
 * @notice Perpetual Trading 시스템 이벤트 정의
 * @dev 인덱싱과 오프체인 모니터링을 위한 이벤트
 */
library PerpetualEvents {
    // ============ Market Events ============

    /// @notice 마켓 생성됨
    /// @param marketId 마켓 ID
    /// @param baseToken 기초 자산 주소
    /// @param quoteToken 결제 토큰 주소
    /// @param maxLeverage 최대 레버리지
    /// @dev Markets are synthetic, so baseToken is address(0); read the base symbol from
    ///      PerpetualEngine.getMarketSymbols(marketId).
    event MarketCreated(
        uint32 indexed marketId, address indexed baseToken, address indexed quoteToken, uint32 maxLeverage
    );

    /// @notice 마켓 상태 변경됨
    /// @param marketId 마켓 ID
    /// @param oldStatus 이전 상태
    /// @param newStatus 새 상태
    event MarketStatusChanged(
        uint32 indexed marketId, PerpetualTypes.MarketStatus oldStatus, PerpetualTypes.MarketStatus newStatus
    );

    /// @notice 마켓 설정 업데이트됨
    /// @param marketId 마켓 ID
    /// @param configKey 설정 키
    /// @param oldValue 이전 값
    /// @param newValue 새 값
    event MarketConfigUpdated(uint32 indexed marketId, bytes32 indexed configKey, uint256 oldValue, uint256 newValue);

    // ============ Position Events ============

    /// @notice 포지션 오픈됨
    /// @param positionKey 포지션 키
    /// @param trader 트레이더 주소
    /// @param marketId 마켓 ID
    /// @param side 포지션 방향
    /// @param size 포지션 크기
    /// @param entryPrice 진입가
    /// @param margin 마진 금액
    /// @param leverage 레버리지
    event PositionOpened(
        bytes32 indexed positionKey,
        address indexed trader,
        uint32 indexed marketId,
        PerpetualTypes.PositionSide side,
        uint256 size,
        uint256 entryPrice,
        uint256 margin,
        uint8 leverage
    );

    /// @notice 포지션 증가됨
    /// @param positionKey 포지션 키
    /// @param trader 트레이더 주소
    /// @param addedSize 추가된 크기
    /// @param addedMargin 추가된 마진
    /// @param newEntryPrice 새 평균 진입가
    /// @param newSize 새 총 크기
    event PositionIncreased(
        bytes32 indexed positionKey,
        address indexed trader,
        uint256 addedSize,
        uint256 addedMargin,
        uint256 newEntryPrice,
        uint256 newSize
    );

    /// @notice 포지션 감소됨
    /// @param positionKey 포지션 키
    /// @param trader 트레이더 주소
    /// @param reducedSize 감소된 크기
    /// @param exitPrice 청산가
    /// @param realizedPnL 실현 손익
    /// @param remainingSize 남은 크기
    event PositionDecreased(
        bytes32 indexed positionKey,
        address indexed trader,
        uint256 reducedSize,
        uint256 exitPrice,
        int256 realizedPnL,
        uint256 remainingSize
    );

    /// @notice 포지션 종료됨
    /// @param positionKey 포지션 키
    /// @param trader 트레이더 주소
    /// @param exitPrice 청산가
    /// @param realizedPnL 실현 손익
    /// @param fee 수수료
    event PositionClosed(
        bytes32 indexed positionKey, address indexed trader, uint256 exitPrice, int256 realizedPnL, uint256 fee
    );

    /// @notice 포지션 마진 추가됨
    /// @param positionKey 포지션 키
    /// @param trader 트레이더 주소
    /// @param addedMargin 추가된 마진
    /// @param newMargin 새 총 마진
    event MarginAdded(bytes32 indexed positionKey, address indexed trader, uint256 addedMargin, uint256 newMargin);

    /// @notice 포지션 마진 제거됨
    /// @param positionKey 포지션 키
    /// @param trader 트레이더 주소
    /// @param removedMargin 제거된 마진
    /// @param newMargin 새 총 마진
    event MarginRemoved(bytes32 indexed positionKey, address indexed trader, uint256 removedMargin, uint256 newMargin);

    // ============ Order Events ============

    /// @notice 주문 생성됨
    /// @param orderId 주문 ID
    /// @param trader 트레이더 주소
    /// @param marketId 마켓 ID
    /// @param side 주문 방향
    /// @param orderType 주문 유형
    /// @param size 주문 수량
    /// @param price 지정 가격
    event OrderCreated(
        bytes32 indexed orderId,
        address indexed trader,
        uint32 indexed marketId,
        PerpetualTypes.PositionSide side,
        PerpetualTypes.OrderType orderType,
        uint256 size,
        uint256 price
    );

    /// @notice 주문 부분 체결됨
    /// @param orderId 주문 ID
    /// @param filledSize 이번 체결 수량
    /// @param totalFilledSize 총 체결 수량
    /// @param remainingSize 남은 수량
    /// @param fillPrice 체결 가격
    event OrderPartiallyFilled(
        bytes32 indexed orderId, uint256 filledSize, uint256 totalFilledSize, uint256 remainingSize, uint256 fillPrice
    );

    /// @notice 주문 취소됨
    /// @param orderId 주문 ID
    /// @param trader 트레이더 주소
    /// @param reason 취소 사유
    event OrderCancelled(bytes32 indexed orderId, address indexed trader, string reason);

    /// @notice 주문 만료됨
    /// @param orderId 주문 ID
    /// @param trader 트레이더 주소
    /// @param expiredAt 만료 시간
    event OrderExpired(bytes32 indexed orderId, address indexed trader, uint256 expiredAt);

    /// @notice 주문 수정됨
    /// @param orderId 주문 ID
    /// @param trader 트레이더 주소
    /// @param newSize 새 수량
    /// @param newPrice 새 가격
    event OrderModified(bytes32 indexed orderId, address indexed trader, uint256 newSize, uint256 newPrice);

    /// @notice 주문 트리거됨 (스탑/TP)
    /// @param orderId 주문 ID
    /// @param currentPrice 현재 가격
    /// @param triggerPrice 트리거 가격
    event OrderTriggered(bytes32 indexed orderId, uint128 currentPrice, uint128 triggerPrice);

    /// @notice 시장가 주문 실행됨
    /// @param trader 트레이더 주소
    /// @param marketId 마켓 ID
    /// @param side 주문 방향
    /// @param fillSize 체결 수량
    /// @param fillPrice 체결 가격
    event MarketOrderExecuted(
        address indexed trader,
        uint32 indexed marketId,
        PerpetualTypes.PositionSide side,
        uint128 fillSize,
        uint128 fillPrice
    );

    /// @notice 주문 매칭됨
    /// @param makerOrderId 메이커 주문 ID
    /// @param takerOrderId 테이커 주문 ID
    /// @param matchSize 매칭 수량
    /// @param matchPrice 매칭 가격
    event OrdersMatched(
        bytes32 indexed makerOrderId, bytes32 indexed takerOrderId, uint128 matchSize, uint128 matchPrice
    );

    // ============ Liquidation Events ============

    /// @notice 포지션 청산됨
    /// @param positionKey 포지션 키
    /// @param trader 트레이더 주소
    /// @param liquidator 청산자 주소
    /// @param size 청산 크기
    /// @param price 청산 가격
    /// @param pnl 실현 손익
    /// @param liquidationFee 청산 수수료
    event PositionLiquidated(
        bytes32 indexed positionKey,
        address indexed trader,
        address indexed liquidator,
        uint256 size,
        uint256 price,
        int256 pnl,
        uint256 liquidationFee
    );

    /// @notice 부분 청산됨
    /// @param positionKey 포지션 키
    /// @param liquidatedSize 청산된 크기
    /// @param remainingSize 남은 크기
    /// @param price 청산 가격
    event PartialLiquidation(bytes32 indexed positionKey, uint256 liquidatedSize, uint256 remainingSize, uint256 price);

    /// @notice 청산 보상 지급됨
    /// @param liquidator 청산자 주소
    /// @param positionKey 포지션 키
    /// @param reward 보상 금액
    event LiquidationRewardPaid(address indexed liquidator, bytes32 indexed positionKey, uint256 reward);

    // ============ ADL Events ============

    /// @notice ADL 실행됨
    /// @param positionKey 청산된 포지션 키
    /// @param counterpartyKey 상대방 포지션 키
    /// @param marketId 마켓 ID
    /// @param size ADL 크기
    /// @param price ADL 가격
    event ADLExecuted(
        bytes32 indexed positionKey,
        bytes32 indexed counterpartyKey,
        uint32 indexed marketId,
        uint256 size,
        uint256 price
    );

    /// @notice ADL 우선순위 업데이트됨
    /// @param marketId 마켓 ID
    /// @param side 포지션 방향
    /// @param topPriority 최고 우선순위 값
    event ADLPriorityUpdated(uint32 indexed marketId, PerpetualTypes.PositionSide side, uint256 topPriority);

    // ============ Insurance Fund Events ============

    /// @notice 보험 기금 입금됨
    /// @param amount 입금 금액
    /// @param source 입금 출처 (청산 잔여금 등)
    /// @param newBalance 새 잔액
    event InsuranceFundDeposit(uint256 amount, string source, uint256 newBalance);

    /// @notice 보험 기금 출금됨
    /// @param amount 출금 금액
    /// @param purpose 출금 목적 (손실 보전 등)
    /// @param newBalance 새 잔액
    event InsuranceFundWithdrawal(uint256 amount, string purpose, uint256 newBalance);

    /// @notice 손실 보전됨
    /// @param positionKey 포지션 키
    /// @param amount 보전 금액
    /// @param remainingFund 남은 기금
    event LossCovered(bytes32 indexed positionKey, uint256 amount, uint256 remainingFund);

    // ============ Funding Events ============

    /// @notice 펀딩비 정산됨
    /// @param marketId 마켓 ID
    /// @param fundingRate 펀딩 비율 (BPS, 부호 있음)
    /// @param cumulativeFundingIndex 누적 펀딩 인덱스
    /// @param markPrice 마크 가격
    /// @param indexPrice 인덱스 가격
    event FundingSettled(
        uint32 indexed marketId, int64 fundingRate, int64 cumulativeFundingIndex, uint256 markPrice, uint256 indexPrice
    );

    /// @notice 포지션 펀딩비 정산됨
    /// @param positionKey 포지션 키
    /// @param trader 트레이더 주소
    /// @param fundingPayment 펀딩 지불액 (양수: 지불, 음수: 수령)
    event PositionFundingSettled(bytes32 indexed positionKey, address indexed trader, int256 fundingPayment);

    /// @notice 펀딩 스냅샷 기록됨
    /// @param marketId 마켓 ID
    /// @param fundingRate 펀딩 비율
    /// @param markPrice 마크 가격
    /// @param indexPrice 인덱스 가격
    /// @param timestamp 타임스탬프
    event FundingSnapshotRecorded(
        uint32 indexed marketId, int64 fundingRate, uint256 markPrice, uint256 indexPrice, uint256 timestamp
    );

    // ============ Price Events ============

    /// @notice 마크 가격 업데이트됨
    /// @param marketId 마켓 ID
    /// @param markPrice 마크 가격
    /// @param indexPrice 인덱스 가격
    /// @param basis Basis
    /// @param emaBasis EMA Basis
    event MarkPriceUpdated(
        uint32 indexed marketId, uint256 markPrice, uint256 indexPrice, int256 basis, int256 emaBasis
    );

    /// @notice 인덱스 가격 업데이트됨
    /// @param marketId 마켓 ID
    /// @param price 인덱스 가격
    /// @param source 가격 소스
    /// @param timestamp 타임스탬프
    event IndexPriceUpdated(uint32 indexed marketId, uint256 price, uint8 source, uint256 timestamp);

    /// @notice 가격 오라클 장애
    /// @param marketId 마켓 ID
    /// @param reason 장애 사유
    event OracleFailure(uint32 indexed marketId, string reason);

    // ============ Fee Events ============

    /// @notice 수수료 징수됨
    /// @param trader 트레이더 주소
    /// @param marketId 마켓 ID
    /// @param amount 수수료 금액
    /// @param feeType 수수료 유형 (0: trading, 1: liquidation, 2: funding)
    event FeeCollected(address indexed trader, uint32 indexed marketId, uint256 amount, uint8 feeType);

    /// @notice 수수료 분배됨
    /// @param totalAmount 총 수수료
    /// @param protocolAmount 프로토콜 몫
    /// @param insuranceAmount 보험 기금 몫
    /// @param stakingAmount 스테이킹 몫
    event FeeDistributed(uint256 totalAmount, uint256 protocolAmount, uint256 insuranceAmount, uint256 stakingAmount);

    /// @notice 수수료율 업데이트됨
    /// @param marketId 마켓 ID
    /// @param makerFeeBps 메이커 수수료 (BPS)
    /// @param takerFeeBps 테이커 수수료 (BPS)
    event FeeRateUpdated(uint32 indexed marketId, uint32 makerFeeBps, uint32 takerFeeBps);

    /// @notice 수수료 분배 비율 업데이트됨
    /// @param protocolShareBps 프로토콜 비율
    /// @param insuranceShareBps 보험 기금 비율
    /// @param stakingShareBps 스테이킹 비율
    event FeeDistributionUpdated(uint32 protocolShareBps, uint32 insuranceShareBps, uint32 stakingShareBps);

    /// @notice 프로토콜 수수료 출금됨
    /// @param recipient 수령자
    /// @param amount 금액
    event ProtocolFeesWithdrawn(address indexed recipient, uint256 amount);

    // ============ Margin Events ============

    /// @notice 마진 입금됨
    /// @param trader 트레이더 주소
    /// @param amount 입금 금액
    /// @param newBalance 새 잔액
    event MarginDeposited(address indexed trader, uint256 amount, uint256 newBalance);

    /// @notice 마진 출금됨
    /// @param trader 트레이더 주소
    /// @param amount 출금 금액
    /// @param newBalance 새 잔액
    event MarginWithdrawn(address indexed trader, uint256 amount, uint256 newBalance);

    /// @notice 마진 모드 변경됨
    /// @param trader 트레이더 주소
    /// @param marketId 마켓 ID
    /// @param oldMode 이전 모드
    /// @param newMode 새 모드
    event MarginModeChanged(
        address indexed trader,
        uint32 indexed marketId,
        PerpetualTypes.MarginMode oldMode,
        PerpetualTypes.MarginMode newMode
    );

    // ============ Risk Management Events ============

    /// @notice 서킷 브레이커 발동됨
    /// @param marketId 마켓 ID
    /// @param reason 발동 사유
    /// @param triggeredAt 발동 시간
    event CircuitBreakerTriggered(uint32 indexed marketId, string reason, uint256 triggeredAt);

    /// @notice 서킷 브레이커 해제됨
    /// @param marketId 마켓 ID
    /// @param resolvedAt 해제 시간
    event CircuitBreakerResolved(uint32 indexed marketId, uint256 resolvedAt);

    /// @notice 리스크 한도 업데이트됨
    /// @param marketId 마켓 ID
    /// @param limitType 한도 유형
    /// @param oldLimit 이전 한도
    /// @param newLimit 새 한도
    event RiskLimitUpdated(uint32 indexed marketId, bytes32 indexed limitType, uint256 oldLimit, uint256 newLimit);

    // ============ System Events ============

    /// @notice 시스템 일시중지됨
    /// @param pausedBy 일시중지자
    event SystemPaused(address indexed pausedBy);

    /// @notice 시스템 재개됨
    /// @param unpausedBy 재개자
    event SystemUnpaused(address indexed unpausedBy);

    /// @notice 업그레이드됨
    /// @param implementation 새 구현 주소
    event Upgraded(address indexed implementation);
}
