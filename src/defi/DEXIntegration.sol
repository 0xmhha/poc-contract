// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IUniswapV3SwapRouter, IUniswapV3Quoter } from "./interfaces/UniswapV3.sol";

/**
 * @title IwKRC
 * @notice Interface for wrapped native token
 */
interface IwKRC {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title DEXIntegration
 * @notice Integration layer for Uniswap V3 swaps with native token support
 * @dev Provides simplified swap interface with automatic wrapping/unwrapping
 */
contract DEXIntegration is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* //////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error InvalidFee();
    error DeadlineExpired();
    error InsufficientOutput();
    error SwapFailed();
    error InvalidPath();

    /* //////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event SwapExecuted(
        address indexed sender, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event RouterUpdated(address indexed newRouter);
    event QuoterUpdated(address indexed newQuoter);
    event WkrcUpdated(address indexed newWkrc);

    /* //////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Uniswap V3 SwapRouter
    IUniswapV3SwapRouter public swapRouter;

    /// @notice Uniswap V3 Quoter
    IUniswapV3Quoter public quoter;

    /// @notice Wrapped native token (wKRC)
    IwKRC public wkrc;

    /// @notice Native token placeholder
    address public constant NATIVE_TOKEN = address(0);

    /// @notice Default slippage tolerance (0.5% = 50 bps)
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 50;

    /// @notice Maximum slippage tolerance (5% = 500 bps)
    uint256 public constant MAX_SLIPPAGE_BPS = 500;

    /// @notice Valid Uniswap V3 fee tiers
    uint24 public constant FEE_LOWEST = 100; // 0.01%
    uint24 public constant FEE_LOW = 500; // 0.05%
    uint24 public constant FEE_MEDIUM = 3000; // 0.3%
    uint24 public constant FEE_HIGH = 10_000; //1%

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _swapRouter, address _quoter, address _wkrc) Ownable(msg.sender) {
        if (_swapRouter == address(0)) revert ZeroAddress();
        if (_wkrc == address(0)) revert ZeroAddress();

        swapRouter = IUniswapV3SwapRouter(_swapRouter);
        quoter = IUniswapV3Quoter(_quoter);
        wkrc = IwKRC(_wkrc);
    }

    /* //////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update the SwapRouter address
     * @param _router New router address
     */
    function setSwapRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        swapRouter = IUniswapV3SwapRouter(_router);
        emit RouterUpdated(_router);
    }

    /**
     * @notice Update the Quoter address
     * @param _quoter New quoter address
     */
    function setQuoter(address _quoter) external onlyOwner {
        quoter = IUniswapV3Quoter(_quoter);
        emit QuoterUpdated(_quoter);
    }

    /**
     * @notice Update the wKRC address
     * @param _wkrc New wKRC address
     */
    function setWkrc(address _wkrc) external onlyOwner {
        if (_wkrc == address(0)) revert ZeroAddress();
        wkrc = IwKRC(_wkrc);
        emit WkrcUpdated(_wkrc);
    }

    /* //////////////////////////////////////////////////////////////
                           SWAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Swap exact input tokens for output tokens
     * @param tokenIn Input token (address(0) for native)
     * @param tokenOut Output token (address(0) for native)
     * @param amountIn Amount of input tokens
     * @param amountOutMinimum Minimum output amount
     * @param fee Pool fee tier
     * @param deadline Transaction deadline
     * @return amountOut Amount of output tokens received
     */
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint24 fee,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (!_isValidFee(fee)) revert InvalidFee();

        address actualTokenIn = tokenIn;
        address actualTokenOut = tokenOut;

        // Handle native token input
        if (tokenIn == NATIVE_TOKEN) {
            require(msg.value == amountIn, "Invalid native amount");
            wkrc.deposit{ value: amountIn }();
            actualTokenIn = address(wkrc);
            IERC20(actualTokenIn).approve(address(swapRouter), amountIn);
        } else {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            IERC20(tokenIn).approve(address(swapRouter), amountIn);
        }

        // Handle native token output
        bool unwrapOutput = tokenOut == NATIVE_TOKEN;
        if (unwrapOutput) {
            actualTokenOut = address(wkrc);
        }

        // Execute swap
        IUniswapV3SwapRouter.ExactInputSingleParams memory params = IUniswapV3SwapRouter.ExactInputSingleParams({
            tokenIn: actualTokenIn,
            tokenOut: actualTokenOut,
            fee: fee,
            recipient: unwrapOutput ? address(this) : msg.sender,
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);

        if (amountOut < amountOutMinimum) revert InsufficientOutput();

        // Unwrap if output is native token
        if (unwrapOutput) {
            wkrc.withdraw(amountOut);
            (bool success,) = msg.sender.call{ value: amountOut }("");
            require(success, "Native transfer failed");
        }

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /**
     * @notice Swap tokens for exact output amount
     * @param tokenIn Input token (address(0) for native)
     * @param tokenOut Output token (address(0) for native)
     * @param amountOut Exact output amount wanted
     * @param amountInMaximum Maximum input amount
     * @param fee Pool fee tier
     * @param deadline Transaction deadline
     * @return amountIn Amount of input tokens used
     */
    function swapExactOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint24 fee,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountIn) {
        if (amountOut == 0) revert ZeroAmount();
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (!_isValidFee(fee)) revert InvalidFee();

        address actualTokenIn = tokenIn;
        address actualTokenOut = tokenOut;

        // Handle native token input
        if (tokenIn == NATIVE_TOKEN) {
            require(msg.value >= amountInMaximum, "Insufficient native");
            wkrc.deposit{ value: amountInMaximum }();
            actualTokenIn = address(wkrc);
            IERC20(actualTokenIn).approve(address(swapRouter), amountInMaximum);
        } else {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountInMaximum);
            IERC20(tokenIn).approve(address(swapRouter), amountInMaximum);
        }

        // Handle native token output
        bool unwrapOutput = tokenOut == NATIVE_TOKEN;
        if (unwrapOutput) {
            actualTokenOut = address(wkrc);
        }

        // Execute swap
        IUniswapV3SwapRouter.ExactOutputSingleParams memory params = IUniswapV3SwapRouter.ExactOutputSingleParams({
            tokenIn: actualTokenIn,
            tokenOut: actualTokenOut,
            fee: fee,
            recipient: unwrapOutput ? address(this) : msg.sender,
            deadline: deadline,
            amountOut: amountOut,
            amountInMaximum: amountInMaximum,
            sqrtPriceLimitX96: 0
        });

        amountIn = swapRouter.exactOutputSingle(params);

        // Refund excess input
        if (tokenIn == NATIVE_TOKEN) {
            uint256 excess = amountInMaximum - amountIn;
            if (excess > 0) {
                wkrc.withdraw(excess);
                (bool success,) = msg.sender.call{ value: excess }("");
                require(success, "Refund failed");
            }
        } else {
            uint256 excess = amountInMaximum - amountIn;
            if (excess > 0) {
                IERC20(tokenIn).safeTransfer(msg.sender, excess);
            }
        }

        // Unwrap if output is native token
        if (unwrapOutput) {
            wkrc.withdraw(amountOut);
            (bool success,) = msg.sender.call{ value: amountOut }("");
            require(success, "Native transfer failed");
        }

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /**
     * @notice Multi-hop swap with exact input
     * @param path Encoded swap path (tokenIn, fee, tokenMid, fee, tokenOut, ...)
     * @param amountIn Amount of input tokens
     * @param amountOutMinimum Minimum output amount
     * @param deadline Transaction deadline
     * @return amountOut Amount of output tokens received
     */
    function swapExactInputMultihop(bytes calldata path, uint256 amountIn, uint256 amountOutMinimum, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (path.length < 43) revert InvalidPath(); // minimum: token(20) + fee(3) + token(20)

        // Decode first token from path
        address tokenIn;
        assembly {
            tokenIn := shr(96, calldataload(path.offset))
        }

        // Handle native token input
        if (msg.value > 0) {
            require(msg.value == amountIn, "Invalid native amount");
            wkrc.deposit{ value: amountIn }();
            IERC20(address(wkrc)).approve(address(swapRouter), amountIn);
        } else {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            IERC20(tokenIn).approve(address(swapRouter), amountIn);
        }

        IUniswapV3SwapRouter.ExactInputParams memory params = IUniswapV3SwapRouter.ExactInputParams({
            path: path,
            recipient: msg.sender,
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum
        });

        amountOut = swapRouter.exactInput(params);

        emit SwapExecuted(msg.sender, tokenIn, address(0), amountIn, amountOut);
    }

    /* //////////////////////////////////////////////////////////////
                           QUOTE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get quote for exact input swap
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Input amount
     * @param fee Pool fee tier
     * @return amountOut Expected output amount
     */
    function quoteExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee)
        external
        returns (uint256 amountOut)
    {
        if (address(quoter) == address(0)) revert ZeroAddress();

        address actualTokenIn = tokenIn == NATIVE_TOKEN ? address(wkrc) : tokenIn;
        address actualTokenOut = tokenOut == NATIVE_TOKEN ? address(wkrc) : tokenOut;

        return quoter.quoteExactInputSingle(actualTokenIn, actualTokenOut, fee, amountIn, 0);
    }

    /**
     * @notice Get quote for exact output swap
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountOut Desired output amount
     * @param fee Pool fee tier
     * @return amountIn Required input amount
     */
    function quoteExactOutput(address tokenIn, address tokenOut, uint256 amountOut, uint24 fee)
        external
        returns (uint256 amountIn)
    {
        if (address(quoter) == address(0)) revert ZeroAddress();

        address actualTokenIn = tokenIn == NATIVE_TOKEN ? address(wkrc) : tokenIn;
        address actualTokenOut = tokenOut == NATIVE_TOKEN ? address(wkrc) : tokenOut;

        return quoter.quoteExactOutputSingle(actualTokenIn, actualTokenOut, fee, amountOut, 0);
    }

    /* //////////////////////////////////////////////////////////////
                           UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate minimum output with slippage
     * @param expectedOutput Expected output amount
     * @param slippageBps Slippage tolerance in basis points
     * @return Minimum output amount
     */
    function calculateMinOutput(uint256 expectedOutput, uint256 slippageBps) external pure returns (uint256) {
        if (slippageBps > MAX_SLIPPAGE_BPS) slippageBps = MAX_SLIPPAGE_BPS;
        return (expectedOutput * (10_000 - slippageBps)) / 10_000;
    }

    /**
     * @notice Encode a swap path for multi-hop swaps
     * @param tokens Array of token addresses
     * @param fees Array of fee tiers
     * @return path Encoded path
     */
    function encodePath(address[] calldata tokens, uint24[] calldata fees) external pure returns (bytes memory path) {
        if (tokens.length < 2 || tokens.length != fees.length + 1) {
            revert InvalidPath();
        }

        path = abi.encodePacked(tokens[0]);
        for (uint256 i = 0; i < fees.length; i++) {
            path = abi.encodePacked(path, fees[i], tokens[i + 1]);
        }
    }

    /**
     * @notice Check if a fee tier is valid
     * @param fee The fee tier to check
     */
    function _isValidFee(uint24 fee) internal pure returns (bool) {
        return fee == FEE_LOWEST || fee == FEE_LOW || fee == FEE_MEDIUM || fee == FEE_HIGH;
    }

    /* //////////////////////////////////////////////////////////////
                              RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    /// @dev Allow receiving native tokens
    receive() external payable { }
}
