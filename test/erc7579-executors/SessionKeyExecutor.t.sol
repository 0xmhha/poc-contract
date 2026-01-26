// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SessionKeyExecutor } from "../../src/erc7579-executors/SessionKeyExecutor.sol";
import { MockSmartAccount } from "./mocks/MockSmartAccount.sol";
import { MockERC20 } from "../erc4337-paymaster/mocks/MockERC20.sol";
import { MODULE_TYPE_EXECUTOR } from "../../src/erc7579-smartaccount/types/Constants.sol";

contract SessionKeyExecutorTest is Test {
    SessionKeyExecutor public executor;
    MockSmartAccount public smartAccount;
    MockERC20 public token;

    address public owner;
    address public sessionKey;
    uint256 public sessionKeyPrivateKey;
    address public recipient;

    uint48 constant VALID_AFTER = 0;
    uint48 constant VALID_UNTIL = type(uint48).max;
    uint256 constant SPENDING_LIMIT = 10 ether;

    function setUp() public {
        owner = makeAddr("owner");
        sessionKeyPrivateKey = 0xB_EEF;
        sessionKey = vm.addr(sessionKeyPrivateKey);
        recipient = makeAddr("recipient");

        // Deploy contracts
        executor = new SessionKeyExecutor();
        smartAccount = new MockSmartAccount(owner);
        token = new MockERC20("Test Token", "TEST", 18);

        // Fund smart account
        vm.deal(address(smartAccount), 100 ether);
        token.mint(address(smartAccount), 1_000_000e18);

        // Install executor
        vm.prank(address(smartAccount));
        smartAccount.installModule(MODULE_TYPE_EXECUTOR, address(executor), "");
    }

    function test_onInstall_withData() public {
        SessionKeyExecutor newExecutor = new SessionKeyExecutor();
        MockSmartAccount newAccount = new MockSmartAccount(owner);

        // Prepare permissions
        SessionKeyExecutor.Permission[] memory perms = new SessionKeyExecutor.Permission[](1);
        perms[0] =
            SessionKeyExecutor.Permission({ target: address(token), selector: bytes4(0), maxValue: 0, allowed: true });

        bytes memory permData = abi.encode(perms);
        bytes memory installData = abi.encode(sessionKey, VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT, permData);

        vm.prank(address(newAccount));
        newAccount.installModule(MODULE_TYPE_EXECUTOR, address(newExecutor), installData);

        // Verify session key was added
        SessionKeyExecutor.SessionKeyConfig memory config = newExecutor.getSessionKey(address(newAccount), sessionKey);
        assertTrue(config.isActive);
        assertEq(config.sessionKey, sessionKey);
        assertEq(config.spendingLimit, SPENDING_LIMIT);
    }

    function test_addSessionKey() public {
        vm.prank(address(smartAccount));
        executor.addSessionKey(sessionKey, VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT);

        SessionKeyExecutor.SessionKeyConfig memory config = executor.getSessionKey(address(smartAccount), sessionKey);
        assertTrue(config.isActive);
        assertEq(config.sessionKey, sessionKey);
        assertEq(config.validAfter, VALID_AFTER);
        assertEq(config.validUntil, VALID_UNTIL);
        assertEq(config.spendingLimit, SPENDING_LIMIT);
    }

    function test_addSessionKey_revertIfZeroAddress() public {
        vm.prank(address(smartAccount));
        vm.expectRevert(SessionKeyExecutor.InvalidSessionKey.selector);
        executor.addSessionKey(address(0), VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT);
    }

    function test_addSessionKey_revertIfAlreadyExists() public {
        vm.startPrank(address(smartAccount));
        executor.addSessionKey(sessionKey, VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT);

        vm.expectRevert(SessionKeyExecutor.SessionKeyAlreadyExists.selector);
        executor.addSessionKey(sessionKey, VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT);
        vm.stopPrank();
    }

    function test_revokeSessionKey() public {
        vm.startPrank(address(smartAccount));
        executor.addSessionKey(sessionKey, VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT);
        executor.revokeSessionKey(sessionKey);
        vm.stopPrank();

        SessionKeyExecutor.SessionKeyConfig memory config = executor.getSessionKey(address(smartAccount), sessionKey);
        assertFalse(config.isActive);
    }

    function test_revokeSessionKey_revertIfNotActive() public {
        vm.prank(address(smartAccount));
        vm.expectRevert(SessionKeyExecutor.SessionKeyNotActive.selector);
        executor.revokeSessionKey(sessionKey);
    }

    function test_grantPermission() public {
        vm.startPrank(address(smartAccount));
        executor.addSessionKey(sessionKey, VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT);
        executor.grantPermission(sessionKey, address(token), bytes4(0), 0);
        vm.stopPrank();

        assertTrue(executor.hasPermission(address(smartAccount), sessionKey, address(token), bytes4(0)));
    }

    function test_revokePermission() public {
        vm.startPrank(address(smartAccount));
        executor.addSessionKey(sessionKey, VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT);
        executor.grantPermission(sessionKey, address(token), bytes4(0), 0);
        executor.revokePermission(sessionKey, address(token), bytes4(0));
        vm.stopPrank();

        assertFalse(executor.hasPermission(address(smartAccount), sessionKey, address(token), bytes4(0)));
    }

    function test_executeAsSessionKey() public {
        // Setup session key with permission
        vm.startPrank(address(smartAccount));
        executor.addSessionKey(sessionKey, VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT);
        executor.grantPermission(sessionKey, recipient, bytes4(0), 1 ether);
        vm.stopPrank();

        uint256 balanceBefore = recipient.balance;

        // Execute as session key
        vm.prank(sessionKey);
        executor.executeAsSessionKey(address(smartAccount), recipient, 0.5 ether, "");

        assertEq(recipient.balance, balanceBefore + 0.5 ether);
    }

    function test_executeAsSessionKey_revertIfNotActive() public {
        vm.prank(sessionKey);
        vm.expectRevert(SessionKeyExecutor.SessionKeyNotActive.selector);
        executor.executeAsSessionKey(address(smartAccount), recipient, 1 ether, "");
    }

    function test_executeAsSessionKey_revertIfExpired() public {
        vm.startPrank(address(smartAccount));
        executor.addSessionKey(sessionKey, uint48(block.timestamp), uint48(block.timestamp + 1 hours), SPENDING_LIMIT);
        executor.grantPermission(sessionKey, recipient, bytes4(0), 1 ether);
        vm.stopPrank();

        // Warp past expiration
        vm.warp(block.timestamp + 2 hours);

        vm.prank(sessionKey);
        vm.expectRevert(SessionKeyExecutor.SessionKeyExpired.selector);
        executor.executeAsSessionKey(address(smartAccount), recipient, 0.5 ether, "");
    }

    function test_executeAsSessionKey_revertIfNotYetValid() public {
        vm.startPrank(address(smartAccount));
        executor.addSessionKey(sessionKey, uint48(block.timestamp + 1 hours), VALID_UNTIL, SPENDING_LIMIT);
        executor.grantPermission(sessionKey, recipient, bytes4(0), 1 ether);
        vm.stopPrank();

        vm.prank(sessionKey);
        vm.expectRevert(SessionKeyExecutor.SessionKeyNotYetValid.selector);
        executor.executeAsSessionKey(address(smartAccount), recipient, 0.5 ether, "");
    }

    function test_executeAsSessionKey_revertIfNoPermission() public {
        vm.prank(address(smartAccount));
        executor.addSessionKey(sessionKey, VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT);

        vm.prank(sessionKey);
        vm.expectRevert(SessionKeyExecutor.PermissionDenied.selector);
        executor.executeAsSessionKey(address(smartAccount), recipient, 0.5 ether, "");
    }

    function test_executeAsSessionKey_revertIfSpendingLimitExceeded() public {
        vm.startPrank(address(smartAccount));
        executor.addSessionKey(sessionKey, VALID_AFTER, VALID_UNTIL, 1 ether);
        executor.grantPermission(sessionKey, recipient, bytes4(0), 0);
        vm.stopPrank();

        vm.prank(sessionKey);
        vm.expectRevert(SessionKeyExecutor.SpendingLimitExceeded.selector);
        executor.executeAsSessionKey(address(smartAccount), recipient, 2 ether, "");
    }

    function test_getRemainingSpendingLimit() public {
        vm.startPrank(address(smartAccount));
        executor.addSessionKey(sessionKey, VALID_AFTER, VALID_UNTIL, 10 ether);
        executor.grantPermission(sessionKey, recipient, bytes4(0), 0);
        vm.stopPrank();

        assertEq(executor.getRemainingSpendingLimit(address(smartAccount), sessionKey), 10 ether);

        vm.prank(sessionKey);
        executor.executeAsSessionKey(address(smartAccount), recipient, 3 ether, "");

        assertEq(executor.getRemainingSpendingLimit(address(smartAccount), sessionKey), 7 ether);
    }

    function test_getActiveSessionKeys() public {
        address sessionKey2 = makeAddr("sessionKey2");

        vm.startPrank(address(smartAccount));
        executor.addSessionKey(sessionKey, VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT);
        executor.addSessionKey(sessionKey2, VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT);
        vm.stopPrank();

        address[] memory keys = executor.getActiveSessionKeys(address(smartAccount));
        assertEq(keys.length, 2);
        assertEq(keys[0], sessionKey);
        assertEq(keys[1], sessionKey2);
    }

    function test_isModuleType() public view {
        assertTrue(executor.isModuleType(MODULE_TYPE_EXECUTOR));
        assertFalse(executor.isModuleType(1)); // VALIDATOR type
    }

    function test_isInitialized() public {
        assertFalse(executor.isInitialized(address(smartAccount)));

        vm.prank(address(smartAccount));
        executor.addSessionKey(sessionKey, VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT);

        assertTrue(executor.isInitialized(address(smartAccount)));
    }

    function test_onUninstall() public {
        vm.startPrank(address(smartAccount));
        executor.addSessionKey(sessionKey, VALID_AFTER, VALID_UNTIL, SPENDING_LIMIT);
        executor.onUninstall("");
        vm.stopPrank();

        assertFalse(executor.isInitialized(address(smartAccount)));
    }
}
