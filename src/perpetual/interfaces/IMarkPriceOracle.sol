// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";

/**
 * @title IMarkPriceOracle
 * @author StableNet Team
 * @notice 마크 가격 오라클 인터페이스
 */
interface IMarkPriceOracle {
    // ============ View Functions ============

    /**
     * @notice 마크 가격 조회
     * @param marketId 마켓 ID
     * @return markPrice 마크 가격
     */
    function getMarkPrice(uint32 marketId) external view returns (uint256 markPrice);

    /**
     * @notice 마크 가격 데이터 조회 (상세)
     * @param marketId 마켓 ID
     * @return priceData 마크 가격 데이터
     */
    function getMarkPriceData(uint32 marketId) external view returns (PerpetualTypes.MarkPriceData memory priceData);

    /**
     * @notice Basis 조회 (Mark - Index)
     * @param marketId 마켓 ID
     * @return basis 현재 Basis
     */
    function getBasis(uint32 marketId) external view returns (int256 basis);

    /**
     * @notice EMA Basis 조회
     * @param marketId 마켓 ID
     * @return emaBasis EMA Basis
     */
    function getEMABasis(uint32 marketId) external view returns (int256 emaBasis);

    /**
     * @notice 인덱스 가격 조회
     * @param marketId 마켓 ID
     * @return indexPrice 인덱스 가격
     */
    function getIndexPrice(uint32 marketId) external view returns (uint256 indexPrice);

    /**
     * @notice EMA 기간 조회
     * @return period EMA 기간
     */
    function getEMAPeriod() external view returns (uint256 period);

    // ============ State-Changing Functions ============

    /**
     * @notice 마크 가격 업데이트
     * @param marketId 마켓 ID
     */
    function updateMarkPrice(uint32 marketId) external;

    /**
     * @notice EMA 기간 설정
     * @param period 새 EMA 기간
     */
    function setEMAPeriod(uint256 period) external;

    /**
     * @notice 인덱스 오라클 설정
     * @param indexOracle 인덱스 오라클 주소
     */
    function setIndexOracle(address indexOracle) external;
}
