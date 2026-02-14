// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {
    ERC7715PermissionManager,
    IERC7715PermissionManager
} from "../../src/subscription/ERC7715PermissionManager.sol";

contract ERC7715PermissionManagerTest is Test {
    ERC7715PermissionManager public manager;

    address public owner;
    address public granter;
    uint256 public granterKey;
    address public grantee;
    address public target;
    address public executor;

    IERC7715PermissionManager.Permission public defaultPermission;
    IERC7715PermissionManager.Rule[] public defaultRules;

    event PermissionGranted(
        bytes32 indexed permissionId,
        address indexed granter,
        address indexed grantee,
        string permissionType,
        uint256 expiry
    );
    event PermissionRevoked(bytes32 indexed permissionId, address indexed granter, address indexed grantee);
    event PermissionAdjusted(bytes32 indexed permissionId, bytes oldData, bytes newData);
    event PermissionUsed(bytes32 indexed permissionId, address indexed user, uint256 amount);

    function setUp() public {
        owner = makeAddr("owner");
        (granter, granterKey) = makeAddrAndKey("granter");
        grantee = makeAddr("grantee");
        target = makeAddr("target");
        executor = makeAddr("executor");

        vm.startPrank(owner);
        manager = new ERC7715PermissionManager();
        manager.addAuthorizedExecutor(executor);
        manager.addAuthorizedExecutor(target);
        vm.stopPrank();

        // Setup default permission
        defaultPermission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: true,
            data: abi.encode(uint256(100 ether)) // 100 ether spending limit
        });
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertEq(manager.owner(), owner);
        assertNotEq(manager.DOMAIN_SEPARATOR(), bytes32(0));
        assertFalse(manager.paused());
    }

    function test_Constructor_RegistersDefaultPermissionTypes() public view {
        assertTrue(manager.isPermissionTypeSupported("native-token-recurring-allowance"));
        assertTrue(manager.isPermissionTypeSupported("erc20-recurring-allowance"));
        assertTrue(manager.isPermissionTypeSupported("session-key"));
        assertTrue(manager.isPermissionTypeSupported("subscription"));
        assertTrue(manager.isPermissionTypeSupported("spending-limit"));
    }

    // ============ GrantPermission Tests ============

    function test_GrantPermission_Success() public {
        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, defaultRules);

        assertTrue(manager.isPermissionValid(permissionId));

        IERC7715PermissionManager.PermissionRecord memory record = manager.getPermission(permissionId);
        assertEq(record.granter, granter);
        assertEq(record.grantee, grantee);
        assertEq(record.target, target);
        assertTrue(record.active);
    }

    function test_GrantPermission_EmitsEvent() public {
        vm.prank(granter);
        // Only check indexed params, not permissionId which we can't predict
        vm.expectEmit(false, true, true, false);
        emit PermissionGranted(bytes32(0), granter, grantee, "subscription", 0);
        manager.grantPermission(grantee, target, defaultPermission, defaultRules);
    }

    function test_GrantPermission_WithExpiryRule() public {
        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](1);
        rules[0] = IERC7715PermissionManager.Rule({ ruleType: "expiry", data: abi.encode(block.timestamp + 7 days) });

        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, rules);

        assertTrue(manager.isPermissionValid(permissionId));
    }

    function test_GrantPermission_RevertsOnInvalidPermissionType() public {
        IERC7715PermissionManager.Permission memory invalidPermission = IERC7715PermissionManager.Permission({
            permissionType: "invalid-type", isAdjustmentAllowed: false, data: ""
        });

        vm.prank(granter);
        vm.expectRevert(IERC7715PermissionManager.InvalidPermissionType.selector);
        manager.grantPermission(grantee, target, invalidPermission, defaultRules);
    }

    function test_GrantPermission_RevertsOnZeroTarget() public {
        vm.prank(granter);
        vm.expectRevert(IERC7715PermissionManager.InvalidTarget.selector);
        manager.grantPermission(grantee, address(0), defaultPermission, defaultRules);
    }

    function test_GrantPermission_RevertsOnExpiredExpiry() public {
        // Set a reasonable timestamp to avoid underflow
        vm.warp(1 days);

        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](1);
        rules[0] = IERC7715PermissionManager.Rule({
            ruleType: "expiry",
            data: abi.encode(block.timestamp - 1) // Already expired
        });

        vm.prank(granter);
        vm.expectRevert(IERC7715PermissionManager.InvalidExpiryTime.selector);
        manager.grantPermission(grantee, target, defaultPermission, rules);
    }

    function test_GrantPermission_RevertsWhenPaused() public {
        vm.prank(owner);
        manager.setPaused(true);

        vm.prank(granter);
        vm.expectRevert(IERC7715PermissionManager.PermissionPaused.selector);
        manager.grantPermission(grantee, target, defaultPermission, defaultRules);
    }

    // ============ GrantPermissionWithSignature Tests ============

    function test_GrantPermissionWithSignature_Success() public {
        uint256 deadline = block.timestamp + 1 hours;

        // Build signature
        bytes32 structHash = keccak256(
            abi.encode(
                manager.PERMISSION_GRANT_TYPEHASH(),
                granter,
                grantee,
                target,
                keccak256(bytes(defaultPermission.permissionType)),
                keccak256(defaultPermission.data),
                manager.nonces(granter),
                deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", manager.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(granterKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        bytes32 permissionId = manager.grantPermissionWithSignature(
            granter, grantee, target, defaultPermission, defaultRules, deadline, signature
        );

        assertTrue(manager.isPermissionValid(permissionId));
    }

    function test_GrantPermissionWithSignature_RevertsOnInvalidSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory invalidSignature = new bytes(65);

        // ECDSA library throws ECDSAInvalidSignature, which gets caught and re-thrown as InvalidSignature
        vm.expectRevert();
        manager.grantPermissionWithSignature(
            granter, grantee, target, defaultPermission, defaultRules, deadline, invalidSignature
        );
    }

    function test_GrantPermissionWithSignature_RevertsOnExpiredDeadline() public {
        vm.warp(1 days);
        uint256 deadline = block.timestamp - 1;
        bytes memory signature = new bytes(65);

        vm.expectRevert(IERC7715PermissionManager.ExpiredDeadline.selector);
        manager.grantPermissionWithSignature(
            granter, grantee, target, defaultPermission, defaultRules, deadline, signature
        );
    }

    // ============ RevokePermission Tests ============

    function test_RevokePermission_ByGranter() public {
        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, defaultRules);

        vm.prank(granter);
        vm.expectEmit(true, true, true, false);
        emit PermissionRevoked(permissionId, granter, grantee);
        manager.revokePermission(permissionId);

        assertFalse(manager.isPermissionValid(permissionId));
    }

    function test_RevokePermission_ByOwner() public {
        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, defaultRules);

        vm.prank(owner);
        manager.revokePermission(permissionId);

        assertFalse(manager.isPermissionValid(permissionId));
    }

    function test_RevokePermission_RevertsOnNotFound() public {
        bytes32 fakeId = keccak256("fake");

        vm.prank(granter);
        vm.expectRevert(IERC7715PermissionManager.PermissionNotFound.selector);
        manager.revokePermission(fakeId);
    }

    function test_RevokePermission_RevertsOnUnauthorized() public {
        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, defaultRules);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(IERC7715PermissionManager.UnauthorizedCaller.selector);
        manager.revokePermission(permissionId);
    }

    // ============ AdjustPermission Tests ============

    function test_AdjustPermission_Success() public {
        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, defaultRules);

        bytes memory newData = abi.encode(uint256(200 ether));

        vm.prank(granter);
        vm.expectEmit(true, false, false, false);
        emit PermissionAdjusted(permissionId, defaultPermission.data, newData);
        manager.adjustPermission(permissionId, newData);

        IERC7715PermissionManager.PermissionRecord memory record = manager.getPermission(permissionId);
        assertEq(keccak256(record.permission.data), keccak256(newData));
    }

    function test_AdjustPermission_RevertsOnNotAdjustable() public {
        IERC7715PermissionManager.Permission memory noAdjustPermission = IERC7715PermissionManager.Permission({
            permissionType: "subscription", isAdjustmentAllowed: false, data: abi.encode(uint256(100 ether))
        });

        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, noAdjustPermission, defaultRules);

        vm.prank(granter);
        vm.expectRevert(IERC7715PermissionManager.AdjustmentNotAllowed.selector);
        manager.adjustPermission(permissionId, abi.encode(uint256(200 ether)));
    }

    function test_AdjustPermission_RevertsOnUnauthorized() public {
        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, defaultRules);

        vm.prank(grantee);
        vm.expectRevert(IERC7715PermissionManager.UnauthorizedCaller.selector);
        manager.adjustPermission(permissionId, abi.encode(uint256(200 ether)));
    }

    // ============ UsePermission Tests ============

    function test_UsePermission_Success() public {
        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, defaultRules);

        vm.prank(target);
        vm.expectEmit(true, true, false, true);
        emit PermissionUsed(permissionId, target, 10 ether);
        bool success = manager.usePermission(permissionId, 10 ether);

        assertTrue(success);
        assertEq(manager.getTotalUsage(permissionId), 10 ether);
    }

    function test_UsePermission_RevertsOnUnauthorized() public {
        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, defaultRules);

        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(IERC7715PermissionManager.UnauthorizedCaller.selector);
        manager.usePermission(permissionId, 10 ether);
    }

    function test_UsePermission_RevertsOnExpired() public {
        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](1);
        rules[0] = IERC7715PermissionManager.Rule({ ruleType: "expiry", data: abi.encode(block.timestamp + 1 hours) });

        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, rules);

        // Move past expiry
        vm.warp(block.timestamp + 2 hours);

        vm.prank(target);
        vm.expectRevert(IERC7715PermissionManager.PermissionExpired.selector);
        manager.usePermission(permissionId, 10 ether);
    }

    function test_UsePermission_RevertsOnExceedingLimit() public {
        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, defaultRules);

        // Try to use more than the 100 ether limit
        vm.prank(target);
        vm.expectRevert(IERC7715PermissionManager.InsufficientAllowance.selector);
        manager.usePermission(permissionId, 150 ether);
    }

    function test_UsePermission_RevertsOnWrongTarget() public {
        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, defaultRules);

        // executor is authorized but not the target for this permission
        vm.prank(executor);
        vm.expectRevert(IERC7715PermissionManager.UnauthorizedCaller.selector);
        manager.usePermission(permissionId, 10 ether);
    }

    // ============ View Function Tests ============

    function test_IsPermissionValid_ReturnsFalseForNonexistent() public view {
        bytes32 fakeId = keccak256("fake");
        assertFalse(manager.isPermissionValid(fakeId));
    }

    function test_IsPermissionValid_ReturnsFalseForRevoked() public {
        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, defaultRules);

        vm.prank(granter);
        manager.revokePermission(permissionId);

        assertFalse(manager.isPermissionValid(permissionId));
    }

    function test_IsPermissionValid_ReturnsFalseForExpired() public {
        IERC7715PermissionManager.Rule[] memory rules = new IERC7715PermissionManager.Rule[](1);
        rules[0] = IERC7715PermissionManager.Rule({ ruleType: "expiry", data: abi.encode(block.timestamp + 1 hours) });

        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, rules);

        vm.warp(block.timestamp + 2 hours);

        assertFalse(manager.isPermissionValid(permissionId));
    }

    function test_GetPermissionId() public view {
        bytes32 id = manager.getPermissionId(granter, grantee, target, "subscription", 0);
        assertNotEq(id, bytes32(0));
    }

    function test_GetRemainingAllowance() public {
        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, defaultPermission, defaultRules);

        // Use 30 ether
        vm.prank(target);
        manager.usePermission(permissionId, 30 ether);

        uint256 remaining = manager.getRemainingAllowance(permissionId);
        assertEq(remaining, 70 ether);
    }

    function test_GetRemainingAllowance_ReturnsMaxForNoLimit() public {
        IERC7715PermissionManager.Permission memory noLimitPermission = IERC7715PermissionManager.Permission({
            permissionType: "subscription",
            isAdjustmentAllowed: false,
            data: "" // No spending limit
        });

        vm.prank(granter);
        bytes32 permissionId = manager.grantPermission(grantee, target, noLimitPermission, defaultRules);

        uint256 remaining = manager.getRemainingAllowance(permissionId);
        assertEq(remaining, type(uint256).max);
    }

    // ============ Admin Function Tests ============

    function test_RegisterPermissionType() public {
        vm.prank(owner);
        manager.registerPermissionType("custom-permission");

        assertTrue(manager.isPermissionTypeSupported("custom-permission"));
    }

    function test_UnregisterPermissionType() public {
        vm.prank(owner);
        manager.unregisterPermissionType("subscription");

        assertFalse(manager.isPermissionTypeSupported("subscription"));
    }

    function test_AddAuthorizedExecutor() public {
        address newExecutor = makeAddr("newExecutor");

        vm.prank(owner);
        manager.addAuthorizedExecutor(newExecutor);

        assertTrue(manager.authorizedExecutors(newExecutor));
    }

    function test_RemoveAuthorizedExecutor() public {
        vm.prank(owner);
        manager.removeAuthorizedExecutor(executor);

        assertFalse(manager.authorizedExecutors(executor));
    }

    function test_SetPaused() public {
        vm.prank(owner);
        manager.setPaused(true);

        assertTrue(manager.paused());
    }

    function test_Nonces_IncrementsOnGrant() public {
        assertEq(manager.nonces(granter), 0);

        vm.prank(granter);
        manager.grantPermission(grantee, target, defaultPermission, defaultRules);

        assertEq(manager.nonces(granter), 1);
    }
}
