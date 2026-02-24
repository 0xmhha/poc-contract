// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {
    WithdrawalManager,
    IWithdrawalManager,
    IStealthVaultReader
} from "../../src/privacy/enterprise/WithdrawalManager.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice Mock ERC20 token for testing WithdrawalManager
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
 * @title MockStealthVault
 * @notice Mock vault implementing IStealthVaultReader for controlled test returns
 */
contract MockStealthVault is IStealthVaultReader {
    mapping(bytes32 => Deposit) private _deposits;

    function setDeposit(bytes32 depositId, Deposit memory deposit) external {
        _deposits[depositId] = deposit;
    }

    function getDeposit(bytes32 depositId) external view override returns (Deposit memory) {
        return _deposits[depositId];
    }
}

/**
 * @title WithdrawalManagerTest
 * @notice Comprehensive unit tests for WithdrawalManager
 * @dev Focuses on F-004 vault state validation fix and full withdrawal workflow
 */
contract WithdrawalManagerTest is Test {
    WithdrawalManager public manager;
    MockStealthVault public mockVault;
    MockERC20 public token;

    address public admin;
    address public requester;
    address public recipient;
    address public approver;
    address public executor;
    address public unauthorized;

    uint256 public constant COOLDOWN_PERIOD = 1 hours;
    uint256 public constant APPROVAL_THRESHOLD = 10_000 ether;

    bytes32 public constant TEST_DEPOSIT_ID = keccak256("test-deposit-1");
    bytes32 public constant TEST_STEALTH_HASH = keccak256("stealth-address-hash");

    event WithdrawalRequested(
        bytes32 indexed requestId, bytes32 indexed depositId, address indexed requester, uint256 amount
    );
    event WithdrawalApproved(bytes32 indexed requestId, address indexed approver);
    event WithdrawalExecuted(bytes32 indexed requestId, address indexed recipient, uint256 amount);
    event WithdrawalRejected(bytes32 indexed requestId, address indexed rejector, string reason);
    event WithdrawalCancelled(bytes32 indexed requestId, address indexed canceller);
    event CooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    function setUp() public {
        admin = makeAddr("admin");
        requester = makeAddr("requester");
        recipient = makeAddr("recipient");
        approver = makeAddr("approver");
        executor = makeAddr("executor");
        unauthorized = makeAddr("unauthorized");

        // Deploy contracts
        vm.startPrank(admin);
        manager = new WithdrawalManager(admin, COOLDOWN_PERIOD, APPROVAL_THRESHOLD);
        mockVault = new MockStealthVault();
        token = new MockERC20();

        // Configure vault reference
        manager.setStealthVault(address(mockVault));

        // Grant roles to separate actors
        manager.grantRole(manager.APPROVER_ROLE(), approver);
        manager.grantRole(manager.EXECUTOR_ROLE(), executor);
        vm.stopPrank();

        // Fund the manager contract with tokens for executing withdrawals
        vm.prank(admin);
        token.mint(address(manager), 1_000_000 ether);

        // Fund the manager contract with ETH for native token withdrawals
        vm.deal(address(manager), 1000 ether);
    }

    /* //////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /// @notice Sets up a valid deposit in the mock vault
    function _setupValidDeposit(bytes32 depositId, address depositor, address depositToken, uint256 amount) internal {
        mockVault.setDeposit(
            depositId,
            IStealthVaultReader.Deposit({
                depositor: depositor,
                token: depositToken,
                amount: amount,
                stealthAddress: TEST_STEALTH_HASH,
                timestamp: block.timestamp,
                withdrawn: false
            })
        );
    }

    /// @notice Creates a valid withdrawal request and returns the requestId
    function _createValidRequest(bytes32 depositId, address depositToken, uint256 amount)
        internal
        returns (bytes32 requestId)
    {
        _setupValidDeposit(depositId, requester, depositToken, amount);

        vm.prank(requester);
        requestId = manager.requestWithdrawal(depositId, recipient, depositToken, amount);
    }

    /* //////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    ////////////////////////////////////////////////////////////// */

    function test_Constructor_GrantsAllRolesToAdmin() public view {
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(manager.hasRole(manager.WITHDRAWAL_ADMIN_ROLE(), admin));
        assertTrue(manager.hasRole(manager.APPROVER_ROLE(), admin));
        assertTrue(manager.hasRole(manager.EXECUTOR_ROLE(), admin));
    }

    function test_Constructor_SetsCooldownPeriod() public view {
        assertEq(manager.cooldownPeriod(), COOLDOWN_PERIOD);
    }

    function test_Constructor_SetsApprovalThreshold() public view {
        assertEq(manager.approvalThreshold(), APPROVAL_THRESHOLD);
    }

    function test_Constructor_InitializesZeroRequestCount() public view {
        assertEq(manager.requestCount(), 0);
    }

    /* //////////////////////////////////////////////////////////////
                F-004: VAULT NOT CONFIGURED REVERT TESTS
    ////////////////////////////////////////////////////////////// */

    function test_RequestWithdrawal_RevertsOnVaultNotConfigured() public {
        // Deploy a fresh manager without vault configuration
        vm.prank(admin);
        WithdrawalManager freshManager = new WithdrawalManager(admin, COOLDOWN_PERIOD, APPROVAL_THRESHOLD);

        // stealthVault is address(0) by default -- must revert
        vm.prank(requester);
        vm.expectRevert(IWithdrawalManager.VaultNotConfigured.selector);
        freshManager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 100 ether);
    }

    function test_RequestWithdrawal_RevertsOnVaultResetToZero() public {
        // Admin resets vault back to address(0)
        vm.prank(admin);
        manager.setStealthVault(address(0));

        vm.prank(requester);
        vm.expectRevert(IWithdrawalManager.VaultNotConfigured.selector);
        manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 100 ether);
    }

    /* //////////////////////////////////////////////////////////////
            F-004: INVALID DEPOSIT VALIDATION REVERT TESTS
    ////////////////////////////////////////////////////////////// */

    function test_RequestWithdrawal_RevertsOnNoDepositExists() public {
        // No deposit configured in mock vault -- depositor is address(0)
        vm.prank(requester);
        vm.expectRevert(IWithdrawalManager.InvalidDeposit.selector);
        manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 100 ether);
    }

    function test_RequestWithdrawal_RevertsOnTokenMismatch() public {
        // Deposit exists with a different token
        address wrongToken = makeAddr("wrong-token");
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, wrongToken, 100 ether);

        vm.prank(requester);
        vm.expectRevert(IWithdrawalManager.InvalidDeposit.selector);
        manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 100 ether);
    }

    function test_RequestWithdrawal_RevertsOnInsufficientAmount() public {
        // Deposit exists but with less than requested amount
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(token), 50 ether);

        vm.prank(requester);
        vm.expectRevert(IWithdrawalManager.InvalidDeposit.selector);
        manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 100 ether);
    }

    function test_RequestWithdrawal_RevertsOnAlreadyWithdrawn() public {
        // Deposit exists but already withdrawn
        mockVault.setDeposit(
            TEST_DEPOSIT_ID,
            IStealthVaultReader.Deposit({
                depositor: requester,
                token: address(token),
                amount: 100 ether,
                stealthAddress: TEST_STEALTH_HASH,
                timestamp: block.timestamp,
                withdrawn: true
            })
        );

        vm.prank(requester);
        vm.expectRevert(IWithdrawalManager.InvalidDeposit.selector);
        manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 100 ether);
    }

    /* //////////////////////////////////////////////////////////////
                    REQUEST WITHDRAWAL BASIC REVERT TESTS
    ////////////////////////////////////////////////////////////// */

    function test_RequestWithdrawal_RevertsOnZeroDepositId() public {
        vm.prank(requester);
        vm.expectRevert(IWithdrawalManager.InvalidDepositId.selector);
        manager.requestWithdrawal(bytes32(0), recipient, address(token), 100 ether);
    }

    function test_RequestWithdrawal_RevertsOnZeroRecipient() public {
        vm.prank(requester);
        vm.expectRevert(IWithdrawalManager.InvalidRecipient.selector);
        manager.requestWithdrawal(TEST_DEPOSIT_ID, address(0), address(token), 100 ether);
    }

    function test_RequestWithdrawal_RevertsOnZeroAmount() public {
        vm.prank(requester);
        vm.expectRevert(IWithdrawalManager.InvalidAmount.selector);
        manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 0);
    }

    function test_RequestWithdrawal_RevertsWhenPaused() public {
        vm.prank(admin);
        manager.pause();

        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(token), 100 ether);

        vm.prank(requester);
        vm.expectRevert(); // EnforcedPause
        manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 100 ether);
    }

    /* //////////////////////////////////////////////////////////////
                SUCCESSFUL REQUEST WITHDRAWAL TESTS
    ////////////////////////////////////////////////////////////// */

    function test_RequestWithdrawal_SucceedsWithValidDeposit() public {
        uint256 amount = 100 ether;
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(token), amount);

        vm.prank(requester);
        bytes32 requestId = manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), amount);

        assertTrue(requestId != bytes32(0), "Request ID should not be zero");

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        assertEq(request.depositId, TEST_DEPOSIT_ID);
        assertEq(request.requester, requester);
        assertEq(request.recipient, recipient);
        assertEq(request.token, address(token));
        assertEq(request.amount, amount);
        assertEq(request.requestedAt, block.timestamp);
        assertEq(request.cooldownEnd, block.timestamp + COOLDOWN_PERIOD);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.PENDING));
        assertEq(request.approvalHash, bytes32(0));
    }

    function test_RequestWithdrawal_PartialAmount() public {
        // Deposit has 1000 ether but only request 100 ether
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(token), 1000 ether);

        vm.prank(requester);
        bytes32 requestId = manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 100 ether);

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        assertEq(request.amount, 100 ether);
    }

    function test_RequestWithdrawal_ExactAmount() public {
        uint256 amount = 500 ether;
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(token), amount);

        vm.prank(requester);
        bytes32 requestId = manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), amount);

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        assertEq(request.amount, amount);
    }

    function test_RequestWithdrawal_NativeToken() public {
        address nativeToken = address(0);
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, nativeToken, 10 ether);

        vm.prank(requester);
        bytes32 requestId = manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, nativeToken, 10 ether);

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        assertEq(request.token, nativeToken);
    }

    function test_RequestWithdrawal_EmitsEvent() public {
        uint256 amount = 100 ether;
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(token), amount);

        vm.prank(requester);
        vm.expectEmit(false, true, true, true);
        emit WithdrawalRequested(bytes32(0), TEST_DEPOSIT_ID, requester, amount);
        manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), amount);
    }

    function test_RequestWithdrawal_IncrementsRequestCount() public {
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(token), 100 ether);

        assertEq(manager.requestCount(), 0);

        vm.prank(requester);
        manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 100 ether);

        assertEq(manager.requestCount(), 1);
    }

    function test_RequestWithdrawal_TracksDepositRequests() public {
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(token), 100 ether);

        vm.prank(requester);
        bytes32 requestId = manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 100 ether);

        bytes32[] memory depositReqs = manager.getDepositRequests(TEST_DEPOSIT_ID);
        assertEq(depositReqs.length, 1);
        assertEq(depositReqs[0], requestId);
    }

    function test_RequestWithdrawal_TracksRequesterRequests() public {
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(token), 100 ether);

        vm.prank(requester);
        bytes32 requestId = manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 100 ether);

        bytes32[] memory userReqs = manager.getRequesterRequests(requester);
        assertEq(userReqs.length, 1);
        assertEq(userReqs[0], requestId);
    }

    /* //////////////////////////////////////////////////////////////
                        APPROVE WITHDRAWAL TESTS
    ////////////////////////////////////////////////////////////// */

    function test_ApproveWithdrawal_Success() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(approver);
        manager.approveWithdrawal(requestId);

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.APPROVED));
        assertTrue(request.approvalHash != bytes32(0), "Approval hash should be set");
    }

    function test_ApproveWithdrawal_EmitsEvent() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(approver);
        vm.expectEmit(true, true, false, false);
        emit WithdrawalApproved(requestId, approver);
        manager.approveWithdrawal(requestId);
    }

    function test_ApproveWithdrawal_RevertsOnUnauthorized() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(unauthorized);
        vm.expectRevert(); // AccessControl error
        manager.approveWithdrawal(requestId);
    }

    function test_ApproveWithdrawal_RevertsOnRequestNotFound() public {
        bytes32 fakeId = keccak256("nonexistent");

        vm.prank(approver);
        vm.expectRevert(IWithdrawalManager.RequestNotFound.selector);
        manager.approveWithdrawal(fakeId);
    }

    function test_ApproveWithdrawal_RevertsOnRequestNotPending() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        // Approve once
        vm.prank(approver);
        manager.approveWithdrawal(requestId);

        // Try to approve again -- status is no longer PENDING
        vm.prank(approver);
        vm.expectRevert(IWithdrawalManager.RequestNotPending.selector);
        manager.approveWithdrawal(requestId);
    }

    function test_ApproveWithdrawal_RevertsOnAlreadyApproved() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        // First approval sets the approvalHash
        vm.prank(admin); // admin also has APPROVER_ROLE
        manager.approveWithdrawal(requestId);

        // The status is now APPROVED, so this hits RequestNotPending
        vm.prank(approver);
        vm.expectRevert(IWithdrawalManager.RequestNotPending.selector);
        manager.approveWithdrawal(requestId);
    }

    function test_ApproveWithdrawal_RevertsOnExpiredRequest() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        // Warp past the 30-day expiration window
        vm.warp(block.timestamp + manager.REQUEST_EXPIRATION() + 1);

        vm.prank(approver);
        vm.expectRevert(IWithdrawalManager.RequestExpired.selector);
        manager.approveWithdrawal(requestId);
    }

    function test_ApproveWithdrawal_RevertsWhenPaused() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(admin);
        manager.pause();

        vm.prank(approver);
        vm.expectRevert(); // EnforcedPause
        manager.approveWithdrawal(requestId);
    }

    /* //////////////////////////////////////////////////////////////
                        EXECUTE WITHDRAWAL TESTS
    ////////////////////////////////////////////////////////////// */

    function test_ExecuteWithdrawal_SmallAmountBelowThreshold() public {
        uint256 amount = 100 ether; // Below APPROVAL_THRESHOLD of 10_000 ether

        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), amount);

        // Warp past cooldown -- no approval needed for below-threshold amounts
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        vm.prank(executor);
        manager.executeWithdrawal(requestId);

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.EXECUTED));
        assertEq(token.balanceOf(recipient), recipientBalanceBefore + amount);
    }

    function test_ExecuteWithdrawal_LargeAmountRequiresApproval() public {
        uint256 amount = APPROVAL_THRESHOLD; // Exactly at threshold

        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), amount);

        // Approve the request
        vm.prank(approver);
        manager.approveWithdrawal(requestId);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(executor);
        manager.executeWithdrawal(requestId);

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.EXECUTED));
    }

    function test_ExecuteWithdrawal_LargeAmountRevertsWithoutApproval() public {
        uint256 amount = APPROVAL_THRESHOLD; // At threshold -- requires approval

        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), amount);

        // Warp past cooldown but do not approve
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(executor);
        vm.expectRevert(IWithdrawalManager.RequestNotPending.selector);
        manager.executeWithdrawal(requestId);
    }

    function test_ExecuteWithdrawal_NativeETH() public {
        uint256 amount = 5 ether;

        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(0), amount);

        vm.prank(requester);
        bytes32 requestId = manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(0), amount);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(executor);
        manager.executeWithdrawal(requestId);

        assertEq(recipient.balance, recipientBalanceBefore + amount);
    }

    function test_ExecuteWithdrawal_EmitsEvent() public {
        uint256 amount = 100 ether;
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), amount);

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(executor);
        vm.expectEmit(true, true, false, true);
        emit WithdrawalExecuted(requestId, recipient, amount);
        manager.executeWithdrawal(requestId);
    }

    function test_ExecuteWithdrawal_RevertsOnCooldownNotElapsed() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        // Do not warp -- cooldown is still active
        vm.prank(executor);
        vm.expectRevert(IWithdrawalManager.CooldownNotElapsed.selector);
        manager.executeWithdrawal(requestId);
    }

    function test_ExecuteWithdrawal_RevertsOnRequestNotFound() public {
        bytes32 fakeId = keccak256("nonexistent");

        vm.prank(executor);
        vm.expectRevert(IWithdrawalManager.RequestNotFound.selector);
        manager.executeWithdrawal(fakeId);
    }

    function test_ExecuteWithdrawal_RevertsOnExpiredRequest() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        // Warp past the 30-day expiration
        vm.warp(block.timestamp + manager.REQUEST_EXPIRATION() + 1);

        vm.prank(executor);
        vm.expectRevert(IWithdrawalManager.RequestExpired.selector);
        manager.executeWithdrawal(requestId);
    }

    function test_ExecuteWithdrawal_RevertsOnUnauthorized() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(unauthorized);
        vm.expectRevert(); // AccessControl error
        manager.executeWithdrawal(requestId);
    }

    function test_ExecuteWithdrawal_RevertsWhenPaused() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(admin);
        manager.pause();

        vm.prank(executor);
        vm.expectRevert(); // EnforcedPause
        manager.executeWithdrawal(requestId);
    }

    function test_ExecuteWithdrawal_RevertsOnAlreadyExecuted() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(executor);
        manager.executeWithdrawal(requestId);

        // Try to execute again -- status is EXECUTED, so the status check reverts
        vm.prank(executor);
        vm.expectRevert(IWithdrawalManager.RequestNotPending.selector);
        manager.executeWithdrawal(requestId);
    }

    /* //////////////////////////////////////////////////////////////
                FULL WORKFLOW: REQUEST -> APPROVE -> EXECUTE
    ////////////////////////////////////////////////////////////// */

    function test_FullWorkflow_SmallAmountSkipsApproval() public {
        uint256 amount = 500 ether; // Below threshold

        // Step 1: Request
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(token), amount);

        vm.prank(requester);
        bytes32 requestId = manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), amount);

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.PENDING));

        // Step 2: Skip approval (amount below threshold)

        // Step 3: Wait for cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        // Step 4: Execute
        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        vm.prank(executor);
        manager.executeWithdrawal(requestId);

        request = manager.getRequest(requestId);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.EXECUTED));
        assertEq(token.balanceOf(recipient), recipientBalanceBefore + amount);
    }

    function test_FullWorkflow_LargeAmountRequiresApproval() public {
        uint256 amount = 50_000 ether; // Above threshold

        // Step 1: Request
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(token), amount);
        vm.prank(admin);
        token.mint(address(manager), amount); // Ensure manager has enough tokens

        vm.prank(requester);
        bytes32 requestId = manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), amount);

        // Step 2: Approve
        vm.prank(approver);
        manager.approveWithdrawal(requestId);

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.APPROVED));

        // Step 3: Wait for cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        // Step 4: Execute
        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        vm.prank(executor);
        manager.executeWithdrawal(requestId);

        request = manager.getRequest(requestId);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.EXECUTED));
        assertEq(token.balanceOf(recipient), recipientBalanceBefore + amount);
    }

    function test_FullWorkflow_NativeETH() public {
        uint256 amount = 2 ether;

        // Step 1: Request
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(0), amount);

        vm.prank(requester);
        bytes32 requestId = manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(0), amount);

        // Step 2: Wait for cooldown
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        // Step 3: Execute
        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(executor);
        manager.executeWithdrawal(requestId);

        assertEq(recipient.balance, recipientBalanceBefore + amount);
    }

    /* //////////////////////////////////////////////////////////////
                        REJECT WITHDRAWAL TESTS
    ////////////////////////////////////////////////////////////// */

    function test_RejectWithdrawal_Success() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(approver);
        manager.rejectWithdrawal(requestId, "Suspicious activity");

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.REJECTED));
    }

    function test_RejectWithdrawal_EmitsEvent() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(approver);
        vm.expectEmit(true, true, false, true);
        emit WithdrawalRejected(requestId, approver, "Reason");
        manager.rejectWithdrawal(requestId, "Reason");
    }

    function test_RejectWithdrawal_RevertsOnUnauthorized() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(unauthorized);
        vm.expectRevert(); // AccessControl error
        manager.rejectWithdrawal(requestId, "Reason");
    }

    function test_RejectWithdrawal_RevertsOnRequestNotFound() public {
        vm.prank(approver);
        vm.expectRevert(IWithdrawalManager.RequestNotFound.selector);
        manager.rejectWithdrawal(keccak256("fake"), "Reason");
    }

    function test_RejectWithdrawal_RevertsOnNotPending() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        // Reject first
        vm.prank(approver);
        manager.rejectWithdrawal(requestId, "First rejection");

        // Try to reject again
        vm.prank(approver);
        vm.expectRevert(IWithdrawalManager.RequestNotPending.selector);
        manager.rejectWithdrawal(requestId, "Second rejection");
    }

    function test_RejectWithdrawal_PreventsExecution() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(approver);
        manager.rejectWithdrawal(requestId, "Rejected");

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(executor);
        vm.expectRevert(); // RequestNotPending or similar
        manager.executeWithdrawal(requestId);
    }

    /* //////////////////////////////////////////////////////////////
                        CANCEL WITHDRAWAL TESTS
    ////////////////////////////////////////////////////////////// */

    function test_CancelWithdrawal_ByRequesterWhilePending() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(requester);
        manager.cancelWithdrawal(requestId);

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.CANCELLED));
    }

    function test_CancelWithdrawal_ByRequesterWhileApproved() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(approver);
        manager.approveWithdrawal(requestId);

        // Requester can still cancel even after approval
        vm.prank(requester);
        manager.cancelWithdrawal(requestId);

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.CANCELLED));
    }

    function test_CancelWithdrawal_EmitsEvent() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(requester);
        vm.expectEmit(true, true, false, false);
        emit WithdrawalCancelled(requestId, requester);
        manager.cancelWithdrawal(requestId);
    }

    function test_CancelWithdrawal_RevertsOnUnauthorizedCaller() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(unauthorized);
        vm.expectRevert(IWithdrawalManager.Unauthorized.selector);
        manager.cancelWithdrawal(requestId);
    }

    function test_CancelWithdrawal_RevertsOnRequestNotFound() public {
        vm.prank(requester);
        vm.expectRevert(IWithdrawalManager.RequestNotFound.selector);
        manager.cancelWithdrawal(keccak256("fake"));
    }

    function test_CancelWithdrawal_RevertsOnAlreadyCancelled() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(requester);
        manager.cancelWithdrawal(requestId);

        vm.prank(requester);
        vm.expectRevert(IWithdrawalManager.RequestNotPending.selector);
        manager.cancelWithdrawal(requestId);
    }

    function test_CancelWithdrawal_PreventsExecution() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(requester);
        manager.cancelWithdrawal(requestId);

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(executor);
        vm.expectRevert(); // RequestNotPending or similar
        manager.executeWithdrawal(requestId);
    }

    /* //////////////////////////////////////////////////////////////
                        CAN EXECUTE VIEW TESTS
    ////////////////////////////////////////////////////////////// */

    function test_CanExecute_ReturnsTrueWhenReady() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        (bool executable, string memory reason) = manager.canExecute(requestId);
        assertTrue(executable);
        assertEq(bytes(reason).length, 0);
    }

    function test_CanExecute_ReturnsFalseForNonexistent() public view {
        (bool executable, string memory reason) = manager.canExecute(keccak256("fake"));
        assertFalse(executable);
        assertEq(reason, "Request not found");
    }

    function test_CanExecute_ReturnsFalseForCooldownActive() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        (bool executable, string memory reason) = manager.canExecute(requestId);
        assertFalse(executable);
        assertEq(reason, "Cooldown not elapsed");
    }

    function test_CanExecute_ReturnsFalseForExpired() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.warp(block.timestamp + manager.REQUEST_EXPIRATION() + 1);

        (bool executable, string memory reason) = manager.canExecute(requestId);
        assertFalse(executable);
        assertEq(reason, "Request expired");
    }

    function test_CanExecute_ReturnsFalseWhenApprovalRequired() public {
        uint256 amount = APPROVAL_THRESHOLD; // At threshold -- needs approval
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), amount);

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        (bool executable, string memory reason) = manager.canExecute(requestId);
        assertFalse(executable);
        assertEq(reason, "Approval required");
    }

    function test_CanExecute_ReturnsFalseForRejected() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(approver);
        manager.rejectWithdrawal(requestId, "Rejected");

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        (bool executable, string memory reason) = manager.canExecute(requestId);
        assertFalse(executable);
        assertEq(reason, "Request rejected");
    }

    function test_CanExecute_ReturnsFalseForCancelled() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.prank(requester);
        manager.cancelWithdrawal(requestId);

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        (bool executable, string memory reason) = manager.canExecute(requestId);
        assertFalse(executable);
        assertEq(reason, "Request cancelled");
    }

    function test_CanExecute_ReturnsFalseForExecuted() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);

        vm.prank(executor);
        manager.executeWithdrawal(requestId);

        (bool executable, string memory reason) = manager.canExecute(requestId);
        assertFalse(executable);
        assertEq(reason, "Already executed");
    }

    /* //////////////////////////////////////////////////////////////
                        ADMIN FUNCTION TESTS
    ////////////////////////////////////////////////////////////// */

    function test_SetCooldownPeriod() public {
        uint256 newCooldown = 2 hours;

        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit CooldownUpdated(COOLDOWN_PERIOD, newCooldown);
        manager.setCooldownPeriod(newCooldown);

        assertEq(manager.cooldownPeriod(), newCooldown);
    }

    function test_SetCooldownPeriod_RevertsOnExceedMax() public {
        uint256 maxCooldown = manager.MAX_COOLDOWN();

        vm.prank(admin);
        vm.expectRevert("Cooldown too long");
        manager.setCooldownPeriod(maxCooldown + 1);
    }

    function test_SetCooldownPeriod_AllowsMaxCooldown() public {
        uint256 maxCooldown = manager.MAX_COOLDOWN();

        vm.prank(admin);
        manager.setCooldownPeriod(maxCooldown);

        assertEq(manager.cooldownPeriod(), maxCooldown);
    }

    function test_SetCooldownPeriod_AllowsZero() public {
        vm.prank(admin);
        manager.setCooldownPeriod(0);

        assertEq(manager.cooldownPeriod(), 0);
    }

    function test_SetCooldownPeriod_RevertsOnUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // AccessControl error
        manager.setCooldownPeriod(1 hours);
    }

    function test_SetApprovalThreshold() public {
        uint256 newThreshold = 50_000 ether;

        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit ThresholdUpdated(APPROVAL_THRESHOLD, newThreshold);
        manager.setApprovalThreshold(newThreshold);

        assertEq(manager.approvalThreshold(), newThreshold);
    }

    function test_SetApprovalThreshold_RevertsOnUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // AccessControl error
        manager.setApprovalThreshold(50_000 ether);
    }

    function test_SetStealthVault() public {
        address newVault = makeAddr("new-vault");

        vm.prank(admin);
        manager.setStealthVault(newVault);

        assertEq(manager.stealthVault(), newVault);
    }

    function test_SetStealthVault_RevertsOnUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // AccessControl error
        manager.setStealthVault(makeAddr("vault"));
    }

    function test_Pause() public {
        vm.prank(admin);
        manager.pause();

        assertTrue(manager.paused());
    }

    function test_Unpause() public {
        vm.startPrank(admin);
        manager.pause();
        manager.unpause();
        vm.stopPrank();

        assertFalse(manager.paused());
    }

    function test_Pause_RevertsOnUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // AccessControl error
        manager.pause();
    }

    function test_Unpause_RevertsOnUnauthorized() public {
        vm.prank(admin);
        manager.pause();

        vm.prank(unauthorized);
        vm.expectRevert(); // AccessControl error
        manager.unpause();
    }

    /* //////////////////////////////////////////////////////////////
                        RECEIVE ETH TEST
    ////////////////////////////////////////////////////////////// */

    function test_ReceiveETH() public {
        uint256 amount = 1 ether;
        uint256 balanceBefore = address(manager).balance;

        vm.deal(requester, amount);
        vm.prank(requester);
        (bool success,) = address(manager).call{ value: amount }("");

        assertTrue(success);
        assertEq(address(manager).balance, balanceBefore + amount);
    }

    /* //////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    ////////////////////////////////////////////////////////////// */

    function test_MultipleRequestsForSameDeposit() public {
        _setupValidDeposit(TEST_DEPOSIT_ID, requester, address(token), 1000 ether);

        vm.startPrank(requester);
        bytes32 requestId1 = manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 100 ether);
        bytes32 requestId2 = manager.requestWithdrawal(TEST_DEPOSIT_ID, recipient, address(token), 200 ether);
        vm.stopPrank();

        assertTrue(requestId1 != requestId2, "Request IDs must be unique");

        bytes32[] memory depositReqs = manager.getDepositRequests(TEST_DEPOSIT_ID);
        assertEq(depositReqs.length, 2);
        assertEq(depositReqs[0], requestId1);
        assertEq(depositReqs[1], requestId2);
    }

    function test_CooldownBoundaryExactlyAtEnd() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);

        // Warp to exactly the cooldown end -- should still revert (< not <=)
        vm.warp(request.cooldownEnd);

        // block.timestamp == cooldownEnd means block.timestamp < cooldownEnd is false
        // so this should succeed since the contract checks: if (block.timestamp < request.cooldownEnd)
        vm.prank(executor);
        manager.executeWithdrawal(requestId);

        request = manager.getRequest(requestId);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.EXECUTED));
    }

    function test_ExpirationBoundaryExactlyAtEnd() public {
        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        uint256 expirationTime = request.requestedAt + manager.REQUEST_EXPIRATION();

        // Warp to exactly the expiration time -- should still work (> not >=)
        vm.warp(expirationTime);

        // block.timestamp == requestedAt + REQUEST_EXPIRATION
        // The check is: if (block.timestamp > request.requestedAt + REQUEST_EXPIRATION)
        // So at exactly the boundary, it should NOT revert
        vm.prank(executor);
        manager.executeWithdrawal(requestId);

        request = manager.getRequest(requestId);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.EXECUTED));
    }

    function test_ZeroCooldownAllowsImmediateExecution() public {
        // Set cooldown to zero
        vm.prank(admin);
        manager.setCooldownPeriod(0);

        bytes32 requestId = _createValidRequest(TEST_DEPOSIT_ID, address(token), 100 ether);

        // Execute immediately without warping
        vm.prank(executor);
        manager.executeWithdrawal(requestId);

        IWithdrawalManager.WithdrawalRequest memory request = manager.getRequest(requestId);
        assertEq(uint8(request.status), uint8(IWithdrawalManager.WithdrawalStatus.EXECUTED));
    }

    function test_RequestWithdrawal_ValidationOrder() public {
        // When multiple validations fail, the first one encountered should revert.
        // depositId == bytes32(0) is checked first.
        vm.prank(requester);
        vm.expectRevert(IWithdrawalManager.InvalidDepositId.selector);
        manager.requestWithdrawal(bytes32(0), address(0), address(token), 0);
    }

    /* //////////////////////////////////////////////////////////////
                            ROLE CONSTANTS
    ////////////////////////////////////////////////////////////// */

    function test_RoleConstants() public view {
        assertEq(manager.WITHDRAWAL_ADMIN_ROLE(), keccak256("WITHDRAWAL_ADMIN_ROLE"));
        assertEq(manager.APPROVER_ROLE(), keccak256("APPROVER_ROLE"));
        assertEq(manager.EXECUTOR_ROLE(), keccak256("EXECUTOR_ROLE"));
    }

    function test_Constants() public view {
        assertEq(manager.NATIVE_TOKEN(), address(0));
        assertEq(manager.MAX_COOLDOWN(), 7 days);
        assertEq(manager.REQUEST_EXPIRATION(), 30 days);
    }
}
