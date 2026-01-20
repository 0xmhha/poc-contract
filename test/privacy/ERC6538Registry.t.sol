// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC6538Registry} from "../../src/privacy/ERC6538Registry.sol";

contract ERC6538RegistryTest is Test {
    ERC6538Registry public registry;

    address public registrant;
    uint256 public registrantKey;

    bytes public stealthMetaAddress;

    event StealthMetaAddressSet(
        address indexed registrant,
        uint256 indexed schemeId,
        bytes stealthMetaAddress
    );
    event StealthMetaAddressRemoved(
        address indexed registrant,
        uint256 indexed schemeId
    );
    event NonceIncremented(address indexed registrant, uint256 newNonce);

    function setUp() public {
        registry = new ERC6538Registry();

        (registrant, registrantKey) = makeAddrAndKey("registrant");

        // Sample stealth meta-address (66 bytes = spending key + viewing key)
        stealthMetaAddress = hex"02abc123def456789012345678901234567890123456789012345678901234567890"
                             hex"03def456abc789012345678901234567890123456789012345678901234567890123";
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertNotEq(registry.DOMAIN_SEPARATOR(), bytes32(0));
        assertNotEq(registry.ERC6538REGISTRY_ENTRY_TYPE_HASH(), bytes32(0));
    }

    // ============ RegisterKeys Tests ============

    function test_RegisterKeys_Success() public {
        vm.prank(registrant);
        vm.expectEmit(true, true, false, true);
        emit StealthMetaAddressSet(registrant, 1, stealthMetaAddress);
        registry.registerKeys(1, stealthMetaAddress);

        bytes memory stored = registry.stealthMetaAddressOf(registrant, 1);
        assertEq(keccak256(stored), keccak256(stealthMetaAddress));
    }

    function test_RegisterKeys_MultipleSchemes() public {
        bytes memory addr1 = stealthMetaAddress;
        bytes memory addr2 = hex"04abc123def456789012345678901234567890123456789012345678901234567890"
                             hex"05def456abc789012345678901234567890123456789012345678901234567890123";

        vm.startPrank(registrant);
        registry.registerKeys(1, addr1);
        registry.registerKeys(2, addr2);
        vm.stopPrank();

        assertEq(keccak256(registry.stealthMetaAddressOf(registrant, 1)), keccak256(addr1));
        assertEq(keccak256(registry.stealthMetaAddressOf(registrant, 2)), keccak256(addr2));
    }

    function test_RegisterKeys_UpdateExisting() public {
        bytes memory newAddress = hex"05aaa123def456789012345678901234567890123456789012345678901234567890"
                                  hex"06bbb456abc789012345678901234567890123456789012345678901234567890123";

        vm.startPrank(registrant);
        registry.registerKeys(1, stealthMetaAddress);
        registry.registerKeys(1, newAddress);
        vm.stopPrank();

        assertEq(keccak256(registry.stealthMetaAddressOf(registrant, 1)), keccak256(newAddress));
    }

    function test_RegisterKeys_RevertsOnEmptyAddress() public {
        vm.prank(registrant);
        vm.expectRevert(ERC6538Registry.InvalidStealthMetaAddress.selector);
        registry.registerKeys(1, "");
    }

    // ============ RegisterKeysOnBehalf Tests ============

    function test_RegisterKeysOnBehalf_Success() public {
        // Build EIP-712 digest
        bytes32 structHash = keccak256(
            abi.encode(
                registry.ERC6538REGISTRY_ENTRY_TYPE_HASH(),
                uint256(1),
                keccak256(stealthMetaAddress),
                registry.nonceOf(registrant)
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash)
        );

        // Sign with registrant's key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(registrantKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Register on behalf
        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        registry.registerKeysOnBehalf(registrant, 1, signature, stealthMetaAddress);

        assertEq(keccak256(registry.stealthMetaAddressOf(registrant, 1)), keccak256(stealthMetaAddress));
        assertEq(registry.nonceOf(registrant), 1);
    }

    function test_RegisterKeysOnBehalf_RevertsOnInvalidSignature() public {
        // Create invalid signature
        bytes memory invalidSignature = new bytes(65);

        vm.expectRevert(); // ERC6538Registry__InvalidSignature
        registry.registerKeysOnBehalf(registrant, 1, invalidSignature, stealthMetaAddress);
    }

    function test_RegisterKeysOnBehalf_RevertsOnReplay() public {
        // Build EIP-712 digest
        bytes32 structHash = keccak256(
            abi.encode(
                registry.ERC6538REGISTRY_ENTRY_TYPE_HASH(),
                uint256(1),
                keccak256(stealthMetaAddress),
                registry.nonceOf(registrant)
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", registry.DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(registrantKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // First registration succeeds
        registry.registerKeysOnBehalf(registrant, 1, signature, stealthMetaAddress);

        // Replay fails (nonce incremented)
        vm.expectRevert(); // ERC6538Registry__InvalidSignature
        registry.registerKeysOnBehalf(registrant, 1, signature, stealthMetaAddress);
    }

    function test_RegisterKeysOnBehalf_RevertsOnEmptyAddress() public {
        bytes memory signature = new bytes(65);

        vm.expectRevert(ERC6538Registry.InvalidStealthMetaAddress.selector);
        registry.registerKeysOnBehalf(registrant, 1, signature, "");
    }

    // ============ RemoveKeys Tests ============

    function test_RemoveKeys_Success() public {
        vm.startPrank(registrant);
        registry.registerKeys(1, stealthMetaAddress);

        vm.expectEmit(true, true, false, false);
        emit StealthMetaAddressRemoved(registrant, 1);
        registry.removeKeys(1);
        vm.stopPrank();

        assertEq(registry.stealthMetaAddressOf(registrant, 1).length, 0);
    }

    function test_RemoveKeys_RevertsOnNotRegistered() public {
        vm.prank(registrant);
        vm.expectRevert(ERC6538Registry.KeysNotRegistered.selector);
        registry.removeKeys(1);
    }

    // ============ IncrementNonce Tests ============

    function test_IncrementNonce_Success() public {
        assertEq(registry.nonceOf(registrant), 0);

        vm.prank(registrant);
        vm.expectEmit(true, false, false, true);
        emit NonceIncremented(registrant, 1);
        registry.incrementNonce();

        assertEq(registry.nonceOf(registrant), 1);
    }

    function test_IncrementNonce_MultipleTimes() public {
        vm.startPrank(registrant);
        registry.incrementNonce();
        registry.incrementNonce();
        registry.incrementNonce();
        vm.stopPrank();

        assertEq(registry.nonceOf(registrant), 3);
    }

    // ============ View Function Tests ============

    function test_HasRegisteredKeys() public {
        assertFalse(registry.hasRegisteredKeys(registrant, 1));

        vm.prank(registrant);
        registry.registerKeys(1, stealthMetaAddress);

        assertTrue(registry.hasRegisteredKeys(registrant, 1));
        assertFalse(registry.hasRegisteredKeys(registrant, 2));
    }

    function test_GetStealthMetaAddress_Success() public {
        vm.prank(registrant);
        registry.registerKeys(1, stealthMetaAddress);

        bytes memory retrieved = registry.getStealthMetaAddress(registrant, 1);
        assertEq(keccak256(retrieved), keccak256(stealthMetaAddress));
    }

    function test_GetStealthMetaAddress_RevertsOnNotRegistered() public {
        vm.expectRevert(ERC6538Registry.KeysNotRegistered.selector);
        registry.getStealthMetaAddress(registrant, 1);
    }

    function test_ParseStealthMetaAddress() public view {
        (bytes memory spendingKey, bytes memory viewingKey) = registry.parseStealthMetaAddress(stealthMetaAddress);

        assertEq(spendingKey.length, 33);
        assertEq(viewingKey.length, 33);
    }

    function test_ParseStealthMetaAddress_RevertsOnInvalidLength() public {
        bytes memory shortAddress = hex"0102030405";

        vm.expectRevert("Invalid stealth meta-address length");
        registry.parseStealthMetaAddress(shortAddress);
    }

    function test_DOMAIN_SEPARATOR() public view {
        bytes32 separator = registry.DOMAIN_SEPARATOR();
        assertNotEq(separator, bytes32(0));
    }

    // ============ Cross-Chain Fork Test ============

    function test_DOMAIN_SEPARATOR_RecomputesOnFork() public {
        bytes32 originalSeparator = registry.DOMAIN_SEPARATOR();

        // Simulate chain fork by changing chainId
        vm.chainId(999);

        bytes32 newSeparator = registry.DOMAIN_SEPARATOR();
        assertNotEq(newSeparator, originalSeparator);
    }
}
