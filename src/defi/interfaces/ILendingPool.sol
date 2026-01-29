// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILendingPool
 * @notice Interface for the collateral-based lending pool
 */
interface ILendingPool {
    // ============ Structs ============

    /// @notice Asset configuration
    struct AssetConfig {
        uint256 ltv; // Loan-to-Value ratio (basis points, e.g., 7500 = 75%)
        uint256 liquidationThreshold; // Liquidation threshold (basis points)
        uint256 liquidationBonus; // Bonus for liquidators (basis points)
        uint256 reserveFactor; // Protocol reserve factor (basis points)
        bool isActive; // Whether the asset is active
        bool canBorrow; // Whether the asset can be borrowed
        bool canCollateral; // Whether the asset can be used as collateral
    }

    /// @notice User account data
    struct AccountData {
        uint256 totalCollateralValue; // Total collateral value in USD (18 decimals)
        uint256 totalDebtValue; // Total debt value in USD (18 decimals)
        uint256 availableBorrowValue; // Available borrow value in USD
        uint256 healthFactor; // Health factor (18 decimals, 1e18 = healthy)
        uint256 ltv; // Current LTV ratio (basis points)
    }

    /// @notice Reserve data for an asset
    struct ReserveData {
        uint256 totalDeposits; // Total deposits
        uint256 totalBorrows; // Total borrows
        uint256 liquidityIndex; // Cumulative liquidity index
        uint256 borrowIndex; // Cumulative borrow index
        uint256 currentLiquidityRate; // Current deposit APY (ray, 27 decimals)
        uint256 currentBorrowRate; // Current borrow APY (ray)
        uint40 lastUpdateTimestamp; // Last update timestamp
    }

    // ============ Events ============

    event Deposit(address indexed asset, address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed asset, address indexed user, uint256 amount, uint256 shares);
    event Borrow(address indexed asset, address indexed user, uint256 amount);
    event Repay(address indexed asset, address indexed user, uint256 amount);
    event Liquidate(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed borrower,
        address liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized
    );
    event FlashLoan(address indexed asset, address indexed receiver, uint256 amount, uint256 fee);
    event AssetConfigured(address indexed asset, AssetConfig config);
    event ReserveUpdated(address indexed asset, uint256 liquidityRate, uint256 borrowRate);

    // ============ Core Functions ============

    /**
     * @notice Deposit assets into the pool
     * @param asset The asset to deposit
     * @param amount The amount to deposit
     */
    function deposit(address asset, uint256 amount) external;

    /**
     * @notice Withdraw assets from the pool
     * @param asset The asset to withdraw
     * @param amount The amount to withdraw (use type(uint256).max for all)
     */
    function withdraw(address asset, uint256 amount) external;

    /**
     * @notice Borrow assets from the pool
     * @param asset The asset to borrow
     * @param amount The amount to borrow
     */
    function borrow(address asset, uint256 amount) external;

    /**
     * @notice Repay borrowed assets
     * @param asset The asset to repay
     * @param amount The amount to repay (use type(uint256).max for all)
     */
    function repay(address asset, uint256 amount) external;

    /**
     * @notice Liquidate an undercollateralized position
     * @param collateralAsset The collateral asset to seize
     * @param debtAsset The debt asset to repay
     * @param borrower The address of the borrower
     * @param debtAmount The amount of debt to repay
     */
    function liquidate(address collateralAsset, address debtAsset, address borrower, uint256 debtAmount) external;

    // ============ Flash Loan ============

    /**
     * @notice Execute a flash loan
     * @param asset The asset to borrow
     * @param amount The amount to borrow
     * @param receiver The receiver contract (must implement IFlashLoanReceiver)
     * @param data Additional data to pass to the receiver
     */
    function flashLoan(address asset, uint256 amount, address receiver, bytes calldata data) external;

    // ============ View Functions ============

    /**
     * @notice Get user account data
     * @param user The user address
     * @return data The account data
     */
    function getAccountData(address user) external view returns (AccountData memory data);

    /**
     * @notice Get user deposit balance for an asset
     * @param asset The asset address
     * @param user The user address
     * @return The deposit balance
     */
    function getDepositBalance(address asset, address user) external view returns (uint256);

    /**
     * @notice Get user borrow balance for an asset
     * @param asset The asset address
     * @param user The user address
     * @return The borrow balance including interest
     */
    function getBorrowBalance(address asset, address user) external view returns (uint256);

    /**
     * @notice Get reserve data for an asset
     * @param asset The asset address
     * @return data The reserve data
     */
    function getReserveData(address asset) external view returns (ReserveData memory data);

    /**
     * @notice Get asset configuration
     * @param asset The asset address
     * @return config The asset configuration
     */
    function getAssetConfig(address asset) external view returns (AssetConfig memory config);

    /**
     * @notice Calculate health factor for a user
     * @param user The user address
     * @return The health factor (1e18 = healthy threshold)
     */
    function calculateHealthFactor(address user) external view returns (uint256);
}

/**
 * @title IFlashLoanReceiver
 * @notice Interface for flash loan receivers
 */
interface IFlashLoanReceiver {
    /**
     * @notice Execute operation after receiving flash loan
     * @param asset The borrowed asset
     * @param amount The borrowed amount
     * @param fee The fee to pay
     * @param initiator The initiator of the flash loan
     * @param data Additional data
     * @return True if the operation succeeded
     */
    function executeOperation(address asset, uint256 amount, uint256 fee, address initiator, bytes calldata data)
        external
        returns (bool);
}
