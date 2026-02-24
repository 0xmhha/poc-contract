// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { PaymasterDataLib } from "../../src/erc4337-paymaster/PaymasterDataLib.sol";
import { PaymasterPayload } from "../../src/erc4337-paymaster/PaymasterPayload.sol";

/**
 * @title DataHelper
 * @notice Helper contract to bridge memory->calldata for library functions
 */
contract DataHelper {
    function isSupported(bytes calldata data) external pure returns (bool) {
        return PaymasterDataLib.isSupported(data);
    }

    function decode(bytes calldata data) external pure returns (PaymasterDataLib.Envelope memory) {
        return PaymasterDataLib.decode(data);
    }

    function decodeMem(bytes memory data) external pure returns (PaymasterDataLib.Envelope memory) {
        return PaymasterDataLib.decodeMem(data);
    }

    function envelopeLength(bytes calldata data) external pure returns (uint256) {
        return PaymasterDataLib.envelopeLength(data);
    }

    function encode(
        uint8 paymasterType,
        uint8 flags,
        uint48 validUntil,
        uint48 validAfter,
        uint64 nonce,
        bytes memory payload
    ) external pure returns (bytes memory) {
        return PaymasterDataLib.encode(paymasterType, flags, validUntil, validAfter, nonce, payload);
    }
}

/**
 * @title PaymasterDataTest
 * @notice Tests for the envelope library (encode/decode roundtrip, boundary checks)
 */
