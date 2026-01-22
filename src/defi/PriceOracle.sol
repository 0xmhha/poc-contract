// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IUniswapV3Pool} from "./interfaces/UniswapV3.sol";

/**
 * @title Chainlink Aggregator V3 Interface
 * @notice Minimal interface for Chainlink price feeds
 */
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

/**
 * @title PriceOracle
 * @notice Unified price oracle supporting Chainlink feeds and Uniswap V3 TWAP
 * @dev Provides price data for tokens with configurable data sources
 */
contract PriceOracle is Ownable {
    using SafeCast for int256;
    using SafeCast for int56;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NoPriceFeed(address token);
    error StalePrice(address token, uint256 updatedAt);
    error InvalidPrice(address token);
    error ZeroAddress();
    error InvalidStalenessThreshold();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ChainlinkFeedSet(address indexed token, address indexed feed);
    event UniswapPoolSet(address indexed token, address indexed pool, uint32 twapPeriod);
    event StalenessThresholdUpdated(uint256 newThreshold);

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct ChainlinkConfig {
        AggregatorV3Interface feed;
        uint8 decimals;
        bool active;
    }

    struct UniswapConfig {
        IUniswapV3Pool pool;
        uint32 twapPeriod;
        bool isToken0;
        bool active;
    }

    struct PriceData {
        uint256 price;
        uint8 decimals;
        uint256 updatedAt;
        string source;
    }

    /*//////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Chainlink price feed configurations
    mapping(address => ChainlinkConfig) public chainlinkFeeds;

    /// @notice Uniswap V3 pool configurations for TWAP
    mapping(address => UniswapConfig) public uniswapPools;

    /// @notice Maximum allowed staleness for price data (default: 1 hour)
    uint256 public stalenessThreshold = 1 hours;

    /// @notice Native token placeholder address
    address public constant NATIVE_TOKEN = address(0);

    /// @notice Standard price decimals (18 for consistency)
    uint8 public constant PRICE_DECIMALS = 18;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() Ownable(msg.sender) {}

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set Chainlink price feed for a token
     * @param token The token address (address(0) for native token)
     * @param feed The Chainlink aggregator address
     */
    function setChainlinkFeed(address token, address feed) external onlyOwner {
        if (feed == address(0)) revert ZeroAddress();

        AggregatorV3Interface aggregator = AggregatorV3Interface(feed);
        uint8 decimals = aggregator.decimals();

        chainlinkFeeds[token] = ChainlinkConfig({
            feed: aggregator,
            decimals: decimals,
            active: true
        });

        emit ChainlinkFeedSet(token, feed);
    }

    /**
     * @notice Set Uniswap V3 pool for TWAP price
     * @param token The token address to get price for
     * @param pool The Uniswap V3 pool address
     * @param twapPeriod The TWAP period in seconds
     */
    function setUniswapPool(
        address token,
        address pool,
        uint32 twapPeriod
    ) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();

        IUniswapV3Pool uniPool = IUniswapV3Pool(pool);
        bool isToken0 = uniPool.token0() == token;

        uniswapPools[token] = UniswapConfig({
            pool: uniPool,
            twapPeriod: twapPeriod,
            isToken0: isToken0,
            active: true
        });

        emit UniswapPoolSet(token, pool, twapPeriod);
    }

    /**
     * @notice Remove Chainlink feed for a token
     * @param token The token address
     */
    function removeChainlinkFeed(address token) external onlyOwner {
        delete chainlinkFeeds[token];
    }

    /**
     * @notice Remove Uniswap pool for a token
     * @param token The token address
     */
    function removeUniswapPool(address token) external onlyOwner {
        delete uniswapPools[token];
    }

    /**
     * @notice Update the staleness threshold
     * @param newThreshold The new threshold in seconds
     */
    function setStalenessThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold == 0 || newThreshold > 24 hours) {
            revert InvalidStalenessThreshold();
        }
        stalenessThreshold = newThreshold;
        emit StalenessThresholdUpdated(newThreshold);
    }

    /*//////////////////////////////////////////////////////////////
                           PRICE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the price of a token in USD (scaled to PRICE_DECIMALS)
     * @param token The token address (address(0) for native token)
     * @return price The price scaled to PRICE_DECIMALS
     */
    function getPrice(address token) external view returns (uint256 price) {
        PriceData memory data = getPriceData(token);
        return data.price;
    }

    /**
     * @notice Get detailed price data for a token
     * @param token The token address
     * @return data The price data including source and timestamp
     */
    function getPriceData(address token) public view returns (PriceData memory data) {
        // Try Chainlink first
        ChainlinkConfig memory clConfig = chainlinkFeeds[token];
        if (clConfig.active) {
            return _getChainlinkPrice(token, clConfig);
        }

        // Fallback to Uniswap TWAP
        UniswapConfig memory uniConfig = uniswapPools[token];
        if (uniConfig.active) {
            return _getUniswapTwap(token, uniConfig);
        }

        revert NoPriceFeed(token);
    }

    /**
     * @notice Get price from Chainlink
     * @param token The token address
     * @param config The Chainlink configuration
     */
    function _getChainlinkPrice(
        address token,
        ChainlinkConfig memory config
    ) internal view returns (PriceData memory) {
        (
            ,
            int256 answer,
            ,
            uint256 updatedAt,
        ) = config.feed.latestRoundData();

        // Validate price
        if (answer <= 0) revert InvalidPrice(token);

        // Check staleness
        if (block.timestamp - updatedAt > stalenessThreshold) {
            revert StalePrice(token, updatedAt);
        }

        // Scale to PRICE_DECIMALS
        uint256 price;
        uint256 answerUint = answer.toUint256();
        if (config.decimals < PRICE_DECIMALS) {
            price = answerUint * (10 ** (PRICE_DECIMALS - config.decimals));
        } else if (config.decimals > PRICE_DECIMALS) {
            price = answerUint / (10 ** (config.decimals - PRICE_DECIMALS));
        } else {
            price = answerUint;
        }

        return PriceData({
            price: price,
            decimals: PRICE_DECIMALS,
            updatedAt: updatedAt,
            source: "Chainlink"
        });
    }

    /**
     * @notice Get TWAP price from Uniswap V3
     * @param token The token address
     * @param config The Uniswap configuration
     */
    function _getUniswapTwap(
        address token,
        UniswapConfig memory config
    ) internal view returns (PriceData memory) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = config.twapPeriod;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = config.pool.observe(secondsAgos);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int56 twapPeriodInt56 = int56(int32(config.twapPeriod));
        int256 meanTickInt256 = int256(tickCumulativesDelta / twapPeriodInt56);
        // Validate int24 range before casting
        require(meanTickInt256 >= type(int24).min && meanTickInt256 <= type(int24).max, "Tick overflow");
        // Casting to int24 is safe: range validated by require above
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 arithmeticMeanTick = int24(meanTickInt256);

        // Round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % twapPeriodInt56 != 0)) {
            arithmeticMeanTick--;
        }

        // Convert tick to price
        // price = 1.0001^tick
        uint256 price = _tickToPrice(arithmeticMeanTick, config.isToken0);

        return PriceData({
            price: price,
            decimals: PRICE_DECIMALS,
            updatedAt: block.timestamp,
            source: "UniswapV3TWAP"
        });
    }

    /**
     * @notice Convert a Uniswap V3 tick to a price
     * @param tick The tick value
     * @param isToken0 Whether the token is token0 in the pool
     */
    function _tickToPrice(int24 tick, bool isToken0) internal pure returns (uint256) {
        // sqrtPriceX96 = sqrt(1.0001^tick) * 2^96
        // price = (sqrtPriceX96 / 2^96)^2 = sqrtPriceX96^2 / 2^192

        uint160 sqrtPriceX96 = _getSqrtRatioAtTick(tick);
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);

        // Scale to PRICE_DECIMALS
        if (isToken0) {
            // price = token1/token0, so we need inverse
            return (uint256(1) << 192) * (10 ** PRICE_DECIMALS) / priceX192;
        } else {
            // price = token0/token1
            return priceX192 * (10 ** PRICE_DECIMALS) / (uint256(1) << 192);
        }
    }

    /**
     * @notice Calculate sqrtPriceX96 from tick
     * @dev Simplified implementation for PoC
     */
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        // Compute absolute value safely
        int256 tickInt256 = int256(tick);
        uint256 absTick = (tick < 0 ? -tickInt256 : tickInt256).toUint256();
        require(absTick <= uint256(int256(type(int24).max)), "T");

        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        return uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    /*//////////////////////////////////////////////////////////////
                           UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Convert an amount from one token to another using prices
     * @param fromToken The source token
     * @param toToken The destination token
     * @param amount The amount to convert
     * @return The converted amount
     */
    function convertAmount(
        address fromToken,
        address toToken,
        uint256 amount
    ) external view returns (uint256) {
        if (amount == 0) return 0;
        if (fromToken == toToken) return amount;

        uint256 fromPrice = this.getPrice(fromToken);
        uint256 toPrice = this.getPrice(toToken);

        return (amount * fromPrice) / toPrice;
    }

    /**
     * @notice Check if a price feed is available for a token
     * @param token The token address
     * @return True if a price feed exists
     */
    function hasPriceFeed(address token) external view returns (bool) {
        return chainlinkFeeds[token].active || uniswapPools[token].active;
    }

    /**
     * @notice Get the price source for a token
     * @param token The token address
     * @return source The price source ("Chainlink", "UniswapV3TWAP", or "None")
     */
    function getPriceSource(address token) external view returns (string memory source) {
        if (chainlinkFeeds[token].active) return "Chainlink";
        if (uniswapPools[token].active) return "UniswapV3TWAP";
        return "None";
    }
}
