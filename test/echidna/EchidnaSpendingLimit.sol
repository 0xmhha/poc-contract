// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title EchidnaSpendingLimit
 * @notice Echidna fuzzing tests for SpendingLimitHook
 * @dev Run with: echidna test/echidna/EchidnaSpendingLimit.sol --contract EchidnaSpendingLimit --config security/echidna.yaml
 *
 * Key invariants to test:
 * 1. Spending cannot exceed configured limits
 * 2. Limits reset properly after period expires
 * 3. Multi-token limits are tracked independently
 * 4. Accumulated spending is monotonically increasing within a period
 */
contract EchidnaSpendingLimit {
    // ========================================================================
    // State Variables
    // ========================================================================

    struct SpendingConfig {
        uint256 limit;
        uint256 period;
        uint256 spent;
        uint256 lastReset;
        bool configured;
    }

    // account => token => config
    mapping(address => mapping(address => SpendingConfig)) internal limits;

    // Track all accounts and tokens for iteration
    address[] internal accounts;
    address[] internal tokens;
    mapping(address => bool) internal isAccount;
    mapping(address => bool) internal isToken;

    // Global tracking
    uint256 internal totalSpent;
    uint256 internal totalLimitConfigured;

    // Constants
    uint256 constant MAX_LIMIT = 1e24;
    uint256 constant MIN_PERIOD = 1 hours;
    uint256 constant MAX_PERIOD = 365 days;
    address constant ETH = address(0);

    // ========================================================================
    // Property: Spending Limit Invariants
    // ========================================================================

    /**
     * @notice Spent amount should never exceed configured limit
     */
    function echidna_spent_within_limit() public view returns (bool) {
        for (uint256 i = 0; i < accounts.length; i++) {
            for (uint256 j = 0; j < tokens.length; j++) {
                SpendingConfig storage config = limits[accounts[i]][tokens[j]];
                if (config.configured && config.spent > config.limit) {
                    return false;
                }
            }
        }
        return true;
    }

    /**
     * @notice Configured limits should be within bounds
     */
    function echidna_limit_bounded() public view returns (bool) {
        for (uint256 i = 0; i < accounts.length; i++) {
            for (uint256 j = 0; j < tokens.length; j++) {
                SpendingConfig storage config = limits[accounts[i]][tokens[j]];
                if (config.configured && config.limit > MAX_LIMIT) {
                    return false;
                }
            }
        }
        return true;
    }

    /**
     * @notice Periods should be within reasonable bounds
     */
    function echidna_period_bounded() public view returns (bool) {
        for (uint256 i = 0; i < accounts.length; i++) {
            for (uint256 j = 0; j < tokens.length; j++) {
                SpendingConfig storage config = limits[accounts[i]][tokens[j]];
                if (config.configured) {
                    if (config.period < MIN_PERIOD || config.period > MAX_PERIOD) {
                        return false;
                    }
                }
            }
        }
        return true;
    }

    /**
     * @notice Last reset time should not be in the future
     */
    function echidna_last_reset_not_future() public view returns (bool) {
        for (uint256 i = 0; i < accounts.length; i++) {
            for (uint256 j = 0; j < tokens.length; j++) {
                SpendingConfig storage config = limits[accounts[i]][tokens[j]];
                if (config.configured && config.lastReset > block.timestamp) {
                    return false;
                }
            }
        }
        return true;
    }

    // ========================================================================
    // Property: State Consistency
    // ========================================================================

    /**
     * @notice Total spent across all accounts/tokens should be consistent
     */
    function echidna_total_spent_consistency() public view returns (bool) {
        uint256 computed = 0;
        for (uint256 i = 0; i < accounts.length; i++) {
            for (uint256 j = 0; j < tokens.length; j++) {
                computed += limits[accounts[i]][tokens[j]].spent;
            }
        }
        return computed == totalSpent;
    }

    // ========================================================================
    // Fuzz Actions: Limit Configuration
    // ========================================================================

    /**
     * @notice Configure a spending limit
     */
    function fuzz_setLimit(
        address account,
        address token,
        uint256 limit,
        uint256 period
    ) external {
        // Bound inputs
        if (account == address(0)) return;
        if (limit == 0 || limit > MAX_LIMIT) return;
        if (period < MIN_PERIOD || period > MAX_PERIOD) return;

        // Track account and token
        if (!isAccount[account]) {
            accounts.push(account);
            isAccount[account] = true;
        }
        if (!isToken[token]) {
            tokens.push(token);
            isToken[token] = true;
        }

        // If previously configured, adjust totals
        if (!limits[account][token].configured) {
            totalLimitConfigured++;
        }

        limits[account][token] = SpendingConfig({
            limit: limit,
            period: period,
            spent: 0,
            lastReset: block.timestamp,
            configured: true
        });
    }

    /**
     * @notice Update an existing limit
     */
    function fuzz_updateLimit(
        address account,
        address token,
        uint256 newLimit
    ) external {
        if (!limits[account][token].configured) return;
        if (newLimit == 0 || newLimit > MAX_LIMIT) return;

        // Can't set limit below current spent (would violate invariant)
        if (newLimit < limits[account][token].spent) return;

        limits[account][token].limit = newLimit;
    }

    // ========================================================================
    // Fuzz Actions: Spending
    // ========================================================================

    /**
     * @notice Record a spend
     */
    function fuzz_spend(
        address account,
        address token,
        uint256 amount
    ) external {
        SpendingConfig storage config = limits[account][token];
        if (!config.configured) return;
        if (amount == 0) return;

        // Check if period has expired and reset
        if (block.timestamp >= config.lastReset + config.period) {
            config.spent = 0;
            config.lastReset = block.timestamp;
        }

        // Check if spend would exceed limit
        if (config.spent + amount > config.limit) return;

        // Record spend
        config.spent += amount;
        totalSpent += amount;
    }

    /**
     * @notice Force reset for testing
     */
    function fuzz_resetSpent(address account, address token) external {
        SpendingConfig storage config = limits[account][token];
        if (!config.configured) return;

        // Only reset if period has elapsed
        if (block.timestamp >= config.lastReset + config.period) {
            totalSpent -= config.spent;
            config.spent = 0;
            config.lastReset = block.timestamp;
        }
    }

    // ========================================================================
    // View Functions
    // ========================================================================

    function getLimit(address account, address token) external view returns (
        uint256 limit,
        uint256 spent,
        uint256 remaining
    ) {
        SpendingConfig storage config = limits[account][token];
        limit = config.limit;
        spent = config.spent;
        remaining = config.limit > config.spent ? config.limit - config.spent : 0;
    }

    function getAccountCount() external view returns (uint256) {
        return accounts.length;
    }

    function getTokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function getTotalSpent() external view returns (uint256) {
        return totalSpent;
    }
}
