// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IExecutor, IModule} from "../erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import {IERC7579Account} from "../erc7579-smartaccount/interfaces/IERC7579Account.sol";
import {MODULE_TYPE_EXECUTOR} from "../erc7579-smartaccount/types/Constants.sol";
import {ExecMode} from "../erc7579-smartaccount/types/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SwapExecutor
 * @notice ERC-7579 Executor module for DEX swaps from Smart Account
 * @dev Enables Smart Accounts to perform Uniswap V3 swaps with:
 *      - Token whitelist for security
 *      - Daily and per-swap limits
 *      - Slippage protection
 *      - Single-hop and multi-hop swaps
 *
 * Architecture:
 * ┌─────────────────────────────────────────────────────────────┐
 * │  SmartAccount                                                │
 * │  ├── executeFromExecutor()                                   │
 * │  └── SwapExecutor (this contract)                            │
 * │      ├── Token Whitelist                                     │
 * │      ├── Swap Limits (daily/per-swap)                        │
 * │      └── Uniswap V3 SwapRouter                               │
 * └─────────────────────────────────────────────────────────────┘
 *
 * Use Cases:
 * - DCA (Dollar Cost Averaging) bots via SessionKey
 * - Portfolio rebalancing automation
 * - Automated yield harvesting with token conversion
 * - Gas-efficient batch swaps
 */
