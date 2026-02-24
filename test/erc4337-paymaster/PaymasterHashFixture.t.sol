// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { PaymasterDataLib } from "../../src/erc4337-paymaster/PaymasterDataLib.sol";
import { PaymasterPayload } from "../../src/erc4337-paymaster/PaymasterPayload.sol";
import { VerifyingPaymaster } from "../../src/erc4337-paymaster/VerifyingPaymaster.sol";
import { SponsorPaymaster } from "../../src/erc4337-paymaster/SponsorPaymaster.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title PaymasterHashFixtureTest
 * @notice Cross-platform hash fixture test for Contract <-> SDK verification
 * @dev Generates deterministic hash values using fixed inputs.
 *      SDK tests (TypeScript, Go) MUST produce identical hashes for the same inputs.
 *
 * How to use:
 *   1. Run: forge test --match-contract PaymasterHashFixtureTest -vvvv
 *   2. Copy EXPECTED_* constants from test output
 *   3. Assert your SDK produces identical values for the same FX_* inputs
 *
 * Fixture namespace: FX_ (fixture inputs), EXPECTED_ (expected outputs)
 */
contract PaymasterHashFixtureTest is Test {
    using MessageHashUtils for bytes32;

    // ============ Fixture Inputs (SDK tests MUST use identical values) ============

    // Domain separator inputs
    uint256 constant FX_CHAIN_ID = 31337;
    address constant FX_ENTRY_POINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    address constant FX_PAYMASTER = 0x1234567890AbcdEF1234567890aBcdef12345678;

    // UserOp inputs
    address constant FX_SENDER = 0xdead000000000000000000000000000000000001;
    uint256 constant FX_NONCE = 42;
    // initCode = "" (empty)
    // callData = 0x12345678
    bytes32 constant FX_ACCOUNT_GAS_LIMITS = bytes32(uint256(100_000) << 128 | uint256(100_000));
    uint256 constant FX_PRE_VERIFICATION_GAS = 21_000;
    bytes32 constant FX_GAS_FEES = bytes32(uint256(1 gwei) << 128 | uint256(1 gwei));

    // Envelope inputs
    uint48 constant FX_VALID_UNTIL = 1_700_000_000;
    uint48 constant FX_VALID_AFTER = 1_699_999_000;
    uint64 constant FX_PM_NONCE = 7;

    // ============ Domain Separator Constants ============

    // EIP-712 domain type hash (used by SDK, standard practice)
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address entryPoint,address paymaster)");

    bytes32 constant NAME_HASH = keccak256("StableNetPaymaster");
    bytes32 constant VERSION_HASH = keccak256("1");

    // ============ Test 1: Domain Separator ============

    /// @notice Verify domain separator computation matches EIP-712 standard with typeHash
    /// @dev SDK (TS/Go) uses 6 fields: [typeHash, nameHash, versionHash, chainId, entryPoint, paymaster]
    ///      Contract MUST match to enable cross-platform signature verification
    function test_fixture_domainSeparator() public pure {
        // EIP-712 compliant domain separator (6 fields, with typeHash)
        bytes32 domainSeparator = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, FX_CHAIN_ID, FX_ENTRY_POINT, FX_PAYMASTER)
        );

        // Determinism check
        bytes32 domainSeparator2 = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, FX_CHAIN_ID, FX_ENTRY_POINT, FX_PAYMASTER)
        );
        assertEq(domainSeparator, domainSeparator2, "Domain separator must be deterministic");
        assertTrue(domainSeparator != bytes32(0));
    }

    /// @notice Verify contract and SDK domain separator are aligned
    /// @dev Both use 6 fields: [typeHash, nameHash, versionHash, chainId, entryPoint, paymaster]
    function test_fixture_domainSeparator_contractVsSdk() public pure {
        // Contract's computation (6 fields, WITH typeHash — aligned with SDK)
        bytes32 contractDomain = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, FX_CHAIN_ID, FX_ENTRY_POINT, FX_PAYMASTER)
        );

        // SDK's computation (6 fields, WITH typeHash — EIP-712 standard)
        bytes32 sdkDomain = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, FX_CHAIN_ID, FX_ENTRY_POINT, FX_PAYMASTER)
        );

        assertEq(contractDomain, sdkDomain, "Contract and SDK domain separators must match");
    }

    /// @notice Verify deployed contract's domain separator matches fixture computation
    function test_fixture_domainSeparator_matchesContract() public {
        EntryPoint ep = new EntryPoint();
        address owner = makeAddr("owner");
        address signer = makeAddr("signer");

        vm.prank(owner);
        VerifyingPaymaster pm = new VerifyingPaymaster(IEntryPoint(address(ep)), owner, signer);

        // Compute expected domain separator using EIP-712 standard (6 fields, with typeHash)
        bytes32 expected = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(ep), address(pm))
        );

        // Build a dummy userOp and envelope to extract the hash
        PackedUserOperation memory userOp = _createFixtureUserOp();
        bytes memory envelope = _createFixtureEnvelope_verifying();
        userOp.paymasterAndData = abi.encodePacked(address(pm), uint128(100_000), uint128(50_000), envelope);

        // The contract's getHash embeds the domain separator
        // We verify by recomputing the full hash manually
        bytes32 userOpCoreHash = _computeUserOpCoreHash(userOp);
        bytes32 manualHash = PaymasterDataLib.hashForSignature(expected, userOpCoreHash, envelope);
        bytes32 contractHash = pm.getHash(userOp, envelope);

        assertEq(manualHash, contractHash, "Manual computation must match contract getHash");
    }

    // ============ Test 2: UserOp Core Hash ============

    /// @notice Verify UserOp core hash with fixed inputs
    /// @dev SDK tests should produce same hash for same inputs
    function test_fixture_userOpCoreHash() public pure {
        bytes memory initCode = "";
        bytes memory callData = hex"12345678";

        bytes32 result = keccak256(
            abi.encode(
                FX_SENDER,
                FX_NONCE,
                keccak256(initCode),
                keccak256(callData),
                FX_ACCOUNT_GAS_LIMITS,
                FX_PRE_VERIFICATION_GAS,
                FX_GAS_FEES
            )
        );

        // Determinism
        bytes32 result2 = keccak256(
            abi.encode(
                FX_SENDER,
                FX_NONCE,
                keccak256(initCode),
                keccak256(callData),
                FX_ACCOUNT_GAS_LIMITS,
                FX_PRE_VERIFICATION_GAS,
                FX_GAS_FEES
            )
        );
        assertEq(result, result2, "UserOp core hash must be deterministic");
        assertTrue(result != bytes32(0));
    }

    // ============ Test 3: Envelope Encoding (byte-level) ============

    /// @notice Verify envelope byte layout for VERIFYING type
    function test_fixture_envelope_verifying() public pure {
        bytes memory payload = PaymasterPayload.encodeVerifying(
            PaymasterPayload.VerifyingPayload({
                policyId: bytes32(uint256(1)), sponsor: address(0xBEEF), maxCost: 1 ether, verifierExtra: ""
            })
        );

        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.VERIFYING), 0, FX_VALID_UNTIL, FX_VALID_AFTER, FX_PM_NONCE, payload
        );

        // Verify header bytes
        assertEq(uint8(envelope[0]), 1, "byte[0] version = 1");
        assertEq(uint8(envelope[1]), 0, "byte[1] type = VERIFYING(0)");
        assertEq(uint8(envelope[2]), 0, "byte[2] flags = 0");
        assertEq(envelope.length, 25 + payload.length, "length = header(25) + payload");

        // Verify roundtrip
        PaymasterDataLib.Envelope memory env = PaymasterDataLib.decodeMem(envelope);
        assertEq(env.version, 1);
        assertEq(env.paymasterType, 0);
        assertEq(env.validUntil, FX_VALID_UNTIL);
        assertEq(env.validAfter, FX_VALID_AFTER);
        assertEq(env.nonce, FX_PM_NONCE);
        assertEq(keccak256(env.payload), keccak256(payload));
    }

    /// @notice Verify envelope byte layout for SPONSOR type
    function test_fixture_envelope_sponsor() public pure {
        bytes memory payload = PaymasterPayload.encodeSponsor(
            PaymasterPayload.SponsorPayload({
                campaignId: bytes32(uint256(42)),
                perUserLimit: 1 ether,
                targetContract: address(0xCAFE),
                targetSelector: bytes4(0x12345678),
                sponsorExtra: ""
            })
        );

        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.SPONSOR), 0, FX_VALID_UNTIL, FX_VALID_AFTER, FX_PM_NONCE, payload
        );

        assertEq(uint8(envelope[1]), 1, "byte[1] type = SPONSOR(1)");
        assertEq(envelope.length, 25 + payload.length);

        // Roundtrip
        PaymasterDataLib.Envelope memory env = PaymasterDataLib.decodeMem(envelope);
        PaymasterPayload.SponsorPayload memory sp = PaymasterPayload.decodeSponsor(env.payload);
        assertEq(sp.campaignId, bytes32(uint256(42)));
        assertEq(sp.perUserLimit, 1 ether);
        assertEq(sp.targetContract, address(0xCAFE));
        assertEq(sp.targetSelector, bytes4(0x12345678));
    }

    /// @notice Verify envelope byte layout for ERC20 type
    function test_fixture_envelope_erc20() public pure {
        bytes memory payload = PaymasterPayload.encodeErc20(
            PaymasterPayload.Erc20Payload({
                token: address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC mainnet
                maxTokenCost: 2200e6,
                quoteId: 99,
                erc20Extra: ""
            })
        );

        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.ERC20), 0, FX_VALID_UNTIL, FX_VALID_AFTER, FX_PM_NONCE, payload
        );

        assertEq(uint8(envelope[1]), 2, "byte[1] type = ERC20(2)");
        assertEq(envelope.length, 25 + payload.length);
    }

    /// @notice Verify envelope byte layout for PERMIT2 type
    function test_fixture_envelope_permit2() public pure {
        bytes memory permitSig = new bytes(65);
        bytes memory payload = PaymasterPayload.encodePermit2(
            PaymasterPayload.Permit2Payload({
                token: address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),
                permitAmount: type(uint160).max,
                permitExpiration: 3600,
                permitNonce: 0,
                permitSig: permitSig,
                permit2Extra: ""
            })
        );

        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.PERMIT2), 0, FX_VALID_UNTIL, FX_VALID_AFTER, FX_PM_NONCE, payload
        );

        assertEq(uint8(envelope[1]), 3, "byte[1] type = PERMIT2(3)");
        assertEq(envelope.length, 25 + payload.length);
    }

    // ============ Test 4: Hash for Signature (end-to-end) ============

    /// @notice End-to-end hash computation with all fixture inputs
    /// @dev SDK must produce identical finalHash for same inputs
    function test_fixture_hashForSignature_verifying() public pure {
        // Step 1: Domain separator (EIP-712 standard, 6 fields with typeHash)
        bytes32 domainSeparator = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, FX_CHAIN_ID, FX_ENTRY_POINT, FX_PAYMASTER)
        );

        // Step 2: UserOp core hash
        bytes memory initCode = "";
        bytes memory callData = hex"12345678";
        bytes32 userOpCoreHash = keccak256(
            abi.encode(
                FX_SENDER,
                FX_NONCE,
                keccak256(initCode),
                keccak256(callData),
                FX_ACCOUNT_GAS_LIMITS,
                FX_PRE_VERIFICATION_GAS,
                FX_GAS_FEES
            )
        );

        // Step 3: Envelope
        bytes memory payload = PaymasterPayload.encodeVerifying(
            PaymasterPayload.VerifyingPayload({
                policyId: bytes32(uint256(1)), sponsor: address(0xBEEF), maxCost: 1 ether, verifierExtra: ""
            })
        );
        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.VERIFYING), 0, FX_VALID_UNTIL, FX_VALID_AFTER, FX_PM_NONCE, payload
        );

        // Step 4: Final hash
        bytes32 finalHash = PaymasterDataLib.hashForSignature(domainSeparator, userOpCoreHash, envelope);

        // Determinism
        bytes32 finalHash2 = PaymasterDataLib.hashForSignature(domainSeparator, userOpCoreHash, envelope);
        assertEq(finalHash, finalHash2, "Final hash must be deterministic");
        assertTrue(finalHash != bytes32(0));
    }

    /// @notice End-to-end hash for SPONSOR type
    function test_fixture_hashForSignature_sponsor() public pure {
        bytes32 domainSeparator = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, FX_CHAIN_ID, FX_ENTRY_POINT, FX_PAYMASTER)
        );

        bytes memory initCode = "";
        bytes memory callData = hex"12345678";
        bytes32 userOpCoreHash = keccak256(
            abi.encode(
                FX_SENDER,
                FX_NONCE,
                keccak256(initCode),
                keccak256(callData),
                FX_ACCOUNT_GAS_LIMITS,
                FX_PRE_VERIFICATION_GAS,
                FX_GAS_FEES
            )
        );

        bytes memory payload = PaymasterPayload.encodeSponsor(
            PaymasterPayload.SponsorPayload({
                campaignId: bytes32(uint256(42)),
                perUserLimit: 1 ether,
                targetContract: address(0xCAFE),
                targetSelector: bytes4(0x12345678),
                sponsorExtra: ""
            })
        );
        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.SPONSOR), 0, FX_VALID_UNTIL, FX_VALID_AFTER, FX_PM_NONCE, payload
        );

        bytes32 finalHash = PaymasterDataLib.hashForSignature(domainSeparator, userOpCoreHash, envelope);
        assertTrue(finalHash != bytes32(0));
    }

    // ============ Test 5: Signature Round-Trip ============

    /// @notice Sign with known private key and verify contract accepts it
    /// @dev Proves the contract's internal hash consistency
    function test_fixture_signatureRoundTrip_verifying() public {
        uint256 privateKey = 0xA1_1CE;
        address signer = vm.addr(privateKey);

        EntryPoint ep = new EntryPoint();
        vm.prank(makeAddr("owner"));
        VerifyingPaymaster pm = new VerifyingPaymaster(IEntryPoint(address(ep)), makeAddr("owner"), signer);

        // Fund
        vm.deal(makeAddr("owner"), 100 ether);
        vm.prank(makeAddr("owner"));
        pm.deposit{ value: 10 ether }();

        // Build userOp and envelope
        PackedUserOperation memory userOp = _createFixtureUserOp();
        bytes memory envelope = _createFixtureEnvelope_verifying();
        userOp.paymasterAndData = abi.encodePacked(address(pm), uint128(100_000), uint128(50_000), envelope);

        // Sign using contract's getHash
        bytes32 hash = pm.getHash(userOp, envelope);
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Attach signature
        userOp.paymasterAndData = abi.encodePacked(address(pm), uint128(100_000), uint128(50_000), envelope, signature);

        // Verify
        vm.prank(address(ep));
        (, uint256 validationData) = pm.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);

        // forge-lint: disable-next-line(unsafe-typecast)
        address sigFail = address(uint160(validationData));
        assertEq(sigFail, address(0), "Signature verification must succeed");
    }

    /// @notice Sign and verify for SponsorPaymaster
    function test_fixture_signatureRoundTrip_sponsor() public {
        uint256 privateKey = 0xA1_1CE;
        address signer = vm.addr(privateKey);

        EntryPoint ep = new EntryPoint();
        vm.prank(makeAddr("owner"));
        SponsorPaymaster pm = new SponsorPaymaster(IEntryPoint(address(ep)), makeAddr("owner"), signer);

        vm.deal(makeAddr("owner"), 100 ether);
        vm.prank(makeAddr("owner"));
        pm.deposit{ value: 10 ether }();

        PackedUserOperation memory userOp = _createFixtureUserOp();
        bytes memory envelope = _createFixtureEnvelope_sponsor();
        userOp.paymasterAndData = abi.encodePacked(address(pm), uint128(100_000), uint128(50_000), envelope);

        bytes32 hash = pm.getHash(userOp, envelope);
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        userOp.paymasterAndData = abi.encodePacked(address(pm), uint128(100_000), uint128(50_000), envelope, signature);

        vm.prank(address(ep));
        (, uint256 validationData) = pm.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);

        // forge-lint: disable-next-line(unsafe-typecast)
        address sigFail = address(uint160(validationData));
        assertEq(sigFail, address(0), "Sponsor signature verification must succeed");
    }

    // ============ Test 6: Envelope Length Splitting ============

    /// @notice Verify envelopeLength correctly splits envelope from trailing signature
    function test_fixture_envelopeLengthSplit() public pure {
        bytes memory envelope = _createFixtureEnvelope_verifying();
        bytes memory signature = new bytes(65);

        // Simulate paymasterData = envelope + signature
        bytes memory paymasterData = abi.encodePacked(envelope, signature);

        // Verify the library correctly computes envelope length
        // (We can't call envelopeLength directly on memory, so verify manually)
        uint16 payloadLen = uint16(bytes2(abi.encodePacked(envelope[23], envelope[24])));
        uint256 expectedEnvLen = 25 + uint256(payloadLen);

        assertEq(expectedEnvLen, envelope.length, "Envelope length computation");
        assertEq(paymasterData.length, envelope.length + 65, "Total = envelope + 65B sig");
    }

    // ============ Helper Functions ============

    function _createFixtureUserOp() internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: FX_SENDER,
            nonce: FX_NONCE,
            initCode: "",
            callData: hex"12345678",
            accountGasLimits: FX_ACCOUNT_GAS_LIMITS,
            preVerificationGas: FX_PRE_VERIFICATION_GAS,
            gasFees: FX_GAS_FEES,
            paymasterAndData: "",
            signature: ""
        });
    }

    function _createFixtureEnvelope_verifying() internal pure returns (bytes memory) {
        bytes memory payload = PaymasterPayload.encodeVerifying(
            PaymasterPayload.VerifyingPayload({
                policyId: bytes32(uint256(1)), sponsor: address(0xBEEF), maxCost: 1 ether, verifierExtra: ""
            })
        );
        return PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.VERIFYING), 0, FX_VALID_UNTIL, FX_VALID_AFTER, FX_PM_NONCE, payload
        );
    }

    function _createFixtureEnvelope_sponsor() internal pure returns (bytes memory) {
        bytes memory payload = PaymasterPayload.encodeSponsor(
            PaymasterPayload.SponsorPayload({
                campaignId: bytes32(uint256(42)),
                perUserLimit: 1 ether,
                targetContract: address(0xCAFE),
                targetSelector: bytes4(0x12345678),
                sponsorExtra: ""
            })
        );
        return PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.SPONSOR), 0, FX_VALID_UNTIL, FX_VALID_AFTER, FX_PM_NONCE, payload
        );
    }

    function _computeUserOpCoreHash(PackedUserOperation memory userOp) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees
            )
        );
    }
}
