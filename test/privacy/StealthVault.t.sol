// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { StealthVault, IStealthVault } from "../../src/privacy/enterprise/StealthVault.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice Mock ERC20 for testing
 */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title StealthVaultTest
 * @notice Unit tests for StealthVault
 */
contract StealthVaultTest is Test {
    StealthVault public vault;
    MockERC20 public token;

    address public admin;
    address public depositor;
    address public recipient;
    address public operator;

    bytes32 public testStealthHash;

    event StealthDeposit(
        bytes32 indexed depositId,
        address indexed depositor,
        address indexed token,
        uint256 amount,
        bytes32 stealthAddressHash
    );

    event StealthWithdrawal(bytes32 indexed depositId, address indexed recipient, uint256 amount);

    function setUp() public {
        admin = makeAddr("admin");
        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");
        operator = makeAddr("operator");

        // Generate test stealth hash
        // casting to 'bytes32' is safe because test string literal fits in 32 bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        testStealthHash = keccak256(abi.encodePacked(recipient, bytes32("secret")));

        vm.startPrank(admin);
        vault = new StealthVault(admin);
        vault.grantRole(vault.OPERATOR_ROLE(), operator);

        token = new MockERC20();
        token.mint(depositor, 100_000 ether);
        vm.stopPrank();

        vm.deal(depositor, 1000 ether);
    }

    /* //////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    ////////////////////////////////////////////////////////////// */

    function test_Constructor() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.VAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.EMERGENCY_ROLE(), admin));
    }

    /* //////////////////////////////////////////////////////////////
                        ETH DEPOSIT TESTS
    ////////////////////////////////////////////////////////////// */

    function test_DepositETH() public {
        uint256 amount = 10 ether;

        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // Verify deposit
        assertTrue(depositId != bytes32(0), "Deposit ID should not be zero");

        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertEq(deposit.depositor, depositor);
        assertEq(deposit.token, address(0)); // NATIVE_TOKEN
        assertEq(deposit.amount, amount);
        assertEq(deposit.stealthAddress, testStealthHash);
        assertFalse(deposit.withdrawn);

        // Verify vault balance
        assertEq(address(vault).balance, amount);
        assertEq(vault.getTotalBalance(address(0)), amount);
    }

    function test_DepositETH_ZeroAmount() public {
        vm.prank(depositor);
        vm.expectRevert(IStealthVault.InvalidAmount.selector);
        vault.depositETH{ value: 0 }(testStealthHash);
    }

    function test_DepositETH_ExceedsMaxDeposit() public {
        uint256 maxDeposit = vault.MAX_DEPOSIT();

        vm.deal(depositor, maxDeposit + 1);

        vm.prank(depositor);
        vm.expectRevert(IStealthVault.InvalidAmount.selector);
        vault.depositETH{ value: maxDeposit + 1 }(testStealthHash);
    }

    function test_DepositETH_InvalidStealthAddress() public {
        vm.prank(depositor);
        vm.expectRevert(IStealthVault.InvalidStealthAddress.selector);
        vault.depositETH{ value: 1 ether }(bytes32(0));
    }

    /* //////////////////////////////////////////////////////////////
                        TOKEN DEPOSIT TESTS
    ////////////////////////////////////////////////////////////// */

    function test_DepositToken() public {
        uint256 amount = 100 ether;

        vm.startPrank(depositor);
        token.approve(address(vault), amount);
        bytes32 depositId = vault.depositToken(address(token), amount, testStealthHash);
        vm.stopPrank();

        // Verify deposit
        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertEq(deposit.depositor, depositor);
        assertEq(deposit.token, address(token));
        assertEq(deposit.amount, amount);
        assertEq(deposit.stealthAddress, testStealthHash);

        // Verify balances
        assertEq(token.balanceOf(address(vault)), amount);
        assertEq(vault.getTotalBalance(address(token)), amount);
    }

    function test_DepositToken_ZeroAddress() public {
        vm.prank(depositor);
        vm.expectRevert(IStealthVault.InvalidAmount.selector);
        vault.depositToken(address(0), 100 ether, testStealthHash);
    }

    function test_DepositToken_ZeroAmount() public {
        vm.startPrank(depositor);
        token.approve(address(vault), 100 ether);
        vm.expectRevert(IStealthVault.InvalidAmount.selector);
        vault.depositToken(address(token), 0, testStealthHash);
        vm.stopPrank();
    }

    /* //////////////////////////////////////////////////////////////
                        WITHDRAWAL TESTS
    ////////////////////////////////////////////////////////////// */

    function test_Withdraw_ETH() public {
        // Setup: deposit ETH
        uint256 amount = 10 ether;
        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // Create valid proof
        // casting to 'bytes32' is safe because test string literal fits in 32 bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory proof = abi.encodePacked(bytes32("secret"));

        // Withdraw
        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(recipient);
        vault.withdraw(depositId, recipient, proof);

        // Verify withdrawal
        assertEq(recipient.balance, recipientBalanceBefore + amount);

        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertTrue(deposit.withdrawn);
        assertEq(vault.getTotalBalance(address(0)), 0);
    }

    function test_Withdraw_Token() public {
        // Setup: deposit token
        uint256 amount = 100 ether;
        vm.startPrank(depositor);
        token.approve(address(vault), amount);
        bytes32 depositId = vault.depositToken(address(token), amount, testStealthHash);
        vm.stopPrank();

        // Create valid proof
        // casting to 'bytes32' is safe because test string literal fits in 32 bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory proof = abi.encodePacked(bytes32("secret"));

        // Withdraw
        vm.prank(recipient);
        vault.withdraw(depositId, recipient, proof);

        // Verify withdrawal
        assertEq(token.balanceOf(recipient), amount);

        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertTrue(deposit.withdrawn);
    }

    function test_Withdraw_DepositNotFound() public {
        bytes32 fakeId = keccak256("fake");
        // casting to 'bytes32' is safe because test string literal fits in 32 bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory proof = abi.encodePacked(bytes32("secret"));

        vm.prank(recipient);
        vm.expectRevert(IStealthVault.DepositNotFound.selector);
        vault.withdraw(fakeId, recipient, proof);
    }

    function test_Withdraw_AlreadyWithdrawn() public {
        // Setup: deposit and withdraw
        uint256 amount = 10 ether;
        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // casting to 'bytes32' is safe because test string literal fits in 32 bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory proof = abi.encodePacked(bytes32("secret"));
        vm.prank(recipient);
        vault.withdraw(depositId, recipient, proof);

        // Try to withdraw again
        vm.prank(recipient);
        vm.expectRevert(IStealthVault.AlreadyWithdrawn.selector);
        vault.withdraw(depositId, recipient, proof);
    }

    function test_Withdraw_InvalidProof() public {
        // Setup: deposit
        uint256 amount = 10 ether;
        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // Invalid proof
        // casting to 'bytes32' is safe because test string literal fits in 32 bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory invalidProof = abi.encodePacked(bytes32("wrong_secret"));

        vm.prank(recipient);
        vm.expectRevert(IStealthVault.InvalidProof.selector);
        vault.withdraw(depositId, recipient, invalidProof);
    }

    /* //////////////////////////////////////////////////////////////
                    EMERGENCY WITHDRAWAL TESTS
    ////////////////////////////////////////////////////////////// */

    function test_EmergencyWithdraw() public {
        // Setup: deposit
        uint256 amount = 10 ether;
        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // Emergency withdraw by admin
        address emergencyRecipient = makeAddr("emergency");
        uint256 balanceBefore = emergencyRecipient.balance;

        vm.prank(admin);
        vault.emergencyWithdraw(depositId, emergencyRecipient);

        // Verify
        assertEq(emergencyRecipient.balance, balanceBefore + amount);

        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertTrue(deposit.withdrawn);
    }

    function test_EmergencyWithdraw_Unauthorized() public {
        // Setup: deposit
        uint256 amount = 10 ether;
        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // Non-admin tries emergency withdraw
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(); // AccessControl error
        vault.emergencyWithdraw(depositId, random);
    }

    /* //////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    ////////////////////////////////////////////////////////////// */

    function test_GetStealthDeposits() public {
        // Multiple deposits to same stealth address
        vm.startPrank(depositor);
        bytes32 depositId1 = vault.depositETH{ value: 1 ether }(testStealthHash);
        bytes32 depositId2 = vault.depositETH{ value: 2 ether }(testStealthHash);
        vm.stopPrank();

        bytes32[] memory deposits = vault.getStealthDeposits(testStealthHash);
        assertEq(deposits.length, 2);
        assertEq(deposits[0], depositId1);
        assertEq(deposits[1], depositId2);
    }

    function test_GetDepositorDeposits() public {
        // casting to 'bytes32' is safe because test string literal fits in 32 bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 stealthHash2 = keccak256(abi.encodePacked(recipient, bytes32("secret2")));

        vm.startPrank(depositor);
        vault.depositETH{ value: 1 ether }(testStealthHash);
        vault.depositETH{ value: 2 ether }(stealthHash2);
        vm.stopPrank();

        bytes32[] memory deposits = vault.getDepositorDeposits(depositor);
        assertEq(deposits.length, 2);
    }

    /* //////////////////////////////////////////////////////////////
                        ADMIN FUNCTION TESTS
    ////////////////////////////////////////////////////////////// */

    function test_SetStealthLedger() public {
        address ledger = makeAddr("ledger");

        vm.prank(admin);
        vault.setStealthLedger(ledger);

        assertEq(vault.stealthLedger(), ledger);
    }

    function test_Pause() public {
        vm.prank(admin);
        vault.pause();

        vm.prank(depositor);
        vm.expectRevert(); // EnforcedPause
        vault.depositETH{ value: 1 ether }(testStealthHash);
    }

    function test_Unpause() public {
        vm.startPrank(admin);
        vault.pause();
        vault.unpause();
        vm.stopPrank();

        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: 1 ether }(testStealthHash);
        assertTrue(depositId != bytes32(0));
    }

    /* //////////////////////////////////////////////////////////////
                    F-007 SECURITY FIX TESTS
                    (Proof Verification Hardening)
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice F-007: Proof reuse prevention via usedProofs mapping
     * @dev After a valid withdrawal, the same proof must not be accepted for
     *      a second deposit that shares the same stealthHash. Without the
     *      usedProofs mapping the proof would pass _verifyStealthProof again
     *      because the second deposit is not yet marked withdrawn.
     */
    function test_F007_ProofReusePrevention_DifferentDeposits() public {
        uint256 amount = 5 ether;

        // Two deposits to the SAME stealth address hash
        vm.startPrank(depositor);
        bytes32 depositId1 = vault.depositETH{ value: amount }(testStealthHash);
        bytes32 depositId2 = vault.depositETH{ value: amount }(testStealthHash);
        vm.stopPrank();

        // Build valid proof (matches testStealthHash construction)
        // casting to 'bytes32' is safe because test string literal fits in 32 bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory proof = abi.encodePacked(bytes32("secret"));

        // First withdrawal succeeds
        vm.prank(recipient);
        vault.withdraw(depositId1, recipient, proof);

        IStealthVault.Deposit memory d1 = vault.getDeposit(depositId1);
        assertTrue(d1.withdrawn, "First deposit should be withdrawn");

        // Second withdrawal with the SAME proof must revert (proof replay)
        // depositId2 is NOT yet withdrawn, so this specifically tests usedProofs
        vm.prank(recipient);
        vm.expectRevert(IStealthVault.InvalidProof.selector);
        vault.withdraw(depositId2, recipient, proof);

        // Confirm second deposit remains unaffected
        IStealthVault.Deposit memory d2 = vault.getDeposit(depositId2);
        assertFalse(d2.withdrawn, "Second deposit must remain unwithdrawn");
    }

    /**
     * @notice F-007: usedProofs flag persists after withdrawal
     * @dev Validates that the usedProofs mapping is correctly set to true
     *      after a successful withdrawal completes.
     */
    function test_F007_UsedProofsFlagSetAfterWithdrawal() public {
        uint256 amount = 1 ether;

        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // casting to 'bytes32' is safe because test string literal fits in 32 bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory proof = abi.encodePacked(bytes32("secret"));

        // Compute the expected proofHash the same way the contract does
        bytes32 expectedProofHash =
            keccak256(abi.encodePacked(recipient, recipient, proof, block.chainid));

        // Before withdrawal, proof should not be marked as used
        assertFalse(vault.usedProofs(expectedProofHash), "Proof should not be used before withdrawal");

        vm.prank(recipient);
        vault.withdraw(depositId, recipient, proof);

        // After withdrawal, proof must be marked as used
        assertTrue(vault.usedProofs(expectedProofHash), "Proof must be marked used after withdrawal");
    }

    /**
     * @notice F-007: Recipient must equal msg.sender
     * @dev The withdraw function requires recipient == msg.sender to prevent
     *      front-running attacks where an attacker submits someone else's
     *      proof with their own address as recipient.
     */
    function test_F007_RecipientMustEqualMsgSender() public {
        uint256 amount = 5 ether;

        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // casting to 'bytes32' is safe because test string literal fits in 32 bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory proof = abi.encodePacked(bytes32("secret"));

        // Attacker (depositor) tries to withdraw to recipient using recipient's proof
        // msg.sender = depositor but recipient != depositor --> should revert
        vm.prank(depositor);
        vm.expectRevert(IStealthVault.Unauthorized.selector);
        vault.withdraw(depositId, recipient, proof);
    }

    /**
     * @notice F-007: Third-party caller cannot redirect funds
     * @dev Even if a third party knows the proof, they cannot call withdraw
     *      with someone else's address as recipient because msg.sender check fails.
     */
    function test_F007_ThirdPartyCannotRedirectFunds() public {
        uint256 amount = 5 ether;

        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // casting to 'bytes32' is safe because test string literal fits in 32 bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory proof = abi.encodePacked(bytes32("secret"));

        address attacker = makeAddr("attacker");

        // Attacker calls withdraw with recipient = recipient (not themselves)
        vm.prank(attacker);
        vm.expectRevert(IStealthVault.Unauthorized.selector);
        vault.withdraw(depositId, recipient, proof);

        // Attacker calls withdraw with recipient = attacker (proof will be invalid)
        vm.prank(attacker);
        vm.expectRevert(IStealthVault.InvalidProof.selector);
        vault.withdraw(depositId, attacker, proof);
    }

    /**
     * @notice F-007: Domain separation -- chainid is included in proofHash
     * @dev Validates that the proofHash computation incorporates block.chainid,
     *      ensuring that a proof valid on one chain cannot be replayed on another.
     *      We verify this by computing the expected proofHash with and without
     *      chainid and asserting the contract uses the chain-specific version.
     */
    function test_F007_DomainSeparation_ChainIdInProofHash() public {
        uint256 amount = 1 ether;

        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        // casting to 'bytes32' is safe because test string literal fits in 32 bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory proof = abi.encodePacked(bytes32("secret"));

        // Compute proofHash WITH chainid (correct, matches contract logic)
        bytes32 proofHashWithChain =
            keccak256(abi.encodePacked(recipient, recipient, proof, block.chainid));

        // Compute proofHash WITHOUT chainid (incorrect, vulnerable version)
        bytes32 proofHashWithoutChain =
            keccak256(abi.encodePacked(recipient, recipient, proof));

        // The two hashes must differ -- domain separation is meaningful
        assertTrue(
            proofHashWithChain != proofHashWithoutChain,
            "Chain-specific hash must differ from chain-agnostic hash"
        );

        // Perform withdrawal
        vm.prank(recipient);
        vault.withdraw(depositId, recipient, proof);

        // The contract must have marked the chain-specific proofHash as used
        assertTrue(
            vault.usedProofs(proofHashWithChain),
            "Contract must use chain-specific proofHash"
        );

        // The chain-agnostic version must NOT be marked as used
        assertFalse(
            vault.usedProofs(proofHashWithoutChain),
            "Chain-agnostic proofHash must not be marked used"
        );
    }

    /**
     * @notice F-007: Domain separation -- fork to a different chainid
     * @dev Uses vm.chainId to simulate a different chain and verifies that
     *      the same proof produces a distinct proofHash, so a cross-chain
     *      replay would not collide with the used proof from the original chain.
     */
    function test_F007_DomainSeparation_DifferentChainProducesDistinctHash() public {
        // casting to 'bytes32' is safe because test string literal fits in 32 bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory proof = abi.encodePacked(bytes32("secret"));

        uint256 originalChainId = block.chainid;

        // Compute proofHash on the current chain
        bytes32 hashOnOriginalChain =
            keccak256(abi.encodePacked(recipient, recipient, proof, originalChainId));

        // Simulate a different chain
        uint256 differentChainId = originalChainId + 1;
        vm.chainId(differentChainId);

        bytes32 hashOnDifferentChain =
            keccak256(abi.encodePacked(recipient, recipient, proof, block.chainid));

        // Proofs must produce different hashes on different chains
        assertTrue(
            hashOnOriginalChain != hashOnDifferentChain,
            "Same proof must produce different hashes on different chains"
        );

        // Restore original chain id for subsequent tests
        vm.chainId(originalChainId);
    }

    /* //////////////////////////////////////////////////////////////
                        FUZZ TESTS
    ////////////////////////////////////////////////////////////// */

    function testFuzz_DepositETH_Amount(uint256 amount) public {
        amount = bound(amount, 1, vault.MAX_DEPOSIT());

        vm.deal(depositor, amount);

        vm.prank(depositor);
        bytes32 depositId = vault.depositETH{ value: amount }(testStealthHash);

        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertEq(deposit.amount, amount);
    }

    function testFuzz_DepositToken_Amount(uint256 amount) public {
        amount = bound(amount, 1, vault.MAX_DEPOSIT());

        vm.prank(admin);
        token.mint(depositor, amount);

        vm.startPrank(depositor);
        token.approve(address(vault), amount);
        bytes32 depositId = vault.depositToken(address(token), amount, testStealthHash);
        vm.stopPrank();

        IStealthVault.Deposit memory deposit = vault.getDeposit(depositId);
        assertEq(deposit.amount, amount);
    }

    function testFuzz_MultipleDeposits(uint8 count) public {
        count = uint8(bound(count, 1, 50));

        vm.deal(depositor, uint256(count) * 1 ether);

        bytes32[] memory depositIds = new bytes32[](count);

        vm.startPrank(depositor);
        for (uint8 i = 0; i < count; i++) {
            bytes32 hash = keccak256(abi.encodePacked(recipient, bytes32(uint256(i))));
            depositIds[i] = vault.depositETH{ value: 1 ether }(hash);
        }
        vm.stopPrank();

        assertEq(vault.depositCount(), count);
        assertEq(vault.getTotalBalance(address(0)), uint256(count) * 1 ether);
    }
}
