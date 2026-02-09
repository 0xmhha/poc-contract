// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IWithdrawalManager
 * @notice Interface for Enterprise Withdrawal Manager
 */
interface IWithdrawalManager {
    /* //////////////////////////////////////////////////////////////
                                 STRUCTS
    ////////////////////////////////////////////////////////////// */

    struct WithdrawalRequest {
        bytes32 depositId;
        address requester;
        address recipient;
        address token;
        uint256 amount;
        uint256 requestedAt;
        uint256 cooldownEnd;
        WithdrawalStatus status;
        bytes32 approvalHash;
    }

    enum WithdrawalStatus {
        PENDING,
        APPROVED,
        EXECUTED,
        REJECTED,
        CANCELLED,
        EXPIRED
    }

    /* //////////////////////////////////////////////////////////////
                                 EVENTS
    ////////////////////////////////////////////////////////////// */

    event WithdrawalRequested(
        bytes32 indexed requestId, bytes32 indexed depositId, address indexed requester, uint256 amount
    );

    event WithdrawalApproved(bytes32 indexed requestId, address indexed approver);

    event WithdrawalExecuted(bytes32 indexed requestId, address indexed recipient, uint256 amount);

    event WithdrawalRejected(bytes32 indexed requestId, address indexed rejector, string reason);

    event WithdrawalCancelled(bytes32 indexed requestId, address indexed canceller);

    event CooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /* //////////////////////////////////////////////////////////////
                                 ERRORS
    ////////////////////////////////////////////////////////////// */

    error InvalidDepositId();
    error InvalidRecipient();
    error InvalidAmount();
    error RequestNotFound();
    error RequestNotPending();
    error CooldownNotElapsed();
    error RequestExpired();
    error AlreadyApproved();
    error Unauthorized();
    error TransferFailed();
    error AmountExceedsThreshold();
}

/**
 * @title WithdrawalManager
 * @notice Enterprise-grade withdrawal management with cooldown and approval workflow
 * @dev Manages withdrawal requests with time-based cooldowns and multi-sig approval for large amounts
 *
 * Features:
 *   - Configurable cooldown periods
 *   - Threshold-based approval requirements
 *   - Request expiration
 *   - Cancellation support
 *   - Audit trail
 */
