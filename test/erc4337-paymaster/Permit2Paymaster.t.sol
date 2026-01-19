// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Permit2Paymaster} from "../../src/erc4337-paymaster/Permit2Paymaster.sol";
import {IPriceOracle} from "../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";
import {IPermit2} from "../../src/erc4337-paymaster/interfaces/IPermit2.sol";
import {IEntryPoint} from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import {EntryPoint} from "../../src/erc4337-entrypoint/EntryPoint.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";

contract Permit2PaymasterTest is Test {
    Permit2Paymaster public paymaster;
    EntryPoint public entryPoint;
    MockPriceOracle public oracle;
    MockERC20 public token;
    MockPermit2 public permit2;

    address public owner;
    address public user;
    uint256 public userPrivateKey;

    uint256 constant INITIAL_DEPOSIT = 10 ether;
    uint256 constant INITIAL_MARKUP = 1000; // 10%

    function setUp() public {
        owner = makeAddr("owner");
        userPrivateKey = 0xBEEF;
        user = vm.addr(userPrivateKey);

        // Deploy EntryPoint
        entryPoint = new EntryPoint();

        // Deploy mock contracts
        oracle = new MockPriceOracle();
        token = new MockERC20("Mock USDC", "MUSDC", 6);
        permit2 = new MockPermit2();

        // Set token price: 1 USDC = 0.0005 ETH (i.e., 2000 USDC per ETH)
        oracle.setPrice(address(token), 5e14);

        // Deploy Permit2Paymaster
        vm.prank(owner);
        paymaster = new Permit2Paymaster(
            IEntryPoint(address(entryPoint)),
            owner,
            IPermit2(address(permit2)),
            IPriceOracle(address(oracle)),
            INITIAL_MARKUP
        );

        // Setup token
        vm.prank(owner);
        paymaster.setSupportedToken(address(token), true);

        // Fund paymaster with ETH
        vm.deal(owner, 100 ether);
        vm.prank(owner);
        paymaster.deposit{value: INITIAL_DEPOSIT}();

        // Mint tokens to user
        token.mint(user, 1_000_000e6);

        // User approves Permit2 (in real scenario, users approve Permit2 once)
        vm.prank(user);
        token.approve(address(permit2), type(uint256).max);
    }

    function test_constructor() public view {
        assertEq(address(paymaster.ENTRYPOINT()), address(entryPoint));
        assertEq(paymaster.owner(), owner);
        assertEq(address(paymaster.oracle()), address(oracle));
        assertEq(paymaster.markup(), INITIAL_MARKUP);
        assertEq(paymaster.getPermit2(), address(permit2));
    }

    function test_constructor_revertIfPermit2Zero() public {
        vm.prank(owner);
        vm.expectRevert(Permit2Paymaster.Permit2CannotBeZero.selector);
        new Permit2Paymaster(
            IEntryPoint(address(entryPoint)),
            owner,
            IPermit2(address(0)),
            IPriceOracle(address(oracle)),
            INITIAL_MARKUP
        );
    }

    function test_constructor_revertIfOracleZero() public {
        vm.prank(owner);
        vm.expectRevert(Permit2Paymaster.OracleCannotBeZero.selector);
        new Permit2Paymaster(
            IEntryPoint(address(entryPoint)),
            owner,
            IPermit2(address(permit2)),
            IPriceOracle(address(0)),
            INITIAL_MARKUP
        );
    }

    function test_constructor_revertIfInvalidMarkup() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Permit2Paymaster.InvalidMarkup.selector, 100));
        new Permit2Paymaster(
            IEntryPoint(address(entryPoint)),
            owner,
            IPermit2(address(permit2)),
            IPriceOracle(address(oracle)),
            100 // Too low
        );
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

    function test_setMarkup() public {
        uint256 newMarkup = 2000; // 20%

        vm.prank(owner);
        paymaster.setMarkup(newMarkup);

        assertEq(paymaster.markup(), newMarkup);
    }

    function test_setSupportedToken() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);

        vm.prank(owner);
        paymaster.setSupportedToken(address(newToken), true);

        assertTrue(paymaster.isTokenSupported(address(newToken)));
        assertEq(paymaster.tokenDecimals(address(newToken)), 18);
    }

    function test_getTokenAmount() public view {
        uint256 ethCost = 1 ether;
        uint256 tokenAmount = paymaster.getTokenAmount(address(token), ethCost);

        // Token price = 0.0005 ETH per token
        // 1 ETH / 0.0005 = 2000 tokens
        // With 10% markup: 2000 * 1.1 = 2200 tokens
        // Token has 6 decimals: 2200e6
        assertEq(tokenAmount, 2200e6);
    }

    function test_getQuote() public view {
        uint256 gasLimit = 100000;
        uint256 maxFeePerGas = 10 gwei;

        uint256 quote = paymaster.getQuote(address(token), gasLimit, maxFeePerGas);

        // maxCost = 100000 * 10 gwei = 0.001 ETH
        // tokenAmount = 0.001 ETH / 0.0005 * 1.1 = 2.2 tokens = 2.2e6
        assertEq(quote, 2.2e6);
    }

    function test_validatePaymasterUserOp_success() public {
        PackedUserOperation memory userOp = _createSampleUserOp(user, address(token));

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            0.001 ether
        );

        assertTrue(context.length > 0);
        assertEq(validationData, 0); // Success
    }

    function test_validatePaymasterUserOp_withExistingAllowance() public {
        // Set existing allowance via Permit2
        permit2.setAllowance(
            user,
            address(token),
            address(paymaster),
            type(uint160).max,
            uint48(block.timestamp + 1 hours),
            0
        );

        // Make permit fail to test existing allowance fallback
        permit2.setShouldFailPermit(true);

        PackedUserOperation memory userOp = _createSampleUserOp(user, address(token));

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            0.001 ether
        );

        assertTrue(context.length > 0);
        assertEq(validationData, 0);
    }

    function test_validatePaymasterUserOp_revertIfUnsupportedToken() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS", 18);
        PackedUserOperation memory userOp = _createSampleUserOp(user, address(unsupportedToken));

        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(
            Permit2Paymaster.UnsupportedToken.selector,
            address(unsupportedToken)
        ));
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);
    }

    function test_validatePaymasterUserOp_revertIfPermitFailedAndNoAllowance() public {
        permit2.setShouldFailPermit(true);

        PackedUserOperation memory userOp = _createSampleUserOp(user, address(token));

        vm.prank(address(entryPoint));
        vm.expectRevert(Permit2Paymaster.PermitFailed.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);
    }

    function test_validatePaymasterUserOp_revertIfInvalidDataLength() public {
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: user,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(uint256(100000) << 128 | uint256(100000)),
            preVerificationGas: 21000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: abi.encodePacked(
                address(paymaster),
                uint128(100000),
                uint128(50000),
                bytes20(address(token)) // Only 20 bytes, not enough
            ),
            signature: ""
        });

        vm.prank(address(entryPoint));
        vm.expectRevert(Permit2Paymaster.InvalidPaymasterDataLength.selector);
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
        // Warp to a reasonable timestamp
        vm.warp(1000000);

        // Set stale price (2 hours ago)
        oracle.setPriceWithTimestamp(address(token), 5e14, block.timestamp - 2 hours);

        PackedUserOperation memory userOp = _createSampleUserOp(user, address(token));

        vm.prank(address(entryPoint));
        vm.expectRevert(); // StalePrice
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);
    }

    // ============ Helper Functions ============

    function _createSampleUserOp(
        address sender,
        address payToken
    ) internal view returns (PackedUserOperation memory) {
        // Create paymaster data
        // [0:20] token, [20:40] amount, [40:46] expiration, [46:52] nonce, [52:117] signature
        uint160 permitAmount = type(uint160).max;
        uint48 expiration = uint48(block.timestamp + 1 hours);
        uint48 nonce = 0;
        bytes memory signature = new bytes(65); // Dummy signature for mock

        bytes memory paymasterData = abi.encodePacked(
            bytes20(payToken),
            bytes20(uint160(permitAmount)),
            bytes6(expiration),
            bytes6(nonce),
            signature
        );

        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(uint256(100000) << 128 | uint256(100000)),
            preVerificationGas: 21000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: abi.encodePacked(
                address(paymaster),
                uint128(100000), // verification gas
                uint128(50000),  // post-op gas
                paymasterData
            ),
            signature: ""
        });
    }
}
