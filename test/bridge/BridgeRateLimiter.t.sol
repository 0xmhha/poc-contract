// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { BridgeRateLimiter } from "../../src/bridge/BridgeRateLimiter.sol";

contract BridgeRateLimiterTest is Test {
    BridgeRateLimiter public limiter;

    address public owner;
    address public bridge;
    address public token;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant TOKEN_PRICE = 1 * PRECISION; //$1
    uint8 public constant TOKEN_DECIMALS = 18;

    event TransactionRecorded(
        address indexed token, uint256 amount, uint256 usdValue, uint256 hourlyUsage, uint256 dailyUsage
    );
    event AlertTriggered(string limitType, uint256 currentUsage, uint256 limit, uint256 percentage);
    event AutoPauseActivated(string reason, uint256 currentUsage, uint256 limit);
    event LimitsUpdated(uint256 maxPerTx, uint256 hourlyLimit, uint256 dailyLimit);
    event ThresholdsUpdated(uint256 alertThreshold, uint256 autoPauseThreshold);
    event TokenPriceUpdated(address indexed token, uint256 price);
    event AuthorizedCallerUpdated(address indexed caller, bool authorized);
    event WindowReset(string windowType, uint256 timestamp);

    function setUp() public {
        owner = makeAddr("owner");
        bridge = makeAddr("bridge");
        token = makeAddr("token");

        vm.prank(owner);
        limiter = new BridgeRateLimiter();

        // Configure token
        vm.prank(owner);
        limiter.configureToken(token, TOKEN_PRICE, TOKEN_DECIMALS);

        // Authorize bridge
        vm.prank(owner);
        limiter.setAuthorizedCaller(bridge, true);
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesDefaultLimits() public view {
        BridgeRateLimiter.RateLimitConfig memory config = limiter.getGlobalLimits();

        assertEq(config.maxPerTransaction, 100_000 * PRECISION);
        assertEq(config.hourlyLimit, 500_000 * PRECISION);
        assertEq(config.dailyLimit, 5_000_000 * PRECISION);
    }

    function test_Constructor_InitializesThresholds() public view {
        assertEq(limiter.alertThreshold(), 80);
        assertEq(limiter.autoPauseThreshold(), 95);
    }

    // ============ Transaction Check Tests ============

    function test_CheckAndRecordTransaction_Success() public {
        uint256 amount = 10_000 * 1e18; // $10,000

        vm.prank(bridge);
        (bool allowed, uint256 usdValue) = limiter.checkAndRecordTransaction(token, amount);

        assertTrue(allowed);
        assertEq(usdValue, 10_000 * PRECISION);
    }

    function test_CheckAndRecordTransaction_UpdatesVolumes() public {
        uint256 amount = 10_000 * 1e18;

        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, amount);

        (uint256 hourlyVolume, uint256 dailyVolume) = limiter.getCurrentWindowVolumes();
        assertEq(hourlyVolume, 10_000 * PRECISION);
        assertEq(dailyVolume, 10_000 * PRECISION);
    }

    function test_CheckAndRecordTransaction_EmitsEvent() public {
        uint256 amount = 10_000 * 1e18;

        vm.prank(bridge);
        vm.expectEmit(true, false, false, true);
        emit TransactionRecorded(token, amount, 10_000 * PRECISION, 10_000 * PRECISION, 10_000 * PRECISION);
        limiter.checkAndRecordTransaction(token, amount);
    }

    function test_CheckAndRecordTransaction_RevertsOnZeroAmount() public {
        vm.prank(bridge);
        vm.expectRevert(BridgeRateLimiter.ZeroAmount.selector);
        limiter.checkAndRecordTransaction(token, 0);
    }

    function test_CheckAndRecordTransaction_RevertsOnUnsupportedToken() public {
        vm.prank(bridge);
        vm.expectRevert(BridgeRateLimiter.TokenNotSupported.selector);
        limiter.checkAndRecordTransaction(makeAddr("unsupported"), 1000);
    }

    function test_CheckAndRecordTransaction_RevertsOnPerTxLimit() public {
        uint256 amount = 150_000 * 1e18; // $150,000 exceeds $100K limit

        vm.prank(bridge);
        vm.expectRevert(BridgeRateLimiter.ExceedsPerTransactionLimit.selector);
        limiter.checkAndRecordTransaction(token, amount);
    }

    function test_CheckAndRecordTransaction_RevertsOnHourlyLimit() public {
        // Make multiple transactions to exceed hourly limit
        uint256 amount = 90_000 * 1e18; // $90,000

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bridge);
            limiter.checkAndRecordTransaction(token, amount);
        }

        // Next transaction should exceed hourly limit ($450K + $90K > $500K)
        vm.prank(bridge);
        vm.expectRevert(BridgeRateLimiter.ExceedsHourlyLimit.selector);
        limiter.checkAndRecordTransaction(token, amount);
    }

    function test_CheckAndRecordTransaction_RevertsOnDailyLimit() public {
        // Set a smaller daily limit (must be >= hourly limit)
        // maxPerTx = 50K, hourly = 100K, daily = 150K
        // Then we can do 100K worth in one hour, reset, do 60K more = 160K > 150K
        vm.prank(owner);
        limiter.setGlobalLimits(50_000 * PRECISION, 100_000 * PRECISION, 150_000 * PRECISION);

        uint256 amount = 45_000 * 1e18; // 45K per tx

        // Make 2 transactions in first hour: 90K (90% of 100K hourly, 60% of 150K daily)
        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, amount);
        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, amount);

        // Advance time to reset hourly window
        vm.warp(block.timestamp + 1 hours + 1);

        // Make 2 more transactions: 90K more (180K total daily > 150K limit)
        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, amount);

        // At 135K daily, which is 90% of 150K - still under 95% auto-pause
        // Next 45K would make it 180K which exceeds 150K daily limit
        vm.prank(bridge);
        vm.expectRevert(BridgeRateLimiter.ExceedsDailyLimit.selector);
        limiter.checkAndRecordTransaction(token, amount);
    }

    function test_CheckAndRecordTransaction_RevertsOnUnauthorized() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(BridgeRateLimiter.UnauthorizedCaller.selector);
        limiter.checkAndRecordTransaction(token, 1000);
    }

    // ============ Alert and Auto-Pause Tests ============

    function test_CheckAndRecordTransaction_TriggersAlert() public {
        // Set up to hit 80% of hourly limit
        uint256 amount = 80_000 * 1e18;

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(bridge);
            limiter.checkAndRecordTransaction(token, amount);
        }

        // Next transaction should trigger alert (320K + 80K = 400K = 80% of 500K)
        vm.prank(bridge);
        vm.expectEmit(false, false, false, true);
        emit AlertTriggered("hourly", 400_000 * PRECISION, 500_000 * PRECISION, 80);
        limiter.checkAndRecordTransaction(token, amount);
    }

    function test_CheckAndRecordTransaction_TriggersAutoPause() public {
        // Set up to hit 95% of hourly limit
        // Hourly limit is 500K, 95% = 475K
        uint256 amount = 95_000 * 1e18;

        // Make 4 transactions: 4 * 95K = 380K
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(bridge);
            limiter.checkAndRecordTransaction(token, amount);
        }

        // Verify we're at 76% (380K / 500K)
        (uint256 hourlyPct,) = limiter.getUsagePercentages();
        assertEq(hourlyPct, 76);

        // Next transaction would push us to 475K = 95%
        // But since auto-pause threshold is 95%, this should trigger AutoPauseTriggered
        // Note: The pause happens inside the function but the entire tx reverts,
        // so paused() returns false after the revert
        vm.prank(bridge);
        vm.expectRevert(BridgeRateLimiter.AutoPauseTriggered.selector);
        limiter.checkAndRecordTransaction(token, amount);

        // The paused state is NOT persisted because the transaction reverted
        // The AutoPauseTriggered error indicates the threshold was hit
        assertFalse(limiter.paused());
    }

    // ============ View Function Tests ============

    function test_CheckTransaction_View() public view {
        uint256 amount = 10_000 * 1e18;

        (bool allowed, string memory reason) = limiter.checkTransaction(token, amount);

        assertTrue(allowed);
        assertEq(reason, "");
    }

    function test_CheckTransaction_ReturnsReasonOnFailure() public view {
        uint256 amount = 150_000 * 1e18;

        (bool allowed, string memory reason) = limiter.checkTransaction(token, amount);

        assertFalse(allowed);
        assertEq(reason, "Exceeds per-transaction limit");
    }

    function test_GetRemainingCapacity() public view {
        (uint256 perTx, uint256 hourly, uint256 daily) = limiter.getRemainingCapacity();

        assertEq(perTx, 100_000 * PRECISION);
        assertEq(hourly, 500_000 * PRECISION);
        assertEq(daily, 5_000_000 * PRECISION);
    }

    function test_GetRemainingCapacity_AfterTransactions() public {
        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, 100_000 * 1e18);

        (uint256 perTx, uint256 hourly, uint256 daily) = limiter.getRemainingCapacity();

        assertEq(perTx, 100_000 * PRECISION); // Per-tx limit is always full
        assertEq(hourly, 400_000 * PRECISION);
        assertEq(daily, 4_900_000 * PRECISION);
    }

    function test_GetUsagePercentages() public {
        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, 50_000 * 1e18); // 10% hourly, 1% daily

        (uint256 hourlyPct, uint256 dailyPct) = limiter.getUsagePercentages();

        assertEq(hourlyPct, 10);
        assertEq(dailyPct, 1);
    }

    // ============ Window Reset Tests ============

    function test_WindowReset_Hourly() public {
        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, 50_000 * 1e18);

        (uint256 hourlyBefore,) = limiter.getCurrentWindowVolumes();
        assertEq(hourlyBefore, 50_000 * PRECISION);

        // Advance past hourly window
        vm.warp(block.timestamp + 1 hours + 1);

        // Make new transaction to trigger reset
        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, 10_000 * 1e18);

        (uint256 hourlyAfter,) = limiter.getCurrentWindowVolumes();
        assertEq(hourlyAfter, 10_000 * PRECISION); // Reset + new tx
    }

    function test_WindowReset_Daily() public {
        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, 50_000 * 1e18);

        (, uint256 dailyBefore) = limiter.getCurrentWindowVolumes();
        assertEq(dailyBefore, 50_000 * PRECISION);

        // Advance past daily window
        vm.warp(block.timestamp + 1 days + 1);

        // Make new transaction to trigger reset
        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, 10_000 * 1e18);

        (, uint256 dailyAfter) = limiter.getCurrentWindowVolumes();
        assertEq(dailyAfter, 10_000 * PRECISION);
    }

    // ============ Admin Functions Tests ============

    function test_SetGlobalLimits() public {
        uint256 newMaxPerTx = 200_000 * PRECISION;
        uint256 newHourly = 1_000_000 * PRECISION;
        uint256 newDaily = 10_000_000 * PRECISION;

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit LimitsUpdated(newMaxPerTx, newHourly, newDaily);
        limiter.setGlobalLimits(newMaxPerTx, newHourly, newDaily);

        BridgeRateLimiter.RateLimitConfig memory config = limiter.getGlobalLimits();
        assertEq(config.maxPerTransaction, newMaxPerTx);
        assertEq(config.hourlyLimit, newHourly);
        assertEq(config.dailyLimit, newDaily);
    }

    function test_SetGlobalLimits_RevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(BridgeRateLimiter.InvalidLimit.selector);
        limiter.setGlobalLimits(0, 100, 200);
    }

    function test_SetGlobalLimits_RevertsOnInvalidOrder() public {
        // maxPerTx > hourlyLimit
        vm.prank(owner);
        vm.expectRevert(BridgeRateLimiter.InvalidLimit.selector);
        limiter.setGlobalLimits(200, 100, 300);
    }

    function test_SetThresholds() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ThresholdsUpdated(70, 90);
        limiter.setThresholds(70, 90);

        assertEq(limiter.alertThreshold(), 70);
        assertEq(limiter.autoPauseThreshold(), 90);
    }

    function test_SetThresholds_RevertsOnInvalidOrder() public {
        // alertThreshold >= autoPauseThreshold
        vm.prank(owner);
        vm.expectRevert(BridgeRateLimiter.InvalidThreshold.selector);
        limiter.setThresholds(90, 90);
    }

    function test_SetThresholds_RevertsOnExceedingMax() public {
        vm.prank(owner);
        vm.expectRevert(BridgeRateLimiter.InvalidThreshold.selector);
        limiter.setThresholds(80, 101);
    }

    function test_ConfigureToken() public {
        address newToken = makeAddr("newToken");

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit TokenPriceUpdated(newToken, 2 * PRECISION);
        limiter.configureToken(newToken, 2 * PRECISION, 6);

        BridgeRateLimiter.TokenConfig memory config = limiter.getTokenConfig(newToken);
        assertTrue(config.supported);
        assertEq(config.price, 2 * PRECISION);
        assertEq(config.decimals, 6);
    }

    function test_ConfigureToken_NativeEth() public {
        // address(0) represents native ETH
        vm.prank(owner);
        limiter.configureToken(address(0), 2000 * PRECISION, 18);

        BridgeRateLimiter.TokenConfig memory config = limiter.getTokenConfig(address(0));
        assertTrue(config.supported);
        assertEq(config.price, 2000 * PRECISION);
    }

    function test_SetTokenLimits() public {
        vm.prank(owner);
        limiter.setTokenLimits(token, 50_000 * PRECISION, 250_000 * PRECISION, 2_500_000 * PRECISION);

        BridgeRateLimiter.TokenConfig memory config = limiter.getTokenConfig(token);
        assertTrue(config.customLimits);
    }

    function test_UpdateTokenPrice() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit TokenPriceUpdated(token, 2 * PRECISION);
        limiter.updateTokenPrice(token, 2 * PRECISION);

        BridgeRateLimiter.TokenConfig memory config = limiter.getTokenConfig(token);
        assertEq(config.price, 2 * PRECISION);
    }

    function test_SetAuthorizedCaller() public {
        address newCaller = makeAddr("newCaller");

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AuthorizedCallerUpdated(newCaller, true);
        limiter.setAuthorizedCaller(newCaller, true);

        assertTrue(limiter.isAuthorizedCaller(newCaller));
    }

    function test_ResetHourlyWindow() public {
        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, 50_000 * 1e18);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit WindowReset("hourly", block.timestamp);
        limiter.resetHourlyWindow();

        (uint256 hourlyVolume,) = limiter.getCurrentWindowVolumes();
        assertEq(hourlyVolume, 0);
    }

    function test_ResetDailyWindow() public {
        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, 50_000 * 1e18);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit WindowReset("daily", block.timestamp);
        limiter.resetDailyWindow();

        (, uint256 dailyVolume) = limiter.getCurrentWindowVolumes();
        assertEq(dailyVolume, 0);
    }

    // ============ Pause Tests ============

    function test_Pause() public {
        vm.prank(owner);
        limiter.pause();

        vm.prank(bridge);
        vm.expectRevert();
        limiter.checkAndRecordTransaction(token, 1000);
    }

    function test_Unpause() public {
        vm.prank(owner);
        limiter.pause();

        vm.prank(owner);
        limiter.unpause();

        vm.prank(bridge);
        (bool allowed,) = limiter.checkAndRecordTransaction(token, 1000 * 1e18);
        assertTrue(allowed);
    }

    // ============ USD Calculation Tests ============

    function test_CalculateUsdValue_18Decimals() public view {
        uint256 amount = 100 * 1e18; // 100 tokens
        uint256 usdValue = limiter.calculateUsdValue(token, amount);
        assertEq(usdValue, 100 * PRECISION);
    }

    function test_CalculateUsdValue_6Decimals() public {
        address usdc = makeAddr("usdc");
        vm.prank(owner);
        limiter.configureToken(usdc, 1 * PRECISION, 6); // $1 with 6 decimals

        uint256 amount = 100 * 1e6; // 100 USDC
        uint256 usdValue = limiter.calculateUsdValue(usdc, amount);
        assertEq(usdValue, 100 * PRECISION);
    }

    function test_CalculateUsdValue_WithDifferentPrice() public {
        address eth = makeAddr("eth");
        vm.prank(owner);
        limiter.configureToken(eth, 2000 * PRECISION, 18); // $2000 per ETH

        uint256 amount = 1 * 1e18; // 1 ETH
        uint256 usdValue = limiter.calculateUsdValue(eth, amount);
        assertEq(usdValue, 2000 * PRECISION);
    }

    // ============ Window Stats Tests ============

    function test_GetWindowStats() public {
        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, 10_000 * 1e18);
        vm.prank(bridge);
        limiter.checkAndRecordTransaction(token, 20_000 * 1e18);

        (uint256 hourlyTxCount, uint256 dailyTxCount, uint256 hourlyStart, uint256 dailyStart) =
            limiter.getWindowStats();

        assertEq(hourlyTxCount, 2);
        assertEq(dailyTxCount, 2);
        assertGt(hourlyStart, 0);
        assertGt(dailyStart, 0);
    }

    // ============ Owner-Only Tests ============

    function test_OnlyOwner_SetGlobalLimits() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        limiter.setGlobalLimits(100, 200, 300);
    }

    function test_OwnerCanCheckTransaction() public {
        // Owner should also be able to call checkAndRecordTransaction
        vm.prank(owner);
        (bool allowed,) = limiter.checkAndRecordTransaction(token, 1000 * 1e18);
        assertTrue(allowed);
    }
}
