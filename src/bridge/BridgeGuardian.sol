// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BridgeGuardian
 * @notice Emergency response system with 3-of-5 multisig for bridge security
 * @dev Implements guardian-based emergency controls for bridge operations
 *
 * Guardian Actions:
 * - Emergency pause (immediate, any single guardian)
 * - Blacklist management (3-of-5 approval)
 * - Configuration updates (3-of-5 approval)
 * - Recovery operations (3-of-5 approval)
 */
contract BridgeGuardian is Ownable, ReentrancyGuard {
    // ============ Errors ============
    error InvalidGuardianCount();
    error InvalidThreshold();
    error GuardianAlreadyExists();
    error GuardianNotFound();
    error NotAGuardian();
    error ProposalNotFound();
    error ProposalAlreadyExecuted();
    error ProposalExpired();
    error AlreadyVoted();
    error InsufficientApprovals();
    error ProposalNotApproved();
    error InvalidTarget();
    error ExecutionFailed();
    error ZeroAddress();
    error CooldownActive();
    error AlreadyPaused();
    error NotPaused();
    error InvalidAction();

    // ============ Events ============
    event GuardianAdded(address indexed guardian, uint256 totalGuardians);
    event GuardianRemoved(address indexed guardian, uint256 totalGuardians);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event ProposalCreated(
        uint256 indexed proposalId, ProposalType proposalType, address indexed proposer, bytes32 dataHash
    );
    event ProposalApproved(uint256 indexed proposalId, address indexed guardian, uint256 approvalCount);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);
    event ProposalCancelled(uint256 indexed proposalId, address indexed canceller);
    event EmergencyPause(address indexed guardian, string reason);
    event EmergencyUnpause(address indexed executor, uint256 proposalId);
    event AddressBlacklisted(address indexed account, string reason);
    event AddressWhitelisted(address indexed account);
    event BridgeTargetUpdated(address indexed oldTarget, address indexed newTarget);
    event RecoveryExecuted(uint256 indexed proposalId, address indexed target, bytes data);
    event BridgePauseCallFailed(address indexed bridgeTarget);

    // ============ Enums ============

    /**
     * @notice Types of proposals that can be created
     */
    enum ProposalType {
        None,
        Unpause, // Unpause the bridge
        Blacklist, // Blacklist an address
        Whitelist, // Remove from blacklist
        UpdateConfig, // Update bridge configuration
        Recovery, // Execute recovery action
        AddGuardian, // Add a new guardian
        RemoveGuardian, // Remove a guardian
        UpdateThreshold // Update approval threshold
    }

    /**
     * @notice Status of a proposal
     */
    enum ProposalStatus {
        Pending,
        Approved,
        Executed,
        Cancelled,
        Expired
    }

    // ============ Structs ============

    /**
     * @notice Structure for guardian proposals
     * @param id Unique proposal identifier
     * @param proposalType Type of action proposed
     * @param proposer Address that created the proposal
     * @param target Target address for the action
     * @param data Encoded action data
     * @param dataHash Hash of the proposal data
     * @param approvalCount Number of guardian approvals
     * @param createdAt Timestamp of creation
     * @param expiresAt Timestamp when proposal expires
     * @param status Current status
     */
    struct Proposal {
        uint256 id;
        ProposalType proposalType;
        address proposer;
        address target;
        bytes data;
        bytes32 dataHash;
        uint256 approvalCount;
        uint256 createdAt;
        uint256 expiresAt;
        ProposalStatus status;
    }

    // ============ Constants ============
    uint256 public constant MIN_GUARDIANS = 3;
    uint256 public constant MAX_GUARDIANS = 15;
    uint256 public constant PROPOSAL_DURATION = 7 days;
    uint256 public constant EMERGENCY_COOLDOWN = 1 hours;

    // ============ State Variables ============

    /// @notice Array of guardian addresses
    address[] public guardians;

    /// @notice Mapping to check if address is a guardian
    mapping(address => bool) public isGuardian;

    /// @notice Required approvals for proposals (3-of-5 default)
    uint256 public threshold;

    /// @notice Counter for proposal IDs
    uint256 public proposalCount;

    /// @notice Mapping of proposal ID to Proposal
    mapping(uint256 => Proposal) public proposals;

    /// @notice Mapping of proposal ID to guardian to approval status
    mapping(uint256 => mapping(address => bool)) public hasApproved;

    /// @notice Blacklisted addresses
    mapping(address => bool) public blacklisted;

    /// @notice Address of the main bridge contract
    address public bridgeTarget;

    /// @notice Whether the bridge is paused by guardian
    bool public guardianPaused;

    /// @notice Last emergency action timestamp
    uint256 public lastEmergencyAction;

    /// @notice Guardian who triggered emergency pause
    address public emergencyPauser;

    // ============ Modifiers ============

    modifier onlyGuardian() {
        _checkGuardian();
        _;
    }

    function _checkGuardian() internal view {
        if (!isGuardian[msg.sender]) revert NotAGuardian();
    }

    // ============ Constructor ============

    /**
     * @notice Initialize the BridgeGuardian with initial guardians
     * @param initialGuardians Array of initial guardian addresses (min 3, max 15)
     * @param initialThreshold Initial approval threshold (e.g., 3 for 3-of-5)
     */
    constructor(address[] memory initialGuardians, uint256 initialThreshold) Ownable(msg.sender) {
        if (initialGuardians.length < MIN_GUARDIANS) revert InvalidGuardianCount();
        if (initialGuardians.length > MAX_GUARDIANS) revert InvalidGuardianCount();
        if (initialThreshold == 0 || initialThreshold > initialGuardians.length) {
            revert InvalidThreshold();
        }

        threshold = initialThreshold;

        for (uint256 i = 0; i < initialGuardians.length; i++) {
            address guardian = initialGuardians[i];
            if (guardian == address(0)) revert ZeroAddress();
            if (isGuardian[guardian]) revert GuardianAlreadyExists();

            guardians.push(guardian);
            isGuardian[guardian] = true;

            emit GuardianAdded(guardian, i + 1);
        }
    }

    // ============ Emergency Functions ============

    /**
     * @notice Emergency pause - any single guardian can trigger
     * @param reason Reason for the emergency pause
     */
    function emergencyPause(string calldata reason) external onlyGuardian {
        if (guardianPaused) revert AlreadyPaused();

        guardianPaused = true;
        emergencyPauser = msg.sender;
        lastEmergencyAction = block.timestamp;

        // Call pause on bridge target if set
        if (bridgeTarget != address(0)) {
            (bool success,) = bridgeTarget.call(abi.encodeWithSignature("pause()"));
            // Don't revert if call fails - guardian pause state is still set
            if (!success) {
                emit BridgePauseCallFailed(bridgeTarget);
            }
        }

        emit EmergencyPause(msg.sender, reason);
    }

    // ============ Proposal Functions ============

    /**
     * @notice Create a new proposal
     * @param proposalType Type of action proposed
     * @param target Target address for the action
     * @param data Encoded action data
     * @return proposalId ID of the created proposal
     */
    function createProposal(ProposalType proposalType, address target, bytes calldata data)
        external
        onlyGuardian
        returns (uint256 proposalId)
    {
        if (proposalType == ProposalType.None) revert InvalidAction();

        proposalCount++;
        proposalId = proposalCount;

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 dataHash = keccak256(abi.encode(proposalType, target, data));

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposalType: proposalType,
            proposer: msg.sender,
            target: target,
            data: data,
            dataHash: dataHash,
            approvalCount: 1, // Proposer auto-approves
            createdAt: block.timestamp,
            expiresAt: block.timestamp + PROPOSAL_DURATION,
            status: ProposalStatus.Pending
        });

        hasApproved[proposalId][msg.sender] = true;

        emit ProposalCreated(proposalId, proposalType, msg.sender, dataHash);
        emit ProposalApproved(proposalId, msg.sender, 1);

        // Check if threshold already met (for 1-of-N scenarios)
        if (proposals[proposalId].approvalCount >= threshold) {
            proposals[proposalId].status = ProposalStatus.Approved;
        }
    }

    /**
     * @notice Approve a pending proposal
     * @param proposalId ID of the proposal to approve
     */
    function approveProposal(uint256 proposalId) external onlyGuardian {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.id == 0) revert ProposalNotFound();
        if (proposal.status != ProposalStatus.Pending) revert ProposalAlreadyExecuted();
        if (block.timestamp > proposal.expiresAt) revert ProposalExpired();
        if (hasApproved[proposalId][msg.sender]) revert AlreadyVoted();

        hasApproved[proposalId][msg.sender] = true;
        proposal.approvalCount++;

        emit ProposalApproved(proposalId, msg.sender, proposal.approvalCount);

        // Check if threshold met
        if (proposal.approvalCount >= threshold) {
            proposal.status = ProposalStatus.Approved;
        }
    }

    /**
     * @notice Execute an approved proposal
     * @param proposalId ID of the proposal to execute
     */
    function executeProposal(uint256 proposalId) external onlyGuardian nonReentrant {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.id == 0) revert ProposalNotFound();
        if (proposal.status == ProposalStatus.Executed) revert ProposalAlreadyExecuted();
        if (proposal.status == ProposalStatus.Cancelled) revert ProposalNotFound();
        if (block.timestamp > proposal.expiresAt) {
            proposal.status = ProposalStatus.Expired;
            revert ProposalExpired();
        }
        if (proposal.approvalCount < threshold) revert InsufficientApprovals();

        proposal.status = ProposalStatus.Executed;

        // Execute based on proposal type
        _executeProposalAction(proposal);

        emit ProposalExecuted(proposalId, msg.sender);
    }

    /**
     * @notice Cancel a pending proposal (only proposer or owner)
     * @param proposalId ID of the proposal to cancel
     */
    function cancelProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.id == 0) revert ProposalNotFound();
        if (proposal.status != ProposalStatus.Pending) revert ProposalAlreadyExecuted();
        if (msg.sender != proposal.proposer && msg.sender != owner()) {
            revert NotAGuardian();
        }

        proposal.status = ProposalStatus.Cancelled;

        emit ProposalCancelled(proposalId, msg.sender);
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the bridge target address
     * @param newTarget New bridge contract address
     */
    function setBridgeTarget(address newTarget) external onlyOwner {
        if (newTarget == address(0)) revert ZeroAddress();

        address oldTarget = bridgeTarget;
        bridgeTarget = newTarget;

        emit BridgeTargetUpdated(oldTarget, newTarget);
    }

    /**
     * @notice Direct guardian addition (owner only, bypasses multisig for initial setup)
     * @param guardian New guardian address
     */
    function addGuardianDirect(address guardian) external onlyOwner {
        if (guardian == address(0)) revert ZeroAddress();
        if (isGuardian[guardian]) revert GuardianAlreadyExists();
        if (guardians.length >= MAX_GUARDIANS) revert InvalidGuardianCount();

        guardians.push(guardian);
        isGuardian[guardian] = true;

        emit GuardianAdded(guardian, guardians.length);
    }

    /**
     * @notice Direct guardian removal (owner only, bypasses multisig for emergency)
     * @param guardian Guardian address to remove
     */
    function removeGuardianDirect(address guardian) external onlyOwner {
        if (!isGuardian[guardian]) revert GuardianNotFound();
        if (guardians.length <= MIN_GUARDIANS) revert InvalidGuardianCount();
        if (guardians.length - 1 < threshold) revert InvalidThreshold();

        _removeGuardian(guardian);
    }

    /**
     * @notice Update threshold (owner only for emergency)
     * @param newThreshold New approval threshold
     */
    function updateThresholdDirect(uint256 newThreshold) external onlyOwner {
        if (newThreshold == 0 || newThreshold > guardians.length) revert InvalidThreshold();

        uint256 oldThreshold = threshold;
        threshold = newThreshold;

        emit ThresholdUpdated(oldThreshold, newThreshold);
    }

    // ============ View Functions ============

    /**
     * @notice Get all guardians
     * @return Array of guardian addresses
     */
    function getGuardians() external view returns (address[] memory) {
        return guardians;
    }

    /**
     * @notice Get guardian count
     * @return Number of guardians
     */
    function getGuardianCount() external view returns (uint256) {
        return guardians.length;
    }

    /**
     * @notice Get proposal details
     * @param proposalId ID of the proposal
     * @return proposal The proposal struct
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    /**
     * @notice Check if a guardian has approved a proposal
     * @param proposalId ID of the proposal
     * @param guardian Guardian address
     * @return approved Whether the guardian has approved
     */
    function hasGuardianApproved(uint256 proposalId, address guardian) external view returns (bool) {
        return hasApproved[proposalId][guardian];
    }

    /**
     * @notice Check if an address is blacklisted
     * @param account Address to check
     * @return blacklistedStatus Whether the address is blacklisted
     */
    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }

    /**
     * @notice Get current pause status
     * @return paused Whether guardian pause is active
     * @return pauser Address that triggered pause
     * @return pausedAt Timestamp of pause
     */
    function getPauseStatus() external view returns (bool paused, address pauser, uint256 pausedAt) {
        return (guardianPaused, emergencyPauser, lastEmergencyAction);
    }

    /**
     * @notice Check if a proposal can be executed
     * @param proposalId ID of the proposal
     * @return canExecute Whether the proposal can be executed
     * @return reason Reason if cannot execute
     */
    function canExecuteProposal(uint256 proposalId) external view returns (bool canExecute, string memory reason) {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.id == 0) return (false, "Proposal not found");
        if (proposal.status == ProposalStatus.Executed) return (false, "Already executed");
        if (proposal.status == ProposalStatus.Cancelled) return (false, "Cancelled");
        if (block.timestamp > proposal.expiresAt) return (false, "Expired");
        if (proposal.approvalCount < threshold) return (false, "Insufficient approvals");

        return (true, "");
    }

    // ============ Internal Functions ============

    /**
     * @notice Execute the action for a proposal
     * @param proposal The proposal to execute
     */
    function _executeProposalAction(Proposal storage proposal) internal {
        if (proposal.proposalType == ProposalType.Unpause) {
            _executeUnpause(proposal);
        } else if (proposal.proposalType == ProposalType.Blacklist) {
            _executeBlacklist(proposal);
        } else if (proposal.proposalType == ProposalType.Whitelist) {
            _executeWhitelist(proposal);
        } else if (proposal.proposalType == ProposalType.UpdateConfig) {
            _executeUpdateConfig(proposal);
        } else if (proposal.proposalType == ProposalType.Recovery) {
            _executeRecovery(proposal);
        } else if (proposal.proposalType == ProposalType.AddGuardian) {
            _executeAddGuardian(proposal);
        } else if (proposal.proposalType == ProposalType.RemoveGuardian) {
            _executeRemoveGuardian(proposal);
        } else if (proposal.proposalType == ProposalType.UpdateThreshold) {
            _executeUpdateThreshold(proposal);
        }
    }

    /**
     * @notice Execute unpause proposal
     */
    function _executeUnpause(Proposal storage proposal) internal {
        if (!guardianPaused) revert NotPaused();

        guardianPaused = false;
        emergencyPauser = address(0);

        // Call unpause on bridge target if set
        if (bridgeTarget != address(0)) {
            (bool success,) = bridgeTarget.call(abi.encodeWithSignature("unpause()"));
            if (!success) {
                // Log but continue
            }
        }

        emit EmergencyUnpause(msg.sender, proposal.id);
    }

    /**
     * @notice Execute blacklist proposal
     */
    function _executeBlacklist(Proposal storage proposal) internal {
        address account = proposal.target;
        string memory reason = abi.decode(proposal.data, (string));

        blacklisted[account] = true;

        emit AddressBlacklisted(account, reason);
    }

    /**
     * @notice Execute whitelist (remove from blacklist) proposal
     */
    function _executeWhitelist(Proposal storage proposal) internal {
        address account = proposal.target;

        blacklisted[account] = false;

        emit AddressWhitelisted(account);
    }

    /**
     * @notice Execute config update proposal
     */
    function _executeUpdateConfig(Proposal storage proposal) internal {
        if (proposal.target == address(0)) revert InvalidTarget();

        // Execute the config update call
        (bool success,) = proposal.target.call(proposal.data);
        if (!success) revert ExecutionFailed();
    }

    /**
     * @notice Execute recovery proposal
     */
    function _executeRecovery(Proposal storage proposal) internal {
        if (proposal.target == address(0)) revert InvalidTarget();

        // Execute the recovery call
        (bool success,) = proposal.target.call(proposal.data);
        if (!success) revert ExecutionFailed();

        emit RecoveryExecuted(proposal.id, proposal.target, proposal.data);
    }

    /**
     * @notice Execute add guardian proposal
     */
    function _executeAddGuardian(Proposal storage proposal) internal {
        address newGuardian = proposal.target;

        if (newGuardian == address(0)) revert ZeroAddress();
        if (isGuardian[newGuardian]) revert GuardianAlreadyExists();
        if (guardians.length >= MAX_GUARDIANS) revert InvalidGuardianCount();

        guardians.push(newGuardian);
        isGuardian[newGuardian] = true;

        emit GuardianAdded(newGuardian, guardians.length);
    }

    /**
     * @notice Execute remove guardian proposal
     */
    function _executeRemoveGuardian(Proposal storage proposal) internal {
        address guardianToRemove = proposal.target;

        if (!isGuardian[guardianToRemove]) revert GuardianNotFound();
        if (guardians.length <= MIN_GUARDIANS) revert InvalidGuardianCount();
        if (guardians.length - 1 < threshold) revert InvalidThreshold();

        _removeGuardian(guardianToRemove);
    }

    /**
     * @notice Execute threshold update proposal
     */
    function _executeUpdateThreshold(Proposal storage proposal) internal {
        uint256 newThreshold = abi.decode(proposal.data, (uint256));

        if (newThreshold == 0 || newThreshold > guardians.length) revert InvalidThreshold();

        uint256 oldThreshold = threshold;
        threshold = newThreshold;

        emit ThresholdUpdated(oldThreshold, newThreshold);
    }

    /**
     * @notice Remove a guardian from the array
     */
    function _removeGuardian(address guardian) internal {
        uint256 guardianIndex = type(uint256).max;
        for (uint256 i = 0; i < guardians.length; i++) {
            if (guardians[i] == guardian) {
                guardianIndex = i;
                break;
            }
        }

        // Move last element to removed position and pop
        guardians[guardianIndex] = guardians[guardians.length - 1];
        guardians.pop();

        isGuardian[guardian] = false;

        emit GuardianRemoved(guardian, guardians.length);
    }
}
