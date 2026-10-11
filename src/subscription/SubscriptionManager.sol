// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC7715PermissionManager } from "./ERC7715PermissionManager.sol";

/**
 * @title ISubscriptionManager
 * @notice Interface for subscription management
 */
interface ISubscriptionManager {
    /* //////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidPlan();
    error PlanNotActive();
    error SubscriptionNotFound();
    error SubscriptionAlreadyExists();
    error SubscriptionNotActive();
    error SubscriptionExpired();
    error PaymentFailed();
    error NotDueForPayment();
    error InvalidAmount();
    error InvalidPeriod();
    error InsufficientFunds();
    error UnauthorizedMerchant();
    error PermissionNotGranted();
    error CancellationPeriodNotMet();

    /* //////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PlanCreated(uint256 indexed planId, address indexed merchant, uint256 amount, uint256 period, address token);

    event PlanUpdated(uint256 indexed planId, uint256 amount, uint256 period, bool active);

    event SubscriptionCreated(
        bytes32 indexed subscriptionId, uint256 indexed planId, address indexed subscriber, uint256 startTime
    );

    event SubscriptionCancelled(bytes32 indexed subscriptionId, address indexed subscriber, uint256 cancelTime);

    event PaymentProcessed(
        bytes32 indexed subscriptionId,
        address indexed subscriber,
        address indexed merchant,
        uint256 amount,
        uint256 paymentNumber
    );

    event PaymentFailedLog(bytes32 indexed subscriptionId, address indexed subscriber, string reason);
    event ProcessorUpdated(address indexed processor, bool authorized);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    /* //////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Subscription plan created by merchants
    struct Plan {
        address merchant; // Merchant receiving payments
        uint256 amount; // Payment amount per period
        uint256 period; // Payment period in seconds (e.g., 30 days)
        address token; // Payment token (ERC-20 only, address(0) not supported)
        uint256 trialPeriod; // Free trial period in seconds
        uint256 gracePeriod; // Grace period after missed payment
        uint256 minSubscriptionTime; // Minimum subscription duration
        string name; // Plan name
        string description; // Plan description
        bool active; // Whether plan accepts new subscriptions
        uint256 subscriberCount; // Current subscriber count
    }

    /// @notice Individual subscription record
    struct Subscription {
        uint256 planId; // Reference to subscription plan
        address subscriber; // Address of subscriber
        bytes32 permissionId; // ERC-7715 permission ID
        uint256 startTime; // Subscription start timestamp
        uint256 lastPayment; // Last successful payment timestamp
        uint256 nextPayment; // Next payment due timestamp
        uint256 paymentCount; // Total successful payments
        uint256 totalPaid; // Total amount paid
        bool active; // Whether subscription is active
        bool inGracePeriod; // Whether in grace period
    }

    /// @notice Price terms a subscriber agreed to, fixed at subscribe time
    /// @dev Kept outside Subscription so the existing struct and getter layout stay unchanged
    struct SubscriptionTerms {
        uint256 amount; // Payment amount per period
        uint256 period; // Payment period in seconds
    }
}

/**
 * @title SubscriptionManager
 * @notice Manages recurring subscription payments using ERC-7715 permissions
 * @dev Integrates with ERC7715PermissionManager for authorization
 *
 * Features:
 *   - Create and manage subscription plans
 *   - Subscribe users with ERC-7715 permission
 *   - Automated recurring payments
 *   - Trial periods and grace periods
 *   - Support for ERC-20 tokens (native token not supported in pull-based model)
 *
 * Flow:
 *   1. Merchant creates a plan
 *   2. User grants permission via ERC7715PermissionManager
 *   3. User subscribes to plan, linking the permission
 *   4. Payments are processed periodically
 */
contract SubscriptionManager is ISubscriptionManager, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* //////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Permission manager contract
    IERC7715PermissionManager public immutable PERMISSION_MANAGER;

    /// @notice Plan ID counter
    uint256 public planCount;

    /// @notice Mapping of plan ID to plan details
    mapping(uint256 => Plan) public plans;

    /// @notice Mapping of subscription ID to subscription details
    mapping(bytes32 => Subscription) public subscriptions;

