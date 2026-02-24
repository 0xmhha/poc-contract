// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { MicroLoanPlugin } from "../../src/erc7579-plugins/MicroLoanPlugin.sol";
import { IPriceOracle } from "../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";
import { MODULE_TYPE_EXECUTOR } from "../../src/erc7579-smartaccount/types/Constants.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice MockERC20 with configurable decimals for testing cross-decimal normalization
contract MockERC20WithDecimals is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view override returns (uint256) {
        return prices[token];
    }

    function getPriceWithTimestamp(address token) external view override returns (uint256 price, uint256 timestamp) {
        return (prices[token], block.timestamp);
    }

    function hasValidPrice(address token) external view override returns (bool) {
        return prices[token] > 0;
    }
}

contract MicroLoanPluginTest is Test {
    MicroLoanPlugin public plugin;
    MockPriceOracle public oracle;
    MockERC20 public borrowToken;
    MockERC20 public collateralToken;

    address public owner;
    address public feeRecipient;
    address public borrower;
    address public liquidator;

    uint256 public configId;

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

    function setUp() public {
        owner = makeAddr("owner");
        feeRecipient = makeAddr("feeRecipient");
        borrower = makeAddr("borrower");
        liquidator = makeAddr("liquidator");

        oracle = new MockPriceOracle();

        vm.startPrank(owner);
        borrowToken = new MockERC20("Borrow Token", "BT");
        collateralToken = new MockERC20("Collateral Token", "CT");

        plugin = new MicroLoanPlugin(
            oracle,
            feeRecipient,
            500, // 5% protocol fee
            500 // 5% liquidation bonus
        );

        // Set prices (1:1 for simplicity)
        oracle.setPrice(address(borrowToken), 1e18);
        oracle.setPrice(address(collateralToken), 1e18);

        // Fund plugin with liquidity
        borrowToken.mint(owner, 10_000 ether);
        borrowToken.approve(address(plugin), 10_000 ether);
        plugin.depositLiquidity(address(borrowToken), 10_000 ether);

        // Fund borrower with collateral
        collateralToken.mint(borrower, 1000 ether);

        // Create default loan config
        configId = plugin.createLoanConfig(
            address(borrowToken),
            address(collateralToken),
            15_000, // 150% collateral ratio
            1000, // 10% annual interest
            1000 ether, // max loan
            1 ether, // min loan
            30 days // max duration
        );
        vm.stopPrank();

        // Approve collateral
        vm.prank(borrower);
        collateralToken.approve(address(plugin), type(uint256).max);
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertEq(address(plugin.oracle()), address(oracle));
        assertEq(plugin.feeRecipient(), feeRecipient);
        assertEq(plugin.protocolFeeBps(), 500);
        assertEq(plugin.liquidationBonusBps(), 500);
    }

    function test_Constructor_RevertsOnZeroOracle() public {
        vm.expectRevert(MicroLoanPlugin.InvalidOracle.selector);
        new MicroLoanPlugin(IPriceOracle(address(0)), feeRecipient, 500, 500);
    }

    function test_Constructor_RevertsOnZeroFeeRecipient() public {
        vm.expectRevert(MicroLoanPlugin.ZeroAddress.selector);
        new MicroLoanPlugin(oracle, address(0), 500, 500);
    }

    // ============ IModule Tests ============

    function test_IsModuleType_Executor() public view {
        assertTrue(plugin.isModuleType(MODULE_TYPE_EXECUTOR));
        assertFalse(plugin.isModuleType(1)); // Not validator
    }

    function test_IsInitialized_AlwaysTrue() public view {
        assertTrue(plugin.isInitialized(borrower));
        assertTrue(plugin.isInitialized(address(0)));
    }

    function test_OnInstall_Succeeds() public {
        vm.prank(borrower);
        plugin.onInstall("");
    }

    // ============ Loan Config Tests ============

    function test_CreateLoanConfig_Success() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit LoanConfigCreated(1, address(borrowToken), address(collateralToken));
        uint256 newConfigId = plugin.createLoanConfig(
            address(borrowToken), address(collateralToken), 12_000, 800, 500 ether, 0.5 ether, 60 days
        );

        assertEq(newConfigId, 1);

        (
            address _borrowToken,
            address _collateralToken,
            uint256 collateralRatio,
            uint256 interestRateBps,
            uint256 maxLoanAmount,
            uint256 minLoanAmount,
            uint256 maxDuration,
            bool isActive
        ) = plugin.loanConfigs(newConfigId);

        assertEq(_borrowToken, address(borrowToken));
        assertEq(_collateralToken, address(collateralToken));
        assertEq(collateralRatio, 12_000);
        assertEq(interestRateBps, 800);
        assertEq(maxLoanAmount, 500 ether);
        assertEq(minLoanAmount, 0.5 ether);
        assertEq(maxDuration, 60 days);
        assertTrue(isActive);
    }

    function test_SetLoanConfigActive_Success() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit LoanConfigUpdated(configId, false);
        plugin.setLoanConfigActive(configId, false);

        (,,,,,,, bool isActive) = plugin.loanConfigs(configId);
        assertFalse(isActive);
    }

    // ============ Liquidity Pool Tests ============

    function test_DepositLiquidity_Success() public {
        vm.startPrank(owner);
        borrowToken.mint(owner, 100 ether);
        borrowToken.approve(address(plugin), 100 ether);

        vm.expectEmit(true, true, false, true);
        emit LiquidityDeposited(address(borrowToken), owner, 100 ether);
        plugin.depositLiquidity(address(borrowToken), 100 ether);
        vm.stopPrank();

        assertEq(plugin.liquidityPool(address(borrowToken)), 10_100 ether);
    }

    function test_WithdrawLiquidity_Success() public {
        address recipient = makeAddr("recipient");

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit LiquidityWithdrawn(address(borrowToken), recipient, 100 ether);
        plugin.withdrawLiquidity(address(borrowToken), 100 ether, recipient);

        assertEq(borrowToken.balanceOf(recipient), 100 ether);
        assertEq(plugin.liquidityPool(address(borrowToken)), 9900 ether);
    }

    function test_WithdrawLiquidity_RevertsOnInsufficientLiquidity() public {
        vm.prank(owner);
        vm.expectRevert(MicroLoanPlugin.InsufficientLiquidity.selector);
        plugin.withdrawLiquidity(address(borrowToken), 20_000 ether, owner);
    }

    // ============ Borrow Tests ============

    function test_Borrow_Success() public {
        uint256 borrowAmount = 100 ether;
        uint256 collateralAmount = 150 ether; // 150% of borrow

        vm.prank(borrower);
        vm.expectEmit(true, true, false, true);
        emit LoanCreated(0, borrower, borrowAmount, collateralAmount, block.timestamp + 7 days);
        uint256 loanId = plugin.borrow(configId, borrowAmount, 7 days, collateralAmount);

        assertEq(loanId, 0);

        MicroLoanPlugin.Loan memory loan = plugin.getLoan(loanId);
        assertEq(loan.configId, configId);
        assertEq(loan.borrower, borrower);
        assertEq(loan.borrowAmount, borrowAmount);
        assertEq(loan.collateralAmount, collateralAmount);
        assertTrue(loan.isActive);

        assertEq(borrowToken.balanceOf(borrower), borrowAmount);
    }

    function test_Borrow_RevertsOnInactiveConfig() public {
        vm.prank(owner);
        plugin.setLoanConfigActive(configId, false);

        vm.prank(borrower);
        vm.expectRevert(MicroLoanPlugin.ConfigNotActive.selector);
        plugin.borrow(configId, 100 ether, 7 days, 150 ether);
    }

    function test_Borrow_RevertsOnAmountTooLow() public {
        vm.prank(borrower);
        vm.expectRevert(MicroLoanPlugin.AmountTooLow.selector);
        plugin.borrow(configId, 0.5 ether, 7 days, 1 ether);
    }

    function test_Borrow_RevertsOnAmountTooHigh() public {
        vm.prank(borrower);
        vm.expectRevert(MicroLoanPlugin.AmountTooHigh.selector);
        plugin.borrow(configId, 2000 ether, 7 days, 3000 ether);
    }

    function test_Borrow_RevertsOnDurationTooLong() public {
        vm.prank(borrower);
        vm.expectRevert(MicroLoanPlugin.DurationTooLong.selector);
        plugin.borrow(configId, 100 ether, 60 days, 150 ether);
    }

    function test_Borrow_RevertsOnInsufficientCollateral() public {
        vm.prank(borrower);
        vm.expectRevert(MicroLoanPlugin.InsufficientCollateral.selector);
        plugin.borrow(configId, 100 ether, 7 days, 100 ether); // Only 100% collateral
    }

    function test_Borrow_RevertsOnInsufficientLiquidity() public {
        vm.prank(owner);
        plugin.withdrawLiquidity(address(borrowToken), 9990 ether, owner);

        vm.prank(borrower);
        vm.expectRevert(MicroLoanPlugin.InsufficientLiquidity.selector);
        plugin.borrow(configId, 100 ether, 7 days, 150 ether);
    }

    // ============ Repay Tests ============

    function test_Repay_Success() public {
        // Borrow
        vm.prank(borrower);
        uint256 loanId = plugin.borrow(configId, 100 ether, 7 days, 150 ether);

        // Move time forward (1 day)
        vm.warp(block.timestamp + 1 days);

        // Calculate repayment
        uint256 repaymentAmount = plugin.getRepaymentAmount(loanId);

        // Mint enough to repay
        vm.prank(owner);
        borrowToken.mint(borrower, repaymentAmount);

        vm.startPrank(borrower);
        borrowToken.approve(address(plugin), repaymentAmount);

        uint256 collateralBefore = collateralToken.balanceOf(borrower);

        plugin.repay(loanId);
        vm.stopPrank();

        // Check loan is closed
        MicroLoanPlugin.Loan memory loan = plugin.getLoan(loanId);
        assertFalse(loan.isActive);

        // Check collateral returned
        assertEq(collateralToken.balanceOf(borrower), collateralBefore + 150 ether);

        // Check credit score updated
        MicroLoanPlugin.CreditScore memory score = plugin.getCreditScore(borrower);
        assertEq(score.loansRepaid, 1);
        assertEq(score.loansDefaulted, 0);
    }

    function test_Repay_RevertsOnLoanNotActive() public {
        vm.prank(borrower);
        uint256 loanId = plugin.borrow(configId, 100 ether, 7 days, 150 ether);

        // Repay once
        uint256 repaymentAmount = plugin.getRepaymentAmount(loanId);
        vm.prank(owner);
        borrowToken.mint(borrower, repaymentAmount);

        vm.startPrank(borrower);
        borrowToken.approve(address(plugin), repaymentAmount);
        plugin.repay(loanId);

        // Try to repay again
        vm.expectRevert(MicroLoanPlugin.LoanNotActive.selector);
        plugin.repay(loanId);
        vm.stopPrank();
    }

    // ============ Liquidation Tests ============

    function test_Liquidate_Success() public {
        vm.prank(borrower);
        uint256 loanId = plugin.borrow(configId, 100 ether, 1 days, 150 ether);

        // Move past due time
        vm.warp(block.timestamp + 2 days);

        // Liquidate
        vm.prank(liquidator);
        plugin.liquidate(loanId);

        // Check loan is closed
        MicroLoanPlugin.Loan memory loan = plugin.getLoan(loanId);
        assertFalse(loan.isActive);

        // Check credit score updated (defaulted)
        MicroLoanPlugin.CreditScore memory score = plugin.getCreditScore(borrower);
        assertEq(score.loansRepaid, 0);
        assertEq(score.loansDefaulted, 1);
    }

    function test_Liquidate_RevertsOnLoanNotActive() public {
        vm.prank(borrower);
        uint256 loanId = plugin.borrow(configId, 100 ether, 7 days, 150 ether);

        // Repay the loan
        uint256 repaymentAmount = plugin.getRepaymentAmount(loanId);
        vm.prank(owner);
        borrowToken.mint(borrower, repaymentAmount);

        vm.startPrank(borrower);
        borrowToken.approve(address(plugin), repaymentAmount);
        plugin.repay(loanId);
        vm.stopPrank();

        // Try to liquidate
        vm.prank(liquidator);
        vm.expectRevert(MicroLoanPlugin.LoanNotActive.selector);
        plugin.liquidate(loanId);
    }

    function test_Liquidate_RevertsOnNotDefaulted() public {
        vm.prank(borrower);
        uint256 loanId = plugin.borrow(configId, 100 ether, 7 days, 150 ether);

        // Try to liquidate before due
        vm.prank(liquidator);
        vm.expectRevert(MicroLoanPlugin.LoanNotDefaulted.selector);
        plugin.liquidate(loanId);
    }

    // ============ View Function Tests ============

    function test_GetUserLoans() public {
        vm.startPrank(borrower);
        plugin.borrow(configId, 10 ether, 7 days, 15 ether);
        plugin.borrow(configId, 20 ether, 7 days, 30 ether);
        vm.stopPrank();

        uint256[] memory loans = plugin.getUserLoans(borrower);
        assertEq(loans.length, 2);
        assertEq(loans[0], 0);
        assertEq(loans[1], 1);
    }

    function test_GetRepaymentAmount() public {
        vm.prank(borrower);
        uint256 loanId = plugin.borrow(configId, 100 ether, 7 days, 150 ether);

        // Immediately after borrow
        uint256 repayment = plugin.getRepaymentAmount(loanId);
        assertEq(repayment, 100 ether); // No interest yet

        // After 1 year (for easy calculation)
        vm.warp(block.timestamp + 365 days);
        repayment = plugin.getRepaymentAmount(loanId);
        // 100 ether + 10% interest = 110 ether
        assertEq(repayment, 110 ether);
    }

    function test_GetRepaymentAmount_ReturnsZeroForInactive() public {
        vm.prank(borrower);
        uint256 loanId = plugin.borrow(configId, 100 ether, 7 days, 150 ether);

        // Repay
        uint256 repaymentAmount = plugin.getRepaymentAmount(loanId);
        vm.prank(owner);
        borrowToken.mint(borrower, repaymentAmount);

        vm.startPrank(borrower);
        borrowToken.approve(address(plugin), repaymentAmount);
        plugin.repay(loanId);
        vm.stopPrank();

        assertEq(plugin.getRepaymentAmount(loanId), 0);
    }

    function test_IsDefaulted() public {
        vm.prank(borrower);
        uint256 loanId = plugin.borrow(configId, 100 ether, 1 days, 150 ether);

        // Not defaulted yet
        assertFalse(plugin.isDefaulted(loanId));

        // Move past due time
        vm.warp(block.timestamp + 2 days);
        assertTrue(plugin.isDefaulted(loanId));
    }

    function test_GetCreditScore() public {
        // Borrow and repay multiple loans
        vm.startPrank(borrower);

        uint256 loanId1 = plugin.borrow(configId, 10 ether, 7 days, 15 ether);
        vm.stopPrank();

        vm.prank(owner);
        borrowToken.mint(borrower, 20 ether);

        vm.startPrank(borrower);
        borrowToken.approve(address(plugin), 20 ether);
        plugin.repay(loanId1);

        uint256 loanId2 = plugin.borrow(configId, 20 ether, 7 days, 30 ether);
        vm.stopPrank();

        vm.prank(owner);
        borrowToken.mint(borrower, 30 ether);

        vm.startPrank(borrower);
        borrowToken.approve(address(plugin), 30 ether);
        plugin.repay(loanId2);
        vm.stopPrank();

        MicroLoanPlugin.CreditScore memory score = plugin.getCreditScore(borrower);
        assertEq(score.loansRepaid, 2);
        assertEq(score.loansDefaulted, 0);
        assertGt(score.totalBorrowed, 0);
        assertGt(score.totalRepaid, 0);
    }

    function test_GetRequiredCollateral() public view {
        // With 150% collateral ratio and 1:1 price
        uint256 required = plugin.getRequiredCollateral(configId, 100 ether);
        assertEq(required, 150 ether);
    }

    // ============ Credit Score Update Tests ============

    function test_CreditScore_UpdatesOnRepay() public {
        vm.prank(borrower);
        uint256 loanId = plugin.borrow(configId, 100 ether, 7 days, 150 ether);

        uint256 repaymentAmount = plugin.getRepaymentAmount(loanId);
        vm.prank(owner);
        borrowToken.mint(borrower, repaymentAmount);

        vm.startPrank(borrower);
        borrowToken.approve(address(plugin), repaymentAmount);

        vm.expectEmit(true, false, false, true);
        emit CreditScoreUpdated(borrower, 1, 0);
        plugin.repay(loanId);
        vm.stopPrank();
    }

    function test_CreditScore_UpdatesOnLiquidation() public {
        vm.prank(borrower);
        uint256 loanId = plugin.borrow(configId, 100 ether, 1 days, 150 ether);

        vm.warp(block.timestamp + 2 days);

        vm.prank(liquidator);
        vm.expectEmit(true, false, false, true);
        emit CreditScoreUpdated(borrower, 0, 1);
        plugin.liquidate(loanId);
    }

    // ============ 6-Decimal Token Normalization Tests ============

    /**
     * @notice Helper to set up a mixed-decimal loan config and plugin instance.
     *         Returns (plugin, configId, borrowTkn, collateralTkn).
     */
    function _setupMixedDecimalPlugin(
        uint8 borrowDecimals,
        uint8 collateralDecimals,
        uint256 borrowPrice,
        uint256 collateralPrice
    )
        internal
        returns (
            MicroLoanPlugin mixedPlugin,
            uint256 mixedConfigId,
            MockERC20WithDecimals borrowTkn,
            MockERC20WithDecimals collateralTkn
        )
    {
        borrowTkn = new MockERC20WithDecimals("Borrow", "BRW", borrowDecimals);
        collateralTkn = new MockERC20WithDecimals("Collateral", "COL", collateralDecimals);

        oracle.setPrice(address(borrowTkn), borrowPrice);
        oracle.setPrice(address(collateralTkn), collateralPrice);

        vm.startPrank(owner);
        mixedPlugin = new MicroLoanPlugin(oracle, feeRecipient, 500, 500);

        mixedConfigId = mixedPlugin.createLoanConfig(
            address(borrowTkn),
            address(collateralTkn),
            15_000, // 150% collateral ratio
            1000, // 10% annual interest
            type(uint256).max, // high max for testing
            1, // min = 1 raw unit
            30 days
        );
        vm.stopPrank();
    }

    /**
     * @notice Test _calculateRequiredCollateral with borrow=18 dec, collateral=6 dec.
     *
     * Both tokens priced at $1. Borrow 100e18 (100 tokens).
     * Required collateral = 100 * ($1/$1) * 150% = 150 tokens = 150e6 raw units.
     *
     * Formula from contract:
     *   rawRequired = borrowAmount * borrowPrice * 10^collateralDec / (collateralPrice * 10^borrowDec)
     *   = 100e18 * 1e18 * 1e6 / (1e18 * 1e18)
     *   = 100e6
     *   requiredCollateral = 100e6 * 15_000 / 10_000 = 150e6
     */
    function test_RequiredCollateral_Borrow18_Collateral6_EqualPrices() public {
        (MicroLoanPlugin mixedPlugin, uint256 mixedConfigId,,) = _setupMixedDecimalPlugin(18, 6, 1e18, 1e18);

        uint256 borrowAmount = 100e18; // 100 tokens, 18 decimals
        uint256 required = mixedPlugin.getRequiredCollateral(mixedConfigId, borrowAmount);

        // Expected: 150 collateral tokens in 6-decimal representation = 150e6
        assertEq(required, 150e6, "150 collateral tokens at 6 decimals = 150e6 raw");
    }

    /**
     * @notice Test _calculateRequiredCollateral with borrow=6 dec, collateral=18 dec.
     *
     * Both tokens priced at $1. Borrow 100e6 (100 tokens).
     * Required collateral = 100 * ($1/$1) * 150% = 150 tokens = 150e18 raw units.
     *
     * Formula:
     *   rawRequired = 100e6 * 1e18 * 1e18 / (1e18 * 1e6) = 100e18
     *   requiredCollateral = 100e18 * 15_000 / 10_000 = 150e18
     */
    function test_RequiredCollateral_Borrow6_Collateral18_EqualPrices() public {
        (MicroLoanPlugin mixedPlugin, uint256 mixedConfigId,,) = _setupMixedDecimalPlugin(6, 18, 1e18, 1e18);

        uint256 borrowAmount = 100e6; // 100 tokens, 6 decimals
        uint256 required = mixedPlugin.getRequiredCollateral(mixedConfigId, borrowAmount);

        // Expected: 150 collateral tokens in 18-decimal representation = 150e18
        assertEq(required, 150e18, "150 collateral tokens at 18 decimals = 150e18 raw");
    }

    /**
     * @notice Test _calculateRequiredCollateral with borrow=18 dec ($1), collateral=6 dec ($2000).
     *
     * Scenario: Borrow 4000 USDC (18 dec, $1), collateral is WBTC-like (6 dec, $2000).
     * Required value = 4000 * $1 * 150% = $6000.
     * Required collateral = $6000 / $2000 = 3 tokens = 3e6 raw.
     *
     * Formula:
     *   rawRequired = 4000e18 * 1e18 * 1e6 / (2000e18 * 1e18) = 2e6
     *   requiredCollateral = 2e6 * 15_000 / 10_000 = 3e6
     */
    function test_RequiredCollateral_Borrow18_Collateral6_DifferentPrices() public {
        (MicroLoanPlugin mixedPlugin, uint256 mixedConfigId,,) = _setupMixedDecimalPlugin(18, 6, 1e18, 2000e18);

        uint256 borrowAmount = 4000e18; // 4000 borrow tokens at 18 decimals
        uint256 required = mixedPlugin.getRequiredCollateral(mixedConfigId, borrowAmount);

        // rawRequired = 4000e18 * 1e18 * 1e6 / (2000e18 * 1e18) = 2e6
        // required = 2e6 * 15000 / 10000 = 3e6
        assertEq(required, 3e6, "3 collateral tokens at 6 decimals = 3e6 raw");
    }

    /**
     * @notice Test _calculateRequiredCollateral with borrow=6 dec ($1), collateral=18 dec ($2000).
     *
     * Scenario: Borrow 4000 USDC (6 dec, $1), collateral is WETH (18 dec, $2000).
     * Required value = 4000 * $1 * 150% = $6000.
     * Required collateral = $6000 / $2000 = 3 tokens = 3e18 raw.
     *
     * Formula:
     *   rawRequired = 4000e6 * 1e18 * 1e18 / (2000e18 * 1e6) = 2e18
     *   requiredCollateral = 2e18 * 15_000 / 10_000 = 3e18
     */
    function test_RequiredCollateral_Borrow6_Collateral18_DifferentPrices() public {
        (MicroLoanPlugin mixedPlugin, uint256 mixedConfigId,,) = _setupMixedDecimalPlugin(6, 18, 1e18, 2000e18);

        uint256 borrowAmount = 4000e6; // 4000 tokens at 6 decimals
        uint256 required = mixedPlugin.getRequiredCollateral(mixedConfigId, borrowAmount);

        // rawRequired = 4000e6 * 1e18 * 1e18 / (2000e18 * 1e6) = 2e18
        // required = 2e18 * 15000 / 10000 = 3e18
        assertEq(required, 3e18, "3 collateral tokens at 18 decimals = 3e18 raw");
    }

    /**
     * @notice End-to-end test: borrow with 6-decimal borrow token and 18-decimal collateral,
     *         then repay successfully.
     */
    function test_BorrowAndRepay_Borrow6Dec_Collateral18Dec() public {
        (
            MicroLoanPlugin mixedPlugin,
            uint256 mixedConfigId,
            MockERC20WithDecimals borrowTkn,
            MockERC20WithDecimals collateralTkn
        ) = _setupMixedDecimalPlugin(6, 18, 1e18, 1e18);

        // Fund plugin with borrow token liquidity
        borrowTkn.mint(owner, 100_000e6);
        vm.startPrank(owner);
        borrowTkn.approve(address(mixedPlugin), type(uint256).max);
        mixedPlugin.depositLiquidity(address(borrowTkn), 100_000e6);
        vm.stopPrank();

        // Fund borrower with collateral
        collateralTkn.mint(borrower, 1000e18);
        vm.prank(borrower);
        collateralTkn.approve(address(mixedPlugin), type(uint256).max);

        // Borrow 100 tokens (6 dec) => need 150 collateral tokens (18 dec) at 150% ratio
        uint256 borrowAmount = 100e6;
        uint256 collateralAmount = 150e18;

        vm.prank(borrower);
        uint256 loanId = mixedPlugin.borrow(mixedConfigId, borrowAmount, 7 days, collateralAmount);

        // Verify loan state
        MicroLoanPlugin.Loan memory loan = mixedPlugin.getLoan(loanId);
        assertEq(loan.borrowAmount, borrowAmount, "Borrow amount should be 100e6");
        assertEq(loan.collateralAmount, collateralAmount, "Collateral should be 150e18");
        assertTrue(loan.isActive, "Loan should be active");

        // Verify borrower received borrow tokens
        assertEq(borrowTkn.balanceOf(borrower), borrowAmount, "Borrower should have received borrow tokens");

        // Repay immediately (no interest accrued at same block)
        uint256 repaymentAmount = mixedPlugin.getRepaymentAmount(loanId);
        borrowTkn.mint(borrower, repaymentAmount);

        vm.startPrank(borrower);
        borrowTkn.approve(address(mixedPlugin), repaymentAmount);
        mixedPlugin.repay(loanId);
        vm.stopPrank();

        MicroLoanPlugin.Loan memory loanAfter = mixedPlugin.getLoan(loanId);
        assertFalse(loanAfter.isActive, "Loan should be inactive after repay");

        // Collateral should be returned
        assertEq(collateralTkn.balanceOf(borrower), 1000e18, "Collateral should be fully returned");
    }

    /**
     * @notice End-to-end test: borrow with 18-decimal borrow token and 6-decimal collateral,
     *         then repay successfully.
     */
    function test_BorrowAndRepay_Borrow18Dec_Collateral6Dec() public {
        (
            MicroLoanPlugin mixedPlugin,
            uint256 mixedConfigId,
            MockERC20WithDecimals borrowTkn,
            MockERC20WithDecimals collateralTkn
        ) = _setupMixedDecimalPlugin(18, 6, 1e18, 1e18);

        // Fund plugin with borrow token liquidity
        borrowTkn.mint(owner, 100_000e18);
        vm.startPrank(owner);
        borrowTkn.approve(address(mixedPlugin), type(uint256).max);
        mixedPlugin.depositLiquidity(address(borrowTkn), 100_000e18);
        vm.stopPrank();

        // Fund borrower with collateral
        collateralTkn.mint(borrower, 1000e6);
        vm.prank(borrower);
        collateralTkn.approve(address(mixedPlugin), type(uint256).max);

        // Borrow 100 tokens (18 dec) => need 150 collateral tokens (6 dec) at 150% ratio
        uint256 borrowAmount = 100e18;
        uint256 collateralAmount = 150e6;

        vm.prank(borrower);
        uint256 loanId = mixedPlugin.borrow(mixedConfigId, borrowAmount, 7 days, collateralAmount);

        MicroLoanPlugin.Loan memory loan = mixedPlugin.getLoan(loanId);
        assertEq(loan.borrowAmount, borrowAmount, "Borrow amount should be 100e18");
        assertEq(loan.collateralAmount, collateralAmount, "Collateral should be 150e6");

        // Repay
        uint256 repaymentAmount = mixedPlugin.getRepaymentAmount(loanId);
        borrowTkn.mint(borrower, repaymentAmount);

        vm.startPrank(borrower);
        borrowTkn.approve(address(mixedPlugin), repaymentAmount);
        mixedPlugin.repay(loanId);
        vm.stopPrank();

        MicroLoanPlugin.Loan memory loanAfter = mixedPlugin.getLoan(loanId);
        assertFalse(loanAfter.isActive, "Loan should be inactive after repay");
        assertEq(collateralTkn.balanceOf(borrower), 1000e6, "Collateral should be fully returned");
    }

    /**
     * @notice Test that InsufficientCollateral reverts correctly with mixed decimals.
     *
     * Borrow 100 tokens (6 dec, $1) needs 150 collateral tokens (18 dec, $1) at 150%.
     * Providing only 100e18 (100 tokens) should revert.
     */
    function test_Borrow_MixedDecimals_InsufficientCollateral_Reverts() public {
        (
            MicroLoanPlugin mixedPlugin,
            uint256 mixedConfigId,
            MockERC20WithDecimals borrowTkn,
            MockERC20WithDecimals collateralTkn
        ) = _setupMixedDecimalPlugin(6, 18, 1e18, 1e18);

        // Fund plugin with liquidity
        borrowTkn.mint(owner, 100_000e6);
        vm.startPrank(owner);
        borrowTkn.approve(address(mixedPlugin), type(uint256).max);
        mixedPlugin.depositLiquidity(address(borrowTkn), 100_000e6);
        vm.stopPrank();

        // Fund borrower with collateral
        collateralTkn.mint(borrower, 1000e18);
        vm.prank(borrower);
        collateralTkn.approve(address(mixedPlugin), type(uint256).max);

        // Try to borrow 100 tokens (6 dec) with only 100e18 collateral (need 150e18)
        vm.prank(borrower);
        vm.expectRevert(MicroLoanPlugin.InsufficientCollateral.selector);
        mixedPlugin.borrow(mixedConfigId, 100e6, 7 days, 100e18);
    }

    /**
     * @notice Test both tokens at 6 decimals with equal prices.
     *
     * Borrow 100 tokens (6 dec, $1) needs 150 collateral tokens (6 dec, $1).
     * Both in 6-decimal space: required = 150e6.
     */
    function test_RequiredCollateral_Both6Decimals_EqualPrices() public {
        (MicroLoanPlugin mixedPlugin, uint256 mixedConfigId,,) = _setupMixedDecimalPlugin(6, 6, 1e18, 1e18);

        uint256 required = mixedPlugin.getRequiredCollateral(mixedConfigId, 100e6);
        assertEq(required, 150e6, "Both 6-dec at 1:1 price => 150e6 collateral for 100e6 borrow");
    }
}
