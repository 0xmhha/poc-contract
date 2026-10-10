// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IFundingRate } from "../interfaces/IFundingRate.sol";
import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";
import { PerpetualMath } from "../libraries/PerpetualMath.sol";
import { PerpetualErrors } from "../libraries/PerpetualErrors.sol";
import { PerpetualEvents } from "../libraries/PerpetualEvents.sol";
import { Constants } from "../../common/libraries/Constants.sol";

/**
 * @title FundingRateManager
 * @author StableNet Team
 * @notice 펀딩비 계산 및 정산 컨트랙트
 * @dev
 * - 펀딩비 계산 (Mark Price - Index Price 기반)
 * - TWAP 펀딩비 계산
 * - 포지션별 펀딩비 정산
 * - 펀딩 히스토리 관리
 */
contract FundingRateManager is IFundingRate {
    using PerpetualMath for uint256;

    // ============ Constants ============

    uint256 private constant PRECISION = Constants.PRECISION;
    uint256 private constant BPS_PRECISION = Constants.BPS_PRECISION;

    /// @notice 기본 펀딩 주기 (8시간)
    uint64 public constant DEFAULT_FUNDING_INTERVAL = 8 hours;

    /// @notice 최소 펀딩 주기 (1시간)
    uint64 public constant MIN_FUNDING_INTERVAL = 1 hours;

    /// @notice 최대 펀딩 주기 (24시간)
    uint64 public constant MAX_FUNDING_INTERVAL = 24 hours;

    /// @notice 기본 최대 펀딩 비율 (0.75% = 75 BPS)
    uint32 public constant DEFAULT_MAX_FUNDING_RATE = 75;

    /// @notice TWAP 윈도우 크기
    uint256 public constant TWAP_WINDOW = 8 hours;

    /// @notice 최대 스냅샷 저장 수
    uint256 public constant MAX_SNAPSHOTS = 192; // 8일간 1시간마다

    // ============ State Variables ============

    /// @notice 마켓별 펀딩 설정
    mapping(uint32 => FundingConfig) private _fundingConfigs;

    /// @notice 마켓별 펀딩 상태
    mapping(uint32 => FundingState) private _fundingStates;

    /// @notice 마켓별 펀딩 스냅샷 (링 버퍼)
    mapping(uint32 => PerpetualTypes.FundingSnapshot[]) private _fundingSnapshots;

    /// @notice 마켓별 스냅샷 인덱스
    mapping(uint32 => uint256) private _snapshotIndex;

    /// @notice 포지션별 마지막 펀딩 인덱스
    mapping(bytes32 => int64) private _positionFundingIndex;

    /// @notice 관리자 주소
    address private _admin;

    /// @notice PerpetualEngine 주소
    address private _engine;

    /// @notice 마크 가격 오라클 주소
    address private _markPriceOracle;

    /// @notice 인덱스 가격 오라클 주소
    address private _indexPriceOracle;

    /// @notice 펀딩 설정
    struct FundingConfig {
        uint64 fundingInterval; // 펀딩 주기
        uint32 maxFundingRateBps; // 최대 펀딩 비율 (BPS)
        bool isInitialized; // 초기화 여부
    }

    /// @notice 펀딩 상태
    struct FundingState {
        int64 currentFundingRate; // 현재 펀딩 비율 (BPS)
        int64 twapFundingRate; // TWAP 펀딩 비율 (BPS)
        int64 cumulativeFundingIndex; // 누적 펀딩 인덱스
        uint64 lastFundingTime; // 마지막 펀딩 시간
        uint64 lastSnapshotTime; // 마지막 스냅샷 시간
    }

    // ============ Modifiers ============

    modifier onlyAuthorized() {
        if (msg.sender != _admin && msg.sender != _engine) {
            revert PerpetualErrors.Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != _admin) {
            revert PerpetualErrors.Unauthorized(msg.sender);
        }
        _;
    }

    modifier marketInitialized(uint32 marketId) {
        if (!_fundingConfigs[marketId].isInitialized) {
            revert PerpetualErrors.MarketNotFound(marketId);
        }
        _;
    }

    // ============ Constructor ============

    /**
     * @notice 컨트랙트 초기화
     * @param admin 관리자 주소
     */
    constructor(address admin) {
        if (admin == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        _admin = admin;
    }

    // ============ View Functions ============

    /// @inheritdoc IFundingRate
    function getCurrentFundingRate(uint32 marketId)
        external
        view
        override
        marketInitialized(marketId)
        returns (int64 fundingRate)
    {
        return _fundingStates[marketId].currentFundingRate;
    }

    /// @inheritdoc IFundingRate
    function getTWAPFundingRate(uint32 marketId)
        external
        view
        override
        marketInitialized(marketId)
        returns (int64 twapFundingRate)
    {
        return _fundingStates[marketId].twapFundingRate;
    }

    /// @inheritdoc IFundingRate
    function getCumulativeFundingIndex(uint32 marketId)
        external
        view
        override
        marketInitialized(marketId)
        returns (int64 cumulativeFundingIndex)
    {
        return _fundingStates[marketId].cumulativeFundingIndex;
    }

    /// @inheritdoc IFundingRate
    function getNextFundingTime(uint32 marketId)
        external
        view
        override
        marketInitialized(marketId)
        returns (uint256 nextFundingTime)
    {
        FundingState storage state = _fundingStates[marketId];
        FundingConfig storage config = _fundingConfigs[marketId];
        return state.lastFundingTime + config.fundingInterval;
    }

    /// @inheritdoc IFundingRate
    function getLastFundingTime(uint32 marketId)
        external
        view
        override
        marketInitialized(marketId)
        returns (uint256 lastFundingTime)
    {
        return _fundingStates[marketId].lastFundingTime;
    }

    /// @inheritdoc IFundingRate
    function getEstimatedFundingPayment(bytes32 positionKey) external view override returns (int256 estimatedPayment) {
        // TODO: 실제 구현 시 PositionManager에서 포지션 정보 조회
        // 임시: 0 반환
        return 0;
    }

    /// @inheritdoc IFundingRate
    function getFundingHistory(uint32 marketId, uint64 startTime, uint64 endTime)
        external
        view
        override
        marketInitialized(marketId)
        returns (PerpetualTypes.FundingHistory[] memory history)
    {
        PerpetualTypes.FundingSnapshot[] storage snapshots = _fundingSnapshots[marketId];
        uint256 count = 0;

        // 범위 내 스냅샷 수 계산
        for (uint256 i = 0; i < snapshots.length; i++) {
            if (snapshots[i].timestamp >= startTime && snapshots[i].timestamp <= endTime) {
                count++;
            }
        }

        // 히스토리 배열 생성
        history = new PerpetualTypes.FundingHistory[](count);
        uint256 idx = 0;

        for (uint256 i = 0; i < snapshots.length && idx < count; i++) {
            if (snapshots[i].timestamp >= startTime && snapshots[i].timestamp <= endTime) {
                PerpetualTypes.FundingSnapshot storage snap = snapshots[i];
                history[idx] = PerpetualTypes.FundingHistory({
                    marketId: marketId,
                    fundingRate: snap.fundingRate,
                    cumulativeFundingIndex: _fundingStates[marketId].cumulativeFundingIndex,
                    timestamp: snap.timestamp,
                    markPrice: snap.markPrice,
                    indexPrice: snap.indexPrice
                });
                idx++;
            }
        }
    }

    /// @inheritdoc IFundingRate
    function getFundingSnapshotCount(uint32 marketId)
        external
        view
        override
        marketInitialized(marketId)
        returns (uint256 count)
    {
        return _fundingSnapshots[marketId].length;
    }

    /// @inheritdoc IFundingRate
    function canSettleFunding(uint32 marketId)
        external
        view
        override
        marketInitialized(marketId)
        returns (bool canSettle)
    {
        FundingState storage state = _fundingStates[marketId];
        FundingConfig storage config = _fundingConfigs[marketId];
        return block.timestamp >= state.lastFundingTime + config.fundingInterval;
    }

    // ============ State-Changing Functions ============

    /// @inheritdoc IFundingRate
    function settleFunding(uint32 marketId)
        external
        override
        onlyAuthorized
        marketInitialized(marketId)
        returns (int64 newFundingRate, int64 newCumulativeFundingIndex)
    {
        FundingState storage state = _fundingStates[marketId];
        FundingConfig storage config = _fundingConfigs[marketId];

        // 펀딩 주기 확인
        if (block.timestamp < state.lastFundingTime + config.fundingInterval) {
            revert PerpetualErrors.FundingIntervalNotReached(marketId, state.lastFundingTime + config.fundingInterval);
        }

        // 펀딩 비율 계산
        newFundingRate = _calculateFundingRate(marketId);

        // 최대 펀딩 비율 클램핑
        if (newFundingRate > int64(uint64(config.maxFundingRateBps))) {
            newFundingRate = int64(uint64(config.maxFundingRateBps));
        } else if (newFundingRate < -int64(uint64(config.maxFundingRateBps))) {
            newFundingRate = -int64(uint64(config.maxFundingRateBps));
        }

        // 누적 펀딩 인덱스 업데이트
        state.cumulativeFundingIndex += newFundingRate;
        newCumulativeFundingIndex = state.cumulativeFundingIndex;

        // 상태 업데이트
        state.currentFundingRate = newFundingRate;
        state.lastFundingTime = uint64(block.timestamp);

        // TWAP 업데이트
        state.twapFundingRate = _calculateTWAPFundingRate(marketId);

        // 가격 조회 (임시)
        uint256 markPrice = 50000e18;
        uint256 indexPrice = 50000e18;

        emit PerpetualEvents.FundingSettled(marketId, newFundingRate, newCumulativeFundingIndex, markPrice, indexPrice);

        return (newFundingRate, newCumulativeFundingIndex);
    }

    /// @inheritdoc IFundingRate
    function recordFundingSnapshot(uint32 marketId) external override onlyAuthorized marketInitialized(marketId) {
        FundingState storage state = _fundingStates[marketId];

        // 스냅샷 주기 확인 (최소 1시간)
        if (block.timestamp < state.lastSnapshotTime + 1 hours) {
            return;
        }

        // 가격 조회 (임시)
        uint128 markPrice = 50000e18;
        uint128 indexPrice = 50000e18;

        // 스냅샷 생성
        PerpetualTypes.FundingSnapshot memory snapshot = PerpetualTypes.FundingSnapshot({
            fundingRate: state.currentFundingRate,
            timestamp: uint64(block.timestamp),
            markPrice: markPrice,
            indexPrice: indexPrice
        });

        // 링 버퍼에 저장
        PerpetualTypes.FundingSnapshot[] storage snapshots = _fundingSnapshots[marketId];
        if (snapshots.length < MAX_SNAPSHOTS) {
            snapshots.push(snapshot);
        } else {
            uint256 idx = _snapshotIndex[marketId] % MAX_SNAPSHOTS;
            snapshots[idx] = snapshot;
            _snapshotIndex[marketId] = idx + 1;
        }

        state.lastSnapshotTime = uint64(block.timestamp);

        emit PerpetualEvents.FundingSnapshotRecorded(
            marketId, state.currentFundingRate, markPrice, indexPrice, block.timestamp
        );
    }

    /// @inheritdoc IFundingRate
    function settlePositionFunding(bytes32 positionKey)
        external
        override
        onlyAuthorized
        returns (int256 fundingPayment)
    {
        // TODO: 실제 구현 시 PositionManager와 연동하여 포지션 정보 조회 및 펀딩비 정산
        // 임시: 0 반환
        return 0;
    }

    /// @inheritdoc IFundingRate
    function setFundingInterval(uint32 marketId, uint64 interval)
        external
        override
        onlyAdmin
        marketInitialized(marketId)
    {
        if (interval < MIN_FUNDING_INTERVAL || interval > MAX_FUNDING_INTERVAL) {
            revert PerpetualErrors.InvalidParameter("funding interval");
        }

        _fundingConfigs[marketId].fundingInterval = interval;
    }

    /// @inheritdoc IFundingRate
    function setMaxFundingRate(uint32 marketId, uint32 maxRate)
        external
        override
        onlyAdmin
        marketInitialized(marketId)
    {
        if (maxRate == 0 || maxRate > 1000) {
            // 최대 10%
            revert PerpetualErrors.InvalidParameter("max funding rate");
        }

        _fundingConfigs[marketId].maxFundingRateBps = maxRate;
    }

    // ============ Admin Functions ============

    /**
     * @notice 마켓 펀딩 초기화
     * @param marketId 마켓 ID
     */
    function initializeMarket(uint32 marketId) external onlyAdmin {
        if (_fundingConfigs[marketId].isInitialized) {
            revert PerpetualErrors.MarketAlreadyExists(marketId);
        }

        _fundingConfigs[marketId] = FundingConfig({
            fundingInterval: DEFAULT_FUNDING_INTERVAL, maxFundingRateBps: DEFAULT_MAX_FUNDING_RATE, isInitialized: true
        });

        _fundingStates[marketId] = FundingState({
            currentFundingRate: 0,
            twapFundingRate: 0,
            cumulativeFundingIndex: 0,
            lastFundingTime: uint64(block.timestamp),
            lastSnapshotTime: uint64(block.timestamp)
        });
    }

    /**
     * @notice 엔진 주소 설정
     * @param engine 엔진 주소
     */
    function setEngine(address engine) external onlyAdmin {
        if (engine == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        _engine = engine;
    }

    /**
     * @notice 가격 오라클 설정
     * @param markOracle 마크 가격 오라클
     * @param indexOracle 인덱스 가격 오라클
     */
    function setOracles(address markOracle, address indexOracle) external onlyAdmin {
        if (markOracle == address(0) || indexOracle == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        _markPriceOracle = markOracle;
        _indexPriceOracle = indexOracle;
    }

    // ============ Internal Functions ============

    /**
     * @notice 펀딩 비율 계산
     * @param marketId 마켓 ID
     * @return fundingRate 펀딩 비율 (BPS)
     */
    function _calculateFundingRate(uint32 marketId) internal view returns (int64 fundingRate) {
        // TODO: 실제 구현 시 오라클에서 마크/인덱스 가격 조회
        // 임시: (markPrice - indexPrice) / indexPrice * 펀딩 주기 비율
        uint128 markPrice = 50000e18;
        uint128 indexPrice = 50000e18;

        if (indexPrice == 0) {
            return 0;
        }

        // basis = (markPrice - indexPrice) / indexPrice * BPS_PRECISION
        int256 basis;
        if (markPrice >= indexPrice) {
            basis = int256(PerpetualMath.mulDiv(markPrice - indexPrice, BPS_PRECISION, indexPrice));
        } else {
            basis = -int256(PerpetualMath.mulDiv(indexPrice - markPrice, BPS_PRECISION, indexPrice));
        }

        // 펀딩 주기에 따른 비율 조정 (8시간 기준)
        FundingConfig storage config = _fundingConfigs[marketId];
        int256 adjustedRate = basis * int256(uint256(config.fundingInterval)) / int256(8 hours);

        return int64(adjustedRate);
    }

    /**
     * @notice TWAP 펀딩 비율 계산
     * @param marketId 마켓 ID
     * @return twapRate TWAP 펀딩 비율 (BPS)
     */
    function _calculateTWAPFundingRate(uint32 marketId) internal view returns (int64 twapRate) {
        PerpetualTypes.FundingSnapshot[] storage snapshots = _fundingSnapshots[marketId];

        if (snapshots.length == 0) {
            return _fundingStates[marketId].currentFundingRate;
        }

        uint256 windowStart = block.timestamp > TWAP_WINDOW ? block.timestamp - TWAP_WINDOW : 0;
        int256 totalRate = 0;
        uint256 count = 0;

        for (uint256 i = 0; i < snapshots.length; i++) {
            if (snapshots[i].timestamp >= windowStart) {
                totalRate += snapshots[i].fundingRate;
                count++;
            }
        }

        if (count == 0) {
            return _fundingStates[marketId].currentFundingRate;
        }

        return int64(totalRate / int256(count));
    }
}
