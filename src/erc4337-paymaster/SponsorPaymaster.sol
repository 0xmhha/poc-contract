// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BasePaymaster } from "./BasePaymaster.sol";
import { IEntryPoint } from "../erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { UserOperationLib } from "../erc4337-entrypoint/UserOperationLib.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { PaymasterDataLib } from "./PaymasterDataLib.sol";
import { PaymasterPayload } from "./PaymasterPayload.sol";

/**
 * @title SponsorPaymaster
 * @notice A paymaster that sponsors gas using off-chain policy (Visa 4-Party model)
 * @dev Off-chain policy engine decides whether to sponsor. On-chain contract only verifies
 *      the signer's ECDSA signature over the envelope data.
 *      Pattern follows VerifyingPaymaster: envelope decode → type check → hash → ECDSA verify.
 *
 * PaymasterData format (envelope):
 *   [0]    version      (uint8)  - must be 0x01
 *   [1]    paymasterType(uint8)  - must be 1 (SPONSOR)
 *   [2]    flags        (uint8)  - reserved
 *   [3:9]  validUntil   (uint48) - expiration timestamp
 *   [9:15] validAfter   (uint48) - activation timestamp
 *   [15:23] nonce       (uint64) - paymaster-level nonce
 *   [23:25] payloadLen  (uint16) - payload length
 *   [25:25+payloadLen]  payload  - ABI-encoded SponsorPayload
 *   [25+payloadLen:]    signature - ECDSA signature from verifyingSigner
 */
contract SponsorPaymaster is BasePaymaster {
    using ECDSA for bytes32;
    using UserOperationLib for PackedUserOperation;

    /// @notice The address authorized to sign sponsorship approvals
    address public verifyingSigner;

    /// @notice Nonces used to prevent signature replay
    mapping(address => uint256) public senderNonce;

    /// @notice Lightweight campaign spending tracker (informational, not enforced on-chain)
    mapping(bytes32 => uint256) public campaignSpending;

    event SignerChanged(address indexed oldSigner, address indexed newSigner);
    event GasSponsored(address indexed sender, bytes32 indexed userOpHash, bytes32 campaignId, uint256 maxCost);

    error InvalidSigner();
    error SignerCannotBeZero();

    /**
     * @notice Constructor
     * @param _entryPoint The EntryPoint contract address
     * @param _owner The owner address
     * @param _signer The verifying signer for sponsorship approvals
     */
    constructor(IEntryPoint _entryPoint, address _owner, address _signer) BasePaymaster(_entryPoint, _owner) {
        if (_signer == address(0)) revert SignerCannotBeZero();
        verifyingSigner = _signer;
    }

    /**
     * @notice Set a new verifying signer
     * @param _signer The new verifying signer address
     */
    function setVerifyingSigner(address _signer) external onlyOwner {
        if (_signer == address(0)) revert SignerCannotBeZero();
        address oldSigner = verifyingSigner;
        verifyingSigner = _signer;
        emit SignerChanged(oldSigner, _signer);
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
     * @return context Context to be passed to postOp
     * @return validationData Packed validation data including time range
     */
    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        internal
        override
        returns (bytes memory context, uint256 validationData)
    {
        (userOpHash); // silence unused variable warning

        bytes calldata paymasterData = _parsePaymasterData(userOp.paymasterAndData);

        // Determine envelope length and split envelope from signature
        uint256 envLen = PaymasterDataLib.envelopeLength(paymasterData);
        bytes calldata envelopeData = paymasterData[:envLen];
        bytes calldata signature = paymasterData[envLen:];

        // Decode envelope
        PaymasterDataLib.Envelope memory env = PaymasterDataLib.decode(envelopeData);

        // Verify paymaster type
        if (env.paymasterType != uint8(PaymasterDataLib.PaymasterType.SPONSOR)) {
            revert PaymasterDataLib.InvalidType(env.paymasterType);
        }

        // Decode SponsorPayload
        PaymasterPayload.SponsorPayload memory payload = PaymasterPayload.decodeSponsor(env.payload);

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
        emit GasSponsored(userOp.sender, keccak256(abi.encode(userOp)), payload.campaignId, maxCost);

        // Return success with time range and context for postOp
        return
            (abi.encode(userOp.sender, payload.campaignId), _packValidationDataSuccess(env.validUntil, env.validAfter));
    }

    /**
     * @notice Post-operation handler — lightweight campaign spending tracker
     * @dev Informational only; no enforcement. Updates campaignSpending for analytics.
     */
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        override
    {
        (actualUserOpFeePerGas); // silence unused warning

        if (mode == PostOpMode.postOpReverted) {
            return;
        }

        (, bytes32 campaignId) = abi.decode(context, (address, bytes32));

        // Track spending per campaign (informational)
        if (campaignId != bytes32(0)) {
            campaignSpending[campaignId] += actualGasCost;
        }
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
