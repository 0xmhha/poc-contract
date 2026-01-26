// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { RegulatoryRegistry } from "../../src/compliance/RegulatoryRegistry.sol";

contract RegulatoryRegistryTest is Test {
    RegulatoryRegistry public registry;

    address public admin;
    address public approver1;
    address public approver2;
    address public approver3;
    address public regulator;
    address public targetAccount;

    event RegulatorRegistered(address indexed regulator, string name, string jurisdiction, uint8 accessLevel);
    event RegulatorDeactivated(address indexed regulator, string reason);
    event RegulatorReactivated(address indexed regulator);
    event RegulatorAccessLevelUpdated(address indexed regulator, uint8 oldLevel, uint8 newLevel);
    event MRKPublicKeyUpdated(address indexed regulator, bytes32 keyHash);
    event TraceRequestCreated(
        uint256 indexed requestId,
        address indexed regulator,
        address indexed targetAccount,
        bytes32 legalBasisHash,
        string jurisdiction
    );
    event TraceRequestApproved(uint256 indexed requestId, address indexed approver, uint8 approvalCount);
    event TraceRequestFullyApproved(uint256 indexed requestId);
    event TraceRequestExecuted(uint256 indexed requestId, address indexed executor);
    event TraceRequestCancelled(uint256 indexed requestId, address indexed canceller, string reason);
    event ApproverAdded(address indexed approver);
    event ApproverRemoved(address indexed approver);

    function setUp() public {
        admin = makeAddr("admin");
        approver1 = makeAddr("approver1");
        approver2 = makeAddr("approver2");
        approver3 = makeAddr("approver3");
        regulator = makeAddr("regulator");
        targetAccount = makeAddr("target");

        address[] memory approvers = new address[](3);
        approvers[0] = approver1;
        approvers[1] = approver2;
        approvers[2] = approver3;

        vm.prank(admin);
        registry = new RegulatoryRegistry(approvers);

        vm.prank(admin);
        registry.registerRegulator(regulator, "Test Regulator", "US", 3);
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.APPROVER_ROLE(), approver1));
        assertTrue(registry.hasRole(registry.APPROVER_ROLE(), approver2));
        assertTrue(registry.hasRole(registry.APPROVER_ROLE(), approver3));
        assertEq(registry.nextRequestId(), 1);
    }

    function test_Constructor_RevertsOnWrongApproverCount() public {
        address[] memory twoApprovers = new address[](2);
        twoApprovers[0] = approver1;
        twoApprovers[1] = approver2;

        vm.expectRevert(RegulatoryRegistry.InvalidAddress.selector);
        new RegulatoryRegistry(twoApprovers);
    }

    function test_Constructor_RevertsOnZeroAddress() public {
        address[] memory approvers = new address[](3);
        approvers[0] = approver1;
        approvers[1] = address(0);
        approvers[2] = approver3;

        vm.expectRevert(RegulatoryRegistry.InvalidAddress.selector);
        new RegulatoryRegistry(approvers);
    }

    function test_Constructor_RevertsOnDuplicateApprover() public {
        address[] memory approvers = new address[](3);
        approvers[0] = approver1;
        approvers[1] = approver1;
        approvers[2] = approver3;

        vm.expectRevert(RegulatoryRegistry.InvalidAddress.selector);
        new RegulatoryRegistry(approvers);
    }

    // ============ Regulator Registration Tests ============

    function test_RegisterRegulator_Success() public {
        address newRegulator = makeAddr("newRegulator");

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit RegulatorRegistered(newRegulator, "New Regulator", "EU", 4);
        registry.registerRegulator(newRegulator, "New Regulator", "EU", 4);

        RegulatoryRegistry.Regulator memory reg = registry.getRegulator(newRegulator);
        assertEq(keccak256(bytes(reg.name)), keccak256(bytes("New Regulator")));
        assertEq(keccak256(bytes(reg.jurisdiction)), keccak256(bytes("EU")));
        assertEq(reg.accessLevel, 4);
        assertTrue(reg.isActive);
        assertTrue(registry.hasRole(registry.REGULATOR_ROLE(), newRegulator));
        assertEq(registry.activeRegulatorCount(), 2);
    }

    function test_RegisterRegulator_RevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(RegulatoryRegistry.InvalidAddress.selector);
        registry.registerRegulator(address(0), "Test", "US", 1);
    }

    function test_RegisterRegulator_RevertsOnEmptyName() public {
        vm.prank(admin);
        vm.expectRevert(RegulatoryRegistry.EmptyName.selector);
        registry.registerRegulator(makeAddr("new"), "", "US", 1);
    }

    function test_RegisterRegulator_RevertsOnEmptyJurisdiction() public {
        vm.prank(admin);
        vm.expectRevert(RegulatoryRegistry.InvalidJurisdiction.selector);
        registry.registerRegulator(makeAddr("new"), "Test", "", 1);
    }

    function test_RegisterRegulator_RevertsOnInvalidAccessLevel() public {
        vm.prank(admin);
        vm.expectRevert(RegulatoryRegistry.InvalidAccessLevel.selector);
        registry.registerRegulator(makeAddr("new"), "Test", "US", 0);

        vm.prank(admin);
        vm.expectRevert(RegulatoryRegistry.InvalidAccessLevel.selector);
        registry.registerRegulator(makeAddr("new"), "Test", "US", 6);
    }

    function test_RegisterRegulator_RevertsOnDuplicate() public {
        vm.prank(admin);
        vm.expectRevert(RegulatoryRegistry.RegulatorAlreadyExists.selector);
        registry.registerRegulator(regulator, "Duplicate", "US", 1);
    }

    // ============ Regulator Deactivation Tests ============

    function test_DeactivateRegulator_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit RegulatorDeactivated(regulator, "Test deactivation");
        registry.deactivateRegulator(regulator, "Test deactivation");

        RegulatoryRegistry.Regulator memory reg = registry.getRegulator(regulator);
        assertFalse(reg.isActive);
        assertFalse(registry.hasRole(registry.REGULATOR_ROLE(), regulator));
        assertEq(registry.activeRegulatorCount(), 0);
    }

    function test_DeactivateRegulator_RevertsOnNotFound() public {
        vm.prank(admin);
        vm.expectRevert(RegulatoryRegistry.RegulatorNotFound.selector);
        registry.deactivateRegulator(makeAddr("unknown"), "Test");
    }

    function test_DeactivateRegulator_RevertsOnNotActive() public {
        vm.prank(admin);
        registry.deactivateRegulator(regulator, "First");

        vm.prank(admin);
        vm.expectRevert(RegulatoryRegistry.RegulatorNotActive.selector);
        registry.deactivateRegulator(regulator, "Second");
    }

    // ============ Regulator Reactivation Tests ============

    function test_ReactivateRegulator_Success() public {
        vm.prank(admin);
        registry.deactivateRegulator(regulator, "Test");

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit RegulatorReactivated(regulator);
        registry.reactivateRegulator(regulator);

        RegulatoryRegistry.Regulator memory reg = registry.getRegulator(regulator);
        assertTrue(reg.isActive);
    }

    function test_ReactivateRegulator_RevertsOnAlreadyActive() public {
        vm.prank(admin);
        vm.expectRevert(RegulatoryRegistry.RegulatorAlreadyExists.selector);
        registry.reactivateRegulator(regulator);
    }

    // ============ Access Level Tests ============

    function test_UpdateAccessLevel_Success() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit RegulatorAccessLevelUpdated(regulator, 3, 5);
        registry.updateAccessLevel(regulator, 5);

        RegulatoryRegistry.Regulator memory reg = registry.getRegulator(regulator);
        assertEq(reg.accessLevel, 5);
    }

    function test_UpdateAccessLevel_RevertsOnInvalid() public {
        vm.prank(admin);
        vm.expectRevert(RegulatoryRegistry.InvalidAccessLevel.selector);
        registry.updateAccessLevel(regulator, 0);
    }

    // ============ MRK Public Key Tests ============

    function test_SetMrkPublicKey_Success() public {
        bytes32 keyHash = keccak256("mrk_public_key");

        vm.prank(regulator);
        vm.expectEmit(true, false, false, true);
        emit MRKPublicKeyUpdated(regulator, keyHash);
        registry.setMrkPublicKey(keyHash);

        RegulatoryRegistry.Regulator memory reg = registry.getRegulator(regulator);
        assertEq(reg.mrkPublicKeyHash, keyHash);
    }

    function test_SetMrkPublicKey_RevertsOnInactive() public {
        vm.prank(admin);
        registry.deactivateRegulator(regulator, "Test");

        // After deactivation, regulator loses REGULATOR_ROLE, so AccessControl check fails first
        vm.prank(regulator);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        registry.setMrkPublicKey(keccak256("test"));
    }

    // ============ Trace Request Creation Tests ============

    function test_CreateTraceRequest_Success() public {
        bytes32 legalBasisHash = keccak256("court_order");

        vm.prank(regulator);
        vm.expectEmit(true, true, true, true);
        emit TraceRequestCreated(1, regulator, targetAccount, legalBasisHash, "US");
        uint256 requestId = registry.createTraceRequest(targetAccount, legalBasisHash, 3);

        assertEq(requestId, 1);

        RegulatoryRegistry.TraceRequest memory request = registry.getTraceRequest(1);
        assertEq(request.id, 1);
        assertEq(request.regulator, regulator);
        assertEq(request.targetAccount, targetAccount);
        assertEq(request.legalBasisHash, legalBasisHash);
        assertFalse(request.isApproved);
        assertFalse(request.isExecuted);
        assertFalse(request.isCancelled);
    }

    function test_CreateTraceRequest_RevertsOnZeroTarget() public {
        vm.prank(regulator);
        vm.expectRevert(RegulatoryRegistry.InvalidAddress.selector);
        registry.createTraceRequest(address(0), bytes32(0), 1);
    }

    function test_CreateTraceRequest_RevertsOnZeroLegalBasis() public {
        vm.prank(regulator);
        vm.expectRevert(RegulatoryRegistry.InvalidAddress.selector);
        registry.createTraceRequest(targetAccount, bytes32(0), 1);
    }

    function test_CreateTraceRequest_RevertsOnInsufficientAccessLevel() public {
        // Regulator has level 3, trying to create level 4 request
        vm.prank(regulator);
        vm.expectRevert(RegulatoryRegistry.InsufficientAccessLevel.selector);
        registry.createTraceRequest(targetAccount, keccak256("test"), 4);
    }

    // ============ Trace Request Approval Tests ============

    function test_ApproveTraceRequest_Success() public {
        vm.prank(regulator);
        uint256 requestId = registry.createTraceRequest(targetAccount, keccak256("test"), 1);

        vm.prank(approver1);
        vm.expectEmit(true, true, false, true);
        emit TraceRequestApproved(requestId, approver1, 1);
        registry.approveTraceRequest(requestId);

        assertTrue(registry.hasApproved(requestId, approver1));
    }

    function test_ApproveTraceRequest_FullyApproved() public {
        vm.prank(regulator);
        uint256 requestId = registry.createTraceRequest(targetAccount, keccak256("test"), 1);

        vm.prank(approver1);
        registry.approveTraceRequest(requestId);

        vm.prank(approver2);
        vm.expectEmit(true, false, false, true);
        emit TraceRequestFullyApproved(requestId);
        registry.approveTraceRequest(requestId);

        RegulatoryRegistry.TraceRequest memory request = registry.getTraceRequest(requestId);
        assertTrue(request.isApproved);
        assertEq(request.approvalCount, 2);
    }

    function test_ApproveTraceRequest_RevertsOnNotFound() public {
        vm.prank(approver1);
        vm.expectRevert(RegulatoryRegistry.RequestNotFound.selector);
        registry.approveTraceRequest(999);
    }

    function test_ApproveTraceRequest_RevertsOnExpired() public {
        vm.prank(regulator);
        uint256 requestId = registry.createTraceRequest(targetAccount, keccak256("test"), 1);

        vm.warp(block.timestamp + 8 days);

        vm.prank(approver1);
        vm.expectRevert(RegulatoryRegistry.RequestExpired.selector);
        registry.approveTraceRequest(requestId);
    }

    function test_ApproveTraceRequest_RevertsOnAlreadyApproved() public {
        vm.prank(regulator);
        uint256 requestId = registry.createTraceRequest(targetAccount, keccak256("test"), 1);

        vm.prank(approver1);
        registry.approveTraceRequest(requestId);

        vm.prank(approver1);
        vm.expectRevert(RegulatoryRegistry.AlreadyApproved.selector);
        registry.approveTraceRequest(requestId);
    }

    // ============ Trace Request Execution Tests ============

    function test_ExecuteTraceRequest_Success() public {
        uint256 requestId = _createAndApproveRequest();

        vm.prank(regulator);
        vm.expectEmit(true, true, false, false);
        emit TraceRequestExecuted(requestId, regulator);
        registry.executeTraceRequest(requestId);

        RegulatoryRegistry.TraceRequest memory request = registry.getTraceRequest(requestId);
        assertTrue(request.isExecuted);
    }

    function test_ExecuteTraceRequest_RevertsOnNotApproved() public {
        vm.prank(regulator);
        uint256 requestId = registry.createTraceRequest(targetAccount, keccak256("test"), 1);

        vm.prank(regulator);
        vm.expectRevert(RegulatoryRegistry.InsufficientApprovals.selector);
        registry.executeTraceRequest(requestId);
    }

    function test_ExecuteTraceRequest_RevertsOnAlreadyExecuted() public {
        uint256 requestId = _createAndApproveRequest();

        vm.prank(regulator);
        registry.executeTraceRequest(requestId);

        vm.prank(regulator);
        vm.expectRevert(RegulatoryRegistry.RequestAlreadyExecuted.selector);
        registry.executeTraceRequest(requestId);
    }

    function test_ExecuteTraceRequest_RevertsOnInsufficientAccessLevel() public {
        // Create request with level 3
        vm.prank(regulator);
        uint256 requestId = registry.createTraceRequest(targetAccount, keccak256("test"), 3);

        vm.prank(approver1);
        registry.approveTraceRequest(requestId);
        vm.prank(approver2);
        registry.approveTraceRequest(requestId);

        // Create lower level regulator
        address lowLevelReg = makeAddr("lowLevel");
        vm.prank(admin);
        registry.registerRegulator(lowLevelReg, "Low Level", "US", 1);

        vm.prank(lowLevelReg);
        vm.expectRevert(RegulatoryRegistry.InsufficientAccessLevel.selector);
        registry.executeTraceRequest(requestId);
    }

    // ============ Trace Request Cancellation Tests ============

    function test_CancelTraceRequest_ByCreator() public {
        vm.prank(regulator);
        uint256 requestId = registry.createTraceRequest(targetAccount, keccak256("test"), 1);

        vm.prank(regulator);
        vm.expectEmit(true, true, false, true);
        emit TraceRequestCancelled(requestId, regulator, "No longer needed");
        registry.cancelTraceRequest(requestId, "No longer needed");

        RegulatoryRegistry.TraceRequest memory request = registry.getTraceRequest(requestId);
        assertTrue(request.isCancelled);
    }

    function test_CancelTraceRequest_ByAdmin() public {
        vm.prank(regulator);
        uint256 requestId = registry.createTraceRequest(targetAccount, keccak256("test"), 1);

        vm.prank(admin);
        registry.cancelTraceRequest(requestId, "Admin cancel");

        RegulatoryRegistry.TraceRequest memory request = registry.getTraceRequest(requestId);
        assertTrue(request.isCancelled);
    }

    function test_CancelTraceRequest_RevertsOnUnauthorized() public {
        vm.prank(regulator);
        uint256 requestId = registry.createTraceRequest(targetAccount, keccak256("test"), 1);

        vm.prank(approver1);
        vm.expectRevert(RegulatoryRegistry.NotRequestCreator.selector);
        registry.cancelTraceRequest(requestId, "Unauthorized");
    }

    function test_CancelTraceRequest_RevertsOnExecuted() public {
        uint256 requestId = _createAndApproveRequest();

        vm.prank(regulator);
        registry.executeTraceRequest(requestId);

        vm.prank(regulator);
        vm.expectRevert(RegulatoryRegistry.RequestAlreadyExecuted.selector);
        registry.cancelTraceRequest(requestId, "Too late");
    }

    // ============ Approver Management Tests ============

    function test_ReplaceApprover_Success() public {
        address newApprover = makeAddr("newApprover");

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit ApproverRemoved(approver1);
        vm.expectEmit(true, false, false, false);
        emit ApproverAdded(newApprover);
        registry.replaceApprover(approver1, newApprover);

        assertFalse(registry.hasRole(registry.APPROVER_ROLE(), approver1));
        assertTrue(registry.hasRole(registry.APPROVER_ROLE(), newApprover));
    }

    function test_ReplaceApprover_RevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(RegulatoryRegistry.InvalidAddress.selector);
        registry.replaceApprover(approver1, address(0));
    }

    function test_ReplaceApprover_RevertsOnNotFound() public {
        vm.prank(admin);
        vm.expectRevert(RegulatoryRegistry.ApproverNotFound.selector);
        registry.replaceApprover(makeAddr("unknown"), makeAddr("new"));
    }

    // ============ View Function Tests ============

    function test_IsActiveRegulator() public {
        assertTrue(registry.isActiveRegulator(regulator));
        assertFalse(registry.isActiveRegulator(makeAddr("unknown")));
    }

    function test_GetApprovers() public view {
        address[] memory approvers = registry.getApprovers();
        assertEq(approvers.length, 3);
        assertEq(approvers[0], approver1);
        assertEq(approvers[1], approver2);
        assertEq(approvers[2], approver3);
    }

    function test_CanExecuteTraceRequest() public {
        vm.prank(regulator);
        uint256 requestId = registry.createTraceRequest(targetAccount, keccak256("test"), 1);

        (bool ready, string memory reason) = registry.canExecuteTraceRequest(requestId);
        assertFalse(ready);
        assertEq(reason, "Insufficient approvals");

        vm.prank(approver1);
        registry.approveTraceRequest(requestId);
        vm.prank(approver2);
        registry.approveTraceRequest(requestId);

        (ready, reason) = registry.canExecuteTraceRequest(requestId);
        assertTrue(ready);
        assertEq(reason, "");
    }

    function test_GetPendingRequestCount() public {
        vm.prank(regulator);
        registry.createTraceRequest(targetAccount, keccak256("test1"), 1);

        vm.prank(regulator);
        registry.createTraceRequest(makeAddr("target2"), keccak256("test2"), 1);

        assertEq(registry.getPendingRequestCount(regulator), 2);
    }

    // ============ Pause Tests ============

    function test_Pause() public {
        vm.prank(admin);
        registry.pause();

        assertTrue(registry.paused());

        vm.prank(regulator);
        vm.expectRevert();
        registry.createTraceRequest(targetAccount, keccak256("test"), 1);
    }

    function test_Unpause() public {
        vm.prank(admin);
        registry.pause();

        vm.prank(admin);
        registry.unpause();

        assertFalse(registry.paused());
    }

    // ============ Helper Functions ============

    function _createAndApproveRequest() internal returns (uint256 requestId) {
        vm.prank(regulator);
        requestId = registry.createTraceRequest(targetAccount, keccak256("test"), 1);

        vm.prank(approver1);
        registry.approveTraceRequest(requestId);

        vm.prank(approver2);
        registry.approveTraceRequest(requestId);
    }
}