    /// @notice Mapping of subscription ID to the amount and period agreed at subscribe time
    mapping(bytes32 => SubscriptionTerms) public subscriptionTerms;

    /// @notice Mapping of subscriber address to their subscription IDs
    mapping(address => bytes32[]) public subscriberSubscriptions;

    /// @notice Mapping of merchant address to their plan IDs
    mapping(address => uint256[]) public merchantPlans;

    /// @notice Authorized payment processors
    mapping(address => bool) public authorizedProcessors;

    /// @notice Protocol fee in basis points (100 = 1%)
    uint256 public protocolFeeBps;

    /// @notice Fee recipient
    address public feeRecipient;

    /// @notice Maximum protocol fee (10%)
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice Minimum period (1 hour)
    uint256 public constant MIN_PERIOD = 1 hours;

    /// @notice Maximum period (1 year)
    uint256 public constant MAX_PERIOD = 365 days;

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize SubscriptionManager
     * @param _permissionManager ERC-7715 Permission Manager address
     */
    constructor(address _permissionManager) Ownable(msg.sender) {
        PERMISSION_MANAGER = IERC7715PermissionManager(_permissionManager);
        feeRecipient = msg.sender;
        protocolFeeBps = 50; // 0.5% default fee
    }

    /* //////////////////////////////////////////////////////////////
                           PLAN MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a new subscription plan
     * @param amount Payment amount per period
     * @param period Payment period in seconds
     * @param token Payment token (must be ERC-20, address(0) not supported)
     * @param trialPeriod Trial period in seconds
     * @param gracePeriod Grace period in seconds
     * @param minSubscriptionTime Minimum subscription duration
     * @param name Plan name
     * @param description Plan description
     * @return planId Created plan ID
     */
    function createPlan(
        uint256 amount,
        uint256 period,
        address token,
        uint256 trialPeriod,
        uint256 gracePeriod,
        uint256 minSubscriptionTime,
        string calldata name,
        string calldata description
    ) external returns (uint256 planId) {
        if (amount == 0) revert InvalidAmount();
        if (token == address(0)) revert InvalidAmount(); // Native token not supported for subscriptions
        if (period < MIN_PERIOD || period > MAX_PERIOD) revert InvalidPeriod();

        planId = ++planCount;

        plans[planId] = Plan({
            merchant: msg.sender,
            amount: amount,
            period: period,
            token: token,
            trialPeriod: trialPeriod,
            gracePeriod: gracePeriod,
            minSubscriptionTime: minSubscriptionTime,
            name: name,
            description: description,
            active: true,
            subscriberCount: 0
        });

        merchantPlans[msg.sender].push(planId);

        emit PlanCreated(planId, msg.sender, amount, period, token);
    }

    /**
     * @notice Update an existing plan
     * @dev Amount and period changes apply only to subscriptions created afterwards;
     *      existing subscriptions keep the terms recorded in subscriptionTerms.
     * @param planId Plan to update
     * @param amount New payment amount
     * @param period New payment period
     * @param active New active status
     */
    function updatePlan(uint256 planId, uint256 amount, uint256 period, bool active) external {
        Plan storage plan = plans[planId];
        if (plan.merchant == address(0)) revert InvalidPlan();
        if (plan.merchant != msg.sender) revert UnauthorizedMerchant();

        if (amount > 0) {
            plan.amount = amount;
        }
        if (period >= MIN_PERIOD && period <= MAX_PERIOD) {
            plan.period = period;
        }
        plan.active = active;

        emit PlanUpdated(planId, plan.amount, plan.period, active);
    }

