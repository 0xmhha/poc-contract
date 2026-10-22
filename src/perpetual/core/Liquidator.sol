// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IPositionManager } from "../interfaces/IPositionManager.sol";
import { IMarginManager } from "../interfaces/IMarginManager.sol";
import { IInsuranceFund } from "../interfaces/IInsuranceFund.sol";
import { IADLEngine } from "../interfaces/IADLEngine.sol";
import { ILiquidator } from "../interfaces/ILiquidator.sol";
import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";
import { PerpetualMath } from "../libraries/PerpetualMath.sol";
import { PerpetualErrors } from "../libraries/PerpetualErrors.sol";
import { PerpetualEvents } from "../libraries/PerpetualEvents.sol";
import { Constants } from "../../common/libraries/Constants.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Liquidator
 * @author StableNet Team
 * @notice 포지션 청산 실행 컨트랙트
 * @dev
 * - 청산 가능 여부 확인
 * - 전체/부분 청산 실행
 * - 청산 수수료 분배
 * - 청산자 보상 관리
 * @custom:status TESTNET ONLY. Reference implementation for indexer trading venues; not audited.
 *      Uses isolated-margin settlement and records uncovered losses for ADL.
 */
contract Liquidator is ILiquidator, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PerpetualMath for uint256;

    // ============ Constants ============

    uint256 private constant PRECISION = Constants.PRECISION;
    uint256 private constant BPS_PRECISION = Constants.BPS_PRECISION;

    /// @notice 기본 청산자 수수료율 (0.5% = 50 BPS)
    uint16 public constant DEFAULT_LIQUIDATOR_FEE_BPS = 50;

    /// @notice 기본 프로토콜 수수료율 (0.25% = 25 BPS)
    uint16 public constant DEFAULT_PROTOCOL_FEE_BPS = 25;

    /// @notice 기본 보험 기금 수수료율 (0.25% = 25 BPS)
    uint16 public constant DEFAULT_INSURANCE_FEE_BPS = 25;

    /// @notice 최대 배치 청산 수
    uint256 public constant MAX_BATCH_LIQUIDATIONS = 20;

    // ============ State Variables ============

    /// @notice 결제 토큰
    IERC20 public immutable collateralToken;

    /// @notice 청산자 수수료율 (BPS)
    uint16 private _liquidatorFeeBps;

    /// @notice 프로토콜 수수료율 (BPS)
    uint16 private _protocolFeeBps;

    /// @notice 보험 기금 수수료율 (BPS)
    uint16 private _insuranceFeeBps;

    /// @notice 마켓별 최소 청산 크기
    mapping(uint32 => uint128) private _minLiquidationSizes;

    /// @notice 청산자별 대기 보상
    mapping(address => uint256) private _pendingRewards;

    /// @notice 마켓별 청산 통계
    mapping(uint32 => LiquidationStats) private _liquidationStats;

    /// @notice 누적 프로토콜 수수료
    uint256 private _accumulatedProtocolFees;

    /// @notice 관리자 주소
    address private _admin;

    /// @notice PerpetualEngine 주소
    address private _engine;

    /// @notice 보험 기금 주소
    address private _insuranceFund;

    /// @notice 청산 통계
    struct LiquidationStats {
        uint256 totalLiquidations;
        uint256 totalLiquidatedValue;
        uint256 totalFeeCollected;
    }

    IPositionManager private _positionManager;
    IMarginManager private _marginManager;
    IADLEngine private _adlEngine;

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
     * @param collateral 결제 토큰 주소
     */
    constructor(address admin, address collateral) {
        if (admin == address(0) || collateral == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }

        _admin = admin;
        collateralToken = IERC20(collateral);

        // 기본 수수료율 설정
        _liquidatorFeeBps = DEFAULT_LIQUIDATOR_FEE_BPS;
        _protocolFeeBps = DEFAULT_PROTOCOL_FEE_BPS;
        _insuranceFeeBps = DEFAULT_INSURANCE_FEE_BPS;
    }

    // ============ View Functions ============

    /// @inheritdoc ILiquidator
    function canLiquidate(bytes32 positionKey)
        external
        view
        override
        returns (bool isLiquidatable, string memory reason)
    {
        _requireConfigured();
        PerpetualTypes.Position memory pos = _positionManager.getPosition(positionKey);
        if (pos.openedAt == 0) return (false, "position not found");
        if (pos.status != PerpetualTypes.PositionStatus.Open) return (false, "position not open");
        if (!_positionManager.isLiquidatable(positionKey)) return (false, "above maintenance margin");
        return (true, "");
    }

    /// @inheritdoc ILiquidator
    function getLiquidationInfo(bytes32 positionKey)
        external
        view
        override
        returns (PerpetualTypes.LiquidationInfo memory info)
    {
        _requireConfigured();
        PerpetualTypes.Position memory pos = _positionManager.getPosition(positionKey);
        if (pos.openedAt == 0) revert PerpetualErrors.PositionNotFound(positionKey);
        if (pos.status != PerpetualTypes.PositionStatus.Open) revert PerpetualErrors.PositionNotOpen(positionKey);
        PerpetualTypes.PositionResult memory result = _positionManager.getPositionResult(positionKey);
        uint128 price = _positionManager.getMarkPrice(pos.marketId);
        uint256 fee = _totalFee(PerpetualMath.mulDiv(pos.size, price, PRECISION));
        if (fee > result.equity) fee = result.equity;
        info = PerpetualTypes.LiquidationInfo({
            positionKey: positionKey,
            trader: pos.trader,
            marketId: pos.marketId,
            side: pos.side,
            size: pos.size,
            price: price,
            pnl: result.unrealizedPnL - result.accumulatedFunding,
            liquidationFee: fee,
            remainingMargin: result.equity - fee,
            isPartial: false,
            liquidator: address(0),
            timestamp: uint64(block.timestamp)
        });
    }

    /// @inheritdoc ILiquidator
    function getLiquidationFees(uint256 positionSize, uint32 marketId)
        external
        view
        override
        returns (uint256 liquidatorFee, uint256 protocolFee, uint256 insuranceFundFee)
    {
        _requireConfigured();
        uint256 value = PerpetualMath.mulDiv(positionSize, _positionManager.getMarkPrice(marketId), PRECISION);
        liquidatorFee = PerpetualMath.mulDiv(value, _liquidatorFeeBps, BPS_PRECISION);
        protocolFee = PerpetualMath.mulDiv(value, _protocolFeeBps, BPS_PRECISION);
        insuranceFundFee = PerpetualMath.mulDiv(value, _insuranceFeeBps, BPS_PRECISION);
    }

    /// @inheritdoc ILiquidator
    function getLiquidationPrice(bytes32 positionKey) external view override returns (uint256) {
        _requireConfigured();
        return _positionManager.getLiquidationPrice(positionKey);
    }

    /// @inheritdoc ILiquidator
    function getPendingReward(address liquidator) external view override returns (uint256 pendingReward) {
        return _pendingRewards[liquidator];
    }

    /// @inheritdoc ILiquidator
    function getLiquidationStats(uint32 marketId)
        external
        view
        override
        returns (uint256 totalLiquidations, uint256 totalLiquidatedValue, uint256 totalFeeCollected)
    {
        LiquidationStats storage stats = _liquidationStats[marketId];
        return (stats.totalLiquidations, stats.totalLiquidatedValue, stats.totalFeeCollected);
    }

    // ============ State-Changing Functions ============

    /// @inheritdoc ILiquidator
    function liquidate(bytes32 positionKey) external override nonReentrant returns (uint256, uint256) {
        _requireConfigured();
        return _liquidate(positionKey, _positionManager.getPosition(positionKey).size, msg.sender);
    }

    /// @inheritdoc ILiquidator
    function partialLiquidate(bytes32 positionKey, uint128 liquidateSize)
        external
        override
        nonReentrant
        returns (uint256, uint256)
    {
        return _liquidate(positionKey, liquidateSize, msg.sender);
    }

    /// @inheritdoc ILiquidator
    function batchLiquidate(bytes32[] calldata positionKeys)
        external
        override
        nonReentrant
        returns (uint256 liquidatedCount, uint256 totalReward)
    {
        if (positionKeys.length > MAX_BATCH_LIQUIDATIONS) {
            revert PerpetualErrors.InvalidParameter("too many positions");
        }
        _requireConfigured();
        for (uint256 i = 0; i < positionKeys.length; i++) {
            // Each subcall rolls back independently. The original keeper receives rewards.
            try this.liquidateFor(positionKeys[i], msg.sender) returns (uint256, uint256 reward) {
                liquidatedCount++;
                totalReward += reward;
            } catch { }
        }
    }

    /// @notice Self-call boundary for atomic best-effort batch liquidation.
    function liquidateFor(bytes32 positionKey, address keeper) external returns (uint256, uint256) {
        if (msg.sender != address(this)) revert PerpetualErrors.Unauthorized(msg.sender);
        return _liquidate(positionKey, _positionManager.getPosition(positionKey).size, keeper);
    }

    /// @inheritdoc ILiquidator
    function claimReward() external override nonReentrant returns (uint256 amount) {
        amount = _pendingRewards[msg.sender];
        if (amount == 0) {
            return 0;
        }

        _pendingRewards[msg.sender] = 0;
        collateralToken.safeTransfer(msg.sender, amount);

        emit PerpetualEvents.LiquidationRewardPaid(msg.sender, bytes32(0), amount);
        return amount;
    }

    /// @inheritdoc ILiquidator
    function setLiquidationFees(uint16 liquidatorFeeBps, uint16 protocolFeeBps, uint16 insuranceFeeBps)
        external
        override
        onlyAdmin
    {
        // 총 수수료가 5%를 넘지 않도록
        uint256 total = uint256(liquidatorFeeBps) + protocolFeeBps + insuranceFeeBps;
        if (total > 500) {
            revert PerpetualErrors.InvalidFeeRate(total, 500);
        }

        _liquidatorFeeBps = liquidatorFeeBps;
        _protocolFeeBps = protocolFeeBps;
        _insuranceFeeBps = insuranceFeeBps;
    }

    /// @inheritdoc ILiquidator
    function setMinLiquidationSize(uint32 marketId, uint128 minSize) external override onlyAdmin {
        _minLiquidationSizes[marketId] = minSize;
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
     * @notice 보험 기금 주소 설정
     * @param insuranceFund 보험 기금 주소
     */
    function setInsuranceFund(address insuranceFund) external onlyAdmin {
        if (insuranceFund == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        _insuranceFund = insuranceFund;
    }

    /**
     * @notice 프로토콜 수수료 인출
     * @param recipient 수령자 주소
     * @param amount 인출 금액
     */
    function withdrawProtocolFees(address recipient, uint256 amount) external onlyAdmin {
        if (recipient == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        if (amount > _accumulatedProtocolFees) {
            revert PerpetualErrors.InsufficientBalance(address(this), amount, _accumulatedProtocolFees);
        }

        _accumulatedProtocolFees -= amount;
        collateralToken.safeTransfer(recipient, amount);

        emit PerpetualEvents.ProtocolFeesWithdrawn(recipient, amount);
    }

    function setPositionManager(address manager) external onlyAdmin {
        if (manager == address(0)) revert PerpetualErrors.ZeroAddress();
        _positionManager = IPositionManager(manager);
    }

    function setMarginManager(address manager) external onlyAdmin {
        if (manager == address(0)) revert PerpetualErrors.ZeroAddress();
        _marginManager = IMarginManager(manager);
    }

    function setADLEngine(address adlEngine) external onlyAdmin {
        if (adlEngine == address(0)) revert PerpetualErrors.ZeroAddress();
        _adlEngine = IADLEngine(adlEngine);
    }

    function _requireConfigured() internal view {
        if (
            address(_positionManager) == address(0) || address(_marginManager) == address(0)
                || _insuranceFund == address(0)
        ) {
            revert PerpetualErrors.NotInitialized();
        }
    }

    function _totalFee(uint256 value) internal view returns (uint256) {
        return PerpetualMath.mulDiv(value, _liquidatorFeeBps, BPS_PRECISION)
            + PerpetualMath.mulDiv(value, _protocolFeeBps, BPS_PRECISION)
            + PerpetualMath.mulDiv(value, _insuranceFeeBps, BPS_PRECISION);
    }

    function _liquidate(bytes32 key, uint128 size, address keeper) internal returns (uint256, uint256 reward) {
        _requireConfigured();
        PerpetualTypes.Position memory pos = _positionManager.getPosition(key);
        if (pos.openedAt == 0) revert PerpetualErrors.PositionNotFound(key);
        if (pos.status != PerpetualTypes.PositionStatus.Open) revert PerpetualErrors.PositionNotOpen(key);
        if (size == 0) revert PerpetualErrors.ZeroSize();
        if (size > pos.size) revert PerpetualErrors.ExceedsPositionSize(key, size, pos.size);
        PerpetualTypes.PositionResult memory result = _positionManager.getPositionResult(key);
        if (!result.isLiquidatable) {
            revert PerpetualErrors.PositionNotLiquidatable(
                key, result.marginRatio, _positionManager.getMarketConfig(pos.marketId).maintenanceMarginBps
            );
        }
        if (size != pos.size) {
            uint128 minSize = _minLiquidationSizes[pos.marketId];
            if (size < minSize || pos.size - size < minSize || result.equity == 0) {
                revert PerpetualErrors.PartialLiquidationNotAllowed(key);
            }
        }
        uint128 price = _positionManager.getMarkPrice(pos.marketId);
        (uint256 released, int256 pnl) = _positionManager.reduceForLiquidation(key, size, price);
        int256 equity = int256(released) + pnl;
        uint256 value = PerpetualMath.mulDiv(size, price, PRECISION);
        uint256 fee = _totalFee(value);
        uint256 available = equity > 0 ? uint256(equity) : 0;
        if (fee > available) fee = available;
        uint256 deficit = _marginManager.settleLiquidation(pos.trader, released, pnl, fee);
        reward = _distributeFees(pos.marketId, fee, keeper);
        if (deficit > 0) {
            uint256 covered = IInsuranceFund(_insuranceFund).coverLoss(pos.marketId, deficit);
            if (covered > 0) collateralToken.safeTransfer(address(_marginManager), covered);
            if (deficit > covered) {
                if (address(_adlEngine) == address(0)) revert PerpetualErrors.NotInitialized();
                _adlEngine.registerBankruptcy(key, pos.marketId, pos.side, size, deficit - covered);
            }
        }
        _updateStats(pos.marketId, value, fee);
        emit PerpetualEvents.PositionLiquidated(key, pos.trader, keeper, size, price, pnl, fee);
        return (size, reward);
    }

    function _distributeFees(uint32 marketId, uint256 fee, address keeper) internal returns (uint256 reward) {
        if (fee == 0) return 0;
        uint256 totalBps = uint256(_liquidatorFeeBps) + _protocolFeeBps + _insuranceFeeBps;
        reward = PerpetualMath.mulDiv(fee, _liquidatorFeeBps, totalBps);
        uint256 insuranceFee = PerpetualMath.mulDiv(fee, _insuranceFeeBps, totalBps);
        _pendingRewards[keeper] += reward;
        _accumulatedProtocolFees += fee - reward - insuranceFee;
        if (insuranceFee > 0) {
            collateralToken.forceApprove(_insuranceFund, insuranceFee);
            IInsuranceFund(_insuranceFund).deposit(marketId, insuranceFee);
        }
    }

    function _updateStats(uint32 marketId, uint256 liquidatedValue, uint256 fee) internal {
        LiquidationStats storage stats = _liquidationStats[marketId];
        stats.totalLiquidations++;
        stats.totalLiquidatedValue += liquidatedValue;
        stats.totalFeeCollected += fee;
    }
}
