// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title PaymasterDataLib
 * @notice Standard envelope encoder/decoder for all Paymaster types
 * @dev Provides a common header format across verifying, sponsor, erc20, and permit2 paymasters.
 *
 * Envelope layout (25-byte fixed header + variable payload):
 *   [0]    version      (uint8)  - must be 0x01
 *   [1]    paymasterType(uint8)  - 0=verifying,1=sponsor,2=erc20,3=permit2
 *   [2]    flags        (uint8)  - reserved for future use
 *   [3:9]  validUntil   (uint48) - expiration timestamp
 *   [9:15] validAfter   (uint48) - activation timestamp
 *   [15:23] nonce       (uint64) - paymaster-level nonce
 *   [23:25] payloadLen  (uint16) - length of the type-specific payload
 *   [25:25+payloadLen]  payload  - type-specific ABI-encoded data
 */
library PaymasterDataLib {
    // ============ Offsets ============

    uint256 internal constant VERSION_OFFSET = 0;
    uint256 internal constant TYPE_OFFSET = 1;
    uint256 internal constant FLAGS_OFFSET = 2;
    uint256 internal constant VALID_UNTIL_OFFSET = 3; // 6 bytes
    uint256 internal constant VALID_AFTER_OFFSET = 9; // 6 bytes
    uint256 internal constant NONCE_OFFSET = 15; // 8 bytes
    uint256 internal constant PAYLOAD_LEN_OFFSET = 23; // 2 bytes
    uint256 internal constant PAYLOAD_OFFSET = 25;
    uint256 internal constant HEADER_SIZE = 25;

    uint8 internal constant VERSION = 1;

    // ============ Types ============

    enum PaymasterType {
        VERIFYING, // 0
        SPONSOR, // 1
        ERC20, // 2
        PERMIT2 // 3
    }

    struct Envelope {
        uint8 version;
        uint8 paymasterType;
        uint8 flags;
        uint48 validUntil;
        uint48 validAfter;
        uint64 nonce;
        bytes payload;
    }

    // ============ Errors ============

    error InvalidVersion(uint8 version);
    error InvalidLength(uint256 length);
    error InvalidType(uint8 paymasterType);

    // ============ Detection ============

    /**
     * @notice Check whether the data uses supported format (first byte == VERSION)
     * @param data Raw paymasterData (after the 52-byte static prefix)
     */
    function isSupported(bytes calldata data) internal pure returns (bool) {
        return data.length >= HEADER_SIZE && uint8(bytes1(data[0:1])) == VERSION;
    }

    // ============ Decode ============

    /**
     * @notice Compute the total envelope length (header + payload) from raw data
     * @dev Use this to slice off trailing bytes (e.g. paymaster signature)
     */
    function envelopeLength(bytes calldata data) internal pure returns (uint256) {
        if (data.length < HEADER_SIZE) revert InvalidLength(data.length);
        uint16 payloadLen = uint16(bytes2(data[PAYLOAD_LEN_OFFSET:PAYLOAD_LEN_OFFSET + 2]));
        return PAYLOAD_OFFSET + uint256(payloadLen);
    }

    /**
     * @notice Decode an envelope from calldata
     * @dev The caller MUST pass exactly the envelope bytes (use envelopeLength to slice).
     *      Reverts if version != VERSION, type > 3, or length mismatch.
     */
    function decode(bytes calldata data) internal pure returns (Envelope memory env) {
        if (data.length < HEADER_SIZE) revert InvalidLength(data.length);

        env.version = uint8(bytes1(data[VERSION_OFFSET:VERSION_OFFSET + 1]));
        if (env.version != VERSION) revert InvalidVersion(env.version);

        env.paymasterType = uint8(bytes1(data[TYPE_OFFSET:TYPE_OFFSET + 1]));
        if (env.paymasterType > uint8(PaymasterType.PERMIT2)) revert InvalidType(env.paymasterType);

        env.flags = uint8(bytes1(data[FLAGS_OFFSET:FLAGS_OFFSET + 1]));
        env.validUntil = uint48(bytes6(data[VALID_UNTIL_OFFSET:VALID_UNTIL_OFFSET + 6]));
        env.validAfter = uint48(bytes6(data[VALID_AFTER_OFFSET:VALID_AFTER_OFFSET + 6]));
        env.nonce = uint64(bytes8(data[NONCE_OFFSET:NONCE_OFFSET + 8]));

        uint16 payloadLen = uint16(bytes2(data[PAYLOAD_LEN_OFFSET:PAYLOAD_LEN_OFFSET + 2]));
        uint256 expectedLen = PAYLOAD_OFFSET + uint256(payloadLen);
        if (data.length != expectedLen) revert InvalidLength(data.length);

        env.payload = data[PAYLOAD_OFFSET:expectedLen];
    }

    /**
     * @notice Decode an envelope from memory (for tests and off-chain usage)
     */
    function decodeMem(bytes memory data) internal pure returns (Envelope memory env) {
        if (data.length < HEADER_SIZE) revert InvalidLength(data.length);

        env.version = uint8(data[VERSION_OFFSET]);
        if (env.version != VERSION) revert InvalidVersion(env.version);

        env.paymasterType = uint8(data[TYPE_OFFSET]);
        if (env.paymasterType > uint8(PaymasterType.PERMIT2)) revert InvalidType(env.paymasterType);

        env.flags = uint8(data[FLAGS_OFFSET]);

        // Parse uint48 validUntil from 6 bytes at offset 3
        uint48 validUntil;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            validUntil := shr(208, mload(add(add(data, 32), 3))) // shift right by 256-48=208 bits
        }
        env.validUntil = validUntil;

        uint48 validAfter;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            validAfter := shr(208, mload(add(add(data, 32), 9)))
        }
        env.validAfter = validAfter;

        uint64 nonce;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            nonce := shr(192, mload(add(add(data, 32), 15))) // shift right by 256-64=192 bits
        }
        env.nonce = nonce;

        uint16 payloadLen;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            payloadLen := shr(240, mload(add(add(data, 32), 23))) // shift right by 256-16=240 bits
        }

        uint256 expectedLen = PAYLOAD_OFFSET + uint256(payloadLen);
        if (data.length != expectedLen) revert InvalidLength(data.length);

        // Copy payload
        env.payload = new bytes(payloadLen);
        for (uint256 i = 0; i < payloadLen; i++) {
            env.payload[i] = data[PAYLOAD_OFFSET + i];
        }
    }

    // ============ Encode ============

    /**
     * @notice Encode an envelope from components
     * @param paymasterType Paymaster type (0-3)
     * @param flags Reserved flags (0 for now)
     * @param validUntil Expiration timestamp
     * @param validAfter Activation timestamp
     * @param nonce Paymaster nonce
     * @param payload ABI-encoded type-specific data
     */
    function encode(
        uint8 paymasterType,
        uint8 flags,
        uint48 validUntil,
        uint48 validAfter,
        uint64 nonce,
        bytes memory payload
    ) internal pure returns (bytes memory out) {
        if (paymasterType > uint8(PaymasterType.PERMIT2)) revert InvalidType(paymasterType);
        if (payload.length > type(uint16).max) revert InvalidLength(payload.length);

        out = abi.encodePacked(
            bytes1(VERSION),
            bytes1(paymasterType),
            bytes1(flags),
            bytes6(validUntil),
            bytes6(validAfter),
            bytes8(nonce),
            bytes2(uint16(payload.length)),
            payload
        );
    }

    // ============ Hashing ============

    /**
     * @notice Compute the hash to be signed by the paymaster signer
     * @param domainSeparator EIP-712-like domain separator
     * @param userOpCoreHash Hash of the UserOp core fields
     * @param envelopeWithoutSig Raw envelope bytes (header + payload, no trailing signature)
     */
    function hashForSignature(bytes32 domainSeparator, bytes32 userOpCoreHash, bytes memory envelopeWithoutSig)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(domainSeparator, userOpCoreHash, keccak256(envelopeWithoutSig)));
    }
}
