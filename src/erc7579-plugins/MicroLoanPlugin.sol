// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IExecutor } from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { MODULE_TYPE_EXECUTOR } from "../erc7579-smartaccount/types/Constants.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IPriceOracle } from "../erc4337-paymaster/interfaces/IPriceOracle.sol";

/**
 * @title MicroLoanPlugin
 * @notice ERC-7579 Plugin for micro-lending functionality
 * @dev Enables smart accounts to take small collateralized loans
 *
 * Features:
 * - Collateralized micro-loans (overcollateralized)
 * - Multiple collateral token support
 * - Configurable interest rates and terms
 * - Automatic liquidation on default
 * - Credit score tracking for repeat borrowers
 *
 * Use Cases:
 * - Short-term liquidity for gas fees
 * - Bridge loans while waiting for transfers
 * - Emergency funds access
 * - Small business working capital
 *
 * Loan Flow:
 * 1. User deposits collateral
 * 2. User borrows against collateral (up to LTV)
 * 3. User repays loan + interest
 * 4. User withdraws collateral
 */
contract MicroLoanPlugin is IExecutor, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Loan configuration
    struct LoanConfig {
        address borrowToken; // Token to borrow
        address collateralToken; // Accepted collateral token
        uint256 collateralRatio; // Required collateral ratio (e.g., 15000 = 150%)
        uint256 interestRateBps; // Annual interest rate in basis points
        uint256 maxLoanAmount; // Maximum loan amount
        uint256 minLoanAmount; // Minimum loan amount
        uint256 maxDuration; // Maximum loan duration in seconds
        bool isActive;
    }

    /// @notice Active loan
    struct Loan {
        uint256 configId;
        address borrower;
        uint256 borrowAmount;
        uint256 collateralAmount;
        uint256 interestAccrued;
        uint256 startTime;
        uint256 dueTime;
        bool isActive;
    }

    /// @notice Credit score for repeat borrowers
    struct CreditScore {
        uint256 loansRepaid;
        uint256 loansDefaulted;
        uint256 totalBorrowed;
        uint256 totalRepaid;
        uint256 lastLoanTime;
    }

    /// @notice Price oracle for collateral valuation
    IPriceOracle public oracle;

    /// @notice Protocol fee recipient
    address public feeRecipient;

    /// @notice Protocol fee in basis points
    uint256 public protocolFeeBps;

    /// @notice Liquidation bonus in basis points
    uint256 public liquidationBonusBps;

    /// @notice Loan configurations
    mapping(uint256 => LoanConfig) public loanConfigs;
    uint256 public nextConfigId;

    /// @notice Active loans: loanId => Loan
    mapping(uint256 => Loan) public loans;
    uint256 public nextLoanId;

    /// @notice User loans: user => loanIds
    mapping(address => uint256[]) public userLoans;

    /// @notice Credit scores: user => CreditScore
    mapping(address => CreditScore) public creditScores;

    /// @notice Liquidity pool balance per token
    mapping(address => uint256) public liquidityPool;

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Seconds per year for interest calculation
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // Events
    event LoanConfigCreated(uint256 indexed configId, address borrowToken, address collateralToken);
    event LoanConfigUpdated(uint256 indexed configId, bool isActive);
    event LiquidityDeposited(address indexed token, address indexed depositor, uint256 amount);
    event LiquidityWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    event LoanCreated(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 borrowAmount,
        uint256 collateralAmount,
        uint256 dueTime
    );
    event LoanRepaid(uint256 indexed loanId, address indexed borrower, uint256 repaidAmount, uint256 interest);
    event LoanLiquidated(uint256 indexed loanId, address indexed liquidator, uint256 collateralSeized);
    event CreditScoreUpdated(address indexed user, uint256 loansRepaid, uint256 loansDefaulted);

    // Errors
    error ConfigNotActive();
    error InsufficientCollateral();
    error InsufficientLiquidity();
    error LoanNotActive();
    error LoanNotDue();
    error LoanNotDefaulted();
    error AmountTooLow();
    error AmountTooHigh();
    error DurationTooLong();
    error InvalidOracle();
    error ZeroAddress();

    /**
     * @notice Constructor
     * @param _oracle Price oracle address
     * @param _feeRecipient Protocol fee recipient
     * @param _protocolFeeBps Protocol fee in basis points
     * @param _liquidationBonusBps Liquidation bonus in basis points
     */
    constructor(IPriceOracle _oracle, address _feeRecipient, uint256 _protocolFeeBps, uint256 _liquidationBonusBps)
        Ownable(msg.sender)
    {
        if (address(_oracle) == address(0)) revert InvalidOracle();
        if (_feeRecipient == address(0)) revert ZeroAddress();

        oracle = _oracle;
        feeRecipient = _feeRecipient;
        protocolFeeBps = _protocolFeeBps;
        liquidationBonusBps = _liquidationBonusBps;
    }

    // ============ IModule Implementation ============

    function onInstall(bytes calldata) external payable override {
        // No initialization needed
    }

    function onUninstall(bytes calldata) external payable override {
        // Check user has no active loans
        uint256[] storage userLoanIds = userLoans[msg.sender];
        for (uint256 i = 0; i < userLoanIds.length; i++) {
            if (loans[userLoanIds[i]].isActive) {
                revert LoanNotActive(); // Cannot uninstall with active loans
            }
        }
    }

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    function isInitialized(address) external pure override returns (bool) {
        return true; // Always initialized
    }

    // ============ Configuration ============

    /**
     * @notice Create a new loan configuration
     * @param borrowToken Token to borrow
     * @param collateralToken Accepted collateral
     * @param collateralRatio Required collateral ratio (e.g., 15000 = 150%)
     * @param interestRateBps Annual interest rate in basis points
     * @param maxLoanAmount Maximum loan amount
     * @param minLoanAmount Minimum loan amount
     * @param maxDuration Maximum loan duration
     */
    function createLoanConfig(
        address borrowToken,
        address collateralToken,
        uint256 collateralRatio,
        uint256 interestRateBps,
        uint256 maxLoanAmount,
        uint256 minLoanAmount,
        uint256 maxDuration
    ) external onlyOwner returns (uint256 configId) {
        configId = nextConfigId++;

        loanConfigs[configId] = LoanConfig({
            borrowToken: borrowToken,
            collateralToken: collateralToken,
            collateralRatio: collateralRatio,
            interestRateBps: interestRateBps,
            maxLoanAmount: maxLoanAmount,
            minLoanAmount: minLoanAmount,
            maxDuration: maxDuration,
            isActive: true
        });

        emit LoanConfigCreated(configId, borrowToken, collateralToken);
    }

    /**
     * @notice Update loan config status
     * @param configId The config ID
     * @param isActive New status
     */
    function setLoanConfigActive(uint256 configId, bool isActive) external onlyOwner {
        loanConfigs[configId].isActive = isActive;
        emit LoanConfigUpdated(configId, isActive);
    }

    // ============ Liquidity Pool ============

    /**
     * @notice Deposit liquidity to the pool
     * @param token The token to deposit
     * @param amount The amount to deposit
     */
    function depositLiquidity(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        liquidityPool[token] += amount;
        emit LiquidityDeposited(token, msg.sender, amount);
    }

    /**
     * @notice Withdraw liquidity from the pool (only owner/governance)
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     * @param to Recipient address
     */
    function withdrawLiquidity(address token, uint256 amount, address to) external onlyOwner {
        if (amount > liquidityPool[token]) revert InsufficientLiquidity();
        liquidityPool[token] -= amount;
        IERC20(token).safeTransfer(to, amount);
        emit LiquidityWithdrawn(token, to, amount);
    }

    // ============ Loan Operations ============

    /**
     * @notice Take a micro-loan
     * @param configId Loan configuration ID
     * @param borrowAmount Amount to borrow
     * @param duration Loan duration in seconds
     * @param collateralAmount Collateral amount to provide
     * @return loanId The created loan ID
     */
    function borrow(uint256 configId, uint256 borrowAmount, uint256 duration, uint256 collateralAmount)
        external
        returns (uint256 loanId)
    {
        LoanConfig storage config = loanConfigs[configId];

        // Validations
        if (!config.isActive) revert ConfigNotActive();
        if (borrowAmount < config.minLoanAmount) revert AmountTooLow();
        if (borrowAmount > config.maxLoanAmount) revert AmountTooHigh();
        if (duration > config.maxDuration) revert DurationTooLong();
        if (borrowAmount > liquidityPool[config.borrowToken]) revert InsufficientLiquidity();

        // Check collateral is sufficient
        uint256 requiredCollateral = _calculateRequiredCollateral(config, borrowAmount, collateralAmount);
        if (collateralAmount < requiredCollateral) revert InsufficientCollateral();

        // Transfer collateral from user
        IERC20(config.collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);

        // Create loan
        loanId = nextLoanId++;
        loans[loanId] = Loan({
            configId: configId,
            borrower: msg.sender,
            borrowAmount: borrowAmount,
            collateralAmount: collateralAmount,
            interestAccrued: 0,
            startTime: block.timestamp,
            dueTime: block.timestamp + duration,
            isActive: true
        });

        userLoans[msg.sender].push(loanId);

        // Transfer borrowed tokens
        liquidityPool[config.borrowToken] -= borrowAmount;
        IERC20(config.borrowToken).safeTransfer(msg.sender, borrowAmount);

        emit LoanCreated(loanId, msg.sender, borrowAmount, collateralAmount, block.timestamp + duration);
    }

    /**
     * @notice Repay a loan
     * @param loanId The loan ID to repay
     */
    function repay(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        LoanConfig storage config = loanConfigs[loan.configId];

        if (!loan.isActive) revert LoanNotActive();

        // Calculate total repayment (principal + interest)
        uint256 interest = _calculateInterest(loan, config);
        uint256 totalRepayment = loan.borrowAmount + interest;

        // Calculate protocol fee
        uint256 protocolFee = (interest * protocolFeeBps) / BASIS_POINTS;

        // Transfer repayment
        IERC20(config.borrowToken).safeTransferFrom(msg.sender, address(this), totalRepayment);

        // Return collateral
        IERC20(config.collateralToken).safeTransfer(loan.borrower, loan.collateralAmount);

        // Add repayment to liquidity pool (minus fee)
        liquidityPool[config.borrowToken] += (totalRepayment - protocolFee);

        // Transfer fee
        if (protocolFee > 0) {
            IERC20(config.borrowToken).safeTransfer(feeRecipient, protocolFee);
        }

        // Update loan state
        loan.isActive = false;
        loan.interestAccrued = interest;

        // Update credit score
        CreditScore storage score = creditScores[loan.borrower];
        score.loansRepaid++;
        score.totalBorrowed += loan.borrowAmount;
        score.totalRepaid += totalRepayment;
        score.lastLoanTime = block.timestamp;

        emit LoanRepaid(loanId, loan.borrower, totalRepayment, interest);
        emit CreditScoreUpdated(loan.borrower, score.loansRepaid, score.loansDefaulted);
    }

    /**
     * @notice Liquidate a defaulted loan
     * @param loanId The loan ID to liquidate
     */
    function liquidate(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        LoanConfig storage config = loanConfigs[loan.configId];

        if (!loan.isActive) revert LoanNotActive();
        if (block.timestamp <= loan.dueTime) revert LoanNotDefaulted();

        // Calculate amounts
        uint256 interest = _calculateInterest(loan, config);
        uint256 totalOwed = loan.borrowAmount + interest;

        // Calculate liquidation bonus for liquidator
        uint256 bonus = (loan.collateralAmount * liquidationBonusBps) / BASIS_POINTS;
        uint256 liquidatorReward = loan.collateralAmount >= totalOwed + bonus ? bonus : 0;

        // Transfer collateral
        // Liquidator gets their bonus
        if (liquidatorReward > 0) {
            IERC20(config.collateralToken).safeTransfer(msg.sender, liquidatorReward);
        }

        // Remaining collateral goes to protocol (covers the loss)
        uint256 remainingCollateral = loan.collateralAmount - liquidatorReward;
        if (remainingCollateral > 0) {
            IERC20(config.collateralToken).safeTransfer(feeRecipient, remainingCollateral);
        }

        // Update loan state
        loan.isActive = false;

        // Update credit score (negative)
        CreditScore storage score = creditScores[loan.borrower];
        score.loansDefaulted++;
        score.lastLoanTime = block.timestamp;

        emit LoanLiquidated(loanId, msg.sender, loan.collateralAmount);
        emit CreditScoreUpdated(loan.borrower, score.loansRepaid, score.loansDefaulted);
    }

    // ============ View Functions ============

    /**
     * @notice Get loan details
     * @param loanId The loan ID
     */
    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }

    /**
     * @notice Get all loans for a user
     * @param user The user address
     */
    function getUserLoans(address user) external view returns (uint256[] memory) {
        return userLoans[user];
    }

    /**
     * @notice Get current repayment amount for a loan
     * @param loanId The loan ID
     */
    function getRepaymentAmount(uint256 loanId) external view returns (uint256) {
        Loan storage loan = loans[loanId];
        if (!loan.isActive) return 0;

        LoanConfig storage config = loanConfigs[loan.configId];
        uint256 interest = _calculateInterest(loan, config);
        return loan.borrowAmount + interest;
    }

    /**
     * @notice Check if a loan is defaulted
     * @param loanId The loan ID
     */
    function isDefaulted(uint256 loanId) external view returns (bool) {
        Loan storage loan = loans[loanId];
        return loan.isActive && block.timestamp > loan.dueTime;
    }

    /**
     * @notice Get credit score for a user
     * @param user The user address
     */
    function getCreditScore(address user) external view returns (CreditScore memory) {
        return creditScores[user];
    }

    /**
     * @notice Calculate required collateral for a loan
     * @param configId The config ID
     * @param borrowAmount The borrow amount
     */
    function getRequiredCollateral(uint256 configId, uint256 borrowAmount) external view returns (uint256) {
        LoanConfig storage config = loanConfigs[configId];
        return _calculateRequiredCollateral(config, borrowAmount, 0);
    }

    // ============ Internal Functions ============

    function _calculateRequiredCollateral(
        LoanConfig storage config,
        uint256 borrowAmount,
        uint256 /* providedCollateral */
    )
        internal
        view
        returns (uint256)
    {
        // Get prices from oracle
        (uint256 borrowTokenPrice,) = oracle.getPriceWithTimestamp(config.borrowToken);
        (uint256 collateralTokenPrice,) = oracle.getPriceWithTimestamp(config.collateralToken);

        // Get token decimals to normalize across different decimal tokens (e.g. USDC 6 vs WETH 18)
        uint8 borrowDecimals = IERC20Metadata(config.borrowToken).decimals();
        uint8 collateralDecimals = IERC20Metadata(config.collateralToken).decimals();

        // Normalize: required = borrowAmount * borrowPrice * 10^collateralDecimals / (collateralPrice *
        // 10^borrowDecimals) Then apply collateral ratio
        uint256 rawRequired = (borrowAmount * borrowTokenPrice * (10 ** collateralDecimals))
            / (collateralTokenPrice * (10 ** borrowDecimals));
        uint256 requiredCollateral = (rawRequired * config.collateralRatio) / BASIS_POINTS;

        return requiredCollateral;
    }

    function _calculateInterest(Loan storage loan, LoanConfig storage config) internal view returns (uint256) {
        uint256 duration = block.timestamp > loan.startTime ? block.timestamp - loan.startTime : 0;

        // Simple interest: principal * rate * time / (seconds_per_year * 10000)
        uint256 interest = (loan.borrowAmount * config.interestRateBps * duration) / (SECONDS_PER_YEAR * BASIS_POINTS);

        return interest;
    }
}
