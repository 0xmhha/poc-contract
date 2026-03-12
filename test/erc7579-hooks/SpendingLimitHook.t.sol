// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SpendingLimitHook } from "../../src/erc7579-hooks/SpendingLimitHook.sol";
import { MockHookAccount, MockERC20 } from "./mocks/MockHookAccount.sol";

contract SpendingLimitHookTest is Test {
    SpendingLimitHook public hook;
    MockHookAccount public account;
    MockERC20 public token;

    address public user;
    address public recipient;

    // Constants
    uint256 constant DAILY_LIMIT = 1 ether;
    uint256 constant PERIOD_DAILY = 1 days;

    function setUp() public {
        user = makeAddr("user");
        recipient = makeAddr("recipient");

        // Deploy contracts
        hook = new SpendingLimitHook();
        account = new MockHookAccount();
        token = new MockERC20("Test Token", "TEST");

        // Fund account
        vm.deal(address(account), 100 ether);
        token.mint(address(account), 1000 ether);
    }

    /* //////////////////////////////////////////////////////////////
                            INSTALLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OnInstall_NoData() public {
        vm.prank(address(account));
        hook.onInstall("");

        assertFalse(hook.isInitialized(address(account)), "Should not be initialized with no data");
    }

    function test_OnInstall_WithInitialLimits() public {
        _installHookWithEthLimit();

        assertTrue(hook.isInitialized(address(account)), "Should be initialized");

        SpendingLimitHook.SpendingLimit memory ethLimit = hook.getSpendingLimit(address(account), address(0));
        assertEq(ethLimit.limit, DAILY_LIMIT, "ETH limit should be set");
        assertEq(ethLimit.allowance, DAILY_LIMIT, "ETH allowance should equal limit");
        assertEq(ethLimit.periodLength, PERIOD_DAILY, "ETH period should be set");
        assertTrue(ethLimit.isEnabled, "ETH limit should be enabled");
    }

    function test_OnInstall_MultipleLimits() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(0); // ETH
        tokens[1] = address(token);

        uint256[] memory limits = new uint256[](2);
        limits[0] = 1 ether;
        limits[1] = 100 ether;

        uint256[] memory periods = new uint256[](2);
        periods[0] = PERIOD_DAILY;
        periods[1] = PERIOD_DAILY;

        bytes memory installData = abi.encode(tokens, limits, periods);

        vm.prank(address(account));
        hook.onInstall(installData);

        SpendingLimitHook.SpendingLimit memory tokenLimit = hook.getSpendingLimit(address(account), address(token));
        assertEq(tokenLimit.limit, 100 ether, "Token limit should be set");
        assertEq(tokenLimit.allowance, 100 ether, "Token allowance should equal limit");
    }

    function test_OnUninstall() public {
        _installHookWithEthLimit();

        vm.prank(address(account));
        hook.onUninstall("");

        assertFalse(hook.isInitialized(address(account)), "Should not be initialized after uninstall");
    }

    function test_IsModuleType() public view {
        assertTrue(hook.isModuleType(4), "Should be MODULE_TYPE_HOOK (4)");
        assertFalse(hook.isModuleType(1), "Should not be validator");
        assertFalse(hook.isModuleType(2), "Should not be executor");
    }

    /* //////////////////////////////////////////////////////////////
                        SPENDING LIMIT MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_SetSpendingLimit() public {
        vm.prank(address(account));
        hook.setSpendingLimit(address(0), DAILY_LIMIT, PERIOD_DAILY);

        SpendingLimitHook.SpendingLimit memory limit = hook.getSpendingLimit(address(account), address(0));
        assertEq(limit.limit, DAILY_LIMIT);
        assertEq(limit.allowance, DAILY_LIMIT);
        assertEq(limit.periodLength, PERIOD_DAILY);
        assertTrue(limit.isEnabled);
    }

    function test_SetSpendingLimit_LifetimeLimit() public {
        // periodLength = 0 means lifetime limit (no reset)
        vm.prank(address(account));
        hook.setSpendingLimit(address(0), DAILY_LIMIT, 0);

        SpendingLimitHook.SpendingLimit memory limit = hook.getSpendingLimit(address(account), address(0));
        assertEq(limit.limit, DAILY_LIMIT);
        assertEq(limit.periodLength, 0, "Lifetime limit has period 0");
        assertTrue(limit.isEnabled);
    }

    function test_SetSpendingLimit_RevertInvalidLimit() public {
        vm.prank(address(account));
        vm.expectRevert(SpendingLimitHook.InvalidLimit.selector);
        hook.setSpendingLimit(address(0), 0, PERIOD_DAILY);
    }

    function test_RemoveSpendingLimit() public {
        _installHookWithEthLimit();

        vm.prank(address(account));
        hook.removeSpendingLimit(address(0));

        SpendingLimitHook.SpendingLimit memory limit = hook.getSpendingLimit(address(account), address(0));
        assertFalse(limit.isEnabled);
    }

    function test_RemoveSpendingLimit_RevertNotConfigured() public {
        vm.prank(address(account));
        vm.expectRevert(SpendingLimitHook.LimitNotConfigured.selector);
        hook.removeSpendingLimit(address(0));
    }

    function test_GetConfiguredTokens() public {
        vm.startPrank(address(account));
        hook.setSpendingLimit(address(0), DAILY_LIMIT, PERIOD_DAILY);
        hook.setSpendingLimit(address(token), 100 ether, PERIOD_DAILY);
        vm.stopPrank();

        address[] memory tokens = hook.getConfiguredTokens(address(account));
        assertEq(tokens.length, 2);
    }

    /* //////////////////////////////////////////////////////////////
                            PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause() public {
        vm.prank(address(account));
        hook.pause();

        assertTrue(hook.isPaused(address(account)));
    }

    function test_Unpause() public {
        vm.startPrank(address(account));
        hook.pause();
        hook.unpause();
        vm.stopPrank();

        assertFalse(hook.isPaused(address(account)));
    }

    function test_PreCheck_RevertWhenPaused() public {
        _installHookViaAccount();

        vm.prank(address(account));
        hook.pause();

        // executeWithHookAndCall triggers preCheck which should revert
        vm.expectRevert(SpendingLimitHook.AccountIsPaused.selector);
        account.executeWithHookAndCall(recipient, 0.1 ether, "");
    }

    /* //////////////////////////////////////////////////////////////
                    BALANCE-BASED SPENDING ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_ETH_UnderLimit() public {
        _installHookViaAccount();

        // Transfer 0.5 ETH (under 1 ETH limit)
        account.executeWithHookAndCall(recipient, 0.5 ether, "");

        uint256 remaining = hook.getRemainingAllowance(address(account), address(0));
        assertEq(remaining, 0.5 ether, "Should have 0.5 ETH remaining");
    }

    function test_ETH_AtLimit() public {
        _installHookViaAccount();

        // Transfer exactly 1 ETH (at limit)
        account.executeWithHookAndCall(recipient, DAILY_LIMIT, "");

        uint256 remaining = hook.getRemainingAllowance(address(account), address(0));
        assertEq(remaining, 0, "Should have 0 remaining after spending full limit");
    }

    function test_ETH_ExceedsLimit() public {
        _installHookViaAccount();

        // Transfer 1.5 ETH (over 1 ETH limit) — should revert in postCheck
        vm.expectRevert(
            abi.encodeWithSelector(SpendingLimitHook.SpendingLimitExceeded.selector, address(0), 1.5 ether, DAILY_LIMIT)
        );
        account.executeWithHookAndCall(recipient, 1.5 ether, "");
    }

    function test_ETH_CumulativeSpending() public {
        _installHookViaAccount();

        // First: 0.6 ETH
        account.executeWithHookAndCall(recipient, 0.6 ether, "");
        assertEq(hook.getRemainingAllowance(address(account), address(0)), 0.4 ether);

        // Second: 0.5 ETH — exceeds remaining 0.4 ETH
        vm.expectRevert(
            abi.encodeWithSelector(SpendingLimitHook.SpendingLimitExceeded.selector, address(0), 0.5 ether, 0.4 ether)
        );
        account.executeWithHookAndCall(recipient, 0.5 ether, "");
    }

    function test_ERC20_UnderLimit() public {
        _installHookViaAccountWithToken();

        // Transfer 50 tokens (under 100 token limit)
        bytes memory transferCall = abi.encodeWithSelector(token.transfer.selector, recipient, 50 ether);
        account.executeWithHookAndCall(address(token), 0, transferCall);

        uint256 remaining = hook.getRemainingAllowance(address(account), address(token));
        assertEq(remaining, 50 ether, "Should have 50 tokens remaining");
    }

    function test_ERC20_ExceedsLimit() public {
        _installHookViaAccountWithToken();

        // Transfer 150 tokens (over 100 token limit)
        bytes memory transferCall = abi.encodeWithSelector(token.transfer.selector, recipient, 150 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitHook.SpendingLimitExceeded.selector, address(token), 150 ether, 100 ether
            )
        );
        account.executeWithHookAndCall(address(token), 0, transferCall);
    }

    function test_BalanceIncrease_SkipsCheck() public {
        _installHookViaAccountWithToken();

        // Mint tokens TO the account — balance increases, should not affect limits
        bytes memory mintCall = abi.encodeWithSelector(token.mint.selector, address(account), 100 ether);
        account.executeWithHookAndCall(address(token), 0, mintCall);

        // Allowance should be unchanged
        uint256 remaining = hook.getRemainingAllowance(address(account), address(token));
        assertEq(remaining, 100 ether, "Receiving tokens should not consume allowance");
    }

    /* //////////////////////////////////////////////////////////////
                            PERIOD RESET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PeriodAutoReset() public {
        _installHookViaAccount();

        // Spend full limit
        account.executeWithHookAndCall(recipient, DAILY_LIMIT, "");
        assertEq(hook.getRemainingAllowance(address(account), address(0)), 0);

        // Fast forward past the period
        vm.warp(block.timestamp + PERIOD_DAILY + 1);

        // Remaining should be full limit again (auto-reset on read)
        assertEq(hook.getRemainingAllowance(address(account), address(0)), DAILY_LIMIT);
    }

    function test_PeriodAutoReset_AllowsSpendingAgain() public {
        _installHookViaAccount();

        // Spend full limit
        account.executeWithHookAndCall(recipient, DAILY_LIMIT, "");

        // Fast forward past period
        vm.warp(block.timestamp + PERIOD_DAILY + 1);

        // Should be able to spend again
        account.executeWithHookAndCall(recipient, 0.5 ether, "");
        assertEq(hook.getRemainingAllowance(address(account), address(0)), 0.5 ether);
    }

    function test_ManualPeriodReset() public {
        _installHookViaAccount();

        // Spend some
        account.executeWithHookAndCall(recipient, 0.5 ether, "");

        // Manual reset
        vm.prank(address(account));
        hook.resetPeriod(address(0));

        assertEq(hook.getRemainingAllowance(address(account), address(0)), DAILY_LIMIT);
    }

    function test_GetTimeUntilReset() public {
        _installHookWithEthLimit();

        uint256 timeUntilReset = hook.getTimeUntilReset(address(account), address(0));
        assertEq(timeUntilReset, PERIOD_DAILY);

        // Fast forward half the period
        vm.warp(block.timestamp + PERIOD_DAILY / 2);

        timeUntilReset = hook.getTimeUntilReset(address(account), address(0));
        assertEq(timeUntilReset, PERIOD_DAILY / 2);
    }

    function test_GetTimeUntilReset_AfterPeriodExpired() public {
        _installHookWithEthLimit();

        vm.warp(block.timestamp + PERIOD_DAILY + 1);

        uint256 timeUntilReset = hook.getTimeUntilReset(address(account), address(0));
        assertEq(timeUntilReset, 0);
    }

    function test_LifetimeLimit_NoReset() public {
        // Install with periodLength = 0 (lifetime)
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256[] memory limits = new uint256[](1);
        limits[0] = DAILY_LIMIT;
        uint256[] memory periods = new uint256[](1);
        periods[0] = 0; // lifetime

        account.installHook(address(hook), abi.encode(tokens, limits, periods));

        // Spend some
        account.executeWithHookAndCall(recipient, 0.5 ether, "");
        assertEq(hook.getRemainingAllowance(address(account), address(0)), 0.5 ether);

        // Even after time passes, allowance should NOT reset
        vm.warp(block.timestamp + 365 days);
        assertEq(hook.getRemainingAllowance(address(account), address(0)), 0.5 ether);
    }

    /* //////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_GetRemainingAllowance_NoLimit() public view {
        uint256 remaining = hook.getRemainingAllowance(address(account), address(0));
        assertEq(remaining, type(uint256).max);
    }

    function test_GetRemainingAllowance_WithLimit() public {
        _installHookWithEthLimit();

        uint256 remaining = hook.getRemainingAllowance(address(account), address(0));
        assertEq(remaining, DAILY_LIMIT);
    }

    /* //////////////////////////////////////////////////////////////
                        POST CHECK EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_PostCheck_NoConfiguredTokens() public {
        // Install hook with no limits
        account.installHook(address(hook), "");

        // Should not revert — no tokens to check
        vm.prank(address(account));
        hook.postCheck(abi.encode(new uint256[](0)));
    }

    /* //////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _installHookWithEthLimit() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        uint256[] memory limits = new uint256[](1);
        limits[0] = DAILY_LIMIT;

        uint256[] memory periods = new uint256[](1);
        periods[0] = PERIOD_DAILY;

        bytes memory installData = abi.encode(tokens, limits, periods);

        vm.prank(address(account));
        hook.onInstall(installData);
    }

    /// @dev Installs hook via account (sets account.hook reference for executeWithHookAndCall)
    function _installHookViaAccount() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        uint256[] memory limits = new uint256[](1);
        limits[0] = DAILY_LIMIT;

        uint256[] memory periods = new uint256[](1);
        periods[0] = PERIOD_DAILY;

        account.installHook(address(hook), abi.encode(tokens, limits, periods));
    }

    /// @dev Installs hook via account with ERC20 token limit
    function _installHookViaAccountWithToken() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);

        uint256[] memory limits = new uint256[](1);
        limits[0] = 100 ether;

        uint256[] memory periods = new uint256[](1);
        periods[0] = PERIOD_DAILY;

        account.installHook(address(hook), abi.encode(tokens, limits, periods));
    }
}
