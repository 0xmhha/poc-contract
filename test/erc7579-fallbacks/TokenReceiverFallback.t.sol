// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TokenReceiverFallback } from "../../src/erc7579-fallbacks/TokenReceiverFallback.sol";
import { MockFallbackAccount } from "./mocks/MockFallbackAccount.sol";

contract TokenReceiverFallbackTest is Test {
    TokenReceiverFallback public fallbackModule;
    MockFallbackAccount public account;

    address public user;
    address public recipient;

    // ERC-777 tokensReceived selector
    bytes4 constant ERC777_TOKENS_RECEIVED = 0x00_23d_e29;

    function setUp() public {
        user = makeAddr("user");
        recipient = makeAddr("recipient");

        // Deploy contracts
        fallbackModule = new TokenReceiverFallback();
        account = new MockFallbackAccount();
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

        address tokenA = makeAddr("tokenA");
        vm.prank(address(account));
        fallbackModule.addToWhitelist(tokenA);

        assertTrue(fallbackModule.isWhitelisted(address(account), tokenA));
    }

    function test_RemoveFromWhitelist() public {
        _installModule();

        address tokenA = makeAddr("tokenA");
        vm.startPrank(address(account));
        fallbackModule.addToWhitelist(tokenA);
        fallbackModule.removeFromWhitelist(tokenA);
        vm.stopPrank();

        assertFalse(fallbackModule.isWhitelisted(address(account), tokenA));
    }

    function test_AddToBlacklist() public {
        _installModule();

        address tokenA = makeAddr("tokenA");
        vm.prank(address(account));
        fallbackModule.addToBlacklist(tokenA);

        assertTrue(fallbackModule.isBlacklisted(address(account), tokenA));
    }

    function test_RemoveFromBlacklist() public {
        _installModule();

        address tokenA = makeAddr("tokenA");
        vm.startPrank(address(account));
        fallbackModule.addToBlacklist(tokenA);
        fallbackModule.removeFromBlacklist(tokenA);
        vm.stopPrank();

        assertFalse(fallbackModule.isBlacklisted(address(account), tokenA));
    }

    function test_BatchUpdateWhitelist() public {
        _installModule();

        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");

        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;

        bool[] memory statuses = new bool[](2);
        statuses[0] = true;
        statuses[1] = true;

        vm.prank(address(account));
        fallbackModule.batchUpdateWhitelist(tokens, statuses);

        assertTrue(fallbackModule.isWhitelisted(address(account), tokenA));
        assertTrue(fallbackModule.isWhitelisted(address(account), tokenB));
    }

    /* //////////////////////////////////////////////////////////////
                            VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WillAcceptToken_Enabled() public {
        _installModule();

        address tokenA = makeAddr("tokenA");
        (bool willAccept, string memory reason) = fallbackModule.willAcceptToken(address(account), tokenA);
        assertTrue(willAccept);
        assertEq(reason, "");
    }

    function test_WillAcceptToken_Blacklisted() public {
        _installModule();

        address tokenA = makeAddr("tokenA");
        vm.prank(address(account));
        fallbackModule.addToBlacklist(tokenA);

        (bool willAccept, string memory reason) = fallbackModule.willAcceptToken(address(account), tokenA);
        assertFalse(willAccept);
        assertEq(reason, "Token is blacklisted");
    }

    function test_WillAcceptToken_NotWhitelisted() public {
        // Install with acceptAllTokens = false
        bytes memory installData = abi.encode(false, false);
        vm.prank(address(account));
        fallbackModule.onInstall(installData);

        address tokenA = makeAddr("tokenA");
        (bool willAccept, string memory reason) = fallbackModule.willAcceptToken(address(account), tokenA);
        assertFalse(willAccept);
        assertEq(reason, "Token not whitelisted");
    }

    function test_WillAcceptToken_NotEnabled() public {
        // Don't install module
        address tokenA = makeAddr("tokenA");
        (bool willAccept, string memory reason) = fallbackModule.willAcceptToken(address(account), tokenA);
        assertFalse(willAccept);
        assertEq(reason, "Module not enabled");
    }

    function test_GetTransferLogs() public {
        _installModuleWithLogging();

        address mockToken = makeAddr("erc777Token");

        // Simulate 5 ERC-777 tokensReceived calls through the account's fallback
        for (uint256 i = 0; i < 5; i++) {
            // tokensReceived(operator, from, to, amount, userData, operatorData)
            bytes memory callData = abi.encodeWithSelector(
                ERC777_TOKENS_RECEIVED, address(0), user, address(account), (i + 1) * 100, bytes(""), bytes("")
            );
            // Call from mock token → account's fallback() → TokenReceiverFallback.tokensReceived()
            vm.prank(mockToken);
            (bool success,) = address(account).call(callData);
            assertTrue(success, "tokensReceived call should succeed");
        }

        // Get logs range
        TokenReceiverFallback.TransferLog[] memory logs = fallbackModule.getTransferLogs(address(account), 1, 4);
        assertEq(logs.length, 3);
        assertEq(logs[0].amount, 200);
        assertEq(logs[1].amount, 300);
        assertEq(logs[2].amount, 400);
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

        // Register fallback handler for ERC-777 callback
        account.registerFallbackHandler(address(fallbackModule), ERC777_TOKENS_RECEIVED);
    }

    function _installModuleWithLogging() internal {
        bytes memory installData = abi.encode(true, true); // acceptAll=true, log=true
        vm.prank(address(account));
        fallbackModule.onInstall(installData);

        // Register fallback handler for ERC-777 callback
        account.registerFallbackHandler(address(fallbackModule), ERC777_TOKENS_RECEIVED);
    }
}
