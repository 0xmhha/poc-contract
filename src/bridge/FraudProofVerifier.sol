// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { OptimisticVerifier } from "./OptimisticVerifier.sol";

/**
 * @title FraudProofVerifier
 * @notice Fraud proof verification for challenged bridge requests
 * @dev Implements multiple fraud proof types with Merkle and state proof validation
 *
 * Fraud Proof Types:
 * - DoubleSpending: Same funds used in multiple requests
 * - InvalidAmount: Amount mismatch between chains
 * - InvalidToken: Unauthorized token in bridge request
 * - InvalidSignature, ReplayAttack: rejected. Their evidence (signatures, sender/nonce) is
 *   chosen by the submitter and cannot be tied to the challenged request, so accepting them
 *   would let any challenger prove "fraud" against a legitimate request.
 *
 * Proofs may only be submitted by the active challenger of a request (or the owner) while the
 * request is Challenged in the OptimisticVerifier, and are evaluated against the request data
 * recorded there.
 */
contract FraudProofVerifier is Ownable, Pausable, ReentrancyGuard {
    // ============ Errors ============
    error InvalidProofType();
    error InvalidProof();
    error ProofAlreadySubmitted();
    error ProofVerificationFailed();
    error InvalidMerkleProof();
    error InvalidStateProof();
    error OptimisticVerifierNotSet();
    error UnauthorizedCaller();
    error ZeroAddress();
    error InvalidRequestId();
    error ProofExpired();
    error InsufficientEvidence();

    // ============ Events ============
    event FraudProofSubmitted(
        bytes32 indexed requestId, FraudProofType proofType, address indexed submitter, bytes32 proofHash
    );
    event FraudProofVerified(
        bytes32 indexed requestId, FraudProofType proofType, bool isValid, address indexed verifier
    );
    event OptimisticVerifierUpdated(address oldVerifier, address newVerifier);
    event BridgeValidatorUpdated(address oldValidator, address newValidator);
    event DoubleSpendRecorded(bytes32 indexed requestId1, bytes32 indexed requestId2, bytes32 txHash);
    event StateRootUpdated(uint256 indexed chainId, bytes32 newRoot, uint256 blockNumber);
    event OptimisticVerifierNotificationFailed(bytes32 indexed requestId, bool fraudProven);

    // ============ Enums ============

    /**
     * @notice Types of fraud proofs that can be submitted
     */
    enum FraudProofType {
        None,
        InvalidSignature, // MPC signature verification failed (rejected: evidence cannot be bound)
        DoubleSpending, // Same funds used multiple times
        InvalidAmount, // Amount mismatch
        InvalidToken, // Unauthorized token
        ReplayAttack // Nonce reuse (rejected: evidence cannot be bound)
    }

    // ============ Structs ============

    /**
     * @notice Structure for fraud proof submission
     * @param requestId ID of the challenged request
     * @param proofType Type of fraud being claimed
     * @param merkleProof Merkle proof for state verification
     * @param stateProof Additional state proof data
     * @param evidence Additional evidence bytes
     */
    struct FraudProof {
        bytes32 requestId;
        FraudProofType proofType;
        bytes32[] merkleProof;
        bytes stateProof;
        bytes evidence;
    }

    /**
     * @notice Structure for tracking submitted proofs
     * @param submitter Address that submitted the proof
     * @param proofType Type of fraud claimed
     * @param proofHash Hash of the submitted proof
     * @param submittedAt Timestamp of submission
     * @param verified Whether proof has been verified
     * @param isValid Result of verification
     */
    struct ProofRecord {
        address submitter;
        FraudProofType proofType;
        bytes32 proofHash;
        uint256 submittedAt;
        bool verified;
        bool isValid;
    }

    /**
     * @notice Structure for double-spend evidence
     * @param txHash1 First transaction hash
     * @param txHash2 Second transaction hash (double-spend)
     * @param sameInputs Whether the same inputs were used
     */
    struct DoubleSpendEvidence {
        bytes32 txHash1;
        bytes32 txHash2;
        bool sameInputs;
    }

    // ============ Constants ============
    uint256 public constant PROOF_EXPIRY = 7 days;

    // ============ State Variables ============

    /// @notice Address of the OptimisticVerifier contract
    address public optimisticVerifier;

    /// @notice Address of the BridgeValidator contract
    address public bridgeValidator;

    /// @notice Mapping of request ID to proof records
    mapping(bytes32 => ProofRecord) public proofRecords;

    /// @notice Mapping of chain ID to state root
    mapping(uint256 => bytes32) public stateRoots;

    /// @notice Mapping of chain ID to state root block number
    mapping(uint256 => uint256) public stateRootBlockNumbers;

    /// @notice Mapping to track double-spend evidence
    mapping(bytes32 => DoubleSpendEvidence) public doubleSpendEvidence;

    /// @notice Mapping of nonces to check for replay attacks
    mapping(bytes32 => bool) public usedNonces;

    /// @notice Mapping of authorized tokens per chain
    mapping(uint256 => mapping(address => bool)) public authorizedTokens;

    /// @notice Number of authorized tokens per chain; 0 means no token list is configured
    mapping(uint256 => uint256) public authorizedTokenCount;

    /// @notice Total proofs submitted
    uint256 public totalProofsSubmitted;

    /// @notice Total successful fraud proofs
    uint256 public totalFraudProven;

    // ============ Constructor ============

    /**
     * @notice Initialize the FraudProofVerifier
     */
    constructor() Ownable(msg.sender) { }

    // ============ External Functions ============

    /**
     * @notice Submit a fraud proof for verification
     * @param proof The fraud proof data
     * @return proofHash Hash of the submitted proof
     */
    function submitFraudProof(FraudProof calldata proof)
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 proofHash)
    {
        if (proof.proofType == FraudProofType.None) revert InvalidProofType();
        if (proof.requestId == bytes32(0)) revert InvalidRequestId();
        if (proof.proofType == FraudProofType.InvalidSignature || proof.proofType == FraudProofType.ReplayAttack) {
            revert InvalidProofType();
        }

        // Only the active challenger (or owner) may submit, and only while the request is challenged
        _checkActiveChallenger(proof.requestId);

        // Check if proof already submitted for this request
        if (proofRecords[proof.requestId].submittedAt > 0) revert ProofAlreadySubmitted();

        // Compute proof hash
        proofHash = keccak256(
            abi.encode(proof.requestId, proof.proofType, proof.merkleProof, proof.stateProof, proof.evidence)
        );

        // Store proof record
        proofRecords[proof.requestId] = ProofRecord({
            submitter: msg.sender,
            proofType: proof.proofType,
            proofHash: proofHash,
            submittedAt: block.timestamp,
            verified: false,
            isValid: false
        });

        totalProofsSubmitted++;

        emit FraudProofSubmitted(proof.requestId, proof.proofType, msg.sender, proofHash);
    }

    /**
     * @notice Verify a submitted fraud proof
     * @param proof The fraud proof to verify
     * @return isValid Whether the fraud proof is valid
     */
    function verifyFraudProof(FraudProof calldata proof) external whenNotPaused nonReentrant returns (bool isValid) {
        ProofRecord storage record = proofRecords[proof.requestId];

        // Verify proof was submitted
        if (record.submittedAt == 0) revert InvalidProof();
        if (record.verified) return record.isValid;
        if (msg.sender != record.submitter && msg.sender != owner()) revert UnauthorizedCaller();

        // Check proof hasn't expired
        if (block.timestamp > record.submittedAt + PROOF_EXPIRY) revert ProofExpired();

        // Verify proof hash matches
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 proofHash = keccak256(
            abi.encode(proof.requestId, proof.proofType, proof.merkleProof, proof.stateProof, proof.evidence)
        );

        if (proofHash != record.proofHash) revert InvalidProof();

        // Verify based on proof type, against the request recorded in the OptimisticVerifier
        OptimisticVerifier.BridgeRequest memory request =
            OptimisticVerifier(payable(optimisticVerifier)).getRequest(proof.requestId);
        if (proof.proofType == FraudProofType.DoubleSpending) {
            isValid = _verifyDoubleSpendingProof(proof);
        } else if (proof.proofType == FraudProofType.InvalidAmount) {
            isValid = _verifyInvalidAmountProof(proof, request);
        } else if (proof.proofType == FraudProofType.InvalidToken) {
            isValid = _verifyInvalidTokenProof(proof, request);
        }

        // Update record
        record.verified = true;
        record.isValid = isValid;

        if (isValid) {
            totalFraudProven++;

            // Notify OptimisticVerifier of successful fraud proof
            if (optimisticVerifier != address(0)) {
                _notifyOptimisticVerifier(proof.requestId, true);
            }

            // Record double-spend evidence after successful notification
            if (proof.proofType == FraudProofType.DoubleSpending) {
                (bytes32 txHash1, bytes32 txHash2,) = abi.decode(proof.evidence, (bytes32, bytes32, bytes32));
                doubleSpendEvidence[proof.requestId] =
                    DoubleSpendEvidence({ txHash1: txHash1, txHash2: txHash2, sameInputs: true });
                emit DoubleSpendRecorded(proof.requestId, txHash1, txHash2);
            }
        }

        emit FraudProofVerified(proof.requestId, proof.proofType, isValid, msg.sender);
    }

    /**
     * @notice Verify a Merkle proof against a state root
     * @param chainId Chain ID for the state root
     * @param leaf Leaf node to verify
     * @param proof Merkle proof path
     * @return valid Whether the proof is valid
     */
    function verifyMerkleProof(uint256 chainId, bytes32 leaf, bytes32[] calldata proof)
        external
        view
        returns (bool valid)
    {
        bytes32 root = stateRoots[chainId];
        if (root == bytes32(0)) return false;

        return MerkleProof.verify(proof, root, leaf);
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the OptimisticVerifier address
     * @param newVerifier Address of the OptimisticVerifier
     */
    function setOptimisticVerifier(address newVerifier) external onlyOwner {
        if (newVerifier == address(0)) revert ZeroAddress();

        address oldVerifier = optimisticVerifier;
        optimisticVerifier = newVerifier;

        emit OptimisticVerifierUpdated(oldVerifier, newVerifier);
    }

    /**
     * @notice Set the BridgeValidator address
     * @param newValidator Address of the BridgeValidator
     */
    function setBridgeValidator(address newValidator) external onlyOwner {
        if (newValidator == address(0)) revert ZeroAddress();

        address oldValidator = bridgeValidator;
        bridgeValidator = newValidator;

        emit BridgeValidatorUpdated(oldValidator, newValidator);
    }

    /**
     * @notice Update the state root for a chain
     * @param chainId Chain ID
     * @param newRoot New state root
     * @param blockNumber Block number of the state root
     */
    function updateStateRoot(uint256 chainId, bytes32 newRoot, uint256 blockNumber) external onlyOwner {
        stateRoots[chainId] = newRoot;
        stateRootBlockNumbers[chainId] = blockNumber;

        emit StateRootUpdated(chainId, newRoot, blockNumber);
    }

    /**
     * @notice Set authorized tokens for a chain
     * @param chainId Chain ID
     * @param token Token address
     * @param authorized Whether the token is authorized
     */
    function setAuthorizedToken(uint256 chainId, address token, bool authorized) external onlyOwner {
        _setAuthorizedToken(chainId, token, authorized);
    }

    /**
     * @notice Batch set authorized tokens
     * @param chainId Chain ID
     * @param tokens Array of token addresses
     * @param authorized Whether the tokens are authorized
     */
    function batchSetAuthorizedTokens(uint256 chainId, address[] calldata tokens, bool authorized) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            _setAuthorizedToken(chainId, tokens[i], authorized);
        }
    }

    /**
     * @notice Update a token's authorization and keep authorizedTokenCount in sync
     * @dev Only state changes adjust the count, so repeated calls never double count
     */
    function _setAuthorizedToken(uint256 chainId, address token, bool authorized) internal {
        if (authorizedTokens[chainId][token] == authorized) return;
        authorizedTokens[chainId][token] = authorized;
        if (authorized) {
            authorizedTokenCount[chainId]++;
        } else {
            authorizedTokenCount[chainId]--;
        }
    }

    /**
     * @notice Record a used nonce (for replay prevention)
     * @param nonceHash Hash of the nonce
     */
    function recordUsedNonce(bytes32 nonceHash) external onlyOwner {
        usedNonces[nonceHash] = true;
    }

    /**
     * @notice Pause the verifier
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the verifier
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ View Functions ============

    /**
     * @notice Get proof record for a request
     * @param requestId ID of the request
     * @return record The proof record
     */
    function getProofRecord(bytes32 requestId) external view returns (ProofRecord memory) {
        return proofRecords[requestId];
    }

    /**
     * @notice Check if a token is authorized for a chain
     * @param chainId Chain ID
     * @param token Token address
     * @return authorized Whether the token is authorized
     */
    function isTokenAuthorized(uint256 chainId, address token) external view returns (bool) {
        return authorizedTokens[chainId][token];
    }

    /**
     * @notice Get state root for a chain
     * @param chainId Chain ID
     * @return root The state root
     * @return blockNumber Block number of the state root
     */
    function getStateRoot(uint256 chainId) external view returns (bytes32 root, uint256 blockNumber) {
        return (stateRoots[chainId], stateRootBlockNumbers[chainId]);
    }

    /**
     * @notice Check if a nonce has been used
     * @param nonceHash Hash of the nonce
     * @return used Whether the nonce has been used
     */
    function isNonceUsed(bytes32 nonceHash) external view returns (bool) {
        return usedNonces[nonceHash];
    }

    // ============ Internal Functions ============

    /**
     * @notice Verify double spending proof
     * @param proof The fraud proof
     * @return isValid Whether the proof is valid
     */
    function _verifyDoubleSpendingProof(FraudProof calldata proof) internal view returns (bool) {
        if (proof.evidence.length == 0) return false;

        (bytes32 txHash1, bytes32 txHash2, bytes32 inputHash) = abi.decode(proof.evidence, (bytes32, bytes32, bytes32));

        // Verify merkle proofs for both transactions
        if (proof.merkleProof.length == 0) return false;

        // Same tx is not double-spend
        if (txHash1 == txHash2) return false;

        // Decode state proof to get the chain ID for state root lookup
        if (proof.stateProof.length == 0) return false;
        uint256 chainId = abi.decode(proof.stateProof, (uint256));

        // Verify the first transaction exists in the state via Merkle proof
        bytes32 root = stateRoots[chainId];
        if (root == bytes32(0)) return false;

        // Verify that inputHash is included in the Merkle tree (proves shared input).
        // The leaf commits to the requestId so an attested double-spend cannot be reused
        // against other requests.
        bytes32 leaf = keccak256(abi.encodePacked(proof.requestId, txHash1, txHash2, inputHash));
        if (!MerkleProof.verify(proof.merkleProof, root, leaf)) return false;

        return true;
    }

    /**
     * @notice Verify invalid amount proof
     * @param proof The fraud proof
     * @param request The challenged request
     * @return isValid Whether the proof is valid
     */
    function _verifyInvalidAmountProof(FraudProof calldata proof, OptimisticVerifier.BridgeRequest memory request)
        internal
        view
        returns (bool)
    {
        if (proof.evidence.length == 0) return false;

        (uint256 sourceAmount, uint256 targetAmount, uint256 expectedAmount) =
            abi.decode(proof.evidence, (uint256, uint256, uint256));

        // The expected amount must be the amount recorded for the challenged request
        if (expectedAmount != request.amount) return false;

        // Verify merkle proof for the claimed amounts
        if (proof.merkleProof.length == 0) return false;
        if (proof.stateProof.length == 0) return false;

        uint256 chainId = abi.decode(proof.stateProof, (uint256));
        bytes32 root = stateRoots[chainId];
        if (root == bytes32(0)) return false;

        // Verify the amounts are anchored to on-chain state
        bytes32 leaf = keccak256(abi.encodePacked(proof.requestId, sourceAmount, targetAmount));
        if (!MerkleProof.verify(proof.merkleProof, root, leaf)) return false;

        // Check if amounts don't match
        return sourceAmount != targetAmount || targetAmount != expectedAmount;
    }

    /**
     * @notice Verify invalid token proof
     * @param proof The fraud proof
     * @param request The challenged request
     * @return isValid Whether the proof is valid
     */
    function _verifyInvalidTokenProof(FraudProof calldata proof, OptimisticVerifier.BridgeRequest memory request)
        internal
        view
        returns (bool)
    {
        // Decode evidence: (address token, uint256 chainId)
        if (proof.evidence.length == 0) return false;

        (address token, uint256 chainId) = abi.decode(proof.evidence, (address, uint256));

        // Evidence must name the token and source chain of the challenged request
        if (token != request.token || chainId != request.sourceChain) return false;

        // Fail closed: without a configured token list for the chain, no token can be proven invalid
        if (authorizedTokenCount[chainId] == 0) return false;

        // Check if token is NOT authorized for the chain
        return !authorizedTokens[chainId][token];
    }

    /**
     * @notice Revert unless msg.sender is the active challenger of the request or the owner
     * @param requestId ID of the challenged request
     */
    function _checkActiveChallenger(bytes32 requestId) internal view {
        if (optimisticVerifier == address(0)) revert OptimisticVerifierNotSet();

        OptimisticVerifier verifier = OptimisticVerifier(payable(optimisticVerifier));
        if (verifier.getRequestStatus(requestId) != OptimisticVerifier.RequestStatus.Challenged) {
            revert InvalidRequestId();
        }
        if (msg.sender != owner() && msg.sender != verifier.getChallenge(requestId).challenger) {
            revert UnauthorizedCaller();
        }
    }

    /**
     * @notice Notify OptimisticVerifier of fraud proof result
     * @dev Reverts if the OptimisticVerifier rejects the resolution so a valid proof is never
     *      recorded as verified without the challenge being resolved.
     * @param requestId ID of the request
     * @param fraudProven Whether fraud was proven
     */
    function _notifyOptimisticVerifier(bytes32 requestId, bool fraudProven) internal {
        OptimisticVerifier(payable(optimisticVerifier)).resolveChallenge(requestId, fraudProven);
    }
}
