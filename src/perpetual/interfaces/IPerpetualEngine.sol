// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";

/**
 * @title IPerpetualEngine
 * @author StableNet Team
 * @notice 무기한 선물 거래 메인 엔진 인터페이스
 * @dev 모든 거래 기능의 진입점 역할
 */
interface IPerpetualEngine {
    // ============ View Functions ============

    /**
     * @notice 마켓 정보 조회
     * @param marketId 마켓 ID
     * @return market 마켓 정보
     */
    function getMarket(uint32 marketId) external view returns (PerpetualTypes.Market memory market);

    /**
     * @notice Market symbols as given to createMarket
     * @dev Markets are synthetic, so MarketCreated carries address(0) as base token;
     *      indexers read the human-readable pair from here.
     * @param marketId Market ID
     * @return baseAsset Base asset symbol (e.g. "BTC")
     * @return quoteAsset Quote asset symbol (e.g. "USDT")
     */
    function getMarketSymbols(uint32 marketId) external view returns (string memory baseAsset, string memory quoteAsset);

    /**
     * @notice 마켓 설정 조회
     * @param marketId 마켓 ID
     * @return config 마켓 설정
     */
    function getMarketConfig(uint32 marketId) external view returns (PerpetualTypes.MarketConfig memory config);

    /**
     * @notice 마켓 통계 조회
     * @param marketId 마켓 ID
     * @return stats 마켓 통계
     */
    function getMarketStats(uint32 marketId) external view returns (PerpetualTypes.MarketStats memory stats);

    /**
     * @notice 마켓 존재 여부 확인
     * @param marketId 마켓 ID
     * @return exists 존재 여부
     */
    function marketExists(uint32 marketId) external view returns (bool exists);

    /**
     * @notice 마켓 활성화 여부 확인
     * @param marketId 마켓 ID
     * @return isActive 활성화 여부
     */
    function isMarketActive(uint32 marketId) external view returns (bool isActive);

    /**
     * @notice 전체 마켓 ID 목록 조회
     * @return marketIds 마켓 ID 배열
     */
    function getAllMarketIds() external view returns (uint32[] memory marketIds);

    /**
     * @notice 마켓 수 조회
     * @return count 마켓 수
     */
    function getMarketCount() external view returns (uint256 count);

    /**
     * @notice 컴포넌트 주소 조회
     * @return positionManager 포지션 매니저 주소
     * @return marginManager 마진 매니저 주소
     * @return orderManager 주문 매니저 주소
     * @return liquidator 청산자 주소
     * @return insuranceFund 보험 기금 주소
     * @return adlEngine ADL 엔진 주소
     */
    function getComponents()
        external
        view
        returns (
            address positionManager,
            address marginManager,
            address orderManager,
            address liquidator,
            address insuranceFund,
            address adlEngine
        );

    // ============ Trading Functions ============

    /**
     * @notice 마진 입금
     * @param amount 입금 금액
     */
    function depositMargin(uint256 amount) external;

    /**
     * @notice 마진 출금
     * @param amount 출금 금액
     */
    function withdrawMargin(uint256 amount) external;

    /**
     * @notice 시장가 주문
     * @param marketId 마켓 ID
     * @param side 포지션 방향
     * @param size 주문 수량
     * @param maxSlippage 최대 슬리피지 (BPS)
     * @return positionKey 포지션 키
     * @return fillPrice 체결 가격
     */
    function openMarketPosition(uint32 marketId, PerpetualTypes.PositionSide side, uint128 size, uint128 maxSlippage)
        external
        returns (bytes32 positionKey, uint128 fillPrice);

    /**
     * @notice 지정가 주문 생성
     * @param params 주문 파라미터
     * @return orderId 주문 ID
     */
    function placeLimitOrder(PerpetualTypes.OrderParams calldata params) external returns (bytes32 orderId);

