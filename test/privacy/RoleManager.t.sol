// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { RoleManager, IRoleManager } from "../../src/privacy/enterprise/RoleManager.sol";

contract RoleManagerTest is Test {
    RoleManager internal rm;

    address internal admin = makeAddr("admin");
    address internal assigner = makeAddr("assigner");
    address internal member = makeAddr("member");

    bytes32 internal constant AUDITOR = keccak256("AUDITOR");

    function setUp() public {
        rm = new RoleManager(admin);
        vm.startPrank(admin);
        rm.assignRole(rm.ROLE_ASSIGNER(), assigner, 0);
        rm.createRole(AUDITOR, "Auditor", "Reads audit logs");
        vm.stopPrank();
    }

    // ============ Privilege escalation ============

    /// @notice A ROLE_ASSIGNER alone must not be able to hand itself ROLE_ADMIN
    function test_AssignRole_AssignerCannotAssignRoleAdmin() public {
        bytes32 roleAdmin = rm.ROLE_ADMIN();
        vm.prank(assigner);
        vm.expectRevert(IRoleManager.PermissionDenied.selector);
        rm.assignRole(roleAdmin, assigner, 0);
        assertFalse(rm.hasRole(roleAdmin, assigner));
    }

    /// @notice The full escalation path to DEFAULT_ADMIN_ROLE is closed
    function test_CreateRole_RejectsDefaultAdminRole() public {
        vm.prank(admin);
        vm.expectRevert(IRoleManager.RoleAlreadyExists.selector);
        rm.createRole(bytes32(0), "root", "x");

        vm.prank(admin);
        vm.expectRevert(IRoleManager.RoleNotFound.selector);
        rm.assignRole(bytes32(0), member, 0);
        assertFalse(rm.hasRole(rm.DEFAULT_ADMIN_ROLE(), member));
    }

    function test_CreateRole_RejectsSystemRoles() public {
        bytes32 roleAssigner = rm.ROLE_ASSIGNER();
        vm.prank(admin);
        vm.expectRevert(IRoleManager.RoleAlreadyExists.selector);
        rm.createRole(roleAssigner, "dup", "x");
    }

    function test_RevokeRoleAssignment_AssignerCannotRevokeRoleItDoesNotAdminister() public {
        bytes32 roleAdmin = rm.ROLE_ADMIN();
        vm.prank(admin);
        rm.assignRole(roleAdmin, member, 0);

        vm.prank(assigner);
        vm.expectRevert(IRoleManager.PermissionDenied.selector);
        rm.revokeRoleAssignment(roleAdmin, member);
        assertTrue(rm.hasRole(roleAdmin, member));
    }

    // ============ Legitimate assignment ============

    function test_CreateRole_SetsRoleAdminAsAdmin() public view {
        assertEq(rm.getRoleAdmin(AUDITOR), rm.ROLE_ADMIN());
        assertEq(rm.roleAdmins(AUDITOR), rm.ROLE_ADMIN());
    }

    function test_AssignRole_AdminAssignsCustomAndSystemRoles() public {
        bytes32 roleAdmin = rm.ROLE_ADMIN();
        vm.startPrank(admin);
        rm.assignRole(AUDITOR, member, 0);
        rm.assignRole(roleAdmin, member, 0);
        vm.stopPrank();
        assertTrue(rm.hasRole(AUDITOR, member));
        assertTrue(rm.hasRole(roleAdmin, member));
    }

    function test_AssignRole_AssignerNeedsAdminOfCustomRole() public {
        vm.prank(assigner);
        vm.expectRevert(IRoleManager.PermissionDenied.selector);
        rm.assignRole(AUDITOR, member, 0);

        // ROLE_ADMIN delegates the custom role to ROLE_ASSIGNER through the role hierarchy
        bytes32 roleAssigner = rm.ROLE_ASSIGNER();
        vm.prank(admin);
        rm.setRoleAdmin(AUDITOR, roleAssigner);

        vm.prank(assigner);
        rm.assignRole(AUDITOR, member, 0);
        assertTrue(rm.hasRole(AUDITOR, member));

        vm.prank(assigner);
        rm.revokeRoleAssignment(AUDITOR, member);
        assertFalse(rm.hasRole(AUDITOR, member));
    }
}
