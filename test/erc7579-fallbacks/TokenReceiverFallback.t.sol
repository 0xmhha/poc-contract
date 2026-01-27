// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TokenReceiverFallback } from "../../src/erc7579-fallbacks/TokenReceiverFallback.sol";
import { MockFallbackAccount, MockERC721, MockERC1155 } from "./mocks/MockFallbackAccount.sol";

contract TokenReceiverFallbackTest is Test {
    TokenReceiverFallback public fallbackModule;
    MockFallbackAccount public account;
    MockERC721 public erc721;
    MockERC1155 public erc1155;

    address public user;
    address public recipient;

    // Selectors
    bytes4 constant ERC721_RECEIVED = 0x15_0b7_a02;
    bytes4 constant ERC1155_RECEIVED = 0xf2_3a6_e61;
    bytes4 constant ERC1155_BATCH_RECEIVED = 0xbc_197_c81;

    function setUp() public {
        user = makeAddr("user");
        recipient = makeAddr("recipient");

        // Deploy contracts
        fallbackModule = new TokenReceiverFallback();
        account = new MockFallbackAccount();
        erc721 = new MockERC721("Test NFT", "TNFT");
        erc1155 = new MockERC1155();
    }

    /* //////////////////////////////////////////////////////////////
                            INSTALLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OnInstall_NoData() public {
        vm.prank(address(account));
        fallbackModule.onInstall("");

        assertTrue(fallbackModule.isInitialized(address(account)));

        TokenReceiverFallback.AccountConfig memory config = fallbackModule.getConfig(address(account));
        assertTrue(config.acceptAllTokens);
        assertFalse(config.logTransfers);
        assertTrue(config.isEnabled);
    }

    function test_OnInstall_WithConfig() public {
        bytes memory installData = abi.encode(false, true); // acceptAll=false, log=true

        vm.prank(address(account));
        fallbackModule.onInstall(installData);

        TokenReceiverFallback.AccountConfig memory config = fallbackModule.getConfig(address(account));
        assertFalse(config.acceptAllTokens);
        assertTrue(config.logTransfers);
    }

    function test_OnUninstall() public {
        _installModule();

        vm.prank(address(account));
        fallbackModule.onUninstall("");

        assertFalse(fallbackModule.isInitialized(address(account)));
    }

    function test_IsModuleType() public view {
        assertTrue(fallbackModule.isModuleType(3), "Should be MODULE_TYPE_FALLBACK (3)");
        assertFalse(fallbackModule.isModuleType(1), "Should not be validator");
        assertFalse(fallbackModule.isModuleType(2), "Should not be executor");
    }

    /* //////////////////////////////////////////////////////////////
                        ERC-721 RECEIVER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OnERC721Received() public {
        _installModuleWithLogging();

        // Mint NFT to user
        uint256 tokenId = erc721.mint(user);

        // Transfer to account (will trigger callback)
        vm.prank(user);
        erc721.safeTransferFrom(user, address(account), tokenId, "");

        // Verify ownership
        assertEq(erc721.ownerOf(tokenId), address(account));

        // Verify log
        assertEq(fallbackModule.getTransferLogLength(address(account)), 1);

        TokenReceiverFallback.TransferLog memory log = fallbackModule.getTransferLog(address(account), 0);
        assertEq(log.token, address(erc721));
        assertEq(log.from, user);
        assertEq(log.tokenId, tokenId);
        assertEq(log.amount, 1);
    }

    function test_OnERC721Received_BlacklistedToken() public {
        _installModuleWithLogging();

        // Blacklist the token
        vm.prank(address(account));
        fallbackModule.addToBlacklist(address(erc721));

        // Mint NFT to user
        uint256 tokenId = erc721.mint(user);

        // Transfer should revert
        vm.prank(user);
        vm.expectRevert();
        erc721.safeTransferFrom(user, address(account), tokenId, "");
    }

    function test_OnERC721Received_WhitelistRequired() public {
        // Install with acceptAllTokens = false
        bytes memory installData = abi.encode(false, true);
        vm.prank(address(account));
        fallbackModule.onInstall(installData);

        // Register fallback handler for ERC-721 callback
        account.registerFallbackHandler(address(fallbackModule), ERC721_RECEIVED);

        // Mint NFT to user
        uint256 tokenId = erc721.mint(user);

        // Transfer should revert (token not whitelisted)
        vm.prank(user);
        vm.expectRevert();
        erc721.safeTransferFrom(user, address(account), tokenId, "");

        // Whitelist the token
        vm.prank(address(account));
        fallbackModule.addToWhitelist(address(erc721));

        // Now it should work
        vm.prank(user);
        erc721.safeTransferFrom(user, address(account), tokenId, "");

        assertEq(erc721.ownerOf(tokenId), address(account));
    }

    /* //////////////////////////////////////////////////////////////
                        ERC-1155 RECEIVER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OnERC1155Received() public {
        _installModuleWithLogging();

        // Mint tokens to user
        erc1155.mint(user, 1, 100);

        // Set approval
        vm.prank(user);
        erc1155.setApprovalForAll(user, true);

        // Transfer to account
        vm.prank(user);
        erc1155.safeTransferFrom(user, address(account), 1, 50, "");

        // Verify balance
        assertEq(erc1155.balanceOf(address(account), 1), 50);

        // Verify log
        assertEq(fallbackModule.getTransferLogLength(address(account)), 1);

        TokenReceiverFallback.TransferLog memory log = fallbackModule.getTransferLog(address(account), 0);
        assertEq(log.token, address(erc1155));
        assertEq(log.tokenId, 1);
        assertEq(log.amount, 50);
    }

    function test_OnERC1155BatchReceived() public {
        _installModuleWithLogging();

        // Mint multiple tokens to user
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100;
        amounts[1] = 200;
        amounts[2] = 300;

        erc1155.mintBatch(user, ids, amounts);

        // Set approval
        vm.prank(user);
        erc1155.setApprovalForAll(user, true);

        // Batch transfer to account
        vm.prank(user);
        erc1155.safeBatchTransferFrom(user, address(account), ids, amounts, "");

        // Verify balances
        assertEq(erc1155.balanceOf(address(account), 1), 100);
        assertEq(erc1155.balanceOf(address(account), 2), 200);
        assertEq(erc1155.balanceOf(address(account), 3), 300);

        // Verify logs (3 entries for batch)
        assertEq(fallbackModule.getTransferLogLength(address(account)), 3);
    }

    /* //////////////////////////////////////////////////////////////
                        CONFIGURATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetConfig() public {
        _installModule();

        vm.prank(address(account));
        fallbackModule.setConfig(false, true);

        TokenReceiverFallback.AccountConfig memory config = fallbackModule.getConfig(address(account));
        assertFalse(config.acceptAllTokens);
        assertTrue(config.logTransfers);
    }

    function test_AddToWhitelist() public {
        _installModule();

        vm.prank(address(account));
        fallbackModule.addToWhitelist(address(erc721));

        assertTrue(fallbackModule.isWhitelisted(address(account), address(erc721)));
    }

    function test_RemoveFromWhitelist() public {
        _installModule();

        vm.startPrank(address(account));
        fallbackModule.addToWhitelist(address(erc721));
        fallbackModule.removeFromWhitelist(address(erc721));
        vm.stopPrank();

        assertFalse(fallbackModule.isWhitelisted(address(account), address(erc721)));
    }

    function test_AddToBlacklist() public {
        _installModule();

        vm.prank(address(account));
        fallbackModule.addToBlacklist(address(erc721));

        assertTrue(fallbackModule.isBlacklisted(address(account), address(erc721)));
    }

    function test_RemoveFromBlacklist() public {
        _installModule();

        vm.startPrank(address(account));
        fallbackModule.addToBlacklist(address(erc721));
        fallbackModule.removeFromBlacklist(address(erc721));
        vm.stopPrank();

        assertFalse(fallbackModule.isBlacklisted(address(account), address(erc721)));
    }

    function test_BatchUpdateWhitelist() public {
        _installModule();

        address[] memory tokens = new address[](2);
        tokens[0] = address(erc721);
        tokens[1] = address(erc1155);

        bool[] memory statuses = new bool[](2);
        statuses[0] = true;
        statuses[1] = true;

        vm.prank(address(account));
        fallbackModule.batchUpdateWhitelist(tokens, statuses);

        assertTrue(fallbackModule.isWhitelisted(address(account), address(erc721)));
        assertTrue(fallbackModule.isWhitelisted(address(account), address(erc1155)));
    }

    /* //////////////////////////////////////////////////////////////
                            VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WillAcceptToken_Enabled() public {
        _installModule();

        (bool willAccept, string memory reason) = fallbackModule.willAcceptToken(address(account), address(erc721));
        assertTrue(willAccept);
        assertEq(reason, "");
    }

    function test_WillAcceptToken_Blacklisted() public {
        _installModule();

        vm.prank(address(account));
        fallbackModule.addToBlacklist(address(erc721));

        (bool willAccept, string memory reason) = fallbackModule.willAcceptToken(address(account), address(erc721));
        assertFalse(willAccept);
        assertEq(reason, "Token is blacklisted");
    }

    function test_WillAcceptToken_NotWhitelisted() public {
        // Install with acceptAllTokens = false
        bytes memory installData = abi.encode(false, false);
        vm.prank(address(account));
        fallbackModule.onInstall(installData);

        (bool willAccept, string memory reason) = fallbackModule.willAcceptToken(address(account), address(erc721));
        assertFalse(willAccept);
        assertEq(reason, "Token not whitelisted");
    }

    function test_WillAcceptToken_NotEnabled() public {
        // Don't install module
        (bool willAccept, string memory reason) = fallbackModule.willAcceptToken(address(account), address(erc721));
        assertFalse(willAccept);
        assertEq(reason, "Module not enabled");
    }

    function test_GetTransferLogs() public {
        _installModuleWithLogging();

        // Create multiple transfers
        for (uint256 i = 0; i < 5; i++) {
            uint256 tokenId = erc721.mint(user);
            vm.prank(user);
            erc721.safeTransferFrom(user, address(account), tokenId, "");
        }

        // Get logs range
        TokenReceiverFallback.TransferLog[] memory logs = fallbackModule.getTransferLogs(address(account), 1, 4);
        assertEq(logs.length, 3);
        assertEq(logs[0].tokenId, 1);
        assertEq(logs[1].tokenId, 2);
        assertEq(logs[2].tokenId, 3);
    }

    function test_GetTransferLogs_OutOfBounds() public {
        _installModule();

        TokenReceiverFallback.TransferLog[] memory logs = fallbackModule.getTransferLogs(address(account), 10, 20);
        assertEq(logs.length, 0);
    }

    /* //////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _installModule() internal {
        vm.prank(address(account));
        fallbackModule.onInstall("");

        // Register fallback handlers for token callbacks
        account.registerFallbackHandler(address(fallbackModule), ERC721_RECEIVED);
        account.registerFallbackHandler(address(fallbackModule), ERC1155_RECEIVED);
        account.registerFallbackHandler(address(fallbackModule), ERC1155_BATCH_RECEIVED);
    }

    function _installModuleWithLogging() internal {
        bytes memory installData = abi.encode(true, true); // acceptAll=true, log=true
        vm.prank(address(account));
        fallbackModule.onInstall(installData);

        // Register fallback handlers for token callbacks
        account.registerFallbackHandler(address(fallbackModule), ERC721_RECEIVED);
        account.registerFallbackHandler(address(fallbackModule), ERC1155_RECEIVED);
        account.registerFallbackHandler(address(fallbackModule), ERC1155_BATCH_RECEIVED);
    }
}
