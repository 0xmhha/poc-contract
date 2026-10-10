// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC20Paymaster } from "../../src/erc4337-paymaster/ERC20Paymaster.sol";
import { Permit2Paymaster } from "../../src/erc4337-paymaster/Permit2Paymaster.sol";
import { BasePaymaster } from "../../src/erc4337-paymaster/BasePaymaster.sol";
import { IPriceOracle } from "../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";
import { IPermit2 } from "../../src/permit2/interfaces/IPermit2.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";
import { PaymasterDataLib } from "../../src/erc4337-paymaster/PaymasterDataLib.sol";
import { PaymasterPayload } from "../../src/erc4337-paymaster/PaymasterPayload.sol";
import { MockAccount } from "../mocks/MockAccount.sol";
import { MockPriceOracle } from "./mocks/MockPriceOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockPermit2 } from "./mocks/MockPermit2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TokenPaymasterSettlementTest
 * @notice End-to-end handleOps tests for the token paymasters.
 * @dev A postOp revert makes the EntryPoint charge the paymaster's deposit while the
 *      user's execution is rolled back. A paymaster that collects tokens only in postOp
 *      can therefore be made to pay gas for free: the user moves the tokens away during
 *      execution (or never had them), postOp fails, and the paymaster absorbs the cost.
 *      These tests check that the paymaster is paid in tokens whenever it pays gas.
 */
