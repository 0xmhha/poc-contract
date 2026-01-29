// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {
    ERC7715PermissionManager,
    IERC7715PermissionManager
} from "../../src/subscription/ERC7715PermissionManager.sol";

/**
 * @title ERC7715PermissionManagerFuzzTest
 * @notice Fuzzing tests for ERC7715PermissionManager edge cases and boundary values
 */
contract ERC7715PermissionManagerFuzzTest is Test {
    ERC7715PermissionManager public permManager;

    address public owner;
    address public executor;

    function setUp() public {
        owner = makeAddr("owner");
        executor = makeAddr("executor");

        vm.prank(owner);
        permManager = new ERC7715PermissionManager();

        vm.prank(owner);
        permManager.addAuthorizedExecutor(executor);
    }

    /* //////////////////////////////////////////////////////////////
                    PERMISSION GRANTING FUZZ TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Fuzz test permission granting with various spending limits
     * @param spendingLimit The spending limit to encode
     */
    function testFuzz_GrantPermission_SpendingLimit(uint256 spendingLimit) public {
        address granter = makeAddr("granter");

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: true,
            data: abi.encode(spendingLimit)
        });

        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);

        vm.prank(granter);
        bytes32 permissionId = permManager.grantPermission(executor, executor, permission, rules);

        // Verify permission was created
        assertTrue(permissionId != bytes32(0), "Permission ID should not be zero");

        // Verify permission status
        assertTrue(permManager.isPermissionValid(permissionId), "Permission should be valid");
    }

    /**
     * @notice Fuzz test permission granting by different addresses
     * @param granterSeed Seed to generate granter address
     */
    function testFuzz_GrantPermission_DifferentGranters(uint256 granterSeed) public {
        // Generate random granter address
        address granter = address(uint160(bound(granterSeed, 1, type(uint160).max)));
        vm.assume(granter != address(0));
        vm.assume(granter != executor);

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: false,
            data: abi.encode(uint256(1000 ether))
        });

        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);

        vm.prank(granter);
        bytes32 permissionId = permManager.grantPermission(executor, executor, permission, rules);

        // Verify permission was created for the correct granter
        assertTrue(permissionId != bytes32(0), "Permission ID should not be zero");
    }

    /**
     * @notice Fuzz test permission types
     * @param permissionTypeSeed Seed to generate permission type
     */
    function testFuzz_GrantPermission_PermissionTypes(uint8 permissionTypeSeed) public {
        address granter = makeAddr("granter");

        // Use only valid permission types registered in the contract
        string[5] memory types =
            ["subscription", "native-token-recurring-allowance", "erc20-recurring-allowance", "session-key", "spending-limit"];
        string memory permType = types[permissionTypeSeed % 5];

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: permType,
            isAdjustmentAllowed: true,
            data: abi.encode(uint256(1000 ether))
        });

        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);

        vm.prank(granter);
        bytes32 permissionId = permManager.grantPermission(executor, executor, permission, rules);

        assertTrue(permissionId != bytes32(0), "Permission should be granted");
    }

    /* //////////////////////////////////////////////////////////////
                    PERMISSION VALIDATION FUZZ TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Fuzz test permission validation with various amounts
     * @param limit Spending limit
     * @param spentAmount Amount to spend
     */
    function testFuzz_ValidatePermission_SpendingAmounts(uint256 limit, uint256 spentAmount) public {
        // Bound values to avoid overflow
        limit = bound(limit, 1, type(uint128).max);
        spentAmount = bound(spentAmount, 0, limit);

        address granter = makeAddr("granter");

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: true,
            data: abi.encode(limit)
        });

        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);

        vm.prank(granter);
        bytes32 permissionId = permManager.grantPermission(executor, executor, permission, rules);

        // Permission should be valid initially
        assertTrue(permManager.isPermissionValid(permissionId), "Permission should be valid");

        // Record spending (if executor tries to use)
        vm.prank(executor);
        bool canSpend = permManager.usePermission(permissionId, spentAmount);
        assertTrue(canSpend, "Should be able to spend within limit");
    }

    /**
     * @notice Fuzz test permission validation exceeds limit
     * @param limit Spending limit
     */
    function testFuzz_ValidatePermission_ExceedsLimit(uint256 limit) public {
        // Bound limit to reasonable range
        limit = bound(limit, 1, type(uint128).max - 1);
        uint256 excessAmount = limit + 1;

        address granter = makeAddr("granter");

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: true,
            data: abi.encode(limit)
        });

        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);

        vm.prank(granter);
        bytes32 permissionId = permManager.grantPermission(executor, executor, permission, rules);

        // Attempt to spend more than limit should fail
        vm.prank(executor);
        vm.expectRevert();
        permManager.usePermission(permissionId, excessAmount);
    }

    /* //////////////////////////////////////////////////////////////
                    PERMISSION REVOCATION FUZZ TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Fuzz test revoking permissions at various timestamps
     * @param grantTime Time when permission is granted
     * @param revokeDelay Delay before revocation
     */
    function testFuzz_RevokePermission_Timestamps(uint256 grantTime, uint256 revokeDelay) public {
        // Bound times to reasonable range
        grantTime = bound(grantTime, block.timestamp, block.timestamp + 365 days);
        revokeDelay = bound(revokeDelay, 0, 365 days);

        address granter = makeAddr("granter");

        // Warp to grant time
        vm.warp(grantTime);

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: true,
            data: abi.encode(uint256(1000 ether))
        });

        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);

        vm.prank(granter);
        bytes32 permissionId = permManager.grantPermission(executor, executor, permission, rules);

        // Warp to revoke time
        vm.warp(grantTime + revokeDelay);

        // Revoke permission
        vm.prank(granter);
        permManager.revokePermission(permissionId);

        // Permission should no longer be valid
        assertFalse(permManager.isPermissionValid(permissionId), "Permission should be revoked");
    }

    /* //////////////////////////////////////////////////////////////
                    MULTIPLE PERMISSIONS FUZZ TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Fuzz test creating multiple permissions
     * @param permissionCount Number of permissions to create
     */
    function testFuzz_GrantMultiplePermissions(uint8 permissionCount) public {
        // Bound permission count
        permissionCount = uint8(bound(permissionCount, 1, 50));

        address granter = makeAddr("granter");
        bytes32[] memory permissionIds = new bytes32[](permissionCount);

        for (uint8 i = 0; i < permissionCount; i++) {
            IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
                permissionType: "subscription",
                isAdjustmentAllowed: true,
                data: abi.encode(uint256(i + 1) * 100 ether)
            });

            IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);

            vm.prank(granter);
            permissionIds[i] = permManager.grantPermission(executor, executor, permission, rules);

            assertTrue(permissionIds[i] != bytes32(0), "Permission should be created");

            // Verify unique IDs
            for (uint8 j = 0; j < i; j++) {
                assertTrue(permissionIds[i] != permissionIds[j], "Permission IDs should be unique");
            }
        }
    }

    /* //////////////////////////////////////////////////////////////
                        RULE VALIDATION FUZZ TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Fuzz test with varying number of rules
     * @param ruleCount Number of rules
     */
    function testFuzz_GrantPermission_WithRules(uint8 ruleCount) public {
        // Bound rule count
        ruleCount = uint8(bound(ruleCount, 0, 10));

        address granter = makeAddr("granter");

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: true,
            data: abi.encode(uint256(1000 ether))
        });

        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](ruleCount);

        for (uint8 i = 0; i < ruleCount; i++) {
            rules[i] = IERC7715PermissionManager.Rule({
                ruleType: "maxAmount",
                data: abi.encode(uint256(100 ether + i))
            });
        }

        vm.prank(granter);
        bytes32 permissionId = permManager.grantPermission(executor, executor, permission, rules);

        assertTrue(permissionId != bytes32(0), "Permission with rules should be created");
    }

    /* //////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Test zero spending limit
     */
    function test_GrantPermission_ZeroLimit() public {
        address granter = makeAddr("granter");

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: true,
            data: abi.encode(uint256(0))
        });

        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);

        vm.prank(granter);
        bytes32 permissionId = permManager.grantPermission(executor, executor, permission, rules);

        // Permission should be created but any spend should fail
        assertTrue(permissionId != bytes32(0), "Permission should be created");
    }

    /**
     * @notice Test maximum spending limit
     */
    function test_GrantPermission_MaxLimit() public {
        address granter = makeAddr("granter");

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: true,
            data: abi.encode(type(uint256).max)
        });

        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);

        vm.prank(granter);
        bytes32 permissionId = permManager.grantPermission(executor, executor, permission, rules);

        assertTrue(permissionId != bytes32(0), "Permission with max limit should be created");
        assertTrue(permManager.isPermissionValid(permissionId), "Permission should be valid");
    }

    /**
     * @notice Test revoking non-existent permission
     */
    function test_RevokePermission_NonExistent() public {
        address granter = makeAddr("granter");
        bytes32 fakeId = keccak256("fake");

        vm.prank(granter);
        vm.expectRevert();
        permManager.revokePermission(fakeId);
    }

    /**
     * @notice Test double revocation
     */
    function test_RevokePermission_DoubleRevoke() public {
        address granter = makeAddr("granter");

        IERC7715PermissionManager.Permission memory permission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: true,
            data: abi.encode(uint256(1000 ether))
        });

        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](0);

        vm.prank(granter);
        bytes32 permissionId = permManager.grantPermission(executor, executor, permission, rules);

        // First revocation should succeed
        vm.prank(granter);
        permManager.revokePermission(permissionId);

        // Second revocation should fail
        vm.prank(granter);
        vm.expectRevert();
        permManager.revokePermission(permissionId);
    }
}
