// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ECDSAValidator} from "../../src/erc7579-validators/ECDSAValidator.sol";
import {PackedUserOperation} from "../../src/erc7579-smartaccount/interfaces/PackedUserOperation.sol";
import {
    SIG_VALIDATION_SUCCESS_UINT,
    SIG_VALIDATION_FAILED_UINT,
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_HOOK,
    ERC1271_MAGICVALUE,
    ERC1271_INVALID
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract ECDSAValidatorTest is Test {
    using MessageHashUtils for bytes32;

    ECDSAValidator public validator;

    address public smartAccount;
    uint256 public ownerPrivateKey;
    address public owner;

    function setUp() public {
        validator = new ECDSAValidator();

        smartAccount = makeAddr("smartAccount");
        ownerPrivateKey = 0xA11CE;
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
        emit ECDSAValidator.OwnerRegistered(smartAccount, owner);

        vm.prank(smartAccount);
        validator.onInstall(data);
    }

    // ============ onUninstall Tests ============

    function test_onUninstall() public {
        // Install first
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        // Uninstall
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

    // ============ validateUserOp Tests ============

    function test_validateUserOp_success() public {
        // Install validator
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        // Create user op and sign
        bytes32 userOpHash = keccak256("userOp");
        bytes32 ethSignedHash = userOpHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = _createUserOp(smartAccount, signature);

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash);

        assertEq(result, SIG_VALIDATION_SUCCESS_UINT);
    }

    function test_validateUserOp_successWithRawHash() public {
        // Install validator
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        // Sign raw hash (not eth signed)
        bytes32 userOpHash = keccak256("userOp");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = _createUserOp(smartAccount, signature);

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash);

        assertEq(result, SIG_VALIDATION_SUCCESS_UINT);
    }

    function test_validateUserOp_failWithWrongSigner() public {
        // Install validator
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        // Sign with wrong key
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

    // ============ isValidSignatureWithSender Tests ============

    function test_isValidSignatureWithSender_success() public {
        // Install validator
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        // Sign hash
        bytes32 hash = keccak256("message");
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signature);

        assertEq(result, ERC1271_MAGICVALUE);
    }

    function test_isValidSignatureWithSender_successWithRawHash() public {
        // Install validator
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        // Sign raw hash
        bytes32 hash = keccak256("message");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, hash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signature);

        assertEq(result, ERC1271_MAGICVALUE);
    }

    function test_isValidSignatureWithSender_invalid() public {
        // Install validator
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        // Sign with wrong key
        uint256 wrongKey = 0xBAD;
        bytes32 hash = keccak256("message");
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signature);

        assertEq(result, ERC1271_INVALID);
    }

    // ============ preCheck Tests (Hook) ============

    function test_preCheck_success() public {
        // Install validator
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        // preCheck should pass when called by owner
        vm.prank(smartAccount);
        bytes memory result = validator.preCheck(owner, 0, "");

        assertEq(result, hex"");
    }

    function test_preCheck_revertIfNotOwner() public {
        // Install validator
        vm.prank(smartAccount);
        validator.onInstall(abi.encodePacked(owner));

        address notOwner = makeAddr("notOwner");

        vm.prank(smartAccount);
        vm.expectRevert("ECDSAValidator: sender is not owner");
        validator.preCheck(notOwner, 0, "");
    }

    // ============ postCheck Tests ============

    function test_postCheck() public {
        // postCheck should not revert
        vm.prank(smartAccount);
        validator.postCheck("");
    }

    // ============ Helper Functions ============

    function _createUserOp(address sender, bytes memory signature) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(uint256(100000) << 128 | uint256(100000)),
            preVerificationGas: 21000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: "",
            signature: signature
        });
    }
}