contract TokenPaymasterSettlementTest is Test {
    EntryPoint internal entryPoint;
    MockPriceOracle internal oracle;
    MockERC20 internal token;
    MockPermit2 internal permit2;
    ERC20Paymaster internal erc20Paymaster;
    Permit2Paymaster internal permit2Paymaster;
    MockAccount internal account;

    address internal owner = makeAddr("owner");
    address internal accountOwner = makeAddr("accountOwner");
    address internal bundler = makeAddr("bundler");
    address internal sink = makeAddr("sink");

    uint256 internal constant MARKUP = 1000; // 10%
    uint256 internal constant USER_TOKENS = 1000e6;

    function setUp() public {
        entryPoint = new EntryPoint();
        oracle = new MockPriceOracle();
        token = new MockERC20("Mock USDC", "MUSDC", 6);
        permit2 = new MockPermit2();
        oracle.setPrice(address(token), 5e14); // 0.0005 ETH per token

        vm.startPrank(owner);
        erc20Paymaster =
            new ERC20Paymaster(IEntryPoint(address(entryPoint)), owner, IPriceOracle(address(oracle)), MARKUP);
        permit2Paymaster = new Permit2Paymaster(
            IEntryPoint(address(entryPoint)), owner, IPermit2(address(permit2)), IPriceOracle(address(oracle)), MARKUP
        );
        erc20Paymaster.setSupportedToken(address(token), true);
        permit2Paymaster.setSupportedToken(address(token), true);
        vm.stopPrank();

        vm.deal(owner, 100 ether);
        vm.startPrank(owner);
        erc20Paymaster.deposit{ value: 10 ether }();
        permit2Paymaster.deposit{ value: 10 ether }();
        vm.stopPrank();

        account = new MockAccount(IEntryPoint(address(entryPoint)), accountOwner);
        token.mint(address(account), USER_TOKENS);

        vm.startPrank(address(account));
        token.approve(address(erc20Paymaster), type(uint256).max);
        token.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    // ============ ERC20Paymaster ============

    function test_ERC20Paymaster_ChargesTokensForGas() public {
        PackedUserOperation memory op = _userOp(_erc20PaymasterAndData(), "");

        uint256 depositBefore = entryPoint.balanceOf(address(erc20Paymaster));
        _handleOp(op);

        uint256 gasPaid = depositBefore - entryPoint.balanceOf(address(erc20Paymaster));
        uint256 collected = token.balanceOf(address(erc20Paymaster));
        assertGt(gasPaid, 0, "paymaster paid gas");
        assertGt(collected, 0, "paymaster collected tokens");
        assertEq(token.balanceOf(address(account)), USER_TOKENS - collected, "user paid exactly what was collected");
    }

    function test_ERC20Paymaster_UserCannotDrainTokensBeforePostOp() public {
        // Execution sends every token away, so a postOp-only charge has nothing to pull.
        bytes memory drain = abi.encodeCall(
            MockAccount.execute, (address(token), 0, abi.encodeCall(IERC20.transfer, (sink, USER_TOKENS)))
        );
        PackedUserOperation memory op = _userOp(_erc20PaymasterAndData(), drain);

        uint256 depositBefore = entryPoint.balanceOf(address(erc20Paymaster));
        _handleOp(op);

        uint256 gasPaid = depositBefore - entryPoint.balanceOf(address(erc20Paymaster));
        assertGt(gasPaid, 0, "paymaster paid gas");
        assertGt(token.balanceOf(address(erc20Paymaster)), 0, "paymaster must be paid in tokens");
    }

    // ============ Permit2Paymaster ============

    function test_Permit2Paymaster_ChargesTokensForGas() public {
        PackedUserOperation memory op = _userOp(_permit2PaymasterAndData(type(uint160).max), "");

        uint256 depositBefore = entryPoint.balanceOf(address(permit2Paymaster));
        _handleOp(op);

        uint256 gasPaid = depositBefore - entryPoint.balanceOf(address(permit2Paymaster));
        uint256 collected = token.balanceOf(address(permit2Paymaster));
        assertGt(gasPaid, 0, "paymaster paid gas");
        assertGt(collected, 0, "paymaster collected tokens");
        assertEq(token.balanceOf(address(account)), USER_TOKENS - collected, "user paid exactly what was collected");
    }

    function test_Permit2Paymaster_UserCannotDrainTokensBeforePostOp() public {
        bytes memory drain = abi.encodeCall(
            MockAccount.execute, (address(token), 0, abi.encodeCall(IERC20.transfer, (sink, USER_TOKENS)))
        );
        PackedUserOperation memory op = _userOp(_permit2PaymasterAndData(type(uint160).max), drain);

        uint256 depositBefore = entryPoint.balanceOf(address(permit2Paymaster));
        _handleOp(op);

        uint256 gasPaid = depositBefore - entryPoint.balanceOf(address(permit2Paymaster));
        assertGt(gasPaid, 0, "paymaster paid gas");
        assertGt(token.balanceOf(address(permit2Paymaster)), 0, "paymaster must be paid in tokens");
    }

    function test_Permit2Paymaster_RejectsPermitBelowMaxCost() public {
        // A permit for 1 unit cannot cover the gas, so validation must fail
        // instead of letting postOp revert at the paymaster's expense.
        PackedUserOperation memory op = _userOp(_permit2PaymasterAndData(1), "");

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.expectPartialRevert(IEntryPoint.FailedOpWithRevert.selector);
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, payable(bundler));
    }

    // ============ Helpers ============

    function _handleOp(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, payable(bundler));
    }

    function _userOp(bytes memory paymasterAndData, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory)
    {
        return PackedUserOperation({
            sender: address(account),
            nonce: entryPoint.getNonce(address(account), 0),
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(uint256(200_000) << 128 | uint256(200_000)),
            preVerificationGas: 50_000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: paymasterAndData,
            signature: abi.encodePacked(accountOwner)
        });
    }

    function _erc20PaymasterAndData() internal view returns (bytes memory) {
        bytes memory payload = PaymasterPayload.encodeErc20(
            PaymasterPayload.Erc20Payload({ token: address(token), maxTokenCost: 0, quoteId: 0, erc20Extra: "" })
        );
        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.ERC20), 0, uint48(block.timestamp + 1 hours), 0, uint64(0), payload
        );
        return abi.encodePacked(address(erc20Paymaster), uint128(200_000), uint128(100_000), envelope);
    }

    function _permit2PaymasterAndData(uint160 permitAmount) internal view returns (bytes memory) {
        uint48 expiration = uint48(block.timestamp + 1 hours);
        bytes memory payload = PaymasterPayload.encodePermit2(
            PaymasterPayload.Permit2Payload({
                token: address(token),
                permitAmount: permitAmount,
                permitExpiration: expiration,
                permitNonce: 0,
                permitSig: new bytes(65),
                permit2Extra: ""
            })
        );
        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.PERMIT2), 0, expiration, 0, uint64(0), payload
        );
        return abi.encodePacked(address(permit2Paymaster), uint128(200_000), uint128(100_000), envelope);
    }
}
