// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { EntryPoint } from "../src/erc4337-entrypoint/EntryPoint.sol";
import { IEntryPoint } from "../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { IStakeManager } from "../src/erc4337-entrypoint/interfaces/IStakeManager.sol";
import { PackedUserOperation } from "../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { MockAccount, MockAccountFactory } from "./mocks/MockAccount.sol";
import { MockPaymaster } from "./mocks/MockPaymaster.sol";

contract EntryPointTest is Test {
    EntryPoint public entryPoint;
    MockAccountFactory public accountFactory;
    MockPaymaster public paymaster;

    address public owner;
    address public beneficiary;
    uint256 public ownerKey;

    // Gas limits for UserOp
    uint128 constant VERIFICATION_GAS_LIMIT = 100_000;
    uint128 constant CALL_GAS_LIMIT = 50_000;
    uint256 constant PRE_VERIFICATION_GAS = 21_000;
    uint128 constant MAX_FEE_PER_GAS = 10 gwei;
    uint128 constant MAX_PRIORITY_FEE_PER_GAS = 1 gwei;

    function setUp() public {
        // Create test accounts
        (owner, ownerKey) = makeAddrAndKey("owner");
        beneficiary = makeAddr("beneficiary");

        // Deploy EntryPoint
        entryPoint = new EntryPoint();

        // Deploy MockAccountFactory
        accountFactory = new MockAccountFactory(entryPoint);

        // Deploy MockPaymaster
        paymaster = new MockPaymaster(entryPoint);

        // Fund paymaster with deposit and stake
        vm.deal(address(paymaster), 10 ether);
        vm.prank(address(paymaster));
        paymaster.deposit{ value: 5 ether }();
        paymaster.addStake{ value: 1 ether }(86400); // 1 day unstake delay
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Deployment() public view {
        assertNotEq(address(entryPoint), address(0), "EntryPoint should be deployed");
        assertNotEq(address(entryPoint.senderCreator()), address(0), "SenderCreator should be deployed");
    }

    function test_SupportsInterface() public view {
        // Check IEntryPoint interface
        assertTrue(entryPoint.supportsInterface(type(IEntryPoint).interfaceId), "Should support IEntryPoint");
        assertTrue(entryPoint.supportsInterface(type(IStakeManager).interfaceId), "Should support IStakeManager");
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositTo() public {
        address account = makeAddr("account");
        uint256 depositAmount = 1 ether;

        vm.deal(address(this), depositAmount);
        entryPoint.depositTo{ value: depositAmount }(account);

        assertEq(entryPoint.balanceOf(account), depositAmount, "Deposit should be recorded");
    }

    function test_WithdrawTo() public {
        address account = makeAddr("account");
        address payable recipient = payable(makeAddr("recipient"));
        uint256 depositAmount = 1 ether;
        uint256 withdrawAmount = 0.5 ether;

        // Deposit first
        vm.deal(address(this), depositAmount);
        entryPoint.depositTo{ value: depositAmount }(account);

        // Withdraw
        vm.prank(account);
        entryPoint.withdrawTo(recipient, withdrawAmount);

        assertEq(entryPoint.balanceOf(account), depositAmount - withdrawAmount, "Remaining balance should be correct");
        assertEq(recipient.balance, withdrawAmount, "Recipient should receive funds");
    }

    function test_GetDepositInfo() public {
        address account = makeAddr("account");
        uint256 depositAmount = 1 ether;

        vm.deal(address(this), depositAmount);
        entryPoint.depositTo{ value: depositAmount }(account);

        IStakeManager.DepositInfo memory info = entryPoint.getDepositInfo(account);
        assertEq(info.deposit, depositAmount, "Deposit should match");
        assertFalse(info.staked, "Should not be staked");
    }

    /*//////////////////////////////////////////////////////////////
                            STAKE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddStake() public {
        address staker = makeAddr("staker");
        uint256 stakeAmount = 1 ether;
        uint32 unstakeDelaySec = 86400; // 1 day

        vm.deal(staker, stakeAmount);
        vm.prank(staker);
        entryPoint.addStake{ value: stakeAmount }(unstakeDelaySec);

        IStakeManager.DepositInfo memory info = entryPoint.getDepositInfo(staker);
        assertEq(info.stake, stakeAmount, "Stake should match");
        assertTrue(info.staked, "Should be staked");
        assertEq(info.unstakeDelaySec, unstakeDelaySec, "Unstake delay should match");
    }

    function test_UnlockStake() public {
        address staker = makeAddr("staker");
        uint256 stakeAmount = 1 ether;
        uint32 unstakeDelaySec = 86400;

        vm.deal(staker, stakeAmount);
        vm.startPrank(staker);
        entryPoint.addStake{ value: stakeAmount }(unstakeDelaySec);

        // Unlock stake
        entryPoint.unlockStake();
        vm.stopPrank();

        IStakeManager.DepositInfo memory info = entryPoint.getDepositInfo(staker);
        assertFalse(info.staked, "Should not be staked after unlock");
        assertGt(info.withdrawTime, 0, "Withdraw time should be set");
    }

    function test_WithdrawStake() public {
        address staker = makeAddr("staker");
        address payable recipient = payable(makeAddr("recipient"));
        uint256 stakeAmount = 1 ether;
        uint32 unstakeDelaySec = 86400;

        vm.deal(staker, stakeAmount);
        vm.startPrank(staker);
        entryPoint.addStake{ value: stakeAmount }(unstakeDelaySec);
        entryPoint.unlockStake();

        // Fast forward time past unstake delay
        vm.warp(block.timestamp + unstakeDelaySec + 1);

        // Withdraw stake
        entryPoint.withdrawStake(recipient);
        vm.stopPrank();

        assertEq(recipient.balance, stakeAmount, "Recipient should receive stake");
    }

    /*//////////////////////////////////////////////////////////////
                            NONCE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetNonce() public {
        address account = makeAddr("account");
        uint192 key = 0;

        uint256 nonce = entryPoint.getNonce(account, key);
        assertEq(nonce, 0, "Initial nonce should be 0");
    }

    function test_IncrementNonce() public {
        address account = makeAddr("account");
        uint192 key = 0;

        vm.prank(account);
        entryPoint.incrementNonce(key);

        uint256 nonce = entryPoint.getNonce(account, key);
        assertEq(nonce, 1, "Nonce should be incremented");
    }

    function test_NonceWithDifferentKeys() public {
        address account = makeAddr("account");
        uint192 key1 = 0;
        uint192 key2 = 1;

        vm.startPrank(account);
        entryPoint.incrementNonce(key1);
        entryPoint.incrementNonce(key1);
        entryPoint.incrementNonce(key2);
        vm.stopPrank();

        // Nonce is packed as (key << 64) | seq
        // So for key1=0, seq=2: nonce = 2
        // For key2=1, seq=1: nonce = (1 << 64) | 1 = 18446744073709551617
        uint256 expectedNonceKey1 = (uint256(key1) << 64) | 2;
        uint256 expectedNonceKey2 = (uint256(key2) << 64) | 1;

        assertEq(entryPoint.getNonce(account, key1), expectedNonceKey1, "Key1 nonce should be correct");
        assertEq(entryPoint.getNonce(account, key2), expectedNonceKey2, "Key2 nonce should be correct");
    }

    /*//////////////////////////////////////////////////////////////
                        USER OPERATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HandleOps_SimpleExecution() public {
        // Create account
        MockAccount account = accountFactory.createAccount(owner, 0);

        // Fund account with deposit
        vm.deal(address(account), 10 ether);
        account.addDeposit{ value: 5 ether }();

        // Create UserOp
        PackedUserOperation memory userOp = _createUserOp(address(account), 0);

        // Set callData to execute a simple call
        userOp.callData = abi.encodeCall(MockAccount.execute, (address(0), 0, ""));

        // Set signature (owner address for MockAccount validation)
        userOp.signature = abi.encodePacked(owner);

        // Create ops array
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        // Execute - must be called by EOA (not contract)
        vm.prank(beneficiary, beneficiary);
        entryPoint.handleOps(ops, payable(beneficiary));

        // Verify execution
        assertEq(account.executeCount(), 1, "Account should have executed once");
    }

    function test_HandleOps_WithPaymaster() public {
        // Create account
        MockAccount account = accountFactory.createAccount(owner, 0);

        // No need to fund account - paymaster will pay

        // Create UserOp with paymaster
        PackedUserOperation memory userOp = _createUserOp(address(account), 0);

        // Set callData
        userOp.callData = abi.encodeCall(MockAccount.execute, (address(0), 0, ""));

        // Set paymaster data
        userOp.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(VERIFICATION_GAS_LIMIT), // paymasterVerificationGasLimit
            uint128(CALL_GAS_LIMIT) // paymasterPostOpGasLimit
        );

        // Set signature
        userOp.signature = abi.encodePacked(owner);

        // Create ops array
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        // Execute
        vm.prank(beneficiary, beneficiary);
        entryPoint.handleOps(ops, payable(beneficiary));

        // Verify paymaster was called
        assertEq(paymaster.validateCount(), 1, "Paymaster should have validated once");
    }

    function test_GetUserOpHash() public {
        address account = makeAddr("account");
        PackedUserOperation memory userOp = _createUserOp(account, 0);

        bytes32 hash = entryPoint.getUserOpHash(userOp);
        assertNotEq(hash, bytes32(0), "Hash should not be zero");
    }

    function test_RevertOnInvalidSignature() public {
        // Create account
        MockAccount account = accountFactory.createAccount(owner, 0);

        // Fund account
        vm.deal(address(account), 10 ether);
        account.addDeposit{ value: 5 ether }();

        // Create UserOp with wrong signature
        PackedUserOperation memory userOp = _createUserOp(address(account), 0);
        userOp.callData = abi.encodeCall(MockAccount.execute, (address(0), 0, ""));
        userOp.signature = abi.encodePacked(makeAddr("wrongSigner")); // Wrong signer

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        // Expect revert
        vm.prank(beneficiary, beneficiary);
        vm.expectRevert();
        entryPoint.handleOps(ops, payable(beneficiary));
    }

    /*//////////////////////////////////////////////////////////////
                            EIP-7702 TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Eip7702InitCodeMarker() public pure {
        // Test that EIP-7702 initCode marker is recognized
        bytes memory eip7702InitCode = hex"7702";
        assertTrue(eip7702InitCode.length >= 2, "EIP-7702 marker should be at least 2 bytes");

        // Extract first 2 bytes using assembly
        bytes2 marker;
        assembly {
            marker := mload(add(eip7702InitCode, 32))
        }
        assertEq(marker, bytes2(0x7702), "Should recognize EIP-7702 marker");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _createUserOp(address sender, uint256 nonce) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(abi.encodePacked(VERIFICATION_GAS_LIMIT, CALL_GAS_LIMIT)),
            preVerificationGas: PRE_VERIFICATION_GAS,
            gasFees: bytes32(abi.encodePacked(MAX_PRIORITY_FEE_PER_GAS, MAX_FEE_PER_GAS)),
            paymasterAndData: "",
            signature: ""
        });
    }
}
