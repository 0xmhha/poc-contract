// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { LendingPool } from "../../src/defi/LendingPool.sol";
import { ILendingPool } from "../../src/defi/interfaces/ILendingPool.sol";
import { MockERC20 as LMock, MockPriceOracle, MockFlashLoanReceiver } from "./LendingPool.t.sol";
import { StakingVault } from "../../src/defi/StakingVault.sol";
import { IStakingVault } from "../../src/defi/interfaces/IStakingVault.sol";
import { MockERC20 as SMock } from "./StakingVault.t.sol";

/// @notice Regression tests for audited DeFi defects
contract LendingPoolAuditRegressionTest is Test {
    LendingPool internal pool;
    MockPriceOracle internal oracle;
    LMock internal usdc;
    LMock internal weth;
    ILendingPool.AssetConfig internal cfg;

    address internal alice = makeAddr("alice"); // lender
    address internal bob = makeAddr("bob"); // borrower

    function setUp() public {
        vm.warp(1_000_000);
        oracle = new MockPriceOracle();
        pool = new LendingPool(address(oracle));
        usdc = new LMock("USDC", "USDC", 18);
        weth = new LMock("WETH", "WETH", 18);
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(weth), 2000e18);
        cfg = ILendingPool.AssetConfig({
            ltv: 7500,
            liquidationThreshold: 8000,
            liquidationBonus: 500,
            reserveFactor: 1000,
            isActive: true,
            canBorrow: true,
            canCollateral: true
        });
        pool.configureAsset(address(usdc), cfg);
        pool.configureAsset(address(weth), cfg);

        usdc.mint(alice, 100_000e18);
        usdc.mint(bob, 100_000e18);
        weth.mint(bob, 100e18);
        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);
        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- DEFI-1

    /// @dev At full utilization, accrued protocol reserves push totalBorrows above totalDeposits.
    ///      Liquidity checks must report "no liquidity" instead of panicking on underflow.
    function test_DEFI1_FullUtilizationAfterInterest_NoUnderflow() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 1000e18);
        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18);
        pool.borrow(address(usdc), 1000e18);
        vm.stopPrank();

        vm.warp(1_000_000 + 1 days);

        vm.prank(alice);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.withdraw(address(usdc), 1);

        vm.prank(bob);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.borrow(address(usdc), 1);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.flashLoan(address(usdc), 1, address(receiver), "");
    }

    /// @dev Interest paid by the borrower, net of the reserve factor, is credited to the lender,
    ///      who can withdraw it in full while the protocol share stays withdrawable by the owner.
    function test_DEFI1_LenderEarnsInterest() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 1000e18);
        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18);
        pool.borrow(address(usdc), 500e18);
        vm.stopPrank();

        vm.warp(1_000_000 + 365 days);

        vm.prank(bob);
        pool.repay(address(usdc), type(uint256).max);
        assertEq(pool.getBorrowBalance(address(usdc), bob), 0, "fully repaid");

        uint256 interestPaid = usdc.balanceOf(address(pool)) - 1000e18;
        uint256 reserves = pool.protocolReserves(address(usdc));
        assertGt(interestPaid, 0, "interest was paid into the pool");
        assertGt(reserves, 0, "protocol took its reserve factor");

        uint256 aliceBalance = pool.getDepositBalance(address(usdc), alice);
        assertEq(aliceBalance, 1000e18 + interestPaid - reserves, "lender credited net interest");

        vm.prank(alice);
        pool.withdraw(address(usdc), type(uint256).max);
        assertEq(usdc.balanceOf(alice), 100_000e18 + interestPaid - reserves, "lender withdrew interest");

        // Remaining balance covers protocol reserves exactly
        assertEq(usdc.balanceOf(address(pool)), reserves);
        pool.withdrawReserves(address(usdc), address(this), reserves);
        assertEq(usdc.balanceOf(address(pool)), 0);
    }

    /// @dev A depositor joining after interest accrued must not capture interest earned earlier.
    function test_DEFI1_LateDepositorDoesNotCaptureEarlierInterest() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 1000e18);
        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18);
        pool.borrow(address(usdc), 500e18);
        vm.stopPrank();

        vm.warp(1_000_000 + 365 days);

        address carol = makeAddr("carol");
        usdc.mint(carol, 1000e18);
        vm.startPrank(carol);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 1000e18);
        vm.stopPrank();

        assertGt(pool.getDepositBalance(address(usdc), alice), 1000e18, "early lender earned interest");
        assertApproxEqAbs(pool.getDepositBalance(address(usdc), carol), 1000e18, 1, "late lender gets principal");
    }

    // ---------------------------------------------------------------- DEFI-8

    /// @dev Delisting (ltv = 0) and relisting an asset must not add it to supportedAssets twice,
    ///      otherwise its collateral is counted twice in health-factor calculations.
    function test_DEFI8_RelistDoesNotDuplicateAsset() public {
        ILendingPool.AssetConfig memory off = cfg;
        off.ltv = 0;
        pool.configureAsset(address(weth), off); // delist
        pool.configureAsset(address(weth), cfg); // relist

        assertEq(pool.supportedAssets(0), address(usdc));
        assertEq(pool.supportedAssets(1), address(weth));
        vm.expectRevert();
        pool.supportedAssets(2);

        vm.prank(alice);
        pool.deposit(address(usdc), 50_000e18);
        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18); // $20,000 collateral
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.borrow(address(usdc), 30_000e18); // 150% of collateral value
        vm.stopPrank();

        // Collateral is counted once: $20,000 * 80% threshold / $10,000 debt = 1.6
        vm.prank(bob);
        pool.borrow(address(usdc), 10_000e18);
        assertEq(pool.calculateHealthFactor(bob), 1.6e18);
    }

    // ---------------------------------------------------------------- DEFI-3

    /// @dev Borrowing is capped by LTV (75%), not by the liquidation threshold (80%).
    function test_DEFI3_BorrowCappedByLtv() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 50_000e18);
        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18); // $20,000 collateral -> $15,000 capacity at 75% LTV

        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.borrow(address(usdc), 16_000e18); // within 80% threshold, above 75% LTV

        pool.borrow(address(usdc), 15_000e18); // exactly at LTV
        vm.stopPrank();
        assertGt(pool.calculateHealthFactor(bob), 1e18, "position at LTV is not liquidatable");
    }

    /// @dev Withdrawing collateral may not push debt above LTV-based capacity.
    function test_DEFI3_WithdrawCappedByLtv() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 50_000e18);
        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18); // $20,000
        pool.borrow(address(usdc), 12_000e18); // needs $16,000 collateral at 75% LTV

        // Leaving 7.6 WETH ($15,200): above the 80% threshold ($15,000) but below LTV ($16,000)
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.withdraw(address(weth), 2.4e18);

        pool.withdraw(address(weth), 2e18); // leaves exactly $16,000
        vm.stopPrank();
        assertEq(pool.getDepositBalance(address(weth), bob), 8e18);
    }

    /// @dev Liquidation still uses the liquidation threshold: a price drop that breaks LTV but not
    ///      the threshold does not make the position liquidatable.
    function test_DEFI3_LiquidationStillUsesThreshold() public {
        vm.prank(alice);
        pool.deposit(address(usdc), 50_000e18);
        vm.startPrank(bob);
        pool.deposit(address(weth), 10e18);
        pool.borrow(address(usdc), 15_000e18);
        vm.stopPrank();

        oracle.setPrice(address(weth), 1900e18); // capacity $14,250 < debt, threshold $15,200 > debt
        assertGe(pool.calculateHealthFactor(bob), 1e18);

        usdc.mint(address(this), 1000e18);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(LendingPool.HealthFactorOk.selector);
        pool.liquidate(address(weth), address(usdc), bob, 1000e18);
    }
}