contract SwapExecutor is IExecutor {
    // =========================================================================
    // Type Declarations
    // =========================================================================

    /// @notice Account-specific swap configuration
    struct AccountConfig {
        uint256 dailyLimit; // Maximum swap amount per day
        uint256 perSwapLimit; // Maximum single swap amount
        uint256 dailyUsed; // Amount used today
        uint256 lastResetTime; // Last daily reset timestamp
        bool isActive; // Whether module is active
        bool isPaused; // Emergency pause flag
    }

    /// @notice Storage for each smart account
    struct AccountStorage {
        AccountConfig config;
        mapping(address => bool) whitelistedTokens;
        address[] whitelistedTokenList;
    }

    /// @notice Uniswap V3 ExactInputSingleParams
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Uniswap V3 ExactInputParams for multi-hop
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Uniswap V3 SwapRouter address
    address public immutable SWAP_ROUTER;

    /// @notice Uniswap V3 Quoter address
    address public immutable QUOTER;

    /// @notice Account address => AccountStorage
    mapping(address => AccountStorage) internal accountStorage;

    /// @notice 1 day in seconds
    uint256 private constant ONE_DAY = 1 days;

    /// @notice Maximum basis points (100%)
    uint256 private constant MAX_BPS = 10000;

    /// @notice Minimum path length (address + fee + address = 20 + 3 + 20 = 43 bytes)
    uint256 private constant MIN_PATH_LENGTH = 43;

    // =========================================================================
    // Events
    // =========================================================================

    event SwapExecuted(
        address indexed account,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event TokenWhitelisted(address indexed account, address indexed token);
    event TokenRemovedFromWhitelist(address indexed account, address indexed token);
    event LimitsUpdated(address indexed account, uint256 dailyLimit, uint256 perSwapLimit);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    // =========================================================================
    // Errors
    // =========================================================================

    // NotInitialized and AlreadyInitialized are inherited from IERC7579Modules
    error InvalidToken();
    error TokenAlreadyWhitelisted();
    error TokenNotWhitelisted();
    error InvalidLimits();
    error ExceedsPerSwapLimit();
    error ExceedsDailyLimit();
    error DeadlineExpired();
    error InvalidAmount();
    error InvalidPath();
    error SlippageTooHigh();
    error SwapsPaused();
    error SwapFailed();

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @notice Initialize SwapExecutor with Uniswap V3 addresses
     * @param _swapRouter Uniswap V3 SwapRouter address
     * @param _quoter Uniswap V3 Quoter address
     */
    constructor(address _swapRouter, address _quoter) {
        SWAP_ROUTER = _swapRouter;
        QUOTER = _quoter;
    }

    // =========================================================================
    // IModule Implementation
    // =========================================================================

    /// @inheritdoc IModule
    function onInstall(bytes calldata data) external payable override {
        AccountStorage storage store = accountStorage[msg.sender];

        if (store.config.isActive) revert AlreadyInitialized(msg.sender);

        // Initialize with defaults
        store.config.isActive = true;
        store.config.lastResetTime = block.timestamp;

        if (data.length > 0) {
            // Decode: whitelisted tokens, daily limit, per-swap limit
            (address[] memory tokens, uint256 dailyLimit, uint256 perSwapLimit) =
                abi.decode(data, (address[], uint256, uint256));

            // Validate limits
            if (perSwapLimit > dailyLimit) revert InvalidLimits();

            store.config.dailyLimit = dailyLimit;
            store.config.perSwapLimit = perSwapLimit;

            // Add whitelisted tokens
            for (uint256 i = 0; i < tokens.length; i++) {
                if (tokens[i] == address(0)) revert InvalidToken();
                store.whitelistedTokens[tokens[i]] = true;
                store.whitelistedTokenList.push(tokens[i]);
            }
        }
    }

    /// @inheritdoc IModule
    function onUninstall(bytes calldata) external payable override {
        AccountStorage storage store = accountStorage[msg.sender];

        // Clear whitelist
        for (uint256 i = 0; i < store.whitelistedTokenList.length; i++) {
            delete store.whitelistedTokens[store.whitelistedTokenList[i]];
        }
        delete store.whitelistedTokenList;

        // Clear config
        delete store.config;
    }

    /// @inheritdoc IModule
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    /// @inheritdoc IModule
    function isInitialized(address smartAccount) external view override returns (bool) {
        return accountStorage[smartAccount].config.isActive;
    }

    // =========================================================================
    // Token Whitelist Management
    // =========================================================================

    /**
     * @notice Add a token to the whitelist
     * @param token Token address to whitelist
     */
    function addWhitelistedToken(address token) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (!store.config.isActive) revert NotInitialized(msg.sender);
        if (token == address(0)) revert InvalidToken();
        if (store.whitelistedTokens[token]) revert TokenAlreadyWhitelisted();

        store.whitelistedTokens[token] = true;
        store.whitelistedTokenList.push(token);

        emit TokenWhitelisted(msg.sender, token);
    }

    /**
     * @notice Remove a token from the whitelist
     * @param token Token address to remove
     */
    function removeWhitelistedToken(address token) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (!store.config.isActive) revert NotInitialized(msg.sender);
        if (!store.whitelistedTokens[token]) revert TokenNotWhitelisted();

        store.whitelistedTokens[token] = false;
        _removeFromTokenList(msg.sender, token);

        emit TokenRemovedFromWhitelist(msg.sender, token);
    }

    /**
     * @notice Check if a token is whitelisted for an account
     * @param account Smart Account address
     * @param token Token address
     * @return True if whitelisted
     */
    function isTokenWhitelisted(address account, address token) external view returns (bool) {
        return accountStorage[account].whitelistedTokens[token];
    }

    /**
     * @notice Get all whitelisted tokens for an account
     * @param account Smart Account address
     * @return Array of whitelisted token addresses
     */
    function getWhitelistedTokens(address account) external view returns (address[] memory) {
        return accountStorage[account].whitelistedTokenList;
    }

    // =========================================================================
    // Limit Management
    // =========================================================================

    /**
     * @notice Set swap limits
     * @param dailyLimit Maximum daily swap amount
     * @param perSwapLimit Maximum per-swap amount
     */
    function setLimits(uint256 dailyLimit, uint256 perSwapLimit) external {
        AccountStorage storage store = accountStorage[msg.sender];

        if (!store.config.isActive) revert NotInitialized(msg.sender);
        if (perSwapLimit > dailyLimit) revert InvalidLimits();

        store.config.dailyLimit = dailyLimit;
        store.config.perSwapLimit = perSwapLimit;

        emit LimitsUpdated(msg.sender, dailyLimit, perSwapLimit);
    }

    /**
     * @notice Get limits for an account
     * @param account Smart Account address
     * @return dailyLimit Daily limit
     * @return perSwapLimit Per-swap limit
     */
    function getLimits(address account) external view returns (uint256 dailyLimit, uint256 perSwapLimit) {
        AccountConfig storage config = accountStorage[account].config;
        return (config.dailyLimit, config.perSwapLimit);
    }

    /**
     * @notice Get daily usage for an account (resets after 24 hours)
     * @param account Smart Account address
     * @return Current daily usage
     */
    function getDailyUsage(address account) public view returns (uint256) {
        AccountConfig storage config = accountStorage[account].config;

        // Check if day has passed - return 0 if so
        if (block.timestamp >= config.lastResetTime + ONE_DAY) {
            return 0;
        }

        return config.dailyUsed;
    }

    /**
     * @notice Get full account configuration
     * @param account Smart Account address
     */
    function getAccountConfig(address account)
        external
        view
        returns (uint256 dailyLimit, uint256 perSwapLimit, uint256 dailyUsed, uint256 lastResetTime, bool isActive)
    {
        AccountConfig storage config = accountStorage[account].config;
        return (config.dailyLimit, config.perSwapLimit, getDailyUsage(account), config.lastResetTime, config.isActive);
    }

    // =========================================================================
    // Swap Execution - Single Hop
    // =========================================================================

    /**
     * @notice Execute a single-hop swap with exact input
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param fee Pool fee tier
     * @param amountIn Amount of input tokens
     * @param amountOutMinimum Minimum output amount (slippage protection)
     * @param deadline Transaction deadline
     * @return amountOut Amount of output tokens received
     */
    function swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        AccountStorage storage store = accountStorage[msg.sender];

        // Validations
        _validateSwap(store, tokenIn, tokenOut, amountIn, deadline);

        // Update daily usage
        _updateDailyUsage(store, amountIn);

        // Build swap params
        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: msg.sender, // Tokens go back to Smart Account
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0 // No price limit
        });

        // Execute via Smart Account
        amountOut = _executeSwapSingle(msg.sender, params);

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    // =========================================================================
    // Swap Execution - Multi Hop
    // =========================================================================

    /**
     * @notice Execute a multi-hop swap with exact input
     * @param path Encoded swap path (token + fee + token + fee + ...)
     * @param amountIn Amount of input tokens
     * @param amountOutMinimum Minimum output amount (slippage protection)
     * @param deadline Transaction deadline
     * @return amountOut Amount of output tokens received
     */
    function swapExactInput(bytes calldata path, uint256 amountIn, uint256 amountOutMinimum, uint256 deadline)
        external
        returns (uint256 amountOut)
    {
        AccountStorage storage store = accountStorage[msg.sender];

        // Validate path
        if (path.length < MIN_PATH_LENGTH) revert InvalidPath();

        // Extract and validate all tokens in path
        (address tokenIn, address tokenOut) = _validatePath(store, path);

        // Validate swap
        _validateSwapBasic(store, amountIn, deadline);

        // Update daily usage
        _updateDailyUsage(store, amountIn);

        // Build swap params
        ExactInputParams memory params = ExactInputParams({
            path: path,
            recipient: msg.sender,
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum
        });

        // Execute via Smart Account
        amountOut = _executeSwapMulti(msg.sender, params);

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    // =========================================================================
    // Utility Functions
    // =========================================================================

    /**
     * @notice Calculate minimum output with slippage protection
     * @param expectedOutput Expected output amount
     * @param slippageBps Slippage tolerance in basis points (1 bp = 0.01%)
     * @return Minimum acceptable output
     */
    function calculateMinOutput(uint256 expectedOutput, uint256 slippageBps) external pure returns (uint256) {
        if (slippageBps > MAX_BPS) revert SlippageTooHigh();
        return expectedOutput - (expectedOutput * slippageBps / MAX_BPS);
    }

    /**
     * @notice Get the SwapRouter address
     */
    function getSwapRouter() external view returns (address) {
        return SWAP_ROUTER;
    }

    /**
     * @notice Get the Quoter address
     */
    function getQuoter() external view returns (address) {
        return QUOTER;
    }

    // =========================================================================
    // Emergency Functions
    // =========================================================================

    /**
     * @notice Pause all swaps for the caller's account
     */
    function pause() external {
        AccountStorage storage store = accountStorage[msg.sender];
        if (!store.config.isActive) revert NotInitialized(msg.sender);

        store.config.isPaused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause swaps for the caller's account
     */
    function unpause() external {
        AccountStorage storage store = accountStorage[msg.sender];
        if (!store.config.isActive) revert NotInitialized(msg.sender);

        store.config.isPaused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Check if an account is paused
     * @param account Smart Account address
     */
    function isPaused(address account) external view returns (bool) {
        return accountStorage[account].config.isPaused;
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /**
     * @dev Validate swap parameters
     */
    function _validateSwap(AccountStorage storage store, address tokenIn, address tokenOut, uint256 amountIn, uint256 deadline)
        internal
        view
    {
        _validateSwapBasic(store, amountIn, deadline);

        // Validate tokens are whitelisted
        if (!store.whitelistedTokens[tokenIn]) revert TokenNotWhitelisted();
        if (!store.whitelistedTokens[tokenOut]) revert TokenNotWhitelisted();
    }

    /**
     * @dev Basic swap validation (no token checks)
     */
    function _validateSwapBasic(AccountStorage storage store, uint256 amountIn, uint256 deadline) internal view {
        AccountConfig storage config = store.config;

        if (!config.isActive) revert NotInitialized(msg.sender);
        if (config.isPaused) revert SwapsPaused();
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (amountIn == 0) revert InvalidAmount();

        // Check per-swap limit
        if (config.perSwapLimit > 0 && amountIn > config.perSwapLimit) {
            revert ExceedsPerSwapLimit();
        }

        // Check daily limit
        if (config.dailyLimit > 0) {
            uint256 currentUsage = getDailyUsage(msg.sender);
            if (currentUsage + amountIn > config.dailyLimit) {
                revert ExceedsDailyLimit();
            }
        }
    }

    /**
     * @dev Update daily usage counter
     */
    function _updateDailyUsage(AccountStorage storage store, uint256 amount) internal {
        AccountConfig storage config = store.config;

        // Reset if day has passed
        if (block.timestamp >= config.lastResetTime + ONE_DAY) {
            config.dailyUsed = 0;
            config.lastResetTime = block.timestamp;
        }

        config.dailyUsed += amount;
    }

    /**
     * @dev Validate all tokens in path are whitelisted
     * @return tokenIn First token in path
     * @return tokenOut Last token in path
     */
    function _validatePath(AccountStorage storage store, bytes calldata path)
        internal
        view
        returns (address tokenIn, address tokenOut)
    {
        // Path format: token (20 bytes) + fee (3 bytes) + token (20 bytes) + ...
        uint256 numTokens = (path.length - 20) / 23 + 1;

        for (uint256 i = 0; i < numTokens; i++) {
            address token;
            if (i == 0) {
                // First token - extract from calldata
                token = _toAddress(path, 0);
                tokenIn = token;
            } else {
                // Subsequent tokens: offset = 20 (first token) + (i-1) * 23 (previous hops) + 3 (fee)
                uint256 offset = 20 + (i - 1) * 23 + 3;
                token = _toAddress(path, offset);
                if (i == numTokens - 1) {
                    tokenOut = token;
                }
            }

            if (!store.whitelistedTokens[token]) revert TokenNotWhitelisted();
        }
    }

    /**
     * @dev Extract address from bytes at given offset
     */
    function _toAddress(bytes calldata data, uint256 offset) internal pure returns (address) {
        return address(bytes20(data[offset:offset + 20]));
    }

    /**
     * @dev Extract first token address from path (for memory types)
     */
    function _extractFirstToken(bytes memory path) internal pure returns (address token) {
        assembly {
            token := shr(96, mload(add(path, 32)))
        }
    }

    /**
     * @dev Execute single-hop swap via Smart Account
     */
    function _executeSwapSingle(address account, ExactInputSingleParams memory params)
        internal
        returns (uint256 amountOut)
    {
        // First, approve SwapRouter to spend tokens
        bytes memory approveCall =
            abi.encodeWithSelector(IERC20.approve.selector, SWAP_ROUTER, params.amountIn);

        bytes memory approveExecData = abi.encodePacked(params.tokenIn, uint256(0), approveCall);

        ExecMode execMode = _encodeExecMode();
        IERC7579Account(account).executeFromExecutor(execMode, approveExecData);

        // Then execute swap
        bytes memory swapCall = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))",
            params
        );

        bytes memory swapExecData = abi.encodePacked(SWAP_ROUTER, uint256(0), swapCall);

        bytes[] memory results = IERC7579Account(account).executeFromExecutor(execMode, swapExecData);

        if (results.length > 0 && results[0].length >= 32) {
            amountOut = abi.decode(results[0], (uint256));
        }
    }

    /**
     * @dev Execute multi-hop swap via Smart Account
     */
    function _executeSwapMulti(address account, ExactInputParams memory params)
        internal
        returns (uint256 amountOut)
    {
        // Extract first token from path for approval
        address tokenIn = _extractFirstToken(params.path);

        // First, approve SwapRouter to spend tokens
        bytes memory approveCall =
            abi.encodeWithSelector(IERC20.approve.selector, SWAP_ROUTER, params.amountIn);

        bytes memory approveExecData = abi.encodePacked(tokenIn, uint256(0), approveCall);

        ExecMode execMode = _encodeExecMode();
        IERC7579Account(account).executeFromExecutor(execMode, approveExecData);

        // Then execute swap
        bytes memory swapCall = abi.encodeWithSignature(
            "exactInput((bytes,address,uint256,uint256,uint256))",
            params
        );

        bytes memory swapExecData = abi.encodePacked(SWAP_ROUTER, uint256(0), swapCall);

        bytes[] memory results = IERC7579Account(account).executeFromExecutor(execMode, swapExecData);

        if (results.length > 0 && results[0].length >= 32) {
            amountOut = abi.decode(results[0], (uint256));
        }
    }

    /**
     * @dev Remove token from whitelist array
     */
    function _removeFromTokenList(address account, address token) internal {
        AccountStorage storage store = accountStorage[account];
        uint256 length = store.whitelistedTokenList.length;

        for (uint256 i = 0; i < length; i++) {
            if (store.whitelistedTokenList[i] == token) {
                store.whitelistedTokenList[i] = store.whitelistedTokenList[length - 1];
                store.whitelistedTokenList.pop();
                break;
            }
        }
    }

    /**
     * @dev Encode execution mode for single call
     */
    function _encodeExecMode() internal pure returns (ExecMode) {
        return ExecMode.wrap(bytes32(0));
    }
}
