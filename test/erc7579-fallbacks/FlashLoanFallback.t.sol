// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FlashLoanFallback} from "../../src/erc7579-fallbacks/FlashLoanFallback.sol";
import {MockFallbackAccount, MockERC20, MockFlashLoanProvider} from "./mocks/MockFallbackAccount.sol";

contract FlashLoanFallbackTest is Test {
    FlashLoanFallback public fallbackModule;
    MockFallbackAccount public account;
    MockERC20 public token;
    MockFlashLoanProvider public flashLoanProvider;

    address public user;

    // Callback selectors
    bytes4 constant AAVE_EXECUTE_OPERATION = bytes4(keccak256("executeOperation(address[],uint256[],uint256[],address,bytes)"));
    bytes4 constant ERC3156_ON_FLASH_LOAN = bytes4(keccak256("onFlashLoan(address,address,uint256,uint256,bytes)"));

    function setUp() public {
        user = makeAddr("user");

        // Deploy contracts
        fallbackModule = new FlashLoanFallback();
        account = new MockFallbackAccount();
        token = new MockERC20("Test Token", "TEST");
        flashLoanProvider = new MockFlashLoanProvider();

        // Fund contracts
        token.mint(address(flashLoanProvider), 1000000 ether);
        token.mint(address(account), 10000 ether); // For repayment fees
    }

    /*//////////////////////////////////////////////////////////////
                            INSTALLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OnInstall_NoData() public {
        vm.prank(address(account));
        fallbackModule.onInstall("");

        assertTrue(fallbackModule.isInitialized(address(account)));

        FlashLoanFallback.AccountConfig memory config = fallbackModule.getConfig(address(account));
        assertTrue(config.requireWhitelistedProtocol);
        assertTrue(config.logFlashLoans);
        assertTrue(config.isEnabled);
    }

    function test_OnInstall_WithConfig() public {
        bytes memory installData = abi.encode(false, false); // No whitelist, no log

        vm.prank(address(account));
        fallbackModule.onInstall(installData);

        FlashLoanFallback.AccountConfig memory config = fallbackModule.getConfig(address(account));
        assertFalse(config.requireWhitelistedProtocol);
        assertFalse(config.logFlashLoans);
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

    /*//////////////////////////////////////////////////////////////
                        CONFIGURATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetConfig() public {
        _installModule();

        vm.prank(address(account));
        fallbackModule.setConfig(false, false);

        FlashLoanFallback.AccountConfig memory config = fallbackModule.getConfig(address(account));
        assertFalse(config.requireWhitelistedProtocol);
        assertFalse(config.logFlashLoans);
    }

    function test_AddToWhitelist() public {
        _installModule();

        vm.prank(address(account));
        fallbackModule.addToWhitelist(address(flashLoanProvider));

        assertTrue(fallbackModule.isWhitelisted(address(account), address(flashLoanProvider)));
    }

    function test_RemoveFromWhitelist() public {
        _installModule();

        vm.startPrank(address(account));
        fallbackModule.addToWhitelist(address(flashLoanProvider));
        fallbackModule.removeFromWhitelist(address(flashLoanProvider));
        vm.stopPrank();

        assertFalse(fallbackModule.isWhitelisted(address(account), address(flashLoanProvider)));
    }

    function test_BatchUpdateWhitelist() public {
        _installModule();

        address[] memory protocols = new address[](2);
        protocols[0] = address(flashLoanProvider);
        protocols[1] = makeAddr("protocol2");

        bool[] memory statuses = new bool[](2);
        statuses[0] = true;
        statuses[1] = true;

        vm.prank(address(account));
        fallbackModule.batchUpdateWhitelist(protocols, statuses);

        assertTrue(fallbackModule.isWhitelisted(address(account), address(flashLoanProvider)));
        assertTrue(fallbackModule.isWhitelisted(address(account), protocols[1]));
    }

    /*//////////////////////////////////////////////////////////////
                        AAVE FLASH LOAN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ExecuteOperation_Success() public {
        _installModuleWithWhitelist();

        // Prepare flash loan
        address[] memory assets = new address[](1);
        assets[0] = address(token);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000 ether;

        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;

        // Approve repayment
        vm.prank(address(account));
        token.approve(address(flashLoanProvider), type(uint256).max);

        // Execute flash loan
        flashLoanProvider.flashLoan(
            address(account),
            assets,
            amounts,
            modes,
            address(account),
            "",
            0
        );

        // Verify log
        assertEq(fallbackModule.getFlashLoanLogLength(address(account)), 1);

        FlashLoanFallback.FlashLoanLog memory log = fallbackModule.getFlashLoanLog(address(account), 0);
        assertEq(log.protocol, address(flashLoanProvider));
        assertEq(log.tokens[0], address(token));
        assertEq(log.amounts[0], 1000 ether);
        assertTrue(log.success);
    }

    function test_ExecuteOperation_ProtocolNotWhitelisted() public {
        _installModule(); // Default requires whitelist

        address[] memory assets = new address[](1);
        assets[0] = address(token);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000 ether;

        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;

        // Should revert because provider not whitelisted
        vm.expectRevert();
        flashLoanProvider.flashLoan(
            address(account),
            assets,
            amounts,
            modes,
            address(account),
            "",
            0
        );
    }

    function test_ExecuteOperation_NoWhitelistRequired() public {
        // Install without whitelist requirement
        bytes memory installData = abi.encode(false, true);
        vm.prank(address(account));
        fallbackModule.onInstall(installData);

        // Register fallback handler for the callback
        account.registerFallbackHandler(address(fallbackModule), AAVE_EXECUTE_OPERATION);

        address[] memory assets = new address[](1);
        assets[0] = address(token);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000 ether;

        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;

        // Approve repayment
        vm.prank(address(account));
        token.approve(address(flashLoanProvider), type(uint256).max);

        // Should work without whitelist
        flashLoanProvider.flashLoan(
            address(account),
            assets,
            amounts,
            modes,
            address(account),
            "",
            0
        );

        assertEq(fallbackModule.getFlashLoanLogLength(address(account)), 1);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-3156 FLASH LOAN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OnFlashLoan_Success() public {
        _installModuleWithWhitelist();

        // Approve repayment
        vm.prank(address(account));
        token.approve(address(flashLoanProvider), type(uint256).max);

        // Execute ERC-3156 flash loan
        flashLoanProvider.flashLoanERC3156(
            address(account),
            address(token),
            500 ether,
            ""
        );

        // Verify log
        assertEq(fallbackModule.getFlashLoanLogLength(address(account)), 1);

        FlashLoanFallback.FlashLoanLog memory log = fallbackModule.getFlashLoanLog(address(account), 0);
        assertEq(log.protocol, address(flashLoanProvider));
        assertEq(log.tokens[0], address(token));
        assertEq(log.amounts[0], 500 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        CALLBACK REGISTRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RegisterCallback() public {
        _installModule();

        bytes32 callbackId = keccak256("testCallback");

        vm.prank(address(account));
        fallbackModule.registerCallback(
            callbackId,
            address(token),
            abi.encodeWithSignature("approve(address,uint256)", address(flashLoanProvider), 1000 ether),
            false
        );

        FlashLoanFallback.FlashLoanCallback memory callback = fallbackModule.getCallback(address(account), callbackId);
        assertEq(callback.target, address(token));
        assertFalse(callback.executeAfterRepay);
    }

    function test_ClearCallback() public {
        _installModule();

        bytes32 callbackId = keccak256("testCallback");

        vm.startPrank(address(account));
        fallbackModule.registerCallback(
            callbackId,
            address(token),
            "",
            false
        );
        fallbackModule.clearCallback(callbackId);
        vm.stopPrank();

        FlashLoanFallback.FlashLoanCallback memory callback = fallbackModule.getCallback(address(account), callbackId);
        assertEq(callback.target, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WillAcceptProtocol_Enabled() public {
        _installModuleWithWhitelist();

        (bool willAccept, string memory reason) = fallbackModule.willAcceptProtocol(address(account), address(flashLoanProvider));
        assertTrue(willAccept);
        assertEq(reason, "");
    }

    function test_WillAcceptProtocol_NotWhitelisted() public {
        _installModule();

        (bool willAccept, string memory reason) = fallbackModule.willAcceptProtocol(address(account), address(flashLoanProvider));
        assertFalse(willAccept);
        assertEq(reason, "Protocol not whitelisted");
    }

    function test_WillAcceptProtocol_NotEnabled() public {
        // Don't install module
        (bool willAccept, string memory reason) = fallbackModule.willAcceptProtocol(address(account), address(flashLoanProvider));
        assertFalse(willAccept);
        assertEq(reason, "Module not enabled");
    }

    function test_GetFlashLoanLogs() public {
        _installModuleWithWhitelist();

        // Approve repayment
        vm.prank(address(account));
        token.approve(address(flashLoanProvider), type(uint256).max);

        // Execute multiple flash loans
        for (uint256 i = 0; i < 5; i++) {
            address[] memory assets = new address[](1);
            assets[0] = address(token);

            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 100 ether * (i + 1);

            uint256[] memory modes = new uint256[](1);
            modes[0] = 0;

            flashLoanProvider.flashLoan(
                address(account),
                assets,
                amounts,
                modes,
                address(account),
                "",
                0
            );
        }

        // Get logs range
        FlashLoanFallback.FlashLoanLog[] memory logs = fallbackModule.getFlashLoanLogs(address(account), 1, 4);
        assertEq(logs.length, 3);
        assertEq(logs[0].amounts[0], 200 ether);
        assertEq(logs[1].amounts[0], 300 ether);
        assertEq(logs[2].amounts[0], 400 ether);
    }

    function test_GetFlashLoanLogs_OutOfBounds() public {
        _installModule();

        FlashLoanFallback.FlashLoanLog[] memory logs = fallbackModule.getFlashLoanLogs(address(account), 10, 20);
        assertEq(logs.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _installModule() internal {
        vm.prank(address(account));
        fallbackModule.onInstall("");

        // Register fallback handlers for flash loan callbacks
        account.registerFallbackHandler(address(fallbackModule), AAVE_EXECUTE_OPERATION);
        account.registerFallbackHandler(address(fallbackModule), ERC3156_ON_FLASH_LOAN);
    }

    function _installModuleWithWhitelist() internal {
        vm.prank(address(account));
        fallbackModule.onInstall("");

        // Register fallback handlers for flash loan callbacks
        account.registerFallbackHandler(address(fallbackModule), AAVE_EXECUTE_OPERATION);
        account.registerFallbackHandler(address(fallbackModule), ERC3156_ON_FLASH_LOAN);

        // Whitelist the flash loan provider
        vm.prank(address(account));
        fallbackModule.addToWhitelist(address(flashLoanProvider));
    }
}
