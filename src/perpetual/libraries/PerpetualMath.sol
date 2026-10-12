// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Constants } from "../../common/libraries/Constants.sol";

/**
 * @title PerpetualMath
 * @author StableNet Team
 * @notice Perpetual Trading 시스템 수학 연산 라이브러리
 * @dev 고정 소수점 연산, PnL 계산, 마진 비율, 청산가, 펀딩비, ADL 우선순위 계산
 */
library PerpetualMath {
    using PerpetualMath for uint256;
    using PerpetualMath for int256;

    // ============ Precision Constants ============

    uint256 internal constant PRECISION = Constants.PRECISION;
    uint256 internal constant BPS_PRECISION = Constants.BPS_PRECISION;

    // ============ Fixed Point Math ============

    /**
     * @notice 곱셈 후 나눗셈 (정밀도 유지)
     * @param a 피연산자 1
     * @param b 피연산자 2
     * @param denominator 나눗수
     * @return result 결과
     */
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        require(denominator > 0, "Division by zero");
        // Use a full-width intermediate product for large position and price values.
        result = Math.mulDiv(a, b, denominator);
    }

    /**
     * @notice 곱셈 후 나눗셈 (올림)
     * @param a 피연산자 1
     * @param b 피연산자 2
     * @param denominator 나눗수
     * @return result 결과 (올림)
     */
    function mulDivRoundUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            result += 1;
        }
    }

    /**
     * @notice 부호 있는 곱셈 후 나눗셈
     * @param a 피연산자 1 (부호 있음)
     * @param b 피연산자 2
     * @param denominator 나눗수
     * @return result 결과 (부호 있음)
     */
    function mulDivSigned(int256 a, uint256 b, uint256 denominator) internal pure returns (int256 result) {
        require(denominator > 0, "Division by zero");
        if (a >= 0) {
            result = int256(mulDiv(uint256(a), b, denominator));
        } else {
            result = -int256(mulDiv(uint256(-a), b, denominator));
        }
    }

    /**
     * @notice 절댓값
     * @param x 입력값
     * @return 절댓값
     */
    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    /**
     * @notice 최솟값
     * @param a 값 1
     * @param b 값 2
     * @return 최솟값
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @notice 최댓값
     * @param a 값 1
     * @param b 값 2
     * @return 최댓값
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /**
     * @notice 값을 범위 내로 제한 (clamp)
     * @param value 입력값
     * @param minValue 최솟값
     * @param maxValue 최댓값
     * @return 범위 내 값
     */
    function clamp(int256 value, int256 minValue, int256 maxValue) internal pure returns (int256) {
        if (value < minValue) return minValue;
        if (value > maxValue) return maxValue;
        return value;
    }

    // ============ PnL Calculations ============

    /**
     * @notice 미실현 PnL 계산
     * @dev Long: (markPrice - entryPrice) * size / PRECISION
     *      Short: (entryPrice - markPrice) * size / PRECISION
     * @param entryPrice 진입가
     * @param markPrice 마크 가격
     * @param size 포지션 크기
     * @param isLong 롱 포지션 여부
     * @return pnl 미실현 손익 (부호 있음)
     */
    function calculateUnrealizedPnL(uint256 entryPrice, uint256 markPrice, uint256 size, bool isLong)
        internal
        pure
        returns (int256 pnl)
    {
        if (size == 0) return 0;

        if (isLong) {
            if (markPrice >= entryPrice) {
                pnl = int256(mulDiv(markPrice - entryPrice, size, PRECISION));
            } else {
                pnl = -int256(mulDiv(entryPrice - markPrice, size, PRECISION));
            }
        } else {
            if (entryPrice >= markPrice) {
                pnl = int256(mulDiv(entryPrice - markPrice, size, PRECISION));
            } else {
                pnl = -int256(mulDiv(markPrice - entryPrice, size, PRECISION));
            }
        }
    }

    /**
     * @notice 실현 PnL 계산 (포지션 종료 시)
     * @param entryPrice 진입가
     * @param exitPrice 청산가
     * @param size 청산 크기
     * @param isLong 롱 포지션 여부
     * @return pnl 실현 손익 (부호 있음)
     */
    function calculateRealizedPnL(uint256 entryPrice, uint256 exitPrice, uint256 size, bool isLong)
        internal
        pure
        returns (int256 pnl)
    {
        return calculateUnrealizedPnL(entryPrice, exitPrice, size, isLong);
    }

    /**
     * @notice 평균 진입가 계산 (포지션 증가 시)
     * @dev newEntryPrice = (oldSize * oldEntryPrice + addSize * addPrice) / (oldSize + addSize)
     * @param oldSize 기존 포지션 크기
     * @param oldEntryPrice 기존 진입가
     * @param addSize 추가 크기
     * @param addPrice 추가 가격
     * @return newEntryPrice 새 평균 진입가
     */
    function calculateAverageEntryPrice(uint256 oldSize, uint256 oldEntryPrice, uint256 addSize, uint256 addPrice)
        internal
        pure
        returns (uint256 newEntryPrice)
    {
        if (oldSize == 0) return addPrice;
        if (addSize == 0) return oldEntryPrice;

        uint256 totalValue = mulDiv(oldSize, oldEntryPrice, PRECISION) + mulDiv(addSize, addPrice, PRECISION);
        uint256 totalSize = oldSize + addSize;

        newEntryPrice = mulDiv(totalValue, PRECISION, totalSize);
    }

    // ============ Margin Calculations ============

    /**
     * @notice 마진 비율 계산 (격리 마진)
     * @dev marginRatio = equity / notionalValue
     *      equity = margin + unrealizedPnL - pendingFunding
     * @param margin 마진 금액
     * @param unrealizedPnL 미실현 손익
     * @param pendingFunding 미정산 펀딩비
     * @param size 포지션 크기
     * @param markPrice 마크 가격
     * @return ratio 마진 비율 (BPS)
     */
    function calculateMarginRatio(
        uint256 margin,
        int256 unrealizedPnL,
        int256 pendingFunding,
        uint256 size,
        uint256 markPrice
    ) internal pure returns (uint256 ratio) {
        if (size == 0 || markPrice == 0) return type(uint256).max;

        // equity = margin + unrealizedPnL - pendingFunding
        int256 equitySigned = int256(margin) + unrealizedPnL - pendingFunding;

        // equity가 0 이하면 마진 비율 0 (청산 대상)
        if (equitySigned <= 0) return 0;

        uint256 equity = uint256(equitySigned);

        // notionalValue = size * markPrice / PRECISION
        uint256 notionalValue = mulDiv(size, markPrice, PRECISION);

        if (notionalValue == 0) return type(uint256).max;

        // marginRatio = equity * BPS_PRECISION / notionalValue
        ratio = mulDiv(equity, BPS_PRECISION, notionalValue);
    }

    /**
     * @notice 교차 마진 비율 계산
     * @dev marginRatio = totalEquity / totalNotionalValue
     * @param totalBalance 계정 총 잔액
     * @param totalUnrealizedPnL 총 미실현 손익
     * @param totalPendingFunding 총 미정산 펀딩비
     * @param totalNotionalValue 총 명목 가치
     * @return ratio 마진 비율 (BPS)
     */
    function calculateCrossMarginRatio(
        uint256 totalBalance,
        int256 totalUnrealizedPnL,
        int256 totalPendingFunding,
        uint256 totalNotionalValue
    ) internal pure returns (uint256 ratio) {
        if (totalNotionalValue == 0) return type(uint256).max;

        int256 totalEquitySigned = int256(totalBalance) + totalUnrealizedPnL - totalPendingFunding;

        if (totalEquitySigned <= 0) return 0;

        ratio = mulDiv(uint256(totalEquitySigned), BPS_PRECISION, totalNotionalValue);
    }

    /**
     * @notice 청산가 계산
     * @dev Long: liqPrice = entryPrice - marginBuffer * PRECISION / size
     *      Short: liqPrice = entryPrice + marginBuffer * PRECISION / size
     *      marginBuffer = margin - (size * entryPrice * MM / PRECISION)
     * @param entryPrice 진입가
     * @param margin 마진
     * @param size 포지션 크기
     * @param maintenanceMarginBps 유지 마진율 (BPS)
     * @param isLong 롱 포지션 여부
     * @return liquidationPrice 청산가
     */
    function calculateLiquidationPrice(
        uint256 entryPrice,
        uint256 margin,
        uint256 size,
        uint256 maintenanceMarginBps,
        bool isLong
    ) internal pure returns (uint256 liquidationPrice) {
        if (size == 0) return 0;

        // 유지 마진 필요량: size * entryPrice * MM / (PRECISION * BPS_PRECISION)
        uint256 maintenanceMarginRequired =
            mulDiv(mulDiv(size, entryPrice, PRECISION), maintenanceMarginBps, BPS_PRECISION);

        // 마진이 유지 마진보다 작으면 즉시 청산
        if (margin <= maintenanceMarginRequired) {
            return isLong ? type(uint256).max : 0;
        }

        // marginBuffer = margin - maintenanceMarginRequired
        uint256 marginBuffer = margin - maintenanceMarginRequired;

        // 가격 변동 여유분
        uint256 priceBuffer = mulDiv(marginBuffer, PRECISION, size);

        if (isLong) {
            // Long: 가격 하락 시 청산
            liquidationPrice = entryPrice > priceBuffer ? entryPrice - priceBuffer : 0;
        } else {
            // Short: 가격 상승 시 청산
            liquidationPrice = entryPrice + priceBuffer;
        }
    }

    /**
     * @notice 청산 가능 여부 확인
     * @param marginRatio 현재 마진 비율 (BPS)
     * @param maintenanceMarginBps 유지 마진율 (BPS)
     * @return isLiquidatable 청산 가능 여부
     */
    function isLiquidatable(uint256 marginRatio, uint256 maintenanceMarginBps) internal pure returns (bool) {
        return marginRatio <= maintenanceMarginBps;
    }

    // ============ Funding Rate Calculations ============

    /**
     * @notice 프리미엄 인덱스 계산
     * @dev premiumIndex = (markPrice - indexPrice) / indexPrice
     * @param markPrice 마크 가격
     * @param indexPrice 인덱스 가격
     * @return premium 프리미엄 인덱스 (부호 있음, BPS)
     */
    function calculatePremiumIndex(uint256 markPrice, uint256 indexPrice) internal pure returns (int256 premium) {
        if (indexPrice == 0) return 0;

        if (markPrice >= indexPrice) {
            premium = int256(mulDiv(markPrice - indexPrice, BPS_PRECISION, indexPrice));
        } else {
            premium = -int256(mulDiv(indexPrice - markPrice, BPS_PRECISION, indexPrice));
        }
    }

    /**
     * @notice 펀딩 비율 계산
     * @dev fundingRate = clamp(premiumIndex, -maxFundingRate, maxFundingRate)
     * @param premiumIndex 프리미엄 인덱스 (BPS)
     * @param maxFundingRateBps 최대 펀딩 비율 (BPS)
     * @return fundingRate 펀딩 비율 (부호 있음, BPS)
     */
    function calculateFundingRate(int256 premiumIndex, uint256 maxFundingRateBps)
        internal
        pure
        returns (int256 fundingRate)
    {
        int256 maxRate = int256(maxFundingRateBps);
        fundingRate = clamp(premiumIndex, -maxRate, maxRate);
    }

    /**
     * @notice 펀딩비 지불액 계산
     * @dev fundingPayment = size * (cumulativeFundingIndex - lastFundingIndex) / PRECISION
     *      부호 규칙: 양수 = Long 지불 / Short 수령, 음수 = Short 지불 / Long 수령
     * @param size 포지션 크기
     * @param cumulativeFundingIndex 현재 누적 펀딩 인덱스
     * @param lastFundingIndex 마지막 정산 시 펀딩 인덱스
     * @param isLong 롱 포지션 여부
     * @return payment 펀딩 지불액 (양수: 지불, 음수: 수령)
     */
    function calculateFundingPayment(uint256 size, int256 cumulativeFundingIndex, int256 lastFundingIndex, bool isLong)
        internal
        pure
        returns (int256 payment)
    {
        if (size == 0) return 0;

        int256 fundingDelta = cumulativeFundingIndex - lastFundingIndex;

        // payment = size * fundingDelta / PRECISION
        payment = mulDivSigned(fundingDelta, size, PRECISION);

        // 롱은 양수 펀딩비 지불, 숏은 양수 펀딩비 수령
        if (!isLong) {
            payment = -payment;
        }
    }

    // ============ ADL Calculations ============

    /**
     * @notice ADL 우선순위 계산
     * @dev priority = (pnl / equity) * leverage
     *      높은 수익 + 높은 레버리지 = 높은 ADL 우선순위
     * @param unrealizedPnL 미실현 손익
     * @param margin 마진
     * @param size 포지션 크기
     * @param markPrice 마크 가격
     * @return priority ADL 우선순위 (높을수록 먼저 ADL)
     */
    function calculateADLPriority(int256 unrealizedPnL, uint256 margin, uint256 size, uint256 markPrice)
        internal
        pure
        returns (uint256 priority)
    {
        // 손실 포지션은 ADL 대상 아님
        if (unrealizedPnL <= 0) return 0;

        // margin이 0이면 우선순위 0 (0 나누기 방지)
        if (margin == 0) return 0;

        // equity = margin + unrealizedPnL
        uint256 equity = margin + uint256(unrealizedPnL);

        // equity가 0이면 우선순위 0 (0 나누기 방지)
        if (equity == 0) return 0;

        // notionalValue = size * markPrice / PRECISION
        uint256 notionalValue = mulDiv(size, markPrice, PRECISION);

        // leverage = notionalValue / equity
        uint256 leverage = equity > 0 ? mulDiv(notionalValue, PRECISION, equity) : 0;

        // pnlRatio = pnl / equity
        uint256 pnlRatio = mulDiv(uint256(unrealizedPnL), PRECISION, equity);

        // priority = pnlRatio * leverage / PRECISION
        priority = mulDiv(pnlRatio, leverage, PRECISION);
    }

    // ============ Mark Price Calculations ============

    /**
     * @notice EMA 계산
     * @dev EMA = previousEMA * (1 - alpha) + currentValue * alpha
     *      alpha = 2 / (period + 1)
     * @param previousEMA 이전 EMA
     * @param currentValue 현재 값
     * @param period EMA 기간
     * @return newEMA 새 EMA
     */
    function calculateEMA(int256 previousEMA, int256 currentValue, uint256 period)
        internal
        pure
        returns (int256 newEMA)
    {
        if (period == 0) return currentValue;

        // alpha = 2 / (period + 1), 정밀도 유지를 위해 PRECISION 곱함
        uint256 alpha = mulDiv(2, PRECISION, period + 1);
        uint256 oneMinusAlpha = PRECISION - alpha;

        // newEMA = previousEMA * (1 - alpha) + currentValue * alpha
        int256 part1 = mulDivSigned(previousEMA, oneMinusAlpha, PRECISION);
        int256 part2 = mulDivSigned(currentValue, alpha, PRECISION);

        newEMA = part1 + part2;
    }

    /**
     * @notice 마크 가격 계산
     * @dev markPrice = indexPrice + emaBasis
     * @param indexPrice 인덱스 가격
     * @param emaBasis EMA Basis
     * @return markPrice 마크 가격
     */
    function calculateMarkPrice(uint256 indexPrice, int256 emaBasis) internal pure returns (uint256 markPrice) {
        if (emaBasis >= 0) {
            markPrice = indexPrice + uint256(emaBasis);
        } else {
            uint256 absBasis = uint256(-emaBasis);
            markPrice = indexPrice > absBasis ? indexPrice - absBasis : 0;
        }
    }

    // ============ Fee Calculations ============

    /**
     * @notice 거래 수수료 계산
     * @param notionalValue 명목 가치
     * @param feeBps 수수료율 (BPS)
     * @return fee 수수료 금액
     */
    function calculateTradingFee(uint256 notionalValue, uint256 feeBps) internal pure returns (uint256 fee) {
        fee = mulDiv(notionalValue, feeBps, BPS_PRECISION);
    }

    /**
     * @notice 청산 수수료 계산
     * @param notionalValue 명목 가치
     * @param liquidationFeeBps 청산 수수료율 (BPS)
     * @return fee 청산 수수료
     */
    function calculateLiquidationFee(uint256 notionalValue, uint256 liquidationFeeBps)
        internal
        pure
        returns (uint256 fee)
    {
        fee = mulDiv(notionalValue, liquidationFeeBps, BPS_PRECISION);
    }

    // ============ Leverage Calculations ============

    /**
     * @notice 레버리지 계산
     * @param notionalValue 명목 가치
     * @param margin 마진
     * @return leverage 레버리지 (1x = PRECISION)
     */
    function calculateLeverage(uint256 notionalValue, uint256 margin) internal pure returns (uint256 leverage) {
        if (margin == 0) return 0;
        leverage = mulDiv(notionalValue, PRECISION, margin);
    }

    /**
     * @notice 필요 마진 계산
     * @param size 포지션 크기
     * @param price 가격
     * @param leverage 레버리지 (1-100)
     * @return requiredMargin 필요 마진
     */
    function calculateRequiredMargin(uint256 size, uint256 price, uint256 leverage)
        internal
        pure
        returns (uint256 requiredMargin)
    {
        if (leverage == 0) return 0;
        uint256 notionalValue = mulDiv(size, price, PRECISION);
        requiredMargin = notionalValue / leverage;
    }
}
