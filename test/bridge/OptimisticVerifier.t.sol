// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { OptimisticVerifier } from "../../src/bridge/OptimisticVerifier.sol";

contract OptimisticVerifierTest is Test {
    OptimisticVerifier public verifier;

    address public owner;
    address public bridge;
    address public fraudProofVerifier;

    uint256 public constant CHALLENGE_PERIOD = 6 hours;
    uint256 public constant CHALLENGE_BOND = 1 ether;
    uint256 public constant CHALLENGER_REWARD = 0.5 ether;

    event RequestSubmitted(
        bytes32 indexed requestId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 sourceChain,
        uint256 targetChain,
        uint256 challengeDeadline
    );
    event RequestChallenged(bytes32 indexed requestId, address indexed challenger, uint256 bondAmount, string reason);
    event ChallengeResolved(
        bytes32 indexed requestId, bool challengeSuccessful, address indexed challenger, uint256 reward
    );
    event RequestApproved(bytes32 indexed requestId, uint256 timestamp);
    event RequestExecuted(bytes32 indexed requestId, uint256 timestamp);
    event RequestCancelled(bytes32 indexed requestId, string reason);

    function setUp() public {
        owner = makeAddr("owner");
        bridge = makeAddr("bridge");
        fraudProofVerifier = makeAddr("fraudProofVerifier");

        vm.prank(owner);
        verifier = new OptimisticVerifier(CHALLENGE_PERIOD, CHALLENGE_BOND, CHALLENGER_REWARD);

        // Authorize bridge
        vm.prank(owner);
        verifier.setAuthorizedCaller(bridge, true);

        // Set fraud proof verifier
        vm.prank(owner);
        verifier.setFraudProofVerifier(fraudProofVerifier);

        // Fund the contract for rewards
        vm.deal(address(verifier), 10 ether);
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertEq(verifier.challengePeriod(), CHALLENGE_PERIOD);
        assertEq(verifier.challengeBond(), CHALLENGE_BOND);
        assertEq(verifier.challengerReward(), CHALLENGER_REWARD);
    }

    function test_Constructor_RevertsOnInvalidChallengePeriod() public {
        vm.expectRevert(OptimisticVerifier.InvalidChallengePeriod.selector);
        new OptimisticVerifier(30 minutes, CHALLENGE_BOND, CHALLENGER_REWARD); // Less than 1 hour

        vm.expectRevert(OptimisticVerifier.InvalidChallengePeriod.selector);
        new OptimisticVerifier(8 days, CHALLENGE_BOND, CHALLENGER_REWARD); // More than 7 days
    }

    // ============ Submit Request Tests ============

    function test_SubmitRequest() public {
        bytes32 requestId = keccak256("request1");
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        address token = makeAddr("token");

        vm.prank(bridge);
        uint256 deadline = verifier.submitRequest(requestId, sender, recipient, token, 1000, 1, 137);

        assertEq(deadline, block.timestamp + CHALLENGE_PERIOD);

        OptimisticVerifier.BridgeRequest memory request = verifier.getRequest(requestId);
        assertEq(request.id, requestId);
        assertEq(request.sender, sender);
        assertEq(request.recipient, recipient);
        assertEq(request.token, token);
        assertEq(request.amount, 1000);
        assertEq(request.sourceChain, 1);
        assertEq(request.targetChain, 137);
        assertEq(uint256(request.status), uint256(OptimisticVerifier.RequestStatus.Pending));
    }

    function test_SubmitRequest_EmitsEvent() public {
        bytes32 requestId = keccak256("request1");
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        address token = makeAddr("token");

        vm.prank(bridge);
        vm.expectEmit(true, true, true, true);
        emit RequestSubmitted(requestId, sender, recipient, token, 1000, 1, 137, block.timestamp + CHALLENGE_PERIOD);
        verifier.submitRequest(requestId, sender, recipient, token, 1000, 1, 137);
    }

    function test_SubmitRequest_RevertsOnDuplicate() public {
        bytes32 requestId = keccak256("request1");

        vm.prank(bridge);
        verifier.submitRequest(requestId, makeAddr("sender"), makeAddr("recipient"), makeAddr("token"), 1000, 1, 137);

        vm.prank(bridge);
        vm.expectRevert(OptimisticVerifier.RequestAlreadyExists.selector);
        verifier.submitRequest(requestId, makeAddr("sender"), makeAddr("recipient"), makeAddr("token"), 1000, 1, 137);
    }

    function test_SubmitRequest_RevertsOnZeroSender() public {
        vm.prank(bridge);
        vm.expectRevert(OptimisticVerifier.ZeroAddress.selector);
        verifier.submitRequest(keccak256("req"), address(0), makeAddr("recipient"), makeAddr("token"), 1000, 1, 137);
    }

    function test_SubmitRequest_RevertsOnUnauthorized() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(OptimisticVerifier.UnauthorizedCaller.selector);
        verifier.submitRequest(
            keccak256("req"), makeAddr("sender"), makeAddr("recipient"), makeAddr("token"), 1000, 1, 137
        );
    }

    // ============ Challenge Request Tests ============

    function test_ChallengeRequest() public {
        bytes32 requestId = _createPendingRequest();
        address challenger = makeAddr("challenger");
        vm.deal(challenger, 2 ether);

        vm.prank(challenger);
        vm.expectEmit(true, true, false, true);
        emit RequestChallenged(requestId, challenger, CHALLENGE_BOND, "Suspicious activity");
        verifier.challengeRequest{ value: CHALLENGE_BOND }(requestId, "Suspicious activity");

        OptimisticVerifier.BridgeRequest memory request = verifier.getRequest(requestId);
        assertEq(uint256(request.status), uint256(OptimisticVerifier.RequestStatus.Challenged));

        OptimisticVerifier.Challenge memory challenge = verifier.getChallenge(requestId);
        assertEq(challenge.challenger, challenger);
        assertEq(challenge.bondAmount, CHALLENGE_BOND);
    }

    function test_ChallengeRequest_RevertsOnNotFound() public {
        address challenger = makeAddr("challenger");
        vm.deal(challenger, 2 ether);

        vm.prank(challenger);
        vm.expectRevert(OptimisticVerifier.RequestNotFound.selector);
        verifier.challengeRequest{ value: CHALLENGE_BOND }(keccak256("nonexistent"), "test");
    }

    function test_ChallengeRequest_RevertsOnNotPending() public {
        bytes32 requestId = _createPendingRequest();

        // Advance past challenge period
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        verifier.approveRequest(requestId);

        address challenger = makeAddr("challenger");
        vm.deal(challenger, 2 ether);

        vm.prank(challenger);
        vm.expectRevert(OptimisticVerifier.RequestNotPending.selector);
        verifier.challengeRequest{ value: CHALLENGE_BOND }(requestId, "test");
    }

    function test_ChallengeRequest_RevertsOnPeriodEnded() public {
        bytes32 requestId = _createPendingRequest();

        // Advance to exact end of challenge period
        vm.warp(block.timestamp + CHALLENGE_PERIOD);

        address challenger = makeAddr("challenger");
        vm.deal(challenger, 2 ether);

        vm.prank(challenger);
        vm.expectRevert(OptimisticVerifier.ChallengePeriodEnded.selector);
        verifier.challengeRequest{ value: CHALLENGE_BOND }(requestId, "test");
    }

    function test_ChallengeRequest_RevertsOnInsufficientBond() public {
        bytes32 requestId = _createPendingRequest();
        address challenger = makeAddr("challenger");
        vm.deal(challenger, 0.5 ether);

        vm.prank(challenger);
        vm.expectRevert(OptimisticVerifier.InsufficientChallengeBond.selector);
        verifier.challengeRequest{ value: 0.5 ether }(requestId, "test");
    }

    // ============ Resolve Challenge Tests ============

    function test_ResolveChallenge_Success() public {
        bytes32 requestId = _createChallengedRequest();

        address challenger = verifier.getChallenge(requestId).challenger;
        uint256 challengerBalanceBefore = challenger.balance;

        vm.prank(fraudProofVerifier);
        verifier.resolveChallenge(requestId, true);

        OptimisticVerifier.BridgeRequest memory request = verifier.getRequest(requestId);
        assertEq(uint256(request.status), uint256(OptimisticVerifier.RequestStatus.Refunded));

        // Challenger should receive bond + reward
        assertEq(challenger.balance, challengerBalanceBefore + CHALLENGE_BOND + CHALLENGER_REWARD);
    }

    function test_ResolveChallenge_Failure() public {
        bytes32 requestId = _createChallengedRequest();

        address challenger = verifier.getChallenge(requestId).challenger;
        uint256 challengerBalanceBefore = challenger.balance;

        vm.prank(fraudProofVerifier);
        verifier.resolveChallenge(requestId, false);

        OptimisticVerifier.BridgeRequest memory request = verifier.getRequest(requestId);
        assertEq(uint256(request.status), uint256(OptimisticVerifier.RequestStatus.Approved));

        // Challenger forfeits bond
        assertEq(challenger.balance, challengerBalanceBefore);
    }

    function test_ResolveChallenge_RevertsOnUnauthorized() public {
        bytes32 requestId = _createChallengedRequest();

        vm.prank(makeAddr("random"));
        vm.expectRevert(OptimisticVerifier.UnauthorizedCaller.selector);
        verifier.resolveChallenge(requestId, true);
    }

    function test_ResolveChallenge_RevertsOnNotChallenged() public {
        bytes32 requestId = _createPendingRequest();

        vm.prank(fraudProofVerifier);
        vm.expectRevert(OptimisticVerifier.RequestNotChallenged.selector);
        verifier.resolveChallenge(requestId, true);
    }

    // ============ Approve Request Tests ============

    function test_ApproveRequest() public {
        bytes32 requestId = _createPendingRequest();

        // Advance past challenge period
        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        vm.expectEmit(true, false, false, true);
        emit RequestApproved(requestId, block.timestamp);
        verifier.approveRequest(requestId);

        OptimisticVerifier.BridgeRequest memory request = verifier.getRequest(requestId);
        assertEq(uint256(request.status), uint256(OptimisticVerifier.RequestStatus.Approved));
    }

    function test_ApproveRequest_RevertsOnPeriodNotEnded() public {
        bytes32 requestId = _createPendingRequest();

        vm.expectRevert(OptimisticVerifier.ChallengePeriodNotEnded.selector);
        verifier.approveRequest(requestId);
    }

    function test_ApproveRequest_RevertsOnNotPending() public {
        bytes32 requestId = _createPendingRequest();

        // Challenge the request
        address challenger = makeAddr("challenger");
        vm.deal(challenger, 2 ether);
        vm.prank(challenger);
        verifier.challengeRequest{ value: CHALLENGE_BOND }(requestId, "test");

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        vm.expectRevert(OptimisticVerifier.RequestNotPending.selector);
        verifier.approveRequest(requestId);
    }

    // ============ Mark Executed Tests ============

    function test_MarkExecuted() public {
        bytes32 requestId = _createApprovedRequest();

        vm.prank(bridge);
        vm.expectEmit(true, false, false, true);
        emit RequestExecuted(requestId, block.timestamp);
        verifier.markExecuted(requestId);

        OptimisticVerifier.BridgeRequest memory request = verifier.getRequest(requestId);
        assertEq(uint256(request.status), uint256(OptimisticVerifier.RequestStatus.Executed));
    }

    function test_MarkExecuted_RevertsOnNotApproved() public {
        bytes32 requestId = _createPendingRequest();

        vm.prank(bridge);
        vm.expectRevert(OptimisticVerifier.InvalidStatus.selector);
        verifier.markExecuted(requestId);
    }

    function test_MarkExecuted_RevertsOnAlreadyExecuted() public {
        bytes32 requestId = _createApprovedRequest();

        vm.prank(bridge);
        verifier.markExecuted(requestId);

        vm.prank(bridge);
        vm.expectRevert(OptimisticVerifier.RequestAlreadyExecuted.selector);
        verifier.markExecuted(requestId);
    }

    // ============ Cancel Request Tests ============

    function test_CancelRequest() public {
        bytes32 requestId = _createPendingRequest();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit RequestCancelled(requestId, "Admin decision");
        verifier.cancelRequest(requestId, "Admin decision");

        OptimisticVerifier.BridgeRequest memory request = verifier.getRequest(requestId);
        assertEq(uint256(request.status), uint256(OptimisticVerifier.RequestStatus.Cancelled));
    }

    function test_CancelRequest_RefundsChallengerBond() public {
        bytes32 requestId = _createChallengedRequest();

        address challenger = verifier.getChallenge(requestId).challenger;
        uint256 challengerBalanceBefore = challenger.balance;

        vm.prank(owner);
        verifier.cancelRequest(requestId, "Admin decision");

        // Challenger should get bond back
        assertEq(challenger.balance, challengerBalanceBefore + CHALLENGE_BOND);
    }

    function test_CancelRequest_RevertsOnAlreadyExecuted() public {
        bytes32 requestId = _createApprovedRequest();

        vm.prank(bridge);
        verifier.markExecuted(requestId);

        vm.prank(owner);
        vm.expectRevert(OptimisticVerifier.RequestAlreadyExecuted.selector);
        verifier.cancelRequest(requestId, "test");
    }

    // ============ Admin Functions Tests ============

    function test_SetChallengePeriod() public {
        vm.prank(owner);
        verifier.setChallengePeriod(12 hours);

        assertEq(verifier.challengePeriod(), 12 hours);
    }

    function test_SetChallengePeriod_RevertsOnInvalid() public {
        vm.prank(owner);
        vm.expectRevert(OptimisticVerifier.InvalidChallengePeriod.selector);
        verifier.setChallengePeriod(30 minutes);
    }

    function test_SetChallengeBond() public {
        vm.prank(owner);
        verifier.setChallengeBond(2 ether);

        assertEq(verifier.challengeBond(), 2 ether);
    }

    function test_SetChallengeBond_RevertsOnTooLow() public {
        vm.prank(owner);
        vm.expectRevert(OptimisticVerifier.InsufficientChallengeBond.selector);
        verifier.setChallengeBond(0.001 ether);
    }

    function test_SetChallengerReward() public {
        vm.prank(owner);
        verifier.setChallengerReward(1 ether);

        assertEq(verifier.challengerReward(), 1 ether);
    }

    function test_SetFraudProofVerifier() public {
        address newVerifier = makeAddr("newVerifier");

        vm.prank(owner);
        verifier.setFraudProofVerifier(newVerifier);

        assertEq(verifier.fraudProofVerifier(), newVerifier);
    }

    function test_SetAuthorizedCaller() public {
        address newCaller = makeAddr("newCaller");

        vm.prank(owner);
        verifier.setAuthorizedCaller(newCaller, true);

        assertTrue(verifier.isAuthorizedCaller(newCaller));
    }

    function test_WithdrawFees() public {
        address recipient = makeAddr("recipient");
        uint256 balanceBefore = recipient.balance;

        vm.prank(owner);
        verifier.withdrawFees(recipient, 1 ether);

        assertEq(recipient.balance, balanceBefore + 1 ether);
    }

    // ============ View Functions Tests ============

    function test_CanApprove() public {
        bytes32 requestId = _createPendingRequest();

        assertFalse(verifier.canApprove(requestId));

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);

        assertTrue(verifier.canApprove(requestId));
    }

    function test_CanChallenge() public {
        bytes32 requestId = _createPendingRequest();

        assertTrue(verifier.canChallenge(requestId));

        vm.warp(block.timestamp + CHALLENGE_PERIOD);

        assertFalse(verifier.canChallenge(requestId));
    }

    function test_GetTimeRemaining() public {
        bytes32 requestId = _createPendingRequest();

        uint256 timeRemaining = verifier.getTimeRemaining(requestId);
        assertEq(timeRemaining, CHALLENGE_PERIOD);

        vm.warp(block.timestamp + 1 hours);
        timeRemaining = verifier.getTimeRemaining(requestId);
        assertEq(timeRemaining, CHALLENGE_PERIOD - 1 hours);

        vm.warp(block.timestamp + CHALLENGE_PERIOD);
        timeRemaining = verifier.getTimeRemaining(requestId);
        assertEq(timeRemaining, 0);
    }

    function test_GetRequestStatus() public {
        bytes32 requestId = _createPendingRequest();

        assertEq(uint256(verifier.getRequestStatus(requestId)), uint256(OptimisticVerifier.RequestStatus.Pending));
    }

    // ============ Pause Tests ============

    function test_Pause() public {
        vm.prank(owner);
        verifier.pause();

        vm.prank(bridge);
        vm.expectRevert();
        verifier.submitRequest(
            keccak256("req"), makeAddr("sender"), makeAddr("recipient"), makeAddr("token"), 1000, 1, 137
        );
    }

    function test_Unpause() public {
        vm.prank(owner);
        verifier.pause();

        vm.prank(owner);
        verifier.unpause();

        vm.prank(bridge);
        verifier.submitRequest(
            keccak256("req"), makeAddr("sender"), makeAddr("recipient"), makeAddr("token"), 1000, 1, 137
        );
    }

    // ============ Receive Tests ============

    function test_ReceiveEther() public {
        uint256 balanceBefore = address(verifier).balance;

        vm.deal(makeAddr("sender"), 1 ether);
        vm.prank(makeAddr("sender"));
        (bool success,) = address(verifier).call{ value: 1 ether }("");

        assertTrue(success);
        assertEq(address(verifier).balance, balanceBefore + 1 ether);
    }

    // ============ Helper Functions ============

    function _createPendingRequest() internal returns (bytes32) {
        bytes32 requestId = keccak256(abi.encodePacked("request", block.timestamp));

        vm.prank(bridge);
        verifier.submitRequest(requestId, makeAddr("sender"), makeAddr("recipient"), makeAddr("token"), 1000, 1, 137);

        return requestId;
    }

    function _createChallengedRequest() internal returns (bytes32) {
        bytes32 requestId = _createPendingRequest();

        address challenger = makeAddr("challenger");
        vm.deal(challenger, 2 ether);

        vm.prank(challenger);
        verifier.challengeRequest{ value: CHALLENGE_BOND }(requestId, "Challenge reason");

        return requestId;
    }

    function _createApprovedRequest() internal returns (bytes32) {
        bytes32 requestId = _createPendingRequest();

        vm.warp(block.timestamp + CHALLENGE_PERIOD + 1);
        verifier.approveRequest(requestId);

        return requestId;
    }
}