    /* //////////////////////////////////////////////////////////////
                       SUBSCRIPTION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Subscribe to a plan
     * @param planId Plan to subscribe to
     * @param permissionId ERC-7715 permission ID for recurring payments
     * @return subscriptionId Created subscription ID
     */
    function subscribe(uint256 planId, bytes32 permissionId) external nonReentrant returns (bytes32 subscriptionId) {
        Plan storage plan = plans[planId];
        if (plan.merchant == address(0)) revert InvalidPlan();
        if (!plan.active) revert PlanNotActive();

        // Verify permission is valid and belongs to subscriber
        if (!PERMISSION_MANAGER.isPermissionValid(permissionId)) {
            revert PermissionNotGranted();
        }

        IERC7715PermissionManager.PermissionRecord memory permission = PERMISSION_MANAGER.getPermission(permissionId);

        if (permission.granter != msg.sender) {
            revert PermissionNotGranted();
        }

        // Generate subscription ID
        subscriptionId = keccak256(abi.encodePacked(planId, msg.sender, block.timestamp));

        if (subscriptions[subscriptionId].startTime != 0) {
            revert SubscriptionAlreadyExists();
        }

        // Calculate first payment time (after trial if applicable)
        uint256 firstPaymentTime = block.timestamp + plan.trialPeriod;

        subscriptions[subscriptionId] = Subscription({
            planId: planId,
            subscriber: msg.sender,
            permissionId: permissionId,
            startTime: block.timestamp,
            lastPayment: 0,
            nextPayment: firstPaymentTime,
            paymentCount: 0,
            totalPaid: 0,
            active: true,
            inGracePeriod: false
        });

        // Snapshot the price terms so later plan updates cannot change what this subscriber pays
        subscriptionTerms[subscriptionId] = SubscriptionTerms({ amount: plan.amount, period: plan.period });

        subscriberSubscriptions[msg.sender].push(subscriptionId);
        plan.subscriberCount++;

        emit SubscriptionCreated(subscriptionId, planId, msg.sender, block.timestamp);

        // Process first payment if no trial period; a failed first payment aborts the subscription
        if (plan.trialPeriod == 0) {
            if (!_processPayment(subscriptionId)) revert PaymentFailed();
        }
    }

    /**
     * @notice Cancel a subscription
     * @param subscriptionId Subscription to cancel
     */
    function cancelSubscription(bytes32 subscriptionId) external {
        Subscription storage sub = subscriptions[subscriptionId];
        if (sub.startTime == 0) revert SubscriptionNotFound();
        if (sub.subscriber != msg.sender) revert UnauthorizedMerchant();
        if (!sub.active) revert SubscriptionNotActive();

        Plan storage plan = plans[sub.planId];

        // Check minimum subscription time
        if (plan.minSubscriptionTime > 0) {
            if (block.timestamp < sub.startTime + plan.minSubscriptionTime) {
                revert CancellationPeriodNotMet();
            }
        }

        sub.active = false;
        plan.subscriberCount--;

        emit SubscriptionCancelled(subscriptionId, msg.sender, block.timestamp);
    }

