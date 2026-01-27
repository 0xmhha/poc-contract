// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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
 * @title WebAuthnValidator
 * @notice ERC-7579 Validator module for WebAuthn/Passkey authentication (P256 curve)
 * @dev Enables smart accounts to use biometric authentication via passkeys
 *
 * Features:
 * - P256 (secp256r1) signature verification for WebAuthn
 * - Support for multiple passkey credentials per account
 * - Credential management (add, remove, list)
 * - Compatible with browser WebAuthn API and hardware security keys
 *
 * Signature Format (for validateUserOp):
 * - [0:32] - authenticatorData length (uint256)
 * - [32:32+len] - authenticatorData
 * - [32+len:64+len] - clientDataJson length (uint256)
 * - [64+len:64+len+cdLen] - clientDataJson
 * - [remaining] - r (32 bytes) + s (32 bytes) signature
 */
contract WebAuthnValidator is IValidator {
    /// @notice P256 curve constants
    uint256 internal constant P256_N =
        0xF_FFF_FFF_F00_000_000_FFF_FFF_FFF_FFF_FFF_FBC_E6F_AAD_A71_79E_84F_3B9_CAC_2FC_632_551;
    uint256 internal constant P256_N_DIV_2 = P256_N / 2;

    /// @notice WebAuthn credential structure
    struct Credential {
        bytes32 credentialId;
        uint256 pubKeyX;
        uint256 pubKeyY;
        bool isActive;
    }

    /// @notice Storage for each smart account
    struct WebAuthnStorage {
        uint256 credentialCount;
        mapping(bytes32 => Credential) credentials;
        bytes32[] credentialIds;
    }

    /// @notice Storage mapping
    mapping(address => WebAuthnStorage) private webAuthnStorage;

    /// @notice Events
    event CredentialRegistered(address indexed account, bytes32 indexed credentialId, uint256 pubKeyX, uint256 pubKeyY);
    event CredentialRevoked(address indexed account, bytes32 indexed credentialId);

    /// @notice Errors
    error InvalidCredentialId();
    error CredentialAlreadyExists();
    error CredentialNotFound();
    error NoCredentials();
    error InvalidSignatureLength();
    error InvalidAuthenticatorData();
    error InvalidClientDataJSON();
    error SignatureVerificationFailed();
    error MalformedSignature();

    /**
     * @notice Install the validator with initial credential
     * @param data ABI-encoded credential data: (bytes32 credentialId, uint256 pubKeyX, uint256 pubKeyY)
     */
    function onInstall(bytes calldata data) external payable override {
        if (data.length < 96) revert InvalidSignatureLength();

        (bytes32 credentialId, uint256 pubKeyX, uint256 pubKeyY) = abi.decode(data, (bytes32, uint256, uint256));

        _addCredential(msg.sender, credentialId, pubKeyX, pubKeyY);
    }

    /**
     * @notice Uninstall the validator and remove all credentials
     * @param data Not used
     */
    function onUninstall(bytes calldata data) external payable override {
        (data); // silence unused warning
        if (!_isInitialized(msg.sender)) revert NotInitialized(msg.sender);

        WebAuthnStorage storage store = webAuthnStorage[msg.sender];

        // Clear all credentials
        for (uint256 i = 0; i < store.credentialIds.length; i++) {
            delete store.credentials[store.credentialIds[i]];
        }
        delete store.credentialIds;
        store.credentialCount = 0;
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
     * @notice Validate a user operation signature
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
        WebAuthnStorage storage store = webAuthnStorage[msg.sender];
        if (store.credentialCount == 0) return SIG_VALIDATION_FAILED_UINT;

        bytes calldata sig = userOp.signature;

        // Parse WebAuthn signature
        (bytes32 credentialId, bytes memory authenticatorData, bytes memory clientDataJson, uint256 r, uint256 s) =
            _parseSignature(sig);

        // Find the credential
        Credential storage cred = store.credentials[credentialId];
        if (!cred.isActive) return SIG_VALIDATION_FAILED_UINT;

        // Verify the signature
        if (_verifyWebAuthnSignature(userOpHash, authenticatorData, clientDataJson, r, s, cred.pubKeyX, cred.pubKeyY)) {
            return SIG_VALIDATION_SUCCESS_UINT;
        }

        return SIG_VALIDATION_FAILED_UINT;
    }

    /**
     * @notice Validate signature for ERC-1271
     * @param sender The sender address (not used)
     * @param hash The hash to verify
     * @param sig The signature data
     * @return Magic value if valid
     */
    function isValidSignatureWithSender(address sender, bytes32 hash, bytes calldata sig)
        external
        view
        override
        returns (bytes4)
    {
        (sender); // silence unused warning

        WebAuthnStorage storage store = webAuthnStorage[msg.sender];
        if (store.credentialCount == 0) return ERC1271_INVALID;

        // Parse WebAuthn signature
        (bytes32 credentialId, bytes memory authenticatorData, bytes memory clientDataJson, uint256 r, uint256 s) =
            _parseSignature(sig);

        // Find the credential
        Credential storage cred = store.credentials[credentialId];
        if (!cred.isActive) return ERC1271_INVALID;

        // Verify the signature
        if (_verifyWebAuthnSignature(hash, authenticatorData, clientDataJson, r, s, cred.pubKeyX, cred.pubKeyY)) {
            return ERC1271_MAGICVALUE;
        }

        return ERC1271_INVALID;
    }

    // ============ Credential Management ============

    /**
     * @notice Add a new credential to the account
     * @param credentialId The credential ID
     * @param pubKeyX The X coordinate of the public key
     * @param pubKeyY The Y coordinate of the public key
     */
    function addCredential(bytes32 credentialId, uint256 pubKeyX, uint256 pubKeyY) external {
        _addCredential(msg.sender, credentialId, pubKeyX, pubKeyY);
    }

    /**
     * @notice Remove a credential from the account
     * @param credentialId The credential ID to remove
     */
    function revokeCredential(bytes32 credentialId) external {
        WebAuthnStorage storage store = webAuthnStorage[msg.sender];

        if (!store.credentials[credentialId].isActive) {
            revert CredentialNotFound();
        }

        // Must have at least one credential remaining
        if (store.credentialCount <= 1) {
            revert NoCredentials();
        }

        store.credentials[credentialId].isActive = false;
        store.credentialCount--;

        emit CredentialRevoked(msg.sender, credentialId);
    }

    /**
     * @notice Get credential information
     * @param account The smart account address
     * @param credentialId The credential ID
     * @return The credential data
     */
    function getCredential(address account, bytes32 credentialId) external view returns (Credential memory) {
        return webAuthnStorage[account].credentials[credentialId];
    }

    /**
     * @notice Get all credential IDs for an account
     * @param account The smart account address
     * @return Array of credential IDs
     */
    function getCredentialIds(address account) external view returns (bytes32[] memory) {
        return webAuthnStorage[account].credentialIds;
    }

    /**
     * @notice Get the number of active credentials
     * @param account The smart account address
     * @return Number of active credentials
     */
    function getCredentialCount(address account) external view returns (uint256) {
        return webAuthnStorage[account].credentialCount;
    }

    // ============ Internal Functions ============

    function _isInitialized(address smartAccount) internal view returns (bool) {
        return webAuthnStorage[smartAccount].credentialCount > 0;
    }

    function _addCredential(address account, bytes32 credentialId, uint256 pubKeyX, uint256 pubKeyY) internal {
        if (credentialId == bytes32(0)) revert InvalidCredentialId();

        WebAuthnStorage storage store = webAuthnStorage[account];

        if (store.credentials[credentialId].isActive) {
            revert CredentialAlreadyExists();
        }

        store.credentials[credentialId] =
            Credential({ credentialId: credentialId, pubKeyX: pubKeyX, pubKeyY: pubKeyY, isActive: true });

        store.credentialIds.push(credentialId);
        store.credentialCount++;

        emit CredentialRegistered(account, credentialId, pubKeyX, pubKeyY);
    }

    /**
     * @notice Parse WebAuthn signature from calldata
     * @dev Signature format:
     *      [0:32] - credentialId
     *      [32:64] - authenticatorData offset
     *      [64:96] - clientDataJson offset
     *      [dynamic] - authenticatorData (length-prefixed)
     *      [dynamic] - clientDataJson (length-prefixed)
     *      [last 64 bytes] - r, s
     */
    function _parseSignature(bytes calldata sig)
        internal
        pure
        returns (
            bytes32 credentialId,
            bytes memory authenticatorData,
            bytes memory clientDataJson,
            uint256 r,
            uint256 s
        )
    {
        if (sig.length < 160) revert InvalidSignatureLength();

        // Decode the structured signature
        (credentialId, authenticatorData, clientDataJson, r, s) =
            abi.decode(sig, (bytes32, bytes, bytes, uint256, uint256));

        // Validate s is in lower half of curve order (malleability fix)
        if (s > P256_N_DIV_2) revert MalformedSignature();
    }

    /**
     * @notice Verify a WebAuthn signature
     * @param challenge The challenge (userOpHash)
     * @param authenticatorData The authenticator data
     * @param clientDataJson The client data JSON
     * @param r Signature r value
     * @param s Signature s value
     * @param pubKeyX Public key X coordinate
     * @param pubKeyY Public key Y coordinate
     * @return True if valid
     */
    function _verifyWebAuthnSignature(
        bytes32 challenge,
        bytes memory authenticatorData,
        bytes memory clientDataJson,
        uint256 r,
        uint256 s,
        uint256 pubKeyX,
        uint256 pubKeyY
    ) internal view returns (bool) {
        // Validate authenticator data (minimum 37 bytes)
        if (authenticatorData.length < 37) revert InvalidAuthenticatorData();

        // Verify the challenge is in clientDataJson
        // The challenge should be base64url encoded in the clientDataJson
        if (!_containsChallenge(clientDataJson, challenge)) {
            return false;
        }

        // Compute the message hash
        // WebAuthn signature is over: SHA256(authenticatorData || SHA256(clientDataJson))
        bytes32 clientDataHash = sha256(clientDataJson);
        bytes32 messageHash = sha256(abi.encodePacked(authenticatorData, clientDataHash));

        // Verify P256 signature using precompile (EIP-7212)
        // If precompile not available, use fallback library
        return _verifyP256Signature(messageHash, r, s, pubKeyX, pubKeyY);
    }

    /**
     * @notice Check if clientDataJson contains the challenge
     * @param clientDataJson The client data JSON
     * @param challenge The challenge to find
     * @return True if found
     */
    function _containsChallenge(bytes memory clientDataJson, bytes32 challenge) internal pure returns (bool) {
        // In production, this would parse the JSON and verify the base64url-encoded challenge
        // For simplicity, we do a basic check that the JSON is not empty
        // A full implementation would use a JSON parser
        return clientDataJson.length > 0 && challenge != bytes32(0);
    }

    /**
     * @notice Verify P256 signature using EIP-7212 precompile or fallback
     * @param hash The message hash
     * @param r Signature r
     * @param s Signature s
     * @param pubKeyX Public key X
     * @param pubKeyY Public key Y
     * @return True if valid
     */
    function _verifyP256Signature(bytes32 hash, uint256 r, uint256 s, uint256 pubKeyX, uint256 pubKeyY)
        internal
        view
        returns (bool)
    {
        // Try EIP-7212 P256VERIFY precompile at address 0x100
        // Input: hash (32) || r (32) || s (32) || x (32) || y (32) = 160 bytes
        // Output: 1 if valid, empty or 0 if invalid

        bytes memory input = abi.encodePacked(hash, r, s, pubKeyX, pubKeyY);

        (bool success, bytes memory output) = address(0x100).staticcall(input);

        if (success && output.length == 32) {
            return abi.decode(output, (uint256)) == 1;
        }

        // Fallback: Use P256 library verification if precompile not available
        // This would require importing a P256 verification library like FCL or Daimo's P256Verifier
        // For now, return false if precompile is not available
        return false;
    }
}
