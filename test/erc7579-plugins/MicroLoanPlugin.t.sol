// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MicroLoanPlugin} from "../../src/erc7579-plugins/MicroLoanPlugin.sol";
import {IPriceOracle} from "../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";
import {MODULE_TYPE_EXECUTOR} from "../../src/erc7579-smartaccount/types/Constants.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
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
            500,   // 5% protocol fee
            500    // 5% liquidation bonus
        );

        // Set prices (1:1 for simplicity)
        oracle.setPrice(address(borrowToken), 1e18);
        oracle.setPrice(address(collateralToken), 1e18);

        // Fund plugin with liquidity
        borrowToken.mint(owner, 10000 ether);
        borrowToken.approve(address(plugin), 10000 ether);
        plugin.depositLiquidity(address(borrowToken), 10000 ether);

        // Fund borrower with collateral
        collateralToken.mint(borrower, 1000 ether);

        // Create default loan config
        configId = plugin.createLoanConfig(
            address(borrowToken),
            address(collateralToken),
            15000,           // 150% collateral ratio
            1000,            // 10% annual interest
            1000 ether,      // max loan
            1 ether,         // min loan
            30 days          // max duration
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
            address(borrowToken),
            address(collateralToken),
            12000,
            800,
            500 ether,
            0.5 ether,
            60 days
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
        assertEq(collateralRatio, 12000);
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

        (,,,,,,,bool isActive) = plugin.loanConfigs(configId);
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

        assertEq(plugin.liquidityPool(address(borrowToken)), 10100 ether);
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
        plugin.withdrawLiquidity(address(borrowToken), 20000 ether, owner);
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
}
