// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IPositionManager } from "../interfaces/IPositionManager.sol";
import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";
import { PerpetualMath } from "../libraries/PerpetualMath.sol";
import { PerpetualErrors } from "../libraries/PerpetualErrors.sol";
import { PerpetualEvents } from "../libraries/PerpetualEvents.sol";
import { Constants } from "../../common/libraries/Constants.sol";

/**
 * @title PositionManager
 * @author StableNet Team
 * @notice 포지션 관리 컨트랙트
 * @dev
 * - 포지션 CRUD (생성, 조회, 수정, 삭제)
 * - PnL 계산
 * - 청산가 계산
 * - 펀딩비 정산
 */
contract PositionManager is IPositionManager {
    using PerpetualMath for uint256;
    using PerpetualMath for int256;

    // ============ Constants ============

    uint256 private constant PRECISION = Constants.PRECISION;
    uint256 private constant BPS_PRECISION = Constants.BPS_PRECISION;

    // ============ State Variables ============

    /// @notice 오라클 주소 (마크 가격 조회용)
    address public markPriceOracle;

    /// @notice 마켓 설정 (마켓 ID => 설정)
    mapping(uint32 => PerpetualTypes.MarketConfig) private _marketConfigs;

    /// @notice 포지션 저장소
    mapping(bytes32 => PerpetualTypes.Position) private _positions;

    /// @notice 트레이더별 포지션 목록
    mapping(address => bytes32[]) private _traderPositions;

    /// @notice 트레이더 포지션 인덱스
    mapping(address => mapping(bytes32 => uint256)) private _traderPositionIndex;

    /// @notice 마켓별 Open Interest
    mapping(uint32 => mapping(PerpetualTypes.PositionSide => uint256)) private _openInterest;

    /// @notice 마켓별 누적 펀딩 인덱스
    mapping(uint32 => int64) private _cumulativeFundingIndex;

    /// @notice 관리자 주소
    address private _admin;

    /// @notice PerpetualEngine 주소 (권한 있는 호출자)
    address private _engine;

    // ============ Modifiers ============

    /// @notice 권한 있는 호출자만 허용
    modifier onlyAuthorized() {
        if (msg.sender != _admin && msg.sender != _engine) {
            revert PerpetualErrors.Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice 관리자만 허용
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
    }

    // ============ View Functions ============

    /// @inheritdoc IPositionManager
    function getPosition(bytes32 positionKey) external view override returns (PerpetualTypes.Position memory) {
        return _positions[positionKey];
    }

    /// @inheritdoc IPositionManager
    function getPositionKey(address trader, uint32 marketId, PerpetualTypes.PositionSide side)
        external
        pure
        override
        returns (bytes32 positionKey)
    {
        return _computePositionKey(trader, marketId, side);
    }

    /// @inheritdoc IPositionManager
    function positionExists(bytes32 positionKey) external view override returns (bool) {
        return _positions[positionKey].openedAt != 0;
    }

    /// @inheritdoc IPositionManager
    function getPositionResult(bytes32 positionKey)
        external
        view
        override
        returns (PerpetualTypes.PositionResult memory result)
    {
        PerpetualTypes.Position storage pos = _positions[positionKey];
        if (pos.openedAt == 0) {
            revert PerpetualErrors.PositionNotFound(positionKey);
        }

        uint256 markPrice = _getMarkPrice(pos.marketId);
        bool isLong = pos.side == PerpetualTypes.PositionSide.Long;

        // 미실현 PnL
        result.unrealizedPnL = PerpetualMath.calculateUnrealizedPnL(pos.entryPrice, markPrice, pos.size, isLong);

        // 펀딩비
        int64 currentFundingIndex = _cumulativeFundingIndex[pos.marketId];
        result.accumulatedFunding =
            PerpetualMath.calculateFundingPayment(pos.size, currentFundingIndex, pos.lastFundingIndex, isLong);

        // 마진 비율
        result.marginRatio = PerpetualMath.calculateMarginRatio(
            pos.margin, result.unrealizedPnL, result.accumulatedFunding, pos.size, markPrice
        );

        // 청산가
        PerpetualTypes.MarketConfig storage config = _marketConfigs[pos.marketId];
        result.liquidationPrice = PerpetualMath.calculateLiquidationPrice(
            pos.entryPrice, pos.margin, pos.size, config.maintenanceMarginBps, isLong
        );

        // 순자산
        int256 equitySigned = int256(uint256(pos.margin)) + result.unrealizedPnL - result.accumulatedFunding;
        result.equity = equitySigned > 0 ? uint256(equitySigned) : 0;

        // 청산 가능 여부
        result.isLiquidatable = PerpetualMath.isLiquidatable(result.marginRatio, config.maintenanceMarginBps);
    }

    /// @inheritdoc IPositionManager
    function getUnrealizedPnL(bytes32 positionKey) external view override returns (int256 pnl) {
        PerpetualTypes.Position storage pos = _positions[positionKey];
        if (pos.openedAt == 0) {
            return 0;
        }

        uint256 markPrice = _getMarkPrice(pos.marketId);
        bool isLong = pos.side == PerpetualTypes.PositionSide.Long;

        return PerpetualMath.calculateUnrealizedPnL(pos.entryPrice, markPrice, pos.size, isLong);
    }

    /// @inheritdoc IPositionManager
    function getMarginRatio(bytes32 positionKey) external view override returns (uint256 ratio) {
        PerpetualTypes.Position storage pos = _positions[positionKey];
        if (pos.openedAt == 0) {
            return type(uint256).max;
        }

        uint256 markPrice = _getMarkPrice(pos.marketId);
        bool isLong = pos.side == PerpetualTypes.PositionSide.Long;

        int256 unrealizedPnL = PerpetualMath.calculateUnrealizedPnL(pos.entryPrice, markPrice, pos.size, isLong);
        int64 currentFundingIndex = _cumulativeFundingIndex[pos.marketId];
        int256 fundingPayment =
            PerpetualMath.calculateFundingPayment(pos.size, currentFundingIndex, pos.lastFundingIndex, isLong);

        return PerpetualMath.calculateMarginRatio(pos.margin, unrealizedPnL, fundingPayment, pos.size, markPrice);
    }

    /// @inheritdoc IPositionManager
    function getLiquidationPrice(bytes32 positionKey) external view override returns (uint256 liquidationPrice) {
        PerpetualTypes.Position storage pos = _positions[positionKey];
        if (pos.openedAt == 0) {
            return 0;
        }

        PerpetualTypes.MarketConfig storage config = _marketConfigs[pos.marketId];
        bool isLong = pos.side == PerpetualTypes.PositionSide.Long;

        return PerpetualMath.calculateLiquidationPrice(
            pos.entryPrice, pos.margin, pos.size, config.maintenanceMarginBps, isLong
        );
    }

    /// @inheritdoc IPositionManager
    function isLiquidatable(bytes32 positionKey) external view override returns (bool) {
        PerpetualTypes.Position storage pos = _positions[positionKey];
        if (pos.openedAt == 0 || pos.status != PerpetualTypes.PositionStatus.Open) {
            return false;
        }

        uint256 markPrice = _getMarkPrice(pos.marketId);
        bool isLong = pos.side == PerpetualTypes.PositionSide.Long;

        int256 unrealizedPnL = PerpetualMath.calculateUnrealizedPnL(pos.entryPrice, markPrice, pos.size, isLong);
        int64 currentFundingIndex = _cumulativeFundingIndex[pos.marketId];
        int256 fundingPayment =
            PerpetualMath.calculateFundingPayment(pos.size, currentFundingIndex, pos.lastFundingIndex, isLong);

        uint256 marginRatio =
            PerpetualMath.calculateMarginRatio(pos.margin, unrealizedPnL, fundingPayment, pos.size, markPrice);

        PerpetualTypes.MarketConfig storage config = _marketConfigs[pos.marketId];
        return PerpetualMath.isLiquidatable(marginRatio, config.maintenanceMarginBps);
    }

    /// @inheritdoc IPositionManager
    function getTraderPositions(address trader) external view override returns (bytes32[] memory positionKeys) {
        return _traderPositions[trader];
    }

    /// @inheritdoc IPositionManager
    function getOpenInterest(uint32 marketId, PerpetualTypes.PositionSide side)
        external
        view
        override
        returns (uint256 oi)
    {
        return _openInterest[marketId][side];
    }

    // ============ State-Changing Functions ============

    /// @inheritdoc IPositionManager
    function openPosition(
        address trader,
        uint32 marketId,
        PerpetualTypes.PositionSide side,
        uint128 size,
        uint128 margin,
        uint8 leverage,
        uint128 entryPrice
    ) external override onlyAuthorized returns (bytes32 positionKey) {
        if (trader == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        if (size == 0) {
            revert PerpetualErrors.ZeroSize();
        }
        if (margin == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        positionKey = _computePositionKey(trader, marketId, side);

        // 기존 포지션 확인
        if (_positions[positionKey].openedAt != 0) {
            revert PerpetualErrors.PositionAlreadyExists(positionKey);
        }

        // 레버리지 검증
        PerpetualTypes.MarketConfig storage config = _marketConfigs[marketId];
        if (leverage == 0 || leverage > config.maxLeverage) {
            revert PerpetualErrors.InvalidLeverage(leverage, 1, config.maxLeverage);
        }

        // OI 한도 확인
        uint256 newOI = _openInterest[marketId][side] + size;
        if (newOI > config.maxOpenInterest) {
            revert PerpetualErrors.OpenInterestLimitExceeded(marketId, newOI, config.maxOpenInterest);
        }

        // 포지션 생성
        _positions[positionKey] = PerpetualTypes.Position({
            trader: trader,
            marketId: marketId,
            side: side,
            status: PerpetualTypes.PositionStatus.Open,
            marginMode: PerpetualTypes.MarginMode.Isolated,
            leverage: leverage,
            reserved: 0,
            size: size,
            margin: margin,
            entryPrice: entryPrice,
            lastFundingIndex: _cumulativeFundingIndex[marketId],
            openedAt: uint64(block.timestamp)
        });

        // 트레이더 포지션 목록에 추가
        _traderPositions[trader].push(positionKey);
        _traderPositionIndex[trader][positionKey] = _traderPositions[trader].length;

        // OI 업데이트
        _openInterest[marketId][side] = newOI;

        emit PerpetualEvents.PositionOpened(positionKey, trader, marketId, side, size, entryPrice, margin, leverage);
    }

    /// @inheritdoc IPositionManager
    function increasePosition(bytes32 positionKey, uint128 addSize, uint128 addMargin, uint128 price)
        external
        override
        onlyAuthorized
    {
        PerpetualTypes.Position storage pos = _positions[positionKey];

        if (pos.openedAt == 0) {
            revert PerpetualErrors.PositionNotFound(positionKey);
        }
        if (pos.status != PerpetualTypes.PositionStatus.Open) {
            revert PerpetualErrors.PositionNotOpen(positionKey);
        }
        if (addSize == 0) {
            revert PerpetualErrors.ZeroSize();
        }

        // OI 한도 확인
        PerpetualTypes.MarketConfig storage config = _marketConfigs[pos.marketId];
        uint256 newOI = _openInterest[pos.marketId][pos.side] + addSize;
        if (newOI > config.maxOpenInterest) {
            revert PerpetualErrors.OpenInterestLimitExceeded(pos.marketId, newOI, config.maxOpenInterest);
        }

        // 평균 진입가 계산
        uint256 newEntryPrice = PerpetualMath.calculateAverageEntryPrice(pos.size, pos.entryPrice, addSize, price);

        // 포지션 업데이트
        uint128 newSize = pos.size + addSize;
        pos.size = newSize;
        pos.margin = pos.margin + addMargin;
        pos.entryPrice = uint128(newEntryPrice);

        // OI 업데이트
        _openInterest[pos.marketId][pos.side] = newOI;

        emit PerpetualEvents.PositionIncreased(positionKey, pos.trader, addSize, addMargin, newEntryPrice, newSize);
    }

    /// @inheritdoc IPositionManager
    function decreasePosition(bytes32 positionKey, uint128 reduceSize, uint128 exitPrice)
        external
        override
        onlyAuthorized
        returns (int256 realizedPnL)
    {
        PerpetualTypes.Position storage pos = _positions[positionKey];

        if (pos.openedAt == 0) {
            revert PerpetualErrors.PositionNotFound(positionKey);
        }
        if (pos.status != PerpetualTypes.PositionStatus.Open) {
            revert PerpetualErrors.PositionNotOpen(positionKey);
        }
        if (reduceSize == 0) {
            revert PerpetualErrors.ZeroSize();
        }
        if (reduceSize > pos.size) {
            revert PerpetualErrors.ExceedsPositionSize(positionKey, reduceSize, pos.size);
        }

        bool isLong = pos.side == PerpetualTypes.PositionSide.Long;

        // 실현 PnL 계산
        realizedPnL = PerpetualMath.calculateRealizedPnL(pos.entryPrice, exitPrice, reduceSize, isLong);

        // 마진 비례 감소
        uint128 releasedMargin = uint128(uint256(pos.margin) * reduceSize / pos.size);

        // 포지션 업데이트
        uint128 remainingSize = pos.size - reduceSize;
        pos.size = remainingSize;
        pos.margin = pos.margin - releasedMargin;

        // OI 업데이트
        _openInterest[pos.marketId][pos.side] -= reduceSize;

        // 완전 종료 시 상태 변경
        if (remainingSize == 0) {
            pos.status = PerpetualTypes.PositionStatus.Closed;
            _removeFromTraderPositions(pos.trader, positionKey);
        }

        emit PerpetualEvents.PositionDecreased(
            positionKey, pos.trader, reduceSize, exitPrice, realizedPnL, remainingSize
        );
    }

    /// @inheritdoc IPositionManager
    function closePosition(bytes32 positionKey, uint128 exitPrice)
        external
        override
        onlyAuthorized
        returns (int256 realizedPnL)
    {
        PerpetualTypes.Position storage pos = _positions[positionKey];

        if (pos.openedAt == 0) {
            revert PerpetualErrors.PositionNotFound(positionKey);
        }
        if (pos.status != PerpetualTypes.PositionStatus.Open) {
            revert PerpetualErrors.PositionNotOpen(positionKey);
        }

        bool isLong = pos.side == PerpetualTypes.PositionSide.Long;

        // 실현 PnL 계산
        realizedPnL = PerpetualMath.calculateRealizedPnL(pos.entryPrice, exitPrice, pos.size, isLong);

        // OI 업데이트
        _openInterest[pos.marketId][pos.side] -= pos.size;

        // 포지션 종료
        uint128 closedSize = pos.size;
        pos.size = 0;
        pos.margin = 0;
        pos.status = PerpetualTypes.PositionStatus.Closed;

        // 트레이더 목록에서 제거
        _removeFromTraderPositions(pos.trader, positionKey);

        emit PerpetualEvents.PositionClosed(positionKey, pos.trader, exitPrice, realizedPnL, 0);

        // PositionDecreased도 발생
        emit PerpetualEvents.PositionDecreased(positionKey, pos.trader, closedSize, exitPrice, realizedPnL, 0);
    }

    /// @inheritdoc IPositionManager
    function addMargin(bytes32 positionKey, uint128 addMargin) external override onlyAuthorized {
        PerpetualTypes.Position storage pos = _positions[positionKey];

        if (pos.openedAt == 0) {
            revert PerpetualErrors.PositionNotFound(positionKey);
        }
        if (pos.status != PerpetualTypes.PositionStatus.Open) {
            revert PerpetualErrors.PositionNotOpen(positionKey);
        }
        if (addMargin == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        uint128 newMargin = pos.margin + addMargin;
        pos.margin = newMargin;

        emit PerpetualEvents.MarginAdded(positionKey, pos.trader, addMargin, newMargin);
    }

    /// @inheritdoc IPositionManager
    function removeMargin(bytes32 positionKey, uint128 removeMargin) external override onlyAuthorized {
        PerpetualTypes.Position storage pos = _positions[positionKey];

        if (pos.openedAt == 0) {
            revert PerpetualErrors.PositionNotFound(positionKey);
        }
        if (pos.status != PerpetualTypes.PositionStatus.Open) {
            revert PerpetualErrors.PositionNotOpen(positionKey);
        }
        if (removeMargin == 0) {
            revert PerpetualErrors.ZeroAmount();
        }
        if (removeMargin > pos.margin) {
            revert PerpetualErrors.CannotRemoveMargin(positionKey, removeMargin, pos.margin);
        }

        // 마진 제거 후 청산가 확인
        uint128 newMargin = pos.margin - removeMargin;
        PerpetualTypes.MarketConfig storage config = _marketConfigs[pos.marketId];
        uint256 markPrice = _getMarkPrice(pos.marketId);
        bool isLong = pos.side == PerpetualTypes.PositionSide.Long;

        int256 unrealizedPnL = PerpetualMath.calculateUnrealizedPnL(pos.entryPrice, markPrice, pos.size, isLong);
        int64 currentFundingIndex = _cumulativeFundingIndex[pos.marketId];
        int256 fundingPayment =
            PerpetualMath.calculateFundingPayment(pos.size, currentFundingIndex, pos.lastFundingIndex, isLong);

        uint256 newMarginRatio =
            PerpetualMath.calculateMarginRatio(newMargin, unrealizedPnL, fundingPayment, pos.size, markPrice);

        // 초기 마진율 이상 유지해야 함
        if (newMarginRatio <= config.initialMarginBps) {
            revert PerpetualErrors.CannotRemoveMargin(positionKey, removeMargin, pos.margin);
        }

        pos.margin = newMargin;

        emit PerpetualEvents.MarginRemoved(positionKey, pos.trader, removeMargin, newMargin);
    }

    /// @inheritdoc IPositionManager
    function settleFunding(bytes32 positionKey, int64 cumulativeFundingIndex)
        external
        override
        onlyAuthorized
        returns (int256 fundingPayment)
    {
        PerpetualTypes.Position storage pos = _positions[positionKey];

        if (pos.openedAt == 0) {
            revert PerpetualErrors.PositionNotFound(positionKey);
        }
        if (pos.status != PerpetualTypes.PositionStatus.Open) {
            return 0;
        }

        bool isLong = pos.side == PerpetualTypes.PositionSide.Long;

        // 펀딩비 계산
        fundingPayment =
            PerpetualMath.calculateFundingPayment(pos.size, cumulativeFundingIndex, pos.lastFundingIndex, isLong);

        // 마지막 펀딩 인덱스 업데이트
        pos.lastFundingIndex = cumulativeFundingIndex;

        emit PerpetualEvents.PositionFundingSettled(positionKey, pos.trader, fundingPayment);
    }

    /// @inheritdoc IPositionManager
    function liquidatePosition(bytes32 positionKey, uint128 liquidationPrice)
        external
        override
        onlyAuthorized
        returns (int256 remainingMargin)
    {
        PerpetualTypes.Position storage pos = _positions[positionKey];

        if (pos.openedAt == 0) {
            revert PerpetualErrors.PositionNotFound(positionKey);
        }
        if (pos.status != PerpetualTypes.PositionStatus.Open) {
            revert PerpetualErrors.PositionNotOpen(positionKey);
        }

        bool isLong = pos.side == PerpetualTypes.PositionSide.Long;

        // PnL 계산
        int256 pnl = PerpetualMath.calculateRealizedPnL(pos.entryPrice, liquidationPrice, pos.size, isLong);

        // 청산 수수료 계산
        PerpetualTypes.MarketConfig storage config = _marketConfigs[pos.marketId];
        uint256 notionalValue = PerpetualMath.mulDiv(pos.size, liquidationPrice, PRECISION);
        uint256 liquidationFee = PerpetualMath.calculateLiquidationFee(notionalValue, config.liquidationFeeBps);

        // 잔여 마진 계산 (마진 + PnL - 수수료)
        remainingMargin = int256(uint256(pos.margin)) + pnl - int256(liquidationFee);

        // OI 업데이트
        _openInterest[pos.marketId][pos.side] -= pos.size;

        // 포지션 청산 처리
        uint128 liquidatedSize = pos.size;
        pos.size = 0;
        pos.margin = 0;
        pos.status = PerpetualTypes.PositionStatus.Liquidated;

        // 트레이더 목록에서 제거
        _removeFromTraderPositions(pos.trader, positionKey);

        emit PerpetualEvents.PositionLiquidated(
            positionKey, pos.trader, msg.sender, liquidatedSize, liquidationPrice, pnl, liquidationFee
        );
    }

    // ============ Admin Functions ============

    /**
     * @notice 마켓 설정 업데이트
     * @param marketId 마켓 ID
     * @param config 마켓 설정
     */
    function setMarketConfig(uint32 marketId, PerpetualTypes.MarketConfig calldata config) external onlyAdmin {
        _marketConfigs[marketId] = config;
    }

    /**
     * @notice 누적 펀딩 인덱스 업데이트
     * @param marketId 마켓 ID
     * @param fundingIndex 새 펀딩 인덱스
     */
    function updateCumulativeFundingIndex(uint32 marketId, int64 fundingIndex) external onlyAuthorized {
        _cumulativeFundingIndex[marketId] = fundingIndex;
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
     * @notice 오라클 주소 설정
     * @param oracle 오라클 주소
     */
    function setMarkPriceOracle(address oracle) external onlyAdmin {
        if (oracle == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        markPriceOracle = oracle;
    }

    // ============ Internal Functions ============

    /**
     * @notice 포지션 키 계산
     * @param trader 트레이더 주소
     * @param marketId 마켓 ID
     * @param side 포지션 방향
     * @return 포지션 키
     */
    function _computePositionKey(address trader, uint32 marketId, PerpetualTypes.PositionSide side)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(trader, marketId, uint8(side)));
    }

    /**
     * @notice 트레이더 포지션 목록에서 제거
     * @param trader 트레이더 주소
     * @param positionKey 포지션 키
     */
    function _removeFromTraderPositions(address trader, bytes32 positionKey) internal {
        uint256 indexPlusOne = _traderPositionIndex[trader][positionKey];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _traderPositions[trader].length - 1;

        if (index != lastIndex) {
            bytes32 lastKey = _traderPositions[trader][lastIndex];
            _traderPositions[trader][index] = lastKey;
            _traderPositionIndex[trader][lastKey] = indexPlusOne;
        }

        _traderPositions[trader].pop();
        delete _traderPositionIndex[trader][positionKey];
    }

    /**
     * @notice 마크 가격 조회 (임시 구현)
     * @param marketId 마켓 ID
     * @return 마크 가격
     */
    function _getMarkPrice(uint32 marketId) internal view returns (uint256) {
        // TODO: 실제 오라클 연동
        // 임시로 1e18 반환 (1:1)
        if (markPriceOracle == address(0)) {
            return PRECISION;
        }
        // 실제 구현 시 오라클 호출
        (bool success, bytes memory data) =
            markPriceOracle.staticcall(abi.encodeWithSignature("getMarkPrice(uint32)", marketId));
        if (success && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return PRECISION;
    }
}
