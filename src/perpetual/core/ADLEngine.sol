// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IADLEngine } from "../interfaces/IADLEngine.sol";
import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";
import { PerpetualMath } from "../libraries/PerpetualMath.sol";
import { PerpetualErrors } from "../libraries/PerpetualErrors.sol";
import { PerpetualEvents } from "../libraries/PerpetualEvents.sol";
import { Constants } from "../../common/libraries/Constants.sol";

/**
 * @title ADLEngine
 * @author StableNet Team
 * @notice 자동 디레버리징(ADL) 엔진 컨트랙트
 * @dev
 * - ADL 우선순위 계산
 * - ADL 대상 선정
 * - ADL 실행
 * - 우선순위 큐 관리
 */
contract ADLEngine is IADLEngine {
    using PerpetualMath for uint256;

    // ============ Constants ============

    uint256 private constant PRECISION = Constants.PRECISION;
    uint256 private constant BPS_PRECISION = Constants.BPS_PRECISION;

    /// @notice 최대 ADL 레벨
    uint8 public constant MAX_ADL_LEVEL = 5;

    /// @notice ADL 배치 최대 크기
    uint256 public constant MAX_ADL_BATCH_SIZE = 50;

    /// @notice 기본 레벨별 임계값 (BPS)
    uint256[5] public DEFAULT_LEVEL_THRESHOLDS = [800, 600, 400, 200, 100]; // 80%, 60%, 40%, 20%, 10%

    // ============ State Variables ============

    /// @notice 마켓별 ADL 활성화 상태
    mapping(uint32 => bool) private _adlActive;

    /// @notice 마켓별 ADL 레벨
    mapping(uint32 => uint8) private _adlLevels;

    /// @notice 마켓별 ADL 통계
    mapping(uint32 => ADLStats) private _adlStats;

    /// @notice 레벨별 임계값 (BPS)
    mapping(uint8 => uint256) private _levelThresholds;

    /// @notice 포지션별 ADL 우선순위
    mapping(bytes32 => uint256) private _adlPriorities;

    /// @notice 마켓별 방향별 우선순위 큐 (포지션 키 배열)
    mapping(uint32 => mapping(PerpetualTypes.PositionSide => bytes32[])) private _priorityQueues;

    /// @notice 관리자 주소
    address private _admin;

    /// @notice PerpetualEngine 주소
    address private _engine;

    /// @notice InsuranceFund 주소
    address private _insuranceFund;

    /// @notice PositionManager 주소
    address private _positionManager;

    /// @notice ADL 통계
    struct ADLStats {
        uint256 totalADLEvents;
        uint256 totalADLVolume;
        uint256 lastADLTime;
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

        // 기본 레벨 임계값 설정
        for (uint8 i = 0; i < MAX_ADL_LEVEL; i++) {
            _levelThresholds[i + 1] = DEFAULT_LEVEL_THRESHOLDS[i];
        }
    }

    // ============ View Functions ============

    /// @inheritdoc IADLEngine
    function isADLActive(uint32 marketId) external view override returns (bool isActive) {
        return _adlActive[marketId];
    }

    /// @inheritdoc IADLEngine
    function getADLPriority(bytes32 positionKey) external view override returns (uint256 priority) {
        return _adlPriorities[positionKey];
    }

    /// @inheritdoc IADLEngine
    function getADLTargets(uint32 marketId, PerpetualTypes.PositionSide side, uint256 limit)
        external
        view
        override
        returns (bytes32[] memory positionKeys)
    {
        bytes32[] storage queue = _priorityQueues[marketId][side];
        uint256 count = queue.length > limit ? limit : queue.length;

        positionKeys = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            positionKeys[i] = queue[i];
        }
    }

    /// @inheritdoc IADLEngine
    function getADLInfo(bytes32 positionKey) external view override returns (PerpetualTypes.ADLInfo memory info) {
        info = PerpetualTypes.ADLInfo({
            positionKey: positionKey,
            trader: address(0), // TODO: PositionManager에서 조회
            priority: _adlPriorities[positionKey],
            unrealizedPnL: 0, // TODO: PositionManager에서 조회
            leverage: 0 // TODO: PositionManager에서 조회
        });
    }

    /// @inheritdoc IADLEngine
    function shouldTriggerADL(uint32 marketId) external view override returns (bool shouldTrigger, uint256 deficit) {
        // TODO: InsuranceFund에서 ADL 트리거 여부 확인
        // 임시 구현
        return (false, 0);
    }

    /// @inheritdoc IADLEngine
    function getADLLevel(uint32 marketId) external view override returns (uint8 level) {
        return _adlLevels[marketId];
    }

    /// @inheritdoc IADLEngine
    function getADLStats(uint32 marketId)
        external
        view
        override
        returns (uint256 totalADLEvents, uint256 totalADLVolume, uint256 lastADLTime)
    {
        ADLStats storage stats = _adlStats[marketId];
        return (stats.totalADLEvents, stats.totalADLVolume, stats.lastADLTime);
    }

    // ============ State-Changing Functions ============

    /// @inheritdoc IADLEngine
    function executeADL(bytes32 bankruptPositionKey, bytes32 counterpartyPositionKey, uint128 adlSize)
        external
        override
        onlyAuthorized
        returns (uint128 executedSize)
    {
        // ADL 활성화 확인
        // TODO: 마켓 ID 조회 필요
        uint32 marketId = 0; // 임시

        if (!_adlActive[marketId]) {
            revert PerpetualErrors.ADLNotRequired();
        }

        // 상대방 포지션 유효성 확인
        uint256 priority = _adlPriorities[counterpartyPositionKey];
        if (priority == 0) {
            revert PerpetualErrors.NotADLCandidate(counterpartyPositionKey);
        }

        // TODO: 실제 ADL 실행 로직
        // 1. 파산 포지션 정보 조회
        // 2. 상대방 포지션 정보 조회
        // 3. ADL 가격 계산 (파산 포지션의 파산 가격)
        // 4. 상대방 포지션 감소
        // 5. 파산 포지션 정리

        executedSize = adlSize;

        // 통계 업데이트
        _adlStats[marketId].totalADLEvents++;
        _adlStats[marketId].totalADLVolume += adlSize;
        _adlStats[marketId].lastADLTime = block.timestamp;

        emit PerpetualEvents.ADLExecuted(bankruptPositionKey, counterpartyPositionKey, marketId, adlSize, 0);

        return executedSize;
    }

    /// @inheritdoc IADLEngine
    function batchExecuteADL(
        bytes32 bankruptPositionKey,
        bytes32[] calldata counterpartyPositionKeys,
        uint128[] calldata adlSizes
    ) external override onlyAuthorized returns (uint128 totalExecuted) {
        if (counterpartyPositionKeys.length != adlSizes.length) {
            revert PerpetualErrors.InvalidParameter("array length mismatch");
        }
        if (counterpartyPositionKeys.length > MAX_ADL_BATCH_SIZE) {
            revert PerpetualErrors.InvalidParameter("batch size exceeded");
        }

        for (uint256 i = 0; i < counterpartyPositionKeys.length; i++) {
            uint128 executed = this.executeADL(bankruptPositionKey, counterpartyPositionKeys[i], adlSizes[i]);
            totalExecuted += executed;
        }

        return totalExecuted;
    }

    /// @inheritdoc IADLEngine
    function autoExecuteADL(bytes32 bankruptPositionKey)
        external
        override
        onlyAuthorized
        returns (uint128 totalExecuted, uint256 adlCount)
    {
        // TODO: 마켓 ID 및 방향 조회
        uint32 marketId = 0;
        PerpetualTypes.PositionSide oppositeSide = PerpetualTypes.PositionSide.Long;

        // ADL 대상 조회
        bytes32[] storage queue = _priorityQueues[marketId][oppositeSide];

        if (queue.length == 0) {
            revert PerpetualErrors.NoADLCandidates(marketId, oppositeSide);
        }

        // TODO: 파산 포지션의 남은 크기만큼 ADL 실행
        uint128 remainingSize = 0; // 파산 포지션 크기

        uint256 i = 0;
        while (remainingSize > 0 && i < queue.length) {
            bytes32 counterpartyKey = queue[i];
            // TODO: 상대방 포지션 크기 조회
            uint128 counterpartySize = 0;

            uint128 adlSize = remainingSize > counterpartySize ? counterpartySize : remainingSize;

            uint128 executed = this.executeADL(bankruptPositionKey, counterpartyKey, adlSize);
            totalExecuted += executed;
            remainingSize -= executed;
            adlCount++;
            i++;
        }

        return (totalExecuted, adlCount);
    }

    /// @inheritdoc IADLEngine
    function setADLActive(uint32 marketId, bool active) external override onlyAdmin {
        _adlActive[marketId] = active;
    }

    /// @inheritdoc IADLEngine
    function setADLLevelThreshold(uint8 level, uint256 threshold) external override onlyAdmin {
        if (level == 0 || level > MAX_ADL_LEVEL) {
            revert PerpetualErrors.InvalidParameter("invalid ADL level");
        }
        if (threshold > BPS_PRECISION) {
            revert PerpetualErrors.InvalidParameter("threshold exceeds 100%");
        }

        _levelThresholds[level] = threshold;
    }

    /// @inheritdoc IADLEngine
    function updatePriorityQueue(uint32 marketId, PerpetualTypes.PositionSide side) external override onlyAuthorized {
        // TODO: PositionManager에서 모든 오픈 포지션 조회
        // 우선순위 계산 및 정렬

        // 우선순위 = PnL 비율 * 레버리지
        // 높은 수익 + 높은 레버리지 = 높은 ADL 우선순위

        emit PerpetualEvents.ADLPriorityUpdated(marketId, side, 0);
    }

    // ============ Admin Functions ============

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
     * @notice InsuranceFund 주소 설정
     * @param insuranceFund InsuranceFund 주소
     */
    function setInsuranceFund(address insuranceFund) external onlyAdmin {
        if (insuranceFund == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        _insuranceFund = insuranceFund;
    }

    /**
     * @notice PositionManager 주소 설정
     * @param positionManager PositionManager 주소
     */
    function setPositionManager(address positionManager) external onlyAdmin {
        if (positionManager == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        _positionManager = positionManager;
    }

    /**
     * @notice ADL 레벨 수동 설정 (긴급 상황)
     * @param marketId 마켓 ID
     * @param level ADL 레벨
     */
    function setADLLevel(uint32 marketId, uint8 level) external onlyAdmin {
        if (level > MAX_ADL_LEVEL) {
            revert PerpetualErrors.InvalidParameter("invalid ADL level");
        }
        _adlLevels[marketId] = level;
    }

    // ============ Internal Functions ============

    /**
     * @notice ADL 우선순위 계산
     * @param unrealizedPnL 미실현 PnL
     * @param margin 마진
     * @param leverage 레버리지
     * @return priority ADL 우선순위
     */
    function _calculatePriority(int256 unrealizedPnL, uint256 margin, uint256 leverage)
        internal
        pure
        returns (uint256 priority)
    {
        // 수익 포지션만 ADL 대상
        if (unrealizedPnL <= 0) {
            return 0;
        }

        // 우선순위 = (PnL / margin) * leverage
        // 높은 수익률 + 높은 레버리지 = 높은 우선순위
        if (margin == 0) {
            return 0;
        }

        uint256 pnlRatio = PerpetualMath.mulDiv(uint256(unrealizedPnL), PRECISION, margin);
        priority = pnlRatio * leverage;

        return priority;
    }

    /**
     * @notice 우선순위 큐 삽입 (정렬된 위치에)
     * @param marketId 마켓 ID
     * @param side 방향
     * @param positionKey 포지션 키
     * @param priority 우선순위
     */
    function _insertToPriorityQueue(
        uint32 marketId,
        PerpetualTypes.PositionSide side,
        bytes32 positionKey,
        uint256 priority
    ) internal {
        bytes32[] storage queue = _priorityQueues[marketId][side];

        // 우선순위 저장
        _adlPriorities[positionKey] = priority;

        // 정렬된 위치 찾기 (내림차순)
        uint256 insertIdx = queue.length;
        for (uint256 i = 0; i < queue.length; i++) {
            if (priority > _adlPriorities[queue[i]]) {
                insertIdx = i;
                break;
            }
        }

        // 삽입
        queue.push(bytes32(0)); // 공간 확보
        for (uint256 i = queue.length - 1; i > insertIdx; i--) {
            queue[i] = queue[i - 1];
        }
        queue[insertIdx] = positionKey;
    }

    /**
     * @notice 우선순위 큐에서 제거
     * @param marketId 마켓 ID
     * @param side 방향
     * @param positionKey 포지션 키
     */
    function _removeFromPriorityQueue(uint32 marketId, PerpetualTypes.PositionSide side, bytes32 positionKey) internal {
        bytes32[] storage queue = _priorityQueues[marketId][side];

        for (uint256 i = 0; i < queue.length; i++) {
            if (queue[i] == positionKey) {
                // 마지막 요소와 교체 후 삭제
                queue[i] = queue[queue.length - 1];
                queue.pop();

                // 우선순위 삭제
                delete _adlPriorities[positionKey];
                break;
            }
        }
    }
}
