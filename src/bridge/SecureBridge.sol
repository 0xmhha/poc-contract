// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BridgeValidator} from "./BridgeValidator.sol";
import {OptimisticVerifier} from "./OptimisticVerifier.sol";
import {BridgeRateLimiter} from "./BridgeRateLimiter.sol";
import {BridgeGuardian} from "./BridgeGuardian.sol";

/**
 * @title SecureBridge
 * @notice Main bridge contract integrating all security layers
 * @dev Defense-in-depth bridge with MPC + Optimistic verification
 *
 * Security Layers:
 * 1. MPC Signing (BridgeValidator) - 5-of-7 threshold
 * 2. Optimistic Verification (OptimisticVerifier) - 6h challenge period
 * 3. Fraud Proofs (FraudProofVerifier) - Dispute resolution
 * 4. Rate Limiting (BridgeRateLimiter) - Volume controls
 * 5. Guardian System (BridgeGuardian) - Emergency response
 */
contract SecureBridge is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Errors ============
    error InvalidAmount();
    error InvalidRecipient();
    error InvalidToken();
    error InsufficientBalance();
    error TransferFailed();
    error RequestNotApproved();
    error RequestAlreadyExecuted();
    error InvalidSignatures();
    error RateLimitExceeded();
    error Blacklisted();
    error GuardianPaused();
    error UnsupportedChain();
    error ZeroAddress();
    error InvalidDeadline();
    error DeadlineExpired();
    error NativeTransferFailed();
    error InsufficientFee();

    // ============ Events ============
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
    event BridgeCompleted(
        bytes32 indexed requestId,
        address indexed recipient,
        address token,
        uint256 amount
    );
    event BridgeRefunded(
        bytes32 indexed requestId,
        address indexed sender,
        address token,
        uint256 amount
    );
    event TokenMapped(
        address indexed sourceToken,
        uint256 indexed targetChain,
        address targetToken
    );
    event ChainSupportUpdated(uint256 indexed chainId, bool supported);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event ComponentUpdated(string component, address oldAddress, address newAddress);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    // ============ Structs ============

    /**
     * @notice Structure for bridge deposit info
     * @param sender Original sender
     * @param token Token address (address(0) for native)
     * @param amount Amount deposited
     * @param timestamp Deposit timestamp
     * @param executed Whether tokens have been released
     * @param refunded Whether tokens have been refunded
     */
    struct DepositInfo {
        address sender;
        address token;
        uint256 amount;
        uint256 timestamp;
        bool executed;
        bool refunded;
    }

    // ============ State Variables ============

    /// @notice BridgeValidator contract
    BridgeValidator public bridgeValidator;

    /// @notice OptimisticVerifier contract
    OptimisticVerifier public optimisticVerifier;

    /// @notice BridgeRateLimiter contract
    BridgeRateLimiter public rateLimiter;

    /// @notice BridgeGuardian contract
    BridgeGuardian public guardian;

    /// @notice Current chain ID
    uint256 public immutable CHAIN_ID;

    /// @notice Mapping of supported chains
    mapping(uint256 => bool) public supportedChains;

    /// @notice Mapping of token addresses between chains
    /// sourceToken => targetChain => targetToken
    mapping(address => mapping(uint256 => address)) public tokenMappings;

    /// @notice Mapping of request ID to deposit info
    mapping(bytes32 => DepositInfo) public deposits;

    /// @notice Bridge fee in basis points (default: 10 = 0.1%)
    uint256 public bridgeFeeBps = 10;

    /// @notice Fee recipient address
    address public feeRecipient;

    /// @notice Request nonce counter per user
    mapping(address => uint256) public userNonces;

    /// @notice Total value locked per token
    mapping(address => uint256) public totalValueLocked;

    /// @notice Total fees collected per token
    mapping(address => uint256) public feesCollected;

    // ============ Constructor ============

    /**
     * @notice Initialize the SecureBridge
     * @param _bridgeValidator Address of BridgeValidator
     * @param _optimisticVerifier Address of OptimisticVerifier
     * @param _rateLimiter Address of BridgeRateLimiter
     * @param _guardian Address of BridgeGuardian
     * @param _feeRecipient Address to receive fees
     */
    constructor(
        address _bridgeValidator,
        address payable _optimisticVerifier,
        address _rateLimiter,
        address _guardian,
        address _feeRecipient
    ) Ownable(msg.sender) {
        if (_bridgeValidator == address(0)) revert ZeroAddress();
        if (_optimisticVerifier == address(0)) revert ZeroAddress();
        if (_rateLimiter == address(0)) revert ZeroAddress();
        if (_guardian == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();

        bridgeValidator = BridgeValidator(_bridgeValidator);
        optimisticVerifier = OptimisticVerifier(_optimisticVerifier);
        rateLimiter = BridgeRateLimiter(_rateLimiter);
        guardian = BridgeGuardian(_guardian);
        feeRecipient = _feeRecipient;
        CHAIN_ID = block.chainid;
    }

    // ============ External Functions ============

    /**
     * @notice Initiate a bridge transfer (lock tokens on source chain)
     * @param token Token address (address(0) for native)
     * @param amount Amount to bridge
     * @param recipient Recipient address on target chain
     * @param targetChain Target chain ID
     * @param deadline Transaction deadline
     * @return requestId Unique request identifier
     */
    function initiateBridge(
        address token,
        uint256 amount,
        address recipient,
        uint256 targetChain,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant returns (bytes32 requestId) {
        // Validate inputs
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        if (!supportedChains[targetChain]) revert UnsupportedChain();
        if (deadline <= block.timestamp) revert InvalidDeadline();

        // Check guardian pause and blacklist
        if (guardian.guardianPaused()) revert GuardianPaused();
        if (guardian.isBlacklisted(msg.sender)) revert Blacklisted();
        if (guardian.isBlacklisted(recipient)) revert Blacklisted();

        // Check rate limits
        (bool allowed,) = rateLimiter.checkAndRecordTransaction(token, amount);
        if (!allowed) revert RateLimitExceeded();

        // Calculate fee
        uint256 fee = (amount * bridgeFeeBps) / 10000;
        uint256 amountAfterFee = amount - fee;

        // Generate request ID
        uint256 nonce = userNonces[msg.sender]++;
        requestId = keccak256(abi.encode(
            msg.sender,
            recipient,
            token,
            amount,
            CHAIN_ID,
            targetChain,
            nonce,
            block.timestamp
        ));

        // Handle token transfer
        if (token == address(0)) {
            // Native token
            if (msg.value < amount) revert InsufficientFee();
            // Refund excess
            if (msg.value > amount) {
                (bool refundSuccess,) = payable(msg.sender).call{value: msg.value - amount}("");
                if (!refundSuccess) revert NativeTransferFailed();
            }
        } else {
            // ERC20 token
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        // Store deposit info
        deposits[requestId] = DepositInfo({
            sender: msg.sender,
            token: token,
            amount: amount,
            timestamp: block.timestamp,
            executed: false,
            refunded: false
        });

        // Update TVL and fees
        totalValueLocked[token] += amountAfterFee;
        feesCollected[token] += fee;

        // Submit to optimistic verifier
        optimisticVerifier.submitRequest(
            requestId,
            msg.sender,
            recipient,
            token,
            amountAfterFee,
            CHAIN_ID,
            targetChain
        );

        emit BridgeInitiated(
            requestId,
            msg.sender,
            recipient,
            token,
            amountAfterFee,
            CHAIN_ID,
            targetChain,
            fee
        );
    }

    /**
     * @notice Complete a bridge transfer (release tokens on target chain)
     * @param requestId Unique request identifier
     * @param sender Original sender on source chain
     * @param recipient Recipient on this chain
     * @param sourceToken Token address on source chain
     * @param amount Amount to release
     * @param sourceChain Source chain ID
     * @param nonce Request nonce
     * @param deadline Message deadline
     * @param signatures MPC signatures
     */
    function completeBridge(
        bytes32 requestId,
        address sender,
        address recipient,
        address sourceToken,
        uint256 amount,
        uint256 sourceChain,
        uint256 nonce,
        uint256 deadline,
        bytes[] calldata signatures
    ) external whenNotPaused nonReentrant {
        // Validate inputs
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        if (deadline < block.timestamp) revert DeadlineExpired();

        // Check guardian pause and blacklist
        if (guardian.guardianPaused()) revert GuardianPaused();
        if (guardian.isBlacklisted(sender)) revert Blacklisted();
        if (guardian.isBlacklisted(recipient)) revert Blacklisted();

        // Verify MPC signatures
        BridgeValidator.BridgeMessage memory message = BridgeValidator.BridgeMessage({
            requestId: requestId,
            sender: sender,
            recipient: recipient,
            token: sourceToken,
            amount: amount,
            sourceChain: sourceChain,
            targetChain: CHAIN_ID,
            nonce: nonce,
            deadline: deadline
        });

        bool valid = bridgeValidator.verifyMpcSignatures(message, signatures);
        if (!valid) revert InvalidSignatures();

        // Check optimistic verification status
        OptimisticVerifier.RequestStatus status = optimisticVerifier.getRequestStatus(requestId);
        if (status != OptimisticVerifier.RequestStatus.Approved) {
            // If not approved, it might still be in challenge period or already executed
            if (status == OptimisticVerifier.RequestStatus.Executed) revert RequestAlreadyExecuted();
            revert RequestNotApproved();
        }

        // Get target token
        address targetToken = tokenMappings[sourceToken][sourceChain];
        if (targetToken == address(0)) {
            // If no mapping, use source token (same-chain or native mapping)
            targetToken = sourceToken;
        }

        // Mark as executed in optimistic verifier
        optimisticVerifier.markExecuted(requestId);

        // Release tokens
        if (targetToken == address(0)) {
            // Native token
            (bool success,) = payable(recipient).call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            // ERC20 token
            IERC20(targetToken).safeTransfer(recipient, amount);
        }

        // Update TVL
        if (totalValueLocked[targetToken] >= amount) {
            totalValueLocked[targetToken] -= amount;
        }

        emit BridgeCompleted(requestId, recipient, targetToken, amount);
    }

    /**
     * @notice Refund a failed or challenged bridge request
     * @param requestId Request ID to refund
     */
    function refundBridge(bytes32 requestId) external nonReentrant {
        DepositInfo storage deposit = deposits[requestId];

        if (deposit.sender == address(0)) revert InvalidAmount();
        if (deposit.executed) revert RequestAlreadyExecuted();
        if (deposit.refunded) revert RequestAlreadyExecuted();

        // Check optimistic verifier status - must be Refunded or Cancelled
        OptimisticVerifier.RequestStatus status = optimisticVerifier.getRequestStatus(requestId);
        if (status != OptimisticVerifier.RequestStatus.Refunded &&
            status != OptimisticVerifier.RequestStatus.Cancelled) {
            revert RequestNotApproved();
        }

        deposit.refunded = true;

        // Update TVL (deduct fee that was already taken)
        uint256 fee = (deposit.amount * bridgeFeeBps) / 10000;
        uint256 refundAmount = deposit.amount - fee;

        if (totalValueLocked[deposit.token] >= refundAmount) {
            totalValueLocked[deposit.token] -= refundAmount;
        }

        // Refund tokens to original sender
        if (deposit.token == address(0)) {
            (bool success,) = payable(deposit.sender).call{value: refundAmount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(deposit.token).safeTransfer(deposit.sender, refundAmount);
        }

        emit BridgeRefunded(requestId, deposit.sender, deposit.token, refundAmount);
    }

    // ============ Admin Functions ============

    /**
     * @notice Set supported chain
     * @param _chainId Chain ID
     * @param supported Whether chain is supported
     */
    function setSupportedChain(uint256 _chainId, bool supported) external onlyOwner {
        supportedChains[_chainId] = supported;
        emit ChainSupportUpdated(_chainId, supported);
    }

    /**
     * @notice Set token mapping between chains
     * @param sourceToken Token on source chain
     * @param targetChain Target chain ID
     * @param targetToken Token on target chain
     */
    function setTokenMapping(
        address sourceToken,
        uint256 targetChain,
        address targetToken
    ) external onlyOwner {
        tokenMappings[sourceToken][targetChain] = targetToken;
        emit TokenMapped(sourceToken, targetChain, targetToken);
    }

    /**
     * @notice Set bridge fee
     * @param newFeeBps New fee in basis points
     */
    function setBridgeFee(uint256 newFeeBps) external onlyOwner {
        uint256 oldFee = bridgeFeeBps;
        bridgeFeeBps = newFeeBps;
        emit FeeUpdated(oldFee, newFeeBps);
    }

    /**
     * @notice Set fee recipient
     * @param newRecipient New fee recipient address
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();

        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /**
     * @notice Update bridge validator
     * @param newValidator New validator address
     */
    function setBridgeValidator(address newValidator) external onlyOwner {
        if (newValidator == address(0)) revert ZeroAddress();

        address old = address(bridgeValidator);
        bridgeValidator = BridgeValidator(newValidator);
        emit ComponentUpdated("BridgeValidator", old, newValidator);
    }

    /**
     * @notice Update optimistic verifier
     * @param newVerifier New verifier address
     */
    function setOptimisticVerifier(address payable newVerifier) external onlyOwner {
        if (newVerifier == address(0)) revert ZeroAddress();

        address old = address(optimisticVerifier);
        optimisticVerifier = OptimisticVerifier(newVerifier);
        emit ComponentUpdated("OptimisticVerifier", old, newVerifier);
    }

    /**
     * @notice Update rate limiter
     * @param newLimiter New limiter address
     */
    function setRateLimiter(address newLimiter) external onlyOwner {
        if (newLimiter == address(0)) revert ZeroAddress();

        address old = address(rateLimiter);
        rateLimiter = BridgeRateLimiter(newLimiter);
        emit ComponentUpdated("RateLimiter", old, newLimiter);
    }

    /**
     * @notice Update guardian
     * @param newGuardian New guardian address
     */
    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();

        address old = address(guardian);
        guardian = BridgeGuardian(newGuardian);
        emit ComponentUpdated("Guardian", old, newGuardian);
    }

    /**
     * @notice Withdraw collected fees
     * @param token Token address (address(0) for native)
     * @param amount Amount to withdraw
     */
    function withdrawFees(address token, uint256 amount) external onlyOwner {
        if (amount > feesCollected[token]) revert InsufficientBalance();

        feesCollected[token] -= amount;

        if (token == address(0)) {
            (bool success,) = payable(feeRecipient).call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(feeRecipient, amount);
        }
    }

    /**
     * @notice Emergency withdraw (owner only, for stuck funds)
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        if (token == address(0)) {
            (bool success,) = payable(to).call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit EmergencyWithdraw(token, to, amount);
    }

    /**
     * @notice Pause the bridge
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the bridge
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ View Functions ============

    /**
     * @notice Get deposit info
     * @param requestId Request ID
     * @return info Deposit information
     */
    function getDeposit(bytes32 requestId) external view returns (DepositInfo memory) {
        return deposits[requestId];
    }

    /**
     * @notice Get user's current nonce
     * @param user User address
     * @return nonce Current nonce
     */
    function getUserNonce(address user) external view returns (uint256) {
        return userNonces[user];
    }

    /**
     * @notice Calculate fee for an amount
     * @param amount Amount to calculate fee for
     * @return fee Fee amount
     */
    function calculateFee(uint256 amount) external view returns (uint256) {
        return (amount * bridgeFeeBps) / 10000;
    }

    /**
     * @notice Check if bridge is operational
     * @return operational Whether bridge can process transactions
     */
    function isOperational() external view returns (bool) {
        return !paused() && !guardian.guardianPaused();
    }

    /**
     * @notice Get target token for a source token and chain
     * @param sourceToken Source token address
     * @param sourceChain Source chain ID
     * @return targetToken Target token address
     */
    function getTargetToken(
        address sourceToken,
        uint256 sourceChain
    ) external view returns (address) {
        return tokenMappings[sourceToken][sourceChain];
    }

    /**
     * @notice Get total value locked for a token
     * @param token Token address
     * @return tvl Total value locked
     */
    function getTvl(address token) external view returns (uint256) {
        return totalValueLocked[token];
    }

    // ============ Receive Function ============

    /**
     * @notice Allow contract to receive ETH
     */
    receive() external payable {}
}