    /**
     * @notice 포지션 종료
     * @param positionKey 포지션 키
     * @param maxSlippage 최대 슬리피지 (BPS)
     * @return realizedPnL 실현 손익
     */
    function closePosition(bytes32 positionKey, uint128 maxSlippage) external returns (int256 realizedPnL);

    /**
     * @notice 포지션 부분 종료
     * @param positionKey 포지션 키
     * @param reduceSize 감소 크기
     * @param maxSlippage 최대 슬리피지 (BPS)
     * @return realizedPnL 실현 손익
     */
    function reducePosition(bytes32 positionKey, uint128 reduceSize, uint128 maxSlippage)
        external
        returns (int256 realizedPnL);

    /**
     * @notice 주문 취소
     * @param orderId 주문 ID
     */
    function cancelOrder(bytes32 orderId) external;

    /**
     * @notice 모든 주문 취소
     * @param marketId 마켓 ID (0이면 전체)
     */
    function cancelAllOrders(uint32 marketId) external;

    /**
     * @notice 포지션 마진 추가
     * @param positionKey 포지션 키
     * @param addMargin 추가 마진
     */
    function addPositionMargin(bytes32 positionKey, uint128 addMargin) external;

    /**
     * @notice 포지션 마진 제거
     * @param positionKey 포지션 키
     * @param removeMargin 제거 마진
     */
    function removePositionMargin(bytes32 positionKey, uint128 removeMargin) external;

    /**
     * @notice 마진 모드 변경
     * @param marketId 마켓 ID
     * @param mode 새 마진 모드
     */
    function setMarginMode(uint32 marketId, PerpetualTypes.MarginMode mode) external;

    /**
     * @notice 레버리지 변경
     * @param marketId 마켓 ID
     * @param leverage 새 레버리지
     */
    function setLeverage(uint32 marketId, uint8 leverage) external;

    // ============ Admin Functions ============

    /**
     * @notice 마켓 생성
     * @param baseAsset 기초 자산 (예: "BTC")
     * @param quoteAsset 견적 자산 (예: "USDT")
     * @param config 마켓 설정
     * @return marketId 생성된 마켓 ID
     */
    function createMarket(
        string calldata baseAsset,
        string calldata quoteAsset,
        PerpetualTypes.MarketConfig calldata config
    ) external returns (uint32 marketId);

    /**
     * @notice 마켓 상태 변경
     * @param marketId 마켓 ID
     * @param status 새 상태
     */
    function setMarketStatus(uint32 marketId, PerpetualTypes.MarketStatus status) external;

    /**
     * @notice 마켓 설정 업데이트
     * @param marketId 마켓 ID
     * @param config 새 설정
     */
    function updateMarketConfig(uint32 marketId, PerpetualTypes.MarketConfig calldata config) external;

    /**
     * @notice 컴포넌트 주소 설정
     * @param positionManager 포지션 매니저 주소
     * @param marginManager 마진 매니저 주소
     * @param orderManager 주문 매니저 주소
     * @param liquidator 청산자 주소
     * @param insuranceFund 보험 기금 주소
     * @param adlEngine ADL 엔진 주소
     */
    function setComponents(
        address positionManager,
        address marginManager,
        address orderManager,
        address liquidator,
        address insuranceFund,
        address adlEngine
    ) external;

    /**
     * @notice 오라클 주소 설정
     * @param marketId 마켓 ID
     * @param indexOracle 인덱스 가격 오라클
     * @param markOracle 마크 가격 오라클
     */
    function setOracles(uint32 marketId, address indexOracle, address markOracle) external;

    /**
     * @notice 긴급 정지
     */
    function emergencyPause() external;

    /**
     * @notice 긴급 정지 해제
     */
    function emergencyUnpause() external;

    /**
     * @notice 거래 정지
     * @param marketId 마켓 ID
     */
    function pauseTrading(uint32 marketId) external;

    /**
     * @notice 거래 재개
     * @param marketId 마켓 ID
     */
    function resumeTrading(uint32 marketId) external;
}
