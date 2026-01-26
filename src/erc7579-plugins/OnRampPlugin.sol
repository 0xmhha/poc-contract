// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IExecutor } from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { MODULE_TYPE_EXECUTOR } from "../erc7579-smartaccount/types/Constants.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

/**
 * @title OnRampPlugin
 * @notice ERC-7579 Plugin for fiat on-ramp integration
 * @dev Enables smart accounts to receive funds from off-chain payment providers
 *
 * Features:
 * - Support for multiple on-ramp providers (Moonpay, Transak, Wyre, etc.)
 * - KYC/AML verification tracking
 * - Order management with status tracking
 * - Secure claim mechanism with provider signatures
 * - Rate limiting and limits per provider
 *
 * Use Cases:
 * - Purchase crypto with credit/debit card
 * - Bank transfer to crypto
 * - Mobile money to crypto
 * - Voucher/prepaid card redemption
 *
 * Flow:
 * 1. User initiates purchase through on-ramp provider's UI
 * 2. Provider processes payment off-chain
 * 3. Provider signs order completion
 * 4. Anyone can call claimOrder with the signature
 * 5. Tokens are minted/transferred to user's smart account
 */
contract OnRampPlugin is IExecutor {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    /// @notice Provider status
    enum ProviderStatus {
        INACTIVE,
        ACTIVE,
        PAUSED
    }

    /// @notice Order status
    enum OrderStatus {
        PENDING,
        COMPLETED,
        CANCELLED,
        REFUNDED,
        EXPIRED
    }

    /// @notice KYC level
    enum KYCLevel {
        NONE,
        BASIC, // Email + Phone
        STANDARD, // ID verification
        ENHANCED // Full verification
    }

    /// @notice Provider configuration
    struct Provider {
        string name;
        address signer; // Address that signs completed orders
        address tokenAddress; // Token this provider delivers
        ProviderStatus status;
        uint256 minAmount;
        uint256 maxAmount;
        uint256 dailyLimit;
        uint256 dailyUsed;
        uint256 lastResetTime;
        KYCLevel requiredKyc;
    }

    /// @notice On-ramp order
    struct Order {
        bytes32 orderId; // External order ID from provider
        uint256 providerId;
        address recipient;
        uint256 fiatAmount; // Amount in fiat (scaled by 100 for cents)
        string fiatCurrency; // e.g., "USD", "EUR", "KRW"
        uint256 cryptoAmount; // Amount of crypto to deliver
        uint256 exchangeRate; // Rate at time of order (18 decimals)
        OrderStatus status;
        uint256 createdAt;
        uint256 completedAt;
    }

    /// @notice User KYC status
    struct UserKyc {
        KYCLevel level;
        uint256 verifiedAt;
        bytes32 verificationHash; // Hash of KYC documents
        bool isBlacklisted;
    }

    /// @notice Providers: providerId => Provider
    mapping(uint256 => Provider) public providers;
    uint256 public nextProviderId;

    /// @notice Orders: orderId (external) => Order
    mapping(bytes32 => Order) public orders;

    /// @notice User KYC status: user => UserKyc
    mapping(address => UserKyc) public userKyc;

    /// @notice User orders: user => orderIds
    mapping(address => bytes32[]) public userOrders;

    /// @notice Nonces for replay protection: orderId => claimed
    mapping(bytes32 => bool) public claimedOrders;

    /// @notice Treasury address for fees
    address public treasury;

    /// @notice Fee in basis points
    uint256 public feeBps;

    /// @notice Order expiry time
    uint256 public orderExpiry;

    /// @notice Basis points
    uint256 public constant BASIS_POINTS = 10_000;

    // Events
    event ProviderAdded(uint256 indexed providerId, string name, address signer);
    event ProviderUpdated(uint256 indexed providerId, ProviderStatus status);
    event OrderCreated(
        bytes32 indexed orderId,
        uint256 indexed providerId,
        address indexed recipient,
        uint256 fiatAmount,
        uint256 cryptoAmount
    );
    event OrderCompleted(bytes32 indexed orderId, address indexed recipient, uint256 cryptoAmount, uint256 fee);
    event OrderCancelled(bytes32 indexed orderId);
    event KYCUpdated(address indexed user, KYCLevel level);

    // Errors
    error ProviderNotActive();
    error InvalidSignature();
    error OrderAlreadyClaimed();
    error OrderExpiredError();
    error InsufficientKYC();
    error AmountBelowMinimum();
    error AmountAboveMaximum();
    error DailyLimitExceeded();
    error UserBlacklisted();
    error InvalidOrderStatus();
    error ZeroAddress();

    /**
     * @notice Constructor
     * @param _treasury Treasury address for fees
     * @param _feeBps Fee in basis points
     * @param _orderExpiry Order expiry time in seconds
     */
    constructor(address _treasury, uint256 _feeBps, uint256 _orderExpiry) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        feeBps = _feeBps;
        orderExpiry = _orderExpiry > 0 ? _orderExpiry : 24 hours;
    }

    // ============ IModule Implementation ============

    function onInstall(bytes calldata) external payable override {
        // No initialization needed
    }

    function onUninstall(bytes calldata) external payable override {
        // No cleanup needed
    }

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    function isInitialized(address) external pure override returns (bool) {
        return true;
    }

    // ============ Provider Management ============

    /**
     * @notice Add a new on-ramp provider
     * @param name Provider name
     * @param signer Signer address for order completion
     * @param tokenAddress Token this provider delivers
     * @param minAmount Minimum order amount
     * @param maxAmount Maximum order amount
     * @param dailyLimit Daily limit per provider
     * @param requiredKyc Required KYC level
     */
    function addProvider(
        string calldata name,
        address signer,
        address tokenAddress,
        uint256 minAmount,
        uint256 maxAmount,
        uint256 dailyLimit,
        KYCLevel requiredKyc
    ) external returns (uint256 providerId) {
        if (signer == address(0)) revert ZeroAddress();

        providerId = nextProviderId++;

        providers[providerId] = Provider({
            name: name,
            signer: signer,
            tokenAddress: tokenAddress,
            status: ProviderStatus.ACTIVE,
            minAmount: minAmount,
            maxAmount: maxAmount,
            dailyLimit: dailyLimit,
            dailyUsed: 0,
            lastResetTime: block.timestamp,
            requiredKyc: requiredKyc
        });

        emit ProviderAdded(providerId, name, signer);
    }

    /**
     * @notice Update provider status
     * @param providerId The provider ID
     * @param status New status
     */
    function setProviderStatus(uint256 providerId, ProviderStatus status) external {
        providers[providerId].status = status;
        emit ProviderUpdated(providerId, status);
    }

    /**
     * @notice Update provider signer
     * @param providerId The provider ID
     * @param signer New signer address
     */
    function setProviderSigner(uint256 providerId, address signer) external {
        if (signer == address(0)) revert ZeroAddress();
        providers[providerId].signer = signer;
    }

    /**
     * @notice Update provider limits
     * @param providerId The provider ID
     * @param minAmount New minimum
     * @param maxAmount New maximum
     * @param dailyLimit New daily limit
     */
    function setProviderLimits(uint256 providerId, uint256 minAmount, uint256 maxAmount, uint256 dailyLimit) external {
        Provider storage provider = providers[providerId];
        provider.minAmount = minAmount;
        provider.maxAmount = maxAmount;
        provider.dailyLimit = dailyLimit;
    }

    // ============ KYC Management ============

    /**
     * @notice Update user KYC status (called by authorized verifiers)
     * @param user User address
     * @param level KYC level
     * @param verificationHash Hash of verification documents
     */
    function setUserKyc(address user, KYCLevel level, bytes32 verificationHash) external {
        userKyc[user] = UserKyc({
            level: level, verifiedAt: block.timestamp, verificationHash: verificationHash, isBlacklisted: false
        });

        emit KYCUpdated(user, level);
    }

    /**
     * @notice Blacklist a user
     * @param user User address
     * @param blacklisted Blacklist status
     */
    function setUserBlacklist(address user, bool blacklisted) external {
        userKyc[user].isBlacklisted = blacklisted;
    }

    // ============ Order Management ============

    /**
     * @notice Create an on-ramp order (called by provider's backend)
     * @param orderId External order ID
     * @param providerId Provider ID
     * @param recipient Recipient smart account
     * @param fiatAmount Fiat amount (scaled by 100)
     * @param fiatCurrency Fiat currency code
     * @param cryptoAmount Crypto amount to deliver
     * @param exchangeRate Exchange rate used
     */
    function createOrder(
        bytes32 orderId,
        uint256 providerId,
        address recipient,
        uint256 fiatAmount,
        string calldata fiatCurrency,
        uint256 cryptoAmount,
        uint256 exchangeRate
    ) external {
        Provider storage provider = providers[providerId];

        // Validations
        if (provider.status != ProviderStatus.ACTIVE) revert ProviderNotActive();
        if (cryptoAmount < provider.minAmount) revert AmountBelowMinimum();
        if (cryptoAmount > provider.maxAmount) revert AmountAboveMaximum();

        // Check KYC
        UserKyc storage kyc = userKyc[recipient];
        if (kyc.isBlacklisted) revert UserBlacklisted();
        if (kyc.level < provider.requiredKyc) revert InsufficientKYC();

        // Check and update daily limit
        _checkAndUpdateDailyLimit(provider, cryptoAmount);

        // Create order
        orders[orderId] = Order({
            orderId: orderId,
            providerId: providerId,
            recipient: recipient,
            fiatAmount: fiatAmount,
            fiatCurrency: fiatCurrency,
            cryptoAmount: cryptoAmount,
            exchangeRate: exchangeRate,
            status: OrderStatus.PENDING,
            createdAt: block.timestamp,
            completedAt: 0
        });

        userOrders[recipient].push(orderId);

        emit OrderCreated(orderId, providerId, recipient, fiatAmount, cryptoAmount);
    }

    /**
     * @notice Claim completed order (with provider signature)
     * @param orderId The order ID
     * @param signature Provider signature authorizing claim
     */
    function claimOrder(bytes32 orderId, bytes calldata signature) external {
        // Check not already claimed
        if (claimedOrders[orderId]) revert OrderAlreadyClaimed();

        Order storage order = orders[orderId];
        Provider storage provider = providers[order.providerId];

        // Validate order status
        if (order.status != OrderStatus.PENDING) revert InvalidOrderStatus();

        // Check expiry
        if (block.timestamp > order.createdAt + orderExpiry) {
            order.status = OrderStatus.EXPIRED;
            emit OrderCancelled(orderId);
            revert OrderExpiredError();
        }

        // Verify signature
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 messageHash = keccak256(abi.encodePacked(orderId, order.recipient, order.cryptoAmount, block.chainid));

        address recovered = ECDSA.recover(ECDSA.toEthSignedMessageHash(messageHash), signature);

        if (recovered != provider.signer) revert InvalidSignature();

        // Mark as claimed
        claimedOrders[orderId] = true;
        order.status = OrderStatus.COMPLETED;
        order.completedAt = block.timestamp;

        // Calculate fee
        uint256 fee = (order.cryptoAmount * feeBps) / BASIS_POINTS;
        uint256 netAmount = order.cryptoAmount - fee;

        // Transfer tokens
        IERC20 token = IERC20(provider.tokenAddress);

        if (netAmount > 0) {
            token.safeTransfer(order.recipient, netAmount);
        }
        if (fee > 0) {
            token.safeTransfer(treasury, fee);
        }

        emit OrderCompleted(orderId, order.recipient, netAmount, fee);
    }

    /**
     * @notice Cancel an order (by provider)
     * @param orderId The order ID
     */
    function cancelOrder(bytes32 orderId) external {
        Order storage order = orders[orderId];

        if (order.status != OrderStatus.PENDING) revert InvalidOrderStatus();

        order.status = OrderStatus.CANCELLED;

        emit OrderCancelled(orderId);
    }

    /**
     * @notice Refund an order (by provider - marks as refunded)
     * @param orderId The order ID
     */
    function refundOrder(bytes32 orderId) external {
        Order storage order = orders[orderId];

        if (order.status != OrderStatus.PENDING && order.status != OrderStatus.COMPLETED) {
            revert InvalidOrderStatus();
        }

        order.status = OrderStatus.REFUNDED;
    }

    // ============ View Functions ============

    /**
     * @notice Get provider details
     * @param providerId The provider ID
     */
    function getProvider(uint256 providerId) external view returns (Provider memory) {
        return providers[providerId];
    }

    /**
     * @notice Get order details
     * @param orderId The order ID
     */
    function getOrder(bytes32 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /**
     * @notice Get user's orders
     * @param user The user address
     */
    function getUserOrders(address user) external view returns (bytes32[] memory) {
        return userOrders[user];
    }

    /**
     * @notice Get user's KYC status
     * @param user The user address
     */
    function getUserKycStatus(address user) external view returns (UserKyc memory) {
        return userKyc[user];
    }

    /**
     * @notice Check if order can be claimed
     * @param orderId The order ID
     */
    function canClaimOrder(bytes32 orderId) external view returns (bool) {
        if (claimedOrders[orderId]) return false;

        Order storage order = orders[orderId];
        if (order.status != OrderStatus.PENDING) return false;
        if (block.timestamp > order.createdAt + orderExpiry) return false;

        return true;
    }

    /**
     * @notice Get remaining daily limit for provider
     * @param providerId The provider ID
     */
    function getRemainingDailyLimit(uint256 providerId) external view returns (uint256) {
        Provider storage provider = providers[providerId];

        // Check if limit should reset
        if (block.timestamp >= provider.lastResetTime + 1 days) {
            return provider.dailyLimit;
        }

        if (provider.dailyUsed >= provider.dailyLimit) return 0;
        return provider.dailyLimit - provider.dailyUsed;
    }

    // ============ Internal Functions ============

    function _checkAndUpdateDailyLimit(Provider storage provider, uint256 amount) internal {
        // Reset daily limit if 24 hours passed
        if (block.timestamp >= provider.lastResetTime + 1 days) {
            provider.dailyUsed = 0;
            provider.lastResetTime = block.timestamp;
        }

        // Check limit
        if (provider.dailyUsed + amount > provider.dailyLimit) {
            revert DailyLimitExceeded();
        }

        provider.dailyUsed += amount;
    }
}
