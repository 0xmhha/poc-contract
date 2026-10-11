// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { FraudProofVerifier } from "../../src/bridge/FraudProofVerifier.sol";
import { BridgeValidator } from "../../src/bridge/BridgeValidator.sol";
import { OptimisticVerifier } from "../../src/bridge/OptimisticVerifier.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

contract FraudProofVerifierTest is Test {
    FraudProofVerifier public verifier;
    BridgeValidator public bridgeValidatorContract;
    OptimisticVerifier public ov;

    address public owner;
    address public optimisticVerifier;
    address public bridgeValidator;

    // Request data used by _openChallenge
    address public requestToken;
    uint256 public constant REQUEST_AMOUNT = 1000;
    uint256 public constant SOURCE_CHAIN = 1;
    uint256 public constant CHALLENGE_BOND = 1 ether;
    uint256 public constant CHALLENGER_REWARD = 0.5 ether;

    // Test signers for BridgeValidator
    uint256 public signer1Key;
    uint256 public signer2Key;
    uint256 public signer3Key;
    address public signer1;
    address public signer2;
    address public signer3;

    event FraudProofSubmitted(
        bytes32 indexed requestId,
        FraudProofVerifier.FraudProofType proofType,
        address indexed submitter,
        bytes32 proofHash
    );
    event FraudProofVerified(
        bytes32 indexed requestId, FraudProofVerifier.FraudProofType proofType, bool isValid, address indexed verifier
    );
    event OptimisticVerifierUpdated(address oldVerifier, address newVerifier);
    event BridgeValidatorUpdated(address oldValidator, address newValidator);
    event StateRootUpdated(uint256 indexed chainId, bytes32 newRoot, uint256 blockNumber);

    function setUp() public {
        owner = makeAddr("owner");
        requestToken = makeAddr("token");

        // Deploy a real OptimisticVerifier so challenges can be opened and resolved
        vm.prank(owner);
        ov = new OptimisticVerifier(1 hours, CHALLENGE_BOND, CHALLENGER_REWARD);
        optimisticVerifier = address(ov);
        vm.deal(optimisticVerifier, 10 ether);

        // Setup test signers with known private keys
        signer1Key = 0x1;
        signer2Key = 0x2;
        signer3Key = 0x3;
        signer1 = vm.addr(signer1Key);
        signer2 = vm.addr(signer2Key);
        signer3 = vm.addr(signer3Key);

        // Deploy real BridgeValidator with 3 signers, threshold 2
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.prank(owner);
        bridgeValidatorContract = new BridgeValidator(signers, 2);
        bridgeValidator = address(bridgeValidatorContract);

        vm.prank(owner);
        verifier = new FraudProofVerifier();

        vm.prank(owner);
        verifier.setOptimisticVerifier(optimisticVerifier);

        vm.prank(owner);
        verifier.setBridgeValidator(bridgeValidator);

        vm.prank(owner);
        ov.setFraudProofVerifier(address(verifier));
    }

    /// @dev Receives challenger payouts when this contract is the challenger
    receive() external payable { }

    // ============ Helpers ============

    /// @dev Submit a request to the OptimisticVerifier and challenge it as `challenger`
    function _openChallenge(bytes32 requestId, address challenger) internal {
        vm.prank(owner);
        ov.submitRequest(
            requestId, makeAddr("sender"), makeAddr("recipient"), requestToken, REQUEST_AMOUNT, SOURCE_CHAIN, 2
        );
        vm.deal(challenger, CHALLENGE_BOND);
        vm.prank(challenger);
        ov.challengeRequest{ value: CHALLENGE_BOND }(requestId, "fraud");
    }

    /// @dev Open a challenge with this test contract as the challenger
    function _openChallenge(bytes32 requestId) internal {
        _openChallenge(requestId, address(this));
    }

    /// @dev InvalidToken proof whose evidence matches the request opened by _openChallenge
    function _invalidTokenProof(bytes32 requestId) internal view returns (FraudProofVerifier.FraudProof memory) {
        return FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.InvalidToken,
            merkleProof: new bytes32[](0),
            stateProof: "",
            evidence: abi.encode(requestToken, SOURCE_CHAIN)
        });
    }

    /// @dev Root of a two-leaf tree built from `leaf` and a fixed sibling
    function _rootWithSibling(bytes32 leaf) internal pure returns (bytes32 root, bytes32[] memory merkleProof) {
        bytes32 sibling = keccak256("sibling");
        if (uint256(leaf) <= uint256(sibling)) {
            root = keccak256(abi.encodePacked(leaf, sibling));
        } else {
            root = keccak256(abi.encodePacked(sibling, leaf));
        }
        merkleProof = new bytes32[](1);
        merkleProof[0] = sibling;
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsOwner() public view {
        assertEq(verifier.owner(), owner);
    }

    // ============ Submit Fraud Proof Tests ============

    function test_SubmitFraudProof() public {
        bytes32 requestId = keccak256("request1");
        address submitter = makeAddr("submitter");
        _openChallenge(requestId, submitter);

        bytes32[] memory merkleProof = new bytes32[](2);
        merkleProof[0] = keccak256("proof1");
        merkleProof[1] = keccak256("proof2");

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.InvalidAmount,
            merkleProof: merkleProof,
            stateProof: "stateProof",
            evidence: abi.encode(uint256(1000), uint256(900), uint256(1000))
        });

        vm.prank(submitter);
        bytes32 proofHash = verifier.submitFraudProof(proof);

        assertNotEq(proofHash, bytes32(0));
        assertEq(verifier.totalProofsSubmitted(), 1);

        FraudProofVerifier.ProofRecord memory record = verifier.getProofRecord(requestId);
        assertEq(record.submitter, submitter);
        assertEq(uint256(record.proofType), uint256(FraudProofVerifier.FraudProofType.InvalidAmount));
        assertFalse(record.verified);
    }

    function test_SubmitFraudProof_EmitsEvent() public {
        bytes32 requestId = keccak256("request1");
        address submitter = makeAddr("submitter");
        _openChallenge(requestId, submitter);

        bytes32[] memory merkleProof = new bytes32[](1);

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.DoubleSpending,
            merkleProof: merkleProof,
            stateProof: "",
            evidence: abi.encode(bytes32(0), bytes32(0), bytes32(0))
        });

        vm.prank(submitter);
        vm.expectEmit(true, false, true, false);
        emit FraudProofSubmitted(requestId, FraudProofVerifier.FraudProofType.DoubleSpending, submitter, bytes32(0));
        verifier.submitFraudProof(proof);
    }

    function test_SubmitFraudProof_RevertsOnNoneType() public {
        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: keccak256("request1"),
            proofType: FraudProofVerifier.FraudProofType.None,
            merkleProof: new bytes32[](0),
            stateProof: "",
            evidence: ""
        });

        vm.expectRevert(FraudProofVerifier.InvalidProofType.selector);
        verifier.submitFraudProof(proof);
    }

    function test_SubmitFraudProof_RevertsOnInvalidRequestId() public {
        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: bytes32(0),
            proofType: FraudProofVerifier.FraudProofType.InvalidSignature,
            merkleProof: new bytes32[](0),
            stateProof: "",
            evidence: ""
        });

        vm.expectRevert(FraudProofVerifier.InvalidRequestId.selector);
        verifier.submitFraudProof(proof);
    }

    function test_SubmitFraudProof_RevertsOnAlreadySubmitted() public {
        bytes32 requestId = keccak256("request1");
        _openChallenge(requestId);

        FraudProofVerifier.FraudProof memory proof = _invalidTokenProof(requestId);

        verifier.submitFraudProof(proof);

        vm.expectRevert(FraudProofVerifier.ProofAlreadySubmitted.selector);
        verifier.submitFraudProof(proof);
    }

    /// @notice InvalidSignature and ReplayAttack evidence is chosen by the submitter and cannot be
    ///         tied to the challenged request, so both proof types are rejected.
    function test_SubmitFraudProof_RevertsOnUnboundProofTypes() public {
        bytes32 requestId = keccak256("request1");
        _openChallenge(requestId);

        FraudProofVerifier.FraudProof memory proof = _invalidTokenProof(requestId);

        proof.proofType = FraudProofVerifier.FraudProofType.InvalidSignature;
        vm.expectRevert(FraudProofVerifier.InvalidProofType.selector);
        verifier.submitFraudProof(proof);

        proof.proofType = FraudProofVerifier.FraudProofType.ReplayAttack;
        vm.expectRevert(FraudProofVerifier.InvalidProofType.selector);
        verifier.submitFraudProof(proof);
    }

    /// @notice Only the active challenger (or the owner) may submit a proof for a request.
    function test_SubmitFraudProof_RevertsForNonChallenger() public {
        bytes32 requestId = keccak256("request1");
        _openChallenge(requestId);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(FraudProofVerifier.UnauthorizedCaller.selector);
        verifier.submitFraudProof(_invalidTokenProof(requestId));
    }

    /// @notice Proofs can only be submitted while the request is in the Challenged state.
    function test_SubmitFraudProof_RevertsWhenNotChallenged() public {
        bytes32 requestId = keccak256("request1");
        vm.prank(owner);
        ov.submitRequest(
            requestId, makeAddr("sender"), makeAddr("recipient"), requestToken, REQUEST_AMOUNT, SOURCE_CHAIN, 2
        );

        vm.expectRevert(FraudProofVerifier.InvalidRequestId.selector);
        verifier.submitFraudProof(_invalidTokenProof(requestId));

        // Unknown request
        vm.expectRevert(FraudProofVerifier.InvalidRequestId.selector);
        verifier.submitFraudProof(_invalidTokenProof(keccak256("unknown")));
    }

    function test_SubmitFraudProof_AllowsOwner() public {
        bytes32 requestId = keccak256("request1");
        address challenger = makeAddr("challenger");
        _openChallenge(requestId, challenger);

        FraudProofVerifier.FraudProof memory proof = _invalidTokenProof(requestId);
        vm.prank(owner);
        verifier.submitFraudProof(proof);
        vm.prank(owner);
        assertTrue(verifier.verifyFraudProof(proof));

        // The challenger, not the owner, receives the bond and reward
        assertEq(challenger.balance, CHALLENGE_BOND + CHALLENGER_REWARD);
        assertEq(uint256(ov.getRequestStatus(requestId)), uint256(OptimisticVerifier.RequestStatus.Refunded));
    }

    /// @notice A third party can no longer occupy the single proof slot of a request
    ///         and block the honest challenger.
    function test_SubmitFraudProof_ThirdPartyCannotBlockChallenger() public {
        bytes32 requestId = keccak256("request1");
        address challenger = makeAddr("challenger");
        _openChallenge(requestId, challenger);

        FraudProofVerifier.FraudProof memory junk;
        junk.requestId = requestId;
        junk.proofType = FraudProofVerifier.FraudProofType.InvalidAmount;
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(FraudProofVerifier.UnauthorizedCaller.selector);
        verifier.submitFraudProof(junk);

        FraudProofVerifier.FraudProof memory proof = _invalidTokenProof(requestId);
        vm.prank(challenger);
        verifier.submitFraudProof(proof);
        vm.prank(challenger);
        assertTrue(verifier.verifyFraudProof(proof));
        assertEq(challenger.balance, CHALLENGE_BOND + CHALLENGER_REWARD);
    }

    // ============ Verify Fraud Proof Tests ============

    function test_VerifyFraudProof_DoubleSpending() public {
        bytes32 requestId = keccak256("request1");
        _openChallenge(requestId);
        bytes32 txHash1 = keccak256("tx1");
        bytes32 txHash2 = keccak256("tx2");
        bytes32 inputHash = keccak256("input");

        // Compute the Merkle leaf that the contract will verify (bound to the request)
        bytes32 leaf = keccak256(abi.encodePacked(requestId, txHash1, txHash2, inputHash));
        (bytes32 root, bytes32[] memory merkleProof) = _rootWithSibling(leaf);

        // Set the state root for chain 1
        uint256 chainId = 1;
        vm.prank(owner);
        verifier.updateStateRoot(chainId, root, 100);

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.DoubleSpending,
            merkleProof: merkleProof,
            stateProof: abi.encode(chainId),
            evidence: abi.encode(txHash1, txHash2, inputHash)
        });

        verifier.submitFraudProof(proof);

        bool isValid = verifier.verifyFraudProof(proof);
        assertTrue(isValid);
        assertEq(uint256(ov.getRequestStatus(requestId)), uint256(OptimisticVerifier.RequestStatus.Refunded));

        // Check double spend evidence was recorded
        (bytes32 recordedTx1, bytes32 recordedTx2, bool sameInputs) = verifier.doubleSpendEvidence(requestId);
        assertEq(recordedTx1, txHash1);
        assertEq(recordedTx2, txHash2);
        assertTrue(sameInputs);
    }

    /// @notice An attested double-spend leaf that does not commit to the request ID cannot be
    ///         reused against an arbitrary challenged request.
    function test_VerifyFraudProof_DoubleSpending_RejectsLeafNotBoundToRequest() public {
        bytes32 requestId = keccak256("request1");
        _openChallenge(requestId);
        bytes32 txHash1 = keccak256("tx1");
        bytes32 txHash2 = keccak256("tx2");
        bytes32 inputHash = keccak256("input");

        bytes32 unboundLeaf = keccak256(abi.encodePacked(txHash1, txHash2, inputHash));
        (bytes32 root, bytes32[] memory merkleProof) = _rootWithSibling(unboundLeaf);
        vm.prank(owner);
        verifier.updateStateRoot(1, root, 100);

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.DoubleSpending,
            merkleProof: merkleProof,
            stateProof: abi.encode(uint256(1)),
            evidence: abi.encode(txHash1, txHash2, inputHash)
        });

        verifier.submitFraudProof(proof);
        assertFalse(verifier.verifyFraudProof(proof));
        assertEq(uint256(ov.getRequestStatus(requestId)), uint256(OptimisticVerifier.RequestStatus.Challenged));
    }

    function test_VerifyFraudProof_InvalidAmount() public {
        bytes32 requestId = keccak256("request1");
        _openChallenge(requestId);
        uint256 sourceAmount = 1000;
        uint256 targetAmount = 900;
        uint256 expectedAmount = REQUEST_AMOUNT;

        // Compute the Merkle leaf that the contract will verify
        bytes32 leaf = keccak256(abi.encodePacked(requestId, sourceAmount, targetAmount));
        (bytes32 root, bytes32[] memory merkleProof) = _rootWithSibling(leaf);

        // Set the state root for chain 1
        uint256 chainId = 1;
        vm.prank(owner);
        verifier.updateStateRoot(chainId, root, 100);

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.InvalidAmount,
            merkleProof: merkleProof,
            stateProof: abi.encode(chainId),
            evidence: abi.encode(sourceAmount, targetAmount, expectedAmount)
        });

        verifier.submitFraudProof(proof);

        bool isValid = verifier.verifyFraudProof(proof);
        assertTrue(isValid);
    }

    /// @notice The expected amount must be the amount recorded for the request; a submitter-chosen
    ///         value cannot turn a consistent attestation into fraud.
    function test_VerifyFraudProof_InvalidAmount_RejectsUnboundExpectedAmount() public {
        bytes32 requestId = keccak256("request1");
        _openChallenge(requestId);

        // Attested amounts are consistent with the request
        bytes32 leaf = keccak256(abi.encodePacked(requestId, REQUEST_AMOUNT, REQUEST_AMOUNT));
        (bytes32 root, bytes32[] memory merkleProof) = _rootWithSibling(leaf);
        vm.prank(owner);
        verifier.updateStateRoot(1, root, 100);

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.InvalidAmount,
            merkleProof: merkleProof,
            stateProof: abi.encode(uint256(1)),
            evidence: abi.encode(REQUEST_AMOUNT, REQUEST_AMOUNT, uint256(1))
        });

        verifier.submitFraudProof(proof);
        assertFalse(verifier.verifyFraudProof(proof));
    }

    function test_VerifyFraudProof_InvalidToken() public {
        bytes32 requestId = keccak256("request1");
        _openChallenge(requestId);

        // Make sure the request token is NOT authorized
        assertFalse(verifier.isTokenAuthorized(SOURCE_CHAIN, requestToken));

        FraudProofVerifier.FraudProof memory proof = _invalidTokenProof(requestId);

        verifier.submitFraudProof(proof);

        uint256 balanceBefore = address(this).balance;
        bool isValid = verifier.verifyFraudProof(proof);
        assertTrue(isValid);
        assertEq(uint256(ov.getRequestStatus(requestId)), uint256(OptimisticVerifier.RequestStatus.Refunded));
        assertEq(address(this).balance, balanceBefore + CHALLENGE_BOND + CHALLENGER_REWARD);
    }

    /// @notice InvalidToken evidence must name the token and source chain of the challenged request.
    function test_VerifyFraudProof_InvalidToken_RejectsTokenNotInRequest() public {
        bytes32 requestId = keccak256("request1");
        _openChallenge(requestId);

        FraudProofVerifier.FraudProof memory proof = _invalidTokenProof(requestId);
        proof.evidence = abi.encode(address(0xdead), SOURCE_CHAIN);

        verifier.submitFraudProof(proof);
        assertFalse(verifier.verifyFraudProof(proof));
        assertEq(uint256(ov.getRequestStatus(requestId)), uint256(OptimisticVerifier.RequestStatus.Challenged));
    }

    function test_VerifyFraudProof_InvalidToken_RejectsAuthorizedRequestToken() public {
        vm.prank(owner);
        verifier.setAuthorizedToken(SOURCE_CHAIN, requestToken, true);

        bytes32 requestId = keccak256("request1");
        _openChallenge(requestId);

        FraudProofVerifier.FraudProof memory proof = _invalidTokenProof(requestId);
        verifier.submitFraudProof(proof);
        assertFalse(verifier.verifyFraudProof(proof));
    }

    function test_VerifyFraudProof_RevertsOnNotSubmitted() public {
        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: keccak256("nonexistent"),
            proofType: FraudProofVerifier.FraudProofType.InvalidSignature,
            merkleProof: new bytes32[](0),
            stateProof: "",
            evidence: ""
        });

        vm.expectRevert(FraudProofVerifier.InvalidProof.selector);
        verifier.verifyFraudProof(proof);
    }

    function test_VerifyFraudProof_RevertsOnExpired() public {
        bytes32 requestId = keccak256("request1");
        _openChallenge(requestId);

        FraudProofVerifier.FraudProof memory proof = _invalidTokenProof(requestId);

        verifier.submitFraudProof(proof);

        // Fast forward past expiry
        vm.warp(block.timestamp + 8 days);

        vm.expectRevert(FraudProofVerifier.ProofExpired.selector);
        verifier.verifyFraudProof(proof);
    }

    function test_VerifyFraudProof_RevertsForNonSubmitter() public {
        bytes32 requestId = keccak256("request1");
        _openChallenge(requestId);

        FraudProofVerifier.FraudProof memory proof = _invalidTokenProof(requestId);
        verifier.submitFraudProof(proof);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(FraudProofVerifier.UnauthorizedCaller.selector);
        verifier.verifyFraudProof(proof);
    }

    /// @notice A failed OptimisticVerifier notification reverts instead of burning the proof.
    function test_VerifyFraudProof_RevertsWhenNotificationFails() public {
        bytes32 requestId = keccak256("request1");
        _openChallenge(requestId);

        FraudProofVerifier.FraudProof memory proof = _invalidTokenProof(requestId);
        verifier.submitFraudProof(proof);

        // The challenge is resolved elsewhere before the proof is verified
        vm.prank(owner);
        ov.resolveChallenge(requestId, false);

        vm.expectRevert(OptimisticVerifier.RequestNotChallenged.selector);
        verifier.verifyFraudProof(proof);

        assertFalse(verifier.getProofRecord(requestId).verified);
        assertEq(verifier.totalFraudProven(), 0);
    }

    function test_VerifyFraudProof_ReturnsCachedResult() public {
        bytes32 requestId = keccak256("request_cached");
        _openChallenge(requestId);

        FraudProofVerifier.FraudProof memory proof = _invalidTokenProof(requestId);

        verifier.submitFraudProof(proof);

        // First verification
        bool isValid1 = verifier.verifyFraudProof(proof);
        assertTrue(isValid1);

        // Second verification should return cached result
        bool isValid2 = verifier.verifyFraudProof(proof);
        assertTrue(isValid2);
    }

    // ============ Merkle Proof Verification Tests ============

    function test_VerifyMerkleProof() public {
        uint256 chainId = 1;
        bytes32 stateRoot = keccak256("stateRoot");

        // Set state root
        vm.prank(owner);
        verifier.updateStateRoot(chainId, stateRoot, 100);

        // Create valid Merkle proof
        bytes32 leaf = keccak256("leaf");
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("sibling");

        // This will fail because the proof doesn't actually verify
        // but it tests the function call
        bool valid = verifier.verifyMerkleProof(chainId, leaf, proof);
        // Result depends on actual proof validity
        assertFalse(valid); // Our dummy proof won't verify
    }

    function test_VerifyMerkleProof_ReturnsFalseOnNoRoot() public view {
        bool valid = verifier.verifyMerkleProof(999, keccak256("leaf"), new bytes32[](0));
        assertFalse(valid);
    }

    // ============ Admin Functions Tests ============

    function test_SetOptimisticVerifier() public {
        address newVerifier = makeAddr("newVerifier");

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit OptimisticVerifierUpdated(optimisticVerifier, newVerifier);
        verifier.setOptimisticVerifier(newVerifier);

        assertEq(verifier.optimisticVerifier(), newVerifier);
    }

    function test_SetOptimisticVerifier_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(FraudProofVerifier.ZeroAddress.selector);
        verifier.setOptimisticVerifier(address(0));
    }

    function test_SetBridgeValidator() public {
        address newValidator = makeAddr("newValidator");

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit BridgeValidatorUpdated(bridgeValidator, newValidator);
        verifier.setBridgeValidator(newValidator);

        assertEq(verifier.bridgeValidator(), newValidator);
    }

    function test_UpdateStateRoot() public {
        uint256 chainId = 1;
        bytes32 newRoot = keccak256("newRoot");
        uint256 blockNumber = 12_345;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit StateRootUpdated(chainId, newRoot, blockNumber);
        verifier.updateStateRoot(chainId, newRoot, blockNumber);

        (bytes32 root, uint256 blockNum) = verifier.getStateRoot(chainId);
        assertEq(root, newRoot);
        assertEq(blockNum, blockNumber);
    }

    function test_SetAuthorizedToken() public {
        uint256 chainId = 1;
        address token = makeAddr("token");

        vm.prank(owner);
        verifier.setAuthorizedToken(chainId, token, true);

        assertTrue(verifier.isTokenAuthorized(chainId, token));

        vm.prank(owner);
        verifier.setAuthorizedToken(chainId, token, false);

        assertFalse(verifier.isTokenAuthorized(chainId, token));
    }

    function test_BatchSetAuthorizedTokens() public {
        uint256 chainId = 1;
        address[] memory tokens = new address[](3);
        tokens[0] = makeAddr("token1");
        tokens[1] = makeAddr("token2");
        tokens[2] = makeAddr("token3");

        vm.prank(owner);
        verifier.batchSetAuthorizedTokens(chainId, tokens, true);

        for (uint256 i = 0; i < tokens.length; i++) {
            assertTrue(verifier.isTokenAuthorized(chainId, tokens[i]));
        }
    }

    function test_RecordUsedNonce() public {
        bytes32 nonceHash = keccak256("nonce");

        assertFalse(verifier.isNonceUsed(nonceHash));

        vm.prank(owner);
        verifier.recordUsedNonce(nonceHash);

        assertTrue(verifier.isNonceUsed(nonceHash));
    }

    // ============ Pause Tests ============

    function test_Pause() public {
        vm.prank(owner);
        verifier.pause();

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: keccak256("request"),
            proofType: FraudProofVerifier.FraudProofType.InvalidSignature,
            merkleProof: new bytes32[](0),
            stateProof: "",
            evidence: ""
        });

        vm.expectRevert(Pausable.EnforcedPause.selector);
        verifier.submitFraudProof(proof);
    }

    function test_Unpause() public {
        vm.prank(owner);
        verifier.pause();

        vm.prank(owner);
        verifier.unpause();

        bytes32 requestId = keccak256("request");
        _openChallenge(requestId);
        FraudProofVerifier.FraudProof memory proof = _invalidTokenProof(requestId);

        // Should not revert
        verifier.submitFraudProof(proof);
    }

    // ============ View Functions Tests ============

    function test_GetProofRecord() public {
        bytes32 requestId = keccak256("request1");
        address submitter = makeAddr("submitter");
        _openChallenge(requestId, submitter);

        FraudProofVerifier.FraudProof memory proof = _invalidTokenProof(requestId);

        vm.prank(submitter);
        verifier.submitFraudProof(proof);

        FraudProofVerifier.ProofRecord memory record = verifier.getProofRecord(requestId);
        assertEq(record.submitter, submitter);
    }

    function test_GetStateRoot() public {
        uint256 chainId = 1;
        bytes32 root = keccak256("root");
        uint256 blockNum = 100;

        vm.prank(owner);
        verifier.updateStateRoot(chainId, root, blockNum);

        (bytes32 returnedRoot, uint256 returnedBlockNum) = verifier.getStateRoot(chainId);
        assertEq(returnedRoot, root);
        assertEq(returnedBlockNum, blockNum);
    }

    // ============ Access Control Tests ============

    function test_OnlyOwner_SetOptimisticVerifier() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, random));
        verifier.setOptimisticVerifier(makeAddr("newVerifier"));
    }

    function test_OnlyOwner_SetBridgeValidator() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, random));
        verifier.setBridgeValidator(makeAddr("newValidator"));
    }

    function test_OnlyOwner_UpdateStateRoot() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, random));
        verifier.updateStateRoot(1, keccak256("root"), 100);
    }

    function test_OnlyOwner_SetAuthorizedToken() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, random));
        verifier.setAuthorizedToken(1, makeAddr("token"), true);
    }

    function test_OnlyOwner_RecordUsedNonce() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, random));
        verifier.recordUsedNonce(keccak256("nonce"));
    }

    function test_OnlyOwner_Pause() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, random));
        verifier.pause();
    }
}