    /**
     * @notice Process a subscription payment
     * @dev Reverts if the subscription does not exist, is inactive or is not yet due.
     *      A payment that cannot be collected (invalid permission, exhausted allowance or
     *      insufficient token balance/allowance) does not revert: the subscription enters its
     *      grace period, or is deactivated once the grace period has passed, and
     *      PaymentFailedLog is emitted.
     * @param subscriptionId Subscription to process
     */
    function processPayment(bytes32 subscriptionId) external nonReentrant {
        if (!authorizedProcessors[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedMerchant();
        }
        _processPayment(subscriptionId);
    }

    /**
     * @notice Process multiple subscription payments (batch)
     * @dev Entries that do not exist, are inactive or are not yet due are skipped, and a payment
     *      that cannot be collected is recorded as failed, so one subscriber cannot block the batch.
     * @param subscriptionIds Array of subscription IDs to process
     */
    function batchProcessPayments(bytes32[] calldata subscriptionIds) external nonReentrant {
        if (!authorizedProcessors[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedMerchant();
        }

        for (uint256 i = 0; i < subscriptionIds.length; i++) {
            Subscription storage sub = subscriptions[subscriptionIds[i]];
            if (sub.startTime == 0 || !sub.active || block.timestamp < sub.nextPayment) continue;
            _processPayment(subscriptionIds[i]);
        }
    }

    /**
     * @notice Internal function to process payment
     * @return paid True if the payment was collected, false if it was recorded as failed
     */
    function _processPayment(bytes32 subscriptionId) internal returns (bool paid) {
        Subscription storage sub = subscriptions[subscriptionId];
        if (sub.startTime == 0) revert SubscriptionNotFound();
        if (!sub.active) revert SubscriptionNotActive();

        // Check if payment is due
        if (block.timestamp < sub.nextPayment) {
            revert NotDueForPayment();
        }

        Plan storage plan = plans[sub.planId];
        SubscriptionTerms storage terms = subscriptionTerms[subscriptionId];

        // Verify permission is still valid
        if (!PERMISSION_MANAGER.isPermissionValid(sub.permissionId)) {
            return _recordPaymentFailure(subscriptionId, sub, plan, "Permission invalid");
        }

        // Verify the subscriber can cover the charge, so the transfers below cannot revert
        if (
            IERC20(plan.token).balanceOf(sub.subscriber) < terms.amount
                || IERC20(plan.token).allowance(sub.subscriber, address(this)) < terms.amount
        ) {
            return _recordPaymentFailure(subscriptionId, sub, plan, "Insufficient funds");
        }

        // Use permission (an exhausted allowance reverts in the permission manager)
        try PERMISSION_MANAGER.usePermission(sub.permissionId, terms.amount) returns (bool success) {
            if (!success) {
                return _recordPaymentFailure(subscriptionId, sub, plan, "Permission use failed");
            }
        } catch (bytes memory reason) {
            // A paused permission manager is an operator action, not a subscriber failure:
            // bubble it up instead of moving the subscription towards expiry.
            if (reason.length >= 4 && bytes4(reason) == IERC7715PermissionManager.PermissionPaused.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
            return _recordPaymentFailure(subscriptionId, sub, plan, "Permission use failed");
        }

        // Calculate fee
        uint256 fee = (terms.amount * protocolFeeBps) / 10_000;
        uint256 merchantAmount = terms.amount - fee;

        // Transfer tokens BEFORE state update to ensure atomicity
        // If either transfer fails, state remains unchanged
        if (plan.token == address(0)) {
            // Native token payments are not supported in pull-based subscription model
            // Subscribers must use ERC-20 wrapped tokens (e.g., WETH)
            revert PaymentFailed();
        } else {
            // ERC-20 token - both transfers must succeed before state advance
            IERC20(plan.token).safeTransferFrom(sub.subscriber, plan.merchant, merchantAmount);
            if (fee > 0) {
                IERC20(plan.token).safeTransferFrom(sub.subscriber, feeRecipient, fee);
            }
        }

        // Update subscription state AFTER successful transfers (atomic guarantee)
        sub.lastPayment = block.timestamp;
        sub.nextPayment = block.timestamp + terms.period;
        sub.paymentCount++;
        sub.totalPaid += terms.amount;
        sub.inGracePeriod = false;

        emit PaymentProcessed(subscriptionId, sub.subscriber, plan.merchant, terms.amount, sub.paymentCount);
        return true;
    }

    /**
     * @notice Record a payment that could not be collected
     * @dev Persists the grace-period flag, or deactivates the subscription once the grace period
     *      has passed, instead of reverting (a revert would roll these writes back).
     * @return paid Always false
     */
    function _recordPaymentFailure(
        bytes32 subscriptionId,
        Subscription storage sub,
        Plan storage plan,
        string memory reason
    ) internal returns (bool paid) {
        if (block.timestamp > sub.nextPayment + plan.gracePeriod) {
            sub.active = false;
            sub.inGracePeriod = false;
            plan.subscriberCount--;
            emit PaymentFailedLog(subscriptionId, sub.subscriber, "Subscription expired");
        } else {
            sub.inGracePeriod = true;
            emit PaymentFailedLog(subscriptionId, sub.subscriber, reason);
        }
        return false;
    }

    /* //////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get plan details
     * @param planId Plan ID
     * @return Plan details
     */
    function getPlan(uint256 planId) external view returns (Plan memory) {
        return plans[planId];
    }

    /**
     * @notice Get subscription details
     * @param subscriptionId Subscription ID
     * @return Subscription details
     */
    function getSubscription(bytes32 subscriptionId) external view returns (Subscription memory) {
        return subscriptions[subscriptionId];
    }

    /**
     * @notice Get all subscriptions for a subscriber
     * @param subscriber Subscriber address
     * @return Array of subscription IDs
     */
    function getSubscriberSubscriptions(address subscriber) external view returns (bytes32[] memory) {
        return subscriberSubscriptions[subscriber];
    }

    /**
     * @notice Get all plans for a merchant
     * @param merchant Merchant address
     * @return Array of plan IDs
     */
    function getMerchantPlans(address merchant) external view returns (uint256[] memory) {
        return merchantPlans[merchant];
    }

    /**
     * @notice Check if a subscription is due for payment
     * @param subscriptionId Subscription ID
     * @return Whether payment is due
     */
    function isPaymentDue(bytes32 subscriptionId) external view returns (bool) {
        Subscription storage sub = subscriptions[subscriptionId];
        return sub.active && block.timestamp >= sub.nextPayment;
    }

    /**
     * @notice Get subscriptions due for payment
     * @param subscriptionIds Array of subscription IDs to check
     * @return dueIds Array of subscription IDs due for payment
     */
    function getDueSubscriptions(bytes32[] calldata subscriptionIds) external view returns (bytes32[] memory dueIds) {
        uint256 count = 0;
        bytes32[] memory temp = new bytes32[](subscriptionIds.length);

        for (uint256 i = 0; i < subscriptionIds.length; i++) {
            Subscription storage sub = subscriptions[subscriptionIds[i]];
            if (sub.active && block.timestamp >= sub.nextPayment) {
                temp[count++] = subscriptionIds[i];
            }
        }

        dueIds = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            dueIds[i] = temp[i];
        }
    }

    /**
     * @notice Calculate days until next payment
     * @param subscriptionId Subscription ID
     * @return Days until next payment (0 if due now, negative if overdue)
     */
    function daysUntilNextPayment(bytes32 subscriptionId) external view returns (int256) {
        Subscription storage sub = subscriptions[subscriptionId];
        if (!sub.active) return 0;

        if (block.timestamp >= sub.nextPayment) {
            return -int256((block.timestamp - sub.nextPayment) / 1 days);
        }
        return int256((sub.nextPayment - block.timestamp) / 1 days);
    }

    /* //////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add an authorized payment processor
     * @param processor Address to authorize
     */
    function addProcessor(address processor) external onlyOwner {
        authorizedProcessors[processor] = true;
        emit ProcessorUpdated(processor, true);
    }

    /**
     * @notice Remove an authorized payment processor
     * @param processor Address to deauthorize
     */
    function removeProcessor(address processor) external onlyOwner {
        authorizedProcessors[processor] = false;
        emit ProcessorUpdated(processor, false);
    }

    /**
     * @notice Set protocol fee
     * @param feeBps Fee in basis points
     */
    function setProtocolFee(uint256 feeBps) external onlyOwner {
        require(feeBps <= MAX_FEE_BPS, "Fee too high");
        uint256 oldFee = protocolFeeBps;
        protocolFeeBps = feeBps;
        emit ProtocolFeeUpdated(oldFee, feeBps);
    }

    /**
     * @notice Set fee recipient
     * @param recipient New fee recipient
     */
    function setFeeRecipient(address recipient) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        address oldRecipient = feeRecipient;
        feeRecipient = recipient;
        emit FeeRecipientUpdated(oldRecipient, recipient);
    }

    /**
     * @notice Emergency cancel subscription (admin only)
     * @param subscriptionId Subscription to cancel
     */
    function emergencyCancelSubscription(bytes32 subscriptionId) external onlyOwner {
        Subscription storage sub = subscriptions[subscriptionId];
        if (sub.startTime == 0) revert SubscriptionNotFound();

        sub.active = false;
        plans[sub.planId].subscriberCount--;

        emit SubscriptionCancelled(subscriptionId, sub.subscriber, block.timestamp);
    }

    /**
     * @notice Reject ETH transfers to prevent permanent locking
     * @dev Native token payments are not supported; use ERC-20 wrapped tokens (e.g., WETH)
     */
    receive() external payable {
        revert PaymentFailed();
    }
}
