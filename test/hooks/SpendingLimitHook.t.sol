// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpendingLimitHook} from "../../src/erc7579-hooks/SpendingLimitHook.sol";
import {MockHookAccount, MockERC20} from "./mocks/MockHookAccount.sol";

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

    /*//////////////////////////////////////////////////////////////
                            INSTALLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OnInstall_NoData() public {
        vm.prank(address(account));
        hook.onInstall("");

        assertFalse(hook.isInitialized(address(account)), "Should not be initialized with no data");
    }

    function test_OnInstall_WithInitialLimits() public {
        // Prepare initial configuration
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

        assertTrue(hook.isInitialized(address(account)), "Should be initialized");

        // Check ETH limit
        SpendingLimitHook.SpendingLimit memory ethLimit = hook.getSpendingLimit(address(account), address(0));
        assertEq(ethLimit.limit, 1 ether, "ETH limit should be set");
        assertEq(ethLimit.periodLength, PERIOD_DAILY, "ETH period should be set");
        assertTrue(ethLimit.isEnabled, "ETH limit should be enabled");

        // Check token limit
        SpendingLimitHook.SpendingLimit memory tokenLimit = hook.getSpendingLimit(address(account), address(token));
        assertEq(tokenLimit.limit, 100 ether, "Token limit should be set");
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

    /*//////////////////////////////////////////////////////////////
                        SPENDING LIMIT MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_SetSpendingLimit() public {
        vm.prank(address(account));
        hook.setSpendingLimit(address(0), DAILY_LIMIT, PERIOD_DAILY);

        SpendingLimitHook.SpendingLimit memory limit = hook.getSpendingLimit(address(account), address(0));
        assertEq(limit.limit, DAILY_LIMIT);
        assertEq(limit.periodLength, PERIOD_DAILY);
        assertTrue(limit.isEnabled);
    }

    function test_SetSpendingLimit_RevertInvalidLimit() public {
        vm.prank(address(account));
        vm.expectRevert(SpendingLimitHook.InvalidLimit.selector);
        hook.setSpendingLimit(address(0), 0, PERIOD_DAILY);
    }

    function test_SetSpendingLimit_RevertInvalidPeriod() public {
        vm.prank(address(account));
        vm.expectRevert(SpendingLimitHook.InvalidPeriod.selector);
        hook.setSpendingLimit(address(0), DAILY_LIMIT, 0);
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
        // Set up multiple limits
        vm.startPrank(address(account));
        hook.setSpendingLimit(address(0), DAILY_LIMIT, PERIOD_DAILY);
        hook.setSpendingLimit(address(token), 100 ether, PERIOD_DAILY);
        vm.stopPrank();

        address[] memory tokens = hook.getConfiguredTokens(address(account));
        assertEq(tokens.length, 2);
    }

    /*//////////////////////////////////////////////////////////////
                            WHITELIST TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetWhitelist() public {
        vm.prank(address(account));
        hook.setWhitelist(recipient, true);

        assertTrue(hook.isWhitelisted(address(account), recipient));
    }

    function test_Whitelist_BypassesLimits() public {
        _installHookWithEthLimit();

        // Whitelist recipient
        vm.prank(address(account));
        hook.setWhitelist(recipient, true);

        // Build transaction data exceeding limit
        bytes memory msgData = abi.encodePacked(recipient, uint256(10 ether), "");

        // Should not revert even though it exceeds limit
        vm.prank(address(account));
        hook.preCheck(user, 10 ether, msgData);
    }

    /*//////////////////////////////////////////////////////////////
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
        _installHookWithEthLimit();

        vm.prank(address(account));
        hook.pause();

        bytes memory msgData = abi.encodePacked(recipient, uint256(0.1 ether), "");

        vm.prank(address(account));
        vm.expectRevert(SpendingLimitHook.AccountIsPaused.selector);
        hook.preCheck(user, 0.1 ether, msgData);
    }

    /*//////////////////////////////////////////////////////////////
                        SPENDING LIMIT ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_PreCheck_ETH_UnderLimit() public {
        _installHookWithEthLimit();

        bytes memory msgData = abi.encodePacked(recipient, uint256(0.5 ether), "");

        vm.prank(address(account));
        bytes memory hookData = hook.preCheck(user, 0.5 ether, msgData);

        // Should pass without revert
        (address returnedToken, uint256 returnedAmount) = abi.decode(hookData, (address, uint256));
        assertEq(returnedToken, address(0));
        assertEq(returnedAmount, 0.5 ether);
    }

    function test_PreCheck_ETH_AtLimit() public {
        _installHookWithEthLimit();

        bytes memory msgData = abi.encodePacked(recipient, uint256(DAILY_LIMIT), "");

        vm.prank(address(account));
        hook.preCheck(user, DAILY_LIMIT, msgData);

        // Verify spending was recorded
        uint256 remaining = hook.getRemainingAllowance(address(account), address(0));
        assertEq(remaining, 0);
    }

    function test_PreCheck_ETH_ExceedsLimit() public {
        _installHookWithEthLimit();

        bytes memory msgData = abi.encodePacked(recipient, uint256(1.5 ether), "");

        vm.prank(address(account));
        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitHook.SpendingLimitExceeded.selector,
                address(0),
                1.5 ether,
                DAILY_LIMIT
            )
        );
        hook.preCheck(user, 1.5 ether, msgData);
    }

    function test_PreCheck_CumulativeSpending() public {
        _installHookWithEthLimit();

        // First transaction: 0.6 ETH
        bytes memory msgData1 = abi.encodePacked(recipient, uint256(0.6 ether), "");
        vm.prank(address(account));
        hook.preCheck(user, 0.6 ether, msgData1);

        // Check remaining
        uint256 remaining = hook.getRemainingAllowance(address(account), address(0));
        assertEq(remaining, 0.4 ether);

        // Second transaction: 0.5 ETH - should fail
        bytes memory msgData2 = abi.encodePacked(recipient, uint256(0.5 ether), "");
        vm.prank(address(account));
        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitHook.SpendingLimitExceeded.selector,
                address(0),
                0.5 ether,
                0.4 ether
            )
        );
        hook.preCheck(user, 0.5 ether, msgData2);
    }

    function test_PreCheck_ERC20Transfer() public {
        _installHookWithTokenLimit();

        // Build ERC20 transfer calldata
        bytes memory transferCall = abi.encodeWithSelector(
            bytes4(keccak256("transfer(address,uint256)")),
            recipient,
            50 ether
        );

        // msgData format: target (20) + value (32) + callData
        bytes memory msgData = abi.encodePacked(address(token), uint256(0), transferCall);

        vm.prank(address(account));
        hook.preCheck(user, 0, msgData);

        uint256 remaining = hook.getRemainingAllowance(address(account), address(token));
        assertEq(remaining, 50 ether);
    }

    function test_PreCheck_ERC20Transfer_ExceedsLimit() public {
        _installHookWithTokenLimit();

        // Build ERC20 transfer calldata exceeding limit
        bytes memory transferCall = abi.encodeWithSelector(
            bytes4(keccak256("transfer(address,uint256)")),
            recipient,
            150 ether
        );

        bytes memory msgData = abi.encodePacked(address(token), uint256(0), transferCall);

        vm.prank(address(account));
        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitHook.SpendingLimitExceeded.selector,
                address(token),
                150 ether,
                100 ether
            )
        );
        hook.preCheck(user, 0, msgData);
    }

    /*//////////////////////////////////////////////////////////////
                            PERIOD RESET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PeriodAutoReset() public {
        _installHookWithEthLimit();

        // Spend full limit
        bytes memory msgData = abi.encodePacked(recipient, uint256(DAILY_LIMIT), "");
        vm.prank(address(account));
        hook.preCheck(user, DAILY_LIMIT, msgData);

        // Remaining should be 0
        assertEq(hook.getRemainingAllowance(address(account), address(0)), 0);

        // Fast forward past the period
        vm.warp(block.timestamp + PERIOD_DAILY + 1);

        // Remaining should be full limit again
        assertEq(hook.getRemainingAllowance(address(account), address(0)), DAILY_LIMIT);
    }

    function test_ManualPeriodReset() public {
        _installHookWithEthLimit();

        // Spend some
        bytes memory msgData = abi.encodePacked(recipient, uint256(0.5 ether), "");
        vm.prank(address(account));
        hook.preCheck(user, 0.5 ether, msgData);

        // Manual reset
        vm.prank(address(account));
        hook.resetPeriod(address(0));

        // Remaining should be full limit
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

    /*//////////////////////////////////////////////////////////////
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

    /*//////////////////////////////////////////////////////////////
                            POST CHECK TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PostCheck_DoesNotRevert() public {
        vm.prank(address(account));
        hook.postCheck(""); // Should not revert
    }

    /*//////////////////////////////////////////////////////////////
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

    function _installHookWithTokenLimit() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);

        uint256[] memory limits = new uint256[](1);
        limits[0] = 100 ether;

        uint256[] memory periods = new uint256[](1);
        periods[0] = PERIOD_DAILY;

        bytes memory installData = abi.encode(tokens, limits, periods);

        vm.prank(address(account));
        hook.onInstall(installData);
    }
}
