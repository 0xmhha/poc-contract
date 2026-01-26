// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ECDSA } from "solady/utils/ECDSA.sol";
import { IValidator } from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { PackedUserOperation } from "../erc7579-smartaccount/interfaces/PackedUserOperation.sol";
import {
    SIG_VALIDATION_SUCCESS_UINT,
    SIG_VALIDATION_FAILED_UINT,
    MODULE_TYPE_VALIDATOR,
    ERC1271_MAGICVALUE,
    ERC1271_INVALID
} from "../erc7579-smartaccount/types/Constants.sol";

/**
 * @title MultiSigValidator
 * @notice ERC-7579 Validator module for M-of-N multisig authentication
 * @dev Enables smart accounts to require multiple signers for transactions
 *
 * Features:
 * - Configurable M-of-N threshold (e.g., 2-of-3, 3-of-5)
 * - Signer management (add, remove, replace)
 * - Threshold updates with validation
 * - Support for both EOA and smart contract signers
 * - Signature aggregation and verification
 *
 * Signature Format:
 * - Concatenated signatures: sig1 (65 bytes) || sig2 (65 bytes) || ... || sigM (65 bytes)
 * - Total length: M * 65 bytes
 * - Signatures must be ordered by signer address (ascending) to prevent duplicates
 */
