// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { MultiSigValidator } from "../../src/erc7579-validators/MultiSigValidator.sol";
import { PackedUserOperation } from "../../src/erc7579-smartaccount/interfaces/PackedUserOperation.sol";
import {
    SIG_VALIDATION_SUCCESS_UINT,
    SIG_VALIDATION_FAILED_UINT,
    MODULE_TYPE_VALIDATOR,
    ERC1271_MAGICVALUE,
    ERC1271_INVALID
} from "../../src/erc7579-smartaccount/types/Constants.sol";

contract MultiSigValidatorTest is Test {
    MultiSigValidator public validator;

    address public smartAccount;
    address public signer1;
    uint256 public signer1Key;
    address public signer2;
    uint256 public signer2Key;
    address public signer3;
    uint256 public signer3Key;

    event ThresholdChanged(address indexed account, uint8 oldThreshold, uint8 newThreshold);
    event SignerAdded(address indexed account, address indexed signer);
    event SignerRemoved(address indexed account, address indexed signer);

    function setUp() public {
        validator = new MultiSigValidator();
        smartAccount = makeAddr("smartAccount");

        // Create ordered signers (signer1 < signer2 < signer3 by address)
        (signer1, signer1Key) = makeAddrAndKey("signer1");
        (signer2, signer2Key) = makeAddrAndKey("signer2");
        (signer3, signer3Key) = makeAddrAndKey("signer3");

        // Sort signers by address
        _sortSigners();
    }

    function _sortSigners() internal {
        // Bubble sort for 3 elements
        if (signer1 > signer2) {
            (signer1, signer2) = (signer2, signer1);
            (signer1Key, signer2Key) = (signer2Key, signer1Key);
        }
        if (signer2 > signer3) {
            (signer2, signer3) = (signer3, signer2);
            (signer2Key, signer3Key) = (signer3Key, signer2Key);
        }
        if (signer1 > signer2) {
            (signer1, signer2) = (signer2, signer1);
            (signer1Key, signer2Key) = (signer2Key, signer1Key);
        }
    }

    function _install2of3() internal {
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.prank(smartAccount);
        validator.onInstall(abi.encode(signers, uint8(2)));
    }

    function _createMultiSig(bytes32 hash, uint256[] memory keys) internal pure returns (bytes memory) {
        bytes memory signatures;
        for (uint256 i = 0; i < keys.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], hash);
            signatures = abi.encodePacked(signatures, r, s, v);
        }
        return signatures;
    }

    // ============ Install Tests ============

    function test_OnInstall_Success() public {
        address[] memory signers = new address[](2);
        signers[0] = signer1;
        signers[1] = signer2;

        vm.prank(smartAccount);
        validator.onInstall(abi.encode(signers, uint8(1)));

        assertTrue(validator.isInitialized(smartAccount));
        assertEq(validator.getThreshold(smartAccount), 1);
        assertEq(validator.getSignerCount(smartAccount), 2);
    }

    function test_OnInstall_EmitsEvents() public {
        address[] memory signers = new address[](2);
        signers[0] = signer1;
        signers[1] = signer2;

        vm.prank(smartAccount);
        vm.expectEmit(true, true, false, false);
        emit SignerAdded(smartAccount, signer1);
        vm.expectEmit(true, true, false, false);
        emit SignerAdded(smartAccount, signer2);
        validator.onInstall(abi.encode(signers, uint8(2)));
    }

    function test_OnInstall_RevertsOnAlreadyInitialized() public {
        _install2of3();

        address[] memory signers = new address[](1);
        signers[0] = signer1;

        vm.prank(smartAccount);
        vm.expectRevert();
        validator.onInstall(abi.encode(signers, uint8(1)));
    }

    function test_OnInstall_RevertsOnEmptySigners() public {
        address[] memory signers = new address[](0);

        vm.prank(smartAccount);
        vm.expectRevert(MultiSigValidator.InvalidSignerCount.selector);
        validator.onInstall(abi.encode(signers, uint8(1)));
    }

    function test_OnInstall_RevertsOnTooManySigners() public {
        address[] memory signers = new address[](21);
        for (uint160 i = 0; i < 21; i++) {
            signers[i] = address(i + 1);
        }

        vm.prank(smartAccount);
        vm.expectRevert(MultiSigValidator.InvalidSignerCount.selector);
        validator.onInstall(abi.encode(signers, uint8(1)));
    }

    function test_OnInstall_RevertsOnZeroThreshold() public {
        address[] memory signers = new address[](2);
        signers[0] = signer1;
        signers[1] = signer2;

        vm.prank(smartAccount);
        vm.expectRevert(abi.encodeWithSelector(MultiSigValidator.InvalidThreshold.selector, 0, 2));
        validator.onInstall(abi.encode(signers, uint8(0)));
    }

    function test_OnInstall_RevertsOnThresholdTooHigh() public {
        address[] memory signers = new address[](2);
        signers[0] = signer1;
        signers[1] = signer2;

        vm.prank(smartAccount);
        vm.expectRevert(abi.encodeWithSelector(MultiSigValidator.InvalidThreshold.selector, 3, 2));
        validator.onInstall(abi.encode(signers, uint8(3)));
    }

    function test_OnInstall_RevertsOnZeroAddress() public {
        address[] memory signers = new address[](2);
        signers[0] = signer1;
        signers[1] = address(0);

        vm.prank(smartAccount);
        vm.expectRevert(MultiSigValidator.ZeroAddress.selector);
        validator.onInstall(abi.encode(signers, uint8(1)));
    }

    function test_OnInstall_RevertsOnDuplicateSigner() public {
        address[] memory signers = new address[](2);
        signers[0] = signer1;
        signers[1] = signer1;

        vm.prank(smartAccount);
        vm.expectRevert(abi.encodeWithSelector(MultiSigValidator.SignerAlreadyExists.selector, signer1));
        validator.onInstall(abi.encode(signers, uint8(1)));
    }

    // ============ Uninstall Tests ============

    function test_OnUninstall_Success() public {
        _install2of3();

        vm.prank(smartAccount);
        validator.onUninstall("");

        assertFalse(validator.isInitialized(smartAccount));
        assertEq(validator.getThreshold(smartAccount), 0);
        assertEq(validator.getSignerCount(smartAccount), 0);
    }

    function test_OnUninstall_RevertsOnNotInitialized() public {
        vm.prank(smartAccount);
        vm.expectRevert();
        validator.onUninstall("");
    }

    // ============ Module Type Tests ============

    function test_IsModuleType_Validator() public view {
        assertTrue(validator.isModuleType(MODULE_TYPE_VALIDATOR));
        assertFalse(validator.isModuleType(2)); // Not executor
    }

    function test_IsInitialized() public {
        assertFalse(validator.isInitialized(smartAccount));
        _install2of3();
        assertTrue(validator.isInitialized(smartAccount));
    }

    // ============ Signer Management Tests ============

    function test_AddSigner_Success() public {
        _install2of3();

        address newSigner = makeAddr("newSigner");

        vm.prank(smartAccount);
        vm.expectEmit(true, true, false, false);
        emit SignerAdded(smartAccount, newSigner);
        validator.addSigner(newSigner);

        assertTrue(validator.isSigner(smartAccount, newSigner));
        assertEq(validator.getSignerCount(smartAccount), 4);
    }

    function test_AddSigner_RevertsOnZeroAddress() public {
        _install2of3();

        vm.prank(smartAccount);
        vm.expectRevert(MultiSigValidator.ZeroAddress.selector);
        validator.addSigner(address(0));
    }

    function test_AddSigner_RevertsOnAlreadyExists() public {
        _install2of3();

        vm.prank(smartAccount);
        vm.expectRevert(abi.encodeWithSelector(MultiSigValidator.SignerAlreadyExists.selector, signer1));
        validator.addSigner(signer1);
    }

    function test_AddSigner_RevertsOnMaxSigners() public {
        // Install with 20 signers
        address[] memory signers = new address[](20);
        for (uint160 i = 0; i < 20; i++) {
            signers[i] = address(i + 1);
        }

        vm.prank(smartAccount);
        validator.onInstall(abi.encode(signers, uint8(1)));

        vm.prank(smartAccount);
        vm.expectRevert(MultiSigValidator.InvalidSignerCount.selector);
        validator.addSigner(makeAddr("extra"));
    }

    function test_RemoveSigner_Success() public {
        _install2of3();

        vm.prank(smartAccount);
        vm.expectEmit(true, true, false, false);
        emit SignerRemoved(smartAccount, signer3);
        validator.removeSigner(signer3);

        assertFalse(validator.isSigner(smartAccount, signer3));
        assertEq(validator.getSignerCount(smartAccount), 2);
    }

    function test_RemoveSigner_RevertsOnNotFound() public {
        _install2of3();

        address notSigner = makeAddr("notSigner");

        vm.prank(smartAccount);
        vm.expectRevert(abi.encodeWithSelector(MultiSigValidator.SignerNotFound.selector, notSigner));
        validator.removeSigner(notSigner);
    }

    function test_RemoveSigner_RevertsOnCannotRemoveLastSigner() public {
        _install2of3();

        // With threshold 2 and 3 signers, can only remove 1
        vm.startPrank(smartAccount);
        validator.removeSigner(signer3);

        // Cannot remove more (would be 2 signers with threshold 2)
        vm.expectRevert(MultiSigValidator.CannotRemoveLastSigner.selector);
        validator.removeSigner(signer2);
        vm.stopPrank();
    }

    function test_ReplaceSigner_Success() public {
        _install2of3();

        address newSigner = makeAddr("newSigner");

        vm.prank(smartAccount);
        validator.replaceSigner(signer3, newSigner);

        assertFalse(validator.isSigner(smartAccount, signer3));
        assertTrue(validator.isSigner(smartAccount, newSigner));
        assertEq(validator.getSignerCount(smartAccount), 3);
    }

    function test_ReplaceSigner_RevertsOnZeroAddress() public {
        _install2of3();

        vm.prank(smartAccount);
        vm.expectRevert(MultiSigValidator.ZeroAddress.selector);
        validator.replaceSigner(signer1, address(0));
    }

    function test_ReplaceSigner_RevertsOnOldSignerNotFound() public {
        _install2of3();

        address notSigner = makeAddr("notSigner");
        address newSigner = makeAddr("newSigner");

        vm.prank(smartAccount);
        vm.expectRevert(abi.encodeWithSelector(MultiSigValidator.SignerNotFound.selector, notSigner));
        validator.replaceSigner(notSigner, newSigner);
    }

    function test_ReplaceSigner_RevertsOnNewSignerExists() public {
        _install2of3();

        vm.prank(smartAccount);
        vm.expectRevert(abi.encodeWithSelector(MultiSigValidator.SignerAlreadyExists.selector, signer2));
        validator.replaceSigner(signer1, signer2);
    }

    function test_SetThreshold_Success() public {
        _install2of3();

        vm.prank(smartAccount);
        vm.expectEmit(true, false, false, true);
        emit ThresholdChanged(smartAccount, 2, 3);
        validator.setThreshold(3);

        assertEq(validator.getThreshold(smartAccount), 3);
    }

    function test_SetThreshold_RevertsOnZero() public {
        _install2of3();

        vm.prank(smartAccount);
        vm.expectRevert(abi.encodeWithSelector(MultiSigValidator.InvalidThreshold.selector, 0, 3));
        validator.setThreshold(0);
    }

    function test_SetThreshold_RevertsOnTooHigh() public {
        _install2of3();

        vm.prank(smartAccount);
        vm.expectRevert(abi.encodeWithSelector(MultiSigValidator.InvalidThreshold.selector, 4, 3));
        validator.setThreshold(4);
    }

    // ============ Validate UserOp Tests ============

    function test_ValidateUserOp_Success() public {
        _install2of3();

        bytes32 userOpHash = keccak256("test");
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));

        // Create 2 signatures (threshold is 2) - must be in ascending signer order
        uint256[] memory keys = new uint256[](2);
        keys[0] = signer1Key;
        keys[1] = signer2Key;

        bytes memory signatures = _createMultiSig(ethSignedHash, keys);

        PackedUserOperation memory userOp;
        userOp.signature = signatures;

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash);

        assertEq(result, SIG_VALIDATION_SUCCESS_UINT);
    }

    function test_ValidateUserOp_FailsOnNoSigners() public {
        bytes32 userOpHash = keccak256("test");

        PackedUserOperation memory userOp;
        userOp.signature = "";

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash);

        assertEq(result, SIG_VALIDATION_FAILED_UINT);
    }

    function test_ValidateUserOp_FailsOnInvalidSignature() public {
        _install2of3();

        bytes32 userOpHash = keccak256("test");

        // Create signature with wrong key
        (, uint256 wrongKey) = makeAddrAndKey("wrong");
        uint256[] memory keys = new uint256[](2);
        keys[0] = wrongKey;
        keys[1] = signer2Key;

        bytes memory signatures = _createMultiSig(userOpHash, keys);

        PackedUserOperation memory userOp;
        userOp.signature = signatures;

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash);

        assertEq(result, SIG_VALIDATION_FAILED_UINT);
    }

    function test_ValidateUserOp_FailsOnWrongOrder() public {
        _install2of3();

        bytes32 userOpHash = keccak256("test");
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));

        // Create signatures in wrong order (signer2, signer1 instead of signer1, signer2)
        uint256[] memory keys = new uint256[](2);
        keys[0] = signer2Key;
        keys[1] = signer1Key;

        bytes memory signatures = _createMultiSig(ethSignedHash, keys);

        PackedUserOperation memory userOp;
        userOp.signature = signatures;

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash);

        assertEq(result, SIG_VALIDATION_FAILED_UINT);
    }

    // ============ ERC-1271 Tests ============

    function test_IsValidSignatureWithSender_Success() public {
        _install2of3();

        bytes32 hash = keccak256("test message");
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));

        uint256[] memory keys = new uint256[](2);
        keys[0] = signer1Key;
        keys[1] = signer2Key;

        bytes memory signatures = _createMultiSig(ethSignedHash, keys);

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signatures);

        assertEq(result, ERC1271_MAGICVALUE);
    }

    function test_IsValidSignatureWithSender_FailsOnNoSigners() public {
        bytes32 hash = keccak256("test");

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, "");

        assertEq(result, ERC1271_INVALID);
    }

    function test_IsValidSignatureWithSender_FailsOnInvalidSignature() public {
        _install2of3();

        bytes32 hash = keccak256("test");

        (, uint256 wrongKey) = makeAddrAndKey("wrong");
        uint256[] memory keys = new uint256[](2);
        keys[0] = wrongKey;
        keys[1] = signer2Key;

        bytes memory signatures = _createMultiSig(hash, keys);

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signatures);

        assertEq(result, ERC1271_INVALID);
    }

    // ============ View Function Tests ============

    function test_GetSigners() public {
        _install2of3();

        address[] memory signers = validator.getSigners(smartAccount);
        assertEq(signers.length, 3);
    }

    function test_IsSigner() public {
        _install2of3();

        assertTrue(validator.isSigner(smartAccount, signer1));
        assertTrue(validator.isSigner(smartAccount, signer2));
        assertTrue(validator.isSigner(smartAccount, signer3));
        assertFalse(validator.isSigner(smartAccount, makeAddr("notSigner")));
    }
}
