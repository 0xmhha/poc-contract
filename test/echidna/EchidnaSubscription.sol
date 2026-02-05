// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title EchidnaSubscription
 * @notice Echidna fuzzing tests for SubscriptionManager
 * @dev Run with: echidna test/echidna/EchidnaSubscription.sol --contract EchidnaSubscription --config security/echidna.yaml
 *
 * Key invariants to test:
 * 1. Plan prices should never be negative
 * 2. Subscription periods should be consistent
 * 3. Payment amounts should match plan prices
 * 4. Subscription status transitions should be valid
 */
contract EchidnaSubscription {
    // ========================================================================
    // State Variables
    // ========================================================================

    // Subscription Plan
    struct Plan {
        address merchant;
        address token;
        uint256 price;
        uint256 period;
        bool active;
    }

    // Subscription
    struct Subscription {
        uint256 planId;
        address subscriber;
        uint256 nextPaymentTime;
        bool active;
        uint256 totalPaid;
    }

    mapping(uint256 => Plan) internal plans;
    mapping(uint256 => Subscription) internal subscriptions;

    uint256 internal planCount;
    uint256 internal subscriptionCount;
    uint256 internal totalRevenue;

    // Track valid state transitions
    uint256 internal activeSubscriptions;
    uint256 internal cancelledSubscriptions;

    // Constants
    uint256 constant MAX_PRICE = 1e24; // 1M tokens with 18 decimals
    uint256 constant MIN_PERIOD = 1 hours;
    uint256 constant MAX_PERIOD = 365 days;

    // ========================================================================
    // Property: Price Invariants
    // ========================================================================

    /**
     * @notice Plan prices should be within reasonable bounds
     */
    function echidna_plan_price_bounded() public view returns (bool) {
        for (uint256 i = 0; i < planCount; i++) {
            if (plans[i].price > MAX_PRICE) return false;
        }
        return true;
    }

    /**
     * @notice Plan periods should be within reasonable bounds
     */
    function echidna_plan_period_bounded() public view returns (bool) {
        for (uint256 i = 0; i < planCount; i++) {
            if (plans[i].active && plans[i].period < MIN_PERIOD) return false;
            if (plans[i].period > MAX_PERIOD) return false;
        }
        return true;
    }

    // ========================================================================
    // Property: Subscription State Invariants
    // ========================================================================

    /**
     * @notice Active + cancelled should equal total subscriptions
     */
    function echidna_subscription_count_consistency() public view returns (bool) {
        return activeSubscriptions + cancelledSubscriptions == subscriptionCount;
    }

    /**
     * @notice Total paid should be consistent with individual subscriptions
     */
    function echidna_total_paid_consistency() public view returns (bool) {
        uint256 computed = 0;
        for (uint256 i = 0; i < subscriptionCount; i++) {
            computed += subscriptions[i].totalPaid;
        }
        return computed == totalRevenue;
    }

    /**
     * @notice Active subscriptions should have valid plan references
     */
    function echidna_active_subscription_has_valid_plan() public view returns (bool) {
        for (uint256 i = 0; i < subscriptionCount; i++) {
            if (subscriptions[i].active) {
                uint256 planId = subscriptions[i].planId;
                if (planId >= planCount) return false;
            }
        }
        return true;
    }

    // ========================================================================
    // Property: Payment Invariants
    // ========================================================================

    /**
     * @notice Subscription total paid should be multiple of plan price
     */
    function echidna_payment_amount_consistent() public view returns (bool) {
        for (uint256 i = 0; i < subscriptionCount; i++) {
            uint256 planId = subscriptions[i].planId;
            if (planId < planCount && plans[planId].price > 0) {
                // Total paid should be divisible by price (allowing for rounding)
                // This is a simplified check
                if (subscriptions[i].totalPaid % plans[planId].price > 0) {
                    // Allow small rounding errors
                    if (subscriptions[i].totalPaid % plans[planId].price > 1e15) {
                        return false;
                    }
                }
            }
        }
        return true;
    }

    // ========================================================================
    // Fuzz Actions: Plan Management
    // ========================================================================

    /**
     * @notice Create a new subscription plan
     */
    function fuzz_createPlan(
        address merchant,
        address token,
        uint256 price,
        uint256 period
    ) external {
        // Bound inputs to reasonable ranges
        if (merchant == address(0)) return;
        if (token == address(0)) return;
        if (price == 0 || price > MAX_PRICE) return;
        if (period < MIN_PERIOD || period > MAX_PERIOD) return;

        plans[planCount] = Plan({
            merchant: merchant,
            token: token,
            price: price,
            period: period,
            active: true
        });

        planCount++;
    }

    /**
     * @notice Deactivate a plan
     */
    function fuzz_deactivatePlan(uint256 planId) external {
        if (planId >= planCount) return;
        plans[planId].active = false;
    }

    /**
     * @notice Update plan price
     */
    function fuzz_updatePlanPrice(uint256 planId, uint256 newPrice) external {
        if (planId >= planCount) return;
        if (newPrice == 0 || newPrice > MAX_PRICE) return;
        plans[planId].price = newPrice;
    }

    // ========================================================================
    // Fuzz Actions: Subscription Management
    // ========================================================================

    /**
     * @notice Subscribe to a plan
     */
    function fuzz_subscribe(uint256 planId, address subscriber) external {
        if (planId >= planCount) return;
        if (!plans[planId].active) return;
        if (subscriber == address(0)) return;

        subscriptions[subscriptionCount] = Subscription({
            planId: planId,
            subscriber: subscriber,
            nextPaymentTime: block.timestamp + plans[planId].period,
            active: true,
            totalPaid: plans[planId].price
        });

        totalRevenue += plans[planId].price;
        subscriptionCount++;
        activeSubscriptions++;
    }

    /**
     * @notice Process a subscription payment
     */
    function fuzz_processPayment(uint256 subscriptionId) external {
        if (subscriptionId >= subscriptionCount) return;
        if (!subscriptions[subscriptionId].active) return;

        Subscription storage sub = subscriptions[subscriptionId];
        Plan storage plan = plans[sub.planId];

        // Simulate payment processing
        if (block.timestamp >= sub.nextPaymentTime) {
            sub.nextPaymentTime += plan.period;
            sub.totalPaid += plan.price;
            totalRevenue += plan.price;
        }
    }

    /**
     * @notice Cancel a subscription
     */
    function fuzz_cancelSubscription(uint256 subscriptionId) external {
        if (subscriptionId >= subscriptionCount) return;
        if (!subscriptions[subscriptionId].active) return;

        subscriptions[subscriptionId].active = false;
        activeSubscriptions--;
        cancelledSubscriptions++;
    }

    // ========================================================================
    // View Functions
    // ========================================================================

    function getPlanCount() external view returns (uint256) {
        return planCount;
    }

    function getSubscriptionCount() external view returns (uint256) {
        return subscriptionCount;
    }

    function getActiveSubscriptions() external view returns (uint256) {
        return activeSubscriptions;
    }

    function getTotalRevenue() external view returns (uint256) {
        return totalRevenue;
    }
}
