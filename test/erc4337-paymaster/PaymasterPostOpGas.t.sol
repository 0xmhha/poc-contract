// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC20Paymaster } from "../../src/erc4337-paymaster/ERC20Paymaster.sol";
import { Permit2Paymaster } from "../../src/erc4337-paymaster/Permit2Paymaster.sol";
import { SponsorPaymaster } from "../../src/erc4337-paymaster/SponsorPaymaster.sol";
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
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title PaymasterPostOpGasTest
 * @notice End-to-end handleOps tests for the cost of the paymaster postOp phase.
 * @dev The user chooses paymasterPostOpGasLimit. EntryPoint v0.9 charges the paymaster
 *      deposit the postOp gas used plus 10% of the unused postOp gas, none of which is in the
 *      `actualGasCost` passed to postOp. These tests check that the limit is capped and that
 *      a token paymaster collects at least the value of what its deposit pays, at the cap.
 *      SponsorPaymaster's signature does not cover the limit, so a user can raise it after
 *      signing; the cap bounds that, and the recorded spending covers the deposit spent.
 */
contract PaymasterPostOpGasTest is Test {
    EntryPoint internal entryPoint;
    MockPriceOracle internal oracle;
    MockERC20 internal token;
    MockPermit2 internal permit2;
    ERC20Paymaster internal erc20Paymaster;
    Permit2Paymaster internal permit2Paymaster;
    SponsorPaymaster internal sponsorPaymaster;
    MockAccount internal account;

    address internal owner = makeAddr("owner");
    address internal accountOwner = makeAddr("accountOwner");
    address internal bundler = makeAddr("bundler");
    uint256 internal signerKey = 0xA11CE;

    // Lowest markup the token paymasters allow, so the markup hides as little loss as possible
    uint256 internal constant MARKUP = 500;
    uint256 internal constant USER_TOKENS = 1000e6;
    uint256 internal constant TOKEN_PRICE = 5e14; // wei per 1 token (6 decimals)
    uint256 internal constant GAS_PRICE = 1 gwei;
    // Literal copy of BasePaymaster.MAX_POSTOP_GAS_LIMIT (kept literal so the tests compile
    // against the contracts from before the cap was added)
    uint128 internal constant POSTOP_CAP = 150_000;

    struct Result {
        uint256 depositDecrease; // paymaster EntryPoint deposit decrease (wei)
        uint256 tokensPaid; // user token decrease (token units)
        uint256 tokenValue; // tokensPaid at the oracle price, without markup (wei)
    }

    function setUp() public {
        vm.warp(1_700_000_000);
        entryPoint = new EntryPoint();
        oracle = new MockPriceOracle();
        token = new MockERC20("Mock USDC", "MUSDC", 6);
        permit2 = new MockPermit2();
        oracle.setPrice(address(token), TOKEN_PRICE);

        vm.startPrank(owner);
        erc20Paymaster =
            new ERC20Paymaster(IEntryPoint(address(entryPoint)), owner, IPriceOracle(address(oracle)), MARKUP);
        permit2Paymaster = new Permit2Paymaster(
            IEntryPoint(address(entryPoint)), owner, IPermit2(address(permit2)), IPriceOracle(address(oracle)), MARKUP
        );
        erc20Paymaster.setSupportedToken(address(token), true);
        permit2Paymaster.setSupportedToken(address(token), true);
        sponsorPaymaster = new SponsorPaymaster(IEntryPoint(address(entryPoint)), owner, vm.addr(signerKey));
        vm.stopPrank();

        vm.deal(owner, 100 ether);
        vm.startPrank(owner);
        erc20Paymaster.deposit{ value: 10 ether }();
        permit2Paymaster.deposit{ value: 10 ether }();
        sponsorPaymaster.deposit{ value: 10 ether }();
        vm.stopPrank();

        account = new MockAccount(IEntryPoint(address(entryPoint)), accountOwner);
        token.mint(address(account), USER_TOKENS);
        vm.startPrank(address(account));
        token.approve(address(erc20Paymaster), type(uint256).max);
        token.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    // ============ ERC20Paymaster ============

    function test_ERC20Paymaster_RejectsPostOpGasLimitAboveCap() public {
        _expectPostOpLimitRejected(_userOp(_erc20PaymasterAndData(POSTOP_CAP + 1)), POSTOP_CAP + 1);
    }

    function test_ERC20Paymaster_NoNetLossAtPostOpCap() public {
        Result memory r = _runToken(_erc20PaymasterAndData(POSTOP_CAP), address(erc20Paymaster));
        assertLe(r.depositDecrease, r.tokenValue, "deposit paid more than the tokens collected are worth");
        uint256 maxTokenCost = erc20Paymaster.getTokenAmount(address(token), _maxCost(POSTOP_CAP));
        assertLt(r.tokensPaid, maxTokenCost, "unused pre-charge refunded");
    }

    function testFuzz_ERC20Paymaster_NoNetLossUpToPostOpCap(uint128 postOpGasLimit) public {
        postOpGasLimit = uint128(bound(postOpGasLimit, 20_000, POSTOP_CAP));
        Result memory r = _runToken(_erc20PaymasterAndData(postOpGasLimit), address(erc20Paymaster));
        assertLe(r.depositDecrease, r.tokenValue, "deposit paid more than the tokens collected are worth");
    }

    // ============ Permit2Paymaster ============

    function test_Permit2Paymaster_RejectsPostOpGasLimitAboveCap() public {
        _expectPostOpLimitRejected(_userOp(_permit2PaymasterAndData(POSTOP_CAP + 1)), POSTOP_CAP + 1);
    }

    function test_Permit2Paymaster_NoNetLossAtPostOpCap() public {
        Result memory r = _runToken(_permit2PaymasterAndData(POSTOP_CAP), address(permit2Paymaster));
        assertLe(r.depositDecrease, r.tokenValue, "deposit paid more than the tokens collected are worth");
        uint256 maxTokenCost = permit2Paymaster.getTokenAmount(address(token), _maxCost(POSTOP_CAP));
        assertLt(r.tokensPaid, maxTokenCost, "unused pre-charge refunded");
    }

    function testFuzz_Permit2Paymaster_NoNetLossUpToPostOpCap(uint128 postOpGasLimit) public {
        postOpGasLimit = uint128(bound(postOpGasLimit, 20_000, POSTOP_CAP));
        Result memory r = _runToken(_permit2PaymasterAndData(postOpGasLimit), address(permit2Paymaster));
        assertLe(r.depositDecrease, r.tokenValue, "deposit paid more than the tokens collected are worth");
    }

    // ============ SponsorPaymaster ============

    function test_SponsorPaymaster_RejectsPostOpGasLimitRaisedAfterSigning() public {
        // Sponsor signs with a 50k postOp limit; the user raises it, the signature still matches
        PackedUserOperation memory op = _sponsorOp(50_000, POSTOP_CAP + 1);
        _expectPostOpLimitRejected(op, POSTOP_CAP + 1);
    }

    function test_SponsorPaymaster_RecordedSpendingCoversDepositAtPostOpCap() public {
        PackedUserOperation memory op = _sponsorOp(50_000, POSTOP_CAP);
        uint256 depositBefore = entryPoint.balanceOf(address(sponsorPaymaster));
        _handleOp(op);
        uint256 depositDecrease = depositBefore - entryPoint.balanceOf(address(sponsorPaymaster));
        uint256 recorded = sponsorPaymaster.userCampaignSpending(SPONSOR_CAMPAIGN, address(account));
        assertGe(recorded, depositDecrease, "recorded spending below deposit spent");
        assertEq(sponsorPaymaster.campaignSpending(SPONSOR_CAMPAIGN), recorded, "campaign total");
        assertLe(recorded, _maxCost(POSTOP_CAP), "recorded spending above the reserved max cost");
    }

    // ============ Helpers ============

    bytes32 internal constant SPONSOR_CAMPAIGN = bytes32(uint256(7));

    /// @dev Sponsor-signed op with `signedLimit`, then sent with `sentLimit` and the same signature
    function _sponsorOp(uint128 signedLimit, uint128 sentLimit) internal view returns (PackedUserOperation memory op) {
        op = _userOp("");
        bytes memory payload = PaymasterPayload.encodeSponsor(
            PaymasterPayload.SponsorPayload({
                campaignId: SPONSOR_CAMPAIGN,
                perUserLimit: 1 ether,
                targetContract: address(0),
                targetSelector: bytes4(0),
                sponsorExtra: ""
            })
        );
        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.SPONSOR), 0, uint48(block.timestamp + 1 hours), 0, 0, payload
        );
        op.paymasterAndData = abi.encodePacked(address(sponsorPaymaster), uint128(200_000), signedLimit, envelope);
        bytes32 hash = sponsorPaymaster.getHash(op, envelope);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(hash));
        op.paymasterAndData =
            abi.encodePacked(address(sponsorPaymaster), uint128(200_000), sentLimit, envelope, r, s, v);
    }

    function _runToken(bytes memory paymasterAndData, address paymaster) internal returns (Result memory r) {
        PackedUserOperation memory op = _userOp(paymasterAndData);
        uint256 depositBefore = entryPoint.balanceOf(paymaster);
        uint256 tokensBefore = token.balanceOf(address(account));
        _handleOp(op);
        r.depositDecrease = depositBefore - entryPoint.balanceOf(paymaster);
        r.tokensPaid = tokensBefore - token.balanceOf(address(account));
        r.tokenValue = r.tokensPaid * TOKEN_PRICE / 1e6;
    }

    function _expectPostOpLimitRejected(PackedUserOperation memory op, uint256 limit) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        // Selector spelled out so the test compiles against the contracts from before the cap
        bytes memory inner =
            abi.encodeWithSelector(bytes4(keccak256("PostOpGasLimitTooHigh(uint256,uint256)")), limit, POSTOP_CAP);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOpWithRevert.selector, 0, "AA33 reverted", inner));
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, payable(bundler));
    }

    function _handleOp(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, payable(bundler));
    }

    /// @dev Prefund the EntryPoint requires for _userOp with the given postOp gas limit
    function _maxCost(uint256 postOpGasLimit) internal pure returns (uint256) {
        return (200_000 + 200_000 + 50_000 + 200_000 + postOpGasLimit) * GAS_PRICE;
    }

    function _userOp(bytes memory paymasterAndData) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(account),
            nonce: entryPoint.getNonce(address(account), 0),
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(uint256(200_000) << 128 | uint256(200_000)),
            preVerificationGas: 50_000,
            gasFees: bytes32(uint256(GAS_PRICE) << 128 | uint256(GAS_PRICE)),
            paymasterAndData: paymasterAndData,
            signature: abi.encodePacked(accountOwner)
        });
    }

    function _erc20PaymasterAndData(uint128 postOpGasLimit) internal view returns (bytes memory) {
        bytes memory payload = PaymasterPayload.encodeErc20(
            PaymasterPayload.Erc20Payload({ token: address(token), maxTokenCost: 0, quoteId: 0, erc20Extra: "" })
        );
        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.ERC20), 0, uint48(block.timestamp + 1 hours), 0, uint64(0), payload
        );
        return abi.encodePacked(address(erc20Paymaster), uint128(200_000), postOpGasLimit, envelope);
    }

    function _permit2PaymasterAndData(uint128 postOpGasLimit) internal view returns (bytes memory) {
        uint48 expiration = uint48(block.timestamp + 1 hours);
        bytes memory payload = PaymasterPayload.encodePermit2(
            PaymasterPayload.Permit2Payload({
                token: address(token),
                permitAmount: type(uint160).max,
                permitExpiration: expiration,
                permitNonce: 0,
                permitSig: new bytes(65),
                permit2Extra: ""
            })
        );
        bytes memory envelope = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.PERMIT2), 0, expiration, 0, uint64(0), payload
        );
        return abi.encodePacked(address(permit2Paymaster), uint128(200_000), postOpGasLimit, envelope);
    }
}