/// @notice Regression tests for audited StakingVault defects
contract StakingVaultAuditRegressionTest is Test {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _vault(address stk, address rwd, uint256 lockPeriod, uint256 penaltyBps, uint256 funded)
        internal
        returns (StakingVault v)
    {
        IStakingVault.VaultConfig memory cfg = IStakingVault.VaultConfig({
            rewardRate: 1e18,
            lockPeriod: lockPeriod,
            earlyWithdrawPenalty: penaltyBps,
            maxStake: 0,
            minStake: 1e18,
            isActive: true
        });
        v = new StakingVault(stk, rwd, cfg);
        SMock(rwd).mint(address(this), funded);
        SMock(rwd).approve(address(v), type(uint256).max);
        if (funded > 0) v.addRewards(funded);
    }

    function _fundAndApprove(SMock token, StakingVault v, address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(v), type(uint256).max);
    }

    // ---------------------------------------------------------------- DEFI-2

    /// @dev Accrual is capped cumulatively by funded rewards: total promised never exceeds funding,
    ///      and every staker can claim what was promised.
    function test_DEFI2_RewardsNeverOverPromised() public {
        vm.warp(1000);
        SMock stk = new SMock("STK", "STK");
        SMock rwd = new SMock("RWD", "RWD");
        StakingVault v = _vault(address(stk), address(rwd), 0, 0, 100e18); // funds 100 seconds
        _fundAndApprove(stk, v, alice, 10e18);
        _fundAndApprove(stk, v, bob, 10e18);

        vm.prank(alice);
        v.stake(10e18);
        vm.warp(1200);
        vm.prank(bob);
        v.stake(10e18); // accrues the full 100 to alice
        vm.warp(1400);

        uint256 promised = v.pendingRewards(alice) + v.pendingRewards(bob);
        assertLe(promised, 100e18, "promised within funding");
        assertEq(v.pendingRewards(bob), 0, "nothing left for bob");

        vm.prank(alice);
        v.claim();
        assertEq(rwd.balanceOf(alice), 100e18);
        assertEq(v.rewardsAllocated(), 0);

        // New funding resumes accrual for current stakers
        rwd.mint(address(this), 100e18);
        v.addRewards(100e18);
        vm.warp(1450);
        vm.prank(bob);
        v.claim();
        assertEq(rwd.balanceOf(bob), 25e18);
    }

    /// @dev Rewards forfeited by emergencyWithdraw return to the unallocated pool.
    function test_DEFI2_EmergencyWithdrawReleasesAllocation() public {
        vm.warp(1000);
        SMock stk = new SMock("STK", "STK");
        SMock rwd = new SMock("RWD", "RWD");
        StakingVault v = _vault(address(stk), address(rwd), 0, 0, 100e18);
        _fundAndApprove(stk, v, alice, 10e18);
        _fundAndApprove(stk, v, bob, 10e18);

        vm.prank(alice);
        v.stake(10e18);
        vm.warp(1200);
        vm.prank(bob);
        v.stake(10e18); // allocates all 100 to alice
        assertEq(v.rewardsAllocated(), 100e18);

        vm.prank(alice);
        v.emergencyWithdraw();
        assertEq(v.rewardsAllocated(), 0, "forfeited rewards released");

        vm.warp(1300);
        vm.prank(bob);
        v.claim();
        assertEq(rwd.balanceOf(bob), 100e18, "released rewards accrue to remaining staker");
    }
}
