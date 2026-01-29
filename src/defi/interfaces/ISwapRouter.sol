// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IUniswapV3Pool
 * @notice Interface for Uniswap V3 Pool
 */
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function liquidity() external view returns (uint128);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/**
 * @title IUniswapV3Factory
 * @notice Interface for Uniswap V3 Factory
 */
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

/**
 * @title IUniswapV3Quoter
 * @notice Interface for Uniswap V3 Quoter
 */
interface IUniswapV3Quoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);

    function quoteExactOutputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountIn);

    function quoteExactInput(bytes memory path, uint256 amountIn) external returns (uint256 amountOut);

    function quoteExactOutput(bytes memory path, uint256 amountOut) external returns (uint256 amountIn);
}

/**
 * @title IUniswapV3SwapRouter
 * @notice Interface for Uniswap V3 SwapRouter
 */
interface IUniswapV3SwapRouter {
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

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}

/**
 * @title ISwapRouter
 * @notice High-level interface for StableNet SwapRouter
 */
interface ISwapRouter {
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

    /**
     * @notice Execute a single-hop swap with exact input
     * @param params Swap parameters
     * @return amountOut Amount of output tokens received
     */
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    /**
     * @notice Execute a multi-hop swap with exact input
     * @param params Swap parameters including encoded path
     * @return amountOut Amount of output tokens received
     */
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

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
        returns (uint256 amountOut, bytes memory path);

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
        returns (QuoteResult memory result);

    /**
     * @notice Encode a swap path for multi-hop swaps
     * @param tokens Array of token addresses
     * @param fees Array of fee tiers
     * @return path Encoded path
     */
    function encodePath(address[] calldata tokens, uint24[] calldata fees) external pure returns (bytes memory path);

    /**
     * @notice Calculate minimum output with slippage protection
     * @param expectedOutput Expected output amount
     * @param slippageBps Slippage tolerance in basis points
     * @return Minimum output amount
     */
    function calculateMinOutput(uint256 expectedOutput, uint256 slippageBps) external pure returns (uint256);

    /**
     * @notice Check if a pool exists for a token pair and fee
     * @param tokenA First token
     * @param tokenB Second token
     * @param fee Fee tier
     * @return exists Whether the pool exists
     */
    function poolExists(address tokenA, address tokenB, uint24 fee) external view returns (bool exists);

    /**
     * @notice Get all available pools for a token pair
     * @param tokenA First token
     * @param tokenB Second token
     * @return fees Array of available fee tiers
     */
    function getAvailablePools(address tokenA, address tokenB) external view returns (uint24[] memory fees);
}
