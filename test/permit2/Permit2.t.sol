// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Permit2} from "../../src/permit2/Permit2.sol";
import {ISignatureTransfer} from "../../src/permit2/interfaces/ISignatureTransfer.sol";
import {IAllowanceTransfer} from "../../src/permit2/interfaces/IAllowanceTransfer.sol";
import {PermitHash} from "../../src/permit2/libraries/PermitHash.sol";

// Mock ERC20 token for testing
contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Permit2Test is Test {
    Permit2 public permit2;
    MockERC20 public token;

    address public owner;
    uint256 public ownerPrivateKey;
    address public spender;
    address public recipient;

    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    function setUp() public {
        // Setup accounts
        ownerPrivateKey = 0xA11CE;
        owner = vm.addr(ownerPrivateKey);
        spender = makeAddr("spender");
        recipient = makeAddr("recipient");

        // Deploy contracts
        permit2 = new Permit2();
        token = new MockERC20();

        // Mint tokens to owner
        token.mint(owner, 1000 ether);

        // Owner approves Permit2
        vm.prank(owner);
        token.approve(address(permit2), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Deployment() public view {
        assertNotEq(address(permit2), address(0));
        assertNotEq(permit2.DOMAIN_SEPARATOR(), bytes32(0));
    }

    function test_DomainSeparator() public view {
        bytes32 expectedDomainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Permit2"), block.chainid, address(permit2))
        );
        assertEq(permit2.DOMAIN_SEPARATOR(), expectedDomainSeparator);
    }

    function test_DomainSeparatorChangesWithChainId() public {
        bytes32 originalDomainSeparator = permit2.DOMAIN_SEPARATOR();

        // Fork to different chain
        vm.chainId(999);

        bytes32 newDomainSeparator = permit2.DOMAIN_SEPARATOR();
        assertNotEq(originalDomainSeparator, newDomainSeparator);

        // Verify new domain separator is calculated correctly
        bytes32 expected = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Permit2"), 999, address(permit2)));
        assertEq(newDomainSeparator, expected);
    }

    /*//////////////////////////////////////////////////////////////
                        ALLOWANCE TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AllowanceApprove() public {
        uint160 amount = 100 ether;
        uint48 expiration = uint48(block.timestamp + 1 hours);

        vm.prank(owner);
        permit2.approve(address(token), spender, amount, expiration);

        (uint160 allowedAmount, uint48 allowedExpiration, uint48 nonce) =
            permit2.allowance(owner, address(token), spender);

        assertEq(allowedAmount, amount);
        assertEq(allowedExpiration, expiration);
        assertEq(nonce, 0);
    }

    function test_AllowanceTransferFrom() public {
        uint160 amount = 100 ether;
        uint48 expiration = uint48(block.timestamp + 1 hours);

        // Owner approves spender via Permit2
        vm.prank(owner);
        permit2.approve(address(token), spender, amount, expiration);

        // Spender transfers tokens
        vm.prank(spender);
        permit2.transferFrom(owner, recipient, uint160(50 ether), address(token));

        assertEq(token.balanceOf(recipient), 50 ether);
        assertEq(token.balanceOf(owner), 950 ether);

        // Check updated allowance
        (uint160 remainingAmount,,) = permit2.allowance(owner, address(token), spender);
        assertEq(remainingAmount, 50 ether);
    }

    function test_AllowanceTransferFrom_RevertExpired() public {
        uint160 amount = 100 ether;
        uint48 expiration = uint48(block.timestamp + 1 hours);

        vm.prank(owner);
        permit2.approve(address(token), spender, amount, expiration);

        // Warp past expiration
        vm.warp(block.timestamp + 2 hours);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSignature("AllowanceExpired(uint256)", expiration));
        permit2.transferFrom(owner, recipient, uint160(50 ether), address(token));
    }

    function test_AllowanceTransferFrom_RevertInsufficientAllowance() public {
        uint160 amount = 100 ether;
        uint48 expiration = uint48(block.timestamp + 1 hours);

        vm.prank(owner);
        permit2.approve(address(token), spender, amount, expiration);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSignature("InsufficientAllowance(uint256)", amount));
        permit2.transferFrom(owner, recipient, uint160(200 ether), address(token));
    }

    function test_AllowanceLockdown() public {
        uint160 amount = 100 ether;
        uint48 expiration = uint48(block.timestamp + 1 hours);

        vm.prank(owner);
        permit2.approve(address(token), spender, amount, expiration);

        // Lockdown specific token approval
        IAllowanceTransfer.TokenSpenderPair[] memory approvals = new IAllowanceTransfer.TokenSpenderPair[](1);
        approvals[0] = IAllowanceTransfer.TokenSpenderPair({token: address(token), spender: spender});

        vm.prank(owner);
        permit2.lockdown(approvals);

        // Verify allowance is zeroed
        (uint160 allowedAmount,,) = permit2.allowance(owner, address(token), spender);
        assertEq(allowedAmount, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        SIGNATURE TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SignatureTransfer_PermitTransferFrom() public {
        uint256 amount = 100 ether;
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: amount}),
            nonce: nonce,
            deadline: deadline
        });

        ISignatureTransfer.SignatureTransferDetails memory transferDetails =
            ISignatureTransfer.SignatureTransferDetails({to: recipient, requestedAmount: amount});

        bytes memory signature = _signPermitTransferFrom(permit, spender);

        vm.prank(spender);
        permit2.permitTransferFrom(permit, transferDetails, owner, signature);

        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(owner), 900 ether);
    }

    function test_SignatureTransfer_RevertExpiredDeadline() public {
        uint256 amount = 100 ether;
        uint256 nonce = 0;
        uint256 deadline = block.timestamp - 1; // Expired

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: amount}),
            nonce: nonce,
            deadline: deadline
        });

        ISignatureTransfer.SignatureTransferDetails memory transferDetails =
            ISignatureTransfer.SignatureTransferDetails({to: recipient, requestedAmount: amount});

        bytes memory signature = _signPermitTransferFrom(permit, spender);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSignature("SignatureExpired(uint256)", deadline));
        permit2.permitTransferFrom(permit, transferDetails, owner, signature);
    }

    function test_SignatureTransfer_RevertInvalidNonce() public {
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;

        // First transfer
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: amount}),
            nonce: 0,
            deadline: deadline
        });

        ISignatureTransfer.SignatureTransferDetails memory transferDetails =
            ISignatureTransfer.SignatureTransferDetails({to: recipient, requestedAmount: amount});

        bytes memory signature = _signPermitTransferFrom(permit, spender);

        vm.prank(spender);
        permit2.permitTransferFrom(permit, transferDetails, owner, signature);

        // Try to reuse same nonce - should fail
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSignature("InvalidNonce()"));
        permit2.permitTransferFrom(permit, transferDetails, owner, signature);
    }

    function test_SignatureTransfer_InvalidateUnorderedNonces() public {
        uint256 wordPos = 0;
        uint256 mask = 1; // Invalidate nonce 0

        vm.prank(owner);
        permit2.invalidateUnorderedNonces(wordPos, mask);

        // Verify nonce is invalidated
        uint256 bitmap = permit2.nonceBitmap(owner, wordPos);
        assertEq(bitmap, 1);

        // Try to use invalidated nonce
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: amount}),
            nonce: 0,
            deadline: deadline
        });

        ISignatureTransfer.SignatureTransferDetails memory transferDetails =
            ISignatureTransfer.SignatureTransferDetails({to: recipient, requestedAmount: amount});

        bytes memory signature = _signPermitTransferFrom(permit, spender);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSignature("InvalidNonce()"));
        permit2.permitTransferFrom(permit, transferDetails, owner, signature);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _signPermitTransferFrom(ISignatureTransfer.PermitTransferFrom memory permit, address _spender)
        internal
        view
        returns (bytes memory)
    {
        bytes32 permitHash = keccak256(
            abi.encode(
                PermitHash._PERMIT_TRANSFER_FROM_TYPEHASH,
                keccak256(abi.encode(PermitHash._TOKEN_PERMISSIONS_TYPEHASH, permit.permitted)),
                _spender,
                permit.nonce,
                permit.deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), permitHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
