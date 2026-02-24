// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SponsorPaymaster } from "../../src/erc4337-paymaster/SponsorPaymaster.sol";
import { PaymasterDataLib } from "../../src/erc4337-paymaster/PaymasterDataLib.sol";
import { PaymasterPayload } from "../../src/erc4337-paymaster/PaymasterPayload.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract SponsorPaymasterTest is Test {
    using MessageHashUtils for bytes32;

    SponsorPaymaster public paymaster;
    EntryPoint public entryPoint;

    address public owner;
    uint256 public signerPrivateKey;
    address public verifyingSigner;
    address public user;

    uint256 constant INITIAL_DEPOSIT = 10 ether;

    function setUp() public {
        owner = makeAddr("owner");
        signerPrivateKey = 0xA1_1CE;
        verifyingSigner = vm.addr(signerPrivateKey);
        user = makeAddr("user");

        entryPoint = new EntryPoint();

        vm.prank(owner);
        paymaster = new SponsorPaymaster(IEntryPoint(address(entryPoint)), owner, verifyingSigner);

        vm.deal(owner, 100 ether);
        vm.prank(owner);
        paymaster.deposit{ value: INITIAL_DEPOSIT }();
    }

    function test_constructor() public view {
        assertEq(address(paymaster.ENTRYPOINT()), address(entryPoint));
        assertEq(paymaster.owner(), owner);
        assertEq(paymaster.verifyingSigner(), verifyingSigner);
    }

    function test_constructor_revertIfSignerZero() public {
        vm.prank(owner);
        vm.expectRevert(SponsorPaymaster.SignerCannotBeZero.selector);
        new SponsorPaymaster(IEntryPoint(address(entryPoint)), owner, address(0));
    }

    function test_setVerifyingSigner() public {
        address newSigner = makeAddr("newSigner");

        vm.prank(owner);
        paymaster.setVerifyingSigner(newSigner);

        assertEq(paymaster.verifyingSigner(), newSigner);
    }

    function test_setVerifyingSigner_revertIfNotOwner() public {
        address newSigner = makeAddr("newSigner");

        vm.prank(user);
        vm.expectRevert();
        paymaster.setVerifyingSigner(newSigner);
    }

    function test_setVerifyingSigner_revertIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SponsorPaymaster.SignerCannotBeZero.selector);
        paymaster.setVerifyingSigner(address(0));
    }

    function test_validatePaymasterUserOp_success() public {
        PackedUserOperation memory userOp = _createSampleUserOp(user);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);

        // Build envelope data with SponsorPayload
        bytes memory sponsorPayload = PaymasterPayload.encodeSponsor(
            PaymasterPayload.SponsorPayload({
                campaignId: bytes32(uint256(1)),
                perUserLimit: 1 ether,
                targetContract: address(0),
                targetSelector: bytes4(0),
                sponsorExtra: ""
            })
        );
        bytes memory envelopeData = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.SPONSOR), 0, validUntil, validAfter, uint64(0), sponsorPayload
        );

        // Set paymasterAndData temporarily to get hash
        userOp.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000), envelopeData);

        // Create signature using getHash
        bytes32 hash = paymaster.getHash(userOp, envelopeData);
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Set full paymasterAndData with signature
        userOp.paymasterAndData =
            abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000), envelopeData, signature);

        // Validate
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);

        // Check result
        assertTrue(context.length > 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        address sigFail = address(uint160(validationData));
        assertEq(sigFail, address(0)); // 0 = success
    }

    function test_validatePaymasterUserOp_revertIfNotEntryPoint() public {
        PackedUserOperation memory userOp = _createSampleUserOp(user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("OnlyEntryPoint()"));
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);
    }

    function test_validatePaymasterUserOp_failWithInvalidSignature() public {
        PackedUserOperation memory userOp = _createSampleUserOp(user);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);

        bytes memory sponsorPayload = PaymasterPayload.encodeSponsor(
            PaymasterPayload.SponsorPayload({
                campaignId: bytes32(uint256(1)),
                perUserLimit: 1 ether,
                targetContract: address(0),
                targetSelector: bytes4(0),
                sponsorExtra: ""
            })
        );
        bytes memory envelopeData = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.SPONSOR), 0, validUntil, validAfter, uint64(0), sponsorPayload
        );

        // Set paymasterAndData temporarily to get hash
        userOp.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000), envelopeData);

        // Create invalid signature (wrong private key)
        uint256 wrongPrivateKey = 0xBAD;
        bytes32 hash = paymaster.getHash(userOp, envelopeData);
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        userOp.paymasterAndData =
            abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000), envelopeData, signature);

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);

        // Context should be empty for failure
        assertEq(context.length, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        address sigFail = address(uint160(validationData));
        assertEq(sigFail, address(1)); // 1 = failure
    }

    function test_revertIfWrongPaymasterType() public {
        PackedUserOperation memory userOp = _createSampleUserOp(user);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);

        // Build envelope with wrong type (VERIFYING instead of SPONSOR)
        bytes memory envelopeData = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.VERIFYING), 0, validUntil, validAfter, uint64(0), ""
        );

        bytes memory signature = new bytes(65);

        userOp.paymasterAndData =
            abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000), envelopeData, signature);

        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(PaymasterDataLib.InvalidType.selector, uint8(0)));
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);
    }

    function test_nonceIncrementsAfterValidation() public {
        PackedUserOperation memory userOp = _createSampleUserOp(user);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);

        bytes memory sponsorPayload = PaymasterPayload.encodeSponsor(
            PaymasterPayload.SponsorPayload({
                campaignId: bytes32(0),
                perUserLimit: 0,
                targetContract: address(0),
                targetSelector: bytes4(0),
                sponsorExtra: ""
            })
        );
        bytes memory envelopeData = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.SPONSOR), 0, validUntil, validAfter, uint64(0), sponsorPayload
        );

        userOp.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000), envelopeData);

        bytes32 hash = paymaster.getHash(userOp, envelopeData);
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        userOp.paymasterAndData =
            abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000), envelopeData, signature);

        uint256 nonceBefore = paymaster.getNonce(user);

        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);

        uint256 nonceAfter = paymaster.getNonce(user);
        assertEq(nonceAfter, nonceBefore + 1);
    }

    function test_getHash_deterministic() public {
        PackedUserOperation memory userOp = _createSampleUserOp(user);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);

        bytes memory sponsorPayload = PaymasterPayload.encodeSponsor(
            PaymasterPayload.SponsorPayload({
                campaignId: bytes32(uint256(1)),
                perUserLimit: 1 ether,
                targetContract: address(0),
                targetSelector: bytes4(0),
                sponsorExtra: ""
            })
        );
        bytes memory envelopeData = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.SPONSOR), 0, validUntil, validAfter, uint64(0), sponsorPayload
        );

        userOp.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000), envelopeData);

        bytes32 hash1 = paymaster.getHash(userOp, envelopeData);
        bytes32 hash2 = paymaster.getHash(userOp, envelopeData);
        assertEq(hash1, hash2);
    }

    function test_deposit() public view {
        uint256 balance = paymaster.getDeposit();
        assertEq(balance, INITIAL_DEPOSIT);
    }

    function test_withdrawTo() public {
        address recipient = makeAddr("recipient");
        uint256 withdrawAmount = 1 ether;

        vm.prank(owner);
        paymaster.withdrawTo(payable(recipient), withdrawAmount);

        assertEq(paymaster.getDeposit(), INITIAL_DEPOSIT - withdrawAmount);
    }

    function test_getNonce() public view {
        uint256 nonce = paymaster.getNonce(user);
        assertEq(nonce, 0);
    }

    // ============ Helper Functions ============

    function _createSampleUserOp(address sender) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(uint256(100_000) << 128 | uint256(100_000)),
            preVerificationGas: 21_000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: "",
            signature: ""
        });
    }
}
