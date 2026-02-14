// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BridgeRateLimiter
 * @notice Rate limiting for bridge operations to prevent exploitation
 * @dev Implements per-transaction, hourly, and daily volume limits with auto-pause
 *
 * Rate Limiting Tiers:
 * - Per-transaction max: $100K (PoC) / $1M (mainnet)
 * - Hourly limit: $500K (PoC) / $5M (mainnet)
 * - Daily limit: $5M (PoC) / $50M (mainnet)
 * - Alert threshold: 80% of any limit
 * - Auto-pause threshold: 95% of any limit
 */
contract BridgeRateLimiter is Ownable, Pausable, ReentrancyGuard {
    // ============ Errors ============
    error ExceedsPerTransactionLimit();
    error ExceedsHourlyLimit();
    error ExceedsDailyLimit();
    error AlertThresholdReached();
    error AutoPauseTriggered();
    error InvalidLimit();
    error InvalidThreshold();
    error UnauthorizedCaller();
    error ZeroAddress();
    error ZeroAmount();
    error TokenNotSupported();
    error InvalidWindow();

    // ============ Events ============
    event TransactionRecorded(
        address indexed token, uint256 amount, uint256 usdValue, uint256 hourlyUsage, uint256 dailyUsage
    );
    event AlertTriggered(string limitType, uint256 currentUsage, uint256 limit, uint256 percentage);
    event AutoPauseActivated(string reason, uint256 currentUsage, uint256 limit);
    event LimitsUpdated(uint256 maxPerTx, uint256 hourlyLimit, uint256 dailyLimit);
    event ThresholdsUpdated(uint256 alertThreshold, uint256 autoPauseThreshold);
    event TokenPriceUpdated(address indexed token, uint256 price);
    event AuthorizedCallerUpdated(address indexed caller, bool authorized);
    event WindowReset(string windowType, uint256 timestamp);

    // ============ Structs ============

    /**
     * @notice Structure for tracking volume within a time window
     * @param volume Total volume in USD (scaled by 1e18)
     * @param windowStart Start timestamp of the current window
     * @param transactionCount Number of transactions in window
     */
    struct VolumeWindow {
        uint256 volume;
        uint256 windowStart;
        uint256 transactionCount;
    }

    /**
     * @notice Structure for rate limit configuration
     * @param maxPerTransaction Maximum USD value per transaction
     * @param hourlyLimit Maximum USD volume per hour
     * @param dailyLimit Maximum USD volume per day
     */
    struct RateLimitConfig {
        uint256 maxPerTransaction;
        uint256 hourlyLimit;
        uint256 dailyLimit;
    }

    /**
     * @notice Structure for token configuration
     * @param supported Whether the token is supported
     * @param price Price in USD (scaled by 1e18)
     * @param decimals Token decimals
     * @param customLimits Whether token has custom limits
     */
    struct TokenConfig {
        bool supported;
        uint256 price;
        uint8 decimals;
        bool customLimits;
    }

    // ============ Constants ============
    uint256 public constant HOUR = 1 hours;
    uint256 public constant DAY = 1 days;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_PERCENTAGE = 100;

    // Default limits for PoC (in USD scaled by 1e18)
    uint256 public constant DEFAULT_MAX_PER_TX = 100_000 * PRECISION; // $100K
    uint256 public constant DEFAULT_HOURLY_LIMIT = 500_000 * PRECISION; // $500K
    uint256 public constant DEFAULT_DAILY_LIMIT = 5_000_000 * PRECISION; // $5M

    // ============ State Variables ============

    /// @notice Global rate limit configuration
    RateLimitConfig public globalLimits;

    /// @notice Alert threshold percentage (default: 80%)
    uint256 public alertThreshold = 80;

    /// @notice Auto-pause threshold percentage (default: 95%)
    uint256 public autoPauseThreshold = 95;

    /// @notice Hourly volume tracking
    VolumeWindow public hourlyWindow;

    /// @notice Daily volume tracking
    VolumeWindow public dailyWindow;

    /// @notice Token configurations
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice Custom limits per token (if customLimits is true)
    mapping(address => RateLimitConfig) public tokenLimits;

    /// @notice Per-address daily volume tracking
    mapping(address => VolumeWindow) public addressDailyVolume;

    /// @notice Authorized callers (bridge contracts)
    mapping(address => bool) public authorizedCallers;

    /// @notice Total transactions processed
    uint256 public totalTransactions;

    /// @notice Total volume processed (lifetime, in USD)
    uint256 public totalVolumeProcessed;

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
     * @notice Initialize the BridgeRateLimiter with default limits
     */
    constructor() Ownable(msg.sender) {
        globalLimits = RateLimitConfig({
            maxPerTransaction: DEFAULT_MAX_PER_TX, hourlyLimit: DEFAULT_HOURLY_LIMIT, dailyLimit: DEFAULT_DAILY_LIMIT
        });

        // Initialize windows
        hourlyWindow.windowStart = block.timestamp;
        dailyWindow.windowStart = block.timestamp;
    }

    // ============ External Functions ============

    /**
     * @notice Check if a transaction is within rate limits (and record it)
     * @param token Token address
     * @param amount Token amount
     * @return allowed Whether the transaction is allowed
     * @return usdValue USD value of the transaction
     */
    function checkAndRecordTransaction(address token, uint256 amount)
        external
        onlyAuthorized
        whenNotPaused
        nonReentrant
        returns (bool allowed, uint256 usdValue)
    {
        if (amount == 0) revert ZeroAmount();

        TokenConfig storage config = tokenConfigs[token];
        if (!config.supported) revert TokenNotSupported();

        // Calculate USD value
        usdValue = _calculateUsdValue(token, amount);

        // Get applicable limits
        RateLimitConfig memory limits = config.customLimits ? tokenLimits[token] : globalLimits;

        // Check per-transaction limit
        if (usdValue > limits.maxPerTransaction) {
            revert ExceedsPerTransactionLimit();
        }

        // Update windows if needed
        _updateWindows();

        // Check hourly limit
        uint256 newHourlyVolume = hourlyWindow.volume + usdValue;
        if (newHourlyVolume > limits.hourlyLimit) {
            revert ExceedsHourlyLimit();
        }

        // Check daily limit
        uint256 newDailyVolume = dailyWindow.volume + usdValue;
        if (newDailyVolume > limits.dailyLimit) {
            revert ExceedsDailyLimit();
        }

        // Check thresholds and potentially trigger alerts/pause
        bool autoPaused = _checkThresholds(newHourlyVolume, newDailyVolume, limits);
        if (autoPaused) {
            return (false, usdValue);
        }

        // Record the transaction
        hourlyWindow.volume = newHourlyVolume;
        hourlyWindow.transactionCount++;
        dailyWindow.volume = newDailyVolume;
        dailyWindow.transactionCount++;

        totalTransactions++;
        totalVolumeProcessed += usdValue;

        emit TransactionRecorded(token, amount, usdValue, newHourlyVolume, newDailyVolume);

        return (true, usdValue);
    }

    /**
     * @notice Check if a transaction would be within limits (view function)
     * @param token Token address
     * @param amount Token amount
     * @return allowed Whether the transaction would be allowed
     * @return reason Reason if not allowed
     */
    function checkTransaction(address token, uint256 amount)
        external
        view
        returns (bool allowed, string memory reason)
    {
        if (amount == 0) return (false, "Zero amount");

        TokenConfig storage config = tokenConfigs[token];
        if (!config.supported) return (false, "Token not supported");

        uint256 usdValue = _calculateUsdValue(token, amount);

        RateLimitConfig memory limits = config.customLimits ? tokenLimits[token] : globalLimits;

        if (usdValue > limits.maxPerTransaction) {
            return (false, "Exceeds per-transaction limit");
        }

        // Get current window volumes (accounting for window resets)
        (uint256 currentHourly, uint256 currentDaily) = _getCurrentVolumes();

        if (currentHourly + usdValue > limits.hourlyLimit) {
            return (false, "Exceeds hourly limit");
        }

        if (currentDaily + usdValue > limits.dailyLimit) {
            return (false, "Exceeds daily limit");
        }

        return (true, "");
    }

    /**
     * @notice Get remaining capacity for transactions
     * @return perTx Remaining per-transaction capacity (always full limit)
     * @return hourly Remaining hourly capacity
     * @return daily Remaining daily capacity
     */
    function getRemainingCapacity() external view returns (uint256 perTx, uint256 hourly, uint256 daily) {
        (uint256 currentHourly, uint256 currentDaily) = _getCurrentVolumes();

        perTx = globalLimits.maxPerTransaction;

        if (currentHourly >= globalLimits.hourlyLimit) {
            hourly = 0;
        } else {
            hourly = globalLimits.hourlyLimit - currentHourly;
        }

        if (currentDaily >= globalLimits.dailyLimit) {
            daily = 0;
        } else {
            daily = globalLimits.dailyLimit - currentDaily;
        }
    }

    /**
     * @notice Get current usage percentages
     * @return hourlyPct Hourly usage percentage
     * @return dailyPct Daily usage percentage
     */
    function getUsagePercentages() external view returns (uint256 hourlyPct, uint256 dailyPct) {
        (uint256 currentHourly, uint256 currentDaily) = _getCurrentVolumes();

        if (globalLimits.hourlyLimit > 0) {
            hourlyPct = (currentHourly * 100) / globalLimits.hourlyLimit;
        }

        if (globalLimits.dailyLimit > 0) {
            dailyPct = (currentDaily * 100) / globalLimits.dailyLimit;
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Set global rate limits
     * @param maxPerTx Maximum per transaction (in USD scaled by 1e18)
     * @param hourlyLimit Hourly limit (in USD scaled by 1e18)
     * @param dailyLimit Daily limit (in USD scaled by 1e18)
     */
    function setGlobalLimits(uint256 maxPerTx, uint256 hourlyLimit, uint256 dailyLimit) external onlyOwner {
        if (maxPerTx == 0 || hourlyLimit == 0 || dailyLimit == 0) revert InvalidLimit();
        if (maxPerTx > hourlyLimit || hourlyLimit > dailyLimit) revert InvalidLimit();

        globalLimits =
            RateLimitConfig({ maxPerTransaction: maxPerTx, hourlyLimit: hourlyLimit, dailyLimit: dailyLimit });

        emit LimitsUpdated(maxPerTx, hourlyLimit, dailyLimit);
    }

    /**
     * @notice Set alert and auto-pause thresholds
     * @param _alertThreshold Alert threshold percentage (0-100)
     * @param _autoPauseThreshold Auto-pause threshold percentage (0-100)
     */
    function setThresholds(uint256 _alertThreshold, uint256 _autoPauseThreshold) external onlyOwner {
        if (_alertThreshold > MAX_PERCENTAGE || _autoPauseThreshold > MAX_PERCENTAGE) {
            revert InvalidThreshold();
        }
        if (_alertThreshold >= _autoPauseThreshold) revert InvalidThreshold();

        alertThreshold = _alertThreshold;
        autoPauseThreshold = _autoPauseThreshold;

        emit ThresholdsUpdated(_alertThreshold, _autoPauseThreshold);
    }

    /**
     * @notice Configure a supported token
     * @dev address(0) is allowed to represent native ETH
     * @param token Token address (address(0) for native ETH)
     * @param price Price in USD (scaled by 1e18)
     * @param decimals Token decimals
     */
    function configureToken(address token, uint256 price, uint8 decimals) external onlyOwner {
        // Note: address(0) is allowed to represent native ETH

        tokenConfigs[token] = TokenConfig({ supported: true, price: price, decimals: decimals, customLimits: false });

        emit TokenPriceUpdated(token, price);
    }

    /**
     * @notice Set custom limits for a specific token
     * @param token Token address
     * @param maxPerTx Maximum per transaction
     * @param hourlyLimit Hourly limit
     * @param dailyLimit Daily limit
     */
    function setTokenLimits(address token, uint256 maxPerTx, uint256 hourlyLimit, uint256 dailyLimit)
        external
        onlyOwner
    {
        if (!tokenConfigs[token].supported) revert TokenNotSupported();
        if (maxPerTx == 0 || hourlyLimit == 0 || dailyLimit == 0) revert InvalidLimit();

        tokenConfigs[token].customLimits = true;
        tokenLimits[token] =
            RateLimitConfig({ maxPerTransaction: maxPerTx, hourlyLimit: hourlyLimit, dailyLimit: dailyLimit });
    }

    /**
     * @notice Update token price
     * @param token Token address
     * @param price New price in USD (scaled by 1e18)
     */
    function updateTokenPrice(address token, uint256 price) external onlyOwner {
        if (!tokenConfigs[token].supported) revert TokenNotSupported();

        tokenConfigs[token].price = price;

        emit TokenPriceUpdated(token, price);
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
     * @notice Reset hourly window (emergency function)
     */
    function resetHourlyWindow() external onlyOwner {
        hourlyWindow.volume = 0;
        hourlyWindow.windowStart = block.timestamp;
        hourlyWindow.transactionCount = 0;

        emit WindowReset("hourly", block.timestamp);
    }

    /**
     * @notice Reset daily window (emergency function)
     */
    function resetDailyWindow() external onlyOwner {
        dailyWindow.volume = 0;
        dailyWindow.windowStart = block.timestamp;
        dailyWindow.transactionCount = 0;

        emit WindowReset("daily", block.timestamp);
    }

    /**
     * @notice Pause the rate limiter
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the rate limiter
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ View Functions ============

    /**
     * @notice Get global limits
     * @return config The global rate limit configuration
     */
    function getGlobalLimits() external view returns (RateLimitConfig memory) {
        return globalLimits;
    }

    /**
     * @notice Get token configuration
     * @param token Token address
     * @return config The token configuration
     */
    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        return tokenConfigs[token];
    }

    /**
     * @notice Get current window volumes
     * @return hourlyVolume Current hourly volume
     * @return dailyVolume Current daily volume
     */
    function getCurrentWindowVolumes() external view returns (uint256 hourlyVolume, uint256 dailyVolume) {
        return _getCurrentVolumes();
    }

    /**
     * @notice Get window statistics
     * @return hourlyTxCount Transactions in current hour
     * @return dailyTxCount Transactions in current day
     * @return hourlyStart Start of hourly window
     * @return dailyStart Start of daily window
     */
    function getWindowStats()
        external
        view
        returns (uint256 hourlyTxCount, uint256 dailyTxCount, uint256 hourlyStart, uint256 dailyStart)
    {
        // Check if windows should be reset
        if (block.timestamp >= hourlyWindow.windowStart + HOUR) {
            hourlyTxCount = 0;
            hourlyStart = block.timestamp;
        } else {
            hourlyTxCount = hourlyWindow.transactionCount;
            hourlyStart = hourlyWindow.windowStart;
        }

        if (block.timestamp >= dailyWindow.windowStart + DAY) {
            dailyTxCount = 0;
            dailyStart = block.timestamp;
        } else {
            dailyTxCount = dailyWindow.transactionCount;
            dailyStart = dailyWindow.windowStart;
        }
    }

    /**
     * @notice Calculate USD value for a token amount
     * @param token Token address
     * @param amount Token amount
     * @return usdValue USD value (scaled by 1e18)
     */
    function calculateUsdValue(address token, uint256 amount) external view returns (uint256) {
        return _calculateUsdValue(token, amount);
    }

    /**
     * @notice Check if an address is authorized
     * @param caller Address to check
     * @return authorized Whether authorized
     */
    function isAuthorizedCaller(address caller) external view returns (bool) {
        return authorizedCallers[caller];
    }

    // ============ Internal Functions ============

    /**
     * @notice Calculate USD value for a token amount
     * @param token Token address
     * @param amount Token amount
     * @return usdValue USD value (scaled by 1e18)
     */
    function _calculateUsdValue(address token, uint256 amount) internal view returns (uint256) {
        TokenConfig storage config = tokenConfigs[token];

        // Normalize amount to 18 decimals then multiply by price
        uint256 normalizedAmount;
        if (config.decimals < 18) {
            normalizedAmount = amount * (10 ** (18 - config.decimals));
        } else if (config.decimals > 18) {
            normalizedAmount = amount / (10 ** (config.decimals - 18));
        } else {
            normalizedAmount = amount;
        }

        return (normalizedAmount * config.price) / PRECISION;
    }

    /**
     * @notice Update windows if they've expired
     */
    function _updateWindows() internal {
        // Update hourly window
        if (block.timestamp >= hourlyWindow.windowStart + HOUR) {
            hourlyWindow.volume = 0;
            hourlyWindow.windowStart = block.timestamp;
            hourlyWindow.transactionCount = 0;

            emit WindowReset("hourly", block.timestamp);
        }

        // Update daily window
        if (block.timestamp >= dailyWindow.windowStart + DAY) {
            dailyWindow.volume = 0;
            dailyWindow.windowStart = block.timestamp;
            dailyWindow.transactionCount = 0;

            emit WindowReset("daily", block.timestamp);
        }
    }

    /**
     * @notice Get current volumes accounting for window resets
     * @return hourlyVolume Current hourly volume
     * @return dailyVolume Current daily volume
     */
    function _getCurrentVolumes() internal view returns (uint256 hourlyVolume, uint256 dailyVolume) {
        // Check hourly window
        if (block.timestamp >= hourlyWindow.windowStart + HOUR) {
            hourlyVolume = 0;
        } else {
            hourlyVolume = hourlyWindow.volume;
        }

        // Check daily window
        if (block.timestamp >= dailyWindow.windowStart + DAY) {
            dailyVolume = 0;
        } else {
            dailyVolume = dailyWindow.volume;
        }
    }

    /**
     * @notice Check thresholds and trigger alerts/pause if needed
     * @param newHourlyVolume New hourly volume after transaction
     * @param newDailyVolume New daily volume after transaction
     * @param limits Applicable limits
     */
    function _checkThresholds(uint256 newHourlyVolume, uint256 newDailyVolume, RateLimitConfig memory limits)
        internal
        returns (bool paused)
    {
        // Check hourly thresholds
        uint256 hourlyPct = (newHourlyVolume * 100) / limits.hourlyLimit;

        if (hourlyPct >= autoPauseThreshold) {
            _pause();
            emit AutoPauseActivated("hourly_limit", newHourlyVolume, limits.hourlyLimit);
            return true;
        }

        if (hourlyPct >= alertThreshold) {
            emit AlertTriggered("hourly", newHourlyVolume, limits.hourlyLimit, hourlyPct);
        }

        // Check daily thresholds
        uint256 dailyPct = (newDailyVolume * 100) / limits.dailyLimit;

        if (dailyPct >= autoPauseThreshold) {
            _pause();
            emit AutoPauseActivated("daily_limit", newDailyVolume, limits.dailyLimit);
            return true;
        }

        if (dailyPct >= alertThreshold) {
            emit AlertTriggered("daily", newDailyVolume, limits.dailyLimit, dailyPct);
        }

        return false;
    }
}
