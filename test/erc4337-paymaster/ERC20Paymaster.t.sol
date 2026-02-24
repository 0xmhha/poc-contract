// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC20Paymaster } from "../../src/erc4337-paymaster/ERC20Paymaster.sol";
import { IPriceOracle } from "../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";
import { MockPriceOracle } from "./mocks/MockPriceOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { PaymasterDataLib } from "../../src/erc4337-paymaster/PaymasterDataLib.sol";
import { PaymasterPayload } from "../../src/erc4337-paymaster/PaymasterPayload.sol";

contract ERC20PaymasterTest is Test {
    ERC20Paymaster public paymaster;
    EntryPoint public entryPoint;
    MockPriceOracle public oracle;
    MockERC20 public token;

    address public owner;
    address public user;

    uint256 constant INITIAL_DEPOSIT = 10 ether;
    uint256 constant INITIAL_MARKUP = 1000; // 10%
    uint256 constant TOKEN_PRICE = 2000e18; // 1 token = 2000 ETH (stablecoin-like)

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");

        // Deploy EntryPoint
        entryPoint = new EntryPoint();

        // Deploy mock oracle
        oracle = new MockPriceOracle();

        // Deploy mock token (6 decimals like USDC)
        token = new MockERC20("Mock USDC", "MUSDC", 6);

        // Set token price: 1 USDC = 0.0005 ETH (i.e., 2000 USDC per ETH)
        // Price is in 18 decimals, representing ETH per token
        oracle.setPrice(address(token), 5e14); // 0.0005 ETH per token

        // Deploy ERC20Paymaster
        vm.prank(owner);
        paymaster = new ERC20Paymaster(
            IEntryPoint(address(entryPoint)), owner, IPriceOracle(address(oracle)), INITIAL_MARKUP
        );

        // Setup token
        vm.prank(owner);
        paymaster.setSupportedToken(address(token), true);

        // Fund paymaster with ETH
        vm.deal(owner, 100 ether);
        vm.prank(owner);
        paymaster.deposit{ value: INITIAL_DEPOSIT }();

        // Mint tokens to user
        token.mint(user, 1_000_000e6); // 1M tokens

        // User approves paymaster
        vm.prank(user);
        token.approve(address(paymaster), type(uint256).max);
    }

    function test_constructor() public view {
        assertEq(address(paymaster.ENTRYPOINT()), address(entryPoint));
        assertEq(paymaster.owner(), owner);
        assertEq(address(paymaster.oracle()), address(oracle));
        assertEq(paymaster.markup(), INITIAL_MARKUP);
    }

    function test_setOracle() public {
        MockPriceOracle newOracle = new MockPriceOracle();

        vm.prank(owner);
        paymaster.setOracle(IPriceOracle(address(newOracle)));

        assertEq(address(paymaster.oracle()), address(newOracle));
    }

    function test_setOracle_revertIfNotOwner() public {
        MockPriceOracle newOracle = new MockPriceOracle();

        vm.prank(user);
        vm.expectRevert();
        paymaster.setOracle(IPriceOracle(address(newOracle)));
    }

    function test_setOracle_revertIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ERC20Paymaster.OracleCannotBeZero.selector);
        paymaster.setOracle(IPriceOracle(address(0)));
    }

    function test_setMarkup() public {
        uint256 newMarkup = 2000; // 20%

        vm.prank(owner);
        paymaster.setMarkup(newMarkup);

        assertEq(paymaster.markup(), newMarkup);
    }

    function test_setMarkup_revertIfTooLow() public {
        uint256 lowMarkup = 100; //1%

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ERC20Paymaster.InvalidMarkup.selector, lowMarkup));
        paymaster.setMarkup(lowMarkup);
    }

    function test_setMarkup_revertIfTooHigh() public {
        uint256 highMarkup = 6000; // 60%

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ERC20Paymaster.InvalidMarkup.selector, highMarkup));
        paymaster.setMarkup(highMarkup);
    }

    function test_setSupportedToken() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);

        vm.prank(owner);
        paymaster.setSupportedToken(address(newToken), true);

        assertTrue(paymaster.isTokenSupported(address(newToken)));
        assertEq(paymaster.tokenDecimals(address(newToken)), 18);
    }

    function test_getTokenAmount() public view {
        uint256 ethCost = 1 ether; // 1 ETH
        uint256 tokenAmount = paymaster.getTokenAmount(address(token), ethCost);

        // Token price = 0.0005 ETH per token (5e14)
        // 1 ETH / 0.0005 = 2000 tokens
        // With 10% markup: 2000 * 1.1 = 2200 tokens
        // Token has 6 decimals: 2200e6
        assertEq(tokenAmount, 2200e6);
    }

    function test_getQuote() public view {
        uint256 gasLimit = 100_000;
        uint256 maxFeePerGas = 10 gwei;

        uint256 quote = paymaster.getQuote(address(token), gasLimit, maxFeePerGas);

        // maxCost = 100000 * 10 gwei = 0.001 ETH
        // tokenAmount = 0.001 ETH / 0.0005 * 1.1 = 2.2 tokens = 2.2e6
        assertEq(quote, 2.2e6);
    }

    function test_validatePaymasterUserOp_success() public {
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);
        PackedUserOperation memory userOp = _createSampleUserOp(user, address(token), validUntil, validAfter);

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) =
            paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);

        assertTrue(context.length > 0);
        // sigFail (lowest 20 bytes) should be 0 for success
        // forge-lint: disable-next-line(unsafe-typecast)
        address sigFail = address(uint160(validationData));
        assertEq(sigFail, address(0));
    }

    function test_validatePaymasterUserOp_revertIfUnsupportedToken() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS", 18);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);
        PackedUserOperation memory userOp = _createSampleUserOp(user, address(unsupportedToken), validUntil, validAfter);

        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(ERC20Paymaster.UnsupportedToken.selector, address(unsupportedToken)));
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);
    }

    function test_validatePaymasterUserOp_revertIfInsufficientBalance() public {
        // Burn user's tokens
        uint256 userBalance = token.balanceOf(user);
        vm.prank(user);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(address(1), userBalance);

        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);
        PackedUserOperation memory userOp = _createSampleUserOp(user, address(token), validUntil, validAfter);

        vm.prank(address(entryPoint));
        vm.expectRevert(); // InsufficientTokenBalance
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);
    }

    function test_validatePaymasterUserOp_revertIfInsufficientAllowance() public {
        // Revoke approval
        vm.prank(user);
        token.approve(address(paymaster), 0);

        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);
        PackedUserOperation memory userOp = _createSampleUserOp(user, address(token), validUntil, validAfter);

        vm.prank(address(entryPoint));
        vm.expectRevert(); // InsufficientTokenAllowance
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);
    }

    function test_withdrawTokens() public {
        // Transfer some tokens to paymaster
        token.mint(address(paymaster), 1000e6);

        address recipient = makeAddr("recipient");

        vm.prank(owner);
        paymaster.withdrawTokens(address(token), recipient, 500e6);

        assertEq(token.balanceOf(recipient), 500e6);
        assertEq(token.balanceOf(address(paymaster)), 500e6);
    }

    function test_stalePrice_reverts() public {
        // Warp to a reasonable timestamp to avoid underflow
        vm.warp(1_000_000);

        // Set stale price (2 hours ago)
        oracle.setPriceWithTimestamp(address(token), 5e14, block.timestamp - 2 hours);

        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = uint48(block.timestamp);
        PackedUserOperation memory userOp = _createSampleUserOp(user, address(token), validUntil, validAfter);

        vm.prank(address(entryPoint));
        vm.expectRevert(); // StalePrice
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);
    }

    function test_revertIfWrongPaymasterType() public {
        // Build envelope with wrong type (VERIFYING instead of ERC20)
        bytes memory payload = PaymasterPayload.encodeErc20(
            PaymasterPayload.Erc20Payload({ token: address(token), maxTokenCost: 0, quoteId: 0, erc20Extra: "" })
        );
        bytes memory envelopeData = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.VERIFYING),
            0,
            uint48(block.timestamp + 1 hours),
            uint48(block.timestamp),
            uint64(0),
            payload
        );

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: user,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(uint256(100_000) << 128 | uint256(100_000)),
            preVerificationGas: 21_000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: abi.encodePacked(address(paymaster), uint128(100_000), uint128(50_000), envelopeData),
            signature: ""
        });

        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(PaymasterDataLib.InvalidType.selector, uint8(0)));
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);
    }

    // ============ Helper Functions ============

    function _createSampleUserOp(address sender, address payToken, uint48 validUntil, uint48 validAfter)
        internal
        view
        returns (PackedUserOperation memory)
    {
        // Build Erc20Payload
        bytes memory payload = PaymasterPayload.encodeErc20(
            PaymasterPayload.Erc20Payload({ token: payToken, maxTokenCost: 0, quoteId: 0, erc20Extra: "" })
        );

        // Wrap in envelope
        bytes memory envelopeData = PaymasterDataLib.encode(
            uint8(PaymasterDataLib.PaymasterType.ERC20), 0, validUntil, validAfter, uint64(0), payload
        );

        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(uint256(100_000) << 128 | uint256(100_000)),
            preVerificationGas: 21_000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: abi.encodePacked(
                address(paymaster),
                uint128(100_000), // verification gas
                uint128(50_000), // post-op gas
                envelopeData
            ),
            signature: ""
        });
    }
}
