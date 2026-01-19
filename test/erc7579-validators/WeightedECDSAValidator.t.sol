// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {WeightedECDSAValidator} from "../../src/erc7579-validators/WeightedECDSAValidator.sol";
import {PackedUserOperation} from "../../src/erc7579-smartaccount/interfaces/PackedUserOperation.sol";
import {
    SIG_VALIDATION_FAILED_UINT,
    MODULE_TYPE_VALIDATOR,
    ERC1271_MAGICVALUE,
    ERC1271_INVALID
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract WeightedECDSAValidatorTest is Test {
    using MessageHashUtils for bytes32;

    WeightedECDSAValidator public validator;

    address public smartAccount;

    // Guardian keys (sorted in descending order for installation)
    uint256 public guardian1PrivateKey = 0x1111;
    uint256 public guardian2PrivateKey = 0x2222;
    uint256 public guardian3PrivateKey = 0x3333;

    address public guardian1;
    address public guardian2;
    address public guardian3;

    uint24 constant WEIGHT1 = 100;
    uint24 constant WEIGHT2 = 100;
    uint24 constant WEIGHT3 = 50;
    uint24 constant THRESHOLD = 150; // Need guardian1 + guardian2 or all three
    uint48 constant DELAY = 0;

    function setUp() public {
        validator = new WeightedECDSAValidator();

        smartAccount = makeAddr("smartAccount");

        guardian1 = vm.addr(guardian1PrivateKey);
        guardian2 = vm.addr(guardian2PrivateKey);
        guardian3 = vm.addr(guardian3PrivateKey);
    }

    // ============ onInstall Tests ============

    function test_onInstall() public {
        (address[] memory guardians, uint24[] memory weights) = _getSortedGuardiansAndWeights();

        bytes memory data = abi.encode(guardians, weights, THRESHOLD, DELAY);

        vm.prank(smartAccount);
        validator.onInstall(data);

        assertTrue(validator.isInitialized(smartAccount));

        (uint24 totalWeight, uint24 threshold, uint48 delay, address firstGuardian) =
            validator.weightedStorage(smartAccount);

        assertEq(totalWeight, WEIGHT1 + WEIGHT2 + WEIGHT3);
        assertEq(threshold, THRESHOLD);
        assertEq(delay, DELAY);
        assertTrue(firstGuardian != address(0));
    }

    function test_onInstall_emitsEvents() public {
        (address[] memory guardians, uint24[] memory weights) = _getSortedGuardiansAndWeights();

        bytes memory data = abi.encode(guardians, weights, THRESHOLD, DELAY);

        // Expect events for each guardian
        for (uint256 i = 0; i < guardians.length; i++) {
            vm.expectEmit(true, true, false, true);
            emit WeightedECDSAValidator.GuardianAdded(guardians[i], smartAccount, weights[i]);
        }

        vm.prank(smartAccount);
        validator.onInstall(data);
    }

    function test_onInstall_revertIfAlreadyInitialized() public {
        (address[] memory guardians, uint24[] memory weights) = _getSortedGuardiansAndWeights();
        bytes memory data = abi.encode(guardians, weights, THRESHOLD, DELAY);

        vm.prank(smartAccount);
        validator.onInstall(data);

        vm.prank(smartAccount);
        vm.expectRevert();
        validator.onInstall(data);
    }

    function test_onInstall_revertIfThresholdTooHigh() public {
        (address[] memory guardians, uint24[] memory weights) = _getSortedGuardiansAndWeights();
        uint24 tooHighThreshold = 1000; // Higher than total weight

        bytes memory data = abi.encode(guardians, weights, tooHighThreshold, DELAY);

        vm.prank(smartAccount);
        vm.expectRevert("Threshold too high");
        validator.onInstall(data);
    }

    // ============ onUninstall Tests ============

    function test_onUninstall() public {
        _installValidator();

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

    function test_isModuleType_other() public view {
        assertFalse(validator.isModuleType(999));
    }

    // ============ approve Tests ============

    function test_approve() public {
        _installValidator();

        bytes32 callDataAndNonceHash = _getCallDataHash();

        vm.prank(guardian1);
        validator.approve(callDataAndNonceHash, smartAccount);

        (uint256 approvals, bool passed) = validator.getApproval(smartAccount, callDataAndNonceHash);
        assertEq(approvals, WEIGHT1);
        assertFalse(passed); // Not enough weight yet
    }

    function test_approve_reachesThreshold() public {
        _installValidator();

        bytes32 callDataAndNonceHash = _getCallDataHash();

        // First guardian approves
        vm.prank(guardian1);
        validator.approve(callDataAndNonceHash, smartAccount);

        // Second guardian approves - should reach threshold
        vm.prank(guardian2);
        validator.approve(callDataAndNonceHash, smartAccount);

        (uint256 approvals, bool passed) = validator.getApproval(smartAccount, callDataAndNonceHash);
        assertEq(approvals, WEIGHT1 + WEIGHT2);
        assertTrue(passed);
    }

    function test_approve_revertIfNotGuardian() public {
        _installValidator();

        bytes32 callDataAndNonceHash = _getCallDataHash();
        address notGuardian = makeAddr("notGuardian");

        vm.prank(notGuardian);
        vm.expectRevert("Guardian not enabled");
        validator.approve(callDataAndNonceHash, smartAccount);
    }

    function test_approve_revertIfAlreadyVoted() public {
        _installValidator();

        bytes32 callDataAndNonceHash = _getCallDataHash();

        vm.prank(guardian1);
        validator.approve(callDataAndNonceHash, smartAccount);

        vm.prank(guardian1);
        vm.expectRevert("Already voted");
        validator.approve(callDataAndNonceHash, smartAccount);
    }

    // ============ veto Tests ============

    function test_veto() public {
        _installValidator();

        bytes32 callDataAndNonceHash = _getCallDataHash();

        // Guardian approves
        vm.prank(guardian1);
        validator.approve(callDataAndNonceHash, smartAccount);

        // Smart account vetoes
        vm.prank(smartAccount);
        validator.veto(callDataAndNonceHash);

        (uint256 approvals, bool passed) = validator.getApproval(smartAccount, callDataAndNonceHash);
        assertEq(approvals, WEIGHT1);
        assertFalse(passed); // Vetoed
    }

    // ============ renew Tests ============

    function test_renew() public {
        _installValidator();

        // Create new guardian set
        uint256 newGuardianKey = 0x4444;
        address newGuardian = vm.addr(newGuardianKey);

        address[] memory newGuardians = new address[](1);
        newGuardians[0] = newGuardian;

        uint24[] memory newWeights = new uint24[](1);
        newWeights[0] = 100;

        uint24 newThreshold = 100;
        uint48 newDelay = 1 hours;

        vm.prank(smartAccount);
        validator.renew(newGuardians, newWeights, newThreshold, newDelay);

        (uint24 totalWeight, uint24 threshold, uint48 delay,) = validator.weightedStorage(smartAccount);
        assertEq(totalWeight, 100);
        assertEq(threshold, newThreshold);
        assertEq(delay, newDelay);
    }

    // ============ validateUserOp Tests (no delay) ============

    function test_validateUserOp_withPreApproval() public {
        _installValidator();

        PackedUserOperation memory userOp = _createUserOp(smartAccount);
        bytes32 userOpHash = keccak256("userOpHash");
        bytes32 callDataAndNonceHash = keccak256(abi.encode(userOp.sender, userOp.callData, userOp.nonce));

        // Pre-approve with guardian1 and guardian2 to reach threshold
        vm.prank(guardian1);
        validator.approve(callDataAndNonceHash, smartAccount);

        vm.prank(guardian2);
        validator.approve(callDataAndNonceHash, smartAccount);

        // Now validate with guardian1's signature on userOpHash
        bytes32 ethSignedUserOpHash = userOpHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(guardian1PrivateKey, ethSignedUserOpHash);
        userOp.signature = abi.encodePacked(r, s, v);

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash);

        // Should succeed - proposal is approved and guardian signed userOpHash
        assertNotEq(result, SIG_VALIDATION_FAILED_UINT);
    }

    function test_validateUserOp_failIfNotInitialized() public {
        PackedUserOperation memory userOp = _createUserOp(smartAccount);
        bytes32 userOpHash = keccak256("userOpHash");

        vm.prank(smartAccount);
        uint256 result = validator.validateUserOp(userOp, userOpHash);

        assertEq(result, SIG_VALIDATION_FAILED_UINT);
    }

    // ============ isValidSignatureWithSender Tests ============

    function test_isValidSignatureWithSender_success() public {
        _installValidator();

        bytes32 hash = keccak256("message");

        // Sign with enough guardians to reach threshold
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(guardian1PrivateKey, hash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(guardian2PrivateKey, hash);

        // Signatures must be sorted by signer address (descending)
        bytes memory signatures;
        if (guardian1 > guardian2) {
            signatures = abi.encodePacked(r1, s1, v1, r2, s2, v2);
        } else {
            signatures = abi.encodePacked(r2, s2, v2, r1, s1, v1);
        }

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signatures);

        assertEq(result, ERC1271_MAGICVALUE);
    }

    function test_isValidSignatureWithSender_notEnoughWeight() public {
        _installValidator();

        bytes32 hash = keccak256("message");

        // Sign with only guardian3 (weight 50, threshold 150)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(guardian3PrivateKey, hash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signature);

        assertEq(result, ERC1271_INVALID);
    }

    function test_isValidSignatureWithSender_notInitialized() public {
        bytes32 hash = keccak256("message");
        bytes memory signature = new bytes(65);

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, signature);

        assertEq(result, ERC1271_INVALID);
    }

    function test_isValidSignatureWithSender_emptySignature() public {
        _installValidator();

        bytes32 hash = keccak256("message");

        vm.prank(smartAccount);
        bytes4 result = validator.isValidSignatureWithSender(address(0), hash, "");

        assertEq(result, ERC1271_INVALID);
    }

    // ============ getApproval Tests ============

    function test_getApproval_noVotes() public {
        _installValidator();

        bytes32 hash = keccak256("proposal");

        (uint256 approvals, bool passed) = validator.getApproval(smartAccount, hash);

        assertEq(approvals, 0);
        assertFalse(passed);
    }

    // ============ Helper Functions ============

    function _installValidator() internal {
        (address[] memory guardians, uint24[] memory weights) = _getSortedGuardiansAndWeights();
        bytes memory data = abi.encode(guardians, weights, THRESHOLD, DELAY);

        vm.prank(smartAccount);
        validator.onInstall(data);
    }

    function _getSortedGuardiansAndWeights() internal view returns (address[] memory, uint24[] memory) {
        // Sort guardians in descending order by address
        address[] memory unsorted = new address[](3);
        unsorted[0] = guardian1;
        unsorted[1] = guardian2;
        unsorted[2] = guardian3;

        uint24[] memory weights = new uint24[](3);
        weights[0] = WEIGHT1;
        weights[1] = WEIGHT2;
        weights[2] = WEIGHT3;

        // Simple bubble sort descending
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (uint160(unsorted[i]) < uint160(unsorted[j])) {
                    (unsorted[i], unsorted[j]) = (unsorted[j], unsorted[i]);
                    (weights[i], weights[j]) = (weights[j], weights[i]);
                }
            }
        }

        return (unsorted, weights);
    }

    function _getCallDataHash() internal view returns (bytes32) {
        PackedUserOperation memory userOp = _createUserOp(smartAccount);
        return keccak256(abi.encode(userOp.sender, userOp.callData, userOp.nonce));
    }

    function _createUserOp(address sender) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(uint256(100000) << 128 | uint256(100000)),
            preVerificationGas: 21000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: "",
            signature: ""
        });
    }

}
