// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BridgeGuardian} from "../../src/bridge/BridgeGuardian.sol";

contract BridgeGuardianTest is Test {
    BridgeGuardian public guardian;

    address public owner;
    address[] public guardians;
    uint256 public constant THRESHOLD = 3;
    uint256 public constant GUARDIAN_COUNT = 5;

    event GuardianAdded(address indexed guardian, uint256 totalGuardians);
    event GuardianRemoved(address indexed guardian, uint256 totalGuardians);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event ProposalCreated(
        uint256 indexed proposalId, BridgeGuardian.ProposalType proposalType, address indexed proposer, bytes32 dataHash
    );
    event ProposalApproved(uint256 indexed proposalId, address indexed guardian, uint256 approvalCount);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);
    event ProposalCancelled(uint256 indexed proposalId, address indexed canceller);
    event EmergencyPause(address indexed guardian, string reason);
    event EmergencyUnpause(address indexed executor, uint256 proposalId);
    event AddressBlacklisted(address indexed account, string reason);
    event AddressWhitelisted(address indexed account);

    function setUp() public {
        owner = makeAddr("owner");

        // Create 5 guardians
        for (uint256 i = 0; i < GUARDIAN_COUNT; i++) {
            guardians.push(makeAddr(string(abi.encodePacked("guardian", i))));
        }

        vm.prank(owner);
        guardian = new BridgeGuardian(guardians, THRESHOLD);
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertEq(guardian.getGuardianCount(), GUARDIAN_COUNT);
        assertEq(guardian.threshold(), THRESHOLD);

        for (uint256 i = 0; i < GUARDIAN_COUNT; i++) {
            assertTrue(guardian.isGuardian(guardians[i]));
        }
    }

    function test_Constructor_RevertsOnTooFewGuardians() public {
        address[] memory fewGuardians = new address[](2);
        fewGuardians[0] = makeAddr("g1");
        fewGuardians[1] = makeAddr("g2");

        vm.prank(owner);
        vm.expectRevert(BridgeGuardian.InvalidGuardianCount.selector);
        new BridgeGuardian(fewGuardians, 2);
    }

    function test_Constructor_RevertsOnTooManyGuardians() public {
        address[] memory manyGuardians = new address[](16);
        for (uint256 i = 0; i < 16; i++) {
            manyGuardians[i] = makeAddr(string(abi.encodePacked("g", i)));
        }

        vm.prank(owner);
        vm.expectRevert(BridgeGuardian.InvalidGuardianCount.selector);
        new BridgeGuardian(manyGuardians, 8);
    }

    function test_Constructor_RevertsOnZeroThreshold() public {
        vm.prank(owner);
        vm.expectRevert(BridgeGuardian.InvalidThreshold.selector);
        new BridgeGuardian(guardians, 0);
    }

    function test_Constructor_RevertsOnThresholdGreaterThanGuardians() public {
        vm.prank(owner);
        vm.expectRevert(BridgeGuardian.InvalidThreshold.selector);
        new BridgeGuardian(guardians, 6);
    }

    function test_Constructor_RevertsOnZeroAddressGuardian() public {
        address[] memory badGuardians = new address[](3);
        badGuardians[0] = makeAddr("g1");
        badGuardians[1] = address(0);
        badGuardians[2] = makeAddr("g3");

        vm.prank(owner);
        vm.expectRevert(BridgeGuardian.ZeroAddress.selector);
        new BridgeGuardian(badGuardians, 2);
    }

    function test_Constructor_RevertsOnDuplicateGuardian() public {
        address[] memory dupGuardians = new address[](3);
        dupGuardians[0] = makeAddr("g1");
        dupGuardians[1] = makeAddr("g1");
        dupGuardians[2] = makeAddr("g3");

        vm.prank(owner);
        vm.expectRevert(BridgeGuardian.GuardianAlreadyExists.selector);
        new BridgeGuardian(dupGuardians, 2);
    }

    // ============ Emergency Pause Tests ============

    function test_EmergencyPause() public {
        vm.prank(guardians[0]);
        vm.expectEmit(true, false, false, true);
        emit EmergencyPause(guardians[0], "Security threat detected");
        guardian.emergencyPause("Security threat detected");

        assertTrue(guardian.guardianPaused());
        assertEq(guardian.emergencyPauser(), guardians[0]);
    }

    function test_EmergencyPause_RevertsOnNonGuardian() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(BridgeGuardian.NotAGuardian.selector);
        guardian.emergencyPause("test");
    }

    function test_EmergencyPause_RevertsIfAlreadyPaused() public {
        vm.prank(guardians[0]);
        guardian.emergencyPause("First pause");

        vm.prank(guardians[1]);
        vm.expectRevert(BridgeGuardian.AlreadyPaused.selector);
        guardian.emergencyPause("Second pause");
    }

    // ============ Proposal Creation Tests ============

    function test_CreateProposal_Blacklist() public {
        address target = makeAddr("malicious");
        bytes memory data = abi.encode("Suspicious activity");

        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, target, data);

        assertEq(proposalId, 1);

        BridgeGuardian.Proposal memory proposal = guardian.getProposal(proposalId);
        assertEq(proposal.id, 1);
        assertEq(uint256(proposal.proposalType), uint256(BridgeGuardian.ProposalType.Blacklist));
        assertEq(proposal.proposer, guardians[0]);
        assertEq(proposal.target, target);
        assertEq(proposal.approvalCount, 1); // Proposer auto-approves
    }

    function test_CreateProposal_RevertsOnNoneType() public {
        vm.prank(guardians[0]);
        vm.expectRevert(BridgeGuardian.InvalidAction.selector);
        guardian.createProposal(BridgeGuardian.ProposalType.None, address(0), "");
    }

    function test_CreateProposal_RevertsOnNonGuardian() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(BridgeGuardian.NotAGuardian.selector);
        guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), "");
    }

    // ============ Proposal Approval Tests ============

    function test_ApproveProposal() public {
        // Create proposal
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), "");

        // Second guardian approves
        vm.prank(guardians[1]);
        vm.expectEmit(true, true, false, true);
        emit ProposalApproved(proposalId, guardians[1], 2);
        guardian.approveProposal(proposalId);

        BridgeGuardian.Proposal memory proposal = guardian.getProposal(proposalId);
        assertEq(proposal.approvalCount, 2);
    }

    function test_ApproveProposal_ReachesThreshold() public {
        // Create proposal
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), "");

        // Two more guardians approve (total 3 = threshold)
        vm.prank(guardians[1]);
        guardian.approveProposal(proposalId);

        vm.prank(guardians[2]);
        guardian.approveProposal(proposalId);

        BridgeGuardian.Proposal memory proposal = guardian.getProposal(proposalId);
        assertEq(uint256(proposal.status), uint256(BridgeGuardian.ProposalStatus.Approved));
    }

    function test_ApproveProposal_RevertsOnNotFound() public {
        vm.prank(guardians[0]);
        vm.expectRevert(BridgeGuardian.ProposalNotFound.selector);
        guardian.approveProposal(999);
    }

    function test_ApproveProposal_RevertsOnAlreadyVoted() public {
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), "");

        // Proposer tries to vote again
        vm.prank(guardians[0]);
        vm.expectRevert(BridgeGuardian.AlreadyVoted.selector);
        guardian.approveProposal(proposalId);
    }

    function test_ApproveProposal_RevertsOnExpired() public {
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), "");

        // Fast forward past expiry
        vm.warp(block.timestamp + 8 days);

        vm.prank(guardians[1]);
        vm.expectRevert(BridgeGuardian.ProposalExpired.selector);
        guardian.approveProposal(proposalId);
    }

    // ============ Proposal Execution Tests ============

    function test_ExecuteProposal_Blacklist() public {
        address target = makeAddr("malicious");

        // Create and approve proposal
        vm.prank(guardians[0]);
        uint256 proposalId =
            guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, target, abi.encode("Fraud detected"));

        vm.prank(guardians[1]);
        guardian.approveProposal(proposalId);

        vm.prank(guardians[2]);
        guardian.approveProposal(proposalId);

        // Execute
        vm.prank(guardians[0]);
        vm.expectEmit(true, true, false, false);
        emit ProposalExecuted(proposalId, guardians[0]);
        guardian.executeProposal(proposalId);

        assertTrue(guardian.isBlacklisted(target));
    }

    function test_ExecuteProposal_Whitelist() public {
        address target = makeAddr("user");

        // First blacklist the user
        vm.prank(guardians[0]);
        uint256 blacklistId =
            guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, target, abi.encode("Testing"));
        vm.prank(guardians[1]);
        guardian.approveProposal(blacklistId);
        vm.prank(guardians[2]);
        guardian.approveProposal(blacklistId);
        vm.prank(guardians[0]);
        guardian.executeProposal(blacklistId);

        assertTrue(guardian.isBlacklisted(target));

        // Now whitelist
        vm.prank(guardians[0]);
        uint256 whitelistId = guardian.createProposal(BridgeGuardian.ProposalType.Whitelist, target, "");
        vm.prank(guardians[1]);
        guardian.approveProposal(whitelistId);
        vm.prank(guardians[2]);
        guardian.approveProposal(whitelistId);
        vm.prank(guardians[0]);
        guardian.executeProposal(whitelistId);

        assertFalse(guardian.isBlacklisted(target));
    }

    function test_ExecuteProposal_Unpause() public {
        // First pause
        vm.prank(guardians[0]);
        guardian.emergencyPause("Emergency");

        // Create unpause proposal
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Unpause, address(0), "");

        vm.prank(guardians[1]);
        guardian.approveProposal(proposalId);
        vm.prank(guardians[2]);
        guardian.approveProposal(proposalId);

        // Execute unpause
        vm.prank(guardians[0]);
        guardian.executeProposal(proposalId);

        assertFalse(guardian.guardianPaused());
    }

    function test_ExecuteProposal_AddGuardian() public {
        address newGuardian = makeAddr("newGuardian");

        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.AddGuardian, newGuardian, "");

        vm.prank(guardians[1]);
        guardian.approveProposal(proposalId);
        vm.prank(guardians[2]);
        guardian.approveProposal(proposalId);

        vm.prank(guardians[0]);
        guardian.executeProposal(proposalId);

        assertTrue(guardian.isGuardian(newGuardian));
        assertEq(guardian.getGuardianCount(), GUARDIAN_COUNT + 1);
    }

    function test_ExecuteProposal_RemoveGuardian() public {
        // First add an extra guardian so we can remove one
        vm.prank(owner);
        guardian.addGuardianDirect(makeAddr("extraGuardian"));

        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.RemoveGuardian, guardians[4], "");

        vm.prank(guardians[1]);
        guardian.approveProposal(proposalId);
        vm.prank(guardians[2]);
        guardian.approveProposal(proposalId);

        vm.prank(guardians[0]);
        guardian.executeProposal(proposalId);

        assertFalse(guardian.isGuardian(guardians[4]));
    }

    function test_ExecuteProposal_UpdateThreshold() public {
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.UpdateThreshold, address(0), abi.encode(uint256(2)));

        vm.prank(guardians[1]);
        guardian.approveProposal(proposalId);
        vm.prank(guardians[2]);
        guardian.approveProposal(proposalId);

        vm.prank(guardians[0]);
        guardian.executeProposal(proposalId);

        assertEq(guardian.threshold(), 2);
    }

    function test_ExecuteProposal_RevertsOnNotFound() public {
        vm.prank(guardians[0]);
        vm.expectRevert(BridgeGuardian.ProposalNotFound.selector);
        guardian.executeProposal(999);
    }

    function test_ExecuteProposal_RevertsOnInsufficientApprovals() public {
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), "");

        vm.prank(guardians[0]);
        vm.expectRevert(BridgeGuardian.InsufficientApprovals.selector);
        guardian.executeProposal(proposalId);
    }

    function test_ExecuteProposal_RevertsOnAlreadyExecuted() public {
        // Create and fully approve proposal
        vm.prank(guardians[0]);
        uint256 proposalId =
            guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), abi.encode("test"));
        vm.prank(guardians[1]);
        guardian.approveProposal(proposalId);
        vm.prank(guardians[2]);
        guardian.approveProposal(proposalId);

        // Execute once
        vm.prank(guardians[0]);
        guardian.executeProposal(proposalId);

        // Try to execute again
        vm.prank(guardians[0]);
        vm.expectRevert(BridgeGuardian.ProposalAlreadyExecuted.selector);
        guardian.executeProposal(proposalId);
    }

    // ============ Cancel Proposal Tests ============

    function test_CancelProposal_ByProposer() public {
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), "");

        vm.prank(guardians[0]);
        vm.expectEmit(true, true, false, false);
        emit ProposalCancelled(proposalId, guardians[0]);
        guardian.cancelProposal(proposalId);

        BridgeGuardian.Proposal memory proposal = guardian.getProposal(proposalId);
        assertEq(uint256(proposal.status), uint256(BridgeGuardian.ProposalStatus.Cancelled));
    }

    function test_CancelProposal_ByOwner() public {
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), "");

        vm.prank(owner);
        guardian.cancelProposal(proposalId);

        BridgeGuardian.Proposal memory proposal = guardian.getProposal(proposalId);
        assertEq(uint256(proposal.status), uint256(BridgeGuardian.ProposalStatus.Cancelled));
    }

    function test_CancelProposal_RevertsOnUnauthorized() public {
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), "");

        vm.prank(guardians[1]); // Not the proposer
        vm.expectRevert(BridgeGuardian.NotAGuardian.selector);
        guardian.cancelProposal(proposalId);
    }

    // ============ Admin Functions Tests ============

    function test_SetBridgeTarget() public {
        address bridgeContract = makeAddr("bridge");

        vm.prank(owner);
        guardian.setBridgeTarget(bridgeContract);

        assertEq(guardian.bridgeTarget(), bridgeContract);
    }

    function test_SetBridgeTarget_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(BridgeGuardian.ZeroAddress.selector);
        guardian.setBridgeTarget(address(0));
    }

    function test_AddGuardianDirect() public {
        address newGuardian = makeAddr("newGuardian");

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit GuardianAdded(newGuardian, GUARDIAN_COUNT + 1);
        guardian.addGuardianDirect(newGuardian);

        assertTrue(guardian.isGuardian(newGuardian));
    }

    function test_AddGuardianDirect_RevertsOnExisting() public {
        vm.prank(owner);
        vm.expectRevert(BridgeGuardian.GuardianAlreadyExists.selector);
        guardian.addGuardianDirect(guardians[0]);
    }

    function test_RemoveGuardianDirect() public {
        // Add extra guardian first
        vm.prank(owner);
        guardian.addGuardianDirect(makeAddr("extra"));

        vm.prank(owner);
        guardian.updateThresholdDirect(2); // Lower threshold

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit GuardianRemoved(guardians[0], GUARDIAN_COUNT);
        guardian.removeGuardianDirect(guardians[0]);

        assertFalse(guardian.isGuardian(guardians[0]));
    }

    function test_UpdateThresholdDirect() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ThresholdUpdated(THRESHOLD, 2);
        guardian.updateThresholdDirect(2);

        assertEq(guardian.threshold(), 2);
    }

    // ============ View Functions Tests ============

    function test_GetGuardians() public view {
        address[] memory list = guardian.getGuardians();
        assertEq(list.length, GUARDIAN_COUNT);
    }

    function test_GetProposal() public {
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), "");

        BridgeGuardian.Proposal memory proposal = guardian.getProposal(proposalId);
        assertEq(proposal.id, proposalId);
    }

    function test_HasGuardianApproved() public {
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), "");

        assertTrue(guardian.hasGuardianApproved(proposalId, guardians[0]));
        assertFalse(guardian.hasGuardianApproved(proposalId, guardians[1]));
    }

    function test_IsBlacklisted() public {
        assertFalse(guardian.isBlacklisted(makeAddr("random")));
    }

    function test_GetPauseStatus() public {
        vm.prank(guardians[0]);
        guardian.emergencyPause("Test");

        (bool paused, address pauser, uint256 pausedAt) = guardian.getPauseStatus();

        assertTrue(paused);
        assertEq(pauser, guardians[0]);
        assertGt(pausedAt, 0);
    }

    function test_CanExecuteProposal() public {
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), "");

        (bool canExecute, string memory reason) = guardian.canExecuteProposal(proposalId);
        assertFalse(canExecute);
        assertEq(reason, "Insufficient approvals");

        // Add more approvals
        vm.prank(guardians[1]);
        guardian.approveProposal(proposalId);
        vm.prank(guardians[2]);
        guardian.approveProposal(proposalId);

        (canExecute, reason) = guardian.canExecuteProposal(proposalId);
        assertTrue(canExecute);
        assertEq(reason, "");
    }

    // ============ Edge Cases ============

    function test_ProposalExpiration() public {
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, makeAddr("target"), "");

        // Add enough approvals
        vm.prank(guardians[1]);
        guardian.approveProposal(proposalId);
        vm.prank(guardians[2]);
        guardian.approveProposal(proposalId);

        // Fast forward past expiry
        vm.warp(block.timestamp + 8 days);

        vm.prank(guardians[0]);
        vm.expectRevert(BridgeGuardian.ProposalExpired.selector);
        guardian.executeProposal(proposalId);
    }

    function test_UnpauseRequiresNotPaused() public {
        // Create unpause proposal without being paused first
        vm.prank(guardians[0]);
        uint256 proposalId = guardian.createProposal(BridgeGuardian.ProposalType.Unpause, address(0), "");

        vm.prank(guardians[1]);
        guardian.approveProposal(proposalId);
        vm.prank(guardians[2]);
        guardian.approveProposal(proposalId);

        // Should revert because not paused
        vm.prank(guardians[0]);
        vm.expectRevert(BridgeGuardian.NotPaused.selector);
        guardian.executeProposal(proposalId);
    }
}
