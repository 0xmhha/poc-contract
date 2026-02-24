// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BasePaymaster } from "./BasePaymaster.sol";
import { IEntryPoint } from "../erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { UserOperationLib } from "../erc4337-entrypoint/UserOperationLib.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { PaymasterDataLib } from "./PaymasterDataLib.sol";

/**
 * @title VerifyingPaymaster
 * @notice A paymaster that verifies an off-chain signature to sponsor gas
 * @dev The verifying signer signs a hash of the user operation data to approve sponsorship.
 *      This allows for flexible off-chain policies to determine which operations to sponsor.
 *
 * PaymasterData format (envelope):
 *   [0]    version      (uint8)  - must be 0x01
 *   [1]    paymasterType(uint8)  - must be 0 (VERIFYING)
 *   [2]    flags        (uint8)  - reserved
 *   [3:9]  validUntil   (uint48) - expiration timestamp
 *   [9:15] validAfter   (uint48) - activation timestamp
 *   [15:23] nonce       (uint64) - paymaster-level nonce
 *   [23:25] payloadLen  (uint16) - payload length
 *   [25:25+payloadLen]  payload  - ABI-encoded VerifyingPayload
 *   [25+payloadLen:]    signature - ECDSA signature from verifyingSigner
 */
contract VerifyingPaymaster is BasePaymaster {
    using ECDSA for bytes32;
    using UserOperationLib for PackedUserOperation;

    /// @notice The address authorized to sign sponsorship approvals
    address public verifyingSigner;

    /// @notice Nonces used to prevent signature replay
    mapping(address => uint256) public senderNonce;

    event SignerChanged(address indexed oldSigner, address indexed newSigner);
    event GasSponsored(address indexed sender, bytes32 indexed userOpHash, uint256 maxCost);

    error InvalidSignatureLength();
    error InvalidSigner();
    error SignerCannotBeZero();

    /**
     * @notice Constructor
     * @param _entryPoint The EntryPoint contract address
     * @param _owner The owner of this paymaster
     * @param _verifyingSigner Initial verifying signer address
     */
    constructor(IEntryPoint _entryPoint, address _owner, address _verifyingSigner) BasePaymaster(_entryPoint, _owner) {
        if (_verifyingSigner == address(0)) revert SignerCannotBeZero();
        verifyingSigner = _verifyingSigner;
    }

    /**
     * @notice Set a new verifying signer
     * @param _verifyingSigner The new verifying signer address
     */
    function setVerifyingSigner(address _verifyingSigner) external onlyOwner {
        if (_verifyingSigner == address(0)) revert SignerCannotBeZero();
        address oldSigner = verifyingSigner;
        verifyingSigner = _verifyingSigner;
        emit SignerChanged(oldSigner, _verifyingSigner);
    }

    /**
     * @notice Get the hash to be signed by the verifying signer
     * @param userOp The user operation
     * @param envelopeData The raw envelope bytes (without trailing signature)
     * @return The hash that needs to be signed
     */
    function getHash(PackedUserOperation calldata userOp, bytes memory envelopeData) public view returns (bytes32) {
        bytes32 domainSeparator = _computeDomainSeparator();
        bytes32 userOpCoreHash = _computeUserOpCoreHash(userOp);
        return PaymasterDataLib.hashForSignature(domainSeparator, userOpCoreHash, envelopeData);
    }

    /**
     * @notice Internal validation logic
     * @param userOp The user operation
     * @param userOpHash Hash of the user operation (unused, we compute our own)
     * @param maxCost Maximum cost of this transaction
     * @return context Context to be passed to postOp (sender address and nonce)
     * @return validationData Packed validation data including time range
     */
    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        internal
        override
        returns (bytes memory context, uint256 validationData)
    {
        (userOpHash); // silence unused variable warning

        bytes calldata paymasterData = _parsePaymasterData(userOp.paymasterAndData);

        return _validate(userOp, paymasterData, maxCost);
    }

    /**
     * @notice Validate using envelope format
     * @param userOp The user operation
     * @param paymasterData Raw paymaster data
     * @param maxCost Maximum cost
     * @return context Encoded context for postOp
     * @return validationData Packed validation data
     */
    function _validate(PackedUserOperation calldata userOp, bytes calldata paymasterData, uint256 maxCost)
        internal
        returns (bytes memory context, uint256 validationData)
    {
        // Determine envelope length and split envelope from signature
        uint256 envLen = PaymasterDataLib.envelopeLength(paymasterData);
        bytes calldata envelopeData = paymasterData[:envLen];
        bytes calldata signature = paymasterData[envLen:];

        // Decode envelope
        PaymasterDataLib.Envelope memory env = PaymasterDataLib.decode(envelopeData);

        // Verify paymaster type
        if (env.paymasterType != uint8(PaymasterDataLib.PaymasterType.VERIFYING)) {
            revert PaymasterDataLib.InvalidType(env.paymasterType);
        }

        // Compute hash for signature verification
        bytes32 domainSeparator = _computeDomainSeparator();
        bytes32 userOpCoreHash = _computeUserOpCoreHash(userOp);
        bytes32 hash = PaymasterDataLib.hashForSignature(domainSeparator, userOpCoreHash, envelopeData);
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();

        // Verify signature
        address recoveredSigner = ECDSA.recover(ethSignedHash, signature);

        if (recoveredSigner != verifyingSigner) {
            return ("", _packValidationDataFailure(env.validUntil, env.validAfter));
        }

        // Increment nonce to prevent replay
        senderNonce[userOp.sender]++;

        // Emit event for tracking
        emit GasSponsored(userOp.sender, keccak256(abi.encode(userOp)), maxCost);

        // Return success with time range and sender context
        return (abi.encode(userOp.sender), _packValidationDataSuccess(env.validUntil, env.validAfter));
    }

    /**
     * @notice Post-operation handler (empty for this paymaster)
     * @dev Override if post-op tracking or refund logic is needed
     */
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        pure
        override
    {
        // No post-op logic needed for basic verifying paymaster
        // Can be extended for usage tracking, refunds, etc.
        (mode, context, actualGasCost, actualUserOpFeePerGas);
    }

    /**
     * @notice Get the current nonce for a sender
     * @param sender The sender address
     * @return The current nonce
     */
    function getNonce(address sender) external view returns (uint256) {
        return senderNonce[sender];
    }
}
