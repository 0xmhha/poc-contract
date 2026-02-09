// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HealthFactorHook} from "../../src/erc7579-hooks/HealthFactorHook.sol";
import {IModule} from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import {MODULE_TYPE_HOOK} from "../../src/erc7579-smartaccount/types/Constants.sol";

/**
 * @title HealthFactorHook Test
 * @notice TDD RED Phase - Tests for ERC-7579 HealthFactorHook module
 * @dev Tests health factor validation for lending operations
 *
 * Health Factor = (Collateral Value * Liquidation Threshold) / Debt Value
 * If HF < 1.0, position can be liquidated
 */
contract HealthFactorHookTest is Test {
    HealthFactorHook public hook;

    // Mock addresses
    address public owner;
    address public account; // Smart Account
    address public lendingPool;

    // Test addresses
    address public targetContract;
    address public otherContract;

    // Constants
    uint256 public constant MIN_HEALTH_FACTOR = 1e18; // 1.0
    uint256 public constant DEFAULT_THRESHOLD = 1.2e18; // 1.2

    function setUp() public {
        owner = makeAddr("owner");
        account = makeAddr("smartAccount");
        lendingPool = address(new MockLendingPool());
        targetContract = makeAddr("targetContract");
        otherContract = makeAddr("otherContract");

        // Deploy HealthFactorHook
        hook = new HealthFactorHook(lendingPool);
    }

    // =========================================================================
    // Module Interface Tests
    // =========================================================================

    function test_isModuleType_ReturnsTrue_ForHook() public view {
        assertTrue(hook.isModuleType(MODULE_TYPE_HOOK));
    }

    function test_isModuleType_ReturnsFalse_ForOtherTypes() public view {
        assertFalse(hook.isModuleType(1)); // Validator
        assertFalse(hook.isModuleType(2)); // Executor
        assertFalse(hook.isModuleType(3)); // Fallback
    }

    function test_onInstall_WithEmptyData_SetsDefaults() public {
        vm.prank(account);
        hook.onInstall(bytes(""));

        assertTrue(hook.isInitialized(account));
        assertEq(hook.getMinHealthFactor(account), DEFAULT_THRESHOLD);
    }

    function test_onInstall_WithCustomThreshold_SetsThreshold() public {
        uint256 customThreshold = 1.5e18; // 1.5
        bytes memory installData = abi.encode(customThreshold, true); // threshold, enabled

        vm.prank(account);
        hook.onInstall(installData);

        assertEq(hook.getMinHealthFactor(account), customThreshold);
    }

    function test_onInstall_RevertsIf_ThresholdTooLow() public {
        uint256 tooLow = 0.9e18; // Below 1.0
        bytes memory installData = abi.encode(tooLow, true);

        vm.prank(account);
        vm.expectRevert(HealthFactorHook.InvalidThreshold.selector);
        hook.onInstall(installData);
    }

    function test_onInstall_RevertsIf_AlreadyInstalled() public {
        vm.prank(account);
        hook.onInstall(bytes(""));

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IModule.AlreadyInitialized.selector, account));
        hook.onInstall(bytes(""));
    }

    function test_onUninstall_ClearsState() public {
        vm.prank(account);
        hook.onInstall(bytes(""));

        vm.prank(account);
        hook.onUninstall(bytes(""));

        assertFalse(hook.isInitialized(account));
    }

    function test_isInitialized_ReturnsFalse_BeforeInstall() public view {
        assertFalse(hook.isInitialized(account));
    }

    // =========================================================================
    // Configuration Tests
    // =========================================================================

    function test_setMinHealthFactor_UpdatesThreshold() public {
        _installHook();

        uint256 newThreshold = 1.8e18;

        vm.prank(account);
        hook.setMinHealthFactor(newThreshold);

        assertEq(hook.getMinHealthFactor(account), newThreshold);
    }

    function test_setMinHealthFactor_RevertsIf_TooLow() public {
        _installHook();

        vm.prank(account);
        vm.expectRevert(HealthFactorHook.InvalidThreshold.selector);
        hook.setMinHealthFactor(0.5e18);
    }

    function test_setMinHealthFactor_RevertsIf_NotInitialized() public {
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IModule.NotInitialized.selector, account));
        hook.setMinHealthFactor(1.5e18);
    }

    function test_setEnabled_EnablesHook() public {
        _installHook();

        vm.prank(account);
        hook.setEnabled(false);

        assertFalse(hook.isEnabled(account));

        vm.prank(account);
        hook.setEnabled(true);

        assertTrue(hook.isEnabled(account));
    }

    function test_getAccountConfig_ReturnsCorrectConfig() public {
        _installHook();

        (uint256 minHf, bool enabled, bool initialized) = hook.getAccountConfig(account);

        assertEq(minHf, DEFAULT_THRESHOLD);
        assertTrue(enabled);
        assertTrue(initialized);
    }

    // =========================================================================
    // Monitored Target Tests
    // =========================================================================

    function test_addMonitoredTarget_AddsTarget() public {
        _installHook();

        vm.prank(account);
        hook.addMonitoredTarget(targetContract);

        assertTrue(hook.isMonitoredTarget(account, targetContract));
    }

    function test_addMonitoredTarget_RevertsIf_ZeroAddress() public {
        _installHook();

        vm.prank(account);
        vm.expectRevert(HealthFactorHook.InvalidTarget.selector);
        hook.addMonitoredTarget(address(0));
    }

    function test_addMonitoredTarget_RevertsIf_AlreadyMonitored() public {
        _installHook();

        vm.prank(account);
        hook.addMonitoredTarget(targetContract);

        vm.prank(account);
        vm.expectRevert(HealthFactorHook.TargetAlreadyMonitored.selector);
        hook.addMonitoredTarget(targetContract);
    }

    function test_removeMonitoredTarget_RemovesTarget() public {
        _installHook();

        vm.prank(account);
        hook.addMonitoredTarget(targetContract);

        vm.prank(account);
        hook.removeMonitoredTarget(targetContract);

        assertFalse(hook.isMonitoredTarget(account, targetContract));
    }

    function test_removeMonitoredTarget_RevertsIf_NotMonitored() public {
        _installHook();

        vm.prank(account);
        vm.expectRevert(HealthFactorHook.TargetNotMonitored.selector);
        hook.removeMonitoredTarget(targetContract);
    }

    function test_getMonitoredTargets_ReturnsAllTargets() public {
        _installHook();

        vm.prank(account);
        hook.addMonitoredTarget(targetContract);

        vm.prank(account);
        hook.addMonitoredTarget(otherContract);

        address[] memory targets = hook.getMonitoredTargets(account);
        assertEq(targets.length, 2);
    }

    // =========================================================================
    // preCheck Tests - Health Factor Validation
    // =========================================================================

    function test_preCheck_AllowsTransaction_WhenHealthFactorAboveThreshold() public {
        _installHookWithMockPool();

        // Set health factor to 1.5 (above 1.2 threshold)
        MockLendingPool(lendingPool).setHealthFactor(account, 1.5e18);

        vm.prank(account);
        hook.addMonitoredTarget(targetContract);

        // preCheck should pass (no revert)
        vm.prank(account);
        bytes memory context = hook.preCheck(targetContract, 0, bytes(""));

        // Context should contain pre-tx health factor
        assertGt(context.length, 0);
    }

    function test_preCheck_Skips_WhenTargetNotMonitored() public {
        _installHookWithMockPool();

        // Don't add target to monitored list
        // preCheck should pass without checking health factor

        vm.prank(account);
        bytes memory context = hook.preCheck(otherContract, 0, bytes(""));

        // Empty context when not monitored
        assertEq(context.length, 0);
    }

    function test_preCheck_Skips_WhenDisabled() public {
        _installHookWithMockPool();

        vm.prank(account);
        hook.addMonitoredTarget(targetContract);

        vm.prank(account);
        hook.setEnabled(false);

        // Should pass even with low health factor when disabled
        MockLendingPool(lendingPool).setHealthFactor(account, 0.5e18);

        vm.prank(account);
        bytes memory context = hook.preCheck(targetContract, 0, bytes(""));

        assertEq(context.length, 0);
    }

    // =========================================================================
    // postCheck Tests - Health Factor Drop Detection
    // =========================================================================

    function test_postCheck_AllowsTransaction_WhenHealthFactorStaysAboveThreshold() public {
        _installHookWithMockPool();

        vm.prank(account);
        hook.addMonitoredTarget(targetContract);

        // Set initial HF to 1.5
        MockLendingPool(lendingPool).setHealthFactor(account, 1.5e18);

        // preCheck
        vm.prank(account);
        bytes memory context = hook.preCheck(targetContract, 0, bytes(""));

        // HF stays at 1.3 (still above threshold)
        MockLendingPool(lendingPool).setHealthFactor(account, 1.3e18);

        // postCheck should pass
        vm.prank(account);
        hook.postCheck(context);
    }

    function test_postCheck_RevertsTransaction_WhenHealthFactorDropsBelowThreshold() public {
        _installHookWithMockPool();

        vm.prank(account);
        hook.addMonitoredTarget(targetContract);

        // Set initial HF to 1.5
        MockLendingPool(lendingPool).setHealthFactor(account, 1.5e18);

        // preCheck
        vm.prank(account);
        bytes memory context = hook.preCheck(targetContract, 0, bytes(""));

        // HF drops to 1.1 (below 1.2 threshold)
        MockLendingPool(lendingPool).setHealthFactor(account, 1.1e18);

        // postCheck should revert
        vm.prank(account);
        vm.expectRevert(HealthFactorHook.HealthFactorTooLow.selector);
        hook.postCheck(context);
    }

    function test_postCheck_RevertsTransaction_WhenHealthFactorDropsToLiquidation() public {
        _installHookWithMockPool();

        vm.prank(account);
        hook.addMonitoredTarget(targetContract);

        // Set initial HF to 1.5
        MockLendingPool(lendingPool).setHealthFactor(account, 1.5e18);

        // preCheck
        vm.prank(account);
        bytes memory context = hook.preCheck(targetContract, 0, bytes(""));

        // HF drops to 0.9 (liquidatable)
        MockLendingPool(lendingPool).setHealthFactor(account, 0.9e18);

        // postCheck should revert
        vm.prank(account);
        vm.expectRevert(HealthFactorHook.HealthFactorTooLow.selector);
        hook.postCheck(context);
    }

    function test_postCheck_Skips_WhenContextEmpty() public {
        _installHookWithMockPool();

        // Empty context means preCheck skipped validation
        // postCheck should also skip
        vm.prank(account);
        hook.postCheck(bytes(""));

        // No revert = success
    }

    function test_postCheck_EmitsEvent_WhenHealthFactorDropsSignificantly() public {
        _installHookWithMockPool();

        vm.prank(account);
        hook.addMonitoredTarget(targetContract);

        // Set initial HF to 2.0
        MockLendingPool(lendingPool).setHealthFactor(account, 2.0e18);

        vm.prank(account);
        bytes memory context = hook.preCheck(targetContract, 0, bytes(""));

        // HF drops to 1.25 (above threshold but significant drop)
        MockLendingPool(lendingPool).setHealthFactor(account, 1.25e18);

        vm.prank(account);
        vm.expectEmit(true, false, false, true);
        emit HealthFactorHook.HealthFactorChanged(account, 2.0e18, 1.25e18);

        hook.postCheck(context);
    }

    // =========================================================================
    // View Functions Tests
    // =========================================================================

    function test_getLendingPool_ReturnsCorrectAddress() public view {
        assertEq(hook.getLendingPool(), lendingPool);
    }

    function test_getCurrentHealthFactor_ReturnsPoolValue() public {
        _installHookWithMockPool();

        MockLendingPool(lendingPool).setHealthFactor(account, 1.75e18);

        uint256 hf = hook.getCurrentHealthFactor(account);
        assertEq(hf, 1.75e18);
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_setMinHealthFactor_ValidRange(uint256 threshold) public {
        vm.assume(threshold >= MIN_HEALTH_FACTOR && threshold <= 10e18);

        _installHook();

        vm.prank(account);
        hook.setMinHealthFactor(threshold);

        assertEq(hook.getMinHealthFactor(account), threshold);
    }

    function testFuzz_preCheck_postCheck_ValidHealthFactors(uint256 preHf, uint256 postHf) public {
        // Use bound instead of assume to avoid rejecting too many inputs
        preHf = bound(preHf, DEFAULT_THRESHOLD, 10e18);
        postHf = bound(postHf, DEFAULT_THRESHOLD, preHf);

        _installHookWithMockPool();

        vm.prank(account);
        hook.addMonitoredTarget(targetContract);

        MockLendingPool(lendingPool).setHealthFactor(account, preHf);

        vm.prank(account);
        bytes memory context = hook.preCheck(targetContract, 0, bytes(""));

        MockLendingPool(lendingPool).setHealthFactor(account, postHf);

        // Should not revert since postHf >= threshold
        vm.prank(account);
        hook.postCheck(context);
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _installHook() internal {
        bytes memory installData = abi.encode(DEFAULT_THRESHOLD, true);

        vm.prank(account);
        hook.onInstall(installData);
    }

    function _installHookWithMockPool() internal {
        // Set default health factor in mock pool
        MockLendingPool(lendingPool).setHealthFactor(account, 2.0e18);

        _installHook();
    }
}

// =========================================================================
// Mock Contracts
// =========================================================================

contract MockLendingPool {
    mapping(address => uint256) public healthFactors;

    struct AccountData {
        uint256 totalCollateralValue;
        uint256 totalDebtValue;
        uint256 ltv;
        uint256 availableBorrowValue;
        uint256 healthFactor;
    }

    function setHealthFactor(address user, uint256 hf) external {
        healthFactors[user] = hf;
    }

    function calculateHealthFactor(address user) external view returns (uint256) {
        return healthFactors[user];
    }

    function getAccountData(address user) external view returns (AccountData memory data) {
        data.healthFactor = healthFactors[user];
        data.totalCollateralValue = 1000e18;
        data.totalDebtValue = healthFactors[user] > 0 ? (1000e18 * 1e18) / healthFactors[user] : 0;
        data.ltv = 8000; // 80%
        data.availableBorrowValue = 100e18;
    }
}
