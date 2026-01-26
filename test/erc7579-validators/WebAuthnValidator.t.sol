// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { WebAuthnValidator } from "../../src/erc7579-validators/WebAuthnValidator.sol";
import { PackedUserOperation } from "../../src/erc7579-smartaccount/interfaces/PackedUserOperation.sol";
import {
    SIG_VALIDATION_FAILED_UINT,
    MODULE_TYPE_VALIDATOR,
    ERC1271_INVALID
} from "../../src/erc7579-smartaccount/types/Constants.sol";

contract WebAuthnValidatorTest is Test {
    WebAuthnValidator public validator;

    address public smartAccount;

    // Sample P256 public key (these are test values, not cryptographically valid)
    bytes32 public credentialId = keccak256("test-credential");
    uint256 public pubKeyX = 0x6_5a2_fa4_4da_ad4_6ea_b02_787_03e_db6_c4d_cf5_e30_b8a_9ae_c09_fdc_71a_56f_52a_a39_2e4;
    uint256 public pubKeyY = 0x4_a7a_9e4_604_aa3_689_820_999_728_8e9_02a_c54_4a5_55e_4b5_e0a_9ef_ef2_b59_233_f3f_437;

    event CredentialRegistered(address indexed account, bytes32 indexed credentialId, uint256 pubKeyX, uint256 pubKeyY);
    event CredentialRevoked(address indexed account, bytes32 indexed credentialId);

    function setUp() public {
        validator = new WebAuthnValidator();
        smartAccount = makeAddr("smartAccount");
    }

    function _install() internal {
        vm.prank(smartAccount);
        validator.onInstall(abi.encode(credentialId, pubKeyX, pubKeyY));
    }

    // ============ Install Tests ============

    function test_OnInstall_Success() public {
        vm.prank(smartAccount);
        vm.expectEmit(true, true, false, true);
        emit CredentialRegistered(smartAccount, credentialId, pubKeyX, pubKeyY);
        validator.onInstall(abi.encode(credentialId, pubKeyX, pubKeyY));

        assertTrue(validator.isInitialized(smartAccount));
        assertEq(validator.getCredentialCount(smartAccount), 1);
    }

    function test_OnInstall_RevertsOnShortData() public {
        vm.prank(smartAccount);
        vm.expectRevert(WebAuthnValidator.InvalidSignatureLength.selector);
        validator.onInstall(new bytes(64)); // Less than 96 bytes
    }

    function test_OnInstall_RevertsOnZeroCredentialId() public {
        vm.prank(smartAccount);
        vm.expectRevert(WebAuthnValidator.InvalidCredentialId.selector);
        validator.onInstall(abi.encode(bytes32(0), pubKeyX, pubKeyY));
    }

    // ============ Uninstall Tests ============

    function test_OnUninstall_Success() public {
        _install();

        vm.prank(smartAccount);
        validator.onUninstall("");

        assertFalse(validator.isInitialized(smartAccount));
        assertEq(validator.getCredentialCount(smartAccount), 0);
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
        _install();
        assertTrue(validator.isInitialized(smartAccount));
    }

    // ============ Credential Management Tests ============

    function test_AddCredential_Success() public {
        _install();

        bytes32 newCredentialId = keccak256("new-credential");
        uint256 newPubKeyX = 0x1_234_567_890_abc_def_123_456_789_0ab_cde_f12_345_678_90a_bcd_ef1_234_567_890_abc_def;
        uint256 newPubKeyY = 0xf_edc_ba0_987_654_321_fed_cba_098_765_432_1fe_dcb_a09_876_543_21f_edc_ba0_987_654_321;

        vm.prank(smartAccount);
        vm.expectEmit(true, true, false, true);
        emit CredentialRegistered(smartAccount, newCredentialId, newPubKeyX, newPubKeyY);
        validator.addCredential(newCredentialId, newPubKeyX, newPubKeyY);

        assertEq(validator.getCredentialCount(smartAccount), 2);

        WebAuthnValidator.Credential memory cred = validator.getCredential(smartAccount, newCredentialId);
        assertEq(cred.credentialId, newCredentialId);
        assertEq(cred.pubKeyX, newPubKeyX);
        assertEq(cred.pubKeyY, newPubKeyY);
        assertTrue(cred.isActive);
    }

    function test_AddCredential_RevertsOnZeroId() public {
        _install();

        vm.prank(smartAccount);
        vm.expectRevert(WebAuthnValidator.InvalidCredentialId.selector);
        validator.addCredential(bytes32(0), pubKeyX, pubKeyY);
    }

    function test_AddCredential_RevertsOnAlreadyExists() public {
        _install();

        vm.prank(smartAccount);
        vm.expectRevert(WebAuthnValidator.CredentialAlreadyExists.selector);
        validator.addCredential(credentialId, pubKeyX, pubKeyY);
    }

    function test_RevokeCredential_Success() public {
        _install();

        // Add another credential first
        bytes32 secondCredentialId = keccak256("second-credential");
        vm.startPrank(smartAccount);
        validator.addCredential(secondCredentialId, pubKeyX, pubKeyY);

        vm.expectEmit(true, true, false, false);
        emit CredentialRevoked(smartAccount, credentialId);
        validator.revokeCredential(credentialId);
        vm.stopPrank();

        assertEq(validator.getCredentialCount(smartAccount), 1);

        WebAuthnValidator.Credential memory cred = validator.getCredential(smartAccount, credentialId);
        assertFalse(cred.isActive);
    }

    function test_RevokeCredential_RevertsOnNotFound() public {
        _install();

        bytes32 unknownId = keccak256("unknown");

        vm.prank(smartAccount);
        vm.expectRevert(WebAuthnValidator.CredentialNotFound.selector);
        validator.revokeCredential(unknownId);
    }

    function test_RevokeCredential_RevertsOnNoCredentials() public {
        _install();

        // Try to revoke the only credential
        vm.prank(smartAccount);
        vm.expectRevert(WebAuthnValidator.NoCredentials.selector);
        validator.revokeCredential(credentialId);
    }

    // ============ Validate UserOp Tests ============

    function test_ValidateUserOp_FailsOnNoCredentials() public {
        bytes32 userOpHash = keccak256("test");

        PackedUserOperation memory userOp;
        userOp.signature = "";

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash);

        assertEq(result, SIG_VALIDATION_FAILED_UINT);
    }

    function test_ValidateUserOp_FailsOnInactiveCredential() public {
        _install();

        // Add second credential, then revoke first
        bytes32 secondCredentialId = keccak256("second-credential");
        vm.startPrank(smartAccount);
        validator.addCredential(secondCredentialId, pubKeyX, pubKeyY);
        validator.revokeCredential(credentialId);
        vm.stopPrank();

        bytes32 userOpHash = keccak256("test");
        bytes memory authenticatorData = new bytes(37);
        bytes memory clientDataJson = '{"challenge":"test"}';

        // Create signature with revoked credential
        bytes memory signature = abi.encode(credentialId, authenticatorData, clientDataJson, uint256(1), uint256(2));

        PackedUserOperation memory userOp;
        userOp.signature = signature;

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash);

        assertEq(result, SIG_VALIDATION_FAILED_UINT);
    }

    function test_ValidateUserOp_FailsOnShortSignature() public {
        _install();

        bytes32 userOpHash = keccak256("test");

        PackedUserOperation memory userOp;
        userOp.signature = new bytes(100); // Too short

        vm.prank(smartAccount);
        vm.expectRevert(WebAuthnValidator.InvalidSignatureLength.selector);
        validator.validateUserOp(userOp, userOpHash);
    }

    function test_ValidateUserOp_FailsOnMalformedSignature() public {
        _install();

        bytes32 userOpHash = keccak256("test");
        bytes memory authenticatorData = new bytes(37);
        bytes memory clientDataJson = '{"challenge":"test"}';

        // p256NDivTwo < s means malformed
        uint256 p256N = 0xF_FFF_FFF_F00_000_000_FFF_FFF_FFF_FFF_FFF_FBC_E6F_AAD_A71_79E_84F_3B9_CAC_2FC_632_551;
        uint256 p256NDivTwo = p256N / 2;

        bytes memory signature = abi.encode(
            credentialId,
            authenticatorData,
            clientDataJson,
            uint256(1),
            p256NDivTwo + 1 // s > p256NDivTwo
        );

        PackedUserOperation memory userOp;
        userOp.signature = signature;

        vm.prank(smartAccount);
        vm.expectRevert(WebAuthnValidator.MalformedSignature.selector);
        validator.validateUserOp(userOp, userOpHash);
    }

    function test_ValidateUserOp_FailsOnShortAuthenticatorData() public {
        _install();

        bytes32 userOpHash = keccak256("test");
        bytes memory authenticatorData = new bytes(36); // Less than 37
        bytes memory clientDataJson = '{"challenge":"test"}';

        bytes memory signature = abi.encode(credentialId, authenticatorData, clientDataJson, uint256(1), uint256(2));

        PackedUserOperation memory userOp;
        userOp.signature = signature;

        vm.prank(smartAccount);
        vm.expectRevert(WebAuthnValidator.InvalidAuthenticatorData.selector);
        validator.validateUserOp(userOp, userOpHash);
    }

    // ============ ERC-1271 Tests ============

    function test_IsValidSignatureWithSender_FailsOnNoCredentials() public {
        bytes32 hash = keccak256("test");

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, "");

        assertEq(result, ERC1271_INVALID);
    }

    function test_IsValidSignatureWithSender_FailsOnInactiveCredential() public {
        _install();

        // Add second credential, then revoke first
        bytes32 secondCredentialId = keccak256("second-credential");
        vm.startPrank(smartAccount);
        validator.addCredential(secondCredentialId, pubKeyX, pubKeyY);
        validator.revokeCredential(credentialId);
        vm.stopPrank();

        bytes32 hash = keccak256("test");
        bytes memory authenticatorData = new bytes(37);
        bytes memory clientDataJson = '{"challenge":"test"}';

        bytes memory signature = abi.encode(credentialId, authenticatorData, clientDataJson, uint256(1), uint256(2));

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signature);

        assertEq(result, ERC1271_INVALID);
    }

    function test_IsValidSignatureWithSender_FailsOnShortSignature() public {
        _install();

        bytes32 hash = keccak256("test");

        vm.prank(smartAccount);
        vm.expectRevert(WebAuthnValidator.InvalidSignatureLength.selector);
        validator.isValidSignatureWithSender(address(0), hash, new bytes(100));
    }

    // ============ View Function Tests ============

    function test_GetCredential() public {
        _install();

        WebAuthnValidator.Credential memory cred = validator.getCredential(smartAccount, credentialId);

        assertEq(cred.credentialId, credentialId);
        assertEq(cred.pubKeyX, pubKeyX);
        assertEq(cred.pubKeyY, pubKeyY);
        assertTrue(cred.isActive);
    }

    function test_GetCredentialIds() public {
        _install();

        bytes32 secondCredentialId = keccak256("second-credential");
        vm.prank(smartAccount);
        validator.addCredential(secondCredentialId, pubKeyX, pubKeyY);

        bytes32[] memory ids = validator.getCredentialIds(smartAccount);

        assertEq(ids.length, 2);
        assertEq(ids[0], credentialId);
        assertEq(ids[1], secondCredentialId);
    }

    function test_GetCredentialCount() public {
        assertEq(validator.getCredentialCount(smartAccount), 0);

        _install();
        assertEq(validator.getCredentialCount(smartAccount), 1);

        vm.prank(smartAccount);
        validator.addCredential(keccak256("another"), pubKeyX, pubKeyY);
        assertEq(validator.getCredentialCount(smartAccount), 2);
    }

    // ============ Multiple Credentials Tests ============

    function test_MultipleCredentials() public {
        _install();

        // Add multiple credentials
        for (uint256 i = 0; i < 5; i++) {
            bytes32 newId = keccak256(abi.encodePacked("credential-", i));
            vm.prank(smartAccount);
            validator.addCredential(newId, pubKeyX + i, pubKeyY + i);
        }

        assertEq(validator.getCredentialCount(smartAccount), 6);

        bytes32[] memory ids = validator.getCredentialIds(smartAccount);
        assertEq(ids.length, 6);
    }
}
