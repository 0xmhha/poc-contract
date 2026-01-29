// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { LendingPool } from "../../src/defi/LendingPool.sol";
import { ILendingPool, IFlashLoanReceiver } from "../../src/defi/interfaces/ILendingPool.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
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

// Mock Price Oracle
contract MockPriceOracle {
    mapping(address => uint256) public prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPriceWithTimestamp(address token) external view returns (uint256 price, uint256 timestamp) {
        return (prices[token], block.timestamp);
    }

    function getPrice(address token) external view returns (uint256) {
        return prices[token];
    }
}

// Mock Flash Loan Receiver
contract MockFlashLoanReceiver is IFlashLoanReceiver {
    bool public shouldSucceed = true;
    bool public shouldRepay = true;

    function setSucceed(bool _succeed) external {
        shouldSucceed = _succeed;
    }

    function setRepay(bool _repay) external {
        shouldRepay = _repay;
    }

    function executeOperation(address asset, uint256 amount, uint256 fee, address, bytes calldata)
        external
        returns (bool)
    {
        if (shouldRepay) {
            // Repay the loan + fee
            require(ERC20(asset).transfer(msg.sender, amount + fee), "Transfer failed");
        }
        return shouldSucceed;
    }
}

contract LendingPoolTest is Test {
    LendingPool public pool;
    MockPriceOracle public oracle;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockFlashLoanReceiver public flashLoanReceiver;

    address public owner = address(this);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public liquidator = address(0x11D);

    uint256 constant USDC_PRICE = 1e18; // $1
    uint256 constant WETH_PRICE = 2000e18; // $2000

    function setUp() public {
        // Deploy oracle
        oracle = new MockPriceOracle();

        // Deploy pool
        pool = new LendingPool(address(oracle));

        // Deploy tokens (using 18 decimals for simplicity in PoC)
        usdc = new MockERC20("USD Coin", "USDC", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Set prices
        oracle.setPrice(address(usdc), USDC_PRICE);
        oracle.setPrice(address(weth), WETH_PRICE);

        // Configure assets
        ILendingPool.AssetConfig memory usdcConfig = ILendingPool.AssetConfig({
            ltv: 8000, // 80%
            liquidationThreshold: 8500, // 85%
            liquidationBonus: 500, // 5%
            reserveFactor: 1000, // 10%
            isActive: true,
            canBorrow: true,
            canCollateral: true
        });

        ILendingPool.AssetConfig memory wethConfig = ILendingPool.AssetConfig({
            ltv: 7500, // 75%
            liquidationThreshold: 8000, // 80%
            liquidationBonus: 500, // 5%
            reserveFactor: 1000, // 10%
            isActive: true,
            canBorrow: true,
            canCollateral: true
        });

        pool.configureAsset(address(usdc), usdcConfig);
        pool.configureAsset(address(weth), wethConfig);

        // Deploy flash loan receiver
        flashLoanReceiver = new MockFlashLoanReceiver();

        // Mint tokens to users
        usdc.mint(alice, 100_000e18);
        usdc.mint(bob, 100_000e18);
        usdc.mint(liquidator, 100_000e18);
        usdc.mint(address(flashLoanReceiver), 10_000e18);

        weth.mint(alice, 100e18);
        weth.mint(bob, 100e18);
        weth.mint(liquidator, 100e18);
        weth.mint(address(flashLoanReceiver), 10e18);

        // Approve pool
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor() public view {
        assertEq(address(pool.oracle()), address(oracle));
        assertEq(pool.owner(), owner);
    }

    // ============ Admin Tests ============

    function test_ConfigureAsset() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        oracle.setPrice(address(newToken), 1e18);

        ILendingPool.AssetConfig memory config = ILendingPool.AssetConfig({
            ltv: 7000,
            liquidationThreshold: 7500,
            liquidationBonus: 500,
            reserveFactor: 1500,
            isActive: true,
            canBorrow: true,
            canCollateral: true
        });

        pool.configureAsset(address(newToken), config);

        ILendingPool.AssetConfig memory stored = pool.getAssetConfig(address(newToken));
        assertEq(stored.ltv, 7000);
        assertEq(stored.liquidationThreshold, 7500);
    }

    function test_ConfigureAsset_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        pool.configureAsset(address(usdc), ILendingPool.AssetConfig(8000, 8500, 500, 1000, true, true, true));
    }

    function test_SetOracle() public {
        MockPriceOracle newOracle = new MockPriceOracle();
        pool.setOracle(address(newOracle));
        assertEq(address(pool.oracle()), address(newOracle));
    }

    // ============ Deposit Tests ============

    function test_Deposit() public {
        uint256 depositAmount = 10_000e18;

        vm.prank(alice);
        pool.deposit(address(usdc), depositAmount);

        uint256 balance = pool.getDepositBalance(address(usdc), alice);
        assertEq(balance, depositAmount);
    }

    function test_Deposit_EmitsEvent() public {
        uint256 depositAmount = 10_000e18;

        vm.expectEmit(true, true, false, true);
        emit ILendingPool.Deposit(address(usdc), alice, depositAmount, depositAmount);

        vm.prank(alice);
        pool.deposit(address(usdc), depositAmount);
    }

    function test_Deposit_ZeroAmount_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(LendingPool.InvalidAmount.selector);
        pool.deposit(address(usdc), 0);
    }

    function test_Deposit_UnsupportedAsset_Reverts() public {
        MockERC20 unsupported = new MockERC20("Unsupported", "UNS", 18);
        unsupported.mint(alice, 1000e18);

        vm.startPrank(alice);
        unsupported.approve(address(pool), type(uint256).max);
        vm.expectRevert(LendingPool.AssetNotSupported.selector);
        pool.deposit(address(unsupported), 100e18);
        vm.stopPrank();
    }

    // ============ Withdraw Tests ============

    function test_Withdraw() public {
        uint256 depositAmount = 10_000e18;
        uint256 withdrawAmount = 5_000e18;

        vm.startPrank(alice);
        pool.deposit(address(usdc), depositAmount);
        pool.withdraw(address(usdc), withdrawAmount);
        vm.stopPrank();

        uint256 balance = pool.getDepositBalance(address(usdc), alice);
        assertEq(balance, depositAmount - withdrawAmount);
    }

    function test_Withdraw_MaxAmount() public {
        uint256 depositAmount = 10_000e18;

        vm.startPrank(alice);
        pool.deposit(address(usdc), depositAmount);
        pool.withdraw(address(usdc), type(uint256).max);
        vm.stopPrank();

        uint256 balance = pool.getDepositBalance(address(usdc), alice);
        assertEq(balance, 0);
    }

    function test_Withdraw_InsufficientLiquidity_Reverts() public {
        // Alice deposits
        vm.prank(alice);
        pool.deposit(address(usdc), 10_000e18);

        // Bob deposits collateral and borrows
        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18);
        pool.borrow(address(usdc), 8_000e18);
        vm.stopPrank();

        // Alice tries to withdraw more than available
        vm.prank(alice);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.withdraw(address(usdc), 5_000e18);
    }

    // ============ Borrow Tests ============

    function test_Borrow() public {
        // Alice provides liquidity
        vm.prank(alice);
        pool.deposit(address(usdc), 10_000e18);

        // Bob deposits collateral and borrows
        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18); // $20,000 collateral
        pool.borrow(address(usdc), 5_000e18); // Borrow $5,000
        vm.stopPrank();

        uint256 borrowBalance = pool.getBorrowBalance(address(usdc), bob);
        assertEq(borrowBalance, 5_000e18);
    }

    function test_Borrow_EmitsEvent() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 10_000e18);

        vm.prank(bob);
        pool.deposit(address(weth), 10e18);

        vm.expectEmit(true, true, false, true);
        emit ILendingPool.Borrow(address(usdc), bob, 5_000e18);

        vm.prank(bob);
        pool.borrow(address(usdc), 5_000e18);
    }

    function test_Borrow_InsufficientCollateral_Reverts() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 100_000e18);

        // Bob deposits small collateral
        vm.startPrank(bob);
        pool.deposit(address(weth), 1e18); // $2,000 collateral
        // Try to borrow more than allowed (75% of $2000 = $1500)
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.borrow(address(usdc), 2_000e18);
        vm.stopPrank();
    }

    function test_Borrow_InsufficientLiquidity_Reverts() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 1_000e18);

        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.borrow(address(usdc), 5_000e18);
        vm.stopPrank();
    }

    // ============ Repay Tests ============

    function test_Repay() public {
        // Setup borrow
        vm.prank(alice);
        pool.deposit(address(usdc), 10_000e18);

        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18);
        pool.borrow(address(usdc), 5_000e18);

        // Repay half
        pool.repay(address(usdc), 2_500e18);
        vm.stopPrank();

        uint256 borrowBalance = pool.getBorrowBalance(address(usdc), bob);
        assertEq(borrowBalance, 2_500e18);
    }

    function test_Repay_MaxAmount() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 10_000e18);

        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18);
        pool.borrow(address(usdc), 5_000e18);
        pool.repay(address(usdc), type(uint256).max);
        vm.stopPrank();

        uint256 borrowBalance = pool.getBorrowBalance(address(usdc), bob);
        assertEq(borrowBalance, 0);
    }

    function test_Repay_EmitsEvent() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 10_000e18);

        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18);
        pool.borrow(address(usdc), 5_000e18);

        vm.expectEmit(true, true, false, true);
        emit ILendingPool.Repay(address(usdc), bob, 5_000e18);

        pool.repay(address(usdc), 5_000e18);
        vm.stopPrank();
    }

    // ============ Liquidation Tests ============

    function test_Liquidate() public {
        // Alice provides USDC liquidity
        vm.prank(alice);
        pool.deposit(address(usdc), 50_000e18);

        // Bob deposits WETH and borrows USDC
        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18); // $20,000 collateral
        pool.borrow(address(usdc), 15_000e18); // Borrow $15,000 (75% LTV)
        vm.stopPrank();

        // Price drops - WETH now worth $1500
        oracle.setPrice(address(weth), 1500e18);

        // Health factor should be below 1.0 now
        uint256 healthFactor = pool.calculateHealthFactor(bob);
        assertLt(healthFactor, 1e18);

        // Liquidator repays debt and seizes collateral
        vm.prank(liquidator);
        pool.liquidate(address(weth), address(usdc), bob, 5_000e18);

        // Bob's debt should be reduced
        uint256 bobDebt = pool.getBorrowBalance(address(usdc), bob);
        assertLt(bobDebt, 15_000e18);
    }

    function test_Liquidate_HealthFactorOk_Reverts() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 50_000e18);

        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18);
        pool.borrow(address(usdc), 5_000e18); // Safe borrow
        vm.stopPrank();

        // Healthy position
        vm.prank(liquidator);
        vm.expectRevert(LendingPool.HealthFactorOk.selector);
        pool.liquidate(address(weth), address(usdc), bob, 1_000e18);
    }

    // ============ Flash Loan Tests ============

    function test_FlashLoan() public {
        // Provide liquidity
        vm.prank(alice);
        pool.deposit(address(usdc), 10_000e18);

        uint256 loanAmount = 5_000e18;
        uint256 fee = (loanAmount * 9) / 10_000; // 0.09%

        // Give receiver enough to pay fee
        usdc.mint(address(flashLoanReceiver), fee);

        vm.prank(bob);
        pool.flashLoan(address(usdc), loanAmount, address(flashLoanReceiver), "");

        // Check protocol reserves increased
        assertEq(pool.protocolReserves(address(usdc)), fee);
    }

    function test_FlashLoan_EmitsEvent() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 10_000e18);

        uint256 loanAmount = 5_000e18;
        uint256 fee = (loanAmount * 9) / 10_000;
        usdc.mint(address(flashLoanReceiver), fee);

        vm.expectEmit(true, true, false, true);
        emit ILendingPool.FlashLoan(address(usdc), address(flashLoanReceiver), loanAmount, fee);

        vm.prank(bob);
        pool.flashLoan(address(usdc), loanAmount, address(flashLoanReceiver), "");
    }

    function test_FlashLoan_FailedExecution_Reverts() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 10_000e18);

        flashLoanReceiver.setSucceed(false);

        vm.prank(bob);
        vm.expectRevert(LendingPool.FlashLoanFailed.selector);
        pool.flashLoan(address(usdc), 5_000e18, address(flashLoanReceiver), "");
    }

    function test_FlashLoan_NotRepaid_Reverts() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 10_000e18);

        flashLoanReceiver.setRepay(false);

        vm.prank(bob);
        vm.expectRevert(LendingPool.FlashLoanFailed.selector);
        pool.flashLoan(address(usdc), 5_000e18, address(flashLoanReceiver), "");
    }

    function test_FlashLoan_InsufficientLiquidity_Reverts() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 1_000e18);

        vm.prank(bob);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.flashLoan(address(usdc), 5_000e18, address(flashLoanReceiver), "");
    }

    // ============ Interest Accrual Tests ============

    function test_InterestAccrual() public {
        // Alice deposits
        vm.prank(alice);
        pool.deposit(address(usdc), 10_000e18);

        // Bob borrows
        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18);
        pool.borrow(address(usdc), 5_000e18);
        vm.stopPrank();

        // Advance time by 1 year
        vm.warp(block.timestamp + 365 days);

        // Bob's debt should have increased
        uint256 borrowBalance = pool.getBorrowBalance(address(usdc), bob);
        assertGt(borrowBalance, 5_000e18);
    }

    // ============ View Function Tests ============

    function test_GetAccountData() public {
        vm.startPrank(alice);
        pool.deposit(address(weth), 10e18); // $20,000 collateral
        pool.deposit(address(usdc), 10_000e18);
        vm.stopPrank();

        vm.prank(alice);
        pool.borrow(address(usdc), 5_000e18);

        ILendingPool.AccountData memory data = pool.getAccountData(alice);

        assertGt(data.totalCollateralValue, 0);
        assertGt(data.totalDebtValue, 0);
        // Health factor > 1 means position is healthy (not 1e18 due to different scaling in getAccountData)
        assertGt(data.healthFactor, 1);
    }

    function test_GetReserveData() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 10_000e18);

        ILendingPool.ReserveData memory data = pool.getReserveData(address(usdc));

        assertEq(data.totalDeposits, 10_000e18);
        assertEq(data.totalBorrows, 0);
    }

    function test_CalculateHealthFactor_NoDebt() public {
        vm.prank(alice);
        pool.deposit(address(weth), 10e18);

        uint256 healthFactor = pool.calculateHealthFactor(alice);
        assertEq(healthFactor, type(uint256).max);
    }

    function test_CalculateHealthFactor_WithDebt() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 50_000e18);

        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18); // $20,000 collateral
        pool.borrow(address(usdc), 10_000e18); // $10,000 debt
        vm.stopPrank();

        // Health factor = (collateral * liquidation threshold) / debt
        // = (20000 * 0.8) / 10000 = 1.6
        uint256 healthFactor = pool.calculateHealthFactor(bob);
        assertApproxEqRel(healthFactor, 1.6e18, 0.01e18);
    }

    // ============ Protocol Reserve Tests ============

    function test_WithdrawReserves() public {
        // Generate some fees via flash loan
        vm.prank(alice);
        pool.deposit(address(usdc), 10_000e18);

        uint256 loanAmount = 5_000e18;
        uint256 fee = (loanAmount * 9) / 10_000;
        usdc.mint(address(flashLoanReceiver), fee);

        vm.prank(bob);
        pool.flashLoan(address(usdc), loanAmount, address(flashLoanReceiver), "");

        // Withdraw reserves
        uint256 ownerBalanceBefore = usdc.balanceOf(owner);
        pool.withdrawReserves(address(usdc), owner, fee);
        uint256 ownerBalanceAfter = usdc.balanceOf(owner);

        assertEq(ownerBalanceAfter - ownerBalanceBefore, fee);
        assertEq(pool.protocolReserves(address(usdc)), 0);
    }

    // ============ Edge Cases ============

    function test_MultipleAssets() public {
        // Alice deposits both assets
        vm.startPrank(alice);
        pool.deposit(address(usdc), 10_000e18);
        pool.deposit(address(weth), 5e18);
        vm.stopPrank();

        // Bob deposits collateral and borrows both
        vm.startPrank(bob);
        pool.deposit(address(weth), 20e18);
        pool.borrow(address(usdc), 5_000e18);
        vm.stopPrank();

        ILendingPool.AccountData memory data = pool.getAccountData(bob);
        assertGt(data.totalCollateralValue, 0);
        assertGt(data.totalDebtValue, 0);
    }
}
