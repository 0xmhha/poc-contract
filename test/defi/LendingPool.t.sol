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

    // ============ 6-Decimal Token Normalization Tests ============

    /**
     * @notice Test that _getAssetValue correctly normalizes 6-decimal token amounts.
     *
     * A 6-decimal token like real USDC represents 1 token as 1_000_000 (1e6) raw units.
     * With a price of 1e18 ($1), the value should be:
     *   (1e6 * 1e18) / 10^6 = 1e18  ($1 in 18-decimal value)
     *
     * If normalization is wrong (using 18 decimals for a 6-decimal token), the result
     * would be (1e6 * 1e18) / 10^18 = 1e6, which is 1e12x too small.
     */
    function test_GetAssetValue_6DecimalToken_NormalizesCorrectly() public {
        // Deploy a 6-decimal USDC (realistic)
        MockERC20 usdc6 = new MockERC20("USD Coin 6", "USDC6", 6);
        oracle.setPrice(address(usdc6), 1e18); // $1

        ILendingPool.AssetConfig memory usdc6Config = ILendingPool.AssetConfig({
            ltv: 8000,
            liquidationThreshold: 8500,
            liquidationBonus: 500,
            reserveFactor: 1000,
            isActive: true,
            canBorrow: true,
            canCollateral: true
        });
        pool.configureAsset(address(usdc6), usdc6Config);

        // Verify decimals are cached as 6
        assertEq(pool.assetDecimals(address(usdc6)), 6);

        // Deposit 1000 USDC (= 1000e6 raw units) then check account value
        uint256 depositAmount = 1000e6; // 1000 USDC in 6-decimal representation
        usdc6.mint(alice, depositAmount);

        vm.startPrank(alice);
        usdc6.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc6), depositAmount);
        vm.stopPrank();

        // Check that account data reflects $1000 collateral value (1000e18 in 18-decimal USD)
        ILendingPool.AccountData memory data = pool.getAccountData(alice);
        // The value should be (1000e6 * 1e18) / 1e6 = 1000e18
        assertEq(data.totalCollateralValue, 1000e18, "1000 USDC (6 dec) should be valued at $1000");
    }

    /**
     * @notice Test that a single token unit of a 6-decimal asset is valued correctly.
     *
     * 1 USDC = 1e6 raw units. At price $1 (1e18), value should be exactly 1e18.
     */
    function test_GetAssetValue_6DecimalToken_SingleUnit() public {
        MockERC20 usdc6 = new MockERC20("USD Coin 6", "USDC6", 6);
        oracle.setPrice(address(usdc6), 1e18);

        ILendingPool.AssetConfig memory config = ILendingPool.AssetConfig({
            ltv: 8000,
            liquidationThreshold: 8500,
            liquidationBonus: 500,
            reserveFactor: 1000,
            isActive: true,
            canBorrow: true,
            canCollateral: true
        });
        pool.configureAsset(address(usdc6), config);

        // Deposit exactly 1 USDC (1e6 raw units)
        uint256 oneUsdc = 1e6;
        usdc6.mint(alice, oneUsdc);

        vm.startPrank(alice);
        usdc6.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc6), oneUsdc);
        vm.stopPrank();

        // Account value should be exactly $1 = 1e18
        ILendingPool.AccountData memory data = pool.getAccountData(alice);
        assertEq(data.totalCollateralValue, 1e18, "1 USDC (1e6 raw) should be valued at $1 (1e18)");
    }

    /**
     * @notice Test borrowing with mixed-decimal assets:
     *         deposit 6-decimal collateral (USDC6), borrow 18-decimal asset (WETH).
     *
     * Scenario:
     *   - Deposit 10,000 USDC6 (= 10_000e6 raw) at $1 each = $10,000 collateral
     *   - WETH LTV = 75%, so max borrow from WETH deposits
     *   - But USDC6 LTV = 80%, so collateral capacity = $8,000
     *   - Borrow 2 WETH (= 2e18 raw) at $2,000 each = $4,000 debt
     *   - Health factor = (10_000 * 0.85) / 4_000 = 2.125
     */
    function test_BorrowRepay_6DecimalCollateral_18DecimalBorrow() public {
        // Deploy 6-decimal USDC
        MockERC20 usdc6 = new MockERC20("USD Coin 6", "USDC6", 6);
        oracle.setPrice(address(usdc6), 1e18); // $1

        ILendingPool.AssetConfig memory usdc6Config = ILendingPool.AssetConfig({
            ltv: 8000,
            liquidationThreshold: 8500,
            liquidationBonus: 500,
            reserveFactor: 1000,
            isActive: true,
            canBorrow: true,
            canCollateral: true
        });
        pool.configureAsset(address(usdc6), usdc6Config);

        // Alice provides WETH liquidity for borrowing
        vm.prank(alice);
        pool.deposit(address(weth), 50e18); // $100,000

        // Bob deposits 6-decimal USDC collateral and borrows WETH
        uint256 collateralAmount = 10_000e6; // 10,000 USDC in 6 decimals
        usdc6.mint(bob, collateralAmount);

        vm.startPrank(bob);
        usdc6.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc6), collateralAmount);

        // Borrow 2 WETH ($4,000) against $10,000 USDC6 collateral (LTV 80% = $8,000 capacity)
        uint256 borrowAmount = 2e18; // 2 WETH
        pool.borrow(address(weth), borrowAmount);
        vm.stopPrank();

        // Verify borrow balance
        uint256 bobBorrow = pool.getBorrowBalance(address(weth), bob);
        assertEq(bobBorrow, borrowAmount, "Bob should have borrowed 2 WETH");

        // Verify health factor is healthy
        // HF = ($10,000 * 0.85) / $4,000 = 2.125
        uint256 healthFactor = pool.calculateHealthFactor(bob);
        assertApproxEqRel(healthFactor, 2.125e18, 0.01e18, "Health factor should be ~2.125");

        // Bob repays the borrow
        vm.startPrank(bob);
        weth.approve(address(pool), type(uint256).max);
        pool.repay(address(weth), borrowAmount);
        vm.stopPrank();

        uint256 bobBorrowAfter = pool.getBorrowBalance(address(weth), bob);
        assertEq(bobBorrowAfter, 0, "Borrow balance should be 0 after full repay");
    }

    /**
     * @notice Test borrowing 6-decimal token against 18-decimal collateral.
     *
     * Scenario:
     *   - Bob deposits 5 WETH (= 5e18 raw) at $2,000 each = $10,000 collateral
     *   - Borrow 4000 USDC6 (= 4000e6 raw) at $1 each = $4,000 debt
     *   - WETH collateral LTV = 75%, threshold = 80%
     *   - HF = ($10,000 * 0.80) / $4,000 = 2.0
     */
    function test_BorrowRepay_18DecimalCollateral_6DecimalBorrow() public {
        // Deploy 6-decimal borrow token
        MockERC20 usdc6 = new MockERC20("USD Coin 6", "USDC6", 6);
        oracle.setPrice(address(usdc6), 1e18);

        ILendingPool.AssetConfig memory usdc6Config = ILendingPool.AssetConfig({
            ltv: 8000,
            liquidationThreshold: 8500,
            liquidationBonus: 500,
            reserveFactor: 1000,
            isActive: true,
            canBorrow: true,
            canCollateral: true
        });
        pool.configureAsset(address(usdc6), usdc6Config);

        // Alice provides USDC6 liquidity for borrowing
        usdc6.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc6.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc6), 100_000e6);
        vm.stopPrank();

        // Bob deposits WETH collateral (18 decimals) and borrows USDC6 (6 decimals)
        vm.startPrank(bob);
        pool.deposit(address(weth), 5e18); // $10,000 collateral

        uint256 borrowAmount = 4000e6; // 4,000 USDC6 = $4,000
        pool.borrow(address(usdc6), borrowAmount);
        vm.stopPrank();

        // Verify borrow balance
        uint256 bobBorrow = pool.getBorrowBalance(address(usdc6), bob);
        assertEq(bobBorrow, borrowAmount, "Bob should have borrowed 4000 USDC6");

        // Verify health factor
        // HF = ($10,000 * 0.80) / $4,000 = 2.0
        uint256 healthFactor = pool.calculateHealthFactor(bob);
        assertApproxEqRel(healthFactor, 2.0e18, 0.01e18, "Health factor should be ~2.0");

        // Bob repays
        vm.startPrank(bob);
        usdc6.approve(address(pool), type(uint256).max);
        pool.repay(address(usdc6), borrowAmount);
        vm.stopPrank();

        uint256 bobBorrowAfter = pool.getBorrowBalance(address(usdc6), bob);
        assertEq(bobBorrowAfter, 0, "Borrow balance should be 0 after full repay");
    }

    /**
     * @notice Test that the health factor computation is consistent when both
     *         collateral and debt are 6-decimal tokens at different prices.
     *
     * Scenario:
     *   - Token A (6 dec) price = $2, Token B (6 dec) price = $1
     *   - Deposit 5000 TokenA (= 5000e6) = $10,000 collateral
     *   - Borrow  4000 TokenB (= 4000e6) = $4,000 debt
     *   - LTV=80%, liquidation threshold=85%
     *   - HF = ($10,000 * 0.85) / $4,000 = 2.125
     */
    function test_HealthFactor_Both6DecimalTokens_DifferentPrices() public {
        MockERC20 tokenA = new MockERC20("Token A", "TKNA", 6);
        MockERC20 tokenB = new MockERC20("Token B", "TKNB", 6);

        oracle.setPrice(address(tokenA), 2e18);  // $2
        oracle.setPrice(address(tokenB), 1e18);  // $1

        ILendingPool.AssetConfig memory configA = ILendingPool.AssetConfig({
            ltv: 8000,
            liquidationThreshold: 8500,
            liquidationBonus: 500,
            reserveFactor: 1000,
            isActive: true,
            canBorrow: true,
            canCollateral: true
        });
        ILendingPool.AssetConfig memory configB = ILendingPool.AssetConfig({
            ltv: 8000,
            liquidationThreshold: 8500,
            liquidationBonus: 500,
            reserveFactor: 1000,
            isActive: true,
            canBorrow: true,
            canCollateral: true
        });
        pool.configureAsset(address(tokenA), configA);
        pool.configureAsset(address(tokenB), configB);

        // Provide TokenB liquidity for borrowing
        tokenB.mint(alice, 100_000e6);
        vm.startPrank(alice);
        tokenB.approve(address(pool), type(uint256).max);
        pool.deposit(address(tokenB), 100_000e6);
        vm.stopPrank();

        // Bob deposits TokenA collateral and borrows TokenB
        tokenA.mint(bob, 5000e6);
        vm.startPrank(bob);
        tokenA.approve(address(pool), type(uint256).max);
        pool.deposit(address(tokenA), 5000e6); // 5000 * $2 = $10,000

        pool.borrow(address(tokenB), 4000e6); // 4000 * $1 = $4,000
        vm.stopPrank();

        // HF = ($10,000 * 0.85) / $4,000 = 2.125
        uint256 healthFactor = pool.calculateHealthFactor(bob);
        assertApproxEqRel(healthFactor, 2.125e18, 0.01e18, "Health factor should be ~2.125");
    }

    /**
     * @notice Test that insufficient collateral revert still works correctly
     *         with 6-decimal collateral.
     *
     * With 1000 USDC6 ($1,000) at 80% LTV, max borrow = $800.
     * Attempting to borrow $900 worth of WETH should revert.
     */
    function test_Borrow_6DecimalCollateral_InsufficientCollateral_Reverts() public {
        MockERC20 usdc6 = new MockERC20("USD Coin 6", "USDC6", 6);
        oracle.setPrice(address(usdc6), 1e18);

        ILendingPool.AssetConfig memory usdc6Config = ILendingPool.AssetConfig({
            ltv: 8000,
            liquidationThreshold: 8500,
            liquidationBonus: 500,
            reserveFactor: 1000,
            isActive: true,
            canBorrow: true,
            canCollateral: true
        });
        pool.configureAsset(address(usdc6), usdc6Config);

        // Alice provides WETH liquidity
        vm.prank(alice);
        pool.deposit(address(weth), 50e18);

        // Bob deposits only 1000 USDC6 ($1,000) - max borrow at 80% = $800
        usdc6.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdc6.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc6), 1000e6);

        // Try to borrow 0.45 WETH = $900 > $800 max
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.borrow(address(weth), 0.45e18);
        vm.stopPrank();
    }
}
