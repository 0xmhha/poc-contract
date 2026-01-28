// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { StealthVault, IStealthVault } from "../../src/privacy/enterprise/StealthVault.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice Mock ERC20 for testing
 */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title StealthVaultTest
 * @notice Unit tests for StealthVault
 */
contract StealthVaultTest is Test {
    StealthVault public vault;
    MockERC20 public token;

    address public admin;
    address public depositor;
    address public recipient;
    address public operator;

    bytes32 public testStealthHash;

    event StealthDeposit(
        bytes32 indexed depositId,
        address indexed depositor,
        address indexed token,
        uint256 amount,
        bytes32 stealthAddressHash
    );

    event StealthWithdrawal(
        bytes32 indexed depositId,
        address indexed recipient,
        uint256 amount
    );

    function setUp() public {
        admin = makeAddr("admin");
        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");
        operator = makeAddr("operator");

        // Generate test stealth hash
        testStealthHash = keccak256(abi.encodePacked(recipient, bytes32("secret")));

        vm.startPrank(admin);
        vault = new StealthVault(admin);
        vault.grantRole(vault.OPERATOR_ROLE(), operator);

        token = new MockERC20();
        token.mint(depositor, 100_000 ether);
        vm.stopPrank();

        vm.deal(depositor, 1000 ether);
    }

    /* //////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    ////////////////////////////////////////////////////////////// */

    function test_Constructor() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.VAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.EMERGENCY_ROLE(), admin));
    }

    /* //////////////////////////////////////////////////////////////
                        ETH DEPOSIT TESTS
    ////////////////////////////////////////////////////////////// */

    function test_DepositETH() public {
        uint256 amount = 10 ether;

        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // Verify deposit
        assertTrue(depositId != bytes32(0), "Deposit ID should not be zero");

        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertEq(deposit.depositor, depositor);
        assertEq(deposit.token, address(0)); // NATIVE_TOKEN
        assertEq(deposit.amount, amount);
        assertEq(deposit.stealthAddress, testStealthHash);
        assertFalse(deposit.withdrawn);

        // Verify vault balance
        assertEq(address(vault).balance, amount);
        assertEq(vault.getTotalBalance(address(0)), amount);
    }

    function test_DepositETH_ZeroAmount() public {
        vm.prank(depositor);
        vm.expectRevert(IStealthVault.InvalidAmount.selector);
        vault.depositETH{ value: 0 }(testStealthHash);
    }

    function test_DepositETH_ExceedsMaxDeposit() public {
        uint256 maxDeposit = vault.MAX_DEPOSIT();

        vm.deal(depositor, maxDeposit + 1);

        vm.prank(depositor);
        vm.expectRevert(IStealthVault.InvalidAmount.selector);
        vault.depositETH{ value: maxDeposit + 1 }(testStealthHash);
    }

    function test_DepositETH_InvalidStealthAddress() public {
        vm.prank(depositor);
        vm.expectRevert(IStealthVault.InvalidStealthAddress.selector);
        vault.depositETH{ value: 1 ether }(bytes32(0));
    }

    /* //////////////////////////////////////////////////////////////
                        TOKEN DEPOSIT TESTS
    ////////////////////////////////////////////////////////////// */

    function test_DepositToken() public {
        uint256 amount = 100 ether;

        vm.startPrank(depositor);
        token.approve(address(vault), amount);
        bytes32 depositId = vault.depositToken(address(token), amount, testStealthHash);
        vm.stopPrank();

        // Verify deposit
        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertEq(deposit.depositor, depositor);
        assertEq(deposit.token, address(token));
        assertEq(deposit.amount, amount);
        assertEq(deposit.stealthAddress, testStealthHash);

        // Verify balances
        assertEq(token.balanceOf(address(vault)), amount);
        assertEq(vault.getTotalBalance(address(token)), amount);
    }

    function test_DepositToken_ZeroAddress() public {
        vm.prank(depositor);
        vm.expectRevert(IStealthVault.InvalidAmount.selector);
        vault.depositToken(address(0), 100 ether, testStealthHash);
    }

    function test_DepositToken_ZeroAmount() public {
        vm.startPrank(depositor);
        token.approve(address(vault), 100 ether);
        vm.expectRevert(IStealthVault.InvalidAmount.selector);
        vault.depositToken(address(token), 0, testStealthHash);
        vm.stopPrank();
    }

    /* //////////////////////////////////////////////////////////////
                        WITHDRAWAL TESTS
    ////////////////////////////////////////////////////////////// */

    function test_Withdraw_ETH() public {
        // Setup: deposit ETH
        uint256 amount = 10 ether;
        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // Create valid proof
        bytes memory proof = bytes32("secret");

        // Withdraw
        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(recipient);
        vault.withdraw(depositId, recipient, proof);

        // Verify withdrawal
        assertEq(recipient.balance, recipientBalanceBefore + amount);

        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertTrue(deposit.withdrawn);
        assertEq(vault.getTotalBalance(address(0)), 0);
    }

    function test_Withdraw_Token() public {
        // Setup: deposit token
        uint256 amount = 100 ether;
        vm.startPrank(depositor);
        token.approve(address(vault), amount);
        bytes32 depositId = vault.depositToken(address(token), amount, testStealthHash);
        vm.stopPrank();

        // Create valid proof
        bytes memory proof = bytes32("secret");

        // Withdraw
        vm.prank(recipient);
        vault.withdraw(depositId, recipient, proof);

        // Verify withdrawal
        assertEq(token.balanceOf(recipient), amount);

        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertTrue(deposit.withdrawn);
    }

    function test_Withdraw_DepositNotFound() public {
        bytes32 fakeId = keccak256("fake");
        bytes memory proof = bytes32("secret");

        vm.prank(recipient);
        vm.expectRevert(IStealthVault.DepositNotFound.selector);
        vault.withdraw(fakeId, recipient, proof);
    }

    function test_Withdraw_AlreadyWithdrawn() public {
        // Setup: deposit and withdraw
        uint256 amount = 10 ether;
        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        bytes memory proof = bytes32("secret");
        vm.prank(recipient);
        vault.withdraw(depositId, recipient, proof);

        // Try to withdraw again
        vm.prank(recipient);
        vm.expectRevert(IStealthVault.AlreadyWithdrawn.selector);
        vault.withdraw(depositId, recipient, proof);
    }

    function test_Withdraw_InvalidProof() public {
        // Setup: deposit
        uint256 amount = 10 ether;
        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // Invalid proof
        bytes memory invalidProof = bytes32("wrong_secret");

        vm.prank(recipient);
        vm.expectRevert(IStealthVault.InvalidProof.selector);
        vault.withdraw(depositId, recipient, invalidProof);
    }

    /* //////////////////////////////////////////////////////////////
                    EMERGENCY WITHDRAWAL TESTS
    ////////////////////////////////////////////////////////////// */

    function test_EmergencyWithdraw() public {
        // Setup: deposit
        uint256 amount = 10 ether;
        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // Emergency withdraw by admin
        address emergencyRecipient = makeAddr("emergency");
        uint256 balanceBefore = emergencyRecipient.balance;

        vm.prank(admin);
        vault.emergencyWithdraw(depositId, emergencyRecipient);

        // Verify
        assertEq(emergencyRecipient.balance, balanceBefore + amount);

        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertTrue(deposit.withdrawn);
    }

    function test_EmergencyWithdraw_Unauthorized() public {
        // Setup: deposit
        uint256 amount = 10 ether;
        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // Non-admin tries emergency withdraw
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(); // AccessControl error
        vault.emergencyWithdraw(depositId, random);
    }

    /* //////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    ////////////////////////////////////////////////////////////// */

    function test_GetStealthDeposits() public {
        // Multiple deposits to same stealth address
        vm.startPrank(depositor);
        bytes32 depositId1 = vault.depositETH{ value: 1 ether }(testStealthHash);
        bytes32 depositId2 = vault.depositETH{ value: 2 ether }(testStealthHash);
        vm.stopPrank();

        bytes32[] memory deposits = vault.getStealthDeposits(testStealthHash);
        assertEq(deposits.length, 2);
        assertEq(deposits[0], depositId1);
        assertEq(deposits[1], depositId2);
    }

    function test_GetDepositorDeposits() public {
        bytes32 stealthHash2 = keccak256(abi.encodePacked(recipient, bytes32("secret2")));

        vm.startPrank(depositor);
        bytes32 depositId1 = vault.depositETH{ value: 1 ether }(testStealthHash);
        bytes32 depositId2 = vault.depositETH{ value: 2 ether }(stealthHash2);
        vm.stopPrank();

        bytes32[] memory deposits = vault.getDepositorDeposits(depositor);
        assertEq(deposits.length, 2);
    }

    /* //////////////////////////////////////////////////////////////
                        ADMIN FUNCTION TESTS
    ////////////////////////////////////////////////////////////// */

    function test_SetStealthLedger() public {
        address ledger = makeAddr("ledger");

        vm.prank(admin);
        vault.setStealthLedger(ledger);

        assertEq(vault.stealthLedger(), ledger);
    }

    function test_Pause() public {
        vm.prank(admin);
        vault.pause();

        vm.prank(depositor);
        vm.expectRevert(); // EnforcedPause
        vault.depositETH{ value: 1 ether }(testStealthHash);
    }

    function test_Unpause() public {
        vm.startPrank(admin);
        vault.pause();
        vault.unpause();
        vm.stopPrank();

        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: 1 ether }(testStealthHash);
        assertTrue(depositId != bytes32(0));
    }

    /* //////////////////////////////////////////////////////////////
                        FUZZ TESTS
    ////////////////////////////////////////////////////////////// */

    function testFuzz_DepositETH_Amount(uint256 amount) public {
        amount = bound(amount, 1, vault.MAX_DEPOSIT());

        vm.deal(depositor, amount);

        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertEq(deposit.amount, amount);
    }

    function testFuzz_DepositToken_Amount(uint256 amount) public {
        amount = bound(amount, 1, vault.MAX_DEPOSIT());

        vm.prank(admin);
        token.mint(depositor, amount);

        vm.startPrank(depositor);
        token.approve(address(vault), amount);
        bytes32 depositId = vault.depositToken(address(token), amount, testStealthHash);
        vm.stopPrank();

        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertEq(deposit.amount, amount);
    }

    function testFuzz_MultipleDeposits(uint8 count) public {
        count = uint8(bound(count, 1, 50));

        vm.deal(depositor, uint256(count) * 1 ether);

        bytes32[] memory depositIds = new bytes32[](count);

        vm.startPrank(depositor);
        for (uint8 i = 0; i < count; i++) {
            bytes32 hash = keccak256(abi.encodePacked(recipient, bytes32(uint256(i))));
            depositIds[i] = vault.depositETH{ value: 1 ether }(hash);
        }
        vm.stopPrank();

        assertEq(vault.depositCount(), count);
        assertEq(vault.getTotalBalance(address(0)), uint256(count) * 1 ether);
    }
}
