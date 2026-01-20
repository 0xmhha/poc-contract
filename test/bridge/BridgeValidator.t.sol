// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BridgeValidator} from "../../src/bridge/BridgeValidator.sol";

contract BridgeValidatorTest is Test {
    BridgeValidator public validator;

    address public owner;
    address[] public signers;
    uint256[] public signerKeys;
    uint256 public constant THRESHOLD = 5;
    uint256 public constant SIGNER_COUNT = 7;

    event SignerAdded(address indexed signer, uint256 signerSetVersion);
    event SignerRemoved(address indexed signer, uint256 signerSetVersion);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold, uint256 signerSetVersion);
    event SignerSetRotated(uint256 oldVersion, uint256 newVersion);
    event MessageValidated(bytes32 indexed messageHash, uint256 nonce, address indexed sender);
    event NonceInvalidated(uint256 indexed nonce, address indexed sender);

    function setUp() public {
        owner = makeAddr("owner");

        // Create 7 signers with known private keys
        for (uint256 i = 0; i < SIGNER_COUNT; i++) {
            uint256 privateKey = uint256(keccak256(abi.encodePacked("signer", i)));
            signerKeys.push(privateKey);
            signers.push(vm.addr(privateKey));
        }

        vm.prank(owner);
        validator = new BridgeValidator(signers, THRESHOLD);
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        (address[] memory currentSigners, uint256 threshold, uint256 activatedAt) = validator.getCurrentSignerSet();

        assertEq(currentSigners.length, SIGNER_COUNT);
        assertEq(threshold, THRESHOLD);
        assertGt(activatedAt, 0);
        assertEq(validator.signerSetVersion(), 1);

        for (uint256 i = 0; i < SIGNER_COUNT; i++) {
            assertTrue(validator.isSigner(signers[i]));
        }
    }

    function test_Constructor_RevertsOnTooFewSigners() public {
        address[] memory fewSigners = new address[](2);
        fewSigners[0] = makeAddr("s1");
        fewSigners[1] = makeAddr("s2");

        vm.expectRevert(BridgeValidator.InvalidSignerCount.selector);
        new BridgeValidator(fewSigners, 2);
    }

    function test_Constructor_RevertsOnTooManySigners() public {
        address[] memory manySigners = new address[](16);
        for (uint256 i = 0; i < 16; i++) {
            manySigners[i] = makeAddr(string(abi.encodePacked("signer", i)));
        }

        vm.expectRevert(BridgeValidator.InvalidSignerCount.selector);
        new BridgeValidator(manySigners, 8);
    }

    function test_Constructor_RevertsOnZeroThreshold() public {
        vm.expectRevert(BridgeValidator.InvalidThreshold.selector);
        new BridgeValidator(signers, 0);
    }

    function test_Constructor_RevertsOnThresholdGreaterThanSigners() public {
        vm.expectRevert(BridgeValidator.InvalidThreshold.selector);
        new BridgeValidator(signers, 8);
    }

    function test_Constructor_RevertsOnZeroAddressSigner() public {
        address[] memory badSigners = new address[](3);
        badSigners[0] = makeAddr("s1");
        badSigners[1] = address(0);
        badSigners[2] = makeAddr("s3");

        vm.expectRevert(BridgeValidator.ZeroAddress.selector);
        new BridgeValidator(badSigners, 2);
    }

    function test_Constructor_RevertsOnDuplicateSigner() public {
        address[] memory dupSigners = new address[](3);
        dupSigners[0] = makeAddr("s1");
        dupSigners[1] = makeAddr("s1");
        dupSigners[2] = makeAddr("s3");

        vm.expectRevert(BridgeValidator.SignerAlreadyExists.selector);
        new BridgeValidator(dupSigners, 2);
    }

    // ============ Signature Verification Tests ============

    function test_VerifyMpcSignatures_ValidSignatures() public {
        BridgeValidator.BridgeMessage memory message = _createTestMessage();

        bytes[] memory signatures = _signMessage(message, 5);

        bool valid = validator.verifyMpcSignatures(message, signatures);
        assertTrue(valid);
    }

    function test_VerifyMpcSignatures_ExactThresholdSignatures() public {
        BridgeValidator.BridgeMessage memory message = _createTestMessage();

        bytes[] memory signatures = _signMessage(message, THRESHOLD);

        bool valid = validator.verifyMpcSignatures(message, signatures);
        assertTrue(valid);
    }

    function test_VerifyMpcSignatures_MoreThanThreshold() public {
        BridgeValidator.BridgeMessage memory message = _createTestMessage();

        bytes[] memory signatures = _signMessage(message, SIGNER_COUNT);

        bool valid = validator.verifyMpcSignatures(message, signatures);
        assertTrue(valid);
    }

    function test_VerifyMpcSignatures_RevertsOnInsufficientSignatures() public {
        BridgeValidator.BridgeMessage memory message = _createTestMessage();

        bytes[] memory signatures = _signMessage(message, THRESHOLD - 1);

        vm.expectRevert(BridgeValidator.InsufficientSignatures.selector);
        validator.verifyMpcSignatures(message, signatures);
    }

    function test_VerifyMpcSignatures_RevertsOnExpiredMessage() public {
        BridgeValidator.BridgeMessage memory message = _createTestMessage();
        message.deadline = block.timestamp - 1;

        bytes[] memory signatures = _signMessage(message, THRESHOLD);

        vm.expectRevert(BridgeValidator.ExpiredMessage.selector);
        validator.verifyMpcSignatures(message, signatures);
    }

    function test_VerifyMpcSignatures_RevertsOnUsedNonce() public {
        BridgeValidator.BridgeMessage memory message = _createTestMessage();

        bytes[] memory signatures = _signMessage(message, THRESHOLD);

        // First verification should succeed
        validator.verifyMpcSignatures(message, signatures);

        // Second verification with same nonce should fail
        vm.expectRevert(BridgeValidator.NonceAlreadyUsed.selector);
        validator.verifyMpcSignatures(message, signatures);
    }

    function test_VerifyMpcSignatures_RevertsOnDuplicateSignature() public {
        BridgeValidator.BridgeMessage memory message = _createTestMessage();

        // Create signatures with duplicates
        bytes[] memory signatures = new bytes[](THRESHOLD);
        bytes32 messageHash = validator.hashBridgeMessage(message);
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKeys[0], ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Use same signature multiple times
        for (uint256 i = 0; i < THRESHOLD; i++) {
            signatures[i] = sig;
        }

        vm.expectRevert(BridgeValidator.DuplicateSignature.selector);
        validator.verifyMpcSignatures(message, signatures);
    }

    function test_VerifyMpcSignatures_EmitsEvent() public {
        BridgeValidator.BridgeMessage memory message = _createTestMessage();
        bytes[] memory signatures = _signMessage(message, THRESHOLD);

        bytes32 messageHash = validator.hashBridgeMessage(message);

        vm.expectEmit(true, true, false, true);
        emit MessageValidated(messageHash, message.nonce, message.sender);

        validator.verifyMpcSignatures(message, signatures);
    }

    // ============ View Verification Tests ============

    function test_VerifySignaturesView_ReturnsValidCount() public {
        BridgeValidator.BridgeMessage memory message = _createTestMessage();
        bytes[] memory signatures = _signMessage(message, THRESHOLD);

        (bool valid, uint256 validCount) = validator.verifySignaturesView(message, signatures);

        assertTrue(valid);
        assertEq(validCount, THRESHOLD);
    }

    function test_VerifySignaturesView_DoesNotConsumeNonce() public {
        BridgeValidator.BridgeMessage memory message = _createTestMessage();
        bytes[] memory signatures = _signMessage(message, THRESHOLD);

        // Call view function multiple times
        validator.verifySignaturesView(message, signatures);
        validator.verifySignaturesView(message, signatures);

        // Nonce should still be unused
        assertFalse(validator.isNonceUsed(message.sender, message.nonce));
    }

    // ============ Nonce Management Tests ============

    function test_InvalidateNonce() public {
        address user = makeAddr("user");
        uint256 nonce = 42;

        assertFalse(validator.isNonceUsed(user, nonce));

        vm.prank(user);
        vm.expectEmit(true, true, false, false);
        emit NonceInvalidated(nonce, user);
        validator.invalidateNonce(nonce);

        assertTrue(validator.isNonceUsed(user, nonce));
    }

    function test_InvalidateNonce_RevertsOnAlreadyUsed() public {
        address user = makeAddr("user");
        uint256 nonce = 42;

        vm.startPrank(user);
        validator.invalidateNonce(nonce);

        vm.expectRevert(BridgeValidator.NonceAlreadyUsed.selector);
        validator.invalidateNonce(nonce);
        vm.stopPrank();
    }

    // ============ Signer Management Tests ============

    function test_AddSigner() public {
        address newSigner = makeAddr("newSigner");

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit SignerAdded(newSigner, 1);
        validator.addSigner(newSigner);

        assertTrue(validator.isSigner(newSigner));
        assertEq(validator.getSignerCount(), SIGNER_COUNT + 1);
    }

    function test_AddSigner_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(BridgeValidator.ZeroAddress.selector);
        validator.addSigner(address(0));
    }

    function test_AddSigner_RevertsOnExistingSigner() public {
        vm.prank(owner);
        vm.expectRevert(BridgeValidator.SignerAlreadyExists.selector);
        validator.addSigner(signers[0]);
    }

    function test_AddSigner_RevertsOnMaxSigners() public {
        // Add signers up to max
        for (uint256 i = SIGNER_COUNT; i < 15; i++) {
            vm.prank(owner);
            validator.addSigner(makeAddr(string(abi.encodePacked("extra", i))));
        }

        vm.prank(owner);
        vm.expectRevert(BridgeValidator.InvalidSignerCount.selector);
        validator.addSigner(makeAddr("oneMore"));
    }

    function test_RemoveSigner() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit SignerRemoved(signers[0], 1);
        validator.removeSigner(signers[0]);

        assertFalse(validator.isSigner(signers[0]));
        assertEq(validator.getSignerCount(), SIGNER_COUNT - 1);
    }

    function test_RemoveSigner_RevertsOnNonSigner() public {
        vm.prank(owner);
        vm.expectRevert(BridgeValidator.SignerNotFound.selector);
        validator.removeSigner(makeAddr("nonSigner"));
    }

    function test_RemoveSigner_RevertsOnMinSigners() public {
        // Remove signers down to minimum (3)
        // Start with 7 signers, threshold 5
        // First lower threshold to allow removal
        vm.prank(owner);
        validator.updateThreshold(3);

        // Remove signers one by one until we have 3 left
        for (uint256 i = 0; i < SIGNER_COUNT - 3; i++) {
            vm.prank(owner);
            validator.removeSigner(signers[i]);
        }

        // Now try to remove another signer when we only have 3 left
        // This should fail because min signers is 3
        vm.prank(owner);
        vm.expectRevert(BridgeValidator.InvalidSignerCount.selector);
        validator.removeSigner(signers[SIGNER_COUNT - 3]);
    }

    function test_RemoveSigner_RevertsIfThresholdNotAchievable() public {
        // With 7 signers and threshold 5, removing would leave 6 signers
        // which is still >= threshold, but let's test the edge case

        // First reduce to 5 signers
        vm.prank(owner);
        validator.removeSigner(signers[0]);
        vm.prank(owner);
        validator.removeSigner(signers[1]);

        // Now we have 5 signers with threshold 5
        // Removing one more would make threshold unachievable
        vm.prank(owner);
        vm.expectRevert(BridgeValidator.InvalidThreshold.selector);
        validator.removeSigner(signers[2]);
    }

    // ============ Threshold Management Tests ============

    function test_UpdateThreshold() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ThresholdUpdated(THRESHOLD, 3, 1);
        validator.updateThreshold(3);

        (, uint256 threshold,) = validator.getCurrentSignerSet();
        assertEq(threshold, 3);
    }

    function test_UpdateThreshold_RevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(BridgeValidator.InvalidThreshold.selector);
        validator.updateThreshold(0);
    }

    function test_UpdateThreshold_RevertsOnExceedingSigners() public {
        vm.prank(owner);
        vm.expectRevert(BridgeValidator.InvalidThreshold.selector);
        validator.updateThreshold(SIGNER_COUNT + 1);
    }

    // ============ Signer Rotation Tests ============

    function test_RotateSignerSet() public {
        // Warp past the rotation cooldown (1 day) since lastRotationTime is 0
        vm.warp(block.timestamp + 1 days + 1);

        // Create new signers
        address[] memory newSigners = new address[](5);
        uint256[] memory newKeys = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            uint256 pk = uint256(keccak256(abi.encodePacked("newSigner", i)));
            newKeys[i] = pk;
            newSigners[i] = vm.addr(pk);
        }

        // Get the current signer set version
        uint256 currentVersion = validator.signerSetVersion();

        // Create rotation proof signed by current signers
        bytes32 rotationHash = keccak256(
            abi.encode("ROTATE_SIGNER_SET", currentVersion, newSigners, 3, block.chainid)
        );
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", rotationHash));

        bytes[] memory rotationProof = new bytes[](THRESHOLD);
        for (uint256 i = 0; i < THRESHOLD; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKeys[i], ethSignedHash);
            rotationProof[i] = abi.encodePacked(r, s, v);
        }

        vm.prank(owner);
        validator.rotateSignerSet(newSigners, 3, rotationProof);

        // Verify new signer set
        assertEq(validator.signerSetVersion(), currentVersion + 1);
        (address[] memory currentSigners, uint256 threshold,) = validator.getCurrentSignerSet();
        assertEq(currentSigners.length, 5);
        assertEq(threshold, 3);

        // Old signers should not be valid
        for (uint256 i = 0; i < SIGNER_COUNT; i++) {
            assertFalse(validator.isSigner(signers[i]));
        }

        // New signers should be valid
        for (uint256 i = 0; i < 5; i++) {
            assertTrue(validator.isSigner(newSigners[i]));
        }
    }

    function test_RotateSignerSet_RespectsCooldown() public {
        // Warp past the initial rotation cooldown
        vm.warp(block.timestamp + 1 days + 1);

        address[] memory newSigners = new address[](3);
        uint256[] memory newKeys = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            uint256 pk = uint256(keccak256(abi.encodePacked("newSig", i)));
            newKeys[i] = pk;
            newSigners[i] = vm.addr(pk);
        }

        uint256 currentVersion = validator.signerSetVersion();

        bytes32 rotationHash = keccak256(
            abi.encode("ROTATE_SIGNER_SET", currentVersion, newSigners, 2, block.chainid)
        );
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", rotationHash));

        bytes[] memory rotationProof = new bytes[](THRESHOLD);
        for (uint256 i = 0; i < THRESHOLD; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKeys[i], ethSignedHash);
            rotationProof[i] = abi.encodePacked(r, s, v);
        }

        // First rotation
        vm.prank(owner);
        validator.rotateSignerSet(newSigners, 2, rotationProof);

        // Create another rotation proof for immediate retry
        address[] memory newSigners2 = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            uint256 pk = uint256(keccak256(abi.encodePacked("newSig2", i)));
            newSigners2[i] = vm.addr(pk);
        }

        // Try to rotate again immediately - should fail with cooldown
        vm.prank(owner);
        vm.expectRevert(BridgeValidator.RotationCooldownActive.selector);
        // Use empty proof since it will fail before validation anyway
        bytes[] memory emptyProof = new bytes[](2);
        validator.rotateSignerSet(newSigners2, 2, emptyProof);
    }

    // ============ Pause Tests ============

    function test_Pause() public {
        vm.prank(owner);
        validator.pause();

        BridgeValidator.BridgeMessage memory message = _createTestMessage();
        bytes[] memory signatures = _signMessage(message, THRESHOLD);

        vm.expectRevert();
        validator.verifyMpcSignatures(message, signatures);
    }

    function test_Unpause() public {
        vm.prank(owner);
        validator.pause();

        vm.prank(owner);
        validator.unpause();

        BridgeValidator.BridgeMessage memory message = _createTestMessage();
        bytes[] memory signatures = _signMessage(message, THRESHOLD);

        bool valid = validator.verifyMpcSignatures(message, signatures);
        assertTrue(valid);
    }

    // ============ View Function Tests ============

    function test_GetCurrentSignerSet() public view {
        (address[] memory currentSigners, uint256 threshold, uint256 activatedAt) = validator.getCurrentSignerSet();

        assertEq(currentSigners.length, SIGNER_COUNT);
        assertEq(threshold, THRESHOLD);
        assertGt(activatedAt, 0);
    }

    function test_GetSignerCount() public view {
        assertEq(validator.getSignerCount(), SIGNER_COUNT);
    }

    function test_IsNonceUsed() public {
        assertFalse(validator.isNonceUsed(makeAddr("user"), 0));
    }

    function test_HashBridgeMessage() public {
        BridgeValidator.BridgeMessage memory message = _createTestMessage();

        bytes32 hash1 = validator.hashBridgeMessage(message);
        bytes32 hash2 = validator.hashBridgeMessage(message);

        assertEq(hash1, hash2);
        assertNotEq(hash1, bytes32(0));
    }

    // ============ Helper Functions ============

    function _createTestMessage() internal returns (BridgeValidator.BridgeMessage memory) {
        return BridgeValidator.BridgeMessage({
            requestId: keccak256("testRequest"),
            sender: makeAddr("sender"),
            recipient: makeAddr("recipient"),
            token: makeAddr("token"),
            amount: 1000 ether,
            sourceChain: 1,
            targetChain: 137,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });
    }

    function _signMessage(
        BridgeValidator.BridgeMessage memory message,
        uint256 numSigners
    ) internal returns (bytes[] memory) {
        bytes32 messageHash = validator.hashBridgeMessage(message);
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        bytes[] memory signatures = new bytes[](numSigners);
        for (uint256 i = 0; i < numSigners; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKeys[i], ethSignedHash);
            signatures[i] = abi.encodePacked(r, s, v);
        }

        return signatures;
    }
}
