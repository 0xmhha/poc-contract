// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ILendingPool, IFlashLoanReceiver } from "./interfaces/ILendingPool.sol";
import { IPriceOracle } from "../erc4337-paymaster/interfaces/IPriceOracle.sol";

/**
 * @title LendingPool
 * @notice Collateral-based lending pool with variable interest rates
 * @dev Features:
 *      - Multi-asset deposits and borrows
 *      - Variable interest rate model based on utilization
 *      - Liquidation mechanism with bonus for liquidators
 *      - Flash loans with fee
 */
contract LendingPool is ILendingPool, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Ray (27 decimals) for interest rate calculations
    uint256 public constant RAY = 1e27;

    /// @notice Seconds per year for APY calculations
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Health factor threshold (1e18 = 1.0)
    uint256 public constant HEALTH_FACTOR_THRESHOLD = 1e18;

    /// @notice Flash loan fee (0.09% = 9 bps)
    uint256 public constant FLASH_LOAN_FEE = 9;

    /// @notice Optimal utilization rate (80%)
    uint256 public constant OPTIMAL_UTILIZATION = 8000;

    // ============ Interest Rate Model Parameters ============

    /// @notice Base interest rate (2% APY)
    uint256 public constant BASE_RATE = 2e25; // 2% in ray

    /// @notice Slope 1 (below optimal utilization) - 4% at optimal
    uint256 public constant SLOPE1 = 5e25; // 5% in ray

    /// @notice Slope 2 (above optimal utilization) - steep increase
    uint256 public constant SLOPE2 = 75e25; // 75% in ray

    // ============ State Variables ============

    /// @notice Price oracle for asset valuations
    IPriceOracle public oracle;

    /// @notice Asset configurations
    mapping(address => AssetConfig) public assetConfigs;

    /// @notice Reserve data for each asset
    mapping(address => ReserveData) internal _reserves;

    /// @notice User deposit shares per asset
    mapping(address => mapping(address => uint256)) public depositShares;

    /// @notice User borrow amounts per asset (normalized)
    mapping(address => mapping(address => uint256)) public borrowAmounts;

    /// @notice User borrow index snapshot
    mapping(address => mapping(address => uint256)) public userBorrowIndex;

    /// @notice Protocol reserves (fees collected)
    mapping(address => uint256) public protocolReserves;

    /// @notice List of supported assets
    address[] public supportedAssets;

    /// @notice Flash loan in progress flag (defense-in-depth with nonReentrant)
    bool private _flashLoanInProgress;

    /// @notice Maximum price staleness (5 minutes)
    uint256 public constant MAX_PRICE_AGE = 5 minutes;

    /// @notice Minimum deposit amount to prevent dust/rounding exploits
    uint256 public constant MIN_DEPOSIT_AMOUNT = 1000;

    // ============ Errors ============

    error AssetNotSupported();
    error AssetNotActive();
    error CannotBorrow();
    error CannotUseAsCollateral();
    error InsufficientCollateral();
    error InsufficientLiquidity();
    error HealthFactorOk();
    error InvalidAmount();
    error FlashLoanFailed();
    error ReentrantFlashLoan();
    error StalePriceData();
    error DepositTooSmall();

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    // ============ Constructor ============

    constructor(address _oracle) Ownable(msg.sender) {
        oracle = IPriceOracle(_oracle);
    }

    // ============ Admin Functions ============

    /**
     * @notice Configure an asset for the lending pool
     * @param asset The asset address
     * @param config The asset configuration
     */
    function configureAsset(address asset, AssetConfig memory config) external onlyOwner {
        if (assetConfigs[asset].ltv == 0) {
            supportedAssets.push(asset);
        }

        assetConfigs[asset] = config;

        // Initialize reserve if new
        if (_reserves[asset].liquidityIndex == 0) {
            _reserves[asset].liquidityIndex = RAY;
            _reserves[asset].borrowIndex = RAY;
            _reserves[asset].lastUpdateTimestamp = uint40(block.timestamp);
        }

        emit AssetConfigured(asset, config);
    }

    /**
     * @notice Set the price oracle
     * @param _oracle New oracle address
     */
    function setOracle(address _oracle) external onlyOwner {
        address oldOracle = address(oracle);
        oracle = IPriceOracle(_oracle);
        emit OracleUpdated(oldOracle, _oracle);
    }

    /**
     * @notice Withdraw protocol reserves
     * @param asset The asset to withdraw
     * @param to The recipient address
     * @param amount The amount to withdraw
     */
    function withdrawReserves(address asset, address to, uint256 amount) external onlyOwner {
        if (amount > protocolReserves[asset]) {
            amount = protocolReserves[asset];
        }
        protocolReserves[asset] -= amount;
        IERC20(asset).safeTransfer(to, amount);
    }

    /**
     * @notice Pause the lending pool
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the lending pool
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Core Functions ============

    /**
     * @inheritdoc ILendingPool
     */
    function deposit(address asset, uint256 amount) external nonReentrant whenNotPaused {
        _validateAsset(asset, true, false, false);
        if (amount == 0) revert InvalidAmount();
        if (amount < MIN_DEPOSIT_AMOUNT) revert DepositTooSmall();

        // Update interest rates
        _updateReserve(asset);

        ReserveData storage reserve = _reserves[asset];

        // Calculate shares to mint
        uint256 shares;
        if (reserve.totalDeposits == 0) {
            shares = amount;
        } else {
            shares = (amount * _getTotalShares(asset)) / reserve.totalDeposits;
        }

        // Transfer tokens
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Update state
        depositShares[asset][msg.sender] += shares;
        reserve.totalDeposits += amount;

        emit Deposit(asset, msg.sender, amount, shares);
    }

    /**
     * @inheritdoc ILendingPool
     */
    function withdraw(address asset, uint256 amount) external nonReentrant whenNotPaused {
        _validateAsset(asset, true, false, false);

        _updateReserve(asset);

        ReserveData storage reserve = _reserves[asset];
        uint256 userShares = depositShares[asset][msg.sender];
        uint256 userBalance = _getDepositBalanceFromShares(asset, userShares);

        if (amount == type(uint256).max) {
            amount = userBalance;
        }

        if (amount == 0 || amount > userBalance) revert InvalidAmount();

        // Calculate shares to burn
        uint256 sharesToBurn = (amount * userShares) / userBalance;

        // Check liquidity
        uint256 availableLiquidity = reserve.totalDeposits - reserve.totalBorrows;
        if (amount > availableLiquidity) revert InsufficientLiquidity();

        // Update state
        depositShares[asset][msg.sender] -= sharesToBurn;
        reserve.totalDeposits -= amount;

        // Check health factor after withdrawal
        if (borrowAmounts[asset][msg.sender] > 0 || _hasBorrows(msg.sender)) {
            uint256 healthFactor = calculateHealthFactor(msg.sender);
            if (healthFactor < HEALTH_FACTOR_THRESHOLD) revert InsufficientCollateral();
        }

        // Transfer tokens
        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Withdraw(asset, msg.sender, amount, sharesToBurn);
    }

    /**
     * @inheritdoc ILendingPool
     */
    function borrow(address asset, uint256 amount) external nonReentrant whenNotPaused {
        _validateAsset(asset, true, true, false);
        if (amount == 0) revert InvalidAmount();

        _updateReserve(asset);

        ReserveData storage reserve = _reserves[asset];

        // Check liquidity
        uint256 availableLiquidity = reserve.totalDeposits - reserve.totalBorrows;
        if (amount > availableLiquidity) revert InsufficientLiquidity();

        // Update user borrow
        _updateUserBorrow(asset, msg.sender);

        // Update state
        borrowAmounts[asset][msg.sender] += amount;
        reserve.totalBorrows += amount;

        // Check health factor
        uint256 healthFactor = calculateHealthFactor(msg.sender);
        if (healthFactor < HEALTH_FACTOR_THRESHOLD) revert InsufficientCollateral();

        // Transfer tokens
        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrow(asset, msg.sender, amount);
    }

    /**
     * @inheritdoc ILendingPool
     */
    function repay(address asset, uint256 amount) external nonReentrant {
        _validateAsset(asset, true, false, false);

        _updateReserve(asset);
        _updateUserBorrow(asset, msg.sender);

        uint256 userDebt = borrowAmounts[asset][msg.sender];
        if (userDebt == 0) revert InvalidAmount();

        if (amount == type(uint256).max) {
            amount = userDebt;
        }
        if (amount > userDebt) {
            amount = userDebt;
        }

        // Transfer tokens
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Update state
        borrowAmounts[asset][msg.sender] -= amount;
        _reserves[asset].totalBorrows -= amount;

        emit Repay(asset, msg.sender, amount);
    }

    /**
     * @inheritdoc ILendingPool
     */
    function liquidate(address collateralAsset, address debtAsset, address borrower, uint256 debtAmount)
        external
        nonReentrant
    {
        _validateAsset(collateralAsset, true, false, true);
        _validateAsset(debtAsset, true, false, false);

        // Check if borrower is liquidatable
        uint256 healthFactor = calculateHealthFactor(borrower);
        if (healthFactor >= HEALTH_FACTOR_THRESHOLD) revert HealthFactorOk();

        _updateReserve(collateralAsset);
        _updateReserve(debtAsset);
        _updateUserBorrow(debtAsset, borrower);

        uint256 userDebt = borrowAmounts[debtAsset][borrower];
        if (debtAmount > userDebt) {
            debtAmount = userDebt;
        }

        // Calculate collateral to seize
        AssetConfig memory collateralConfig = assetConfigs[collateralAsset];
        uint256 debtValue = _getAssetValue(debtAsset, debtAmount);
        uint256 collateralToSeize =
            (debtValue * (BASIS_POINTS + collateralConfig.liquidationBonus)) / BASIS_POINTS;
        uint256 collateralAmount = _getAmountFromValue(collateralAsset, collateralToSeize);

        // Ensure borrower has enough collateral
        uint256 borrowerCollateral = getDepositBalance(collateralAsset, borrower);
        if (collateralAmount > borrowerCollateral) {
            collateralAmount = borrowerCollateral;
            // Recalculate debt to repay based on available collateral
            uint256 collateralValue = _getAssetValue(collateralAsset, collateralAmount);
            debtAmount = _getAmountFromValue(
                debtAsset, (collateralValue * BASIS_POINTS) / (BASIS_POINTS + collateralConfig.liquidationBonus)
            );
        }

        // Transfer debt from liquidator
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), debtAmount);

        // Update debt
        borrowAmounts[debtAsset][borrower] -= debtAmount;
        _reserves[debtAsset].totalBorrows -= debtAmount;

        // Transfer collateral shares to liquidator
        uint256 userShares = depositShares[collateralAsset][borrower];
        uint256 userBalance = _getDepositBalanceFromShares(collateralAsset, userShares);
        uint256 sharesToTransfer = (collateralAmount * userShares) / userBalance;

        depositShares[collateralAsset][borrower] -= sharesToTransfer;
        depositShares[collateralAsset][msg.sender] += sharesToTransfer;

        emit Liquidate(collateralAsset, debtAsset, borrower, msg.sender, debtAmount, collateralAmount);
    }

    // ============ Flash Loan ============

    /**
     * @inheritdoc ILendingPool
     */
    function flashLoan(address asset, uint256 amount, address receiver, bytes calldata data) external nonReentrant whenNotPaused {
        if (_flashLoanInProgress) revert ReentrantFlashLoan();
        _flashLoanInProgress = true;

        _validateAsset(asset, true, false, false);

        ReserveData storage reserve = _reserves[asset];
        uint256 availableLiquidity = reserve.totalDeposits - reserve.totalBorrows;
        if (amount > availableLiquidity) revert InsufficientLiquidity();

        uint256 fee = (amount * FLASH_LOAN_FEE) / BASIS_POINTS;
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        // Transfer to receiver
        IERC20(asset).safeTransfer(receiver, amount);

        // Execute operation
        bool success = IFlashLoanReceiver(receiver).executeOperation(asset, amount, fee, msg.sender, data);
        if (!success) revert FlashLoanFailed();

        // Check repayment
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (balanceAfter < balanceBefore + fee) revert FlashLoanFailed();

        // Add fee to protocol reserves
        protocolReserves[asset] += fee;

        _flashLoanInProgress = false;

        emit FlashLoan(asset, receiver, amount, fee);
    }

    // ============ View Functions ============

    /**
     * @inheritdoc ILendingPool
     */
    function getAccountData(address user) external view returns (AccountData memory data) {
        uint256 totalCollateralValue;
        uint256 totalDebtValue;
        uint256 weightedLtv;

        for (uint256 i = 0; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            AssetConfig memory config = assetConfigs[asset];

            // Collateral
            if (config.canCollateral) {
                uint256 depositBalance = getDepositBalance(asset, user);
                if (depositBalance > 0) {
                    uint256 value = _getAssetValue(asset, depositBalance);
                    totalCollateralValue += value;
                    weightedLtv += value * config.ltv;
                }
            }

            // Debt
            uint256 borrowBalance = getBorrowBalance(asset, user);
            if (borrowBalance > 0) {
                totalDebtValue += _getAssetValue(asset, borrowBalance);
            }
        }

        data.totalCollateralValue = totalCollateralValue;
        data.totalDebtValue = totalDebtValue;

        if (totalCollateralValue > 0) {
            data.ltv = weightedLtv / totalCollateralValue;
            uint256 maxBorrow = (totalCollateralValue * data.ltv) / BASIS_POINTS;
            data.availableBorrowValue = maxBorrow > totalDebtValue ? maxBorrow - totalDebtValue : 0;
        }

        if (totalDebtValue > 0) {
            // Health factor = (collateral * liquidation threshold) / debt
            uint256 liquidationThreshold = _getWeightedLiquidationThreshold(user, totalCollateralValue);
            data.healthFactor = (totalCollateralValue * liquidationThreshold) / (totalDebtValue * BASIS_POINTS);
        } else {
            data.healthFactor = type(uint256).max;
        }
    }

    /**
     * @inheritdoc ILendingPool
     */
    function getDepositBalance(address asset, address user) public view returns (uint256) {
        uint256 shares = depositShares[asset][user];
        return _getDepositBalanceFromShares(asset, shares);
    }

    /**
     * @inheritdoc ILendingPool
     */
    function getBorrowBalance(address asset, address user) public view returns (uint256) {
        uint256 principal = borrowAmounts[asset][user];
        if (principal == 0) return 0;

        uint256 userIndex = userBorrowIndex[asset][user];
        if (userIndex == 0) userIndex = RAY;

        uint256 currentIndex = _calculateBorrowIndex(asset);
        return (principal * currentIndex) / userIndex;
    }

    /**
     * @inheritdoc ILendingPool
     */
    function getReserveData(address asset) external view returns (ReserveData memory) {
        ReserveData memory data = _reserves[asset];
        // Calculate current rates
        (data.currentLiquidityRate, data.currentBorrowRate) = _calculateInterestRates(asset);
        return data;
    }

    /**
     * @inheritdoc ILendingPool
     */
    function getAssetConfig(address asset) external view returns (AssetConfig memory) {
        return assetConfigs[asset];
    }

    /**
     * @inheritdoc ILendingPool
     */
    function calculateHealthFactor(address user) public view returns (uint256) {
        uint256 totalCollateralValue;
        uint256 totalDebtValue;

        for (uint256 i = 0; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            AssetConfig memory config = assetConfigs[asset];

            if (config.canCollateral) {
                uint256 depositBalance = getDepositBalance(asset, user);
                if (depositBalance > 0) {
                    uint256 value = _getAssetValue(asset, depositBalance);
                    totalCollateralValue += (value * config.liquidationThreshold) / BASIS_POINTS;
                }
            }

            uint256 borrowBalance = getBorrowBalance(asset, user);
            if (borrowBalance > 0) {
                totalDebtValue += _getAssetValue(asset, borrowBalance);
            }
        }

        if (totalDebtValue == 0) return type(uint256).max;
        return (totalCollateralValue * 1e18) / totalDebtValue;
    }

    // ============ Internal Functions ============

    function _validateAsset(address asset, bool checkActive, bool checkBorrow, bool checkCollateral) internal view {
        AssetConfig memory config = assetConfigs[asset];
        if (config.ltv == 0) revert AssetNotSupported();
        if (checkActive && !config.isActive) revert AssetNotActive();
        if (checkBorrow && !config.canBorrow) revert CannotBorrow();
        if (checkCollateral && !config.canCollateral) revert CannotUseAsCollateral();
    }

    function _updateReserve(address asset) internal {
        ReserveData storage reserve = _reserves[asset];

        if (block.timestamp == reserve.lastUpdateTimestamp) return;

        if (reserve.totalBorrows > 0) {
            // Calculate accrued interest
            uint256 timeDelta = block.timestamp - reserve.lastUpdateTimestamp;
            (, uint256 currentBorrowRate) = _calculateInterestRates(asset);

            // Update borrow index
            uint256 interestFactor = (currentBorrowRate * timeDelta) / SECONDS_PER_YEAR;
            reserve.borrowIndex = (reserve.borrowIndex * (RAY + interestFactor)) / RAY;

            // Calculate interest earned
            uint256 interestEarned = (reserve.totalBorrows * interestFactor) / RAY;

            // Protocol takes reserve factor
            uint256 protocolShare = (interestEarned * assetConfigs[asset].reserveFactor) / BASIS_POINTS;
            protocolReserves[asset] += protocolShare;

            // Update liquidity index (interest to depositors)
            if (reserve.totalDeposits > 0) {
                uint256 depositInterest = interestEarned - protocolShare;
                reserve.liquidityIndex =
                    (reserve.liquidityIndex * (reserve.totalDeposits + depositInterest)) / reserve.totalDeposits;
            }
        }

        reserve.lastUpdateTimestamp = uint40(block.timestamp);

        (uint256 liquidityRate, uint256 borrowRate) = _calculateInterestRates(asset);
        emit ReserveUpdated(asset, liquidityRate, borrowRate);
    }

    function _updateUserBorrow(address asset, address user) internal {
        uint256 principal = borrowAmounts[asset][user];
        if (principal == 0) {
            userBorrowIndex[asset][user] = _reserves[asset].borrowIndex;
            return;
        }

        uint256 userIndex = userBorrowIndex[asset][user];
        if (userIndex == 0) userIndex = RAY;

        uint256 currentIndex = _reserves[asset].borrowIndex;
        uint256 newBalance = (principal * currentIndex) / userIndex;

        borrowAmounts[asset][user] = newBalance;
        userBorrowIndex[asset][user] = currentIndex;
    }

    function _calculateInterestRates(address asset) internal view returns (uint256 liquidityRate, uint256 borrowRate) {
        ReserveData memory reserve = _reserves[asset];

        if (reserve.totalDeposits == 0) {
            return (0, BASE_RATE);
        }

        uint256 utilization = (reserve.totalBorrows * BASIS_POINTS) / reserve.totalDeposits;

        if (utilization <= OPTIMAL_UTILIZATION) {
            borrowRate = BASE_RATE + (utilization * SLOPE1) / OPTIMAL_UTILIZATION;
        } else {
            uint256 excessUtilization = utilization - OPTIMAL_UTILIZATION;
            uint256 maxExcess = BASIS_POINTS - OPTIMAL_UTILIZATION;
            borrowRate = BASE_RATE + SLOPE1 + (excessUtilization * SLOPE2) / maxExcess;
        }

        // Liquidity rate = borrow rate * utilization * (1 - reserve factor)
        uint256 reserveFactor = assetConfigs[asset].reserveFactor;
        liquidityRate = (borrowRate * utilization * (BASIS_POINTS - reserveFactor)) / (BASIS_POINTS * BASIS_POINTS);
    }

    function _calculateBorrowIndex(address asset) internal view returns (uint256) {
        ReserveData memory reserve = _reserves[asset];
        if (reserve.totalBorrows == 0) return reserve.borrowIndex;

        uint256 timeDelta = block.timestamp - reserve.lastUpdateTimestamp;
        if (timeDelta == 0) return reserve.borrowIndex;

        (, uint256 borrowRate) = _calculateInterestRates(asset);
        uint256 interestFactor = (borrowRate * timeDelta) / SECONDS_PER_YEAR;

        return (reserve.borrowIndex * (RAY + interestFactor)) / RAY;
    }

    function _getAssetValue(address asset, uint256 amount) internal view returns (uint256) {
        (uint256 price, uint256 timestamp) = oracle.getPriceWithTimestamp(asset);
        if (block.timestamp - timestamp > MAX_PRICE_AGE) revert StalePriceData();
        return (amount * price) / 1e18;
    }

    function _getAmountFromValue(address asset, uint256 value) internal view returns (uint256) {
        (uint256 price, uint256 timestamp) = oracle.getPriceWithTimestamp(asset);
        if (block.timestamp - timestamp > MAX_PRICE_AGE) revert StalePriceData();
        return (value * 1e18) / price;
    }

    function _getTotalShares(address asset) internal view returns (uint256) {
        // For simplicity, return totalDeposits as shares (1:1 initially)
        // In production, track total shares separately
        return _reserves[asset].totalDeposits;
    }

    function _getDepositBalanceFromShares(address asset, uint256 shares) internal view returns (uint256) {
        ReserveData memory reserve = _reserves[asset];
        if (reserve.totalDeposits == 0) return 0;

        uint256 totalShares = _getTotalShares(asset);
        if (totalShares == 0) return 0;

        return (shares * reserve.totalDeposits) / totalShares;
    }

    function _hasBorrows(address user) internal view returns (bool) {
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            if (borrowAmounts[supportedAssets[i]][user] > 0) return true;
        }
        return false;
    }

    function _getWeightedLiquidationThreshold(address user, uint256 totalCollateralValue)
        internal
        view
        returns (uint256)
    {
        if (totalCollateralValue == 0) return 0;

        uint256 weightedThreshold;
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            AssetConfig memory config = assetConfigs[asset];

            if (config.canCollateral) {
                uint256 depositBalance = getDepositBalance(asset, user);
                if (depositBalance > 0) {
                    uint256 value = _getAssetValue(asset, depositBalance);
                    weightedThreshold += value * config.liquidationThreshold;
                }
            }
        }

        return weightedThreshold / totalCollateralValue;
    }
}
