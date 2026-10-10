// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PerpetualTypes } from "./PerpetualTypes.sol";

/**
 * @title PerpetualErrors
 * @author StableNet Team
 * @notice Perpetual Trading 시스템 커스텀 에러 정의
 * @dev 가스 효율적인 revert 메시지를 위한 custom error 사용
 */
library PerpetualErrors {
    // ============ General Errors ============

    /// @notice 제로 주소 사용 불가
    error ZeroAddress();

    /// @notice 제로 금액 불가
    error ZeroAmount();

    /// @notice 제로 크기 불가
    error ZeroSize();

    /// @notice 잘못된 파라미터
    error InvalidParameter(string param);

    /// @notice 권한 없음
    error Unauthorized(address caller);

    /// @notice 작업이 일시중지됨
    error OperationPaused();

    /// @notice 컨트랙트 초기화 안됨
    error NotInitialized();

    /// @notice 이미 초기화됨
    error AlreadyInitialized();

    // ============ Market Errors ============

    /// @notice 마켓을 찾을 수 없음
    error MarketNotFound(uint32 marketId);

    /// @notice 마켓이 이미 존재함
    error MarketAlreadyExists(uint32 marketId);

    /// @notice 잘못된 마켓 상태
    error InvalidMarketStatus(
        uint32 marketId, PerpetualTypes.MarketStatus current, PerpetualTypes.MarketStatus expected
    );

    /// @notice 마켓이 활성화되지 않음
    error MarketNotActive(uint32 marketId);

    /// @notice 마켓이 일시중지됨
    error MarketPaused(uint32 marketId);

    /// @notice 마켓이 정산 전용 모드
    error MarketSettleOnly(uint32 marketId);

    /// @notice 마켓이 상장폐지됨
    error MarketDelisted(uint32 marketId);

    // ============ Position Errors ============

    /// @notice 포지션을 찾을 수 없음
    error PositionNotFound(bytes32 positionKey);

    /// @notice 포지션이 이미 존재함
    error PositionAlreadyExists(bytes32 positionKey);

    /// @notice 잘못된 포지션 상태
    error InvalidPositionStatus(bytes32 positionKey, PerpetualTypes.PositionStatus current);

    /// @notice 포지션이 오픈 상태가 아님
    error PositionNotOpen(bytes32 positionKey);

    /// @notice 포지션이 이미 종료됨
    error PositionAlreadyClosed(bytes32 positionKey);

    /// @notice 감소 크기가 포지션 크기 초과
    error ExceedsPositionSize(bytes32 positionKey, uint256 requested, uint256 available);

    /// @notice 잘못된 포지션 방향
    error InvalidPositionSide(PerpetualTypes.PositionSide side);

    /// @notice 최대 포지션 수 초과
    error MaxPositionsExceeded(address trader, uint256 current, uint256 maximum);

    // ============ Order Errors ============

    /// @notice 주문을 찾을 수 없음
    error OrderNotFound(bytes32 orderId);

    /// @notice 주문이 이미 존재함
    error OrderAlreadyExists(bytes32 orderId);

    /// @notice 잘못된 주문 상태
    error InvalidOrderStatus(bytes32 orderId, PerpetualTypes.OrderStatus current);

    /// @notice 주문이 이미 체결됨
    error OrderAlreadyFilled(bytes32 orderId);

    /// @notice 주문이 이미 취소됨
    error OrderAlreadyCancelled(bytes32 orderId);

    /// @notice 주문 만료됨
    error OrderExpired(bytes32 orderId, uint256 expiredAt);

    /// @notice 잘못된 주문 유형
    error InvalidOrderType(PerpetualTypes.OrderType orderType);

    /// @notice 잘못된 가격
    error InvalidPrice(uint256 price);

    /// @notice 슬리피지 초과
    error SlippageExceeded(uint256 expectedPrice, uint256 actualPrice, uint256 maxSlippage);

    /// @notice 최대 주문 수 초과
    error MaxOrdersExceeded(address trader, uint256 current, uint256 maximum);

    /// @notice Post-Only 주문이 테이커로 체결됨
    error PostOnlyWouldTake(bytes32 orderId);

    /// @notice IOC/FOK 주문이 즉시 체결 불가
    error OrderCannotBeFilled(bytes32 orderId);

    /// @notice Reduce-Only 주문이 포지션 증가
    error ReduceOnlyViolation(bytes32 orderId);

    /// @notice 본인 주문만 취소 가능
    error OnlyOwnerCanCancel(bytes32 orderId, address caller, address owner);

    /// @notice 최대 오픈 주문 수 초과
    error MaxOpenOrdersReached(address trader, uint256 maximum);

    /// @notice 주문 취소 불가
    error OrderNotCancellable(bytes32 orderId, PerpetualTypes.OrderStatus status);

    /// @notice 주문 수정 불가
    error OrderNotModifiable(bytes32 orderId, PerpetualTypes.OrderStatus status);

    /// @notice 잘못된 주문 크기
    error InvalidOrderSize(bytes32 orderId, uint128 newSize, uint128 filledSize);

    /// @notice 주문 체결 불가
    error OrderNotFillable(bytes32 orderId, PerpetualTypes.OrderStatus status);

    /// @notice 가격이 허용 범위 초과
    error PriceOutOfRange(bytes32 orderId, uint128 fillPrice, uint128 limitPrice);

    /// @notice 주문 매칭 불가
    error OrderNotMatchable(bytes32 orderId, PerpetualTypes.OrderStatus status);

    /// @notice 마켓 불일치
    error MarketMismatch(uint32 marketId1, uint32 marketId2);

    /// @notice 같은 방향 주문
    error SameSideOrders(bytes32 orderId1, bytes32 orderId2);

    /// @notice 주문이 이미 최종 상태
    error OrderAlreadyFinalized(bytes32 orderId, PerpetualTypes.OrderStatus status);

    /// @notice 주문이 아직 만료되지 않음
    error OrderNotExpired(bytes32 orderId, uint64 expiresAt);

    /// @notice 잘못된 트리거 가격
    error InvalidTriggerPrice(uint128 triggerPrice);

    // ============ Margin Errors ============

    /// @notice 마진 부족
    error InsufficientMargin(address trader, uint256 required, uint256 available);

    /// @notice 마진 비율 부족 (청산 대상)
    error BelowMaintenanceMargin(bytes32 positionKey, uint256 marginRatio, uint256 maintenanceMargin);

    /// @notice 잘못된 마진 모드
    error InvalidMarginMode(PerpetualTypes.MarginMode mode);

    /// @notice 마진 제거 불가 (청산 위험)
    error CannotRemoveMargin(bytes32 positionKey, uint256 requested, uint256 available);

    /// @notice 잔액 부족
    error InsufficientBalance(address trader, uint256 required, uint256 available);

    /// @notice 교차 마진 부족
    error InsufficientCrossMargin(address trader, uint256 required, uint256 available);

    // ============ Leverage Errors ============

    /// @notice 잘못된 레버리지
    error InvalidLeverage(uint256 leverage, uint256 minLeverage, uint256 maxLeverage);

    /// @notice 레버리지 초과
    error LeverageExceeded(uint256 requested, uint256 maximum);

    // ============ Liquidation Errors ============

    /// @notice 청산 불가능한 포지션
    error PositionNotLiquidatable(bytes32 positionKey, uint256 marginRatio, uint256 maintenanceMargin);

    /// @notice 청산이 이미 진행 중
    error LiquidationInProgress(bytes32 positionKey);

    /// @notice 청산 실패
    error LiquidationFailed(bytes32 positionKey, string reason);

    /// @notice 부분 청산 불가
    error PartialLiquidationNotAllowed(bytes32 positionKey);

    /// @notice 청산 보상 전송 실패
    error LiquidationRewardTransferFailed(address liquidator, uint256 amount);

    // ============ ADL Errors ============

    /// @notice ADL이 필요하지 않음
    error ADLNotRequired();

    /// @notice ADL 대상 포지션 없음
    error NoADLCandidates(uint32 marketId, PerpetualTypes.PositionSide side);

    /// @notice ADL 실행 실패
    error ADLExecutionFailed(bytes32 positionKey, string reason);

    /// @notice ADL 대상 아님 (손실 포지션)
    error NotADLCandidate(bytes32 positionKey);

    // ============ Insurance Fund Errors ============

    /// @notice 보험 기금 부족
    error InsufficientInsuranceFund(uint256 required, uint256 available);

    /// @notice 보험 기금 출금 불가
    error InsuranceFundWithdrawNotAllowed();

    /// @notice 보험 기금 입금 실패
    error InsuranceFundDepositFailed(uint256 amount);

    // ============ Funding Errors ============

    /// @notice 펀딩 정산 간격 미도달
    error FundingIntervalNotReached(uint32 marketId, uint256 nextFundingTime);

    /// @notice 펀딩 정산 실패
    error FundingSettlementFailed(uint32 marketId, string reason);

    // ============ Price Oracle Errors ============

    /// @notice 가격 데이터 없음
    error PriceNotAvailable(uint32 marketId);

    /// @notice 가격이 오래됨 (stale)
    error StalePriceData(uint32 marketId, uint256 lastUpdate, uint256 maxAge);

    /// @notice 잘못된 가격 (0 또는 음수)
    error InvalidPriceData(uint32 marketId, int256 price);

    /// @notice 가격 편차 초과
    error PriceDeviationExceeded(uint32 marketId, uint256 deviation, uint256 maxDeviation);

    /// @notice 오라클 장애
    error OracleFailure(uint32 marketId, string reason);

    // ============ Fee Errors ============

    /// @notice 잘못된 수수료율
    error InvalidFeeRate(uint256 feeRate, uint256 maxFeeRate);

    /// @notice 수수료 분배 비율 합계 불일치
    error InvalidFeeDistribution(uint256 total, uint256 expected);

    /// @notice 메이커 수수료가 테이커보다 높음
    error MakerFeeExceedsTaker(uint256 makerFee, uint256 takerFee);

    /// @notice 수수료 전송 실패
    error FeeTransferFailed(address recipient, uint256 amount);

    // ============ Risk Management Errors ============

    /// @notice 포지션 한도 초과
    error PositionLimitExceeded(uint32 marketId, uint256 requested, uint256 limit);

    /// @notice Open Interest 한도 초과
    error OpenInterestLimitExceeded(uint32 marketId, uint256 requested, uint256 limit);

    /// @notice 서킷 브레이커 발동
    error CircuitBreakerTriggered(uint32 marketId, string reason);

    /// @notice 거래 한도 초과
    error TradingLimitExceeded(address trader, uint256 requested, uint256 limit);

    // ============ Token Errors ============

    /// @notice 지원하지 않는 토큰
    error TokenNotSupported(address token);

    /// @notice 토큰 전송 실패
    error TokenTransferFailed(address token, address from, address to, uint256 amount);

    // ============ Upgrade Errors ============

    /// @notice 업그레이드 권한 없음
    error UnauthorizedUpgrade(address implementation);

    /// @notice 잘못된 구현 주소
    error InvalidImplementation(address implementation);
}
