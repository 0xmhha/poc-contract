// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RegulatoryRegistry
 * @notice Manages regulator registration, permissions, and trace request approvals
 * @dev Implements multi-sig approval (2-of-3) for sensitive trace operations
 *
 * Key Features:
 *   - Regulator registration with jurisdiction and access levels
 *   - Master Regulatory Key (MRK) public key storage
 *   - Trace request management with 2-of-3 multi-sig approval
 *   - Access level-based permission control (1-5)
 */
contract RegulatoryRegistry is AccessControl, Pausable, ReentrancyGuard {
    // ============ Roles ============
    bytes32 public constant REGULATOR_ROLE = keccak256("REGULATOR_ROLE");
    bytes32 public constant APPROVER_ROLE = keccak256("APPROVER_ROLE");

    // ============ Constants ============
    uint256 public constant REQUIRED_APPROVALS = 2;
    uint256 public constant MAX_APPROVERS = 3;
    uint256 public constant REQUEST_EXPIRY = 7 days;

    // ============ Structs ============
    struct Regulator {
        string name;
        string jurisdiction;
        uint8 accessLevel; // 1-5, higher = more access
        bool isActive;
        uint256 registeredAt;
        bytes32 mrkPublicKeyHash; // Hash of Master Regulatory Key public key
    }

    struct TraceRequest {
        uint256 id;
        address regulator;
        address targetAccount;
        bytes32 legalBasisHash; // Hash of legal basis document
        uint256 requestedAt;
        uint256 expiresAt;
        uint8 approvalCount;
        bool isApproved;
        bool isExecuted;
        bool isCancelled;
        string jurisdiction;
        uint8 requiredAccessLevel;
    }

    // ============ State Variables ============
    mapping(address => Regulator) public regulators;
    mapping(uint256 => TraceRequest) public traceRequests;
    mapping(uint256 => mapping(address => bool)) public hasApproved;

    address[] public approverList;
    uint256 public nextRequestId;
    uint256 public activeRegulatorCount;

    // ============ Events ============
    event RegulatorRegistered(address indexed regulator, string name, string jurisdiction, uint8 accessLevel);
    event RegulatorDeactivated(address indexed regulator, string reason);
    event RegulatorReactivated(address indexed regulator);
    event RegulatorAccessLevelUpdated(address indexed regulator, uint8 oldLevel, uint8 newLevel);
    event MRKPublicKeyUpdated(address indexed regulator, bytes32 keyHash);

    event TraceRequestCreated(
        uint256 indexed requestId,
        address indexed regulator,
        address indexed targetAccount,
        bytes32 legalBasisHash,
        string jurisdiction
    );
    event TraceRequestApproved(uint256 indexed requestId, address indexed approver, uint8 approvalCount);
    event TraceRequestFullyApproved(uint256 indexed requestId);
    event TraceRequestExecuted(uint256 indexed requestId, address indexed executor);
    event TraceRequestCancelled(uint256 indexed requestId, address indexed canceller, string reason);
    event TraceRequestExpired(uint256 indexed requestId);

    event ApproverAdded(address indexed approver);
    event ApproverRemoved(address indexed approver);

    // ============ Errors ============
    error InvalidAddress();
    error InvalidAccessLevel();
    error RegulatorNotFound();
    error RegulatorAlreadyExists();
    error RegulatorNotActive();
    error RequestNotFound();
    error RequestAlreadyApproved();
    error RequestAlreadyExecuted();
    error RequestCancelled();
    error RequestExpired();
    error AlreadyApproved();
    error InsufficientApprovals();
    error InsufficientAccessLevel();
    error MaxApproversReached();
    error ApproverNotFound();
    error InvalidJurisdiction();
    error EmptyName();
    error NotRequestCreator();
    error JurisdictionMismatch();

    // ============ Constructor ============
    constructor(address[] memory initialApprovers) {
        if (initialApprovers.length != MAX_APPROVERS) {
            revert InvalidAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        for (uint256 i = 0; i < initialApprovers.length; i++) {
            if (initialApprovers[i] == address(0)) revert InvalidAddress();

            // Check for duplicates
            for (uint256 j = 0; j < i; j++) {
                if (initialApprovers[j] == initialApprovers[i]) {
                    revert InvalidAddress();
                }
            }

            _grantRole(APPROVER_ROLE, initialApprovers[i]);
            approverList.push(initialApprovers[i]);
            emit ApproverAdded(initialApprovers[i]);
        }

        nextRequestId = 1;
    }

    // ============ Regulator Management ============

    /**
     * @notice Register a new regulator
     * @param regulator Address of the regulator
     * @param name Name of the regulatory body
     * @param jurisdiction Jurisdiction code (e.g., "US", "EU", "KR")
     * @param accessLevel Access level (1-5)
     */
    function registerRegulator(address regulator, string calldata name, string calldata jurisdiction, uint8 accessLevel)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (regulator == address(0)) revert InvalidAddress();
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(jurisdiction).length == 0) revert InvalidJurisdiction();
        if (accessLevel == 0 || accessLevel > 5) revert InvalidAccessLevel();
        if (regulators[regulator].registeredAt != 0) revert RegulatorAlreadyExists();

        regulators[regulator] = Regulator({
            name: name,
            jurisdiction: jurisdiction,
            accessLevel: accessLevel,
            isActive: true,
            registeredAt: block.timestamp,
            mrkPublicKeyHash: bytes32(0)
        });

        _grantRole(REGULATOR_ROLE, regulator);
        activeRegulatorCount++;

        emit RegulatorRegistered(regulator, name, jurisdiction, accessLevel);
    }

    /**
     * @notice Deactivate a regulator
     * @param regulator Address of the regulator
     * @param reason Reason for deactivation
     */
    function deactivateRegulator(address regulator, string calldata reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Regulator storage reg = regulators[regulator];
        if (reg.registeredAt == 0) revert RegulatorNotFound();
        if (!reg.isActive) revert RegulatorNotActive();

        reg.isActive = false;
        _revokeRole(REGULATOR_ROLE, regulator);
        activeRegulatorCount--;

        emit RegulatorDeactivated(regulator, reason);
    }

    /**
     * @notice Reactivate a deactivated regulator
     * @param regulator Address of the regulator
     */
    function reactivateRegulator(address regulator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Regulator storage reg = regulators[regulator];
        if (reg.registeredAt == 0) revert RegulatorNotFound();
        if (reg.isActive) revert RegulatorAlreadyExists();

        reg.isActive = true;
        _grantRole(REGULATOR_ROLE, regulator);
        activeRegulatorCount++;

        emit RegulatorReactivated(regulator);
    }

    /**
     * @notice Update regulator access level
     * @param regulator Address of the regulator
     * @param newLevel New access level
     */
    function updateAccessLevel(address regulator, uint8 newLevel) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newLevel == 0 || newLevel > 5) revert InvalidAccessLevel();

        Regulator storage reg = regulators[regulator];
        if (reg.registeredAt == 0) revert RegulatorNotFound();

        uint8 oldLevel = reg.accessLevel;
        reg.accessLevel = newLevel;

        emit RegulatorAccessLevelUpdated(regulator, oldLevel, newLevel);
    }

    /**
     * @notice Store hash of Master Regulatory Key public key
     * @param mrkPublicKeyHash Hash of the MRK public key
     */
    function setMrkPublicKey(bytes32 mrkPublicKeyHash) external onlyRole(REGULATOR_ROLE) {
        Regulator storage reg = regulators[msg.sender];
        if (!reg.isActive) revert RegulatorNotActive();

        reg.mrkPublicKeyHash = mrkPublicKeyHash;
        emit MRKPublicKeyUpdated(msg.sender, mrkPublicKeyHash);
    }

    // ============ Trace Request Management ============

    /**
     * @notice Create a trace request for a target account
     * @param targetAccount Account to trace
     * @param legalBasisHash Hash of legal basis documentation
     * @param requiredAccessLevel Minimum access level required
     * @return requestId The ID of the created request
     */
    function createTraceRequest(address targetAccount, bytes32 legalBasisHash, uint8 requiredAccessLevel)
        external
        onlyRole(REGULATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        if (targetAccount == address(0)) revert InvalidAddress();
        if (legalBasisHash == bytes32(0)) revert InvalidAddress();
        if (requiredAccessLevel == 0 || requiredAccessLevel > 5) revert InvalidAccessLevel();

        Regulator storage reg = regulators[msg.sender];
        if (!reg.isActive) revert RegulatorNotActive();
        if (reg.accessLevel < requiredAccessLevel) revert InsufficientAccessLevel();

        requestId = nextRequestId++;

        traceRequests[requestId] = TraceRequest({
            id: requestId,
            regulator: msg.sender,
            targetAccount: targetAccount,
            legalBasisHash: legalBasisHash,
            requestedAt: block.timestamp,
            expiresAt: block.timestamp + REQUEST_EXPIRY,
            approvalCount: 0,
            isApproved: false,
            isExecuted: false,
            isCancelled: false,
            jurisdiction: reg.jurisdiction,
            requiredAccessLevel: requiredAccessLevel
        });

        emit TraceRequestCreated(requestId, msg.sender, targetAccount, legalBasisHash, reg.jurisdiction);
    }

    /**
     * @notice Approve a trace request (requires 2-of-3 approvers)
     * @param requestId ID of the trace request
     */
    function approveTraceRequest(uint256 requestId) external onlyRole(APPROVER_ROLE) whenNotPaused nonReentrant {
        TraceRequest storage request = traceRequests[requestId];

        if (request.id == 0) revert RequestNotFound();
        if (request.isCancelled) revert RequestCancelled();
        if (request.isApproved) revert RequestAlreadyApproved();
        if (block.timestamp > request.expiresAt) {
            emit TraceRequestExpired(requestId);
            revert RequestExpired();
        }
        if (hasApproved[requestId][msg.sender]) revert AlreadyApproved();

        hasApproved[requestId][msg.sender] = true;
        request.approvalCount++;

        emit TraceRequestApproved(requestId, msg.sender, request.approvalCount);

        if (request.approvalCount >= REQUIRED_APPROVALS) {
            request.isApproved = true;
            emit TraceRequestFullyApproved(requestId);
        }
    }

    /**
     * @notice Execute an approved trace request
     * @param requestId ID of the trace request
     */
    function executeTraceRequest(uint256 requestId) external onlyRole(REGULATOR_ROLE) whenNotPaused nonReentrant {
        TraceRequest storage request = traceRequests[requestId];

        if (request.id == 0) revert RequestNotFound();
        if (request.isCancelled) revert RequestCancelled();
        if (request.isExecuted) revert RequestAlreadyExecuted();
        if (!request.isApproved) revert InsufficientApprovals();
        if (block.timestamp > request.expiresAt) {
            emit TraceRequestExpired(requestId);
            revert RequestExpired();
        }

        Regulator storage reg = regulators[msg.sender];
        if (!reg.isActive) revert RegulatorNotActive();
        if (reg.accessLevel < request.requiredAccessLevel) revert InsufficientAccessLevel();
        if (keccak256(bytes(reg.jurisdiction)) != keccak256(bytes(request.jurisdiction))) {
            revert JurisdictionMismatch();
        }

        request.isExecuted = true;

        emit TraceRequestExecuted(requestId, msg.sender);
    }

    /**
     * @notice Cancel a trace request (only by creator or admin)
     * @param requestId ID of the trace request
     * @param reason Reason for cancellation
     */
    function cancelTraceRequest(uint256 requestId, string calldata reason) external {
        TraceRequest storage request = traceRequests[requestId];

        if (request.id == 0) revert RequestNotFound();
        if (request.isCancelled) revert RequestCancelled();
        if (request.isExecuted) revert RequestAlreadyExecuted();

        bool isCreator = msg.sender == request.regulator;
        bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE, msg.sender);

        if (!isCreator && !isAdmin) revert NotRequestCreator();

        request.isCancelled = true;

        emit TraceRequestCancelled(requestId, msg.sender, reason);
    }

    // ============ Approver Management ============

    /**
     * @notice Replace an approver
     * @param oldApprover Address of approver to remove
     * @param newApprover Address of new approver
     */
    function replaceApprover(address oldApprover, address newApprover) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newApprover == address(0)) revert InvalidAddress();
        if (!hasRole(APPROVER_ROLE, oldApprover)) revert ApproverNotFound();
        if (hasRole(APPROVER_ROLE, newApprover)) revert MaxApproversReached();

        _revokeRole(APPROVER_ROLE, oldApprover);
        _grantRole(APPROVER_ROLE, newApprover);

        // Update approver list
        for (uint256 i = 0; i < approverList.length; i++) {
            if (approverList[i] == oldApprover) {
                approverList[i] = newApprover;
                break;
            }
        }

        emit ApproverRemoved(oldApprover);
        emit ApproverAdded(newApprover);
    }

    // ============ View Functions ============

    /**
     * @notice Get regulator details
     * @param regulator Address of the regulator
     * @return Regulator struct
     */
    function getRegulator(address regulator) external view returns (Regulator memory) {
        return regulators[regulator];
    }

    /**
     * @notice Get trace request details
     * @param requestId ID of the trace request
     * @return TraceRequest struct
     */
    function getTraceRequest(uint256 requestId) external view returns (TraceRequest memory) {
        return traceRequests[requestId];
    }

    /**
     * @notice Check if an address is an active regulator
     * @param account Address to check
     * @return bool True if active regulator
     */
    function isActiveRegulator(address account) external view returns (bool) {
        return regulators[account].isActive;
    }

    /**
     * @notice Get all approvers
     * @return Array of approver addresses
     */
    function getApprovers() external view returns (address[] memory) {
        return approverList;
    }

    /**
     * @notice Check if a trace request is ready for execution
     * @param requestId ID of the trace request
     * @return ready True if ready
     * @return reason Reason if not ready
     */
    function canExecuteTraceRequest(uint256 requestId) external view returns (bool ready, string memory reason) {
        TraceRequest storage request = traceRequests[requestId];

        if (request.id == 0) return (false, "Request not found");
        if (request.isCancelled) return (false, "Request cancelled");
        if (request.isExecuted) return (false, "Already executed");
        if (!request.isApproved) return (false, "Insufficient approvals");
        if (block.timestamp > request.expiresAt) return (false, "Request expired");

        return (true, "");
    }

    /**
     * @notice Get pending trace requests count for a regulator
     * @param regulator Address of the regulator
     * @return count Number of pending requests
     */
    function getPendingRequestCount(address regulator) external view returns (uint256 count) {
        for (uint256 i = 1; i < nextRequestId; i++) {
            TraceRequest storage request = traceRequests[i];
            if (
                request.regulator == regulator && !request.isExecuted && !request.isCancelled
                    && block.timestamp <= request.expiresAt
            ) {
                count++;
            }
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
