// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FraudProofVerifier} from "../../src/bridge/FraudProofVerifier.sol";
import {BridgeValidator} from "../../src/bridge/BridgeValidator.sol";

contract FraudProofVerifierTest is Test {
    FraudProofVerifier public verifier;
    BridgeValidator public bridgeValidatorContract;

    address public owner;
    address public optimisticVerifier;
    address public bridgeValidator;

    // Test signers for BridgeValidator
    uint256 public signer1Key;
    uint256 public signer2Key;
    uint256 public signer3Key;
    address public signer1;
    address public signer2;
    address public signer3;

    event FraudProofSubmitted(
        bytes32 indexed requestId, FraudProofVerifier.FraudProofType proofType, address indexed submitter, bytes32 proofHash
    );
    event FraudProofVerified(
        bytes32 indexed requestId, FraudProofVerifier.FraudProofType proofType, bool isValid, address indexed verifier
    );
    event OptimisticVerifierUpdated(address oldVerifier, address newVerifier);
    event BridgeValidatorUpdated(address oldValidator, address newValidator);
    event StateRootUpdated(uint256 indexed chainId, bytes32 newRoot, uint256 blockNumber);

    function setUp() public {
        owner = makeAddr("owner");
        optimisticVerifier = makeAddr("optimisticVerifier");

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
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsOwner() public view {
        assertEq(verifier.owner(), owner);
    }

    // ============ Submit Fraud Proof Tests ============

    function test_SubmitFraudProof() public {
        bytes32 requestId = keccak256("request1");
        bytes32[] memory merkleProof = new bytes32[](2);
        merkleProof[0] = keccak256("proof1");
        merkleProof[1] = keccak256("proof2");

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.InvalidSignature,
            merkleProof: merkleProof,
            stateProof: "stateProof",
            evidence: abi.encode(keccak256("messageHash"), new bytes[](1), new address[](1))
        });

        address submitter = makeAddr("submitter");
        vm.prank(submitter);
        bytes32 proofHash = verifier.submitFraudProof(proof);

        assertNotEq(proofHash, bytes32(0));
        assertEq(verifier.totalProofsSubmitted(), 1);

        FraudProofVerifier.ProofRecord memory record = verifier.getProofRecord(requestId);
        assertEq(record.submitter, submitter);
        assertEq(uint256(record.proofType), uint256(FraudProofVerifier.FraudProofType.InvalidSignature));
        assertFalse(record.verified);
    }

    function test_SubmitFraudProof_EmitsEvent() public {
        bytes32 requestId = keccak256("request1");
        bytes32[] memory merkleProof = new bytes32[](1);

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.DoubleSpending,
            merkleProof: merkleProof,
            stateProof: "",
            evidence: abi.encode(bytes32(0), bytes32(0), bytes32(0))
        });

        address submitter = makeAddr("submitter");
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

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.InvalidSignature,
            merkleProof: new bytes32[](0),
            stateProof: "",
            evidence: ""
        });

        verifier.submitFraudProof(proof);

        vm.expectRevert(FraudProofVerifier.ProofAlreadySubmitted.selector);
        verifier.submitFraudProof(proof);
    }

    // ============ Verify Fraud Proof Tests ============

    function test_VerifyFraudProof_InvalidSignature() public {
        bytes32 requestId = keccak256("request1");

        // Create BridgeMessage with the same requestId
        BridgeValidator.BridgeMessage memory message = BridgeValidator.BridgeMessage({
            requestId: requestId,
            sender: makeAddr("sender"),
            recipient: makeAddr("recipient"),
            token: makeAddr("token"),
            amount: 1000,
            sourceChain: 1,
            targetChain: 2,
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });

        // Create invalid signatures (only 1 signature, but threshold is 2)
        // This will cause verifySignaturesView to return false
        bytes[] memory signatures = new bytes[](1);
        // Sign with only one signer (threshold requires 2)
        bytes32 messageHash = _hashBridgeMessage(message);
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer1Key, ethSignedHash);
        signatures[0] = abi.encodePacked(r, s, v);

        // Encode evidence in the new format: BridgeMessage + signatures
        bytes memory evidence = abi.encode(message, signatures);

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.InvalidSignature,
            merkleProof: new bytes32[](0),
            stateProof: "",
            evidence: evidence
        });

        verifier.submitFraudProof(proof);

        // Verify - should return true (fraud proven) because signatures are insufficient
        bool isValid = verifier.verifyFraudProof(proof);
        assertTrue(isValid);

        FraudProofVerifier.ProofRecord memory record = verifier.getProofRecord(requestId);
        assertTrue(record.verified);
        assertTrue(record.isValid);
        assertEq(verifier.totalFraudProven(), 1);
    }

    // Helper function to hash BridgeMessage (matches BridgeValidator.hashBridgeMessage)
    function _hashBridgeMessage(BridgeValidator.BridgeMessage memory message) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "BridgeMessage(bytes32 requestId,address sender,address recipient,address token,uint256 amount,uint256 sourceChain,uint256 targetChain,uint256 nonce,uint256 deadline)"
                ),
                message.requestId,
                message.sender,
                message.recipient,
                message.token,
                message.amount,
                message.sourceChain,
                message.targetChain,
                message.nonce,
                message.deadline
            )
        );

        bytes32 domainSeparator = bridgeValidatorContract.DOMAIN_SEPARATOR();
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function test_VerifyFraudProof_DoubleSpending() public {
        bytes32 requestId = keccak256("request1");
        bytes32 txHash1 = keccak256("tx1");
        bytes32 txHash2 = keccak256("tx2");
        bytes32 inputHash = keccak256("input");
        bytes32[] memory merkleProof = new bytes32[](1);
        merkleProof[0] = keccak256("proof");

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.DoubleSpending,
            merkleProof: merkleProof,
            stateProof: "",
            evidence: abi.encode(txHash1, txHash2, inputHash)
        });

        verifier.submitFraudProof(proof);

        bool isValid = verifier.verifyFraudProof(proof);
        assertTrue(isValid);

        // Check double spend evidence was recorded
        (bytes32 recordedTx1, bytes32 recordedTx2, bool sameInputs) = verifier.doubleSpendEvidence(requestId);
        assertEq(recordedTx1, txHash1);
        assertEq(recordedTx2, txHash2);
        assertTrue(sameInputs);
    }

    function test_VerifyFraudProof_InvalidAmount() public {
        bytes32 requestId = keccak256("request1");
        bytes32[] memory merkleProof = new bytes32[](1);
        merkleProof[0] = keccak256("proof");

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.InvalidAmount,
            merkleProof: merkleProof,
            stateProof: "",
            evidence: abi.encode(uint256(1000), uint256(900), uint256(1000)) // amounts don't match
        });

        verifier.submitFraudProof(proof);

        bool isValid = verifier.verifyFraudProof(proof);
        assertTrue(isValid);
    }

    function test_VerifyFraudProof_InvalidToken() public {
        bytes32 requestId = keccak256("request1");
        address unauthorizedToken = makeAddr("unauthorizedToken");
        uint256 chainId = 1;

        // Make sure token is NOT authorized
        assertFalse(verifier.isTokenAuthorized(chainId, unauthorizedToken));

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.InvalidToken,
            merkleProof: new bytes32[](0),
            stateProof: "",
            evidence: abi.encode(unauthorizedToken, chainId)
        });

        verifier.submitFraudProof(proof);

        bool isValid = verifier.verifyFraudProof(proof);
        assertTrue(isValid);
    }

    function test_VerifyFraudProof_ReplayAttack() public {
        bytes32 requestId = keccak256("request1");
        bytes32 nonceHash = keccak256("nonce");
        bytes32 previousTxHash = keccak256("previousTx");
        bytes32[] memory merkleProof = new bytes32[](1);
        merkleProof[0] = keccak256("proof");

        // First record the nonce as used
        vm.prank(owner);
        verifier.recordUsedNonce(nonceHash);

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.ReplayAttack,
            merkleProof: merkleProof,
            stateProof: "",
            evidence: abi.encode(nonceHash, previousTxHash)
        });

        verifier.submitFraudProof(proof);

        bool isValid = verifier.verifyFraudProof(proof);
        assertTrue(isValid);
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

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.InvalidSignature,
            merkleProof: new bytes32[](0),
            stateProof: "",
            evidence: ""
        });

        verifier.submitFraudProof(proof);

        // Fast forward past expiry
        vm.warp(block.timestamp + 8 days);

        vm.expectRevert(FraudProofVerifier.ProofExpired.selector);
        verifier.verifyFraudProof(proof);
    }

    function test_VerifyFraudProof_ReturnsCachedResult() public {
        bytes32 requestId = keccak256("request_cached");

        // Create BridgeMessage with the same requestId
        BridgeValidator.BridgeMessage memory message = BridgeValidator.BridgeMessage({
            requestId: requestId,
            sender: makeAddr("sender"),
            recipient: makeAddr("recipient"),
            token: makeAddr("token"),
            amount: 1000,
            sourceChain: 1,
            targetChain: 2,
            nonce: 2,
            deadline: block.timestamp + 1 hours
        });

        // Create invalid signatures (only 1 signature, but threshold is 2)
        bytes[] memory signatures = new bytes[](1);
        bytes32 messageHash = _hashBridgeMessage(message);
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer1Key, ethSignedHash);
        signatures[0] = abi.encodePacked(r, s, v);

        bytes memory evidence = abi.encode(message, signatures);

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.InvalidSignature,
            merkleProof: new bytes32[](0),
            stateProof: "",
            evidence: evidence
        });

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
        uint256 blockNumber = 12345;

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

        vm.expectRevert();
        verifier.submitFraudProof(proof);
    }

    function test_Unpause() public {
        vm.prank(owner);
        verifier.pause();

        vm.prank(owner);
        verifier.unpause();

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = "sig";
        address[] memory expectedSigners = new address[](1);
        expectedSigners[0] = makeAddr("signer");

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: keccak256("request"),
            proofType: FraudProofVerifier.FraudProofType.InvalidSignature,
            merkleProof: new bytes32[](0),
            stateProof: "",
            evidence: abi.encode(keccak256("messageHash"), signatures, expectedSigners)
        });

        // Should not revert
        verifier.submitFraudProof(proof);
    }

    // ============ View Functions Tests ============

    function test_GetProofRecord() public {
        bytes32 requestId = keccak256("request1");

        FraudProofVerifier.FraudProof memory proof = FraudProofVerifier.FraudProof({
            requestId: requestId,
            proofType: FraudProofVerifier.FraudProofType.InvalidSignature,
            merkleProof: new bytes32[](0),
            stateProof: "",
            evidence: ""
        });

        address submitter = makeAddr("submitter");
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
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        verifier.setOptimisticVerifier(makeAddr("newVerifier"));
    }

    function test_OnlyOwner_SetBridgeValidator() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        verifier.setBridgeValidator(makeAddr("newValidator"));
    }

    function test_OnlyOwner_UpdateStateRoot() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        verifier.updateStateRoot(1, keccak256("root"), 100);
    }

    function test_OnlyOwner_SetAuthorizedToken() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        verifier.setAuthorizedToken(1, makeAddr("token"), true);
    }

    function test_OnlyOwner_RecordUsedNonce() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        verifier.recordUsedNonce(keccak256("nonce"));
    }

    function test_OnlyOwner_Pause() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        verifier.pause();
    }
}
