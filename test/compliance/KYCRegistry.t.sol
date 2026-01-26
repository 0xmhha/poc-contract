// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { KYCRegistry } from "../../src/compliance/KYCRegistry.sol";

contract KYCRegistryTest is Test {
    KYCRegistry public registry;

    address public admin;
    address public kycAdmin;
    address public sanctionsAdmin;
    address public kycProvider;
    address public user;

    event KYCStatusUpdated(
        address indexed account,
        KYCRegistry.KYCStatus oldStatus,
        KYCRegistry.KYCStatus newStatus,
        address indexed updatedBy
    );
    event KYCVerified(address indexed account, bytes32 kycProviderHash, string jurisdiction, uint256 expiresAt);
    event KYCRejected(address indexed account, string reason, address indexed rejectedBy);
    event KYCExpired(address indexed account);
    event RiskLevelUpdated(address indexed account, KYCRegistry.RiskLevel oldLevel, KYCRegistry.RiskLevel newLevel);
    event SanctionsAdded(
        address indexed account, KYCRegistry.SanctionsList listType, bytes32 sanctionId, string reason
    );
    event SanctionsRemoved(address indexed account, KYCRegistry.SanctionsList listType, string reason);
    event AddedToAllowList(address indexed account);
    event RemovedFromAllowList(address indexed account);
    event AddedToBlockList(address indexed account, string reason);
    event RemovedFromBlockList(address indexed account);
    event KycProviderRegistered(address indexed provider, string name, string jurisdiction);
    event KycProviderDeactivated(address indexed provider);

    function setUp() public {
        admin = makeAddr("admin");
        kycAdmin = makeAddr("kycAdmin");
        sanctionsAdmin = makeAddr("sanctionsAdmin");
        kycProvider = makeAddr("kycProvider");
        user = makeAddr("user");

        vm.startPrank(admin);
        registry = new KYCRegistry(admin);
        registry.grantRole(registry.KYC_ADMIN_ROLE(), kycAdmin);
        registry.grantRole(registry.SANCTIONS_ADMIN_ROLE(), sanctionsAdmin);
        registry.registerKycProvider(kycProvider, "TestProvider", "US");
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.KYC_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.SANCTIONS_ADMIN_ROLE(), admin));
        assertEq(registry.defaultKycValidity(), 365 days);
    }

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(KYCRegistry.InvalidAddress.selector);
        new KYCRegistry(address(0));
    }

    // ============ KYC Initiation Tests ============

    function test_InitiateKyc_Success() public {
        vm.prank(kycAdmin);
        registry.initiateKyc(user);

        KYCRegistry.KycRecord memory record = registry.getKycRecord(user);
        assertEq(uint8(record.status), uint8(KYCRegistry.KYCStatus.PENDING));
    }

    function test_InitiateKyc_EmitsEvent() public {
        vm.prank(kycAdmin);
        vm.expectEmit(true, true, false, true);
        emit KYCStatusUpdated(user, KYCRegistry.KYCStatus.NONE, KYCRegistry.KYCStatus.PENDING, kycAdmin);
        registry.initiateKyc(user);
    }

    function test_InitiateKyc_RevertsOnZeroAddress() public {
        vm.prank(kycAdmin);
        vm.expectRevert(KYCRegistry.InvalidAddress.selector);
        registry.initiateKyc(address(0));
    }

    function test_InitiateKyc_RevertsOnSanctioned() public {
        vm.prank(sanctionsAdmin);
        registry.addToSanctions(user, KYCRegistry.SanctionsList.OFAC, bytes32(0), "Test");

        vm.prank(kycAdmin);
        vm.expectRevert(KYCRegistry.AccountSanctioned.selector);
        registry.initiateKyc(user);
    }

    function test_InitiateKyc_RevertsOnBlocked() public {
        vm.prank(kycAdmin);
        registry.addToBlockList(user, "Test");

        vm.prank(kycAdmin);
        vm.expectRevert(KYCRegistry.AccountBlocked.selector);
        registry.initiateKyc(user);
    }

    function test_InitiateKyc_RevertsOnAlreadyVerified() public {
        _verifyUser(user);

        vm.prank(kycAdmin);
        vm.expectRevert(KYCRegistry.KYCAlreadyVerified.selector);
        registry.initiateKyc(user);
    }

    // ============ KYC Verification Tests ============

    function test_VerifyKyc_Success() public {
        bytes32 providerHash = keccak256("provider");
        bytes32 dataHash = keccak256("data");

        vm.prank(kycProvider);
        registry.verifyKyc(user, providerHash, dataHash, "US", KYCRegistry.RiskLevel.LOW, 0);

        KYCRegistry.KycRecord memory record = registry.getKycRecord(user);
        assertEq(uint8(record.status), uint8(KYCRegistry.KYCStatus.VERIFIED));
        assertEq(uint8(record.riskLevel), uint8(KYCRegistry.RiskLevel.LOW));
        assertEq(record.kycProviderHash, providerHash);
        assertEq(record.kycDataHash, dataHash);
        assertEq(record.expiresAt, block.timestamp + 365 days);
        assertEq(registry.totalVerified(), 1);
    }

    function test_VerifyKyc_CustomValidity() public {
        vm.prank(kycProvider);
        registry.verifyKyc(user, bytes32(0), bytes32(0), "US", KYCRegistry.RiskLevel.LOW, 180);

        KYCRegistry.KycRecord memory record = registry.getKycRecord(user);
        assertEq(record.expiresAt, block.timestamp + 180 days);
    }

    function test_VerifyKyc_RevertsOnProhibitedRiskLevel() public {
        vm.prank(kycProvider);
        vm.expectRevert(KYCRegistry.InvalidRiskLevel.selector);
        registry.verifyKyc(user, bytes32(0), bytes32(0), "US", KYCRegistry.RiskLevel.PROHIBITED, 0);
    }

    function test_VerifyKyc_RevertsOnEmptyJurisdiction() public {
        vm.prank(kycProvider);
        vm.expectRevert(KYCRegistry.InvalidJurisdiction.selector);
        registry.verifyKyc(user, bytes32(0), bytes32(0), "", KYCRegistry.RiskLevel.LOW, 0);
    }

    function test_VerifyKyc_RevertsOnInvalidValidity() public {
        vm.prank(kycProvider);
        vm.expectRevert(KYCRegistry.InvalidValidity.selector);
        registry.verifyKyc(user, bytes32(0), bytes32(0), "US", KYCRegistry.RiskLevel.LOW, 10); // Below MIN_KYC_VALIDITY
    }

    // ============ KYC Rejection Tests ============

    function test_RejectKyc_Success() public {
        vm.prank(kycAdmin);
        registry.initiateKyc(user);

        vm.prank(kycAdmin);
        registry.rejectKyc(user, "Failed verification");

        KYCRegistry.KycRecord memory record = registry.getKycRecord(user);
        assertEq(uint8(record.status), uint8(KYCRegistry.KYCStatus.REJECTED));
    }

    function test_RejectKyc_EmitsEvent() public {
        vm.prank(kycAdmin);
        vm.expectEmit(true, true, false, true);
        emit KYCRejected(user, "Failed", kycAdmin);
        registry.rejectKyc(user, "Failed");
    }

    // ============ Risk Level Tests ============

    function test_UpdateRiskLevel_Success() public {
        _verifyUser(user);

        vm.prank(kycAdmin);
        registry.updateRiskLevel(user, KYCRegistry.RiskLevel.HIGH);

        KYCRegistry.KycRecord memory record = registry.getKycRecord(user);
        assertEq(uint8(record.riskLevel), uint8(KYCRegistry.RiskLevel.HIGH));
    }

    function test_UpdateRiskLevel_ProhibitedAddsToBlockList() public {
        _verifyUser(user);

        vm.prank(kycAdmin);
        registry.updateRiskLevel(user, KYCRegistry.RiskLevel.PROHIBITED);

        assertTrue(registry.blockList(user));
    }

    // ============ KYC Expiration Tests ============

    function test_ExpireKyc_Success() public {
        _verifyUser(user);

        vm.prank(kycAdmin);
        registry.expireKyc(user);

        KYCRegistry.KycRecord memory record = registry.getKycRecord(user);
        assertEq(uint8(record.status), uint8(KYCRegistry.KYCStatus.EXPIRED));
        assertEq(registry.totalVerified(), 0);
    }

    function test_ExpireKyc_RevertsOnNotVerified() public {
        vm.prank(kycAdmin);
        vm.expectRevert(KYCRegistry.KYCNotVerified.selector);
        registry.expireKyc(user);
    }

    // ============ Sanctions Tests ============

    function test_AddToSanctions_Success() public {
        bytes32 sanctionId = keccak256("SANCTION_001");

        vm.prank(sanctionsAdmin);
        registry.addToSanctions(user, KYCRegistry.SanctionsList.OFAC, sanctionId, "OFAC SDN List");

        KYCRegistry.SanctionsRecord memory record = registry.getSanctionsRecord(user);
        assertTrue(record.isSanctioned);
        assertEq(uint8(record.listType), uint8(KYCRegistry.SanctionsList.OFAC));
        assertEq(record.sanctionId, sanctionId);
        assertTrue(registry.blockList(user));
        assertEq(registry.totalSanctioned(), 1);
    }

    function test_AddToSanctions_RevertsOnNoneType() public {
        vm.prank(sanctionsAdmin);
        vm.expectRevert(KYCRegistry.InvalidStatus.selector);
        registry.addToSanctions(user, KYCRegistry.SanctionsList.NONE, bytes32(0), "");
    }

    function test_RemoveFromSanctions_Success() public {
        vm.prank(sanctionsAdmin);
        registry.addToSanctions(user, KYCRegistry.SanctionsList.OFAC, bytes32(0), "Test");

        vm.prank(sanctionsAdmin);
        registry.removeFromSanctions(user, "Delisted");

        KYCRegistry.SanctionsRecord memory record = registry.getSanctionsRecord(user);
        assertFalse(record.isSanctioned);
        assertEq(registry.totalSanctioned(), 0);
    }

    function test_RemoveFromSanctions_RevertsOnNotSanctioned() public {
        vm.prank(sanctionsAdmin);
        vm.expectRevert(KYCRegistry.InvalidStatus.selector);
        registry.removeFromSanctions(user, "Not sanctioned");
    }

    // ============ Allow/Block List Tests ============

    function test_AddToAllowList_Success() public {
        vm.prank(kycAdmin);
        vm.expectEmit(true, false, false, false);
        emit AddedToAllowList(user);
        registry.addToAllowList(user);

        assertTrue(registry.allowList(user));
    }

    function test_AddToAllowList_RevertsOnSanctioned() public {
        vm.prank(sanctionsAdmin);
        registry.addToSanctions(user, KYCRegistry.SanctionsList.OFAC, bytes32(0), "Test");

        vm.prank(kycAdmin);
        vm.expectRevert(KYCRegistry.AccountSanctioned.selector);
        registry.addToAllowList(user);
    }

    function test_RemoveFromAllowList_Success() public {
        vm.prank(kycAdmin);
        registry.addToAllowList(user);

        vm.prank(kycAdmin);
        registry.removeFromAllowList(user);

        assertFalse(registry.allowList(user));
    }

    function test_AddToBlockList_Success() public {
        vm.prank(kycAdmin);
        vm.expectEmit(true, false, false, true);
        emit AddedToBlockList(user, "Suspicious activity");
        registry.addToBlockList(user, "Suspicious activity");

        assertTrue(registry.blockList(user));
    }

    function test_RemoveFromBlockList_Success() public {
        vm.prank(kycAdmin);
        registry.addToBlockList(user, "Test");

        vm.prank(kycAdmin);
        registry.removeFromBlockList(user);

        assertFalse(registry.blockList(user));
    }

    function test_RemoveFromBlockList_RevertsOnSanctioned() public {
        vm.prank(sanctionsAdmin);
        registry.addToSanctions(user, KYCRegistry.SanctionsList.OFAC, bytes32(0), "Test");

        vm.prank(kycAdmin);
        vm.expectRevert(KYCRegistry.AccountSanctioned.selector);
        registry.removeFromBlockList(user);
    }

    // ============ KYC Provider Tests ============

    function test_RegisterKycProvider_Success() public {
        address newProvider = makeAddr("newProvider");

        vm.prank(admin);
        registry.registerKycProvider(newProvider, "NewProvider", "EU");

        KYCRegistry.KycProvider memory provider = registry.getKycProvider(newProvider);
        assertEq(keccak256(bytes(provider.name)), keccak256(bytes("NewProvider")));
        assertEq(keccak256(bytes(provider.jurisdiction)), keccak256(bytes("EU")));
        assertTrue(provider.isActive);
        assertTrue(registry.hasRole(registry.KYC_PROVIDER_ROLE(), newProvider));
    }

    function test_RegisterKycProvider_RevertsOnDuplicate() public {
        vm.prank(admin);
        vm.expectRevert(KYCRegistry.ProviderAlreadyExists.selector);
        registry.registerKycProvider(kycProvider, "Duplicate", "US");
    }

    function test_RegisterKycProvider_RevertsOnEmptyName() public {
        address newProvider = makeAddr("newProvider");

        vm.prank(admin);
        vm.expectRevert(KYCRegistry.EmptyName.selector);
        registry.registerKycProvider(newProvider, "", "US");
    }

    function test_DeactivateKycProvider_Success() public {
        vm.prank(admin);
        registry.deactivateKycProvider(kycProvider);

        KYCRegistry.KycProvider memory provider = registry.getKycProvider(kycProvider);
        assertFalse(provider.isActive);
        assertFalse(registry.hasRole(registry.KYC_PROVIDER_ROLE(), kycProvider));
    }

    function test_DeactivateKycProvider_RevertsOnNotFound() public {
        vm.prank(admin);
        vm.expectRevert(KYCRegistry.ProviderNotFound.selector);
        registry.deactivateKycProvider(makeAddr("unknown"));
    }

    // ============ Configuration Tests ============

    function test_ConfigureJurisdiction_Success() public {
        vm.prank(admin);
        registry.configureJurisdiction("KR", 180 days, KYCRegistry.RiskLevel.MEDIUM);

        assertEq(registry.jurisdictionKycValidity("KR"), 180 days);
        assertEq(uint8(registry.jurisdictionDefaultRisk("KR")), uint8(KYCRegistry.RiskLevel.MEDIUM));
    }

    function test_SetDefaultKycValidity_Success() public {
        vm.prank(admin);
        registry.setDefaultKycValidity(180 days);

        assertEq(registry.defaultKycValidity(), 180 days);
    }

    function test_SetDefaultKycValidity_RevertsOnInvalid() public {
        vm.prank(admin);
        vm.expectRevert(KYCRegistry.InvalidValidity.selector);
        registry.setDefaultKycValidity(10 days); // Below minimum
    }

    // ============ View Function Tests ============

    function test_IsKycVerified() public {
        assertFalse(registry.isKycVerified(user));

        _verifyUser(user);
        assertTrue(registry.isKycVerified(user));

        vm.warp(block.timestamp + 366 days);
        assertFalse(registry.isKycVerified(user));
    }

    function test_CanTransact() public {
        (bool allowed, string memory reason) = registry.canTransact(user);
        assertFalse(allowed);
        assertEq(reason, "KYC not verified");

        _verifyUser(user);
        (allowed, reason) = registry.canTransact(user);
        assertTrue(allowed);
        assertEq(reason, "");
    }

    function test_CanTransact_AllowListBypassesKyc() public {
        vm.prank(kycAdmin);
        registry.addToAllowList(user);

        (bool allowed,) = registry.canTransact(user);
        assertTrue(allowed);
    }

    function test_CanTransact_BlockedAccount() public {
        vm.prank(kycAdmin);
        registry.addToBlockList(user, "Test");

        (bool allowed, string memory reason) = registry.canTransact(user);
        assertFalse(allowed);
        assertEq(reason, "Account is blocked");
    }

    function test_GetEffectiveRiskLevel() public {
        assertEq(uint8(registry.getEffectiveRiskLevel(user)), uint8(KYCRegistry.RiskLevel.LOW));

        vm.prank(sanctionsAdmin);
        registry.addToSanctions(user, KYCRegistry.SanctionsList.OFAC, bytes32(0), "Test");

        assertEq(uint8(registry.getEffectiveRiskLevel(user)), uint8(KYCRegistry.RiskLevel.PROHIBITED));
    }

    function test_IsKycExpiringSoon() public {
        _verifyUser(user);

        (bool expiring, uint256 daysRemaining) = registry.isKycExpiringSoon(user, 30);
        assertFalse(expiring);
        assertGt(daysRemaining, 30);

        vm.warp(block.timestamp + 340 days);
        (expiring, daysRemaining) = registry.isKycExpiringSoon(user, 30);
        assertTrue(expiring);
        assertLt(daysRemaining, 30);
    }

    // ============ Pause Tests ============

    function test_Pause() public {
        vm.prank(admin);
        registry.pause();

        assertTrue(registry.paused());

        vm.prank(kycAdmin);
        vm.expectRevert();
        registry.initiateKyc(user);
    }

    function test_Unpause() public {
        vm.prank(admin);
        registry.pause();

        vm.prank(admin);
        registry.unpause();

        assertFalse(registry.paused());
    }

    // ============ Helper Functions ============

    function _verifyUser(address account) internal {
        vm.prank(kycProvider);
        registry.verifyKyc(account, bytes32(0), bytes32(0), "US", KYCRegistry.RiskLevel.LOW, 0);
    }
}
