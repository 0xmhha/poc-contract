// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {USDC} from "../../src/tokens/USDC.sol";

contract USDCTest is Test {
    USDC public usdc;

    address public owner;
    address public minter;
    address public user1;
    address public user2;

    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);
    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event Mint(address indexed minter, address indexed to, uint256 amount);
    event Burn(address indexed burner, uint256 amount);

    function setUp() public {
        owner = makeAddr("owner");
        minter = makeAddr("minter");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vm.prank(owner);
        usdc = new USDC(owner);
    }

    /*//////////////////////////////////////////////////////////////
                            METADATA TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Name() public view {
        assertEq(usdc.name(), "USD Coin");
    }

    function test_Symbol() public view {
        assertEq(usdc.symbol(), "USDC");
    }

    function test_Decimals() public view {
        assertEq(usdc.decimals(), 6);
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OwnerIsInitialMinter() public view {
        assertTrue(usdc.isMinter(owner));
    }

    function test_OwnerSetCorrectly() public view {
        assertEq(usdc.owner(), owner);
    }

    function test_InitialSupplyIsZero() public view {
        assertEq(usdc.totalSupply(), 0);
        assertEq(usdc.totalMinted(), 0);
        assertEq(usdc.totalBurned(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        MINTER MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddMinter() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit MinterAdded(minter);
        usdc.addMinter(minter);

        assertTrue(usdc.isMinter(minter));
    }

    function test_AddMinter_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        usdc.addMinter(minter);
    }

    function test_AddMinter_RevertIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(USDC.ZeroAddress.selector);
        usdc.addMinter(address(0));
    }

    function test_RemoveMinter() public {
        vm.startPrank(owner);
        usdc.addMinter(minter);

        vm.expectEmit(true, false, false, false);
        emit MinterRemoved(minter);
        usdc.removeMinter(minter);
        vm.stopPrank();

        assertFalse(usdc.isMinter(minter));
    }

    function test_RemoveMinter_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        usdc.removeMinter(minter);
    }

    /*//////////////////////////////////////////////////////////////
                        BLACKLIST MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Blacklist() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit Blacklisted(user1);
        usdc.blacklist(user1);

        assertTrue(usdc.isBlacklisted(user1));
    }

    function test_UnBlacklist() public {
        vm.startPrank(owner);
        usdc.blacklist(user1);

        vm.expectEmit(true, false, false, false);
        emit UnBlacklisted(user1);
        usdc.unBlacklist(user1);
        vm.stopPrank();

        assertFalse(usdc.isBlacklisted(user1));
    }

    function test_Blacklist_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        usdc.blacklist(user2);
    }

    function test_UnBlacklist_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        usdc.unBlacklist(user2);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit Paused(owner);
        usdc.pause();

        assertTrue(usdc.paused());
    }

    function test_Unpause() public {
        vm.startPrank(owner);
        usdc.pause();

        vm.expectEmit(true, false, false, false);
        emit Unpaused(owner);
        usdc.unpause();
        vm.stopPrank();

        assertFalse(usdc.paused());
    }

    function test_Pause_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        usdc.pause();
    }

    function test_Unpause_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        usdc.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                            MINT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Mint() public {
        uint256 amount = 1_000_000e6; // 1M USDC

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Mint(owner, user1, amount);
        usdc.mint(user1, amount);

        assertEq(usdc.balanceOf(user1), amount);
        assertEq(usdc.totalSupply(), amount);
        assertEq(usdc.totalMinted(), amount);
    }

    function test_Mint_ByAuthorizedMinter() public {
        vm.prank(owner);
        usdc.addMinter(minter);

        uint256 amount = 500e6;
        vm.prank(minter);
        usdc.mint(user1, amount);

        assertEq(usdc.balanceOf(user1), amount);
    }

    function test_Mint_RevertIfNotMinter() public {
        vm.prank(user1);
        vm.expectRevert(USDC.NotMinter.selector);
        usdc.mint(user1, 100e6);
    }

    function test_Mint_RevertIfPaused() public {
        vm.prank(owner);
        usdc.pause();

        vm.prank(owner);
        vm.expectRevert(USDC.ContractPaused.selector);
        usdc.mint(user1, 100e6);
    }

    function test_Mint_RevertIfRecipientBlacklisted() public {
        vm.startPrank(owner);
        usdc.blacklist(user1);

        vm.expectRevert(USDC.Blacklist.selector);
        usdc.mint(user1, 100e6);
        vm.stopPrank();
    }

    function test_Mint_RevertIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(USDC.ZeroAddress.selector);
        usdc.mint(address(0), 100e6);
    }

    function test_Mint_RevertIfZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(USDC.ZeroAmount.selector);
        usdc.mint(user1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            BURN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Burn() public {
        uint256 mintAmount = 1_000e6;
        uint256 burnAmount = 400e6;

        vm.prank(owner);
        usdc.mint(user1, mintAmount);

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit Burn(user1, burnAmount);
        usdc.burn(burnAmount);

        assertEq(usdc.balanceOf(user1), mintAmount - burnAmount);
        assertEq(usdc.totalBurned(), burnAmount);
    }

    function test_Burn_RevertIfPaused() public {
        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(owner);
        usdc.pause();

        vm.prank(user1);
        vm.expectRevert(USDC.ContractPaused.selector);
        usdc.burn(100e6);
    }

    function test_Burn_RevertIfBlacklisted() public {
        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(owner);
        usdc.blacklist(user1);

        vm.prank(user1);
        vm.expectRevert(USDC.Blacklist.selector);
        usdc.burn(100e6);
    }

    function test_Burn_RevertIfZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(USDC.ZeroAmount.selector);
        usdc.burn(0);
    }

    /*//////////////////////////////////////////////////////////////
                          BURN FROM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BurnFrom() public {
        uint256 mintAmount = 1_000e6;
        uint256 burnAmount = 300e6;

        vm.prank(owner);
        usdc.mint(user1, mintAmount);

        vm.prank(user1);
        usdc.approve(user2, burnAmount);

        vm.prank(user2);
        usdc.burnFrom(user1, burnAmount);

        assertEq(usdc.balanceOf(user1), mintAmount - burnAmount);
        assertEq(usdc.totalBurned(), burnAmount);
    }

    function test_BurnFrom_RevertIfPaused() public {
        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(user1);
        usdc.approve(user2, 500e6);

        vm.prank(owner);
        usdc.pause();

        vm.prank(user2);
        vm.expectRevert(USDC.ContractPaused.selector);
        usdc.burnFrom(user1, 100e6);
    }

    function test_BurnFrom_RevertIfFromBlacklisted() public {
        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(user1);
        usdc.approve(user2, 500e6);

        vm.prank(owner);
        usdc.blacklist(user1);

        vm.prank(user2);
        vm.expectRevert(USDC.Blacklist.selector);
        usdc.burnFrom(user1, 100e6);
    }

    function test_BurnFrom_RevertIfCallerBlacklisted() public {
        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(user1);
        usdc.approve(user2, 500e6);

        vm.prank(owner);
        usdc.blacklist(user2);

        vm.prank(user2);
        vm.expectRevert(USDC.Blacklist.selector);
        usdc.burnFrom(user1, 100e6);
    }

    function test_BurnFrom_RevertIfZeroAmount() public {
        vm.prank(user2);
        vm.expectRevert(USDC.ZeroAmount.selector);
        usdc.burnFrom(user1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                          TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Transfer() public {
        uint256 amount = 500e6;

        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(user1);
        assertTrue(usdc.transfer(user2, amount));

        assertEq(usdc.balanceOf(user1), 500e6);
        assertEq(usdc.balanceOf(user2), 500e6);
    }

    function test_Transfer_RevertIfPaused() public {
        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(owner);
        usdc.pause();

        vm.prank(user1);
        vm.expectRevert(USDC.ContractPaused.selector);
        usdc.transfer(user2, 100e6);
    }

    function test_Transfer_RevertIfSenderBlacklisted() public {
        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(owner);
        usdc.blacklist(user1);

        vm.prank(user1);
        vm.expectRevert(USDC.Blacklist.selector);
        usdc.transfer(user2, 100e6);
    }

    function test_Transfer_RevertIfRecipientBlacklisted() public {
        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(owner);
        usdc.blacklist(user2);

        vm.prank(user1);
        vm.expectRevert(USDC.Blacklist.selector);
        usdc.transfer(user2, 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                        TRANSFER FROM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TransferFrom() public {
        uint256 amount = 300e6;

        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(user1);
        usdc.approve(user2, amount);

        vm.prank(user2);
        assertTrue(usdc.transferFrom(user1, user2, amount));

        assertEq(usdc.balanceOf(user1), 700e6);
        assertEq(usdc.balanceOf(user2), 300e6);
    }

    function test_TransferFrom_RevertIfPaused() public {
        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(user1);
        usdc.approve(user2, 500e6);

        vm.prank(owner);
        usdc.pause();

        vm.prank(user2);
        vm.expectRevert(USDC.ContractPaused.selector);
        usdc.transferFrom(user1, user2, 100e6);
    }

    function test_TransferFrom_RevertIfFromBlacklisted() public {
        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(user1);
        usdc.approve(user2, 500e6);

        vm.prank(owner);
        usdc.blacklist(user1);

        vm.prank(user2);
        vm.expectRevert(USDC.Blacklist.selector);
        usdc.transferFrom(user1, user2, 100e6);
    }

    function test_TransferFrom_RevertIfToBlacklisted() public {
        address user3 = makeAddr("user3");

        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(user1);
        usdc.approve(user2, 500e6);

        vm.prank(owner);
        usdc.blacklist(user3);

        vm.prank(user2);
        vm.expectRevert(USDC.Blacklist.selector);
        usdc.transferFrom(user1, user3, 100e6);
    }

    function test_TransferFrom_RevertIfCallerBlacklisted() public {
        vm.prank(owner);
        usdc.mint(user1, 1_000e6);

        vm.prank(user1);
        usdc.approve(user2, 500e6);

        vm.prank(owner);
        usdc.blacklist(user2);

        vm.prank(user2);
        vm.expectRevert(USDC.Blacklist.selector);
        usdc.transferFrom(user1, user2, 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                          APPROVE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Approve() public {
        vm.prank(user1);
        assertTrue(usdc.approve(user2, 1_000e6));

        assertEq(usdc.allowance(user1, user2), 1_000e6);
    }

    function test_Approve_RevertIfPaused() public {
        vm.prank(owner);
        usdc.pause();

        vm.prank(user1);
        vm.expectRevert(USDC.ContractPaused.selector);
        usdc.approve(user2, 100e6);
    }

    function test_Approve_RevertIfOwnerBlacklisted() public {
        vm.prank(owner);
        usdc.blacklist(user1);

        vm.prank(user1);
        vm.expectRevert(USDC.Blacklist.selector);
        usdc.approve(user2, 100e6);
    }

    function test_Approve_RevertIfSpenderBlacklisted() public {
        vm.prank(owner);
        usdc.blacklist(user2);

        vm.prank(user1);
        vm.expectRevert(USDC.Blacklist.selector);
        usdc.approve(user2, 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CirculatingSupply() public {
        vm.startPrank(owner);
        usdc.mint(user1, 1_000e6);
        usdc.mint(user2, 500e6);
        vm.stopPrank();

        vm.prank(user1);
        usdc.burn(200e6);

        assertEq(usdc.circulatingSupply(), 1_300e6);
        assertEq(usdc.totalMinted(), 1_500e6);
        assertEq(usdc.totalBurned(), 200e6);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Mint(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.prank(owner);
        usdc.mint(user1, amount);

        assertEq(usdc.balanceOf(user1), amount);
        assertEq(usdc.totalMinted(), amount);
    }

    function testFuzz_MintAndBurn(uint256 mintAmount, uint256 burnAmount) public {
        mintAmount = bound(mintAmount, 1, type(uint128).max);
        burnAmount = bound(burnAmount, 1, mintAmount);

        vm.prank(owner);
        usdc.mint(user1, mintAmount);

        vm.prank(user1);
        usdc.burn(burnAmount);

        assertEq(usdc.balanceOf(user1), mintAmount - burnAmount);
        assertEq(usdc.circulatingSupply(), mintAmount - burnAmount);
    }

    function testFuzz_Transfer(uint256 mintAmount, uint256 transferAmount) public {
        mintAmount = bound(mintAmount, 1, type(uint128).max);
        transferAmount = bound(transferAmount, 1, mintAmount);

        vm.prank(owner);
        usdc.mint(user1, mintAmount);

        vm.prank(user1);
        usdc.transfer(user2, transferAmount);

        assertEq(usdc.balanceOf(user1), mintAmount - transferAmount);
        assertEq(usdc.balanceOf(user2), transferAmount);
    }
}
