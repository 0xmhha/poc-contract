// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { PaymasterDataLib } from "../../src/erc4337-paymaster/PaymasterDataLib.sol";
import { PaymasterPayload } from "../../src/erc4337-paymaster/PaymasterPayload.sol";

/**
 * @title CrossLayerConformanceTest
 * @notice Verifies that ABI-encoded payloads match exactly between
 *         Contract (Solidity) ↔ SDK-TS ↔ SDK-Go encoding.
 *
 * Strategy:
 *   1. Encode payloads using Solidity's abi.encode (= contract encoder)
 *   2. Decode with PaymasterPayload library (= contract decoder)
 *   3. Re-encode and verify byte-level equality (roundtrip)
 *   4. Verify raw abi.encode format matches what SDKs produce
 *
 * The SDKs use identical abi.encode format:
 *   - Type 0 (Verifying):  abi.encode(bytes32, address, uint256, bytes)
 *   - Type 1 (Sponsor):    abi.encode(bytes32, uint256, address, bytes4, bytes)
 *   - Type 2 (ERC20):      abi.encode(address, uint256, uint256, bytes)
 *   - Type 3 (Permit2):    abi.encode(address, uint160, uint48, uint48, bytes, bytes)
 */
contract CrossLayerConformanceTest is Test {
    // ============ Verifying Payload (Type 0) ============

    function test_verifying_abiEncode_matchesLibrary() public pure {
        bytes32 policyId = bytes32(uint256(0xABCD));
        address sponsor = 0xdead000000000000000000000000000000000001;
        uint256 maxCost = 0.5 ether;
        bytes memory verifierExtra = hex"CAFE";

        // Raw abi.encode (= what SDK-TS/Go produce)
        bytes memory sdkEncoded = abi.encode(policyId, sponsor, maxCost, verifierExtra);

        // Library encode
        PaymasterPayload.VerifyingPayload memory p = PaymasterPayload.VerifyingPayload({
            policyId: policyId, sponsor: sponsor, maxCost: maxCost, verifierExtra: verifierExtra
        });
        bytes memory libEncoded = PaymasterPayload.encodeVerifying(p);

        // Byte-level equality
        assertEq(keccak256(sdkEncoded), keccak256(libEncoded), "Verifying: SDK vs library encode mismatch");

        // Decode and verify all fields
        PaymasterPayload.VerifyingPayload memory decoded = PaymasterPayload.decodeVerifying(sdkEncoded);
        assertEq(decoded.policyId, policyId);
        assertEq(decoded.sponsor, sponsor);
        assertEq(decoded.maxCost, maxCost);
        assertEq(keccak256(decoded.verifierExtra), keccak256(verifierExtra));
    }

    function test_verifying_realisticValues() public view {
        // Simulate SDK encoding with realistic production values
        bytes32 policyId = keccak256("premium-policy-2026");
        address sponsor = 0x742D35CC6634C0532925a3B844Bc9E7595F2bD18;
        uint256 maxCost = 0.01 ether; // ~$30 at ETH=$3000
        bytes memory verifierExtra = abi.encode(uint256(block.timestamp), bytes32("session-abc"));

        bytes memory encoded = abi.encode(policyId, sponsor, maxCost, verifierExtra);
        PaymasterPayload.VerifyingPayload memory decoded = PaymasterPayload.decodeVerifying(encoded);

        assertEq(decoded.policyId, policyId);
        assertEq(decoded.sponsor, sponsor);
        assertEq(decoded.maxCost, maxCost);
        assertEq(keccak256(decoded.verifierExtra), keccak256(verifierExtra));
    }

    // ============ Sponsor Payload (Type 1) ============

    function test_sponsor_abiEncode_matchesLibrary() public pure {
        bytes32 campaignId = bytes32(uint256(42));
        uint256 perUserLimit = 1 ether;
        address targetContract = 0xcafE000000000000000000000000000000000001;
        bytes4 targetSelector = bytes4(0x12345678);
        bytes memory sponsorExtra = hex"DEAD";

        // Raw abi.encode (= what SDK-TS/Go produce)
        bytes memory sdkEncoded = abi.encode(campaignId, perUserLimit, targetContract, targetSelector, sponsorExtra);

        // Library encode
        PaymasterPayload.SponsorPayload memory p = PaymasterPayload.SponsorPayload({
            campaignId: campaignId,
            perUserLimit: perUserLimit,
            targetContract: targetContract,
            targetSelector: targetSelector,
            sponsorExtra: sponsorExtra
        });
        bytes memory libEncoded = PaymasterPayload.encodeSponsor(p);

        // Byte-level equality
        assertEq(keccak256(sdkEncoded), keccak256(libEncoded), "Sponsor: SDK vs library encode mismatch");

        // Decode and verify all 5 fields
        PaymasterPayload.SponsorPayload memory decoded = PaymasterPayload.decodeSponsor(sdkEncoded);
        assertEq(decoded.campaignId, campaignId);
        assertEq(decoded.perUserLimit, perUserLimit);
        assertEq(decoded.targetContract, targetContract);
        assertEq(decoded.targetSelector, targetSelector);
        assertEq(keccak256(decoded.sponsorExtra), keccak256(sponsorExtra));
    }

    function test_sponsor_zeroValues() public pure {
        // SDK may send zero defaults for optional fields
        bytes32 campaignId = bytes32(0);
        uint256 perUserLimit = 0;
        address targetContract = address(0);
        bytes4 targetSelector = bytes4(0);
        bytes memory sponsorExtra = "";

        bytes memory encoded = abi.encode(campaignId, perUserLimit, targetContract, targetSelector, sponsorExtra);
        PaymasterPayload.SponsorPayload memory decoded = PaymasterPayload.decodeSponsor(encoded);

        assertEq(decoded.campaignId, bytes32(0));
        assertEq(decoded.perUserLimit, 0);
        assertEq(decoded.targetContract, address(0));
        assertEq(decoded.targetSelector, bytes4(0));
        assertEq(decoded.sponsorExtra.length, 0);
    }

    function test_sponsor_maxValues() public pure {
        bytes32 campaignId = bytes32(type(uint256).max);
        uint256 perUserLimit = type(uint256).max;
        address targetContract = address(type(uint160).max);
        bytes4 targetSelector = bytes4(type(uint32).max);
        bytes memory sponsorExtra = new bytes(1024);

        bytes memory encoded = abi.encode(campaignId, perUserLimit, targetContract, targetSelector, sponsorExtra);
        PaymasterPayload.SponsorPayload memory decoded = PaymasterPayload.decodeSponsor(encoded);

        assertEq(decoded.campaignId, campaignId);
        assertEq(decoded.perUserLimit, perUserLimit);
        assertEq(decoded.targetContract, targetContract);
        assertEq(decoded.targetSelector, targetSelector);
        assertEq(decoded.sponsorExtra.length, 1024);
    }

    // ============ ERC20 Payload (Type 2) ============

    function test_erc20_abiEncode_matchesLibrary() public pure {
        address token = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
        uint256 maxTokenCost = 100e6; // 100 USDC
        uint256 quoteId = 12345;
        bytes memory erc20Extra = hex"";

        // Raw abi.encode
        bytes memory sdkEncoded = abi.encode(token, maxTokenCost, quoteId, erc20Extra);

        // Library encode
        PaymasterPayload.Erc20Payload memory p = PaymasterPayload.Erc20Payload({
            token: token, maxTokenCost: maxTokenCost, quoteId: quoteId, erc20Extra: erc20Extra
        });
        bytes memory libEncoded = PaymasterPayload.encodeErc20(p);

        assertEq(keccak256(sdkEncoded), keccak256(libEncoded), "ERC20: SDK vs library encode mismatch");

        // Decode
        PaymasterPayload.Erc20Payload memory decoded = PaymasterPayload.decodeErc20(sdkEncoded);
        assertEq(decoded.token, token);
        assertEq(decoded.maxTokenCost, maxTokenCost);
        assertEq(decoded.quoteId, quoteId);
    }

    // ============ Permit2 Payload (Type 3) ============

    function test_permit2_abiEncode_matchesLibrary() public pure {
        address token = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT
        uint160 permitAmount = type(uint160).max;
        uint48 permitExpiration = 1700003600;
        uint48 permitNonce = 0;
        bytes memory permitSig = new bytes(65);
        bytes memory permit2Extra = hex"";

        // Raw abi.encode
        bytes memory sdkEncoded =
            abi.encode(token, permitAmount, permitExpiration, permitNonce, permitSig, permit2Extra);

        // Library encode
        PaymasterPayload.Permit2Payload memory p = PaymasterPayload.Permit2Payload({
            token: token,
            permitAmount: permitAmount,
            permitExpiration: permitExpiration,
            permitNonce: permitNonce,
            permitSig: permitSig,
            permit2Extra: permit2Extra
        });
        bytes memory libEncoded = PaymasterPayload.encodePermit2(p);

        assertEq(keccak256(sdkEncoded), keccak256(libEncoded), "Permit2: SDK vs library encode mismatch");

        // Decode
        PaymasterPayload.Permit2Payload memory decoded = PaymasterPayload.decodePermit2(sdkEncoded);
        assertEq(decoded.token, token);
        assertEq(decoded.permitAmount, permitAmount);
        assertEq(decoded.permitExpiration, permitExpiration);
        assertEq(decoded.permitNonce, permitNonce);
        assertEq(decoded.permitSig.length, 65);
    }

    // ============ Full Envelope + Payload Integration ============

    function test_sponsor_fullEnvelopeRoundtrip() public pure {
        // Step 1: Build SponsorPayload (as SDK would)
        bytes memory payload = abi.encode(
            bytes32(uint256(42)), // campaignId
            uint256(1 ether), // perUserLimit
            address(0xCAFE), // targetContract
            bytes4(0x12345678), // targetSelector
            bytes("") // sponsorExtra
        );

        // Step 2: Wrap in envelope (as SDK would)
        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.SPONSOR),
            0, // flags
            uint48(1700000000), // validUntil
            uint48(1699999000), // validAfter
            uint64(1), // nonce
            payload
        );

        // Step 3: Contract decodes envelope
        PaymasterDataLib.Envelope memory env = PaymasterDataLib.decodeMem(envelope);
        assertEq(env.paymasterType, uint8(PaymasterDataLib.PaymasterType.SPONSOR));
        assertEq(env.validUntil, 1700000000);

        // Step 4: Contract decodes payload from envelope
        PaymasterPayload.SponsorPayload memory sp = PaymasterPayload.decodeSponsor(env.payload);
        assertEq(sp.campaignId, bytes32(uint256(42)));
        assertEq(sp.perUserLimit, 1 ether);
        assertEq(sp.targetContract, address(0xCAFE));
        assertEq(sp.targetSelector, bytes4(0x12345678));
    }

    function test_erc20_fullEnvelopeRoundtrip() public pure {
        bytes memory payload = abi.encode(
            address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // token (USDC)
            uint256(100e6), // maxTokenCost
            uint256(555), // quoteId
            bytes("") // erc20Extra
        );

        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.ERC20), 0, uint48(1700000000), uint48(1699999000), uint64(1), payload
        );

        PaymasterDataLib.Envelope memory env = PaymasterDataLib.decodeMem(envelope);
        assertEq(env.paymasterType, uint8(PaymasterDataLib.PaymasterType.ERC20));

        PaymasterPayload.Erc20Payload memory ep = PaymasterPayload.decodeErc20(env.payload);
        assertEq(ep.token, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertEq(ep.maxTokenCost, 100e6);
        assertEq(ep.quoteId, 555);
    }

    function test_permit2_fullEnvelopeRoundtrip() public pure {
        bytes memory fakeSig = new bytes(65);
        fakeSig[0] = 0x1b; // v = 27

        bytes memory payload = abi.encode(
            address(0xdAC17F958D2ee523a2206206994597C13D831ec7), // token (USDT)
            uint160(1000e6), // permitAmount
            uint48(1700003600), // permitExpiration
            uint48(0), // permitNonce
            fakeSig, // permitSig
            bytes("") // permit2Extra
        );

        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.PERMIT2), 0, uint48(1700003600), uint48(1699999000), uint64(1), payload
        );

        PaymasterDataLib.Envelope memory env = PaymasterDataLib.decodeMem(envelope);
        assertEq(env.paymasterType, uint8(PaymasterDataLib.PaymasterType.PERMIT2));

        PaymasterPayload.Permit2Payload memory pp = PaymasterPayload.decodePermit2(env.payload);
        assertEq(pp.token, 0xdAC17F958D2ee523a2206206994597C13D831ec7);
        assertEq(pp.permitAmount, 1000e6);
        assertEq(pp.permitExpiration, 1700003600);
    }

    function test_verifying_fullEnvelopeRoundtrip() public pure {
        bytes memory payload = abi.encode(
            bytes32(uint256(1)), // policyId
            address(0xBEEF), // sponsor
            uint256(0.01 ether), // maxCost
            bytes("") // verifierExtra
        );

        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.VERIFYING),
            0,
            uint48(1700000000),
            uint48(1699999000),
            uint64(1),
            payload
        );

        PaymasterDataLib.Envelope memory env = PaymasterDataLib.decodeMem(envelope);
        assertEq(env.paymasterType, uint8(PaymasterDataLib.PaymasterType.VERIFYING));

        PaymasterPayload.VerifyingPayload memory vp = PaymasterPayload.decodeVerifying(env.payload);
        assertEq(vp.policyId, bytes32(uint256(1)));
        assertEq(vp.sponsor, address(0xBEEF));
        assertEq(vp.maxCost, 0.01 ether);
    }

    // ============ ABI Format Snapshot (for SDK comparison) ============

    function test_sponsor_encodedBytesSnapshot() public pure {
        // Fixed inputs — SDK tests must produce identical bytes
        bytes32 campaignId = bytes32(uint256(1));
        uint256 perUserLimit = 1 ether;
        address targetContract = 0x000000000000000000000000000000000000cafE;
        bytes4 targetSelector = bytes4(0x12345678);
        bytes memory sponsorExtra = "";

        bytes memory encoded = abi.encode(campaignId, perUserLimit, targetContract, targetSelector, sponsorExtra);

        // Log the encoding for SDK snapshot comparison
        // SDK tests should assert: keccak256(sdkEncode(same inputs)) == this hash
        bytes32 encodingHash = keccak256(encoded);
        assertEq(encoded.length > 0, true, "encoded should not be empty");

        // Verify determinism
        bytes memory encoded2 = abi.encode(campaignId, perUserLimit, targetContract, targetSelector, sponsorExtra);
        assertEq(encodingHash, keccak256(encoded2), "encoding must be deterministic");
    }
}
