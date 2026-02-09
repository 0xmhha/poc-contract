// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { MerchantRegistry } from "../../src/subscription/MerchantRegistry.sol";

/**
 * @title MerchantRegistry Test
 * @notice TDD RED Phase - Tests for MerchantRegistry
 * @dev Tests merchant registration, verification, and fee management
 */
contract MerchantRegistryTest is Test {
    MerchantRegistry public registry;

    // Test addresses
    address public owner;
    address public verifier;
    address public merchant1;
    address public merchant2;
    address public user;

    // Constants
    uint256 public constant DEFAULT_FEE_BPS = 250; // 2.5%
    uint256 public constant MAX_FEE_BPS = 1000; // 10%

    function setUp() public {
        owner = makeAddr("owner");
        verifier = makeAddr("verifier");
        merchant1 = makeAddr("merchant1");
        merchant2 = makeAddr("merchant2");
        user = makeAddr("user");

        vm.prank(owner);
        registry = new MerchantRegistry();
    }

    // =========================================================================
    // Registration Tests
    // =========================================================================

    function test_registerMerchant_Success() public {
        vm.prank(merchant1);
        registry.registerMerchant("Test Merchant", "https://merchant.test", "merchant@test.com");

        assertTrue(registry.isMerchantRegistered(merchant1));
        assertFalse(registry.isMerchantVerified(merchant1));
    }

    function test_registerMerchant_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit MerchantRegistry.MerchantRegistered(merchant1, "Test Merchant");

        vm.prank(merchant1);
        registry.registerMerchant("Test Merchant", "https://merchant.test", "merchant@test.com");
    }

    function test_registerMerchant_RevertsIf_AlreadyRegistered() public {
        vm.prank(merchant1);
        registry.registerMerchant("Test Merchant", "https://merchant.test", "merchant@test.com");

        vm.prank(merchant1);
        vm.expectRevert(MerchantRegistry.AlreadyRegistered.selector);
        registry.registerMerchant("Test Merchant 2", "https://merchant2.test", "merchant2@test.com");
    }

    function test_registerMerchant_RevertsIf_EmptyName() public {
        vm.prank(merchant1);
        vm.expectRevert(MerchantRegistry.InvalidMerchantData.selector);
        registry.registerMerchant("", "https://merchant.test", "merchant@test.com");
    }

    function test_updateMerchantInfo_Success() public {
        vm.prank(merchant1);
        registry.registerMerchant("Test Merchant", "https://merchant.test", "merchant@test.com");

        vm.prank(merchant1);
        registry.updateMerchantInfo("Updated Merchant", "https://updated.test", "updated@test.com");

        (string memory name,,,,,) = registry.getMerchantInfo(merchant1);
        assertEq(name, "Updated Merchant");
    }

    function test_updateMerchantInfo_RevertsIf_NotRegistered() public {
        vm.prank(merchant1);
        vm.expectRevert(MerchantRegistry.NotRegistered.selector);
        registry.updateMerchantInfo("New Name", "https://new.test", "new@test.com");
    }

    // =========================================================================
    // Verification Tests
    // =========================================================================

    function test_verifyMerchant_Success() public {
        _registerMerchant(merchant1);
        _addVerifier(verifier);

        vm.prank(verifier);
        registry.verifyMerchant(merchant1);

        assertTrue(registry.isMerchantVerified(merchant1));
    }

    function test_verifyMerchant_EmitsEvent() public {
        _registerMerchant(merchant1);
        _addVerifier(verifier);

        vm.expectEmit(true, true, false, true);
        emit MerchantRegistry.MerchantVerified(merchant1, verifier);

        vm.prank(verifier);
        registry.verifyMerchant(merchant1);
    }

    function test_verifyMerchant_RevertsIf_NotVerifier() public {
        _registerMerchant(merchant1);

        vm.prank(user);
        vm.expectRevert(MerchantRegistry.NotVerifier.selector);
        registry.verifyMerchant(merchant1);
    }

    function test_verifyMerchant_RevertsIf_NotRegistered() public {
        _addVerifier(verifier);

        vm.prank(verifier);
        vm.expectRevert(MerchantRegistry.NotRegistered.selector);
        registry.verifyMerchant(merchant1);
    }

    function test_verifyMerchant_RevertsIf_AlreadyVerified() public {
        _registerAndVerifyMerchant(merchant1);

        vm.prank(verifier);
        vm.expectRevert(MerchantRegistry.AlreadyVerified.selector);
        registry.verifyMerchant(merchant1);
    }

    function test_revokeVerification_Success() public {
        _registerAndVerifyMerchant(merchant1);

        vm.prank(verifier);
        registry.revokeVerification(merchant1);

        assertFalse(registry.isMerchantVerified(merchant1));
    }

    function test_revokeVerification_EmitsEvent() public {
        _registerAndVerifyMerchant(merchant1);

        vm.expectEmit(true, true, false, true);
        emit MerchantRegistry.VerificationRevoked(merchant1, verifier);

        vm.prank(verifier);
        registry.revokeVerification(merchant1);
    }

    function test_revokeVerification_RevertsIf_NotVerified() public {
        _registerMerchant(merchant1);
        _addVerifier(verifier);

        vm.prank(verifier);
        vm.expectRevert(MerchantRegistry.NotVerified.selector);
        registry.revokeVerification(merchant1);
    }

    // =========================================================================
    // Fee Configuration Tests
    // =========================================================================

    function test_setMerchantFee_Success() public {
        _registerAndVerifyMerchant(merchant1);

        vm.prank(owner);
        registry.setMerchantFee(merchant1, 500); // 5%

        assertEq(registry.getMerchantFee(merchant1), 500);
    }

    function test_setMerchantFee_EmitsEvent() public {
        _registerAndVerifyMerchant(merchant1);

        vm.expectEmit(true, false, false, true);
        emit MerchantRegistry.MerchantFeeUpdated(merchant1, 500);

        vm.prank(owner);
        registry.setMerchantFee(merchant1, 500);
    }

    function test_setMerchantFee_RevertsIf_NotOwner() public {
        _registerAndVerifyMerchant(merchant1);

        vm.prank(user);
        vm.expectRevert();
        registry.setMerchantFee(merchant1, 500);
    }

    function test_setMerchantFee_RevertsIf_FeeTooHigh() public {
        _registerAndVerifyMerchant(merchant1);

        vm.prank(owner);
        vm.expectRevert(MerchantRegistry.FeeTooHigh.selector);
        registry.setMerchantFee(merchant1, MAX_FEE_BPS + 1);
    }

    function test_getMerchantFee_ReturnsDefault_WhenNotSet() public {
        _registerAndVerifyMerchant(merchant1);

        assertEq(registry.getMerchantFee(merchant1), DEFAULT_FEE_BPS);
    }

    // =========================================================================
    // Verifier Management Tests
    // =========================================================================

    function test_addVerifier_Success() public {
        vm.prank(owner);
        registry.addVerifier(verifier);

        assertTrue(registry.isVerifier(verifier));
    }

    function test_addVerifier_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit MerchantRegistry.VerifierAdded(verifier);

        vm.prank(owner);
        registry.addVerifier(verifier);
    }

    function test_addVerifier_RevertsIf_NotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        registry.addVerifier(verifier);
    }

    function test_addVerifier_RevertsIf_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(MerchantRegistry.InvalidAddress.selector);
        registry.addVerifier(address(0));
    }

    function test_addVerifier_RevertsIf_AlreadyVerifier() public {
        _addVerifier(verifier);

        vm.prank(owner);
        vm.expectRevert(MerchantRegistry.AlreadyVerifier.selector);
        registry.addVerifier(verifier);
    }

    function test_removeVerifier_Success() public {
        _addVerifier(verifier);

        vm.prank(owner);
        registry.removeVerifier(verifier);

        assertFalse(registry.isVerifier(verifier));
    }

    function test_removeVerifier_EmitsEvent() public {
        _addVerifier(verifier);

        vm.expectEmit(true, false, false, true);
        emit MerchantRegistry.VerifierRemoved(verifier);

        vm.prank(owner);
        registry.removeVerifier(verifier);
    }

    function test_removeVerifier_RevertsIf_NotVerifier() public {
        vm.prank(owner);
        vm.expectRevert(MerchantRegistry.NotVerifier.selector);
        registry.removeVerifier(verifier);
    }

    // =========================================================================
    // Suspension Tests
    // =========================================================================

    function test_suspendMerchant_Success() public {
        _registerAndVerifyMerchant(merchant1);

        vm.prank(owner);
        registry.suspendMerchant(merchant1);

        assertTrue(registry.isMerchantSuspended(merchant1));
    }

    function test_suspendMerchant_EmitsEvent() public {
        _registerAndVerifyMerchant(merchant1);

        vm.expectEmit(true, false, false, true);
        emit MerchantRegistry.MerchantSuspended(merchant1);

        vm.prank(owner);
        registry.suspendMerchant(merchant1);
    }

    function test_unsuspendMerchant_Success() public {
        _registerAndVerifyMerchant(merchant1);

        vm.prank(owner);
        registry.suspendMerchant(merchant1);

        vm.prank(owner);
        registry.unsuspendMerchant(merchant1);

        assertFalse(registry.isMerchantSuspended(merchant1));
    }

    function test_unsuspendMerchant_EmitsEvent() public {
        _registerAndVerifyMerchant(merchant1);

        vm.prank(owner);
        registry.suspendMerchant(merchant1);

        vm.expectEmit(true, false, false, true);
        emit MerchantRegistry.MerchantUnsuspended(merchant1);

        vm.prank(owner);
        registry.unsuspendMerchant(merchant1);
    }

    // =========================================================================
    // View Functions Tests
    // =========================================================================

    function test_getMerchantInfo_ReturnsCorrectData() public {
        vm.prank(merchant1);
        registry.registerMerchant("Test Merchant", "https://merchant.test", "merchant@test.com");

        (
            string memory name,
            string memory website,
            string memory email,
            bool isVerified,
            bool isSuspended,
            uint256 registeredAt
        ) = registry.getMerchantInfo(merchant1);

        assertEq(name, "Test Merchant");
        assertEq(website, "https://merchant.test");
        assertEq(email, "merchant@test.com");
        assertFalse(isVerified);
        assertFalse(isSuspended);
        assertGt(registeredAt, 0);
    }

    function test_getVerifiedMerchants_ReturnsCorrectList() public {
        _registerAndVerifyMerchant(merchant1);
        _registerAndVerifyMerchant(merchant2);

        address[] memory verified = registry.getVerifiedMerchants();
        assertEq(verified.length, 2);
    }

    function test_getTotalMerchants_ReturnsCorrectCount() public {
        _registerMerchant(merchant1);
        _registerMerchant(merchant2);

        assertEq(registry.getTotalMerchants(), 2);
    }

    function test_isMerchantActive_ReturnsFalse_WhenSuspended() public {
        _registerAndVerifyMerchant(merchant1);

        vm.prank(owner);
        registry.suspendMerchant(merchant1);

        assertFalse(registry.isMerchantActive(merchant1));
    }

    function test_isMerchantActive_ReturnsFalse_WhenNotVerified() public {
        _registerMerchant(merchant1);

        assertFalse(registry.isMerchantActive(merchant1));
    }

    function test_isMerchantActive_ReturnsTrue_WhenVerifiedAndNotSuspended() public {
        _registerAndVerifyMerchant(merchant1);

        assertTrue(registry.isMerchantActive(merchant1));
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_setMerchantFee_ValidRange(uint256 feeBps) public {
        vm.assume(feeBps > 0 && feeBps <= MAX_FEE_BPS);

        _registerAndVerifyMerchant(merchant1);

        vm.prank(owner);
        registry.setMerchantFee(merchant1, feeBps);

        assertEq(registry.getMerchantFee(merchant1), feeBps);
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _registerMerchant(address merchant) internal {
        vm.prank(merchant);
        registry.registerMerchant("Test Merchant", "https://merchant.test", "merchant@test.com");
    }

    function _addVerifier(address _verifier) internal {
        vm.prank(owner);
        registry.addVerifier(_verifier);
    }

    function _registerAndVerifyMerchant(address merchant) internal {
        _registerMerchant(merchant);

        // Only add verifier if not already added
        if (!registry.isVerifier(verifier)) {
            _addVerifier(verifier);
        }

        vm.prank(verifier);
        registry.verifyMerchant(merchant);
    }
}
