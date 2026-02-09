// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title IERC5564Announcer
 * @notice Minimal interface for ERC-5564 announcer
 */
interface IERC5564Announcer {
    function announce(uint256 schemeId, address stealthAddress, bytes memory ephemeralPubKey, bytes memory metadata)
        external;
}

/**
 * @title IERC6538Registry
 * @notice Minimal interface for ERC-6538 registry
 */
interface IERC6538Registry {
    function stealthMetaAddressOf(address registrant, uint256 schemeId) external view returns (bytes memory);
}

/**
 * @title PrivateBank
 * @notice Privacy-preserving deposit and withdrawal system using stealth addresses
 * @dev Combines ERC-5564 (Stealth Addresses) and ERC-6538 (Registry) for private transfers
 *
 * How it works:
 * 1. Recipient registers stealth meta-address in ERC6538Registry
 * 2. Sender computes stealth address from recipient's meta-address (off-chain)
 * 3. Sender deposits to PrivateBank with stealth address
 * 4. PrivateBank announces the deposit via ERC5564Announcer
 * 5. Recipient scans announcements, derives private key, withdraws
 *
 * Supported assets:
 * - Native tokens (ETH, etc.)
 * - ERC-20 tokens (whitelisted)
 */
contract PrivateBank is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /* //////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error TokenNotSupported();
    error InvalidEphemeralPubKey();
    error WithdrawFailed();
    error DepositLimitExceeded();
    error DailyLimitExceeded();

    /* //////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when native tokens are deposited to a stealth address
    event NativeDeposit(
        address indexed stealthAddress, address indexed depositor, uint256 amount, uint256 indexed schemeId
    );

    /// @notice Emitted when ERC-20 tokens are deposited to a stealth address
    event TokenDeposit(
        address indexed stealthAddress,
        address indexed token,
        address indexed depositor,
        uint256 amount,
        uint256 schemeId
    );

    /// @notice Emitted when funds are withdrawn
    event Withdrawal(address indexed stealthAddress, address indexed recipient, address token, uint256 amount);

    /// @notice Emitted when a token is added/removed from whitelist
    event TokenWhitelistUpdated(address indexed token, bool supported);

    /// @notice Emitted when deposit limit is updated
    event DepositLimitUpdated(uint256 newLimit);

    /// @notice Emitted when daily limit is updated
    event DailyLimitUpdated(uint256 newLimit);

    /* //////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC-5564 Announcer contract
    IERC5564Announcer public immutable ANNOUNCER;

    /// @notice ERC-6538 Registry contract
    IERC6538Registry public immutable REGISTRY;

    /// @notice Native token balances by stealth address
    mapping(address => uint256) public nativeBalances;

    /// @notice ERC-20 token balances: stealthAddress => token => balance
    mapping(address => mapping(address => uint256)) public tokenBalances;

    /// @notice Supported ERC-20 tokens
    mapping(address => bool) public supportedTokens;

    /// @notice Maximum single deposit amount (0 = no limit)
    uint256 public maxDepositAmount;

    /// @notice Maximum daily deposit amount per user (0 = no limit)
    uint256 public dailyDepositLimit;

    /// @notice Daily deposit tracking: user => day => amount
    mapping(address => mapping(uint256 => uint256)) public dailyDeposits;

    /// @notice Total native token deposits
    uint256 public totalNativeDeposits;

    /// @notice Total deposits per token
    mapping(address => uint256) public totalTokenDeposits;

    /// @notice Native token placeholder address
    address public constant NATIVE_TOKEN = address(0);

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the PrivateBank
     * @param _announcer ERC-5564 Announcer address
     * @param _registry ERC-6538 Registry address
     */
    constructor(address _announcer, address _registry) Ownable(msg.sender) {
        if (_announcer == address(0)) revert ZeroAddress();
        if (_registry == address(0)) revert ZeroAddress();

        ANNOUNCER = IERC5564Announcer(_announcer);
        REGISTRY = IERC6538Registry(_registry);
    }

    /* //////////////////////////////////////////////////////////////
                          DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit native tokens to a stealth address
     * @param schemeId Stealth address scheme identifier
     * @param stealthAddress The recipient's stealth address
     * @param ephemeralPubKey Ephemeral public key for announcement
     * @param metadata Additional metadata (first byte = view tag)
     */
    function depositNative(
        uint256 schemeId,
        address stealthAddress,
        bytes calldata ephemeralPubKey,
        bytes calldata metadata
    ) external payable nonReentrant {
        if (stealthAddress == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert ZeroAmount();
        if (ephemeralPubKey.length == 0) revert InvalidEphemeralPubKey();

        // Check deposit limits
        _checkDepositLimits(msg.sender, msg.value);

        // Update balance
        nativeBalances[stealthAddress] += msg.value;
        totalNativeDeposits += msg.value;

        // Announce the deposit
        ANNOUNCER.announce(schemeId, stealthAddress, ephemeralPubKey, metadata);

        emit NativeDeposit(stealthAddress, msg.sender, msg.value, schemeId);
    }

    /**
     * @notice Deposit ERC-20 tokens to a stealth address
     * @param token The ERC-20 token address
     * @param amount The amount to deposit
     * @param schemeId Stealth address scheme identifier
     * @param stealthAddress The recipient's stealth address
     * @param ephemeralPubKey Ephemeral public key for announcement
     * @param metadata Additional metadata (first byte = view tag)
     */
    function depositToken(
        address token,
        uint256 amount,
        uint256 schemeId,
        address stealthAddress,
        bytes calldata ephemeralPubKey,
        bytes calldata metadata
    ) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (stealthAddress == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!supportedTokens[token]) revert TokenNotSupported();
        if (ephemeralPubKey.length == 0) revert InvalidEphemeralPubKey();

        // Check deposit limits
        _checkDepositLimits(msg.sender, amount);

        // Transfer tokens from sender
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update balance
        tokenBalances[stealthAddress][token] += amount;
        totalTokenDeposits[token] += amount;

        // Announce the deposit with token info in metadata
        bytes memory enrichedMetadata = abi.encodePacked(metadata, token, amount);
        ANNOUNCER.announce(schemeId, stealthAddress, ephemeralPubKey, enrichedMetadata);

        emit TokenDeposit(stealthAddress, token, msg.sender, amount, schemeId);
    }

    /* //////////////////////////////////////////////////////////////
                         WITHDRAWAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraw native tokens from a stealth address
     * @param amount The amount to withdraw
     * @dev Caller must be the stealth address owner (derived private key)
     */
    function withdrawNative(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (nativeBalances[msg.sender] < amount) revert InsufficientBalance();

        // Update balance
        nativeBalances[msg.sender] -= amount;
        totalNativeDeposits -= amount;

        // Transfer native tokens
        (bool success,) = msg.sender.call{ value: amount }("");
        if (!success) revert WithdrawFailed();

        emit Withdrawal(msg.sender, msg.sender, NATIVE_TOKEN, amount);
    }

    /**
     * @notice Withdraw native tokens to a different address
     * @param recipient The address to receive funds
     * @param amount The amount to withdraw
     */
    function withdrawNativeTo(address recipient, uint256 amount) external nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (nativeBalances[msg.sender] < amount) revert InsufficientBalance();

        // Update balance
        nativeBalances[msg.sender] -= amount;
        totalNativeDeposits -= amount;

        // Transfer native tokens
        (bool success,) = recipient.call{ value: amount }("");
        if (!success) revert WithdrawFailed();

        emit Withdrawal(msg.sender, recipient, NATIVE_TOKEN, amount);
    }

    /**
     * @notice Withdraw ERC-20 tokens from a stealth address
     * @param token The ERC-20 token address
     * @param amount The amount to withdraw
     */
    function withdrawToken(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (tokenBalances[msg.sender][token] < amount) revert InsufficientBalance();

        // Update balance
        tokenBalances[msg.sender][token] -= amount;
        totalTokenDeposits[token] -= amount;

        // Transfer tokens
        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdrawal(msg.sender, msg.sender, token, amount);
    }

    /**
     * @notice Withdraw ERC-20 tokens to a different address
     * @param token The ERC-20 token address
     * @param recipient The address to receive funds
     * @param amount The amount to withdraw
     */
    function withdrawTokenTo(address token, address recipient, uint256 amount) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (tokenBalances[msg.sender][token] < amount) revert InsufficientBalance();

        // Update balance
        tokenBalances[msg.sender][token] -= amount;
        totalTokenDeposits[token] -= amount;

        // Transfer tokens
        IERC20(token).safeTransfer(recipient, amount);

        emit Withdrawal(msg.sender, recipient, token, amount);
    }

    /**
     * @notice Withdraw all funds (native + tokens) from a stealth address
     * @param tokens Array of token addresses to withdraw (empty for native only)
     * @param recipient The address to receive all funds
     */
    function withdrawAll(address[] calldata tokens, address recipient) external nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();

        // Withdraw native tokens
        uint256 nativeAmount = nativeBalances[msg.sender];
        if (nativeAmount > 0) {
            nativeBalances[msg.sender] = 0;
            totalNativeDeposits -= nativeAmount;

            (bool success,) = recipient.call{ value: nativeAmount }("");
            if (!success) revert WithdrawFailed();

            emit Withdrawal(msg.sender, recipient, NATIVE_TOKEN, nativeAmount);
        }

        // Withdraw all specified tokens
        for (uint256 i = 0; i < tokens.length;) {
            address token = tokens[i];
            uint256 tokenAmount = tokenBalances[msg.sender][token];

            if (tokenAmount > 0) {
                tokenBalances[msg.sender][token] = 0;
                totalTokenDeposits[token] -= tokenAmount;

                IERC20(token).safeTransfer(recipient, tokenAmount);

                emit Withdrawal(msg.sender, recipient, token, tokenAmount);
            }

            unchecked {
                i++;
            }
        }
    }

    /* //////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add or remove a token from the whitelist
     * @param token The token address
     * @param supported Whether to support the token
     */
    function setTokenSupport(address token, bool supported) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        supportedTokens[token] = supported;
        emit TokenWhitelistUpdated(token, supported);
    }

    /**
     * @notice Set maximum single deposit amount
     * @param _maxAmount The maximum amount (0 = no limit)
     */
    function setMaxDepositAmount(uint256 _maxAmount) external onlyOwner {
        maxDepositAmount = _maxAmount;
        emit DepositLimitUpdated(_maxAmount);
    }

    /**
     * @notice Set daily deposit limit per user
     * @param _dailyLimit The daily limit (0 = no limit)
     */
    function setDailyDepositLimit(uint256 _dailyLimit) external onlyOwner {
        dailyDepositLimit = _dailyLimit;
        emit DailyLimitUpdated(_dailyLimit);
    }

    /* //////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get native token balance for a stealth address
     * @param stealthAddress The stealth address
     * @return The balance
     */
    function getNativeBalance(address stealthAddress) external view returns (uint256) {
        return nativeBalances[stealthAddress];
    }

    /**
     * @notice Get ERC-20 token balance for a stealth address
     * @param stealthAddress The stealth address
     * @param token The token address
     * @return The balance
     */
    function getTokenBalance(address stealthAddress, address token) external view returns (uint256) {
        return tokenBalances[stealthAddress][token];
    }

    /**
     * @notice Get all balances for a stealth address
     * @param stealthAddress The stealth address
     * @param tokens Array of token addresses to check
     * @return nativeBalance The native token balance
     * @return tokenAmounts The token balances (same order as input)
     */
    function getBalances(address stealthAddress, address[] calldata tokens)
        external
        view
        returns (uint256 nativeBalance, uint256[] memory tokenAmounts)
    {
        nativeBalance = nativeBalances[stealthAddress];
        tokenAmounts = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length;) {
            tokenAmounts[i] = tokenBalances[stealthAddress][tokens[i]];
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Check remaining daily deposit allowance
     * @param user The user address
     * @return remaining The remaining daily allowance
     */
    function getRemainingDailyAllowance(address user) external view returns (uint256 remaining) {
        if (dailyDepositLimit == 0) {
            return type(uint256).max;
        }

        uint256 today = block.timestamp / 1 days;
        uint256 usedToday = dailyDeposits[user][today];

        if (usedToday >= dailyDepositLimit) {
            return 0;
        }

        return dailyDepositLimit - usedToday;
    }

    /* //////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check deposit limits
     * @param user The depositing user
     * @param amount The deposit amount
     */
    function _checkDepositLimits(address user, uint256 amount) internal {
        // Check single deposit limit
        if (maxDepositAmount > 0 && amount > maxDepositAmount) {
            revert DepositLimitExceeded();
        }

        // Check daily limit
        if (dailyDepositLimit > 0) {
            uint256 today = block.timestamp / 1 days;
            uint256 newDailyTotal = dailyDeposits[user][today] + amount;

            if (newDailyTotal > dailyDepositLimit) {
                revert DailyLimitExceeded();
            }

            dailyDeposits[user][today] = newDailyTotal;
        }
    }

    /* //////////////////////////////////////////////////////////////
                           RECEIVE NATIVE
    //////////////////////////////////////////////////////////////*/

    /// @dev Reject direct native token transfers
    receive() external payable {
        revert("Use depositNative");
    }
}
