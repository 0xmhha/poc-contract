// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { wKRC } from "../../src/tokens/wKRC.sol";

contract wKRCTest is Test {
    wKRC public token;

    address public user1;
    address public user2;

    event Deposit(address indexed from, uint256 amount);
    event Withdrawal(address indexed to, uint256 amount);

    function setUp() public {
        token = new wKRC();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }

    /* //////////////////////////////////////////////////////////////
                            METADATA TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Name() public view {
        assertEq(token.name(), "Wrapped Native Token");
    }

    function test_Symbol() public view {
        assertEq(token.symbol(), "wKRC");
    }

    function test_Decimals() public view {
        assertEq(token.decimals(), 18);
    }

    /* //////////////////////////////////////////////////////////////
                          INITIAL STATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_InitialSupplyIsZero() public view {
        assertEq(token.totalSupply(), 0);
        assertEq(token.totalDeposits(), 0);
    }

    /* //////////////////////////////////////////////////////////////
                           DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Deposit() public {
        uint256 amount = 1 ether;

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit Deposit(user1, amount);
        token.deposit{ value: amount }();

        assertEq(token.balanceOf(user1), amount);
        assertEq(token.totalSupply(), amount);
        assertEq(token.totalDeposits(), amount);
    }

    function test_Deposit_ZeroValue() public {
        vm.prank(user1);
        token.deposit{ value: 0 }();

        assertEq(token.balanceOf(user1), 0);
    }

    function test_Deposit_MultipleDeposits() public {
        vm.startPrank(user1);
        token.deposit{ value: 1 ether }();
        token.deposit{ value: 2 ether }();
        vm.stopPrank();

        assertEq(token.balanceOf(user1), 3 ether);
        assertEq(token.totalSupply(), 3 ether);
    }

    /* //////////////////////////////////////////////////////////////
                          DEPOSIT TO TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositTo() public {
        uint256 amount = 5 ether;

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit Deposit(user2, amount);
        token.depositTo{ value: amount }(user2);

        assertEq(token.balanceOf(user1), 0);
        assertEq(token.balanceOf(user2), amount);
    }

    /* //////////////////////////////////////////////////////////////
                          WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw() public {
        uint256 depositAmount = 5 ether;
        uint256 withdrawAmount = 2 ether;

        vm.startPrank(user1);
        token.deposit{ value: depositAmount }();

        uint256 balanceBefore = user1.balance;

        vm.expectEmit(true, false, false, true);
        emit Withdrawal(user1, withdrawAmount);
        token.withdraw(withdrawAmount);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), depositAmount - withdrawAmount);
        assertEq(user1.balance, balanceBefore + withdrawAmount);
    }

    function test_Withdraw_FullBalance() public {
        uint256 amount = 3 ether;

        vm.startPrank(user1);
        token.deposit{ value: amount }();
        token.withdraw(amount);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), 0);
        assertEq(token.totalSupply(), 0);
        assertEq(token.totalDeposits(), 0);
    }

    function test_Withdraw_RevertIfInsufficientBalance() public {
        vm.startPrank(user1);
        token.deposit{ value: 1 ether }();

        vm.expectRevert();
        token.withdraw(2 ether);
        vm.stopPrank();
    }

    function test_Withdraw_RevertIfNoBalance() public {
        vm.prank(user1);
        vm.expectRevert();
        token.withdraw(1 ether);
    }

    /* //////////////////////////////////////////////////////////////
                        WITHDRAW TO TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawTo() public {
        uint256 depositAmount = 5 ether;
        uint256 withdrawAmount = 2 ether;

        vm.prank(user1);
        token.deposit{ value: depositAmount }();

        uint256 user2BalanceBefore = user2.balance;

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit Withdrawal(user2, withdrawAmount);
        token.withdrawTo(user2, withdrawAmount);

        assertEq(token.balanceOf(user1), depositAmount - withdrawAmount);
        assertEq(user2.balance, user2BalanceBefore + withdrawAmount);
    }

    function test_WithdrawTo_RevertIfInsufficientBalance() public {
        vm.startPrank(user1);
        token.deposit{ value: 1 ether }();

        vm.expectRevert();
        token.withdrawTo(user2, 2 ether);
        vm.stopPrank();
    }

    /* //////////////////////////////////////////////////////////////
                          RECEIVE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Receive() public {
        uint256 amount = 1 ether;

        vm.prank(user1);
        (bool success,) = address(token).call{ value: amount }("");
        assertTrue(success);

        assertEq(token.balanceOf(user1), amount);
        assertEq(token.totalSupply(), amount);
    }

    /* //////////////////////////////////////////////////////////////
                        ERC20 TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Transfer() public {
        uint256 amount = 3 ether;

        vm.prank(user1);
        token.deposit{ value: amount }();

        vm.prank(user1);
        assertTrue(token.transfer(user2, 1 ether));

        assertEq(token.balanceOf(user1), 2 ether);
        assertEq(token.balanceOf(user2), 1 ether);
    }

    function test_Approve_And_TransferFrom() public {
        uint256 amount = 3 ether;

        vm.prank(user1);
        token.deposit{ value: amount }();

        vm.prank(user1);
        token.approve(user2, 2 ether);

        vm.prank(user2);
        assertTrue(token.transferFrom(user1, user2, 2 ether));

        assertEq(token.balanceOf(user1), 1 ether);
        assertEq(token.balanceOf(user2), 2 ether);
    }

    /* //////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TotalDeposits() public {
        vm.prank(user1);
        token.deposit{ value: 5 ether }();

        vm.prank(user2);
        token.deposit{ value: 3 ether }();

        assertEq(token.totalDeposits(), 8 ether);

        vm.prank(user1);
        token.withdraw(2 ether);

        assertEq(token.totalDeposits(), 6 ether);
    }

    /* //////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DepositAndWithdraw(uint256 amount) public {
        amount = bound(amount, 0, 100 ether);

        vm.startPrank(user1);
        token.deposit{ value: amount }();

        assertEq(token.balanceOf(user1), amount);
        assertEq(token.totalDeposits(), amount);

        if (amount > 0) {
            uint256 balanceBefore = user1.balance;
            token.withdraw(amount);

            assertEq(token.balanceOf(user1), 0);
            assertEq(user1.balance, balanceBefore + amount);
            assertEq(token.totalDeposits(), 0);
        }
        vm.stopPrank();
    }

    function testFuzz_DepositTo(uint256 amount) public {
        amount = bound(amount, 0, 100 ether);

        vm.prank(user1);
        token.depositTo{ value: amount }(user2);

        assertEq(token.balanceOf(user2), amount);
        assertEq(token.balanceOf(user1), 0);
    }

    function testFuzz_WithdrawTo(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, 1, 100 ether);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);

        vm.prank(user1);
        token.deposit{ value: depositAmount }();

        uint256 user2BalanceBefore = user2.balance;

        vm.prank(user1);
        token.withdrawTo(user2, withdrawAmount);

        assertEq(token.balanceOf(user1), depositAmount - withdrawAmount);
        assertEq(user2.balance, user2BalanceBefore + withdrawAmount);
    }

    function testFuzz_Transfer(uint256 depositAmount, uint256 transferAmount) public {
        depositAmount = bound(depositAmount, 1, 100 ether);
        transferAmount = bound(transferAmount, 1, depositAmount);

        vm.prank(user1);
        token.deposit{ value: depositAmount }();

        vm.prank(user1);
        require(token.transfer(user2, transferAmount), "Transfer failed");

        assertEq(token.balanceOf(user1), depositAmount - transferAmount);
        assertEq(token.balanceOf(user2), transferAmount);
    }
}