contract MultiSigValidator is IValidator {
    using ECDSA for bytes32;

    /// @notice Maximum number of signers allowed
    uint256 public constant MAX_SIGNERS = 20;

    /// @notice Storage for each smart account
    struct MultiSigStorage {
        uint8 threshold;
        uint8 signerCount;
        mapping(address => bool) isSigner;
        address[] signers;
    }

    /// @notice Storage mapping
    mapping(address => MultiSigStorage) private multiSigStorage;

    /// @notice Events
    event ThresholdChanged(address indexed account, uint8 oldThreshold, uint8 newThreshold);
    event SignerAdded(address indexed account, address indexed signer);
    event SignerRemoved(address indexed account, address indexed signer);

    /// @notice Errors
    error InvalidThreshold(uint8 threshold, uint8 signerCount);
    error InvalidSignerCount();
    error SignerAlreadyExists(address signer);
    error SignerNotFound(address signer);
    error InvalidSignatureOrder();
    error DuplicateSignature();
    error InvalidSignatureLength();
    error ThresholdTooHigh();
    error CannotRemoveLastSigner();
    error ZeroAddress();

    /**
     * @notice Install the validator with initial configuration
     * @param data ABI-encoded: (address[] signers, uint8 threshold)
     */
    function onInstall(bytes calldata data) external payable override {
        if (_isInitialized(msg.sender)) revert AlreadyInitialized(msg.sender);

        (address[] memory signers, uint8 threshold) = abi.decode(data, (address[], uint8));

        if (signers.length == 0 || signers.length > MAX_SIGNERS) {
            revert InvalidSignerCount();
        }

        if (threshold == 0 || threshold > signers.length) {
            revert InvalidThreshold(threshold, uint8(signers.length));
        }

        MultiSigStorage storage store = multiSigStorage[msg.sender];
        store.threshold = threshold;
        store.signerCount = uint8(signers.length);

        // Add signers (check for duplicates and zero addresses)
        for (uint256 i = 0; i < signers.length; i++) {
            address signer = signers[i];
            if (signer == address(0)) revert ZeroAddress();
            if (store.isSigner[signer]) revert SignerAlreadyExists(signer);

            store.isSigner[signer] = true;
            store.signers.push(signer);

            emit SignerAdded(msg.sender, signer);
        }
    }

    /**
     * @notice Uninstall the validator
     * @param data Not used
     */
    function onUninstall(bytes calldata data) external payable override {
        (data); // silence unused warning
        if (!_isInitialized(msg.sender)) revert NotInitialized(msg.sender);

        MultiSigStorage storage store = multiSigStorage[msg.sender];

        // Clear all signers
        for (uint256 i = 0; i < store.signers.length; i++) {
            delete store.isSigner[store.signers[i]];
        }
        delete store.signers;
        store.threshold = 0;
        store.signerCount = 0;
    }

    /**
     * @notice Check if this module is a validator
     * @param typeId Module type ID
     * @return True if this is a validator
     */
    function isModuleType(uint256 typeId) external pure override returns (bool) {
        return typeId == MODULE_TYPE_VALIDATOR;
    }

    /**
     * @notice Check if the module is initialized for an account
     * @param smartAccount The smart account address
     * @return True if initialized
     */
    function isInitialized(address smartAccount) external view override returns (bool) {
        return _isInitialized(smartAccount);
    }

    /**
     * @notice Validate a user operation with multisig
     * @param userOp The packed user operation
     * @param userOpHash The hash to verify
     * @return Validation result
     */
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        payable
        override
        returns (uint256)
    {
        MultiSigStorage storage store = multiSigStorage[msg.sender];

        if (store.signerCount == 0) {
            return SIG_VALIDATION_FAILED_UINT;
        }

        bytes calldata signatures = userOp.signature;

        if (_verifyMultiSig(store, userOpHash, signatures)) {
            return SIG_VALIDATION_SUCCESS_UINT;
        }

        // Try with EIP-191 prefix
        bytes32 ethHash = ECDSA.toEthSignedMessageHash(userOpHash);
        if (_verifyMultiSig(store, ethHash, signatures)) {
            return SIG_VALIDATION_SUCCESS_UINT;
        }

        return SIG_VALIDATION_FAILED_UINT;
    }

    /**
     * @notice Validate signature for ERC-1271
     * @param sender The sender address (not used)
     * @param hash The hash to verify
     * @param sig The concatenated signatures
     * @return Magic value if valid
     */
    function isValidSignatureWithSender(address sender, bytes32 hash, bytes calldata sig)
        external
        view
        override
        returns (bytes4)
    {
        (sender); // silence unused warning

        MultiSigStorage storage store = multiSigStorage[msg.sender];

        if (store.signerCount == 0) {
            return ERC1271_INVALID;
        }

        if (_verifyMultiSig(store, hash, sig)) {
            return ERC1271_MAGICVALUE;
        }

        // Try with EIP-191 prefix
        bytes32 ethHash = ECDSA.toEthSignedMessageHash(hash);
        if (_verifyMultiSig(store, ethHash, sig)) {
            return ERC1271_MAGICVALUE;
        }

        return ERC1271_INVALID;
    }

    // ============ Signer Management ============

    /**
     * @notice Add a new signer
     * @param signer The signer address to add
     */
    function addSigner(address signer) external {
        if (signer == address(0)) revert ZeroAddress();

        MultiSigStorage storage store = multiSigStorage[msg.sender];

        if (store.isSigner[signer]) revert SignerAlreadyExists(signer);
        if (store.signerCount >= MAX_SIGNERS) revert InvalidSignerCount();

        store.isSigner[signer] = true;
        store.signers.push(signer);
        store.signerCount++;

        emit SignerAdded(msg.sender, signer);
    }

    /**
     * @notice Remove a signer
     * @param signer The signer address to remove
     */
    function removeSigner(address signer) external {
        MultiSigStorage storage store = multiSigStorage[msg.sender];

        if (!store.isSigner[signer]) revert SignerNotFound(signer);
        if (store.signerCount <= store.threshold) revert CannotRemoveLastSigner();

        store.isSigner[signer] = false;
        store.signerCount--;

        // Remove from array (swap and pop)
        for (uint256 i = 0; i < store.signers.length; i++) {
            if (store.signers[i] == signer) {
                store.signers[i] = store.signers[store.signers.length - 1];
                store.signers.pop();
                break;
            }
        }

        emit SignerRemoved(msg.sender, signer);
    }

    /**
     * @notice Replace a signer
     * @param oldSigner The signer to replace
     * @param newSigner The new signer address
     */
    function replaceSigner(address oldSigner, address newSigner) external {
        if (newSigner == address(0)) revert ZeroAddress();

        MultiSigStorage storage store = multiSigStorage[msg.sender];

        if (!store.isSigner[oldSigner]) revert SignerNotFound(oldSigner);
        if (store.isSigner[newSigner]) revert SignerAlreadyExists(newSigner);

        store.isSigner[oldSigner] = false;
        store.isSigner[newSigner] = true;

        // Update array
        for (uint256 i = 0; i < store.signers.length; i++) {
            if (store.signers[i] == oldSigner) {
                store.signers[i] = newSigner;
                break;
            }
        }

        emit SignerRemoved(msg.sender, oldSigner);
        emit SignerAdded(msg.sender, newSigner);
    }

    /**
     * @notice Update the threshold
     * @param newThreshold The new threshold value
     */
    function setThreshold(uint8 newThreshold) external {
        MultiSigStorage storage store = multiSigStorage[msg.sender];

        if (newThreshold == 0 || newThreshold > store.signerCount) {
            revert InvalidThreshold(newThreshold, store.signerCount);
        }

        uint8 oldThreshold = store.threshold;
        store.threshold = newThreshold;

        emit ThresholdChanged(msg.sender, oldThreshold, newThreshold);
    }

    // ============ View Functions ============

    /**
     * @notice Get the current threshold
     * @param account The smart account address
     * @return The threshold
     */
    function getThreshold(address account) external view returns (uint8) {
        return multiSigStorage[account].threshold;
    }

    /**
     * @notice Get the number of signers
     * @param account The smart account address
     * @return The number of signers
     */
    function getSignerCount(address account) external view returns (uint8) {
        return multiSigStorage[account].signerCount;
    }

    /**
     * @notice Get all signers
     * @param account The smart account address
     * @return Array of signer addresses
     */
    function getSigners(address account) external view returns (address[] memory) {
        return multiSigStorage[account].signers;
    }

    /**
     * @notice Check if an address is a signer
     * @param account The smart account address
     * @param signer The address to check
     * @return True if the address is a signer
     */
    function isSigner(address account, address signer) external view returns (bool) {
        return multiSigStorage[account].isSigner[signer];
    }

    // ============ Internal Functions ============

    function _isInitialized(address smartAccount) internal view returns (bool) {
        return multiSigStorage[smartAccount].signerCount > 0;
    }

    /**
     * @notice Verify multisig signatures
     * @param store The multisig storage
     * @param hash The hash to verify
     * @param signatures The concatenated signatures
     * @return True if valid
     */
    function _verifyMultiSig(MultiSigStorage storage store, bytes32 hash, bytes calldata signatures)
        internal
        view
        returns (bool)
    {
        uint8 threshold = store.threshold;

        // Check signature length (65 bytes per signature)
        if (signatures.length < threshold * 65) {
            return false;
        }

        address lastSigner = address(0);
        uint256 validCount = 0;

        // Verify each signature
        for (uint256 i = 0; i < threshold; i++) {
            // Extract signature components
            uint256 offset = i * 65;
            bytes32 r;
            bytes32 s;
            uint8 v;

            assembly {
                r := calldataload(add(signatures.offset, offset))
                s := calldataload(add(signatures.offset, add(offset, 32)))
                v := byte(0, calldataload(add(signatures.offset, add(offset, 64))))
            }

            // Recover signer
            address signer = ECDSA.recover(hash, v, r, s);

            // Check signer is valid and in ascending order (prevents duplicates)
            if (signer <= lastSigner) {
                return false; // Invalid order or duplicate
            }

            if (!store.isSigner[signer]) {
                return false; // Not a valid signer
            }

            lastSigner = signer;
            validCount++;
        }

        return validCount >= threshold;
    }
}
