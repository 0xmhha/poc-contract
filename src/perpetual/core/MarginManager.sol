// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IMarginManager } from "../interfaces/IMarginManager.sol";
import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";
import { PerpetualMath } from "../libraries/PerpetualMath.sol";
import { PerpetualErrors } from "../libraries/PerpetualErrors.sol";
import { PerpetualEvents } from "../libraries/PerpetualEvents.sol";
import { Constants } from "../../common/libraries/Constants.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MarginManager
 * @author StableNet Team
 * @notice 마진 관리 컨트랙트
 * @dev
 * - 교차 마진 계정 관리
 * - 격리 마진 관리
 * - 마진 입금/출금
 * - 마진 락/언락
 */
contract MarginManager is IMarginManager, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PerpetualMath for uint256;

    // ============ Constants ============

    uint256 private constant PRECISION = Constants.PRECISION;
    uint256 private constant BPS_PRECISION = Constants.BPS_PRECISION;

    // ============ State Variables ============

    /// @notice 결제 토큰 (USDC 등)
    IERC20 public immutable collateralToken;

    /// @notice 교차 마진 계정 (트레이더 => 잔액 정보)
    mapping(address => CrossMarginAccountData) private _crossMarginAccounts;

    /// @notice 격리 마진 (포지션 키 => 마진)
    mapping(bytes32 => uint256) private _isolatedMargins;

    /// @notice 마진 모드 (트레이더 => 마켓 ID => 모드)
    mapping(address => mapping(uint32 => PerpetualTypes.MarginMode)) private _marginModes;

    /// @notice 관리자 주소
    address private _admin;

    /// @notice PerpetualEngine 주소
    address private _engine;

    /// @notice 교차 마진 계정 데이터
    struct CrossMarginAccountData {
        uint256 balance; // 가용 잔액
        uint256 lockedMargin; // 포지션에 락된 마진
        int256 unrealizedPnL; // 미실현 PnL (외부에서 업데이트)
    }

    address private _liquidator;
    address private _adlEngine;

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
        // This reference ledger uses 18 decimals for both collateral and prices.
        if (IERC20Metadata(collateral).decimals() != 18) revert PerpetualErrors.TokenNotSupported(collateral);
        _admin = admin;
        collateralToken = IERC20(collateral);
    }

    // ============ View Functions ============

    /// @inheritdoc IMarginManager
    function getCrossMarginAccount(address trader)
        external
        view
        override
        returns (PerpetualTypes.CrossMarginAccount memory account)
    {
        CrossMarginAccountData storage data = _crossMarginAccounts[trader];
        int256 equity = int256(data.balance) - int256(data.lockedMargin) + data.unrealizedPnL;

        account = PerpetualTypes.CrossMarginAccount({
            trader: trader,
            balance: data.balance,
            lockedMargin: data.lockedMargin,
            unrealizedPnL: data.unrealizedPnL > 0 ? uint256(data.unrealizedPnL) : 0,
            totalEquity: equity > 0 ? uint256(equity) : 0
        });
    }

    /// @inheritdoc IMarginManager
    function getAvailableMargin(address trader) external view override returns (uint256 available) {
        CrossMarginAccountData storage data = _crossMarginAccounts[trader];
        if (data.balance <= data.lockedMargin) {
            return 0;
        }
        return data.balance - data.lockedMargin;
    }

    /// @inheritdoc IMarginManager
    function getLockedMargin(address trader) external view override returns (uint256 locked) {
        return _crossMarginAccounts[trader].lockedMargin;
    }

    /// @inheritdoc IMarginManager
    function getTotalEquity(address trader) external view override returns (uint256 equity) {
        CrossMarginAccountData storage data = _crossMarginAccounts[trader];
        int256 equitySigned = int256(data.balance) + data.unrealizedPnL;
        return equitySigned > 0 ? uint256(equitySigned) : 0;
    }

    /// @inheritdoc IMarginManager
    function getCrossMarginRatio(address trader) external view override returns (uint256 ratio) {
        CrossMarginAccountData storage data = _crossMarginAccounts[trader];
        if (data.lockedMargin == 0) {
            return type(uint256).max;
        }

        int256 equity = int256(data.balance) + data.unrealizedPnL;
        if (equity <= 0) {
            return 0;
        }

        // ratio = equity / lockedMargin * BPS
        return PerpetualMath.mulDiv(uint256(equity), BPS_PRECISION, data.lockedMargin);
    }

    /// @inheritdoc IMarginManager
    function getIsolatedMargin(bytes32 positionKey) external view override returns (uint256 margin) {
        return _isolatedMargins[positionKey];
    }

    /// @inheritdoc IMarginManager
    function getMarginMode(address trader, uint32 marketId)
        external
        view
        override
        returns (PerpetualTypes.MarginMode mode)
    {
        return _marginModes[trader][marketId];
    }

    /// @inheritdoc IMarginManager
    function calculateRequiredMargin(uint256 size, uint256 price, uint256 leverage)
        external
        pure
        override
        returns (uint256 required)
    {
        return PerpetualMath.calculateRequiredMargin(size, price, leverage);
    }

    /// @inheritdoc IMarginManager
    function getRemovableMargin(address trader, bytes32 positionKey)
        external
        view
        override
        returns (uint256 removable)
    {
        // 격리 마진인 경우
        uint256 isolatedMargin = _isolatedMargins[positionKey];
        if (isolatedMargin > 0) {
            // TODO: 실제 구현 시 청산가 계산 후 제거 가능 마진 반환
            return isolatedMargin / 2; // 임시: 50%까지 제거 가능
        }

        // 교차 마진인 경우
        CrossMarginAccountData storage data = _crossMarginAccounts[trader];
        if (data.balance <= data.lockedMargin) {
            return 0;
        }

        // TODO: 실제 구현 시 마진 비율 계산 후 제거 가능 금액 반환
        return (data.balance - data.lockedMargin) / 2; // 임시: 50%까지 제거 가능
    }

    // ============ State-Changing Functions ============

    /// @inheritdoc IMarginManager
    function depositMargin(address trader, uint256 amount) external override nonReentrant onlyAuthorized {
        if (trader == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        // 토큰 전송 (호출자로부터)
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        // 잔액 증가
        _crossMarginAccounts[trader].balance += amount;

        emit PerpetualEvents.MarginDeposited(trader, amount, _crossMarginAccounts[trader].balance);
    }

    /// @inheritdoc IMarginManager
    function withdrawMargin(address trader, uint256 amount) external override nonReentrant onlyAuthorized {
        if (trader == address(0)) {
            revert PerpetualErrors.ZeroAddress();
        }
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        CrossMarginAccountData storage data = _crossMarginAccounts[trader];

        uint256 available = data.balance > data.lockedMargin ? data.balance - data.lockedMargin : 0;
        if (amount > available) {
            revert PerpetualErrors.InsufficientBalance(trader, amount, available);
        }

        // 잔액 감소
        data.balance -= amount;

        // 토큰 전송
        collateralToken.safeTransfer(trader, amount);

        emit PerpetualEvents.MarginWithdrawn(trader, amount, data.balance);
    }

    /// @inheritdoc IMarginManager
    function lockMargin(address trader, uint256 amount) external override onlyAuthorized {
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        CrossMarginAccountData storage data = _crossMarginAccounts[trader];

        uint256 available = data.balance > data.lockedMargin ? data.balance - data.lockedMargin : 0;
        if (amount > available) {
            revert PerpetualErrors.InsufficientMargin(trader, amount, available);
        }

        data.lockedMargin += amount;
    }

    /// @inheritdoc IMarginManager
    function unlockMargin(address trader, uint256 amount) external override onlyAuthorized {
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        CrossMarginAccountData storage data = _crossMarginAccounts[trader];

        if (amount > data.lockedMargin) {
            amount = data.lockedMargin;
        }

        data.lockedMargin -= amount;
    }

    /// @inheritdoc IMarginManager
    function addPositionMargin(bytes32 positionKey, uint256 amount) external override onlyAuthorized {
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        _isolatedMargins[positionKey] += amount;
    }

    /// @inheritdoc IMarginManager
    function removePositionMargin(bytes32 positionKey, uint256 amount) external override onlyAuthorized {
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        uint256 currentMargin = _isolatedMargins[positionKey];
        if (amount > currentMargin) {
            revert PerpetualErrors.CannotRemoveMargin(positionKey, amount, currentMargin);
        }

        _isolatedMargins[positionKey] = currentMargin - amount;
    }

    /// @inheritdoc IMarginManager
    function setMarginMode(address trader, uint32 marketId, PerpetualTypes.MarginMode mode)
        external
        override
        onlyAuthorized
    {
        PerpetualTypes.MarginMode oldMode = _marginModes[trader][marketId];
        _marginModes[trader][marketId] = mode;

        emit PerpetualEvents.MarginModeChanged(trader, marketId, oldMode, mode);
    }

    /// @inheritdoc IMarginManager
    function realizePnL(address trader, int256 pnl) external override onlyAuthorized {
        CrossMarginAccountData storage data = _crossMarginAccounts[trader];

        if (pnl >= 0) {
            data.balance += uint256(pnl);
        } else {
            uint256 loss = uint256(-pnl);
            if (loss > data.balance) {
                data.balance = 0;
            } else {
                data.balance -= loss;
            }
        }
    }

    /// @inheritdoc IMarginManager
    function updateUnrealizedPnL(address trader, int256 unrealizedPnL) external override onlyAuthorized {
        _crossMarginAccounts[trader].unrealizedPnL = unrealizedPnL;
    }

    function settleLiquidation(address trader, uint256 releasedMargin, int256 pnl, uint256 fee)
        external
        override
        nonReentrant
        returns (uint256 deficit)
    {
        if (msg.sender != _liquidator) revert PerpetualErrors.Unauthorized(msg.sender);
        int256 equity = int256(releasedMargin) + pnl;
        if (equity < 0) deficit = uint256(-equity);
        _settleSlice(trader, releasedMargin, pnl, fee);
        if (fee != 0) collateralToken.safeTransfer(msg.sender, fee);
    }

    function settleADL(address trader, uint256 releasedMargin, int256 pnl, uint256 haircut)
        external
        override
        nonReentrant
    {
        if (msg.sender != _adlEngine) revert PerpetualErrors.Unauthorized(msg.sender);
        if (pnl <= 0 || haircut > uint256(pnl)) revert PerpetualErrors.InvalidParameter("haircut exceeds profit");
        _settleSlice(trader, releasedMargin, pnl - int256(haircut), 0);
    }

    function _settleSlice(address trader, uint256 releasedMargin, int256 pnl, uint256 fee) internal {
        CrossMarginAccountData storage data = _crossMarginAccounts[trader];
        if (releasedMargin > data.lockedMargin || releasedMargin > data.balance) {
            revert PerpetualErrors.InsufficientMargin(trader, releasedMargin, data.lockedMargin);
        }
        int256 equity = int256(releasedMargin) + pnl;
        uint256 remaining = equity > 0 ? uint256(equity) : 0;
        if (fee > remaining) revert PerpetualErrors.InvalidParameter("fee exceeds equity");
        data.lockedMargin -= releasedMargin;
        data.balance = data.balance - releasedMargin + remaining - fee;
    }

    function setLiquidator(address liquidator) external onlyAdmin {
        if (liquidator == address(0)) revert PerpetualErrors.ZeroAddress();
        _liquidator = liquidator;
    }

    function setADLEngine(address adlEngine) external onlyAdmin {
        if (adlEngine == address(0)) revert PerpetualErrors.ZeroAddress();
        _adlEngine = adlEngine;
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
     * @notice 직접 입금 (사용자 호출 가능)
     * @param amount 입금 금액
     */
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        _crossMarginAccounts[msg.sender].balance += amount;

        emit PerpetualEvents.MarginDeposited(msg.sender, amount, _crossMarginAccounts[msg.sender].balance);
    }

    /**
     * @notice 직접 출금 (사용자 호출 가능)
     * @param amount 출금 금액
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert PerpetualErrors.ZeroAmount();
        }

        CrossMarginAccountData storage data = _crossMarginAccounts[msg.sender];

        uint256 available = data.balance > data.lockedMargin ? data.balance - data.lockedMargin : 0;
        if (amount > available) {
            revert PerpetualErrors.InsufficientBalance(msg.sender, amount, available);
        }

        data.balance -= amount;
        collateralToken.safeTransfer(msg.sender, amount);

        emit PerpetualEvents.MarginWithdrawn(msg.sender, amount, data.balance);
    }
}
