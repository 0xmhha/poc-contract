// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { PolicyHook } from "../../src/erc7579-hooks/PolicyHook.sol";
import { MockHookAccount, MockERC20 } from "./mocks/MockHookAccount.sol";

/**
 * @title PolicyHook Test
 * @notice TDD RED Phase - Tests for ERC-7579 Policy enforcement Hook
 * @dev PolicyHook enforces execution policies on Smart Accounts:
 *      - Target address whitelist/blacklist
 *      - Function selector whitelist per target
 *      - Value limits per target
 *      - Transaction count limits per period
 */
contract PolicyHookTest is Test {
    PolicyHook public hook;
    MockHookAccount public account;
    MockERC20 public token;

    address public user;
    address public trustedTarget;
    address public untrustedTarget;
    address public restrictedTarget;

    // Constants
    uint256 constant MAX_VALUE_PER_TX = 1 ether;
    uint256 constant MAX_TX_COUNT = 10;
    uint256 constant PERIOD_DAILY = 1 days;

    // Function selectors
    bytes4 constant TRANSFER_SELECTOR = bytes4(keccak256("transfer(address,uint256)"));
    bytes4 constant APPROVE_SELECTOR = bytes4(keccak256("approve(address,uint256)"));
    bytes4 constant MALICIOUS_SELECTOR = bytes4(keccak256("maliciousFunction()"));

    function setUp() public {
        user = makeAddr("user");
        trustedTarget = makeAddr("trustedTarget");
        untrustedTarget = makeAddr("untrustedTarget");
        restrictedTarget = makeAddr("restrictedTarget");

        // Deploy contracts
        hook = new PolicyHook();
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

    function test_OnInstall_WithDefaultPolicy() public {
        // Default policy: block all by default (allowlist mode)
        bytes memory installData = abi.encode(
            PolicyHook.PolicyMode.ALLOWLIST,
            true // strict mode
        );

        vm.prank(address(account));
        hook.onInstall(installData);

        assertTrue(hook.isInitialized(address(account)), "Should be initialized");
        assertEq(uint8(hook.getPolicyMode(address(account))), uint8(PolicyHook.PolicyMode.ALLOWLIST));
    }

    function test_OnUninstall() public {
        _installWithAllowlistMode();

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
                        POLICY MODE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetPolicyMode_Allowlist() public {
        vm.prank(address(account));
        hook.setPolicyMode(PolicyHook.PolicyMode.ALLOWLIST);

        assertEq(uint8(hook.getPolicyMode(address(account))), uint8(PolicyHook.PolicyMode.ALLOWLIST));
    }

    function test_SetPolicyMode_Blocklist() public {
        vm.prank(address(account));
        hook.setPolicyMode(PolicyHook.PolicyMode.BLOCKLIST);

        assertEq(uint8(hook.getPolicyMode(address(account))), uint8(PolicyHook.PolicyMode.BLOCKLIST));
    }

    /* //////////////////////////////////////////////////////////////
                        TARGET WHITELIST TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddAllowedTarget() public {
        _installWithAllowlistMode();

        vm.prank(address(account));
        hook.addAllowedTarget(trustedTarget);

        assertTrue(hook.isTargetAllowed(address(account), trustedTarget));
    }

    function test_RemoveAllowedTarget() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.removeAllowedTarget(trustedTarget);
        vm.stopPrank();

        assertFalse(hook.isTargetAllowed(address(account), trustedTarget));
    }

    function test_AddBlockedTarget() public {
        _installWithBlocklistMode();

        vm.prank(address(account));
        hook.addBlockedTarget(untrustedTarget);

        assertTrue(hook.isTargetBlocked(address(account), untrustedTarget));
    }

    function test_RemoveBlockedTarget() public {
        _installWithBlocklistMode();

        vm.startPrank(address(account));
        hook.addBlockedTarget(untrustedTarget);
        hook.removeBlockedTarget(untrustedTarget);
        vm.stopPrank();

        assertFalse(hook.isTargetBlocked(address(account), untrustedTarget));
    }

    /* //////////////////////////////////////////////////////////////
                    FUNCTION SELECTOR WHITELIST TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddAllowedSelector() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.addAllowedSelector(trustedTarget, TRANSFER_SELECTOR);
        vm.stopPrank();

        assertTrue(hook.isSelectorAllowed(address(account), trustedTarget, TRANSFER_SELECTOR));
    }

    function test_RemoveAllowedSelector() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.addAllowedSelector(trustedTarget, TRANSFER_SELECTOR);
        hook.removeAllowedSelector(trustedTarget, TRANSFER_SELECTOR);
        vm.stopPrank();

        assertFalse(hook.isSelectorAllowed(address(account), trustedTarget, TRANSFER_SELECTOR));
    }

    function test_AddBlockedSelector() public {
        _installWithBlocklistMode();

        vm.prank(address(account));
        hook.addBlockedSelector(restrictedTarget, MALICIOUS_SELECTOR);

        assertTrue(hook.isSelectorBlocked(address(account), restrictedTarget, MALICIOUS_SELECTOR));
    }

    /* //////////////////////////////////////////////////////////////
                        VALUE LIMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetTargetValueLimit() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.setTargetValueLimit(trustedTarget, MAX_VALUE_PER_TX);
        vm.stopPrank();

        assertEq(hook.getTargetValueLimit(address(account), trustedTarget), MAX_VALUE_PER_TX);
    }

    function test_RemoveTargetValueLimit() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.setTargetValueLimit(trustedTarget, MAX_VALUE_PER_TX);
        hook.removeTargetValueLimit(trustedTarget);
        vm.stopPrank();

        assertEq(hook.getTargetValueLimit(address(account), trustedTarget), 0);
    }

    /* //////////////////////////////////////////////////////////////
                    TRANSACTION COUNT LIMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetTransactionCountLimit() public {
        _installWithAllowlistMode();

        vm.prank(address(account));
        hook.setTransactionCountLimit(MAX_TX_COUNT, PERIOD_DAILY);

        (uint256 limit, uint256 period) = hook.getTransactionCountLimit(address(account));
        assertEq(limit, MAX_TX_COUNT);
        assertEq(period, PERIOD_DAILY);
    }

    function test_GetRemainingTransactionCount() public {
        _installWithAllowlistMode();

        vm.prank(address(account));
        hook.setTransactionCountLimit(MAX_TX_COUNT, PERIOD_DAILY);

        assertEq(hook.getRemainingTransactionCount(address(account)), MAX_TX_COUNT);
    }

    /* //////////////////////////////////////////////////////////////
                            PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause() public {
        _installWithAllowlistMode();

        vm.prank(address(account));
        hook.pause();

        assertTrue(hook.isPaused(address(account)));
    }

    function test_Unpause() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.pause();
        hook.unpause();
        vm.stopPrank();

        assertFalse(hook.isPaused(address(account)));
    }

    function test_PreCheck_RevertWhenPaused() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.pause();
        vm.stopPrank();

        bytes memory msgData = abi.encodePacked(trustedTarget, uint256(0.1 ether), "");

        vm.prank(address(account));
        vm.expectRevert(PolicyHook.AccountIsPaused.selector);
        hook.preCheck(user, 0.1 ether, msgData);
    }

    /* //////////////////////////////////////////////////////////////
                    PRECHECK ENFORCEMENT - ALLOWLIST MODE
    //////////////////////////////////////////////////////////////*/

    function test_PreCheck_Allowlist_AllowedTarget() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        vm.stopPrank();

        bytes memory msgData = abi.encodePacked(trustedTarget, uint256(0.5 ether), "");

        vm.prank(address(account));
        hook.preCheck(user, 0.5 ether, msgData);
        // Should not revert
    }

    function test_PreCheck_Allowlist_BlockedTarget() public {
        _installWithAllowlistMode();

        // trustedTarget is NOT added to allowlist
        bytes memory msgData = abi.encodePacked(untrustedTarget, uint256(0.5 ether), "");

        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(PolicyHook.TargetNotAllowed.selector, untrustedTarget));
        hook.preCheck(user, 0.5 ether, msgData);
    }

    function test_PreCheck_Allowlist_AllowedSelector() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.addAllowedSelector(trustedTarget, TRANSFER_SELECTOR);
        hook.setStrictSelectorMode(trustedTarget, true);
        vm.stopPrank();

        // Build calldata with allowed selector
        bytes memory callData = abi.encodeWithSelector(TRANSFER_SELECTOR, user, 100);
        bytes memory msgData = abi.encodePacked(trustedTarget, uint256(0), callData);

        vm.prank(address(account));
        hook.preCheck(user, 0, msgData);
        // Should not revert
    }

    function test_PreCheck_Allowlist_BlockedSelector() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.addAllowedSelector(trustedTarget, TRANSFER_SELECTOR);
        hook.setStrictSelectorMode(trustedTarget, true);
        vm.stopPrank();

        // Build calldata with non-allowed selector
        bytes memory callData = abi.encodeWithSelector(APPROVE_SELECTOR, user, 100);
        bytes memory msgData = abi.encodePacked(trustedTarget, uint256(0), callData);

        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(PolicyHook.SelectorNotAllowed.selector, trustedTarget, APPROVE_SELECTOR));
        hook.preCheck(user, 0, msgData);
    }

    /* //////////////////////////////////////////////////////////////
                    PRECHECK ENFORCEMENT - BLOCKLIST MODE
    //////////////////////////////////////////////////////////////*/

    function test_PreCheck_Blocklist_AllowedTarget() public {
        _installWithBlocklistMode();

        // Any target not in blocklist should be allowed
        bytes memory msgData = abi.encodePacked(trustedTarget, uint256(0.5 ether), "");

        vm.prank(address(account));
        hook.preCheck(user, 0.5 ether, msgData);
        // Should not revert
    }

    function test_PreCheck_Blocklist_BlockedTarget() public {
        _installWithBlocklistMode();

        vm.prank(address(account));
        hook.addBlockedTarget(untrustedTarget);

        bytes memory msgData = abi.encodePacked(untrustedTarget, uint256(0.5 ether), "");

        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(PolicyHook.TargetIsBlocked.selector, untrustedTarget));
        hook.preCheck(user, 0.5 ether, msgData);
    }

    function test_PreCheck_Blocklist_BlockedSelector() public {
        _installWithBlocklistMode();

        vm.prank(address(account));
        hook.addBlockedSelector(restrictedTarget, MALICIOUS_SELECTOR);

        bytes memory callData = abi.encodeWithSelector(MALICIOUS_SELECTOR);
        bytes memory msgData = abi.encodePacked(restrictedTarget, uint256(0), callData);

        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(PolicyHook.SelectorIsBlocked.selector, restrictedTarget, MALICIOUS_SELECTOR));
        hook.preCheck(user, 0, msgData);
    }

    /* //////////////////////////////////////////////////////////////
                    VALUE LIMIT ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_PreCheck_ValueLimit_UnderLimit() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.setTargetValueLimit(trustedTarget, MAX_VALUE_PER_TX);
        vm.stopPrank();

        bytes memory msgData = abi.encodePacked(trustedTarget, uint256(0.5 ether), "");

        vm.prank(address(account));
        hook.preCheck(user, 0.5 ether, msgData);
        // Should not revert
    }

    function test_PreCheck_ValueLimit_ExceedsLimit() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.setTargetValueLimit(trustedTarget, MAX_VALUE_PER_TX);
        vm.stopPrank();

        bytes memory msgData = abi.encodePacked(trustedTarget, uint256(2 ether), "");

        vm.prank(address(account));
        vm.expectRevert(
            abi.encodeWithSelector(PolicyHook.ValueExceedsLimit.selector, trustedTarget, 2 ether, MAX_VALUE_PER_TX)
        );
        hook.preCheck(user, 2 ether, msgData);
    }

    function test_PreCheck_ValueLimit_NoLimit() public {
        _installWithAllowlistMode();

        vm.prank(address(account));
        hook.addAllowedTarget(trustedTarget);

        // No value limit set - should allow any value
        bytes memory msgData = abi.encodePacked(trustedTarget, uint256(100 ether), "");

        vm.prank(address(account));
        hook.preCheck(user, 100 ether, msgData);
        // Should not revert
    }

    /* //////////////////////////////////////////////////////////////
                    TRANSACTION COUNT ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_PreCheck_TxCount_UnderLimit() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.setTransactionCountLimit(MAX_TX_COUNT, PERIOD_DAILY);
        vm.stopPrank();

        bytes memory msgData = abi.encodePacked(trustedTarget, uint256(0.1 ether), "");

        // Execute multiple transactions under limit
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(address(account));
            hook.preCheck(user, 0.1 ether, msgData);
        }

        assertEq(hook.getRemainingTransactionCount(address(account)), MAX_TX_COUNT - 5);
    }

    function test_PreCheck_TxCount_ExceedsLimit() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.setTransactionCountLimit(3, PERIOD_DAILY); // Only 3 tx allowed
        vm.stopPrank();

        bytes memory msgData = abi.encodePacked(trustedTarget, uint256(0.1 ether), "");

        // Execute 3 transactions (at limit)
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(address(account));
            hook.preCheck(user, 0.1 ether, msgData);
        }

        // 4th transaction should fail
        vm.prank(address(account));
        vm.expectRevert(PolicyHook.TransactionCountExceeded.selector);
        hook.preCheck(user, 0.1 ether, msgData);
    }

    function test_PreCheck_TxCount_ResetAfterPeriod() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.setTransactionCountLimit(3, PERIOD_DAILY);
        vm.stopPrank();

        bytes memory msgData = abi.encodePacked(trustedTarget, uint256(0.1 ether), "");

        // Use all 3 transactions
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(address(account));
            hook.preCheck(user, 0.1 ether, msgData);
        }

        assertEq(hook.getRemainingTransactionCount(address(account)), 0);

        // Fast forward past the period
        vm.warp(block.timestamp + PERIOD_DAILY + 1);

        // Should have full count again
        assertEq(hook.getRemainingTransactionCount(address(account)), 3);

        // Should be able to execute again
        vm.prank(address(account));
        hook.preCheck(user, 0.1 ether, msgData);
    }

    /* //////////////////////////////////////////////////////////////
                            POST CHECK TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PostCheck_DoesNotRevert() public {
        vm.prank(address(account));
        hook.postCheck("");
        // Should not revert
    }

    /* //////////////////////////////////////////////////////////////
                        BATCH CONFIGURATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BatchAddAllowedTargets() public {
        _installWithAllowlistMode();

        address[] memory targets = new address[](3);
        targets[0] = trustedTarget;
        targets[1] = makeAddr("target2");
        targets[2] = makeAddr("target3");

        vm.prank(address(account));
        hook.batchAddAllowedTargets(targets);

        for (uint256 i = 0; i < targets.length; i++) {
            assertTrue(hook.isTargetAllowed(address(account), targets[i]));
        }
    }

    function test_BatchConfigureTarget() public {
        _installWithAllowlistMode();

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = TRANSFER_SELECTOR;
        selectors[1] = APPROVE_SELECTOR;

        vm.prank(address(account));
        hook.configureTarget(
            trustedTarget,
            true, // allowed
            selectors,
            MAX_VALUE_PER_TX,
            true // strict selector mode
        );

        assertTrue(hook.isTargetAllowed(address(account), trustedTarget));
        assertTrue(hook.isSelectorAllowed(address(account), trustedTarget, TRANSFER_SELECTOR));
        assertTrue(hook.isSelectorAllowed(address(account), trustedTarget, APPROVE_SELECTOR));
        assertEq(hook.getTargetValueLimit(address(account), trustedTarget), MAX_VALUE_PER_TX);
    }

    /* //////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_GetAllowedTargets() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.addAllowedTarget(makeAddr("target2"));
        vm.stopPrank();

        address[] memory targets = hook.getAllowedTargets(address(account));
        assertEq(targets.length, 2);
    }

    function test_GetBlockedTargets() public {
        _installWithBlocklistMode();

        vm.startPrank(address(account));
        hook.addBlockedTarget(untrustedTarget);
        hook.addBlockedTarget(makeAddr("blocked2"));
        vm.stopPrank();

        address[] memory targets = hook.getBlockedTargets(address(account));
        assertEq(targets.length, 2);
    }

    function test_GetAllowedSelectors() public {
        _installWithAllowlistMode();

        vm.startPrank(address(account));
        hook.addAllowedTarget(trustedTarget);
        hook.addAllowedSelector(trustedTarget, TRANSFER_SELECTOR);
        hook.addAllowedSelector(trustedTarget, APPROVE_SELECTOR);
        vm.stopPrank();

        bytes4[] memory selectors = hook.getAllowedSelectors(address(account), trustedTarget);
        assertEq(selectors.length, 2);
    }

    /* //////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _installWithAllowlistMode() internal {
        bytes memory installData = abi.encode(
            PolicyHook.PolicyMode.ALLOWLIST,
            false // not strict by default
        );

        vm.prank(address(account));
        hook.onInstall(installData);
    }

    function _installWithBlocklistMode() internal {
        bytes memory installData = abi.encode(
            PolicyHook.PolicyMode.BLOCKLIST,
            false // not strict
        );

        vm.prank(address(account));
        hook.onInstall(installData);
    }
}
