// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IInsuranceFund } from "../interfaces/IInsuranceFund.sol";
import { PerpetualMath } from "../libraries/PerpetualMath.sol";
import { PerpetualErrors } from "../libraries/PerpetualErrors.sol";
import { PerpetualEvents } from "../libraries/PerpetualEvents.sol";
import { Constants } from "../../common/libraries/Constants.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title InsuranceFund
 * @author StableNet Team
 * @notice 보험 기금 관리 컨트랙트
 * @dev
 * - 청산 손실 보전
 * - 마켓별 기금 관리
 * - ADL 트리거 판단
 * - 기금 재분배
 */
contract InsuranceFund is IInsuranceFund, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PerpetualMath for uint256;

    // ============ Constants ============

    uint256 private constant PRECISION = Constants.PRECISION;
    uint256 private constant BPS_PRECISION = Constants.BPS_PRECISION;

    /// @notice 기본 ADL 임계값 (10% = 1000 BPS)
    uint256 public constant DEFAULT_ADL_THRESHOLD = 1000;

    /// @notice 최소 예비율 (5% = 500 BPS)
    uint256 public constant MIN_RESERVE_RATIO = 500;

    // ============ State Variables ============

    /// @notice 결제 토큰
    IERC20 public immutable collateralToken;

    /// @notice 총 기금 잔액
    uint256 private _totalBalance;

    /// @notice 마켓별 할당 잔액
    mapping(uint32 => uint256) private _marketBalances;

    /// @notice 공용 풀 잔액
    uint256 private _commonPoolBalance;

    /// @notice 목표 기금 금액
    uint256 private _targetAmount;

    /// @notice ADL 임계값 (BPS)
    uint256 private _adlThreshold;

    /// @notice 총 입금액
    uint256 private _totalDeposited;

    /// @notice 총 사용액
    uint256 private _totalUsed;

    /// @notice 관리자 주소
    address private _admin;

    /// @notice PerpetualEngine 주소
    address private _engine;

    /// @notice Liquidator 주소
    address private _liquidator;

    /// @notice ADLEngine 주소
    address private _adlEngine;

    // ============ Modifiers ============

    modifier onlyAuthorized() {
        if (msg.sender != _admin && msg.sender != _engine && msg.sender != _liquidator && msg.sender != _adlEngine) {
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
     * @param targetAmount 초기 목표 금액
     */
    constructor(address admin, address collateral, uint256 targetAmount) {
        if (admin == address(0) || collateral == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }

        _admin = admin;
        collateralToken = IERC20(collateral);
        _targetAmount = targetAmount;
        _adlThreshold = DEFAULT_ADL_THRESHOLD;
    }

    // ============ View Functions ============

    /// @inheritdoc IInsuranceFund
    function getTotalBalance() external view override returns (uint256 balance) {
        return _totalBalance;
    }

    /// @inheritdoc IInsuranceFund
    function getMarketBalance(uint32 marketId) external view override returns (uint256 balance) {
        return _marketBalances[marketId];
    }

    /// @inheritdoc IInsuranceFund
    function getAvailableBalance() external view override returns (uint256 available) {
        // 최소 예비율 유지 후 사용 가능 금액
        uint256 minReserve = PerpetualMath.mulDiv(_totalBalance, MIN_RESERVE_RATIO, BPS_PRECISION);
        if (_totalBalance > minReserve) {
            return _totalBalance - minReserve;
        }
        return 0;
    }

    /// @inheritdoc IInsuranceFund
    function getUsageHistory(uint64, uint64)
        external
        view
        override
        returns (uint256 totalUsed, uint256 totalDeposited)
    {
        // 간소화: 전체 기간 통계 반환
        return (_totalUsed, _totalDeposited);
    }

    /// @inheritdoc IInsuranceFund
    function getTargetAmount() external view override returns (uint256 targetAmount) {
        return _targetAmount;
    }

    /// @inheritdoc IInsuranceFund
    function getFundingRatio() external view override returns (uint256 ratio) {
        if (_targetAmount == 0) {
            return BPS_PRECISION; // 100%
        }
        return PerpetualMath.mulDiv(_totalBalance, BPS_PRECISION, _targetAmount);
    }

    /// @inheritdoc IInsuranceFund
    function getADLThreshold() external view override returns (uint256 threshold) {
        return _adlThreshold;
    }

    /// @inheritdoc IInsuranceFund
    function shouldTriggerADL() external view override returns (bool shouldTrigger) {
        if (_targetAmount == 0) {
            return false;
        }

        // 기금이 목표의 ADL 임계값 미만이면 ADL 트리거
        uint256 thresholdAmount = PerpetualMath.mulDiv(_targetAmount, _adlThreshold, BPS_PRECISION);
        return _totalBalance < thresholdAmount;
    }

    // ============ State-Changing Functions ============

    /// @inheritdoc IInsuranceFund
    function deposit(uint32 marketId, uint256 amount) external override onlyAuthorized nonReentrant {
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        // 토큰 전송
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        // 잔액 업데이트
        _marketBalances[marketId] += amount;
        _totalBalance += amount;
        _totalDeposited += amount;

        emit PerpetualEvents.InsuranceFundDeposit(amount, "liquidation", _totalBalance);
    }

    /// @inheritdoc IInsuranceFund
    function coverLoss(uint32 marketId, uint256 amount)
        external
        override
        onlyAuthorized
        nonReentrant
        returns (uint256 actualUsed)
    {
        if (amount == 0) {
            return 0;
        }

        // 마켓 잔액에서 먼저 사용
        uint256 marketBalance = _marketBalances[marketId];
        uint256 fromMarket = amount > marketBalance ? marketBalance : amount;

        if (fromMarket > 0) {
            _marketBalances[marketId] -= fromMarket;
            actualUsed += fromMarket;
        }

        // 부족분은 공용 풀에서 사용
        uint256 remaining = amount - fromMarket;
        if (remaining > 0 && _commonPoolBalance > 0) {
            uint256 fromCommon = remaining > _commonPoolBalance ? _commonPoolBalance : remaining;
            _commonPoolBalance -= fromCommon;
            actualUsed += fromCommon;
        }

        // 총 잔액 감소
        _totalBalance -= actualUsed;
        _totalUsed += actualUsed;

        if (actualUsed > 0) collateralToken.safeTransfer(msg.sender, actualUsed);
        emit PerpetualEvents.LossCovered(bytes32(uint256(marketId)), actualUsed, _totalBalance);

        return actualUsed;
    }

    /// @inheritdoc IInsuranceFund
    function adminDeposit(uint256 amount) external override onlyAdmin nonReentrant {
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        // 토큰 전송
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        // 공용 풀에 추가
        _commonPoolBalance += amount;
        _totalBalance += amount;
        _totalDeposited += amount;

        emit PerpetualEvents.InsuranceFundDeposit(amount, "admin_deposit", _totalBalance);
    }

    /// @inheritdoc IInsuranceFund
    function adminWithdraw(uint256 amount, address recipient) external override onlyAdmin nonReentrant {
        if (recipient == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        // 사용 가능 금액 확인
        uint256 minReserve = PerpetualMath.mulDiv(_totalBalance, MIN_RESERVE_RATIO, BPS_PRECISION);
        uint256 available = _totalBalance > minReserve ? _totalBalance - minReserve : 0;

        if (amount > available) {
            revert PerpetualErrors.InsufficientInsuranceFund(amount, available);
        }

        // 공용 풀에서 먼저 인출
        if (amount <= _commonPoolBalance) {
            _commonPoolBalance -= amount;
        } else {
            // 공용 풀이 부족하면 인출 불가 (마켓 할당분 보호)
            revert PerpetualErrors.InsuranceFundWithdrawNotAllowed();
        }

        _totalBalance -= amount;

        // 토큰 전송
        collateralToken.safeTransfer(recipient, amount);

        emit PerpetualEvents.InsuranceFundWithdrawal(amount, "admin_withdraw", _totalBalance);
    }

    /// @inheritdoc IInsuranceFund
    function setTargetAmount(uint256 newTarget) external override onlyAdmin {
        _targetAmount = newTarget;
    }

    /// @inheritdoc IInsuranceFund
    function setADLThreshold(uint256 newThreshold) external override onlyAdmin {
        if (newThreshold > BPS_PRECISION) {
            revert PerpetualErrors.InvalidParameter("threshold exceeds 100%");
        }
        _adlThreshold = newThreshold;
    }

    /// @inheritdoc IInsuranceFund
    function reallocate(uint32 fromMarketId, uint32 toMarketId, uint256 amount) external override onlyAdmin {
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        uint256 fromBalance = _marketBalances[fromMarketId];
        if (amount > fromBalance) {
            revert PerpetualErrors.InsufficientInsuranceFund(amount, fromBalance);
        }

        _marketBalances[fromMarketId] -= amount;
        _marketBalances[toMarketId] += amount;
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
     * @notice Liquidator 주소 설정
     * @param liquidator Liquidator 주소
     */
    function setLiquidator(address liquidator) external onlyAdmin {
        if (liquidator == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        _liquidator = liquidator;
    }

    /**
     * @notice ADLEngine 주소 설정
     * @param adlEngine ADLEngine 주소
     */
    function setADLEngine(address adlEngine) external onlyAdmin {
        if (adlEngine == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        _adlEngine = adlEngine;
    }

    /**
     * @notice 공용 풀에서 마켓으로 할당
     * @param marketId 마켓 ID
     * @param amount 할당 금액
     */
    function allocateToMarket(uint32 marketId, uint256 amount) external onlyAdmin {
        if (amount > _commonPoolBalance) {
            revert PerpetualErrors.InsufficientInsuranceFund(amount, _commonPoolBalance);
        }

        _commonPoolBalance -= amount;
        _marketBalances[marketId] += amount;
    }

    /**
     * @notice 마켓에서 공용 풀로 회수
     * @param marketId 마켓 ID
     * @param amount 회수 금액
     */
    function reclaimFromMarket(uint32 marketId, uint256 amount) external onlyAdmin {
        uint256 marketBalance = _marketBalances[marketId];
        if (amount > marketBalance) {
            revert PerpetualErrors.InsufficientInsuranceFund(amount, marketBalance);
        }

        _marketBalances[marketId] -= amount;
        _commonPoolBalance += amount;
    }
}
