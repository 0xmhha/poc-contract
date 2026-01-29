// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { MultiChainValidator, DUMMY_ECDSA_SIG } from "../../src/erc7579-validators/MultiChainValidator.sol";
import { PackedUserOperation } from "../../src/erc7579-smartaccount/interfaces/PackedUserOperation.sol";
import {
    SIG_VALIDATION_SUCCESS_UINT,
    SIG_VALIDATION_FAILED_UINT,
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_HOOK,
    ERC1271_MAGICVALUE,
    ERC1271_INVALID
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract MultiChainValidatorTest is Test {
    using MessageHashUtils for bytes32;

    MultiChainValidator public validator;

    address public smartAccount;
    uint256 public ownerPrivateKey;
    address public owner;

    function setUp() public {
        validator = new MultiChainValidator();

        smartAccount = makeAddr("smartAccount");
        ownerPrivateKey = 0xA1_1CE;
        owner = vm.addr(ownerPrivateKey);
    }

    // ============ onInstall Tests ============

    function test_onInstall() public {
        bytes memory data = abi.encodePacked(owner);

        vm.prank(smartAccount);
        validator.onInstall(data);

        (address storedOwner) = validator.ecdsaValidatorStorage(smartAccount);
        assertEq(storedOwner, owner);
        assertTrue(validator.isInitialized(smartAccount));
    }

    function test_onInstall_emitsEvent() public {
        bytes memory data = abi.encodePacked(owner);

        vm.expectEmit(true, true, false, false);
        emit MultiChainValidator.OwnerRegistered(smartAccount, owner);

        vm.prank(smartAccount);
        validator.onInstall(data);
    }

    // ============ onUninstall Tests ============

    function test_onUninstall() public {
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        vm.prank(smartAccount);
        validator.onUninstall("");

        assertFalse(validator.isInitialized(smartAccount));
    }

    function test_onUninstall_revertIfNotInitialized() public {
        vm.prank(smartAccount);
        vm.expectRevert();
        validator.onUninstall("");
    }

    // ============ isModuleType Tests ============

    function test_isModuleType_validator() public view {
        assertTrue(validator.isModuleType(MODULE_TYPE_VALIDATOR));
    }

    function test_isModuleType_hook() public view {
        assertTrue(validator.isModuleType(MODULE_TYPE_HOOK));
    }

    function test_isModuleType_other() public view {
        assertFalse(validator.isModuleType(999));
    }

    // ============ Simple ECDSA validateUserOp Tests ============

    function test_validateUserOp_simpleECDSA_success() public {
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        bytes32 userOpHash = keccak256("userOp");
        bytes32 ethSignedHash = userOpHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = _createUserOp(smartAccount, signature);

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash);

        assertEq(result, SIG_VALIDATION_SUCCESS_UINT);
    }

    function test_validateUserOp_simpleECDSA_successWithRawHash() public {
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        bytes32 userOpHash = keccak256("userOp");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = _createUserOp(smartAccount, signature);

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash);

        assertEq(result, SIG_VALIDATION_SUCCESS_UINT);
    }

    function test_validateUserOp_simpleECDSA_fail() public {
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        uint256 wrongKey = 0xBAD;
        bytes32 userOpHash = keccak256("userOp");
        bytes32 ethSignedHash = userOpHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = _createUserOp(smartAccount, signature);

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash);

        assertEq(result, SIG_VALIDATION_FAILED_UINT);
    }

    // ============ Merkle Proof validateUserOp Tests ============

    function test_validateUserOp_merkleProof_success() public {
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        // Create merkle tree with 2 leaves
        bytes32 userOpHash1 = keccak256("userOp1");
        bytes32 userOpHash2 = keccak256("userOp2");

        // Compute merkle root (simple 2-leaf tree)
        bytes32 merkleRoot = _hashPair(userOpHash1, userOpHash2);

        // Sign the merkle root
        bytes32 ethSignedRoot = merkleRoot.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedRoot);
        bytes memory ecdsaSig = abi.encodePacked(r, s, v);

        // Create proof for userOpHash1 (sibling is userOpHash2)
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = userOpHash2;

        // Construct signature: ecdsaSig (65) + merkleRoot (32) + proof
        bytes memory signature = abi.encodePacked(ecdsaSig, merkleRoot, abi.encode(proof));

        PackedUserOperation memory userOp = _createUserOp(smartAccount, signature);

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash1);

        assertEq(result, SIG_VALIDATION_SUCCESS_UINT);
    }

    function test_validateUserOp_merkleProof_withDummySig() public {
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        // Use dummy signature to specify a different userOpHash for cross-chain
        bytes32 dummyUserOpHash = keccak256("dummyUserOp");
        bytes32 actualUserOpHash = keccak256("actualUserOp"); // This is what EntryPoint passes

        // Create merkle tree containing dummyUserOpHash (for this chain)
        bytes32 otherHash = keccak256("otherOp");
        bytes32 merkleRoot = _hashPair(dummyUserOpHash, otherHash);

        // Create proof for dummyUserOpHash
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = otherHash;

        // Construct signature with DUMMY_ECDSA_SIG to indicate dummyUserOpHash should be used
        bytes memory signature = abi.encodePacked(DUMMY_ECDSA_SIG, merkleRoot, abi.encode(dummyUserOpHash, proof));

        PackedUserOperation memory userOp = _createUserOp(smartAccount, signature);

        // The validator will use dummyUserOpHash instead of actualUserOpHash
        // but still verify the merkle root signature with owner's key
        // This test verifies the dummy sig detection works, but ECDSA validation
        // happens on merkleRoot, not dummyUserOpHash

        // Since DUMMY_ECDSA_SIG won't recover to owner, this should fail
        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, actualUserOpHash);

        // With dummy sig, the merkle proof passes but ECDSA fails
        assertEq(result, SIG_VALIDATION_FAILED_UINT);
    }

    function test_validateUserOp_merkleProof_invalidProof() public {
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        bytes32 userOpHash = keccak256("userOp");
        bytes32 wrongLeaf = keccak256("wrong");

        bytes32 merkleRoot = _hashPair(wrongLeaf, keccak256("other"));

        bytes32 ethSignedRoot = merkleRoot.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedRoot);
        bytes memory ecdsaSig = abi.encodePacked(r, s, v);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("other");

        bytes memory signature = abi.encodePacked(ecdsaSig, merkleRoot, abi.encode(proof));

        PackedUserOperation memory userOp = _createUserOp(smartAccount, signature);

        vm.prank(smartAccount);
        vm.expectRevert("hash is not in proof");
        validator.validateUserOp(userOp, userOpHash);
    }

    // ============ isValidSignatureWithSender Tests ============

    function test_isValidSignatureWithSender_simpleECDSA() public {
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        bytes32 hash = keccak256("message");
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signature);

        assertEq(result, ERC1271_MAGICVALUE);
    }

    function test_isValidSignatureWithSender_merkleProof() public {
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        bytes32 hash = keccak256("message");
        bytes32 otherHash = keccak256("other");
        bytes32 merkleRoot = _hashPair(hash, otherHash);

        bytes32 ethSignedRoot = merkleRoot.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedRoot);
        bytes memory ecdsaSig = abi.encodePacked(r, s, v);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = otherHash;

        bytes memory signature = abi.encodePacked(ecdsaSig, merkleRoot, abi.encode(proof));

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signature);

        assertEq(result, ERC1271_MAGICVALUE);
    }

    function test_isValidSignatureWithSender_invalid() public {
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        uint256 wrongKey = 0xBAD;
        bytes32 hash = keccak256("message");
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signature);

        assertEq(result, ERC1271_INVALID);
    }

    // ============ preCheck Tests ============

    function test_preCheck_success() public {
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        vm.prank(smartAccount);
        bytes memory result = validator.preCheck(owner, 0, "");

        assertEq(result, hex"");
    }

    function test_preCheck_revertIfNotOwner() public {
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        address notOwner = makeAddr("notOwner");

        vm.prank(smartAccount);
        vm.expectRevert("ECDSAValidator: sender is not owner");
        validator.preCheck(notOwner, 0, "");
    }

    // ============ Helper Functions ============

    function _createUserOp(address sender, bytes memory signature) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(uint256(100_000) << 128 | uint256(100_000)),
            preVerificationGas: 21_000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: "",
            signature: signature
        });
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