contract PaymasterDataTest is Test {
    DataHelper public helper;

    function setUp() public {
        helper = new DataHelper();
    }

    // ============ isSupported Detection ============

    function test_isSupported_trueForSupportedData() public view {
        bytes memory data = PaymasterDataLib.encode(0, 0, 0, 0, 0, "");
        assertEq(uint8(data[0]), 1);
        assertTrue(helper.isSupported(data));
    }

    function test_isSupported_falseForEmptyData() public view {
        bytes memory empty = "";
        assertFalse(helper.isSupported(empty));
    }

    function test_isSupported_falseForShortData() public view {
        bytes memory short = hex"01";
        assertFalse(helper.isSupported(short));
    }

    // ============ Encode/Decode Roundtrip (calldata path) ============

    function test_encodeDecode_emptyPayload_calldata() public view {
        bytes memory encoded = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.VERIFYING), 0, uint48(1000), uint48(500), uint64(42), ""
        );

        PaymasterDataLib.Envelope memory env = helper.decode(encoded);

        assertEq(env.version, 1);
        assertEq(env.paymasterType, 0);
        assertEq(env.flags, 0);
        assertEq(env.validUntil, 1000);
        assertEq(env.validAfter, 500);
        assertEq(env.nonce, 42);
        assertEq(env.payload.length, 0);
    }

    function test_encodeDecode_withPayload_calldata() public view {
        bytes memory payload = abi.encode(address(0xdead), uint256(100));
        bytes memory encoded = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.ERC20), 0, uint48(9999), uint48(1111), uint64(7), payload
        );

        PaymasterDataLib.Envelope memory env = helper.decode(encoded);

        assertEq(env.version, 1);
        assertEq(env.paymasterType, 2);
        assertEq(env.validUntil, 9999);
        assertEq(env.validAfter, 1111);
        assertEq(env.nonce, 7);
        assertEq(keccak256(env.payload), keccak256(payload));
    }

    // ============ Encode/Decode Roundtrip (memory path) ============

    function test_encodeDecode_emptyPayload_memory() public pure {
        bytes memory encoded = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.VERIFYING), 0, uint48(1000), uint48(500), uint64(42), ""
        );

        // Use memory decode overload
        PaymasterDataLib.Envelope memory env = PaymasterDataLib.decodeMem(encoded);

        assertEq(env.version, 1);
        assertEq(env.paymasterType, 0);
        assertEq(env.flags, 0);
        assertEq(env.validUntil, 1000);
        assertEq(env.validAfter, 500);
        assertEq(env.nonce, 42);
        assertEq(env.payload.length, 0);
    }

    function test_encodeDecode_withPayload_memory() public pure {
        bytes memory payload = abi.encode(address(0xdead), uint256(100));
        bytes memory encoded = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.ERC20), 0, uint48(9999), uint48(1111), uint64(7), payload
        );

        PaymasterDataLib.Envelope memory env = PaymasterDataLib.decodeMem(encoded);

        assertEq(env.version, 1);
        assertEq(env.paymasterType, 2);
        assertEq(env.validUntil, 9999);
        assertEq(env.validAfter, 1111);
        assertEq(env.nonce, 7);
        assertEq(keccak256(env.payload), keccak256(payload));
    }

    function test_encodeDecode_allTypes() public pure {
        for (uint8 t = 0; t <= 3; t++) {
            bytes memory payload = abi.encode(t);
            bytes memory encoded = PaymasterDataLib.encode(t, 0, 0, 0, 0, payload);
            PaymasterDataLib.Envelope memory env = PaymasterDataLib.decodeMem(encoded);
            assertEq(env.paymasterType, t);
        }
    }

    function test_encodeDecode_withFlags() public pure {
        bytes memory encoded = PaymasterDataLib.encode(0, 0xFF, 0, 0, 0, "");
        PaymasterDataLib.Envelope memory env = PaymasterDataLib.decodeMem(encoded);
        assertEq(env.flags, 0xFF);
    }

    // ============ Encode Validation ============

    function test_encode_revertIfInvalidType() public {
        vm.expectRevert(abi.encodeWithSelector(PaymasterDataLib.InvalidType.selector, uint8(4)));
        helper.encode(4, 0, 0, 0, 0, "");
    }

    // ============ Decode Validation ============

    function test_decode_revertIfTooShort() public {
        bytes memory tooShort = new bytes(24);
        tooShort[0] = bytes1(uint8(1));
        vm.expectRevert(abi.encodeWithSelector(PaymasterDataLib.InvalidLength.selector, uint256(24)));
        helper.decodeMem(tooShort);
    }

    function test_decode_revertIfWrongVersion() public {
        bytes memory data = PaymasterDataLib.encode(0, 0, 0, 0, 0, "");
        data[0] = bytes1(uint8(2));
        vm.expectRevert(abi.encodeWithSelector(PaymasterDataLib.InvalidVersion.selector, uint8(2)));
        helper.decodeMem(data);
    }

    function test_decode_revertIfInvalidType() public {
        bytes memory data = PaymasterDataLib.encode(0, 0, 0, 0, 0, "");
        data[1] = bytes1(uint8(4));
        vm.expectRevert(abi.encodeWithSelector(PaymasterDataLib.InvalidType.selector, uint8(4)));
        helper.decodeMem(data);
    }

    function test_decode_revertIfLengthMismatch() public {
        bytes memory data = PaymasterDataLib.encode(0, 0, 0, 0, 0, abi.encode(uint256(1)));
        bytes memory corrupted = abi.encodePacked(data, bytes1(0));
        vm.expectRevert(abi.encodeWithSelector(PaymasterDataLib.InvalidLength.selector, corrupted.length));
        helper.decodeMem(corrupted);
    }

    // ============ Envelope Length ============

    function test_envelopeLength_emptyPayload() public view {
        bytes memory data = PaymasterDataLib.encode(0, 0, 0, 0, 0, "");
        assertEq(helper.envelopeLength(data), 25);
    }

    function test_envelopeLength_withPayload() public view {
        bytes memory payload = abi.encode(uint256(1), uint256(2));
        bytes memory data = PaymasterDataLib.encode(0, 0, 0, 0, 0, payload);
        assertEq(helper.envelopeLength(data), 25 + payload.length);
    }

    // ============ Hash Determinism ============

    function test_hashForSignature_deterministic() public pure {
        bytes32 domain = keccak256("test-domain");
        bytes32 userOpHash = keccak256("user-op");
        bytes memory envelope = PaymasterDataLib.encode(0, 0, 1000, 500, 1, "");

        bytes32 hash1 = PaymasterDataLib.hashForSignature(domain, userOpHash, envelope);
        bytes32 hash2 = PaymasterDataLib.hashForSignature(domain, userOpHash, envelope);
        assertEq(hash1, hash2);
    }

    function test_hashForSignature_differentInputsDifferentHash() public pure {
        bytes32 domain = keccak256("test-domain");
        bytes32 userOpHash = keccak256("user-op");
        bytes memory envelope1 = PaymasterDataLib.encode(0, 0, 1000, 500, 1, "");
        bytes memory envelope2 = PaymasterDataLib.encode(0, 0, 1001, 500, 1, "");

        bytes32 hash1 = PaymasterDataLib.hashForSignature(domain, userOpHash, envelope1);
        bytes32 hash2 = PaymasterDataLib.hashForSignature(domain, userOpHash, envelope2);
        assertNotEq(hash1, hash2);
    }

    // ============ Payload Roundtrip ============

    function test_verifyingPayload_roundtrip() public pure {
        PaymasterPayload.VerifyingPayload memory original = PaymasterPayload.VerifyingPayload({
            policyId: bytes32(uint256(1)), sponsor: address(0xBEEF), maxCost: 1 ether, verifierExtra: ""
        });

        bytes memory encoded = PaymasterPayload.encodeVerifying(original);
        PaymasterPayload.VerifyingPayload memory decoded = PaymasterPayload.decodeVerifying(encoded);

        assertEq(decoded.policyId, original.policyId);
        assertEq(decoded.sponsor, original.sponsor);
        assertEq(decoded.maxCost, original.maxCost);
        assertEq(decoded.verifierExtra.length, 0);
    }

    function test_sponsorPayload_roundtrip() public pure {
        PaymasterPayload.SponsorPayload memory original = PaymasterPayload.SponsorPayload({
            campaignId: bytes32(uint256(42)),
            perUserLimit: 1 ether,
            targetContract: address(0xCAFE),
            targetSelector: bytes4(0x12345678),
            sponsorExtra: ""
        });

        bytes memory encoded = PaymasterPayload.encodeSponsor(original);
        PaymasterPayload.SponsorPayload memory decoded = PaymasterPayload.decodeSponsor(encoded);

        assertEq(decoded.campaignId, bytes32(uint256(42)));
        assertEq(decoded.perUserLimit, 1 ether);
        assertEq(decoded.targetContract, address(0xCAFE));
        assertEq(decoded.targetSelector, bytes4(0x12345678));
        assertEq(decoded.sponsorExtra.length, 0);
    }

    function test_erc20Payload_roundtrip() public pure {
        PaymasterPayload.Erc20Payload memory original = PaymasterPayload.Erc20Payload({
            token: address(0xCAFE), maxTokenCost: 2200e6, quoteId: 99, erc20Extra: ""
        });

        bytes memory encoded = PaymasterPayload.encodeErc20(original);
        PaymasterPayload.Erc20Payload memory decoded = PaymasterPayload.decodeErc20(encoded);

        assertEq(decoded.token, address(0xCAFE));
        assertEq(decoded.maxTokenCost, 2200e6);
        assertEq(decoded.quoteId, 99);
    }

    function test_permit2Payload_roundtrip() public pure {
        bytes memory fakeSig = new bytes(65);
        PaymasterPayload.Permit2Payload memory original = PaymasterPayload.Permit2Payload({
            token: address(0xDAD),
            permitAmount: type(uint160).max,
            permitExpiration: 3600,
            permitNonce: 0,
            permitSig: fakeSig,
            permit2Extra: ""
        });

        bytes memory encoded = PaymasterPayload.encodePermit2(original);
        PaymasterPayload.Permit2Payload memory decoded = PaymasterPayload.decodePermit2(encoded);

        assertEq(decoded.token, address(0xDAD));
        assertEq(decoded.permitAmount, type(uint160).max);
        assertEq(decoded.permitSig.length, 65);
    }

    // ============ Cross-path Consistency ============

    function test_calldataAndMemoryDecode_consistent() public view {
        bytes memory payload = abi.encode(address(0xBEEF), uint256(42));
        bytes memory encoded = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.SPONSOR), 0x01, uint48(5000), uint48(100), uint64(99), payload
        );

        // Memory decode
        PaymasterDataLib.Envelope memory envMem = PaymasterDataLib.decodeMem(encoded);
        // Calldata decode via helper
        PaymasterDataLib.Envelope memory envCd = helper.decode(encoded);

        assertEq(envMem.version, envCd.version);
        assertEq(envMem.paymasterType, envCd.paymasterType);
        assertEq(envMem.flags, envCd.flags);
        assertEq(envMem.validUntil, envCd.validUntil);
        assertEq(envMem.validAfter, envCd.validAfter);
        assertEq(envMem.nonce, envCd.nonce);
        assertEq(keccak256(envMem.payload), keccak256(envCd.payload));
    }
}
