// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DeployPrivacyScript } from "../../script/deploy-contract/DeployPrivacy.s.sol";
import { Test } from "forge-std/Test.sol";
import { StealthVault, IStealthVault } from "../../src/privacy/enterprise/StealthVault.sol";
import { WithdrawalManager } from "../../src/privacy/enterprise/WithdrawalManager.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

contract WithdrawalToken is ERC20 {
    constructor() ERC20("Withdrawal", "W") {
        _mint(msg.sender, 10 ether);
    }
}

contract PrivacyWiringHarness is DeployPrivacyScript {
    function configure(StealthVault vault, WithdrawalManager manager) external {
        stealthVault = vault;
        withdrawalManager = manager;
        _configureWithdrawals();
    }
}

contract WithdrawalIntegrationTest is Test {
    StealthVault vault;
    WithdrawalManager manager;
    address recipient = address(0x1234);

    function setUp() public {
        vault = new StealthVault(address(this));
        manager = new WithdrawalManager(address(this), 1 hours, 100 ether);
        manager.setStealthVault(address(vault));
        vault.grantRole(vault.WITHDRAWAL_MANAGER_ROLE(), address(manager));
        vm.deal(address(this), 10 ether);
    }

    function withdraw(bytes32 id, address token, uint256 amount) internal {
        bytes32 request = manager.requestWithdrawal(id, recipient, token, amount);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        manager.executeWithdrawal(request);
    }

    function test_partialThenRemainingNativeWithdrawal() public {
        bytes32 id = vault.depositETH{ value: 10 ether }(keccak256("stealth"));
        withdraw(id, address(0), 4 ether);
        assertEq(vault.getDeposit(id).amount, 6 ether);
        assertFalse(vault.getDeposit(id).withdrawn);
        assertEq(vault.getTotalBalance(address(0)), 6 ether);
        withdraw(id, address(0), 6 ether);
        assertTrue(vault.getDeposit(id).withdrawn);
        assertEq(vault.getDeposit(id).amount, 0);
        assertEq(recipient.balance, 10 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_partialThenEmergencyWithdrawal() public {
        bytes32 id = vault.depositETH{ value: 10 ether }(keccak256("stealth"));
        withdraw(id, address(0), 4 ether);
        vault.emergencyWithdraw(id, recipient);
        assertEq(recipient.balance, 10 ether);
        assertEq(vault.getTotalBalance(address(0)), 0);
    }

    function test_partialThenRemainingTokenWithdrawal() public {
        WithdrawalToken token = new WithdrawalToken();
        token.approve(address(vault), 10 ether);
        bytes32 id = vault.depositToken(address(token), 10 ether, keccak256("stealth"));
        withdraw(id, address(token), 4 ether);
        assertEq(vault.getDeposit(id).amount, 6 ether);
        withdraw(id, address(token), 6 ether);
        assertEq(token.balanceOf(recipient), 10 ether);
        assertTrue(vault.getDeposit(id).withdrawn);
        assertEq(vault.getTotalBalance(address(token)), 0);
    }

    function test_managerCannotPullZero() public {
        bytes32 id = vault.depositETH{ value: 10 ether }(keccak256("stealth"));
        vm.prank(address(manager));
        vm.expectRevert(IStealthVault.InvalidAmount.selector);
        vault.transferToWithdrawalManager(id, address(0), 0);
        assertFalse(vault.getDeposit(id).withdrawn);
    }

    function test_pausedVaultBlocksManagerWithdrawal() public {
        bytes32 id = vault.depositETH{ value: 10 ether }(keccak256("stealth"));
        bytes32 request = manager.requestWithdrawal(id, recipient, address(0), 4 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        vault.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        manager.executeWithdrawal(request);
        assertEq(address(vault).balance, 10 ether);

        // The request stays executable once the vault is unpaused
        vault.unpause();
        manager.executeWithdrawal(request);
        assertEq(recipient.balance, 4 ether);
    }

    function test_deploymentWiringIsIdempotent() public {
        PrivacyWiringHarness script = new PrivacyWiringHarness();
        StealthVault freshVault = new StealthVault(address(script));
        WithdrawalManager freshManager = new WithdrawalManager(address(script), 0, 100 ether);
        script.configure(freshVault, freshManager);
        script.configure(freshVault, freshManager);
        assertEq(freshManager.stealthVault(), address(freshVault));
        assertTrue(freshVault.hasRole(freshVault.WITHDRAWAL_MANAGER_ROLE(), address(freshManager)));
    }
}
