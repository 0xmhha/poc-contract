// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ISignatureTransfer } from "../permit2/interfaces/ISignatureTransfer.sol";
import { IUniswapV3SwapRouter, IUniswapV3Quoter, IUniswapV3Factory } from "./interfaces/ISwapRouter.sol";

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
 * @title SwapRouter
 * @notice Advanced DEX router with Uniswap V3 integration, Permit2 support, and optimal path finding
 * @dev Provides simplified swap interface with:
 *      - Single-hop and multi-hop swaps
 *      - Automatic native token wrapping/unwrapping
 *      - Permit2 integration for gasless approvals
 *      - Optimal fee tier discovery
 *      - Best path routing across fee tiers
 */
contract SwapRouter is Ownable, ReentrancyGuard {
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
    error NoLiquidityFound();
    error PermitExpired();

    /* //////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event SwapExecuted(
        address indexed sender, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event SwapWithPermit(
        address indexed sender, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event RouterUpdated(address indexed newRouter);
    event QuoterUpdated(address indexed newQuoter);
    event FactoryUpdated(address indexed newFactory);
    event Permit2Updated(address indexed newPermit2);

    /* //////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Uniswap V3 SwapRouter
    IUniswapV3SwapRouter public swapRouter;

    /// @notice Uniswap V3 Quoter
    IUniswapV3Quoter public quoter;

    /// @notice Uniswap V3 Factory
    IUniswapV3Factory public factory;

    /// @notice Permit2 contract
    ISignatureTransfer public permit2;

    /// @notice Wrapped native token (wKRC)
    IwKRC public wkrc;

    /// @notice Native token placeholder
    address public constant NATIVE_TOKEN = address(0);

    /// @notice Valid Uniswap V3 fee tiers
    uint24 public constant FEE_LOWEST = 100; // 0.01%
    uint24 public constant FEE_LOW = 500; // 0.05%
    uint24 public constant FEE_MEDIUM = 3000; // 0.3%
    uint24 public constant FEE_HIGH = 10_000; // 1%

    /// @notice All fee tiers for iteration
    uint24[4] public feeTiers = [FEE_LOWEST, FEE_LOW, FEE_MEDIUM, FEE_HIGH];

    /// @notice Maximum slippage tolerance (5% = 500 bps)
    uint256 public constant MAX_SLIPPAGE_BPS = 500;

    /* //////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Parameters for exactInputSingle
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Parameters for exactInput (multi-hop)
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Quote result with path
    struct QuoteResult {
        uint256 amountOut;
        bytes path;
        uint24[] fees;
    }

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _swapRouter, address _quoter, address _factory, address _permit2, address _wkrc)
        Ownable(msg.sender)
    {
        if (_swapRouter == address(0)) revert ZeroAddress();
        if (_wkrc == address(0)) revert ZeroAddress();

        swapRouter = IUniswapV3SwapRouter(_swapRouter);
        quoter = IUniswapV3Quoter(_quoter);
        factory = IUniswapV3Factory(_factory);
        permit2 = ISignatureTransfer(_permit2);
        wkrc = IwKRC(_wkrc);
    }

    /* //////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setSwapRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        swapRouter = IUniswapV3SwapRouter(_router);
        emit RouterUpdated(_router);
    }

    function setQuoter(address _quoter) external onlyOwner {
        quoter = IUniswapV3Quoter(_quoter);
        emit QuoterUpdated(_quoter);
    }

    function setFactory(address _factory) external onlyOwner {
        factory = IUniswapV3Factory(_factory);
        emit FactoryUpdated(_factory);
    }

    function setPermit2(address _permit2) external onlyOwner {
        permit2 = ISignatureTransfer(_permit2);
        emit Permit2Updated(_permit2);
    }

    /* //////////////////////////////////////////////////////////////
                           SWAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute a single-hop swap with exact input
     * @param params Swap parameters
     * @return amountOut Amount of output tokens received
     */
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        _validateSwapParams(params.amountIn, params.deadline, params.fee);

        address actualTokenIn = params.tokenIn;
        address actualTokenOut = params.tokenOut;

        // Handle native token input
        if (params.tokenIn == NATIVE_TOKEN) {
            require(msg.value == params.amountIn, "Invalid native amount");
            wkrc.deposit{ value: params.amountIn }();
            actualTokenIn = address(wkrc);
            IERC20(actualTokenIn).approve(address(swapRouter), params.amountIn);
        } else {
            IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
            IERC20(params.tokenIn).approve(address(swapRouter), params.amountIn);
        }

        // Handle native token output
        bool unwrapOutput = params.tokenOut == NATIVE_TOKEN;
        if (unwrapOutput) {
            actualTokenOut = address(wkrc);
        }

        // Execute swap
        IUniswapV3SwapRouter.ExactInputSingleParams memory routerParams = IUniswapV3SwapRouter.ExactInputSingleParams({
            tokenIn: actualTokenIn,
            tokenOut: actualTokenOut,
            fee: params.fee,
            recipient: unwrapOutput ? address(this) : params.recipient,
            deadline: params.deadline,
            amountIn: params.amountIn,
            amountOutMinimum: params.amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(routerParams);

        if (amountOut < params.amountOutMinimum) revert InsufficientOutput();

        // Unwrap if output is native token
        if (unwrapOutput) {
            wkrc.withdraw(amountOut);
            (bool success,) = params.recipient.call{ value: amountOut }("");
            require(success, "Native transfer failed");
        }

        emit SwapExecuted(msg.sender, params.tokenIn, params.tokenOut, params.amountIn, amountOut);
    }

    /**
     * @notice Execute a multi-hop swap with exact input
     * @param params Swap parameters including encoded path
     * @return amountOut Amount of output tokens received
     */
    function exactInput(ExactInputParams calldata params) external payable nonReentrant returns (uint256 amountOut) {
        if (params.amountIn == 0) revert ZeroAmount();
        if (params.deadline < block.timestamp) revert DeadlineExpired();
        if (params.path.length < 43) revert InvalidPath();

        // Decode first token from path (first 20 bytes)
        address tokenIn = _decodeFirstToken(params.path);

        // Handle native token input
        if (msg.value > 0) {
            require(msg.value == params.amountIn, "Invalid native amount");
            wkrc.deposit{ value: params.amountIn }();
            IERC20(address(wkrc)).approve(address(swapRouter), params.amountIn);
        } else {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
            IERC20(tokenIn).approve(address(swapRouter), params.amountIn);
        }

        IUniswapV3SwapRouter.ExactInputParams memory routerParams = IUniswapV3SwapRouter.ExactInputParams({
            path: params.path,
            recipient: params.recipient,
            deadline: params.deadline,
            amountIn: params.amountIn,
            amountOutMinimum: params.amountOutMinimum
        });

        amountOut = swapRouter.exactInput(routerParams);

        emit SwapExecuted(msg.sender, tokenIn, address(0), params.amountIn, amountOut);
    }

    /* //////////////////////////////////////////////////////////////
                        PERMIT2 SWAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute a swap using Permit2 for gasless approval
     * @param params Swap parameters
     * @param permitData Permit2 signature data
     * @param signature EIP-712 signature
     * @return amountOut Amount of output tokens received
     */
    function exactInputSingleWithPermit(
        ExactInputSingleParams calldata params,
        ISignatureTransfer.PermitTransferFrom calldata permitData,
        bytes calldata signature
    ) external nonReentrant returns (uint256 amountOut) {
        _validateSwapParams(params.amountIn, params.deadline, params.fee);

        if (params.tokenIn == NATIVE_TOKEN) revert InvalidPath(); // Native token doesn't need permit

        // Transfer tokens using Permit2
        permit2.permitTransferFrom(
            permitData,
            ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: params.amountIn }),
            msg.sender,
            signature
        );

        // Approve router
        IERC20(params.tokenIn).approve(address(swapRouter), params.amountIn);

        // Handle native token output
        address actualTokenOut = params.tokenOut;
        bool unwrapOutput = params.tokenOut == NATIVE_TOKEN;
        if (unwrapOutput) {
            actualTokenOut = address(wkrc);
        }

        // Execute swap
        IUniswapV3SwapRouter.ExactInputSingleParams memory routerParams = IUniswapV3SwapRouter.ExactInputSingleParams({
            tokenIn: params.tokenIn,
            tokenOut: actualTokenOut,
            fee: params.fee,
            recipient: unwrapOutput ? address(this) : params.recipient,
            deadline: params.deadline,
            amountIn: params.amountIn,
            amountOutMinimum: params.amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(routerParams);

        if (amountOut < params.amountOutMinimum) revert InsufficientOutput();

        // Unwrap if output is native token
        if (unwrapOutput) {
            wkrc.withdraw(amountOut);
            (bool success,) = params.recipient.call{ value: amountOut }("");
            require(success, "Native transfer failed");
        }

        emit SwapWithPermit(msg.sender, params.tokenIn, params.tokenOut, params.amountIn, amountOut);
    }

    /* //////////////////////////////////////////////////////////////
                           QUOTE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the best quote for a swap, finding optimal fee tier
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input tokens
     * @return amountOut Best output amount
     * @return path Encoded path for the swap
     */
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (uint256 amountOut, bytes memory path)
    {
        if (address(quoter) == address(0)) revert ZeroAddress();

        address actualTokenIn = tokenIn == NATIVE_TOKEN ? address(wkrc) : tokenIn;
        address actualTokenOut = tokenOut == NATIVE_TOKEN ? address(wkrc) : tokenOut;

        uint256 bestAmountOut = 0;
        uint24 bestFee = 0;

        // Try each fee tier and find the best quote
        for (uint256 i = 0; i < feeTiers.length; i++) {
            uint24 fee = feeTiers[i];

            // Check if pool exists
            if (address(factory) != address(0)) {
                address pool = factory.getPool(actualTokenIn, actualTokenOut, fee);
                if (pool == address(0)) continue;
            }

            try quoter.quoteExactInputSingle(actualTokenIn, actualTokenOut, fee, amountIn, 0) returns (
                uint256 quotedAmount
            ) {
                if (quotedAmount > bestAmountOut) {
                    bestAmountOut = quotedAmount;
                    bestFee = fee;
                }
            } catch {
                // Pool doesn't exist or has no liquidity, continue
            }
        }

        if (bestAmountOut == 0) revert NoLiquidityFound();

        amountOut = bestAmountOut;
        path = abi.encodePacked(actualTokenIn, bestFee, actualTokenOut);
    }

    /**
     * @notice Get quote with multi-hop path finding
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input tokens
     * @param intermediateToken Optional intermediate token for multi-hop
     * @return result Quote result with best path
     */
    function getQuoteMultihop(address tokenIn, address tokenOut, uint256 amountIn, address intermediateToken)
        external
        returns (QuoteResult memory result)
    {
        if (address(quoter) == address(0)) revert ZeroAddress();

        address actualTokenIn = tokenIn == NATIVE_TOKEN ? address(wkrc) : tokenIn;
        address actualTokenOut = tokenOut == NATIVE_TOKEN ? address(wkrc) : tokenOut;
        address actualIntermediate =
            intermediateToken == NATIVE_TOKEN ? address(wkrc) : intermediateToken;

        // Try direct swap first
        (uint256 directAmount, bytes memory directPath) = this.getQuote(tokenIn, tokenOut, amountIn);

        // If no intermediate token specified, return direct quote
        if (intermediateToken == address(0)) {
            result.amountOut = directAmount;
            result.path = directPath;
            result.fees = new uint24[](1);
            // Decode fee from path
            assembly {
                let feePos := add(add(directPath, 32), 20) // skip length + tokenIn
                mstore(add(result, 96), shr(232, mload(feePos))) // store in fees array
            }
            return result;
        }

        // Try multi-hop through intermediate token
        uint256 bestMultihopAmount = 0;
        uint24 bestFee1 = 0;
        uint24 bestFee2 = 0;

        for (uint256 i = 0; i < feeTiers.length; i++) {
            for (uint256 j = 0; j < feeTiers.length; j++) {
                try quoter.quoteExactInputSingle(actualTokenIn, actualIntermediate, feeTiers[i], amountIn, 0) returns (
                    uint256 intermediateAmount
                ) {
                    try quoter.quoteExactInputSingle(
                        actualIntermediate, actualTokenOut, feeTiers[j], intermediateAmount, 0
                    ) returns (uint256 finalAmount) {
                        if (finalAmount > bestMultihopAmount) {
                            bestMultihopAmount = finalAmount;
                            bestFee1 = feeTiers[i];
                            bestFee2 = feeTiers[j];
                        }
                    } catch { }
                } catch { }
            }
        }

        // Compare direct vs multi-hop
        if (directAmount >= bestMultihopAmount) {
            result.amountOut = directAmount;
            result.path = directPath;
            result.fees = new uint24[](1);
            assembly {
                let feePos := add(add(directPath, 32), 20)
                mstore(add(result, 96), shr(232, mload(feePos)))
            }
        } else {
            result.amountOut = bestMultihopAmount;
            result.path = abi.encodePacked(actualTokenIn, bestFee1, actualIntermediate, bestFee2, actualTokenOut);
            result.fees = new uint24[](2);
            result.fees[0] = bestFee1;
            result.fees[1] = bestFee2;
        }
    }

    /**
     * @notice Get quote for exact input swap (simple version)
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Input amount
     * @param fee Pool fee tier
     * @return amountOut Expected output amount
     */
    function quoteExactInputSingle(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee)
        external
        returns (uint256 amountOut)
    {
        if (address(quoter) == address(0)) revert ZeroAddress();

        address actualTokenIn = tokenIn == NATIVE_TOKEN ? address(wkrc) : tokenIn;
        address actualTokenOut = tokenOut == NATIVE_TOKEN ? address(wkrc) : tokenOut;

        return quoter.quoteExactInputSingle(actualTokenIn, actualTokenOut, fee, amountIn, 0);
    }

    /* //////////////////////////////////////////////////////////////
                           UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
     * @notice Calculate minimum output with slippage protection
     * @param expectedOutput Expected output amount
     * @param slippageBps Slippage tolerance in basis points
     * @return Minimum output amount
     */
    function calculateMinOutput(uint256 expectedOutput, uint256 slippageBps) external pure returns (uint256) {
        if (slippageBps > MAX_SLIPPAGE_BPS) slippageBps = MAX_SLIPPAGE_BPS;
        return (expectedOutput * (10_000 - slippageBps)) / 10_000;
    }

    /**
     * @notice Check if a pool exists for a token pair and fee
     * @param tokenA First token
     * @param tokenB Second token
     * @param fee Fee tier
     * @return exists Whether the pool exists
     */
    function poolExists(address tokenA, address tokenB, uint24 fee) external view returns (bool exists) {
        if (address(factory) == address(0)) return false;

        address actualA = tokenA == NATIVE_TOKEN ? address(wkrc) : tokenA;
        address actualB = tokenB == NATIVE_TOKEN ? address(wkrc) : tokenB;

        address pool = factory.getPool(actualA, actualB, fee);
        return pool != address(0);
    }

    /**
     * @notice Get all available pools for a token pair
     * @param tokenA First token
     * @param tokenB Second token
     * @return fees Array of available fee tiers
     */
    function getAvailablePools(address tokenA, address tokenB) external view returns (uint24[] memory fees) {
        if (address(factory) == address(0)) return new uint24[](0);

        address actualA = tokenA == NATIVE_TOKEN ? address(wkrc) : tokenA;
        address actualB = tokenB == NATIVE_TOKEN ? address(wkrc) : tokenB;

        uint24[] memory tempFees = new uint24[](4);
        uint256 count = 0;

        for (uint256 i = 0; i < feeTiers.length; i++) {
            address pool = factory.getPool(actualA, actualB, feeTiers[i]);
            if (pool != address(0)) {
                tempFees[count] = feeTiers[i];
                count++;
            }
        }

        fees = new uint24[](count);
        for (uint256 i = 0; i < count; i++) {
            fees[i] = tempFees[i];
        }
    }

    /* //////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _validateSwapParams(uint256 amountIn, uint256 deadline, uint24 fee) internal view {
        if (amountIn == 0) revert ZeroAmount();
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (!_isValidFee(fee)) revert InvalidFee();
    }

    function _isValidFee(uint24 fee) internal pure returns (bool) {
        return fee == FEE_LOWEST || fee == FEE_LOW || fee == FEE_MEDIUM || fee == FEE_HIGH;
    }

    function _decodeFirstToken(bytes calldata path) internal pure returns (address token) {
        require(path.length >= 20, "Invalid path");
        assembly {
            token := shr(96, calldataload(path.offset))
        }
    }

    /* //////////////////////////////////////////////////////////////
                              RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable { }
}
