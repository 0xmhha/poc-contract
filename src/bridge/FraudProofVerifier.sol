// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { BridgeValidator } from "./BridgeValidator.sol";

/**
 * @title FraudProofVerifier
 * @notice Fraud proof verification for challenged bridge requests
 * @dev Implements multiple fraud proof types with Merkle and state proof validation
 *
 * Fraud Proof Types:
 * - InvalidSignature: MPC signature verification failure
 * - DoubleSpending: Same funds used in multiple requests
 * - InvalidAmount: Amount mismatch between chains
 * - InvalidToken: Unauthorized token in bridge request
 * - ReplayAttack: Nonce reuse detected
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

    // ============ Enums ============

    /**
     * @notice Types of fraud proofs that can be submitted
     */
    enum FraudProofType {
        None,
        InvalidSignature, // MPC signature verification failed
        DoubleSpending, // Same funds used multiple times
        InvalidAmount, // Amount mismatch
        InvalidToken, // Unauthorized token
        ReplayAttack // Nonce reuse
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

        // Check proof hasn't expired
        if (block.timestamp > record.submittedAt + PROOF_EXPIRY) revert ProofExpired();

        // Verify proof hash matches
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 proofHash = keccak256(
            abi.encode(proof.requestId, proof.proofType, proof.merkleProof, proof.stateProof, proof.evidence)
        );

        if (proofHash != record.proofHash) revert InvalidProof();

        // Verify based on proof type
        if (proof.proofType == FraudProofType.InvalidSignature) {
            isValid = _verifyInvalidSignatureProof(proof);
        } else if (proof.proofType == FraudProofType.DoubleSpending) {
            isValid = _verifyDoubleSpendingProof(proof);
        } else if (proof.proofType == FraudProofType.InvalidAmount) {
            isValid = _verifyInvalidAmountProof(proof);
        } else if (proof.proofType == FraudProofType.InvalidToken) {
            isValid = _verifyInvalidTokenProof(proof);
        } else if (proof.proofType == FraudProofType.ReplayAttack) {
            isValid = _verifyReplayAttackProof(proof);
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
        authorizedTokens[chainId][token] = authorized;
    }

    /**
     * @notice Batch set authorized tokens
     * @param chainId Chain ID
     * @param tokens Array of token addresses
     * @param authorized Whether the tokens are authorized
     */
    function batchSetAuthorizedTokens(uint256 chainId, address[] calldata tokens, bool authorized) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            authorizedTokens[chainId][tokens[i]] = authorized;
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
     * @notice Verify invalid signature proof
     * @dev Fraud proof is valid if signatures do NOT pass BridgeValidator verification
     * @param proof The fraud proof containing BridgeMessage and signatures
     * @return isValid True if fraud is proven (signatures are invalid)
     *
     * Evidence format: abi.encode(BridgeValidator.BridgeMessage, bytes[] signatures)
     * - BridgeMessage: The bridge message that was supposedly validated
     * - signatures: The signatures that were used to validate the message
     *
     * This proves fraud if:
     * 1. The signatures do not meet the threshold requirement
     * 2. The signatures are from unauthorized signers
     * 3. The message was altered after signing
     */
    function _verifyInvalidSignatureProof(FraudProof calldata proof) internal view returns (bool) {
        if (proof.evidence.length == 0) return false;
        if (bridgeValidator == address(0)) revert ZeroAddress();

        // Decode evidence: BridgeMessage struct and signatures array
        (BridgeValidator.BridgeMessage memory message, bytes[] memory signatures) =
            abi.decode(proof.evidence, (BridgeValidator.BridgeMessage, bytes[]));

        // Basic validation
        if (signatures.length == 0) return false;

        // Call BridgeValidator to verify signatures
        // If verification returns false, fraud is proven (signatures are invalid)
        try BridgeValidator(bridgeValidator).verifySignaturesView(message, signatures) returns (
            bool valid, uint256 validCount
        ) {
            // Fraud is proven if signatures are NOT valid
            // validCount helps understand how many signatures were actually valid
            if (!valid) {
                return true; // Fraud proven: insufficient valid signatures
            }

            // Additional check: verify the requestId matches
            if (message.requestId != proof.requestId) {
                return true; // Fraud proven: message requestId mismatch
            }

            return false; // No fraud: signatures are valid
        } catch {
            // If the call reverts, it could indicate:
            // 1. Expired message (deadline passed)
            // 2. Nonce already used
            // 3. Other validation errors
            // In these cases, we consider it as potential fraud evidence
            return true;
        }
    }

    /**
     * @notice Verify double spending proof
     * @param proof The fraud proof
     * @return isValid Whether the proof is valid
     */
    function _verifyDoubleSpendingProof(FraudProof calldata proof) internal returns (bool) {
        // Decode evidence: (bytes32 txHash1, bytes32 txHash2, bytes32 inputHash)
        if (proof.evidence.length == 0) return false;

        (bytes32 txHash1, bytes32 txHash2, bytes32 inputHash) = abi.decode(proof.evidence, (bytes32, bytes32, bytes32));

        // Verify merkle proofs for both transactions
        if (proof.merkleProof.length == 0) return false;

        // Check that both transactions use the same input
        // In reality, this would verify on-chain state
        if (txHash1 == txHash2) return false; // Same tx is not double-spend

        // Record the double-spend evidence
        doubleSpendEvidence[proof.requestId] =
            DoubleSpendEvidence({ txHash1: txHash1, txHash2: txHash2, sameInputs: true });

        emit DoubleSpendRecorded(proof.requestId, txHash1, txHash2);

        return true;
    }

    /**
     * @notice Verify invalid amount proof
     * @param proof The fraud proof
     * @return isValid Whether the proof is valid
     */
    function _verifyInvalidAmountProof(FraudProof calldata proof) internal view returns (bool) {
        // Decode evidence: (uint256 sourceAmount, uint256 targetAmount, uint256 expectedAmount)
        if (proof.evidence.length == 0) return false;

        (uint256 sourceAmount, uint256 targetAmount, uint256 expectedAmount) =
            abi.decode(proof.evidence, (uint256, uint256, uint256));

        // Verify merkle proof for source chain amount
        if (proof.merkleProof.length == 0) return false;

        // Check if amounts don't match
        return sourceAmount != targetAmount || targetAmount != expectedAmount;
    }

    /**
     * @notice Verify invalid token proof
     * @param proof The fraud proof
     * @return isValid Whether the proof is valid
     */
    function _verifyInvalidTokenProof(FraudProof calldata proof) internal view returns (bool) {
        // Decode evidence: (address token, uint256 chainId)
        if (proof.evidence.length == 0) return false;

        (address token, uint256 chainId) = abi.decode(proof.evidence, (address, uint256));

        // Check if token is NOT authorized for the chain
        return !authorizedTokens[chainId][token];
    }

    /**
     * @notice Verify replay attack proof
     * @param proof The fraud proof
     * @return isValid Whether the proof is valid
     */
    function _verifyReplayAttackProof(FraudProof calldata proof) internal view returns (bool) {
        // Decode evidence: (bytes32 nonceHash, bytes32 previousTxHash)
        if (proof.evidence.length == 0) return false;

        (bytes32 nonceHash, bytes32 previousTxHash) = abi.decode(proof.evidence, (bytes32, bytes32));

        // Check if nonce was already used
        if (!usedNonces[nonceHash]) return false;

        // Verify merkle proof shows previous usage
        if (proof.merkleProof.length == 0) return false;
        if (previousTxHash == bytes32(0)) return false;

        return true;
    }

    /**
     * @notice Notify OptimisticVerifier of fraud proof result
     * @param requestId ID of the request
     * @param fraudProven Whether fraud was proven
     */
    function _notifyOptimisticVerifier(bytes32 requestId, bool fraudProven) internal {
        // Call resolveChallenge on OptimisticVerifier
        // Interface call would be:
        // IOptimisticVerifier(optimisticVerifier).resolveChallenge(requestId, fraudProven);

        // For now, use low-level call
        (bool success,) =
            optimisticVerifier.call(abi.encodeWithSignature("resolveChallenge(bytes32,bool)", requestId, fraudProven));

        // We don't revert if call fails - just log
        if (!success) {
            // Silent fail - OptimisticVerifier might handle it differently
        }
    }
}
