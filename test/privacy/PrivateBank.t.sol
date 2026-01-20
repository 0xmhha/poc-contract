// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PrivateBank} from "../../src/privacy/PrivateBank.sol";
import {ERC5564Announcer} from "../../src/privacy/ERC5564Announcer.sol";
import {ERC6538Registry} from "../../src/privacy/ERC6538Registry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PrivateBankTest is Test {
    PrivateBank public bank;
    ERC5564Announcer public announcer;
    ERC6538Registry public registry;
    MockERC20 public token;

    address public owner;
    address public depositor;
    address public stealthAddress;

    bytes public ephemeralPubKey;
    bytes public metadata;

    event NativeDeposit(
        address indexed stealthAddress,
        address indexed depositor,
        uint256 amount,
        uint256 indexed schemeId
    );
    event TokenDeposit(
        address indexed stealthAddress,
        address indexed token,
        address indexed depositor,
        uint256 amount,
        uint256 schemeId
    );
    event Withdrawal(
        address indexed stealthAddress,
        address indexed recipient,
        address token,
        uint256 amount
    );
    event TokenWhitelistUpdated(address indexed token, bool supported);
    event DepositLimitUpdated(uint256 newLimit);
    event DailyLimitUpdated(uint256 newLimit);

    function setUp() public {
        owner = makeAddr("owner");
        depositor = makeAddr("depositor");
        stealthAddress = makeAddr("stealthAddress");

        vm.startPrank(owner);
        announcer = new ERC5564Announcer();
        registry = new ERC6538Registry();
        bank = new PrivateBank(address(announcer), address(registry));
        token = new MockERC20();

        // Add token to whitelist
        bank.setTokenSupport(address(token), true);
        vm.stopPrank();

        // Setup depositor
        vm.deal(depositor, 100 ether);
        vm.prank(owner);
        token.mint(depositor, 1000 ether);

        ephemeralPubKey = hex"02abc123def456789012345678901234567890123456789012345678901234567890";
        metadata = hex"ab1234567890";
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertEq(address(bank.ANNOUNCER()), address(announcer));
        assertEq(address(bank.REGISTRY()), address(registry));
        assertEq(bank.owner(), owner);
    }

    function test_Constructor_RevertsOnZeroAnnouncer() public {
        vm.expectRevert(PrivateBank.ZeroAddress.selector);
        new PrivateBank(address(0), address(registry));
    }

    function test_Constructor_RevertsOnZeroRegistry() public {
        vm.expectRevert(PrivateBank.ZeroAddress.selector);
        new PrivateBank(address(announcer), address(0));
    }

    // ============ DepositNative Tests ============

    function test_DepositNative_Success() public {
        vm.prank(depositor);
        vm.expectEmit(true, true, true, true);
        emit NativeDeposit(stealthAddress, depositor, 1 ether, 1);
        bank.depositNative{value: 1 ether}(1, stealthAddress, ephemeralPubKey, metadata);

        assertEq(bank.nativeBalances(stealthAddress), 1 ether);
        assertEq(bank.totalNativeDeposits(), 1 ether);
    }

    function test_DepositNative_MultipleDeposits() public {
        vm.startPrank(depositor);
        bank.depositNative{value: 1 ether}(1, stealthAddress, ephemeralPubKey, metadata);
        bank.depositNative{value: 2 ether}(1, stealthAddress, ephemeralPubKey, metadata);
        vm.stopPrank();

        assertEq(bank.nativeBalances(stealthAddress), 3 ether);
        assertEq(bank.totalNativeDeposits(), 3 ether);
    }

    function test_DepositNative_RevertsOnZeroAddress() public {
        vm.prank(depositor);
        vm.expectRevert(PrivateBank.ZeroAddress.selector);
        bank.depositNative{value: 1 ether}(1, address(0), ephemeralPubKey, metadata);
    }

    function test_DepositNative_RevertsOnZeroAmount() public {
        vm.prank(depositor);
        vm.expectRevert(PrivateBank.ZeroAmount.selector);
        bank.depositNative{value: 0}(1, stealthAddress, ephemeralPubKey, metadata);
    }

    function test_DepositNative_RevertsOnEmptyEphemeralKey() public {
        vm.prank(depositor);
        vm.expectRevert(PrivateBank.InvalidEphemeralPubKey.selector);
        bank.depositNative{value: 1 ether}(1, stealthAddress, "", metadata);
    }

    // ============ DepositToken Tests ============

    function test_DepositToken_Success() public {
        vm.startPrank(depositor);
        token.approve(address(bank), 100 ether);

        vm.expectEmit(true, true, true, true);
        emit TokenDeposit(stealthAddress, address(token), depositor, 100 ether, 1);
        bank.depositToken(address(token), 100 ether, 1, stealthAddress, ephemeralPubKey, metadata);
        vm.stopPrank();

        assertEq(bank.tokenBalances(stealthAddress, address(token)), 100 ether);
        assertEq(bank.totalTokenDeposits(address(token)), 100 ether);
    }

    function test_DepositToken_RevertsOnUnsupportedToken() public {
        MockERC20 unsupportedToken = new MockERC20();

        vm.startPrank(depositor);
        unsupportedToken.approve(address(bank), 100 ether);

        vm.expectRevert(PrivateBank.TokenNotSupported.selector);
        bank.depositToken(address(unsupportedToken), 100 ether, 1, stealthAddress, ephemeralPubKey, metadata);
        vm.stopPrank();
    }

    function test_DepositToken_RevertsOnZeroAmount() public {
        vm.prank(depositor);
        vm.expectRevert(PrivateBank.ZeroAmount.selector);
        bank.depositToken(address(token), 0, 1, stealthAddress, ephemeralPubKey, metadata);
    }

    // ============ WithdrawNative Tests ============

    function test_WithdrawNative_Success() public {
        // Deposit first
        vm.prank(depositor);
        bank.depositNative{value: 5 ether}(1, stealthAddress, ephemeralPubKey, metadata);

        uint256 balanceBefore = stealthAddress.balance;

        // Withdraw as stealth address owner
        vm.prank(stealthAddress);
        vm.expectEmit(true, true, false, true);
        emit Withdrawal(stealthAddress, stealthAddress, address(0), 3 ether);
        bank.withdrawNative(3 ether);

        assertEq(bank.nativeBalances(stealthAddress), 2 ether);
        assertEq(stealthAddress.balance, balanceBefore + 3 ether);
    }

    function test_WithdrawNative_RevertsOnZeroAmount() public {
        vm.prank(stealthAddress);
        vm.expectRevert(PrivateBank.ZeroAmount.selector);
        bank.withdrawNative(0);
    }

    function test_WithdrawNative_RevertsOnInsufficientBalance() public {
        vm.prank(stealthAddress);
        vm.expectRevert(PrivateBank.InsufficientBalance.selector);
        bank.withdrawNative(1 ether);
    }

    // ============ WithdrawNativeTo Tests ============

    function test_WithdrawNativeTo_Success() public {
        vm.prank(depositor);
        bank.depositNative{value: 5 ether}(1, stealthAddress, ephemeralPubKey, metadata);

        address recipient = makeAddr("recipient");
        uint256 balanceBefore = recipient.balance;

        vm.prank(stealthAddress);
        bank.withdrawNativeTo(recipient, 3 ether);

        assertEq(bank.nativeBalances(stealthAddress), 2 ether);
        assertEq(recipient.balance, balanceBefore + 3 ether);
    }

    function test_WithdrawNativeTo_RevertsOnZeroRecipient() public {
        vm.prank(depositor);
        bank.depositNative{value: 1 ether}(1, stealthAddress, ephemeralPubKey, metadata);

        vm.prank(stealthAddress);
        vm.expectRevert(PrivateBank.ZeroAddress.selector);
        bank.withdrawNativeTo(address(0), 1 ether);
    }

    // ============ WithdrawToken Tests ============

    function test_WithdrawToken_Success() public {
        vm.startPrank(depositor);
        token.approve(address(bank), 100 ether);
        bank.depositToken(address(token), 100 ether, 1, stealthAddress, ephemeralPubKey, metadata);
        vm.stopPrank();

        uint256 balanceBefore = token.balanceOf(stealthAddress);

        vm.prank(stealthAddress);
        bank.withdrawToken(address(token), 50 ether);

        assertEq(bank.tokenBalances(stealthAddress, address(token)), 50 ether);
        assertEq(token.balanceOf(stealthAddress), balanceBefore + 50 ether);
    }

    function test_WithdrawToken_RevertsOnInsufficientBalance() public {
        vm.prank(stealthAddress);
        vm.expectRevert(PrivateBank.InsufficientBalance.selector);
        bank.withdrawToken(address(token), 1 ether);
    }

    // ============ WithdrawTokenTo Tests ============

    function test_WithdrawTokenTo_Success() public {
        vm.startPrank(depositor);
        token.approve(address(bank), 100 ether);
        bank.depositToken(address(token), 100 ether, 1, stealthAddress, ephemeralPubKey, metadata);
        vm.stopPrank();

        address recipient = makeAddr("recipient");

        vm.prank(stealthAddress);
        bank.withdrawTokenTo(address(token), recipient, 50 ether);

        assertEq(token.balanceOf(recipient), 50 ether);
    }

    // ============ WithdrawAll Tests ============

    function test_WithdrawAll_Success() public {
        // Deposit native and tokens
        vm.prank(depositor);
        bank.depositNative{value: 5 ether}(1, stealthAddress, ephemeralPubKey, metadata);

        vm.startPrank(depositor);
        token.approve(address(bank), 100 ether);
        bank.depositToken(address(token), 100 ether, 1, stealthAddress, ephemeralPubKey, metadata);
        vm.stopPrank();

        address recipient = makeAddr("recipient");
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);

        vm.prank(stealthAddress);
        bank.withdrawAll(tokens, recipient);

        assertEq(bank.nativeBalances(stealthAddress), 0);
        assertEq(bank.tokenBalances(stealthAddress, address(token)), 0);
        assertEq(recipient.balance, 5 ether);
        assertEq(token.balanceOf(recipient), 100 ether);
    }

    function test_WithdrawAll_RevertsOnZeroRecipient() public {
        address[] memory tokens = new address[](0);

        vm.prank(stealthAddress);
        vm.expectRevert(PrivateBank.ZeroAddress.selector);
        bank.withdrawAll(tokens, address(0));
    }

    // ============ Admin Function Tests ============

    function test_SetTokenSupport_Add() public {
        MockERC20 newToken = new MockERC20();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit TokenWhitelistUpdated(address(newToken), true);
        bank.setTokenSupport(address(newToken), true);

        assertTrue(bank.supportedTokens(address(newToken)));
    }

    function test_SetTokenSupport_Remove() public {
        vm.prank(owner);
        bank.setTokenSupport(address(token), false);

        assertFalse(bank.supportedTokens(address(token)));
    }

    function test_SetTokenSupport_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PrivateBank.ZeroAddress.selector);
        bank.setTokenSupport(address(0), true);
    }

    function test_SetMaxDepositAmount() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit DepositLimitUpdated(10 ether);
        bank.setMaxDepositAmount(10 ether);

        assertEq(bank.maxDepositAmount(), 10 ether);
    }

    function test_SetDailyDepositLimit() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit DailyLimitUpdated(100 ether);
        bank.setDailyDepositLimit(100 ether);

        assertEq(bank.dailyDepositLimit(), 100 ether);
    }

    // ============ Deposit Limit Tests ============

    function test_DepositNative_RevertsOnExceedingMaxDeposit() public {
        vm.prank(owner);
        bank.setMaxDepositAmount(5 ether);

        vm.prank(depositor);
        vm.expectRevert(PrivateBank.DepositLimitExceeded.selector);
        bank.depositNative{value: 10 ether}(1, stealthAddress, ephemeralPubKey, metadata);
    }

    function test_DepositNative_RevertsOnExceedingDailyLimit() public {
        vm.prank(owner);
        bank.setDailyDepositLimit(5 ether);

        vm.startPrank(depositor);
        bank.depositNative{value: 3 ether}(1, stealthAddress, ephemeralPubKey, metadata);

        vm.expectRevert(PrivateBank.DailyLimitExceeded.selector);
        bank.depositNative{value: 3 ether}(1, stealthAddress, ephemeralPubKey, metadata);
        vm.stopPrank();
    }

    function test_DepositNative_DailyLimitResetsNextDay() public {
        vm.prank(owner);
        bank.setDailyDepositLimit(5 ether);

        vm.prank(depositor);
        bank.depositNative{value: 5 ether}(1, stealthAddress, ephemeralPubKey, metadata);

        // Move to next day
        vm.warp(block.timestamp + 1 days);

        vm.prank(depositor);
        bank.depositNative{value: 5 ether}(1, makeAddr("stealth2"), ephemeralPubKey, metadata);

        assertEq(bank.totalNativeDeposits(), 10 ether);
    }

    // ============ View Function Tests ============

    function test_GetNativeBalance() public {
        vm.prank(depositor);
        bank.depositNative{value: 5 ether}(1, stealthAddress, ephemeralPubKey, metadata);

        assertEq(bank.getNativeBalance(stealthAddress), 5 ether);
    }

    function test_GetTokenBalance() public {
        vm.startPrank(depositor);
        token.approve(address(bank), 100 ether);
        bank.depositToken(address(token), 100 ether, 1, stealthAddress, ephemeralPubKey, metadata);
        vm.stopPrank();

        assertEq(bank.getTokenBalance(stealthAddress, address(token)), 100 ether);
    }

    function test_GetBalances() public {
        vm.prank(depositor);
        bank.depositNative{value: 5 ether}(1, stealthAddress, ephemeralPubKey, metadata);

        vm.startPrank(depositor);
        token.approve(address(bank), 100 ether);
        bank.depositToken(address(token), 100 ether, 1, stealthAddress, ephemeralPubKey, metadata);
        vm.stopPrank();

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);

        (uint256 nativeBalance, uint256[] memory tokenAmounts) = bank.getBalances(stealthAddress, tokens);

        assertEq(nativeBalance, 5 ether);
        assertEq(tokenAmounts[0], 100 ether);
    }

    function test_GetRemainingDailyAllowance_NoLimit() public view {
        uint256 remaining = bank.getRemainingDailyAllowance(depositor);
        assertEq(remaining, type(uint256).max);
    }

    function test_GetRemainingDailyAllowance_WithLimit() public {
        vm.prank(owner);
        bank.setDailyDepositLimit(10 ether);

        vm.prank(depositor);
        bank.depositNative{value: 3 ether}(1, stealthAddress, ephemeralPubKey, metadata);

        uint256 remaining = bank.getRemainingDailyAllowance(depositor);
        assertEq(remaining, 7 ether);
    }

    function test_GetRemainingDailyAllowance_ExhaustedLimit() public {
        vm.prank(owner);
        bank.setDailyDepositLimit(5 ether);

        vm.prank(depositor);
        bank.depositNative{value: 5 ether}(1, stealthAddress, ephemeralPubKey, metadata);

        uint256 remaining = bank.getRemainingDailyAllowance(depositor);
        assertEq(remaining, 0);
    }

    // ============ Receive Function Test ============

    function test_Receive_Reverts() public {
        vm.deal(depositor, 1 ether);

        vm.prank(depositor);
        (bool success, ) = address(bank).call{value: 1 ether}("");
        // The call reverts so success is false
        assertFalse(success);
    }
}
