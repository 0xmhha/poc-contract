// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { AuditHook } from "../../src/erc7579-hooks/AuditHook.sol";
import { MockHookAccount } from "./mocks/MockHookAccount.sol";

contract AuditHookTest is Test {
    AuditHook public hook;
    MockHookAccount public account;

    address public user;
    address public recipient;
    address public blockedAddress;

    // Constants
    uint256 constant HIGH_VALUE_THRESHOLD = 1 ether;
    uint256 constant FLAGGED_DELAY = 1 hours;

    function setUp() public {
        user = makeAddr("user");
        recipient = makeAddr("recipient");
        blockedAddress = makeAddr("blocked");

        // Deploy contracts
        hook = new AuditHook();
        account = new MockHookAccount();

        // Fund account
        vm.deal(address(account), 100 ether);
    }

    /* //////////////////////////////////////////////////////////////
                            INSTALLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OnInstall_NoData() public {
        vm.prank(address(account));
        hook.onInstall("");

        assertTrue(hook.isInitialized(address(account)), "Should be initialized");

        AuditHook.AccountConfig memory config = hook.getConfig(address(account));
        assertEq(config.highValueThreshold, 1 ether, "Default threshold");
        assertEq(config.flaggedDelay, 0, "Default no delay");
        assertTrue(config.isEnabled, "Should be enabled");
    }

    function test_OnInstall_WithConfig() public {
        bytes memory installData = abi.encode(5 ether, 2 hours);

        vm.prank(address(account));
        hook.onInstall(installData);

        AuditHook.AccountConfig memory config = hook.getConfig(address(account));
        assertEq(config.highValueThreshold, 5 ether);
        assertEq(config.flaggedDelay, 2 hours);
    }

    function test_OnUninstall() public {
        _installHook();

        vm.prank(address(account));
        hook.onUninstall("");

        assertFalse(hook.isInitialized(address(account)));
    }

    function test_IsModuleType() public view {
        assertTrue(hook.isModuleType(4), "Should be MODULE_TYPE_HOOK (4)");
        assertFalse(hook.isModuleType(1), "Should not be validator");
        assertFalse(hook.isModuleType(2), "Should not be executor");
    }

    /* //////////////////////////////////////////////////////////////
                        CONFIGURATION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_SetConfig() public {
        _installHook();

        vm.prank(address(account));
        hook.setConfig(10 ether, 3 hours);

        AuditHook.AccountConfig memory config = hook.getConfig(address(account));
        assertEq(config.highValueThreshold, 10 ether);
        assertEq(config.flaggedDelay, 3 hours);
    }

    function test_SetConfig_RevertInvalidThreshold() public {
        _installHook();

        vm.prank(address(account));
        vm.expectRevert(AuditHook.InvalidThreshold.selector);
        hook.setConfig(0, 1 hours);
    }

    /* //////////////////////////////////////////////////////////////
                            BLOCKLIST TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetBlocklist() public {
        _installHook();

        vm.prank(address(account));
        hook.setBlocklist(blockedAddress, true);

        assertTrue(hook.isBlocked(address(account), blockedAddress));
    }

    function test_SetBlocklistBatch() public {
        _installHook();

        address[] memory targets = new address[](2);
        targets[0] = makeAddr("blocked1");
        targets[1] = makeAddr("blocked2");

        bool[] memory isBlocked = new bool[](2);
        isBlocked[0] = true;
        isBlocked[1] = true;

        vm.prank(address(account));
        hook.setBlocklistBatch(targets, isBlocked);

        assertTrue(hook.isBlocked(address(account), targets[0]));
        assertTrue(hook.isBlocked(address(account), targets[1]));
    }

    function test_PreCheck_RevertBlockedAddress() public {
        _installHook();

        vm.prank(address(account));
        hook.setBlocklist(blockedAddress, true);

        bytes memory msgData = abi.encodePacked(blockedAddress, uint256(0.1 ether), "");

        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(AuditHook.AddressBlocked.selector, blockedAddress));
        hook.preCheck(user, 0.1 ether, msgData);
    }

    /* //////////////////////////////////////////////////////////////
                            AUDIT LOG TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PreCheck_CreatesAuditEntry() public {
        _installHook();

        bytes memory msgData = abi.encodePacked(recipient, uint256(0.5 ether), bytes4(0x12_345_678), bytes28(0));

        vm.prank(address(account));
        bytes memory hookData = hook.preCheck(user, 0.5 ether, msgData);

        uint256 logIndex = abi.decode(hookData, (uint256));
        assertEq(logIndex, 0);

        AuditHook.AuditEntry memory entry = hook.getAuditEntry(address(account), 0);
        assertEq(entry.timestamp, block.timestamp);
        assertEq(entry.sender, user);
        assertEq(entry.target, recipient);
        assertEq(entry.value, 0.5 ether);
        assertFalse(entry.isFlagged);
        assertFalse(entry.isExecuted);
    }

    function test_PreCheck_FlagsHighValue() public {
        _installHook();

        bytes memory msgData = abi.encodePacked(recipient, uint256(2 ether), "");

        vm.prank(address(account));
        hook.preCheck(user, 2 ether, msgData);

        AuditHook.AuditEntry memory entry = hook.getAuditEntry(address(account), 0);
        assertTrue(entry.isFlagged);
    }

    function test_PostCheck_MarksExecuted() public {
        _installHook();

        bytes memory msgData = abi.encodePacked(recipient, uint256(0.5 ether), "");

        vm.prank(address(account));
        bytes memory hookData = hook.preCheck(user, 0.5 ether, msgData);

        vm.prank(address(account));
        hook.postCheck(hookData);

        AuditHook.AuditEntry memory entry = hook.getAuditEntry(address(account), 0);
        assertTrue(entry.isExecuted);
    }

    function test_GetAuditLogLength() public {
        _installHook();

        assertEq(hook.getAuditLogLength(address(account)), 0);

        // Create 3 audit entries
        bytes memory msgData = abi.encodePacked(recipient, uint256(0.1 ether), "");

        vm.startPrank(address(account));
        hook.preCheck(user, 0.1 ether, msgData);
        hook.preCheck(user, 0.2 ether, msgData);
        hook.preCheck(user, 0.3 ether, msgData);
        vm.stopPrank();

        assertEq(hook.getAuditLogLength(address(account)), 3);
    }

    function test_GetAuditEntries() public {
        _installHook();

        vm.startPrank(address(account));
        hook.preCheck(user, 0, abi.encodePacked(recipient, uint256(0.1 ether), ""));
        hook.preCheck(user, 0, abi.encodePacked(recipient, uint256(0.2 ether), ""));
        hook.preCheck(user, 0, abi.encodePacked(recipient, uint256(0.3 ether), ""));
        hook.preCheck(user, 0, abi.encodePacked(recipient, uint256(0.4 ether), ""));
        hook.preCheck(user, 0, abi.encodePacked(recipient, uint256(0.5 ether), ""));
        vm.stopPrank();

        // Get entries 1-3
        AuditHook.AuditEntry[] memory entries = hook.getAuditEntries(address(account), 1, 4);
        assertEq(entries.length, 3);
        assertEq(entries[0].value, 0.2 ether);
        assertEq(entries[1].value, 0.3 ether);
        assertEq(entries[2].value, 0.4 ether);
    }

    function test_GetAuditEntries_OutOfBounds() public {
        _installHook();

        AuditHook.AuditEntry[] memory entries = hook.getAuditEntries(address(account), 10, 20);
        assertEq(entries.length, 0);
    }

    /* //////////////////////////////////////////////////////////////
                        FLAGGED DELAY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FlaggedDelay_FirstSubmission() public {
        _installHookWithDelay();

        bytes memory msgData = abi.encodePacked(recipient, uint256(2 ether), "");

        // Without queuing first, should revert with TransactionNotQueued
        vm.prank(address(account));
        vm.expectRevert(
            abi.encodeWithSelector(
                AuditHook.TransactionNotQueued.selector, _getTxHash(address(account), recipient, 2 ether, msgData)
            )
        );
        hook.preCheck(user, 2 ether, msgData);
    }

    function test_FlaggedDelay_StillPending() public {
        _installHookWithDelay();

        bytes memory msgData = abi.encodePacked(recipient, uint256(2 ether), "");

        // Queue the transaction first
        vm.prank(address(account));
        hook.queueFlaggedTransaction(recipient, 2 ether, msgData);

        // Try to execute before delay expires
        vm.warp(block.timestamp + FLAGGED_DELAY / 2);

        vm.prank(address(account));
        vm.expectRevert();
        hook.preCheck(user, 2 ether, msgData);
    }

    function test_FlaggedDelay_AfterDelay() public {
        _installHookWithDelay();

        uint256 startTime = block.timestamp;
        bytes memory msgData = abi.encodePacked(recipient, uint256(2 ether), "");

        // Queue the transaction first
        vm.prank(address(account));
        hook.queueFlaggedTransaction(recipient, 2 ether, msgData);

        // Wait for delay (use absolute time)
        vm.warp(startTime + FLAGGED_DELAY + 1);

        // Should succeed now
        vm.prank(address(account));
        bytes memory hookData = hook.preCheck(user, 2 ether, msgData);

        uint256 logIndex = abi.decode(hookData, (uint256));
        assertEq(logIndex, 0);
    }

    function test_FlaggedDelay_NoDelayForLowValue() public {
        _installHookWithDelay();

        bytes memory msgData = abi.encodePacked(recipient, uint256(0.5 ether), "");

        // Should not trigger delay
        vm.prank(address(account));
        bytes memory hookData = hook.preCheck(user, 0.5 ether, msgData);

        uint256 logIndex = abi.decode(hookData, (uint256));
        assertEq(logIndex, 0);
    }

    function test_GetPendingExecutionTime() public {
        _installHookWithDelay();

        uint256 startTime = block.timestamp;
        bytes memory msgData = abi.encodePacked(recipient, uint256(2 ether), "");

        // Get pending time before queueing
        uint256 pendingBefore = hook.getPendingExecutionTime(address(account), recipient, 2 ether, msgData);
        assertEq(pendingBefore, 0);

        // Queue the transaction
        vm.prank(address(account));
        hook.queueFlaggedTransaction(recipient, 2 ether, msgData);

        // Check pending time
        uint256 pendingAfter = hook.getPendingExecutionTime(address(account), recipient, 2 ether, msgData);
        assertEq(pendingAfter, startTime + FLAGGED_DELAY);
    }

    /* //////////////////////////////////////////////////////////////
                        CAN EXECUTE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CanExecute_ModuleNotEnabled() public view {
        bytes memory msgData = "";
        (bool canExec, string memory reason) = hook.canExecute(address(account), recipient, 0.1 ether, msgData);
        assertFalse(canExec);
        assertEq(reason, "Module not enabled");
    }

    function test_CanExecute_TargetBlocked() public {
        _installHook();

        vm.prank(address(account));
        hook.setBlocklist(blockedAddress, true);

        bytes memory msgData = "";
        (bool canExec, string memory reason) = hook.canExecute(address(account), blockedAddress, 0.1 ether, msgData);
        assertFalse(canExec);
        assertEq(reason, "Target is blocked");
    }

    function test_CanExecute_NeedsSubmission() public {
        _installHookWithDelay();

        bytes memory msgData = "";
        (bool canExec, string memory reason) = hook.canExecute(address(account), recipient, 2 ether, msgData);
        assertFalse(canExec);
        assertEq(reason, "Transaction needs to be submitted first");
    }

    function test_CanExecute_StillPending() public {
        _installHookWithDelay();

        bytes memory msgData = abi.encodePacked(recipient, uint256(2 ether), "");

        // Queue the transaction
        vm.prank(address(account));
        hook.queueFlaggedTransaction(recipient, 2 ether, msgData);

        // canExecute needs the same msgData format as preCheck for correct txHash
        (bool canExec, string memory reason) = hook.canExecute(address(account), recipient, 2 ether, msgData);
        assertFalse(canExec);
        assertEq(reason, "Transaction is still pending");
    }

    function test_CanExecute_Success() public {
        _installHook();

        bytes memory msgData = "";
        (bool canExec, string memory reason) = hook.canExecute(address(account), recipient, 0.5 ether, msgData);
        assertTrue(canExec);
        assertEq(reason, "");
    }

    /* //////////////////////////////////////////////////////////////
                            STATISTICS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetStatistics() public {
        _installHook();

        // Create msgData with value encoded in raw execution format (target || value || calldata)
        bytes memory msgData1 = abi.encodePacked(recipient, uint256(0.5 ether), "");
        bytes memory msgData2 = abi.encodePacked(recipient, uint256(2 ether), "");
        bytes memory msgData3 = abi.encodePacked(recipient, uint256(0.3 ether), "");

        vm.startPrank(address(account));

        // Normal transaction (value from msgData, not msgValue)
        bytes memory hookData1 = hook.preCheck(user, 0, msgData1);
        hook.postCheck(hookData1);

        // High value transaction (flagged)
        bytes memory hookData2 = hook.preCheck(user, 0, msgData2);
        hook.postCheck(hookData2);

        // Another normal transaction
        bytes memory hookData3 = hook.preCheck(user, 0, msgData3);
        hook.postCheck(hookData3);

        vm.stopPrank();

        (uint256 totalTransactions, uint256 totalValueTransferred, uint256 flaggedCount,) =
            hook.getStatistics(address(account));

        assertEq(totalTransactions, 3);
        assertEq(totalValueTransferred, 0.5 ether + 2 ether + 0.3 ether);
        assertEq(flaggedCount, 1);
    }

    /* //////////////////////////////////////////////////////////////
                        MODULE NOT ENABLED TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PreCheck_RevertModuleNotEnabled() public {
        bytes memory msgData = abi.encodePacked(recipient, uint256(0.1 ether), "");

        vm.prank(address(account));
        vm.expectRevert(AuditHook.ModuleNotEnabled.selector);
        hook.preCheck(user, 0.1 ether, msgData);
    }

    /* //////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _installHook() internal {
        vm.prank(address(account));
        hook.onInstall("");
    }

    function _installHookWithDelay() internal {
        bytes memory installData = abi.encode(HIGH_VALUE_THRESHOLD, FLAGGED_DELAY);

        vm.prank(address(account));
        hook.onInstall(installData);
    }

    function _getTxHash(address accountAddr, address target, uint256 value, bytes memory data)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(accountAddr, target, value, data));
    }
}
