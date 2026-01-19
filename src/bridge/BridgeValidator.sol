// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title BridgeValidator
 * @notice MPC signature validation for cross-chain bridge operations
 * @dev Implements 5-of-7 threshold MPC signature verification with key rotation support
 *
 * Security Features:
 * - MPC public key management with versioning
 * - Nonce tracking for replay prevention
 * - Key rotation with proof verification
 * - Signer set versioning for upgrades
 */
contract BridgeValidator is Ownable, Pausable, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Errors ============
    error InvalidSignature();
    error InvalidNonce();
    error NonceAlreadyUsed();
    error InvalidSignerCount();
    error InvalidThreshold();
    error SignerAlreadyExists();
    error SignerNotFound();
    error InsufficientSignatures();
    error DuplicateSignature();
    error InvalidRotationProof();
    error RotationCooldownActive();
    error ZeroAddress();
    error InvalidMessageLength();
    error ExpiredMessage();

    // ============ Events ============
    event SignerAdded(address indexed signer, uint256 signerSetVersion);
    event SignerRemoved(address indexed signer, uint256 signerSetVersion);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold, uint256 signerSetVersion);
    event SignerSetRotated(uint256 oldVersion, uint256 newVersion);
    event MessageValidated(bytes32 indexed messageHash, uint256 nonce, address indexed sender);
    event NonceInvalidated(uint256 indexed nonce, address indexed sender);

    // ============ Structs ============

    /**
     * @notice Structure for bridge messages
     * @param requestId Unique identifier for the bridge request
     * @param sender Address of the sender on source chain
     * @param recipient Address of the recipient on target chain
     * @param token Token address being bridged
     * @param amount Amount of tokens being bridged
     * @param sourceChain Source chain ID
     * @param targetChain Target chain ID
     * @param nonce Unique nonce for replay prevention
     * @param deadline Timestamp after which the message expires
     */
    struct BridgeMessage {
        bytes32 requestId;
        address sender;
        address recipient;
        address token;
        uint256 amount;
        uint256 sourceChain;
        uint256 targetChain;
        uint256 nonce;
        uint256 deadline;
    }

    /**
     * @notice Structure for signer set configuration
     * @param signers Array of authorized signer addresses
     * @param threshold Minimum signatures required
     * @param activatedAt Timestamp when this signer set became active
     */
    struct SignerSet {
        address[] signers;
        uint256 threshold;
        uint256 activatedAt;
    }

    // ============ Constants ============
    uint256 public constant MAX_SIGNERS = 15;
    uint256 public constant MIN_SIGNERS = 3;
    uint256 public constant ROTATION_COOLDOWN = 1 days;
    bytes32 public constant DOMAIN_SEPARATOR_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 public constant BRIDGE_MESSAGE_TYPEHASH = keccak256(
        "BridgeMessage(bytes32 requestId,address sender,address recipient,address token,uint256 amount,uint256 sourceChain,uint256 targetChain,uint256 nonce,uint256 deadline)"
    );

    // ============ State Variables ============

    /// @notice Current signer set version
    uint256 public signerSetVersion;

    /// @notice Mapping of signer set version to configuration
    mapping(uint256 => SignerSet) public signerSets;

    /// @notice Mapping to check if address is a signer in current set
    mapping(address => bool) public isSigner;

    /// @notice Mapping of used nonces per sender
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    /// @notice Last rotation timestamp
    uint256 public lastRotationTime;

    /// @notice Domain separator for EIP-712
    bytes32 public immutable DOMAIN_SEPARATOR;

    // ============ Constructor ============

    /**
     * @notice Initialize the BridgeValidator with initial signers
     * @param initialSigners Array of initial signer addresses
     * @param initialThreshold Minimum signatures required (e.g., 5 for 5-of-7)
     */
    constructor(
        address[] memory initialSigners,
        uint256 initialThreshold
    ) Ownable(msg.sender) {
        if (initialSigners.length < MIN_SIGNERS) revert InvalidSignerCount();
        if (initialSigners.length > MAX_SIGNERS) revert InvalidSignerCount();
        if (initialThreshold == 0 || initialThreshold > initialSigners.length) revert InvalidThreshold();

        // Initialize domain separator
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPEHASH,
                keccak256(bytes("BridgeValidator")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );

        // Set up initial signer set
        signerSetVersion = 1;
        SignerSet storage currentSet = signerSets[1];
        currentSet.threshold = initialThreshold;
        currentSet.activatedAt = block.timestamp;

        for (uint256 i = 0; i < initialSigners.length; i++) {
            address signer = initialSigners[i];
            if (signer == address(0)) revert ZeroAddress();
            if (isSigner[signer]) revert SignerAlreadyExists();

            currentSet.signers.push(signer);
            isSigner[signer] = true;

            emit SignerAdded(signer, 1);
        }
    }

    // ============ External Functions ============

    /**
     * @notice Verify MPC signatures for a bridge message
     * @param message The bridge message to verify
     * @param signatures Array of signatures from MPC signers
     * @return valid True if sufficient valid signatures provided
     */
    function verifyMpcSignatures(
        BridgeMessage calldata message,
        bytes[] calldata signatures
    ) external whenNotPaused returns (bool valid) {
        // Check deadline
        if (block.timestamp > message.deadline) revert ExpiredMessage();

        // Check nonce
        if (usedNonces[message.sender][message.nonce]) revert NonceAlreadyUsed();

        // Get current signer set
        SignerSet storage currentSet = signerSets[signerSetVersion];

        // Check minimum signatures
        if (signatures.length < currentSet.threshold) revert InsufficientSignatures();

        // Compute message hash
        bytes32 messageHash = hashBridgeMessage(message);
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();

        // Track signers who have signed
        address[] memory signersCounted = new address[](signatures.length);
        uint256 validSignatures = 0;

        for (uint256 i = 0; i < signatures.length; i++) {
            address recoveredSigner = ethSignedHash.recover(signatures[i]);

            // Check if signer is valid
            if (!isSigner[recoveredSigner]) continue;

            // Check for duplicate signatures
            for (uint256 j = 0; j < validSignatures; j++) {
                if (signersCounted[j] == recoveredSigner) revert DuplicateSignature();
            }

            signersCounted[validSignatures] = recoveredSigner;
            validSignatures++;
        }

        // Verify threshold met
        if (validSignatures < currentSet.threshold) revert InsufficientSignatures();

        // Mark nonce as used
        usedNonces[message.sender][message.nonce] = true;

        emit MessageValidated(messageHash, message.nonce, message.sender);

        return true;
    }

    /**
     * @notice Verify signatures without consuming nonce (view function)
     * @param message The bridge message to verify
     * @param signatures Array of signatures from MPC signers
     * @return valid True if sufficient valid signatures provided
     * @return validCount Number of valid signatures
     */
    function verifySignaturesView(
        BridgeMessage calldata message,
        bytes[] calldata signatures
    ) external view returns (bool valid, uint256 validCount) {
        // Check deadline
        if (block.timestamp > message.deadline) return (false, 0);

        // Check nonce
        if (usedNonces[message.sender][message.nonce]) return (false, 0);

        // Get current signer set
        SignerSet storage currentSet = signerSets[signerSetVersion];

        // Compute message hash
        bytes32 messageHash = hashBridgeMessage(message);
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();

        // Track signers who have signed
        address[] memory signersCounted = new address[](signatures.length);

        for (uint256 i = 0; i < signatures.length; i++) {
            address recoveredSigner = ethSignedHash.recover(signatures[i]);

            // Check if signer is valid
            if (!isSigner[recoveredSigner]) continue;

            // Check for duplicate signatures
            bool isDuplicate = false;
            for (uint256 j = 0; j < validCount; j++) {
                if (signersCounted[j] == recoveredSigner) {
                    isDuplicate = true;
                    break;
                }
            }

            if (!isDuplicate) {
                signersCounted[validCount] = recoveredSigner;
                validCount++;
            }
        }

        valid = validCount >= currentSet.threshold;
    }

    /**
     * @notice Invalidate a nonce (can only be done by the nonce owner)
     * @param nonce The nonce to invalidate
     */
    function invalidateNonce(uint256 nonce) external {
        if (usedNonces[msg.sender][nonce]) revert NonceAlreadyUsed();

        usedNonces[msg.sender][nonce] = true;

        emit NonceInvalidated(nonce, msg.sender);
    }

    // ============ Admin Functions ============

    /**
     * @notice Add a new signer to the current signer set
     * @param newSigner Address of the new signer
     */
    function addSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        if (isSigner[newSigner]) revert SignerAlreadyExists();

        SignerSet storage currentSet = signerSets[signerSetVersion];
        if (currentSet.signers.length >= MAX_SIGNERS) revert InvalidSignerCount();

        currentSet.signers.push(newSigner);
        isSigner[newSigner] = true;

        emit SignerAdded(newSigner, signerSetVersion);
    }

    /**
     * @notice Remove a signer from the current signer set
     * @param signerToRemove Address of the signer to remove
     */
    function removeSigner(address signerToRemove) external onlyOwner {
        if (!isSigner[signerToRemove]) revert SignerNotFound();

        SignerSet storage currentSet = signerSets[signerSetVersion];

        // Ensure minimum signers maintained
        if (currentSet.signers.length <= MIN_SIGNERS) revert InvalidSignerCount();

        // Ensure threshold still achievable
        if (currentSet.signers.length - 1 < currentSet.threshold) revert InvalidThreshold();

        // Find and remove signer
        uint256 signerIndex = type(uint256).max;
        for (uint256 i = 0; i < currentSet.signers.length; i++) {
            if (currentSet.signers[i] == signerToRemove) {
                signerIndex = i;
                break;
            }
        }

        // Move last element to removed position and pop
        currentSet.signers[signerIndex] = currentSet.signers[currentSet.signers.length - 1];
        currentSet.signers.pop();

        isSigner[signerToRemove] = false;

        emit SignerRemoved(signerToRemove, signerSetVersion);
    }

    /**
     * @notice Update the signature threshold
     * @param newThreshold New minimum signatures required
     */
    function updateThreshold(uint256 newThreshold) external onlyOwner {
        SignerSet storage currentSet = signerSets[signerSetVersion];

        if (newThreshold == 0 || newThreshold > currentSet.signers.length) revert InvalidThreshold();

        uint256 oldThreshold = currentSet.threshold;
        currentSet.threshold = newThreshold;

        emit ThresholdUpdated(oldThreshold, newThreshold, signerSetVersion);
    }

    /**
     * @notice Rotate to a new signer set
     * @param newSigners Array of new signer addresses
     * @param newThreshold New minimum signatures required
     * @param rotationProof Proof authorizing the rotation (signed by current threshold)
     */
    function rotateSignerSet(
        address[] calldata newSigners,
        uint256 newThreshold,
        bytes[] calldata rotationProof
    ) external onlyOwner {
        // Check cooldown
        if (block.timestamp < lastRotationTime + ROTATION_COOLDOWN) revert RotationCooldownActive();

        // Validate new signer set
        if (newSigners.length < MIN_SIGNERS) revert InvalidSignerCount();
        if (newSigners.length > MAX_SIGNERS) revert InvalidSignerCount();
        if (newThreshold == 0 || newThreshold > newSigners.length) revert InvalidThreshold();

        // Verify rotation proof (current signers must approve)
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 rotationHash = keccak256(
            abi.encode(
                "ROTATE_SIGNER_SET",
                signerSetVersion,
                newSigners,
                newThreshold,
                block.chainid
            )
        );

        SignerSet storage currentSet = signerSets[signerSetVersion];
        if (!_verifyRotationProof(rotationHash, rotationProof, currentSet)) {
            revert InvalidRotationProof();
        }

        // Clear old signer mappings
        for (uint256 i = 0; i < currentSet.signers.length; i++) {
            isSigner[currentSet.signers[i]] = false;
        }

        // Increment version and create new signer set
        uint256 oldVersion = signerSetVersion;
        signerSetVersion++;

        SignerSet storage newSet = signerSets[signerSetVersion];
        newSet.threshold = newThreshold;
        newSet.activatedAt = block.timestamp;

        // Add new signers
        for (uint256 i = 0; i < newSigners.length; i++) {
            address signer = newSigners[i];
            if (signer == address(0)) revert ZeroAddress();
            if (isSigner[signer]) revert SignerAlreadyExists();

            newSet.signers.push(signer);
            isSigner[signer] = true;
        }

        lastRotationTime = block.timestamp;

        emit SignerSetRotated(oldVersion, signerSetVersion);
    }

    /**
     * @notice Pause the validator
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the validator
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ View Functions ============

    /**
     * @notice Get the current signer set
     * @return signers Array of current signer addresses
     * @return threshold Current signature threshold
     * @return activatedAt Timestamp when current set was activated
     */
    function getCurrentSignerSet() external view returns (
        address[] memory signers,
        uint256 threshold,
        uint256 activatedAt
    ) {
        SignerSet storage currentSet = signerSets[signerSetVersion];
        return (currentSet.signers, currentSet.threshold, currentSet.activatedAt);
    }

    /**
     * @notice Get signer count for current set
     * @return count Number of signers
     */
    function getSignerCount() external view returns (uint256 count) {
        return signerSets[signerSetVersion].signers.length;
    }

    /**
     * @notice Check if a nonce has been used
     * @param sender Address of the sender
     * @param nonce Nonce to check
     * @return used True if nonce has been used
     */
    function isNonceUsed(address sender, uint256 nonce) external view returns (bool used) {
        return usedNonces[sender][nonce];
    }

    /**
     * @notice Get the hash of a bridge message
     * @param message The bridge message
     * @return messageHash The EIP-712 typed hash
     */
    function hashBridgeMessage(BridgeMessage calldata message) public view returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        BRIDGE_MESSAGE_TYPEHASH,
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
                )
            )
        );
    }

    // ============ Internal Functions ============

    /**
     * @notice Verify rotation proof from current signers
     * @param rotationHash Hash of the rotation parameters
     * @param signatures Signatures from current signers
     * @param currentSet Current signer set
     * @return valid True if sufficient valid signatures provided
     */
    function _verifyRotationProof(
        bytes32 rotationHash,
        bytes[] calldata signatures,
        SignerSet storage currentSet
    ) internal view returns (bool valid) {
        if (signatures.length < currentSet.threshold) return false;

        bytes32 ethSignedHash = rotationHash.toEthSignedMessageHash();

        address[] memory signersCounted = new address[](signatures.length);
        uint256 validSignatures = 0;

        for (uint256 i = 0; i < signatures.length; i++) {
            address recoveredSigner = ethSignedHash.recover(signatures[i]);

            // Check if signer is in current set
            bool isCurrentSigner = false;
            for (uint256 j = 0; j < currentSet.signers.length; j++) {
                if (currentSet.signers[j] == recoveredSigner) {
                    isCurrentSigner = true;
                    break;
                }
            }

            if (!isCurrentSigner) continue;

            // Check for duplicates
            bool isDuplicate = false;
            for (uint256 k = 0; k < validSignatures; k++) {
                if (signersCounted[k] == recoveredSigner) {
                    isDuplicate = true;
                    break;
                }
            }

            if (!isDuplicate) {
                signersCounted[validSignatures] = recoveredSigner;
                validSignatures++;
            }
        }

        return validSignatures >= currentSet.threshold;
    }
}
