// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC5564Announcer} from "../../src/privacy/ERC5564Announcer.sol";

contract ERC5564AnnouncerTest is Test {
    ERC5564Announcer public announcer;

    address public sender;
    address public stealthAddress;

    bytes public ephemeralPubKey;
    bytes public metadata;

    event Announcement(
        uint256 indexed schemeId,
        address indexed stealthAddress,
        address indexed caller,
        bytes ephemeralPubKey,
        bytes metadata
    );
    event BatchAnnouncement(
        uint256 indexed schemeId,
        address indexed caller,
        uint256 count
    );
    event SchemeRegistered(uint256 indexed schemeId, string description);

    function setUp() public {
        sender = makeAddr("sender");
        stealthAddress = makeAddr("stealthAddress");

        announcer = new ERC5564Announcer();

        // Sample ephemeral public key (33 bytes compressed)
        ephemeralPubKey = hex"02abc123def456789012345678901234567890123456789012345678901234567890";
        // Sample metadata with view tag as first byte
        metadata = hex"ab1234567890";
    }

    // ============ Constructor Tests ============

    function test_Constructor_RegistersDefaultSchemes() public view {
        assertTrue(announcer.supportedSchemes(1)); // secp256k1
        assertTrue(announcer.supportedSchemes(2)); // secp256r1
    }

    function test_Constructor_InitializesCounters() public view {
        assertEq(announcer.totalAnnouncements(), 0);
        assertEq(announcer.announcementsByScheme(1), 0);
        assertEq(announcer.announcementsByScheme(2), 0);
    }

    // ============ Announce Tests ============

    function test_Announce_Success() public {
        vm.prank(sender);
        announcer.announce(1, stealthAddress, ephemeralPubKey, metadata);

        assertEq(announcer.totalAnnouncements(), 1);
        assertEq(announcer.announcementsByScheme(1), 1);
    }

    function test_Announce_EmitsEvent() public {
        vm.prank(sender);
        vm.expectEmit(true, true, true, true);
        emit Announcement(1, stealthAddress, sender, ephemeralPubKey, metadata);
        announcer.announce(1, stealthAddress, ephemeralPubKey, metadata);
    }

    function test_Announce_WithScheme2() public {
        vm.prank(sender);
        announcer.announce(2, stealthAddress, ephemeralPubKey, metadata);

        assertEq(announcer.totalAnnouncements(), 1);
        assertEq(announcer.announcementsByScheme(2), 1);
    }

    function test_Announce_WithUnsupportedScheme_WhenNotEnforced() public {
        // By default, scheme validation is not enforced
        assertFalse(announcer.enforceSchemeValidation());

        vm.prank(sender);
        announcer.announce(99, stealthAddress, ephemeralPubKey, metadata);

        assertEq(announcer.totalAnnouncements(), 1);
        assertEq(announcer.announcementsByScheme(99), 1);
    }

    function test_Announce_RevertsOnZeroStealthAddress() public {
        vm.prank(sender);
        vm.expectRevert(ERC5564Announcer.InvalidStealthAddress.selector);
        announcer.announce(1, address(0), ephemeralPubKey, metadata);
    }

    function test_Announce_RevertsOnEmptyEphemeralPubKey() public {
        vm.prank(sender);
        vm.expectRevert(ERC5564Announcer.InvalidEphemeralPubKey.selector);
        announcer.announce(1, stealthAddress, "", metadata);
    }

    function test_Announce_WithEmptyMetadata() public {
        vm.prank(sender);
        announcer.announce(1, stealthAddress, ephemeralPubKey, "");

        assertEq(announcer.totalAnnouncements(), 1);
    }

    function test_Announce_MultipleTimes() public {
        vm.startPrank(sender);
        announcer.announce(1, stealthAddress, ephemeralPubKey, metadata);
        announcer.announce(1, makeAddr("stealth2"), ephemeralPubKey, metadata);
        announcer.announce(2, makeAddr("stealth3"), ephemeralPubKey, metadata);
        vm.stopPrank();

        assertEq(announcer.totalAnnouncements(), 3);
        assertEq(announcer.announcementsByScheme(1), 2);
        assertEq(announcer.announcementsByScheme(2), 1);
    }

    // ============ AnnounceBatch Tests ============

    function test_AnnounceBatch_Success() public {
        address[] memory addresses = new address[](3);
        addresses[0] = makeAddr("stealth1");
        addresses[1] = makeAddr("stealth2");
        addresses[2] = makeAddr("stealth3");

        bytes[] memory keys = new bytes[](3);
        keys[0] = ephemeralPubKey;
        keys[1] = ephemeralPubKey;
        keys[2] = ephemeralPubKey;

        bytes[] memory metas = new bytes[](3);
        metas[0] = metadata;
        metas[1] = metadata;
        metas[2] = metadata;

        vm.prank(sender);
        announcer.announceBatch(1, addresses, keys, metas);

        assertEq(announcer.totalAnnouncements(), 3);
        assertEq(announcer.announcementsByScheme(1), 3);
    }

    function test_AnnounceBatch_EmitsEvents() public {
        address[] memory addresses = new address[](2);
        addresses[0] = makeAddr("stealth1");
        addresses[1] = makeAddr("stealth2");

        bytes[] memory keys = new bytes[](2);
        keys[0] = ephemeralPubKey;
        keys[1] = ephemeralPubKey;

        bytes[] memory metas = new bytes[](2);
        metas[0] = metadata;
        metas[1] = metadata;

        vm.prank(sender);
        vm.expectEmit(true, true, false, true);
        emit BatchAnnouncement(1, sender, 2);
        announcer.announceBatch(1, addresses, keys, metas);
    }

    function test_AnnounceBatch_RevertsOnArrayLengthMismatch() public {
        address[] memory addresses = new address[](2);
        addresses[0] = makeAddr("stealth1");
        addresses[1] = makeAddr("stealth2");

        bytes[] memory keys = new bytes[](1);
        keys[0] = ephemeralPubKey;

        bytes[] memory metas = new bytes[](2);
        metas[0] = metadata;
        metas[1] = metadata;

        vm.prank(sender);
        vm.expectRevert("Array length mismatch");
        announcer.announceBatch(1, addresses, keys, metas);
    }

    function test_AnnounceBatch_RevertsOnZeroAddressInBatch() public {
        address[] memory addresses = new address[](2);
        addresses[0] = makeAddr("stealth1");
        addresses[1] = address(0);

        bytes[] memory keys = new bytes[](2);
        keys[0] = ephemeralPubKey;
        keys[1] = ephemeralPubKey;

        bytes[] memory metas = new bytes[](2);
        metas[0] = metadata;
        metas[1] = metadata;

        vm.prank(sender);
        vm.expectRevert(ERC5564Announcer.InvalidStealthAddress.selector);
        announcer.announceBatch(1, addresses, keys, metas);
    }

    function test_AnnounceBatch_RevertsOnEmptyKeyInBatch() public {
        address[] memory addresses = new address[](2);
        addresses[0] = makeAddr("stealth1");
        addresses[1] = makeAddr("stealth2");

        bytes[] memory keys = new bytes[](2);
        keys[0] = ephemeralPubKey;
        keys[1] = "";

        bytes[] memory metas = new bytes[](2);
        metas[0] = metadata;
        metas[1] = metadata;

        vm.prank(sender);
        vm.expectRevert(ERC5564Announcer.InvalidEphemeralPubKey.selector);
        announcer.announceBatch(1, addresses, keys, metas);
    }

    // ============ AnnounceAndTransfer Tests ============

    function test_AnnounceAndTransfer_Success() public {
        vm.deal(sender, 10 ether);

        vm.prank(sender);
        announcer.announceAndTransfer{value: 1 ether}(1, stealthAddress, ephemeralPubKey, metadata);

        assertEq(stealthAddress.balance, 1 ether);
        assertEq(announcer.totalAnnouncements(), 1);
    }

    function test_AnnounceAndTransfer_WithZeroValue() public {
        vm.prank(sender);
        announcer.announceAndTransfer{value: 0}(1, stealthAddress, ephemeralPubKey, metadata);

        assertEq(stealthAddress.balance, 0);
        assertEq(announcer.totalAnnouncements(), 1);
    }

    function test_AnnounceAndTransfer_RevertsOnZeroAddress() public {
        vm.deal(sender, 1 ether);

        vm.prank(sender);
        vm.expectRevert(ERC5564Announcer.InvalidStealthAddress.selector);
        announcer.announceAndTransfer{value: 1 ether}(1, address(0), ephemeralPubKey, metadata);
    }

    function test_AnnounceAndTransfer_RevertsOnEmptyKey() public {
        vm.deal(sender, 1 ether);

        vm.prank(sender);
        vm.expectRevert(ERC5564Announcer.InvalidEphemeralPubKey.selector);
        announcer.announceAndTransfer{value: 1 ether}(1, stealthAddress, "", metadata);
    }

    // ============ View Function Tests ============

    function test_IsSchemeSupported() public view {
        assertTrue(announcer.isSchemeSupported(1));
        assertTrue(announcer.isSchemeSupported(2));
        assertFalse(announcer.isSchemeSupported(3));
    }

    function test_GetStats() public {
        vm.startPrank(sender);
        announcer.announce(1, stealthAddress, ephemeralPubKey, metadata);
        announcer.announce(1, makeAddr("s2"), ephemeralPubKey, metadata);
        announcer.announce(2, makeAddr("s3"), ephemeralPubKey, metadata);
        vm.stopPrank();

        (uint256 total, uint256 secp256k1Count, uint256 secp256r1Count) = announcer.getStats();
        assertEq(total, 3);
        assertEq(secp256k1Count, 2);
        assertEq(secp256r1Count, 1);
    }

    // ============ Helper Function Tests ============

    function test_GenerateViewTag() public view {
        // View tag is the first byte of the address (most significant 8 bits)
        address testAddr = 0xabCDEF1234567890ABcDEF1234567890aBCDeF12;
        bytes1 viewTag = announcer.generateViewTag(testAddr);
        assertEq(viewTag, bytes1(0xAB));
    }

    function test_EncodeMetadata() public view {
        bytes1 viewTag = bytes1(0xAB);
        bytes memory data = hex"123456";

        bytes memory encoded = announcer.encodeMetadata(viewTag, data);
        assertEq(encoded.length, 4);
        assertEq(encoded[0], viewTag);
    }
}
