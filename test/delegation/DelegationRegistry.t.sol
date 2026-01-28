// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { DelegationRegistry, IDelegationRegistry } from "../../src/delegation/DelegationRegistry.sol";

/**
 * @title DelegationRegistryTest
 * @notice Unit and integration tests for DelegationRegistry
 */
contract DelegationRegistryTest is Test {
    DelegationRegistry public registry;

    address public owner;
    address public delegator;
    address public delegatee;
    address public admin;

    event DelegationCreated(
        bytes32 indexed delegationId,
        address indexed delegator,
        address indexed delegatee,
        IDelegationRegistry.DelegationType delegationType,
        uint256 endTime
    );
    event DelegationRevoked(bytes32 indexed delegationId, address indexed revokedBy);

    function setUp() public {
        owner = makeAddr("owner");
        delegator = makeAddr("delegator");
        delegatee = makeAddr("delegatee");
        admin = makeAddr("admin");

        vm.prank(owner);
        registry = new DelegationRegistry();
    }

    /* //////////////////////////////////////////////////////////////
                        BASIC FUNCTIONALITY TESTS
    ////////////////////////////////////////////////////////////// */

    function test_Constructor() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(registry.hasRole(registry.ADMIN_ROLE(), owner));
    }

    function test_CreateDelegation_Full() public {
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);

        // Verify delegation was created
        assertTrue(delegationId != bytes32(0), "Delegation ID should not be zero");

        // Verify delegation details
        IDelegationRegistry.Delegation memory delegation = registry.getDelegation(delegationId);
        assertEq(delegation.delegator, delegator);
        assertEq(delegation.delegatee, delegatee);
        assertEq(uint8(delegation.delegationType), uint8(IDelegationRegistry.DelegationType.FULL));
        assertEq(uint8(delegation.status), uint8(IDelegationRegistry.DelegationStatus.ACTIVE));
        assertEq(delegation.startTime, block.timestamp);
        assertEq(delegation.endTime, block.timestamp + 7 days);
    }

    function test_CreateDelegation_Limited() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("transfer(address,uint256)"));
        selectors[1] = bytes4(keccak256("approve(address,uint256)"));

        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.LIMITED,
            duration: 7 days,
            spendingLimit: 100 ether,
            allowedSelectors: selectors
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);

        IDelegationRegistry.Delegation memory delegation = registry.getDelegation(delegationId);
        assertEq(uint8(delegation.delegationType), uint8(IDelegationRegistry.DelegationType.LIMITED));
        assertEq(delegation.spendingLimit, 100 ether);
    }

    function test_CreateDelegation_WithSpendingLimit() public {
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.EXECUTOR,
            duration: 30 days,
            spendingLimit: 1000 ether,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);

        IDelegationRegistry.Delegation memory delegation = registry.getDelegation(delegationId);
        assertEq(delegation.spendingLimit, 1000 ether);
        assertEq(delegation.spentAmount, 0);
    }

    /* //////////////////////////////////////////////////////////////
                        VALIDATION TESTS
    ////////////////////////////////////////////////////////////// */

    function test_CreateDelegation_InvalidDelegatee_Zero() public {
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: address(0),
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        vm.expectRevert(IDelegationRegistry.InvalidDelegatee.selector);
        registry.createDelegation(params);
    }

    function test_CreateDelegation_InvalidDelegatee_Self() public {
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegator, // Self delegation
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        vm.expectRevert(IDelegationRegistry.InvalidDelegatee.selector);
        registry.createDelegation(params);
    }

    function test_CreateDelegation_InvalidDuration_TooShort() public {
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 30 minutes, // Too short
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        vm.expectRevert(IDelegationRegistry.InvalidDuration.selector);
        registry.createDelegation(params);
    }

    function test_CreateDelegation_InvalidDuration_TooLong() public {
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 400 days, // Too long
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        vm.expectRevert(IDelegationRegistry.InvalidDuration.selector);
        registry.createDelegation(params);
    }

    /* //////////////////////////////////////////////////////////////
                        REVOCATION TESTS
    ////////////////////////////////////////////////////////////// */

    function test_RevokeDelegation_ByDelegator() public {
        // Create delegation
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);

        // Revoke delegation
        vm.prank(delegator);
        registry.revokeDelegation(delegationId);

        // Verify status
        IDelegationRegistry.Delegation memory delegation = registry.getDelegation(delegationId);
        assertEq(uint8(delegation.status), uint8(IDelegationRegistry.DelegationStatus.REVOKED));
    }

    function test_RevokeDelegation_ByAdmin() public {
        // Create delegation
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);

        // Admin revokes
        vm.prank(owner);
        registry.revokeDelegation(delegationId);

        IDelegationRegistry.Delegation memory delegation = registry.getDelegation(delegationId);
        assertEq(uint8(delegation.status), uint8(IDelegationRegistry.DelegationStatus.REVOKED));
    }

    function test_RevokeDelegation_Unauthorized() public {
        // Create delegation
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);

        // Random user tries to revoke
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(IDelegationRegistry.UnauthorizedDelegatee.selector);
        registry.revokeDelegation(delegationId);
    }

    /* //////////////////////////////////////////////////////////////
                        SELECTOR VALIDATION TESTS
    ////////////////////////////////////////////////////////////// */

    function test_IsDelegationValidForSelector_Full() public {
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);

        // Full delegation should allow any selector
        bytes4 anySelector = bytes4(keccak256("anyFunction()"));
        assertTrue(registry.isDelegationValidForSelector(delegationId, anySelector));
    }

    function test_IsDelegationValidForSelector_Limited() public {
        bytes4 allowedSelector = bytes4(keccak256("transfer(address,uint256)"));
        bytes4 disallowedSelector = bytes4(keccak256("burn(uint256)"));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = allowedSelector;

        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.LIMITED,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: selectors
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);

        // Allowed selector should pass
        assertTrue(registry.isDelegationValidForSelector(delegationId, allowedSelector));

        // Disallowed selector should fail
        assertFalse(registry.isDelegationValidForSelector(delegationId, disallowedSelector));
    }

    /* //////////////////////////////////////////////////////////////
                        SPENDING LIMIT TESTS
    ////////////////////////////////////////////////////////////// */

    function test_UseDelegation_WithinLimit() public {
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.EXECUTOR,
            duration: 7 days,
            spendingLimit: 100 ether,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);

        // Use delegation within limit
        vm.prank(delegatee);
        registry.useDelegation(delegationId, 50 ether);

        IDelegationRegistry.Delegation memory delegation = registry.getDelegation(delegationId);
        assertEq(delegation.spentAmount, 50 ether);

        // Check remaining
        assertEq(registry.getRemainingSpendingLimit(delegationId), 50 ether);
    }

    function test_UseDelegation_ExceedsLimit() public {
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.EXECUTOR,
            duration: 7 days,
            spendingLimit: 100 ether,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);

        // Attempt to exceed limit
        vm.prank(delegatee);
        vm.expectRevert(IDelegationRegistry.SpendingLimitExceeded.selector);
        registry.useDelegation(delegationId, 150 ether);
    }

    function test_UseDelegation_NoLimit() public {
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.EXECUTOR,
            duration: 7 days,
            spendingLimit: 0, // No limit
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);

        // Should allow any amount
        vm.prank(delegatee);
        registry.useDelegation(delegationId, 1_000_000 ether);

        // Remaining should be unlimited
        assertEq(registry.getRemainingSpendingLimit(delegationId), type(uint256).max);
    }

    /* //////////////////////////////////////////////////////////////
                        EXPIRATION TESTS
    ////////////////////////////////////////////////////////////// */

    function test_UseDelegation_Expired() public {
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.EXECUTOR,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);

        // Warp past expiration
        vm.warp(block.timestamp + 8 days);

        // Attempt to use expired delegation
        vm.prank(delegatee);
        vm.expectRevert(IDelegationRegistry.DelegationExpiredError.selector);
        registry.useDelegation(delegationId, 1 ether);
    }

    /* //////////////////////////////////////////////////////////////
                        QUERY TESTS
    ////////////////////////////////////////////////////////////// */

    function test_HasDelegation() public {
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        registry.createDelegation(params);

        // Should find active delegation
        assertTrue(registry.hasDelegation(delegator, delegatee));

        // Should not find non-existent delegation
        address other = makeAddr("other");
        assertFalse(registry.hasDelegation(delegator, other));
    }

    function test_GetDelegatorDelegations() public {
        // Create multiple delegations
        address delegatee2 = makeAddr("delegatee2");

        IDelegationRegistry.DelegationParams memory params1 = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        IDelegationRegistry.DelegationParams memory params2 = IDelegationRegistry.DelegationParams({
            delegatee: delegatee2,
            delegationType: IDelegationRegistry.DelegationType.EXECUTOR,
            duration: 14 days,
            spendingLimit: 100 ether,
            allowedSelectors: new bytes4[](0)
        });

        vm.startPrank(delegator);
        registry.createDelegation(params1);
        registry.createDelegation(params2);
        vm.stopPrank();

        bytes32[] memory delegations = registry.getDelegatorDelegations(delegator);
        assertEq(delegations.length, 2);
    }

    /* //////////////////////////////////////////////////////////////
                        ADMIN TESTS
    ////////////////////////////////////////////////////////////// */

    function test_Pause() public {
        vm.prank(owner);
        registry.pause();

        // Operations should fail when paused
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        vm.expectRevert(); // EnforcedPause
        registry.createDelegation(params);
    }

    function test_Unpause() public {
        vm.startPrank(owner);
        registry.pause();
        registry.unpause();
        vm.stopPrank();

        // Operations should work after unpause
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);
        assertTrue(delegationId != bytes32(0));
    }

    function test_ForceExpireDelegation() public {
        IDelegationRegistry.DelegationParams memory params = IDelegationRegistry.DelegationParams({
            delegatee: delegatee,
            delegationType: IDelegationRegistry.DelegationType.FULL,
            duration: 7 days,
            spendingLimit: 0,
            allowedSelectors: new bytes4[](0)
        });

        vm.prank(delegator);
        bytes32 delegationId = registry.createDelegation(params);

        // Admin force expires
        vm.prank(owner);
        registry.forceExpireDelegation(delegationId);

        IDelegationRegistry.Delegation memory delegation = registry.getDelegation(delegationId);
        assertEq(uint8(delegation.status), uint8(IDelegationRegistry.DelegationStatus.EXPIRED));
    }
}
