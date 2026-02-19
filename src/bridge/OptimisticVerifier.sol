// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OptimisticVerifier
 * @notice Optimistic verification with challenge period for bridge requests
 * @dev Implements challenge-based security with fraud proof integration
 *
 * Security Features:
 * - Configurable challenge period (6h PoC, 24h mainnet)
 * - Challenge bond mechanism to prevent spam
 * - Integration with FraudProofVerifier for dispute resolution
 * - Status tracking for all bridge requests
 */
contract OptimisticVerifier is Ownable, Pausable, ReentrancyGuard {
    // ============ Errors ============
    error InvalidRequest();
    error RequestNotFound();
    error RequestAlreadyExists();
    error ChallengePeriodNotEnded();
    error ChallengePeriodEnded();
    error RequestNotPending();
    error RequestNotChallenged();
    error InsufficientChallengeBond();
    error ChallengerNotFound();
    error InvalidFraudProofVerifier();
    error UnauthorizedCaller();
    error RequestAlreadyExecuted();
    error RequestAlreadyCancelled();
    error InvalidChallengePeriod();
    error ZeroAddress();
    error TransferFailed();
    error InvalidStatus();

    // ============ Events ============
    event RequestSubmitted(
        bytes32 indexed requestId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 sourceChain,
        uint256 targetChain,
        uint256 challengeDeadline
    );
    event RequestChallenged(bytes32 indexed requestId, address indexed challenger, uint256 bondAmount, string reason);
    event ChallengeResolved(
        bytes32 indexed requestId, bool challengeSuccessful, address indexed challenger, uint256 reward
    );
    event RequestApproved(bytes32 indexed requestId, uint256 timestamp);
    event RequestExecuted(bytes32 indexed requestId, uint256 timestamp);
    event RequestRefunded(bytes32 indexed requestId, uint256 timestamp);
    event RequestCancelled(bytes32 indexed requestId, string reason);
    event ChallengePeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event ChallengeBondUpdated(uint256 oldBond, uint256 newBond);
    event ChallengerRewardUpdated(uint256 oldReward, uint256 newReward);
    event FraudProofVerifierUpdated(address oldVerifier, address newVerifier);
    event AuthorizedCallerUpdated(address indexed caller, bool authorized);

    // ============ Enums ============

    /**
     * @notice Status of a bridge request
     */
    enum RequestStatus {
        None, // Request doesn't exist
        Pending, // Submitted, in challenge period
        Approved, // Challenge period passed, ready for execution
        Challenged, // Currently being challenged
        Executed, // Successfully executed
        Refunded, // Refunded due to successful challenge
        Cancelled // Cancelled by admin/guardian
    }

    // ============ Structs ============

    /**
     * @notice Structure for bridge requests
     * @param id Unique request identifier
     * @param sender Address of sender on source chain
     * @param recipient Address of recipient on target chain
     * @param token Token address being bridged
     * @param amount Amount of tokens
     * @param sourceChain Source chain ID
     * @param targetChain Target chain ID
     * @param submittedAt Timestamp when request was submitted
     * @param challengeDeadline Timestamp when challenge period ends
     * @param status Current status of the request
     */
    struct BridgeRequest {
        bytes32 id;
        address sender;
        address recipient;
        address token;
        uint256 amount;
        uint256 sourceChain;
        uint256 targetChain;
        uint256 submittedAt;
        uint256 challengeDeadline;
        RequestStatus status;
    }

    /**
     * @notice Structure for challenge information
     * @param challenger Address of the challenger
     * @param bondAmount Amount of bond deposited
     * @param reason Reason for the challenge
     * @param challengedAt Timestamp when challenge was made
     * @param resolved Whether challenge has been resolved
     */
    struct Challenge {
        address challenger;
        uint256 bondAmount;
        string reason;
        uint256 challengedAt;
        bool resolved;
    }

    // ============ Constants ============
    uint256 public constant MIN_CHALLENGE_PERIOD = 1 hours;
    uint256 public constant MAX_CHALLENGE_PERIOD = 7 days;
    uint256 public constant MIN_CHALLENGE_BOND = 0.01 ether;

    // ============ State Variables ============

    /// @notice Challenge period duration (default: 6 hours for PoC)
    uint256 public challengePeriod = 6 hours;

    /// @notice Required bond for challenging (default: 1 ETH)
    uint256 public challengeBond = 1 ether;

    /// @notice Reward for successful challenger (default: 0.5 ETH)
    uint256 public challengerReward = 0.5 ether;

    /// @notice Address of the FraudProofVerifier contract
    address public fraudProofVerifier;

    /// @notice Mapping of request ID to BridgeRequest
    mapping(bytes32 => BridgeRequest) public requests;

    /// @notice Mapping of request ID to Challenge
    mapping(bytes32 => Challenge) public challenges;

    /// @notice Mapping of authorized callers (bridge contracts)
    mapping(address => bool) public authorizedCallers;

    /// @notice Total number of requests
    uint256 public totalRequests;

    /// @notice Total number of successful challenges
    uint256 public totalSuccessfulChallenges;

    // ============ Modifiers ============

    modifier onlyAuthorized() {
        _checkAuthorized();
        _;
    }

    function _checkAuthorized() internal view {
        if (!authorizedCallers[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedCaller();
        }
    }

    // ============ Constructor ============

    /**
     * @notice Initialize the OptimisticVerifier
     * @param _challengePeriod Initial challenge period duration
     * @param _challengeBond Initial challenge bond amount
     * @param _challengerReward Initial challenger reward amount
     */
    constructor(uint256 _challengePeriod, uint256 _challengeBond, uint256 _challengerReward) Ownable(msg.sender) {
        if (_challengePeriod < MIN_CHALLENGE_PERIOD || _challengePeriod > MAX_CHALLENGE_PERIOD) {
            revert InvalidChallengePeriod();
        }

        challengePeriod = _challengePeriod;
        challengeBond = _challengeBond;
        challengerReward = _challengerReward;
    }

    // ============ External Functions ============

    /**
     * @notice Submit a new bridge request for optimistic verification
     * @param requestId Unique identifier for the request
     * @param sender Address of the sender
     * @param recipient Address of the recipient
     * @param token Token address
     * @param amount Amount being bridged
     * @param sourceChain Source chain ID
     * @param targetChain Target chain ID
     * @return deadline Challenge period deadline
     */
    function submitRequest(
        bytes32 requestId,
        address sender,
        address recipient,
        address token,
        uint256 amount,
        uint256 sourceChain,
        uint256 targetChain
    ) external onlyAuthorized whenNotPaused returns (uint256 deadline) {
        if (requests[requestId].status != RequestStatus.None) revert RequestAlreadyExists();
        if (sender == address(0) || recipient == address(0)) revert ZeroAddress();

        deadline = block.timestamp + challengePeriod;

        requests[requestId] = BridgeRequest({
            id: requestId,
            sender: sender,
            recipient: recipient,
            token: token,
            amount: amount,
            sourceChain: sourceChain,
            targetChain: targetChain,
            submittedAt: block.timestamp,
            challengeDeadline: deadline,
            status: RequestStatus.Pending
        });

        totalRequests++;

        emit RequestSubmitted(requestId, sender, recipient, token, amount, sourceChain, targetChain, deadline);
    }

    /**
     * @notice Challenge a pending bridge request
     * @param requestId ID of the request to challenge
     * @param reason Reason for the challenge
     */
    function challengeRequest(bytes32 requestId, string calldata reason) external payable whenNotPaused nonReentrant {
        BridgeRequest storage request = requests[requestId];

        if (request.status == RequestStatus.None) revert RequestNotFound();
        if (request.status != RequestStatus.Pending) revert RequestNotPending();
        if (block.timestamp >= request.challengeDeadline) revert ChallengePeriodEnded();
        if (msg.value < challengeBond) revert InsufficientChallengeBond();

        // Store challenge info
        challenges[requestId] = Challenge({
            challenger: msg.sender,
            bondAmount: msg.value,
            reason: reason,
            challengedAt: block.timestamp,
            resolved: false
        });

        // Update request status
        request.status = RequestStatus.Challenged;

        emit RequestChallenged(requestId, msg.sender, msg.value, reason);
    }

    /**
     * @notice Resolve a challenge (called by FraudProofVerifier or admin)
     * @param requestId ID of the challenged request
     * @param challengeSuccessful Whether the challenge was successful
     */
    function resolveChallenge(bytes32 requestId, bool challengeSuccessful) external nonReentrant {
        if (msg.sender != fraudProofVerifier && msg.sender != owner()) {
            revert UnauthorizedCaller();
        }

        BridgeRequest storage request = requests[requestId];
        Challenge storage challenge = challenges[requestId];

        if (request.status != RequestStatus.Challenged) revert RequestNotChallenged();
        if (challenge.resolved) revert InvalidStatus();

        challenge.resolved = true;
        uint256 reward = 0;

        if (challengeSuccessful) {
            // Challenge successful - refund request and reward challenger
            request.status = RequestStatus.Refunded;
            totalSuccessfulChallenges++;

            // Return bond + reward to challenger
            reward = challenge.bondAmount + challengerReward;
            (bool success,) = payable(challenge.challenger).call{ value: reward }("");
            if (!success) revert TransferFailed();

            emit RequestRefunded(requestId, block.timestamp);
        } else {
            // Challenge failed - return to pending (with new deadline) or approve
            // For simplicity, we approve immediately after failed challenge
            request.status = RequestStatus.Approved;

            // Forfeit bond (stays in contract)
            emit RequestApproved(requestId, block.timestamp);
        }

        emit ChallengeResolved(requestId, challengeSuccessful, challenge.challenger, reward);
    }

    /**
     * @notice Approve a request after challenge period ends
     * @param requestId ID of the request to approve
     */
    function approveRequest(bytes32 requestId) external whenNotPaused {
        BridgeRequest storage request = requests[requestId];

        if (request.status == RequestStatus.None) revert RequestNotFound();
        if (request.status != RequestStatus.Pending) revert RequestNotPending();
        if (block.timestamp < request.challengeDeadline) revert ChallengePeriodNotEnded();

        request.status = RequestStatus.Approved;

        emit RequestApproved(requestId, block.timestamp);
    }

    /**
     * @notice Mark a request as executed (called by bridge contract)
     * @param requestId ID of the request to mark as executed
     */
    function markExecuted(bytes32 requestId) external onlyAuthorized {
        BridgeRequest storage request = requests[requestId];

        if (request.status == RequestStatus.None) revert RequestNotFound();
        if (request.status == RequestStatus.Executed) revert RequestAlreadyExecuted();
        if (request.status == RequestStatus.Cancelled) revert RequestAlreadyCancelled();
        if (request.status != RequestStatus.Approved) revert InvalidStatus();

        request.status = RequestStatus.Executed;

        emit RequestExecuted(requestId, block.timestamp);
    }

    /**
     * @notice Cancel a request (admin/guardian function)
     * @param requestId ID of the request to cancel
     * @param reason Reason for cancellation
     */
    function cancelRequest(bytes32 requestId, string calldata reason) external onlyOwner nonReentrant {
        BridgeRequest storage request = requests[requestId];

        if (request.status == RequestStatus.None) revert RequestNotFound();
        if (request.status == RequestStatus.Executed) revert RequestAlreadyExecuted();
        if (request.status == RequestStatus.Cancelled) revert RequestAlreadyCancelled();

        // Cache current status before state change
        RequestStatus currentStatus = request.status;

        // Effects: update state BEFORE external call (checks-effects-interactions)
        request.status = RequestStatus.Cancelled;

        // Interactions: refund challenger if there's an active challenge
        Challenge storage challenge = challenges[requestId];
        if (currentStatus == RequestStatus.Challenged && !challenge.resolved) {
            challenge.resolved = true;
            (bool success,) = payable(challenge.challenger).call{ value: challenge.bondAmount }("");
            if (!success) revert TransferFailed();
        }

        emit RequestCancelled(requestId, reason);
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the challenge period duration
     * @param newPeriod New challenge period in seconds
     */
    function setChallengePeriod(uint256 newPeriod) external onlyOwner {
        if (newPeriod < MIN_CHALLENGE_PERIOD || newPeriod > MAX_CHALLENGE_PERIOD) {
            revert InvalidChallengePeriod();
        }

        uint256 oldPeriod = challengePeriod;
        challengePeriod = newPeriod;

        emit ChallengePeriodUpdated(oldPeriod, newPeriod);
    }

    /**
     * @notice Set the challenge bond amount
     * @param newBond New challenge bond amount
     */
    function setChallengeBond(uint256 newBond) external onlyOwner {
        if (newBond < MIN_CHALLENGE_BOND) revert InsufficientChallengeBond();

        uint256 oldBond = challengeBond;
        challengeBond = newBond;

        emit ChallengeBondUpdated(oldBond, newBond);
    }

    /**
     * @notice Set the challenger reward amount
     * @param newReward New challenger reward amount
     */
    function setChallengerReward(uint256 newReward) external onlyOwner {
        uint256 oldReward = challengerReward;
        challengerReward = newReward;

        emit ChallengerRewardUpdated(oldReward, newReward);
    }

    /**
     * @notice Set the fraud proof verifier address
     * @param newVerifier Address of the new verifier
     */
    function setFraudProofVerifier(address newVerifier) external onlyOwner {
        if (newVerifier == address(0)) revert ZeroAddress();

        address oldVerifier = fraudProofVerifier;
        fraudProofVerifier = newVerifier;

        emit FraudProofVerifierUpdated(oldVerifier, newVerifier);
    }

    /**
     * @notice Add or remove an authorized caller
     * @param caller Address to authorize/unauthorize
     * @param authorized Whether to authorize or not
     */
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();

        authorizedCallers[caller] = authorized;

        emit AuthorizedCallerUpdated(caller, authorized);
    }

    /**
     * @notice Pause the verifier
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the verifier
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Withdraw accumulated challenge bonds (forfeited bonds)
     * @param to Address to send funds to
     * @param amount Amount to withdraw
     */
    function withdrawFees(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        (bool success,) = payable(to).call{ value: amount }("");
        if (!success) revert TransferFailed();
    }

    // ============ View Functions ============

    /**
     * @notice Get request details
     * @param requestId ID of the request
     * @return request The bridge request struct
     */
    function getRequest(bytes32 requestId) external view returns (BridgeRequest memory) {
        return requests[requestId];
    }

    /**
     * @notice Get challenge details
     * @param requestId ID of the request
     * @return challenge The challenge struct
     */
    function getChallenge(bytes32 requestId) external view returns (Challenge memory) {
        return challenges[requestId];
    }

    /**
     * @notice Check if a request can be approved (challenge period ended)
     * @param requestId ID of the request
     * @return canApprove True if request can be approved
     */
    function canApprove(bytes32 requestId) external view returns (bool) {
        BridgeRequest storage request = requests[requestId];
        return request.status == RequestStatus.Pending && block.timestamp >= request.challengeDeadline;
    }

    /**
     * @notice Check if a request can be challenged
     * @param requestId ID of the request
     * @return canChallenge True if request can be challenged
     */
    function canChallenge(bytes32 requestId) external view returns (bool) {
        BridgeRequest storage request = requests[requestId];
        return request.status == RequestStatus.Pending && block.timestamp < request.challengeDeadline;
    }

    /**
     * @notice Get time remaining in challenge period
     * @param requestId ID of the request
     * @return timeRemaining Seconds remaining, 0 if ended
     */
    function getTimeRemaining(bytes32 requestId) external view returns (uint256) {
        BridgeRequest storage request = requests[requestId];
        if (request.status == RequestStatus.None) return 0;
        if (block.timestamp >= request.challengeDeadline) return 0;
        return request.challengeDeadline - block.timestamp;
    }

    /**
     * @notice Get request status
     * @param requestId ID of the request
     * @return status The current status
     */
    function getRequestStatus(bytes32 requestId) external view returns (RequestStatus) {
        return requests[requestId].status;
    }

    /**
     * @notice Check if an address is an authorized caller
     * @param caller Address to check
     * @return authorized True if authorized
     */
    function isAuthorizedCaller(address caller) external view returns (bool) {
        return authorizedCallers[caller];
    }

    // ============ Receive Function ============

    /**
     * @notice Allow contract to receive ETH (for reward funding)
     */
    receive() external payable { }
}
