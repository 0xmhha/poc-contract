// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BasePaymaster } from "./BasePaymaster.sol";
import { IEntryPoint } from "../erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { UserOperationLib } from "../erc4337-entrypoint/UserOperationLib.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

/**
 * @title VerifyingPaymaster
 * @notice A paymaster that verifies an off-chain signature to sponsor gas
 * @dev The verifying signer signs a hash of the user operation data to approve sponsorship.
 *      This allows for flexible off-chain policies to determine which operations to sponsor.
 *
 * PaymasterData format:
 *   [0:6] - validUntil (uint48) - timestamp until which sponsorship is valid
 *   [6:12] - validAfter (uint48) - timestamp after which sponsorship is valid
 *   [12:] - signature (65 bytes) - ECDSA signature from verifyingSigner
 */
contract VerifyingPaymaster is BasePaymaster {
    using ECDSA for bytes32;
    using UserOperationLib for PackedUserOperation;

    /// @notice The address authorized to sign sponsorship approvals
    address public verifyingSigner;

    /// @notice Nonces used to prevent signature replay
    mapping(address => uint256) public senderNonce;

    /// @notice Minimum length of paymasterData (timestamps + signature)
    uint256 private constant MIN_VALID_DATA_LENGTH = 12 + 65; // 6 + 6 + 65

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
     * @param validUntil Timestamp until which the signature is valid
     * @param validAfter Timestamp after which the signature is valid
     * @return The hash that needs to be signed
     */
    function getHash(PackedUserOperation calldata userOp, uint48 validUntil, uint48 validAfter)
        public
        view
        returns (bytes32)
    {
        // Hash the operation data excluding the paymaster signature
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees,
                block.chainid,
                address(this),
                validUntil,
                validAfter,
                senderNonce[userOp.sender]
            )
        );
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

        // Validate minimum data length
        if (paymasterData.length < MIN_VALID_DATA_LENGTH) {
            revert InvalidSignatureLength();
        }

        // Parse timestamps
        uint48 validUntil = uint48(bytes6(paymasterData[0:6]));
        uint48 validAfter = uint48(bytes6(paymasterData[6:12]));

        // Extract signature
        bytes calldata signature = paymasterData[12:];

        // Generate hash for signature verification
        bytes32 hash = getHash(userOp, validUntil, validAfter);
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();

        // Verify signature
        address recoveredSigner = ECDSA.recover(ethSignedHash, signature);

        if (recoveredSigner != verifyingSigner) {
            // Return failure but don't revert (for simulation purposes)
            return ("", _packValidationDataFailure(validUntil, validAfter));
        }

        // Increment nonce to prevent replay
        senderNonce[userOp.sender]++;

        // Emit event for tracking
        emit GasSponsored(userOp.sender, keccak256(abi.encode(userOp)), maxCost);

        // Return success with time range and sender context
        return (abi.encode(userOp.sender), _packValidationDataSuccess(validUntil, validAfter));
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