contract WithdrawalManager is IWithdrawalManager, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* //////////////////////////////////////////////////////////////
                                 ROLES
    ////////////////////////////////////////////////////////////// */

    bytes32 public constant WITHDRAWAL_ADMIN_ROLE = keccak256("WITHDRAWAL_ADMIN_ROLE");
    bytes32 public constant APPROVER_ROLE = keccak256("APPROVER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /* //////////////////////////////////////////////////////////////
                              CONSTANTS
    ////////////////////////////////////////////////////////////// */

    /// @notice Address representing native ETH
    address public constant NATIVE_TOKEN = address(0);

    /// @notice Maximum cooldown period (7 days)
    uint256 public constant MAX_COOLDOWN = 7 days;

    /// @notice Request expiration period (30 days)
    uint256 public constant REQUEST_EXPIRATION = 30 days;

    /* //////////////////////////////////////////////////////////////
                            STATE VARIABLES
    ////////////////////////////////////////////////////////////// */

    /// @notice Mapping from request ID to WithdrawalRequest
    mapping(bytes32 requestId => WithdrawalRequest) public requests;

    /// @notice Mapping from deposit ID to request IDs
    mapping(bytes32 depositId => bytes32[]) public depositRequests;

    /// @notice Mapping from requester to their request IDs
    mapping(address requester => bytes32[]) public requesterRequests;

    /// @notice Cooldown period before withdrawal can be executed
    uint256 public cooldownPeriod;

    /// @notice Amount threshold above which approval is required
    uint256 public approvalThreshold;

    /// @notice Total request count
    uint256 public requestCount;

    /// @notice Reference to the StealthVault contract
    address public stealthVault;

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    ////////////////////////////////////////////////////////////// */

    constructor(address _admin, uint256 _cooldownPeriod, uint256 _approvalThreshold) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(WITHDRAWAL_ADMIN_ROLE, _admin);
        _grantRole(APPROVER_ROLE, _admin);
        _grantRole(EXECUTOR_ROLE, _admin);

        cooldownPeriod = _cooldownPeriod;
        approvalThreshold = _approvalThreshold;
    }

    /* //////////////////////////////////////////////////////////////
                        WITHDRAWAL REQUEST FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Request a withdrawal
     * @param depositId The deposit ID to withdraw from
     * @param recipient The recipient address
     * @param token The token address
     * @param amount The amount to withdraw
     * @return requestId The unique request ID
     */
    function requestWithdrawal(bytes32 depositId, address recipient, address token, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 requestId)
    {
        if (depositId == bytes32(0)) revert InvalidDepositId();
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();

        requestId = keccak256(abi.encodePacked(depositId, msg.sender, recipient, amount, block.timestamp, requestCount));

        uint256 cooldownEnd = block.timestamp + cooldownPeriod;

        requests[requestId] = WithdrawalRequest({
            depositId: depositId,
            requester: msg.sender,
            recipient: recipient,
            token: token,
            amount: amount,
            requestedAt: block.timestamp,
            cooldownEnd: cooldownEnd,
            status: WithdrawalStatus.PENDING,
            approvalHash: bytes32(0)
        });

        depositRequests[depositId].push(requestId);
        requesterRequests[msg.sender].push(requestId);
        requestCount++;

        emit WithdrawalRequested(requestId, depositId, msg.sender, amount);
    }

    /**
     * @notice Approve a withdrawal request (required for amounts above threshold)
     * @param requestId The request ID to approve
     */
    function approveWithdrawal(bytes32 requestId) external onlyRole(APPROVER_ROLE) whenNotPaused {
        WithdrawalRequest storage request = requests[requestId];

        if (request.requester == address(0)) revert RequestNotFound();
        if (request.status != WithdrawalStatus.PENDING) revert RequestNotPending();
        if (request.approvalHash != bytes32(0)) revert AlreadyApproved();

        // Check if request has expired
        if (block.timestamp > request.requestedAt + REQUEST_EXPIRATION) {
            request.status = WithdrawalStatus.EXPIRED;
            revert RequestExpired();
        }

        request.approvalHash = keccak256(abi.encodePacked(msg.sender, block.timestamp));
        request.status = WithdrawalStatus.APPROVED;

        emit WithdrawalApproved(requestId, msg.sender);
    }

    /**
     * @notice Execute a withdrawal request
     * @param requestId The request ID to execute
     */
    function executeWithdrawal(bytes32 requestId) external onlyRole(EXECUTOR_ROLE) whenNotPaused nonReentrant {
        WithdrawalRequest storage request = requests[requestId];

        if (request.requester == address(0)) revert RequestNotFound();

        // Check if request has expired
        if (block.timestamp > request.requestedAt + REQUEST_EXPIRATION) {
            request.status = WithdrawalStatus.EXPIRED;
            revert RequestExpired();
        }

        // Verify status
        if (request.amount >= approvalThreshold) {
            // Requires approval for large amounts
            if (request.status != WithdrawalStatus.APPROVED) revert RequestNotPending();
        } else {
            // Auto-approved for small amounts
            if (request.status != WithdrawalStatus.PENDING && request.status != WithdrawalStatus.APPROVED) {
                revert RequestNotPending();
            }
        }

        // Check cooldown
        if (block.timestamp < request.cooldownEnd) revert CooldownNotElapsed();

        request.status = WithdrawalStatus.EXECUTED;

        // Transfer funds
        if (request.token == NATIVE_TOKEN) {
            (bool success,) = request.recipient.call{ value: request.amount }("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(request.token).safeTransfer(request.recipient, request.amount);
        }

        emit WithdrawalExecuted(requestId, request.recipient, request.amount);
    }

    /**
     * @notice Reject a withdrawal request
     * @param requestId The request ID to reject
     * @param reason The reason for rejection
     */
    function rejectWithdrawal(bytes32 requestId, string calldata reason)
        external
        onlyRole(APPROVER_ROLE)
        whenNotPaused
    {
        WithdrawalRequest storage request = requests[requestId];

        if (request.requester == address(0)) revert RequestNotFound();
        if (request.status != WithdrawalStatus.PENDING) revert RequestNotPending();

        request.status = WithdrawalStatus.REJECTED;

        emit WithdrawalRejected(requestId, msg.sender, reason);
    }

    /**
     * @notice Cancel a withdrawal request (by requester)
     * @param requestId The request ID to cancel
     */
    function cancelWithdrawal(bytes32 requestId) external whenNotPaused {
        WithdrawalRequest storage request = requests[requestId];

        if (request.requester == address(0)) revert RequestNotFound();
        if (request.requester != msg.sender) revert Unauthorized();
        if (request.status != WithdrawalStatus.PENDING && request.status != WithdrawalStatus.APPROVED) {
            revert RequestNotPending();
        }

        request.status = WithdrawalStatus.CANCELLED;

        emit WithdrawalCancelled(requestId, msg.sender);
    }

    /* //////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Get withdrawal request details
     * @param requestId The request ID
     * @return request The withdrawal request details
     */
    function getRequest(bytes32 requestId) external view returns (WithdrawalRequest memory) {
        return requests[requestId];
    }

    /**
     * @notice Get all requests for a deposit
     * @param depositId The deposit ID
     * @return requestIds Array of request IDs
     */
    function getDepositRequests(bytes32 depositId) external view returns (bytes32[] memory) {
        return depositRequests[depositId];
    }

    /**
     * @notice Get all requests by a requester
     * @param requester The requester address
     * @return requestIds Array of request IDs
     */
    function getRequesterRequests(address requester) external view returns (bytes32[] memory) {
        return requesterRequests[requester];
    }

    /**
     * @notice Check if a request can be executed
     * @param requestId The request ID
     * @return executable True if the request can be executed
     * @return reason The reason if it cannot be executed
     */
    function canExecute(bytes32 requestId) external view returns (bool executable, string memory reason) {
        WithdrawalRequest storage request = requests[requestId];

        if (request.requester == address(0)) {
            return (false, "Request not found");
        }

        if (block.timestamp > request.requestedAt + REQUEST_EXPIRATION) {
            return (false, "Request expired");
        }

        if (request.status == WithdrawalStatus.EXECUTED) {
            return (false, "Already executed");
        }

        if (request.status == WithdrawalStatus.REJECTED) {
            return (false, "Request rejected");
        }

        if (request.status == WithdrawalStatus.CANCELLED) {
            return (false, "Request cancelled");
        }

        if (request.amount >= approvalThreshold && request.status != WithdrawalStatus.APPROVED) {
            return (false, "Approval required");
        }

        if (block.timestamp < request.cooldownEnd) {
            return (false, "Cooldown not elapsed");
        }

        return (true, "");
    }

    /* //////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Update the cooldown period
     * @param _cooldownPeriod The new cooldown period
     */
    function setCooldownPeriod(uint256 _cooldownPeriod) external onlyRole(WITHDRAWAL_ADMIN_ROLE) {
        require(_cooldownPeriod <= MAX_COOLDOWN, "Cooldown too long");

        uint256 oldCooldown = cooldownPeriod;
        cooldownPeriod = _cooldownPeriod;

        emit CooldownUpdated(oldCooldown, _cooldownPeriod);
    }

    /**
     * @notice Update the approval threshold
     * @param _approvalThreshold The new approval threshold
     */
    function setApprovalThreshold(uint256 _approvalThreshold) external onlyRole(WITHDRAWAL_ADMIN_ROLE) {
        uint256 oldThreshold = approvalThreshold;
        approvalThreshold = _approvalThreshold;

        emit ThresholdUpdated(oldThreshold, _approvalThreshold);
    }

    /**
     * @notice Set the stealth vault address
     * @param _stealthVault The stealth vault address
     */
    function setStealthVault(address _stealthVault) external onlyRole(WITHDRAWAL_ADMIN_ROLE) {
        stealthVault = _stealthVault;
    }

    /**
     * @notice Pause the manager
     */
    function pause() external onlyRole(WITHDRAWAL_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the manager
     */
    function unpause() external onlyRole(WITHDRAWAL_ADMIN_ROLE) {
        _unpause();
    }

    /* //////////////////////////////////////////////////////////////
                          RECEIVE / FALLBACK
    ////////////////////////////////////////////////////////////// */

    receive() external payable { }
}
