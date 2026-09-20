// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import { VerifyingPaymaster } from "../../src/erc4337-paymaster/VerifyingPaymaster.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { SponsorPaymasterTest } from "./SponsorPaymaster.t.sol";
import { SponsorPaymaster } from "../../src/erc4337-paymaster/SponsorPaymaster.sol";
import { PaymasterDataLib } from "../../src/erc4337-paymaster/PaymasterDataLib.sol";
import { PaymasterPayload } from "../../src/erc4337-paymaster/PaymasterPayload.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { IPaymaster } from "../../src/erc4337-entrypoint/interfaces/IPaymaster.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract BundleTestAccount {
    function validateUserOp(PackedUserOperation calldata, bytes32, uint256) external pure returns (uint256) {
        return 0;
    }
    fallback() external payable { }
}

contract SponsorRegressionTest is SponsorPaymasterTest {
    function signedOp(bytes memory data, bytes32 campaign, uint64 nonce, address target, bytes4 selector)
        internal
        returns (PackedUserOperation memory op)
    {
        op = _createSampleUserOp(user);
        op.callData = data;
        op.nonce = nonce;
        if (user.code.length > 0) op.gasFees = bytes32(uint256(1000 gwei) << 128 | uint256(1000 gwei));
        bytes memory payload = PaymasterPayload.encodeSponsor(
            PaymasterPayload.SponsorPayload({
                campaignId: campaign,
                perUserLimit: 1 ether,
                targetContract: target,
                targetSelector: selector,
                sponsorExtra: ""
            })
        );
        bytes memory env = PaymasterDataLib.encode(1, 0, uint48(block.timestamp + 1 hours), 0, nonce, payload);
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(200000), uint128(100000), env);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerPrivateKey, MessageHashUtils.toEthSignedMessageHash(paymaster.getHash(op, env)));
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(200000), uint128(100000), env, r, s, v);
    }

    function validate(PackedUserOperation memory op, uint256 cost) internal returns (bytes memory context) {
        vm.prank(address(entryPoint));
        uint256 result;
        (context, result) = paymaster.validatePaymasterUserOp(op, bytes32(0), cost);
        assertEq(address(uint160(result)), address(0));
    }

    function settle(bytes memory context, uint256 cost) internal {
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, cost, 1);
    }

    function test_allowedTransferSelectorAccepted() public {
        address target = address(0x1234);
        bytes4 selector = 0xa9059cbb;
        bytes memory data = abi.encodeWithSignature(
            "execute(bytes32,bytes)",
            bytes32(0),
            abi.encodePacked(target, uint256(0), selector, abi.encode(user, uint256(1)))
        );
        validate(signedOp(data, bytes32(uint256(1)), 0, target, selector), 1 ether);
    }

    function test_restrictedMalformedCallRejected() public {
        PackedUserOperation memory op = signedOp(hex"12345678", bytes32(0), 0, address(0x1234), bytes4(0));
        vm.expectRevert(SponsorPaymaster.InvalidExecutionCalldata.selector);
        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(op, bytes32(0), 1 ether);
    }

    function test_restrictedBatchModeRejected() public {
        bytes memory data = abi.encodeWithSignature(
            "execute(bytes32,bytes)",
            bytes32(uint256(1) << 248),
            abi.encodePacked(address(0x1234), uint256(0), bytes4(0xa9059cbb))
        );
        PackedUserOperation memory op = signedOp(data, bytes32(0), 0, address(0x1234), bytes4(0xa9059cbb));
        vm.expectRevert(SponsorPaymaster.InvalidExecutionCalldata.selector);
        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(op, bytes32(0), 1 ether);
    }

    function test_zeroCampaignAccumulatesAndEnforcesLimit() public {
        bytes memory context = validate(signedOp("", bytes32(0), 0, address(0), bytes4(0)), 1 ether);
        settle(context, 0.6 ether);
        assertEq(paymaster.userCampaignSpending(bytes32(0), user), 0.6 ether);
        assertEq(paymaster.userCampaignReserved(bytes32(0), user), 0);
        PackedUserOperation memory op = signedOp("", bytes32(0), 1, address(0), bytes4(0));
        vm.expectRevert(abi.encodeWithSelector(SponsorPaymaster.UserLimitExceeded.selector, user, 0.6 ether, 1 ether));
        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.5 ether);
    }

    function test_parallelValidationReservesLimit() public {
        bytes32 campaign = bytes32(uint256(1));
        bytes memory context = validate(signedOp("", campaign, 0, address(0), bytes4(0)), 0.7 ether);
        PackedUserOperation memory op = signedOp("", campaign, 1, address(0), bytes4(0));
        vm.expectRevert(abi.encodeWithSelector(SponsorPaymaster.UserLimitExceeded.selector, user, 0.7 ether, 1 ether));
        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.4 ether);
        settle(context, 0.2 ether);
        validate(op, 0.4 ether);
        assertEq(paymaster.userCampaignReserved(campaign, user), 0.4 ether);
        assertEq(paymaster.userCampaignSpending(campaign, user), 0.2 ether);
    }

    function test_verifyingStubAllowsCostSimulationButNeverAuthorizesPayment() public {
        VerifyingPaymaster p = new VerifyingPaymaster(IEntryPoint(address(entryPoint)), owner, verifyingSigner);
        PackedUserOperation memory op = _createSampleUserOp(user);
        bytes memory payload = PaymasterPayload.encodeVerifying(
            PaymasterPayload.VerifyingPayload(bytes32(0), address(p), type(uint256).max, "")
        );
        bytes memory env = PaymasterDataLib.encode(0, 0, uint48(block.timestamp + 1 hours), 0, 0, payload);
        op.paymasterAndData = abi.encodePacked(address(p), uint128(100000), uint128(50000), env, new bytes(65));
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 result) = p.validatePaymasterUserOp(op, bytes32(0), 1 ether);
        assertEq(address(uint160(result)), address(1));
        assertEq(context.length, 0);
        assertEq(p.senderNonce(user), 0);
    }

    function test_handleOpsBundleCannotExceedCampaignLimit() public {
        user = address(new BundleTestAccount());
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = signedOp("", bytes32(0), 0, address(0), bytes4(0));
        ops[1] = signedOp("", bytes32(0), 1, address(0), bytes4(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPoint.FailedOpWithRevert.selector,
                uint256(1),
                "AA33 reverted",
                abi.encodeWithSelector(
                    SponsorPaymaster.UserLimitExceeded.selector, user, uint256(0.521 ether), uint256(1 ether)
                )
            )
        );
        vm.prank(owner, owner);
        entryPoint.handleOps(ops, payable(owner));
        assertEq(paymaster.senderNonce(user), 0);
        assertEq(paymaster.userCampaignReserved(bytes32(0), user), 0);

        PackedUserOperation[] memory single = new PackedUserOperation[](1);
        single[0] = ops[0];
        vm.prank(owner, owner);
        entryPoint.handleOps(single, payable(owner));
        assertEq(paymaster.senderNonce(user), 1);
        assertEq(paymaster.userCampaignReserved(bytes32(0), user), 0);
        assertGt(paymaster.userCampaignSpending(bytes32(0), user), 0);
        assertLt(paymaster.userCampaignSpending(bytes32(0), user), 1 ether);
    }
}
