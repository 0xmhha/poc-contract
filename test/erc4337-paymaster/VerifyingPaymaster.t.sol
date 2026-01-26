// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { VerifyingPaymaster } from "../../src/erc4337-paymaster/VerifyingPaymaster.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract VerifyingPaymasterTest is Test {
    using MessageHashUtils for bytes32;

    VerifyingPaymaster public paymaster;
    EntryPoint public entryPoint;

    address public owner;
    uint256 public signerPrivateKey;
    address public verifyingSigner;
    address public user;

    uint256 constant INITIAL_DEPOSIT = 10 ether;

    function setUp() public {
        // Setup accounts
        owner = makeAddr("owner");
        signerPrivateKey = 0_xA1_1CE;
        verifyingSigner = vm.addr(signerPrivateKey);
        user = makeAddr("user");

        // Deploy EntryPoint
        entryPoint = new EntryPoint();

        // Deploy VerifyingPaymaster
        vm.prank(owner);
        paymaster = new VerifyingPaymaster(IEntryPoint(address(entryPoint)), owner, verifyingSigner);

        // Fund paymaster
        vm.deal(owner, 100 ether);
        vm.prank(owner);
        paymaster.deposit{ value: INITIAL_DEPOSIT }();
    }

    function test_constructor() public view {
        assertEq(address(paymaster.ENTRYPOINT()), address(entryPoint));
        assertEq(paymaster.owner(), owner);
        assertEq(paymaster.verifyingSigner(), verifyingSigner);
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
        vm.expectRevert(VerifyingPaymaster.SignerCannotBeZero.selector);
        paymaster.setVerifyingSigner(address(0));
    }

    function test_getHash() public view {
        PackedUserOperation memory userOp = _createSampleUserOp(user);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);

        bytes32 hash = paymaster.getHash(userOp, validUntil, validAfter);

        // Hash should be deterministic
        bytes32 hash2 = paymaster.getHash(userOp, validUntil, validAfter);
        assertEq(hash, hash2);

        // Different timestamps should give different hash
        bytes32 hash3 = paymaster.getHash(userOp, validUntil + 1, validAfter);
        assertNotEq(hash, hash3);
    }

    function test_validatePaymasterUserOp_success() public {
        PackedUserOperation memory userOp = _createSampleUserOp(user);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);

        // Create signature
        bytes32 hash = paymaster.getHash(userOp, validUntil, validAfter);
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Create paymasterAndData
        bytes memory paymasterData = abi.encodePacked(bytes6(validUntil), bytes6(validAfter), signature);

        userOp.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100_000), // verification gas
            uint128(50_000), // post-op gas
            paymasterData
        );

        // Validate
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);

        // Check result
        assertTrue(context.length > 0);
        // Extract sigFail from validationData (lowest 20 bytes should be 0 for success)
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

        // Create invalid signature (wrong private key)
        uint256 wrongPrivateKey = 0x_BAD;
        bytes32 hash = paymaster.getHash(userOp, validUntil, validAfter);
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory paymasterData = abi.encodePacked(bytes6(validUntil), bytes6(validAfter), signature);

        userOp.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000), paymasterData);

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);

        // Context should be empty for failure
        assertEq(context.length, 0);
        // Extract sigFail from validationData (should be 1 for failure)
        // forge-lint: disable-next-line(unsafe-typecast)
        address sigFail = address(uint160(validationData));
        assertEq(sigFail, address(1)); // 1 = failure
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

    function test_nonceIncrementsAfterValidation() public {
        PackedUserOperation memory userOp = _createSampleUserOp(user);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);

        bytes32 hash = paymaster.getHash(userOp, validUntil, validAfter);
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory paymasterData = abi.encodePacked(bytes6(validUntil), bytes6(validAfter), signature);

        userOp.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000), paymasterData);

        uint256 nonceBefore = paymaster.getNonce(user);

        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);

        uint256 nonceAfter = paymaster.getNonce(user);
        assertEq(nonceAfter, nonceBefore + 1);
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
