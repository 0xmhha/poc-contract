// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";

/**
 * @title IIndexPriceOracle
 * @author StableNet Team
 * @notice 인덱스 가격 오라클 인터페이스
 */
interface IIndexPriceOracle {
    // ============ View Functions ============

    /**
     * @notice 인덱스 가격 조회
     * @param marketId 마켓 ID
     * @return price 인덱스 가격
     */
    function getIndexPrice(uint32 marketId) external view returns (uint256 price);

    /**
     * @notice 인덱스 가격 데이터 조회 (상세)
     * @param marketId 마켓 ID
     * @return priceData 가격 데이터
     */
    function getIndexPriceData(uint32 marketId) external view returns (PerpetualTypes.PriceData memory priceData);

    /**
     * @notice 가격 유효성 확인
     * @param marketId 마켓 ID
     * @return isValid 유효 여부
     */
    function isPriceValid(uint32 marketId) external view returns (bool isValid);

    /**
     * @notice 가격 마지막 업데이트 시간 조회
     * @param marketId 마켓 ID
     * @return lastUpdate 마지막 업데이트 시간
     */
    function getLastUpdateTime(uint32 marketId) external view returns (uint256 lastUpdate);

    /**
     * @notice 가격 소스 조회
     * @param marketId 마켓 ID
     * @return priceFeed Chainlink 가격 피드 주소
     */
    function getPriceFeed(uint32 marketId) external view returns (address priceFeed);

    /**
     * @notice Staleness 임계값 조회
     * @return threshold Staleness 임계값 (초)
     */
    function getStalenessThreshold() external view returns (uint256 threshold);

    // ============ State-Changing Functions ============

    /**
     * @notice 가격 피드 설정
     * @param marketId 마켓 ID
     * @param priceFeed Chainlink 가격 피드 주소
     */
    function setPriceFeed(uint32 marketId, address priceFeed) external;

    /**
     * @notice Staleness 임계값 설정
     * @param threshold 새 임계값 (초)
     */
    function setStalenessThreshold(uint256 threshold) external;

    /**
     * @notice 폴백 오라클 설정
     * @param marketId 마켓 ID
     * @param fallbackOracle 폴백 오라클 주소
     */
    function setFallbackOracle(uint32 marketId, address fallbackOracle) external;
}
