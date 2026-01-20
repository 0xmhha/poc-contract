// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SecureBridge} from "../../src/bridge/SecureBridge.sol";
import {BridgeValidator} from "../../src/bridge/BridgeValidator.sol";
import {OptimisticVerifier} from "../../src/bridge/OptimisticVerifier.sol";
import {BridgeRateLimiter} from "../../src/bridge/BridgeRateLimiter.sol";
import {BridgeGuardian} from "../../src/bridge/BridgeGuardian.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is IERC20 {
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

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract SecureBridgeTest is Test {
    SecureBridge public bridge;
    BridgeValidator public validator;
    OptimisticVerifier public optimisticVerifier;
    BridgeRateLimiter public rateLimiter;
    BridgeGuardian public guardian;
    MockERC20 public token;

    address public owner;
    address public feeRecipient;
    address[] public signers;
    uint256[] public signerKeys;
    address[] public guardians;

    uint256 public constant SIGNER_COUNT = 7;
    uint256 public constant SIGNER_THRESHOLD = 5;
    uint256 public constant GUARDIAN_COUNT = 5;
    uint256 public constant GUARDIAN_THRESHOLD = 3;
    uint256 public constant TARGET_CHAIN = 137;
    uint256 public constant PRECISION = 1e18;

    event BridgeInitiated(
        bytes32 indexed requestId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 sourceChain,
        uint256 targetChain,
        uint256 fee
    );
    event BridgeCompleted(bytes32 indexed requestId, address indexed recipient, address token, uint256 amount);
    event BridgeRefunded(bytes32 indexed requestId, address indexed sender, address token, uint256 amount);

    function setUp() public {
        owner = makeAddr("owner");
        feeRecipient = makeAddr("feeRecipient");

        // Create signers
        for (uint256 i = 0; i < SIGNER_COUNT; i++) {
            uint256 privateKey = uint256(keccak256(abi.encodePacked("signer", i)));
            signerKeys.push(privateKey);
            signers.push(vm.addr(privateKey));
        }

        // Create guardians
        for (uint256 i = 0; i < GUARDIAN_COUNT; i++) {
            guardians.push(makeAddr(string(abi.encodePacked("guardian", i))));
        }

        vm.startPrank(owner);

        // Deploy components
        validator = new BridgeValidator(signers, SIGNER_THRESHOLD);
        optimisticVerifier = new OptimisticVerifier(6 hours, 1 ether, 0.5 ether);
        rateLimiter = new BridgeRateLimiter();
        guardian = new BridgeGuardian(guardians, GUARDIAN_THRESHOLD);

        // Deploy bridge
        bridge = new SecureBridge(
            address(validator),
            payable(address(optimisticVerifier)),
            address(rateLimiter),
            address(guardian),
            feeRecipient
        );

        // Configure components
        optimisticVerifier.setAuthorizedCaller(address(bridge), true);
        rateLimiter.setAuthorizedCaller(address(bridge), true);
        guardian.setBridgeTarget(address(bridge));

        // Configure token
        token = new MockERC20();
        rateLimiter.configureToken(address(token), 1 * PRECISION, 18);

        // Configure native ETH
        rateLimiter.configureToken(address(0), 2000 * PRECISION, 18);

        // Set supported chain
        bridge.setSupportedChain(TARGET_CHAIN, true);

        vm.stopPrank();

        // Fund optimistic verifier for rewards
        vm.deal(address(optimisticVerifier), 10 ether);
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertEq(address(bridge.bridgeValidator()), address(validator));
        assertEq(address(bridge.optimisticVerifier()), address(optimisticVerifier));
        assertEq(address(bridge.rateLimiter()), address(rateLimiter));
        assertEq(address(bridge.guardian()), address(guardian));
        assertEq(bridge.feeRecipient(), feeRecipient);
        assertEq(bridge.CHAIN_ID(), block.chainid);
    }

    function test_Constructor_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SecureBridge.ZeroAddress.selector);
        new SecureBridge(
            address(0),
            payable(address(optimisticVerifier)),
            address(rateLimiter),
            address(guardian),
            feeRecipient
        );
    }

    // ============ Initiate Bridge Tests ============

    function test_InitiateBridge_ERC20() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        uint256 amount = 1000 * 1e18;

        // Mint and approve tokens
        token.mint(sender, amount);
        vm.prank(sender);
        token.approve(address(bridge), amount);

        vm.prank(sender);
        bytes32 requestId = bridge.initiateBridge(address(token), amount, recipient, TARGET_CHAIN, block.timestamp + 1 hours);

        assertNotEq(requestId, bytes32(0));
        assertEq(token.balanceOf(address(bridge)), amount);
    }

    function test_InitiateBridge_Native() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        uint256 amount = 1 ether;

        vm.deal(sender, amount);

        vm.prank(sender);
        bytes32 requestId =
            bridge.initiateBridge{value: amount}(address(0), amount, recipient, TARGET_CHAIN, block.timestamp + 1 hours);

        assertNotEq(requestId, bytes32(0));
        assertEq(address(bridge).balance, amount);
    }

    function test_InitiateBridge_CalculatesFee() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        uint256 amount = 10_000 * 1e18;

        token.mint(sender, amount);
        vm.prank(sender);
        token.approve(address(bridge), amount);

        vm.prank(sender);
        bridge.initiateBridge(address(token), amount, recipient, TARGET_CHAIN, block.timestamp + 1 hours);

        // Fee is 10 bps = 0.1%
        uint256 expectedFee = amount / 1000;
        assertEq(bridge.feesCollected(address(token)), expectedFee);
    }

    function test_InitiateBridge_RevertsOnZeroAmount() public {
        vm.expectRevert(SecureBridge.InvalidAmount.selector);
        bridge.initiateBridge(address(token), 0, makeAddr("recipient"), TARGET_CHAIN, block.timestamp + 1 hours);
    }

    function test_InitiateBridge_RevertsOnZeroRecipient() public {
        vm.expectRevert(SecureBridge.InvalidRecipient.selector);
        bridge.initiateBridge(address(token), 1000, address(0), TARGET_CHAIN, block.timestamp + 1 hours);
    }

    function test_InitiateBridge_RevertsOnUnsupportedChain() public {
        vm.expectRevert(SecureBridge.UnsupportedChain.selector);
        bridge.initiateBridge(address(token), 1000, makeAddr("recipient"), 999, block.timestamp + 1 hours);
    }

    function test_InitiateBridge_RevertsOnExpiredDeadline() public {
        vm.expectRevert(SecureBridge.InvalidDeadline.selector);
        bridge.initiateBridge(address(token), 1000, makeAddr("recipient"), TARGET_CHAIN, block.timestamp - 1);
    }

    function test_InitiateBridge_RevertsWhenGuardianPaused() public {
        // Guardian pauses
        vm.prank(guardians[0]);
        guardian.emergencyPause("Emergency");

        address sender = makeAddr("sender");
        token.mint(sender, 1000 * 1e18);

        vm.prank(sender);
        token.approve(address(bridge), 1000 * 1e18);

        vm.prank(sender);
        vm.expectRevert(SecureBridge.GuardianPaused.selector);
        bridge.initiateBridge(address(token), 1000 * 1e18, makeAddr("recipient"), TARGET_CHAIN, block.timestamp + 1 hours);
    }

    function test_InitiateBridge_RevertsWhenSenderBlacklisted() public {
        address sender = makeAddr("blacklistedSender");

        // Blacklist sender through guardian
        _blacklistAddress(sender);

        token.mint(sender, 1000 * 1e18);
        vm.prank(sender);
        token.approve(address(bridge), 1000 * 1e18);

        vm.prank(sender);
        vm.expectRevert(SecureBridge.Blacklisted.selector);
        bridge.initiateBridge(address(token), 1000 * 1e18, makeAddr("recipient"), TARGET_CHAIN, block.timestamp + 1 hours);
    }

    // ============ Complete Bridge Tests ============

    function test_CompleteBridge() public {
        // First initiate on "source chain"
        (bytes32 requestId, address sender, address recipient, uint256 amount) = _initiateBridge();

        // Approve in optimistic verifier
        vm.warp(block.timestamp + 7 hours); // Past challenge period
        optimisticVerifier.approveRequest(requestId);

        // Complete bridge
        BridgeValidator.BridgeMessage memory message = BridgeValidator.BridgeMessage({
            requestId: requestId,
            sender: sender,
            recipient: recipient,
            token: address(token),
            amount: amount - (amount / 1000), // After fee
            sourceChain: block.chainid,
            targetChain: block.chainid,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes[] memory signatures = _signMessage(message);

        // Mint tokens to bridge for release
        token.mint(address(bridge), amount);

        bridge.completeBridge(
            requestId, sender, recipient, address(token), message.amount, block.chainid, 0, message.deadline, signatures
        );

        assertGt(token.balanceOf(recipient), 0);
    }

    function test_CompleteBridge_RevertsOnInvalidSignatures() public {
        (bytes32 requestId, address sender, address recipient, uint256 amount) = _initiateBridge();

        vm.warp(block.timestamp + 7 hours);
        optimisticVerifier.approveRequest(requestId);

        bytes[] memory badSignatures = new bytes[](SIGNER_THRESHOLD);
        for (uint256 i = 0; i < SIGNER_THRESHOLD; i++) {
            badSignatures[i] = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        }

        // The underlying ECDSA library may throw ECDSAInvalidSignature for malformed signatures
        // before reaching SecureBridge's InvalidSignatures check
        vm.expectRevert();
        bridge.completeBridge(
            requestId,
            sender,
            recipient,
            address(token),
            amount - (amount / 1000),
            block.chainid,
            0,
            block.timestamp + 1 hours,
            badSignatures
        );
    }

    function test_CompleteBridge_RevertsOnNotApproved() public {
        (bytes32 requestId, address sender, address recipient, uint256 amount) = _initiateBridge();

        // Don't approve - it's still pending

        BridgeValidator.BridgeMessage memory message = BridgeValidator.BridgeMessage({
            requestId: requestId,
            sender: sender,
            recipient: recipient,
            token: address(token),
            amount: amount - (amount / 1000),
            sourceChain: block.chainid,
            targetChain: block.chainid,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes[] memory signatures = _signMessage(message);

        vm.expectRevert(SecureBridge.RequestNotApproved.selector);
        bridge.completeBridge(
            requestId, sender, recipient, address(token), message.amount, block.chainid, 0, message.deadline, signatures
        );
    }

    // ============ Refund Bridge Tests ============

    function test_RefundBridge() public {
        (bytes32 requestId, address sender,, uint256 amount) = _initiateBridge();

        // Challenge and resolve as successful challenge
        address challenger = makeAddr("challenger");
        vm.deal(challenger, 2 ether);
        vm.prank(challenger);
        optimisticVerifier.challengeRequest{value: 1 ether}(requestId, "Fraud detected");

        vm.prank(owner);
        optimisticVerifier.setFraudProofVerifier(owner);

        vm.prank(owner);
        optimisticVerifier.resolveChallenge(requestId, true);

        // Refund
        uint256 senderBalanceBefore = token.balanceOf(sender);
        bridge.refundBridge(requestId);

        uint256 fee = amount / 1000;
        uint256 expectedRefund = amount - fee;
        assertEq(token.balanceOf(sender), senderBalanceBefore + expectedRefund);
    }

    function test_RefundBridge_RevertsOnNotRefundedStatus() public {
        (bytes32 requestId,,,) = _initiateBridge();

        // Request is still pending, not refunded
        vm.expectRevert(SecureBridge.RequestNotApproved.selector);
        bridge.refundBridge(requestId);
    }

    // ============ Admin Functions Tests ============

    function test_SetSupportedChain() public {
        vm.prank(owner);
        bridge.setSupportedChain(56, true);

        assertTrue(bridge.supportedChains(56));
    }

    function test_SetTokenMapping() public {
        address sourceToken = makeAddr("sourceToken");
        address targetToken = makeAddr("targetToken");

        vm.prank(owner);
        bridge.setTokenMapping(sourceToken, TARGET_CHAIN, targetToken);

        assertEq(bridge.getTargetToken(sourceToken, TARGET_CHAIN), targetToken);
    }

    function test_SetBridgeFee() public {
        vm.prank(owner);
        bridge.setBridgeFee(20); // 0.2%

        assertEq(bridge.bridgeFeeBps(), 20);
    }

    function test_SetFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");

        vm.prank(owner);
        bridge.setFeeRecipient(newRecipient);

        assertEq(bridge.feeRecipient(), newRecipient);
    }

    function test_WithdrawFees() public {
        // Generate some fees
        address sender = makeAddr("sender");
        token.mint(sender, 10_000 * 1e18);
        vm.prank(sender);
        token.approve(address(bridge), 10_000 * 1e18);

        vm.prank(sender);
        bridge.initiateBridge(address(token), 10_000 * 1e18, makeAddr("recipient"), TARGET_CHAIN, block.timestamp + 1 hours);

        uint256 fees = bridge.feesCollected(address(token));
        assertGt(fees, 0);

        uint256 recipientBalanceBefore = token.balanceOf(feeRecipient);

        vm.prank(owner);
        bridge.withdrawFees(address(token), fees);

        assertEq(token.balanceOf(feeRecipient), recipientBalanceBefore + fees);
    }

    function test_EmergencyWithdraw() public {
        // Put some tokens in bridge
        token.mint(address(bridge), 1000 * 1e18);

        address emergencyRecipient = makeAddr("emergencyRecipient");

        vm.prank(owner);
        bridge.emergencyWithdraw(address(token), emergencyRecipient, 500 * 1e18);

        assertEq(token.balanceOf(emergencyRecipient), 500 * 1e18);
    }

    // ============ View Functions Tests ============

    function test_GetDeposit() public {
        (bytes32 requestId, address sender,, uint256 amount) = _initiateBridge();

        SecureBridge.DepositInfo memory deposit = bridge.getDeposit(requestId);

        assertEq(deposit.sender, sender);
        assertEq(deposit.amount, amount);
        assertFalse(deposit.executed);
        assertFalse(deposit.refunded);
    }

    function test_GetUserNonce() public {
        address sender = makeAddr("sender");
        token.mint(sender, 2000 * 1e18);

        vm.prank(sender);
        token.approve(address(bridge), 2000 * 1e18);

        assertEq(bridge.getUserNonce(sender), 0);

        vm.prank(sender);
        bridge.initiateBridge(address(token), 1000 * 1e18, makeAddr("recipient"), TARGET_CHAIN, block.timestamp + 1 hours);

        assertEq(bridge.getUserNonce(sender), 1);

        vm.prank(sender);
        bridge.initiateBridge(address(token), 1000 * 1e18, makeAddr("recipient"), TARGET_CHAIN, block.timestamp + 1 hours);

        assertEq(bridge.getUserNonce(sender), 2);
    }

    function test_CalculateFee() public view {
        uint256 amount = 10_000 * 1e18;
        uint256 fee = bridge.calculateFee(amount);

        assertEq(fee, 10 * 1e18); // 0.1% of 10,000
    }

    function test_IsOperational() public {
        assertTrue(bridge.isOperational());

        // Pause bridge
        vm.prank(owner);
        bridge.pause();
        assertFalse(bridge.isOperational());

        vm.prank(owner);
        bridge.unpause();
        assertTrue(bridge.isOperational());

        // Guardian pause
        vm.prank(guardians[0]);
        guardian.emergencyPause("test");
        assertFalse(bridge.isOperational());
    }

    function test_GetTvl() public {
        address sender = makeAddr("sender");
        token.mint(sender, 10_000 * 1e18);

        vm.prank(sender);
        token.approve(address(bridge), 10_000 * 1e18);

        vm.prank(sender);
        bridge.initiateBridge(address(token), 10_000 * 1e18, makeAddr("recipient"), TARGET_CHAIN, block.timestamp + 1 hours);

        uint256 fee = 10_000 * 1e18 / 1000;
        uint256 expectedTvl = 10_000 * 1e18 - fee;
        assertEq(bridge.getTvl(address(token)), expectedTvl);
    }

    // ============ Component Update Tests ============

    function test_SetBridgeValidator() public {
        address newValidator = makeAddr("newValidator");

        vm.prank(owner);
        bridge.setBridgeValidator(newValidator);

        assertEq(address(bridge.bridgeValidator()), newValidator);
    }

    function test_SetOptimisticVerifier() public {
        address newVerifier = makeAddr("newVerifier");

        vm.prank(owner);
        bridge.setOptimisticVerifier(payable(newVerifier));

        assertEq(address(bridge.optimisticVerifier()), newVerifier);
    }

    function test_SetRateLimiter() public {
        address newLimiter = makeAddr("newLimiter");

        vm.prank(owner);
        bridge.setRateLimiter(newLimiter);

        assertEq(address(bridge.rateLimiter()), newLimiter);
    }

    function test_SetGuardian() public {
        address newGuardian = makeAddr("newGuardian");

        vm.prank(owner);
        bridge.setGuardian(newGuardian);

        assertEq(address(bridge.guardian()), newGuardian);
    }

    // ============ Pause Tests ============

    function test_Pause() public {
        vm.prank(owner);
        bridge.pause();

        address sender = makeAddr("sender");
        token.mint(sender, 1000 * 1e18);
        vm.prank(sender);
        token.approve(address(bridge), 1000 * 1e18);

        vm.prank(sender);
        vm.expectRevert();
        bridge.initiateBridge(address(token), 1000 * 1e18, makeAddr("recipient"), TARGET_CHAIN, block.timestamp + 1 hours);
    }

    // ============ Helper Functions ============

    function _initiateBridge() internal returns (bytes32 requestId, address sender, address recipient, uint256 amount) {
        sender = makeAddr("bridgeSender");
        recipient = makeAddr("bridgeRecipient");
        amount = 1000 * 1e18;

        token.mint(sender, amount);
        vm.prank(sender);
        token.approve(address(bridge), amount);

        vm.prank(sender);
        requestId = bridge.initiateBridge(address(token), amount, recipient, TARGET_CHAIN, block.timestamp + 1 hours);
    }

    function _signMessage(BridgeValidator.BridgeMessage memory message) internal view returns (bytes[] memory) {
        bytes32 messageHash = validator.hashBridgeMessage(message);
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        bytes[] memory signatures = new bytes[](SIGNER_THRESHOLD);
        for (uint256 i = 0; i < SIGNER_THRESHOLD; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKeys[i], ethSignedHash);
            signatures[i] = abi.encodePacked(r, s, v);
        }

        return signatures;
    }

    function _blacklistAddress(address target) internal {
        // Create and approve blacklist proposal
        vm.prank(guardians[0]);
        uint256 proposalId =
            guardian.createProposal(BridgeGuardian.ProposalType.Blacklist, target, abi.encode("Suspicious"));

        vm.prank(guardians[1]);
        guardian.approveProposal(proposalId);

        vm.prank(guardians[2]);
        guardian.approveProposal(proposalId);

        vm.prank(guardians[0]);
        guardian.executeProposal(proposalId);
    }
}
