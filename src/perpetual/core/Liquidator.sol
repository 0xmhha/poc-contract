// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
 *      liquidate() is a placeholder that liquidates nothing.
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
        // TODO: 실제 구현 시 PositionManager에서 포지션 정보 조회
        // 마진 비율 확인 및 청산 가능 여부 판단

        // 임시: 항상 false 반환
        return (false, "position not found");
    }

    /// @inheritdoc ILiquidator
    function getLiquidationInfo(bytes32 positionKey)
        external
        view
        override
        returns (PerpetualTypes.LiquidationInfo memory info)
    {
        // TODO: 실제 구현 시 PositionManager에서 포지션 정보 조회
        // 청산 정보 생성

        info = PerpetualTypes.LiquidationInfo({
            positionKey: positionKey,
            trader: address(0),
            marketId: 0,
            side: PerpetualTypes.PositionSide.Long,
            size: 0,
            price: 0,
            pnl: 0,
            liquidationFee: 0,
            remainingMargin: 0,
            isPartial: false,
            liquidator: address(0),
            timestamp: 0
        });
    }

    /// @inheritdoc ILiquidator
    function getLiquidationFees(uint256 positionSize, uint32 marketId)
        external
        view
        override
        returns (uint256 liquidatorFee, uint256 protocolFee, uint256 insuranceFundFee)
    {
        uint256 totalValue = positionSize; // 실제로는 size * price

        liquidatorFee = PerpetualMath.mulDiv(totalValue, _liquidatorFeeBps, BPS_PRECISION);
        protocolFee = PerpetualMath.mulDiv(totalValue, _protocolFeeBps, BPS_PRECISION);
        insuranceFundFee = PerpetualMath.mulDiv(totalValue, _insuranceFeeBps, BPS_PRECISION);
    }

    /// @inheritdoc ILiquidator
    function getLiquidationPrice(bytes32 positionKey) external view override returns (uint256 liquidationPrice) {
        // TODO: 실제 구현 시 PositionManager에서 포지션 정보 조회 후 청산가 계산
        return 0;
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
    function liquidate(bytes32 positionKey)
        external
        override
        nonReentrant
        returns (uint256 liquidatedSize, uint256 liquidatorReward)
    {
        // 청산 가능 여부 확인
        (bool canLiq, string memory reason) = this.canLiquidate(positionKey);
        if (!canLiq) {
            revert PerpetualErrors.PositionNotLiquidatable(positionKey, 0, 0);
        }

        // TODO: 실제 구현 시 PositionManager를 통해 포지션 청산 실행
        // 1. 포지션 정보 조회
        // 2. 청산가 계산
        // 3. 포지션 종료
        // 4. 수수료 분배
        // 5. 잔여 마진 처리

        // 임시 구현
        liquidatedSize = 0;
        liquidatorReward = 0;
    }

    /// @inheritdoc ILiquidator
    function partialLiquidate(bytes32 positionKey, uint128 liquidateSize)
        external
        override
        nonReentrant
        returns (uint256 actualLiquidatedSize, uint256 liquidatorReward)
    {
        // 청산 가능 여부 확인
        (bool canLiq,) = this.canLiquidate(positionKey);
        if (!canLiq) {
            revert PerpetualErrors.PositionNotLiquidatable(positionKey, 0, 0);
        }

        // 부분 청산 허용 여부 확인
        // TODO: 실제 구현

        actualLiquidatedSize = liquidateSize;
        liquidatorReward = 0;
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

        for (uint256 i = 0; i < positionKeys.length; i++) {
            (bool canLiq,) = this.canLiquidate(positionKeys[i]);
            if (canLiq) {
                try this.liquidate(positionKeys[i]) returns (uint256, uint256 reward) {
                    liquidatedCount++;
                    totalReward += reward;
                } catch {
                    // 개별 청산 실패는 무시하고 계속 진행
                    continue;
                }
            }
        }

        return (liquidatedCount, totalReward);
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
        if (liquidatorFeeBps + protocolFeeBps + insuranceFeeBps > 500) {
            revert PerpetualErrors.InvalidFeeRate(liquidatorFeeBps + protocolFeeBps + insuranceFeeBps, 500);
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

    // ============ Internal Functions ============

    /**
     * @notice 청산 수수료 분배
     * @param positionValue 포지션 가치
     * @param liquidator 청산자 주소
     */
    function _distributeFees(uint256 positionValue, address liquidator) internal {
        uint256 liquidatorFee = PerpetualMath.mulDiv(positionValue, _liquidatorFeeBps, BPS_PRECISION);
        uint256 protocolFee = PerpetualMath.mulDiv(positionValue, _protocolFeeBps, BPS_PRECISION);
        uint256 insuranceFee = PerpetualMath.mulDiv(positionValue, _insuranceFeeBps, BPS_PRECISION);

        // 청산자 보상 적립
        _pendingRewards[liquidator] += liquidatorFee;

        // 프로토콜 수수료 적립
        _accumulatedProtocolFees += protocolFee;

        // 보험 기금 수수료 전송
        if (_insuranceFund != address(0) && insuranceFee > 0) {
            collateralToken.safeTransfer(_insuranceFund, insuranceFee);
        }
    }

    /**
     * @notice 청산 통계 업데이트
     * @param marketId 마켓 ID
     * @param liquidatedValue 청산 가치
     * @param fee 수수료
     */
    function _updateStats(uint32 marketId, uint256 liquidatedValue, uint256 fee) internal {
        LiquidationStats storage stats = _liquidationStats[marketId];
        stats.totalLiquidations++;
        stats.totalLiquidatedValue += liquidatedValue;
        stats.totalFeeCollected += fee;
    }
}
