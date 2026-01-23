// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {PriceOracle} from "../../src/defi/PriceOracle.sol";
import {IPriceOracle} from "../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";

/**
 * @title MockChainlinkAggregator
 * @notice Mock Chainlink price feed for testing
 */
contract MockChainlinkAggregator {
    int256 public price;
    uint8 public decimals_;
    uint256 public updatedAt;
    string public description_;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decimals_ = _decimals;
        updatedAt = block.timestamp;
        description_ = "Mock Price Feed";
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function description() external view returns (string memory) {
        return description_;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt_,
        uint80 answeredInRound
    ) {
        return (1, price, updatedAt, updatedAt, 1);
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt_,
        uint80 answeredInRound
    ) {
        return (1, price, updatedAt, updatedAt, 1);
    }

    // Test helpers
    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function setPriceAndTimestamp(int256 _price, uint256 _updatedAt) external {
        price = _price;
        updatedAt = _updatedAt;
    }
}

/**
 * @title MockUniswapV3Pool
 * @notice Mock Uniswap V3 pool for TWAP testing
 */
contract MockUniswapV3Pool {
    address public token0;
    address public token1;
    int56[] public tickCumulatives;
    uint160[] public secondsPerLiquidityCumulativeX128s;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
        // Initialize with default values
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = 0;
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
    }

    function observe(uint32[] calldata) external view returns (
        int56[] memory,
        uint160[] memory
    ) {
        return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
    }

    function slot0() external pure returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    ) {
        return (0, 0, 0, 0, 0, 0, true);
    }

    // Test helpers
    function setTickCumulatives(int56 tick0, int56 tick1) external {
        tickCumulatives[0] = tick0;
        tickCumulatives[1] = tick1;
    }
}

/**
 * @title MockERC20
 * @notice Mock ERC20 token for testing
 */
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }
}

/**
 * @title PriceOracleTest
 * @notice Comprehensive tests for PriceOracle contract
 */
contract PriceOracleTest is Test {
    PriceOracle public oracle;
    MockChainlinkAggregator public chainlinkFeed;
    MockChainlinkAggregator public ethUsdFeed;
    MockUniswapV3Pool public uniswapPool;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockERC20 public testToken;

    address public owner;
    address public user;

    // Constants
    uint256 constant ETH_PRICE = 2000e8; // $2000 with 8 decimals (Chainlink standard)
    uint256 constant USDC_PRICE = 1e8;   // $1 with 8 decimals
    uint256 constant TOKEN_PRICE = 100e8; // $100 with 8 decimals

    function setUp() public {
        owner = address(this);
        user = makeAddr("user");

        // Deploy oracle
        oracle = new PriceOracle();

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        testToken = new MockERC20("Test Token", "TEST", 18);

        // Deploy mock Chainlink feeds
        chainlinkFeed = new MockChainlinkAggregator(int256(TOKEN_PRICE), 8);
        ethUsdFeed = new MockChainlinkAggregator(int256(ETH_PRICE), 8);

        // Deploy mock Uniswap pool (testToken/USDC)
        uniswapPool = new MockUniswapV3Pool(address(testToken), address(usdc));
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsOwner() public view {
        assertEq(oracle.owner(), owner);
    }

    function test_Constructor_DefaultStalenessThreshold() public view {
        assertEq(oracle.stalenessThreshold(), 1 hours);
    }

    function test_Constructor_PriceDecimals() public view {
        assertEq(oracle.PRICE_DECIMALS(), 18);
    }

    /*//////////////////////////////////////////////////////////////
                        CHAINLINK FEED TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetChainlinkFeed_Success() public {
        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));

        (,, bool active) = oracle.chainlinkFeeds(address(testToken));
        assertTrue(active);
    }

    function test_SetChainlinkFeed_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit PriceOracle.ChainlinkFeedSet(address(testToken), address(chainlinkFeed));

        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));
    }

    function test_SetChainlinkFeed_RevertsOnZeroAddress() public {
        vm.expectRevert(PriceOracle.ZeroAddress.selector);
        oracle.setChainlinkFeed(address(testToken), address(0));
    }

    function test_SetChainlinkFeed_RevertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert();
        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));
    }

    function test_RemoveChainlinkFeed_Success() public {
        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));
        oracle.removeChainlinkFeed(address(testToken));

        (,, bool active) = oracle.chainlinkFeeds(address(testToken));
        assertFalse(active);
    }

    /*//////////////////////////////////////////////////////////////
                        UNISWAP POOL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetUniswapPool_Success() public {
        oracle.setUniswapPool(address(testToken), address(uniswapPool), 1800, address(0));

        (,,, bool active,,,) = oracle.uniswapPools(address(testToken));
        assertTrue(active);
    }

    function test_SetUniswapPool_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit PriceOracle.UniswapPoolSet(address(testToken), address(uniswapPool), 1800);

        oracle.setUniswapPool(address(testToken), address(uniswapPool), 1800, address(0));
    }

    function test_SetUniswapPool_RevertsOnZeroAddress() public {
        vm.expectRevert(PriceOracle.ZeroAddress.selector);
        oracle.setUniswapPool(address(testToken), address(0), 1800, address(0));
    }

    function test_SetUniswapPool_RevertsOnInvalidToken() public {
        // Token not in pool
        address randomToken = makeAddr("randomToken");
        vm.expectRevert(abi.encodeWithSelector(PriceOracle.InvalidPoolConfiguration.selector, randomToken));
        oracle.setUniswapPool(randomToken, address(uniswapPool), 1800, address(0));
    }

    function test_SetUniswapPool_RevertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert();
        oracle.setUniswapPool(address(testToken), address(uniswapPool), 1800, address(0));
    }

    function test_RemoveUniswapPool_Success() public {
        oracle.setUniswapPool(address(testToken), address(uniswapPool), 1800, address(0));
        oracle.removeUniswapPool(address(testToken));

        (,,, bool active,,,) = oracle.uniswapPools(address(testToken));
        assertFalse(active);
    }

    /*//////////////////////////////////////////////////////////////
                      STALENESS THRESHOLD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetStalenessThreshold_Success() public {
        oracle.setStalenessThreshold(2 hours);
        assertEq(oracle.stalenessThreshold(), 2 hours);
    }

    function test_SetStalenessThreshold_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit PriceOracle.StalenessThresholdUpdated(2 hours);

        oracle.setStalenessThreshold(2 hours);
    }

    function test_SetStalenessThreshold_RevertsOnZero() public {
        vm.expectRevert(PriceOracle.InvalidStalenessThreshold.selector);
        oracle.setStalenessThreshold(0);
    }

    function test_SetStalenessThreshold_RevertsOnTooHigh() public {
        vm.expectRevert(PriceOracle.InvalidStalenessThreshold.selector);
        oracle.setStalenessThreshold(25 hours);
    }

    /*//////////////////////////////////////////////////////////////
                        CHAINLINK PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPrice_Chainlink_Success() public {
        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));

        uint256 price = oracle.getPrice(address(testToken));

        // TOKEN_PRICE is 100e8 (8 decimals), should be scaled to 18 decimals
        assertEq(price, 100e18);
    }

    function test_GetPrice_Chainlink_ScalesDecimals() public {
        // Test with different decimals
        MockChainlinkAggregator feed6 = new MockChainlinkAggregator(1000000, 6); // $1 with 6 decimals
        oracle.setChainlinkFeed(address(usdc), address(feed6));

        uint256 price = oracle.getPrice(address(usdc));
        assertEq(price, 1e18); // Should be scaled to 18 decimals
    }

    function test_GetPrice_Chainlink_RevertsOnStalePrice() public {
        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));

        // Warp to a reasonable timestamp first
        vm.warp(10000);

        // Set price to be stale (2 hours ago)
        uint256 staleTime = block.timestamp - 2 hours;
        chainlinkFeed.setUpdatedAt(staleTime);

        vm.expectRevert(abi.encodeWithSelector(
            PriceOracle.StalePrice.selector,
            address(testToken),
            staleTime
        ));
        oracle.getPrice(address(testToken));
    }

    function test_GetPrice_Chainlink_RevertsOnNegativePrice() public {
        chainlinkFeed.setPrice(-100);
        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));

        vm.expectRevert(abi.encodeWithSelector(PriceOracle.InvalidPrice.selector, address(testToken)));
        oracle.getPrice(address(testToken));
    }

    function test_GetPrice_Chainlink_RevertsOnZeroPrice() public {
        chainlinkFeed.setPrice(0);
        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));

        vm.expectRevert(abi.encodeWithSelector(PriceOracle.InvalidPrice.selector, address(testToken)));
        oracle.getPrice(address(testToken));
    }

    /*//////////////////////////////////////////////////////////////
                          UNISWAP TWAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPrice_UniswapTWAP_Success() public {
        // Setup: tick delta that represents a known price
        // For tick 0, price = 1.0001^0 = 1
        uniswapPool.setTickCumulatives(0, 0);

        oracle.setUniswapPool(address(testToken), address(uniswapPool), 1800, address(0));

        uint256 price = oracle.getPrice(address(testToken));
        // Price should be close to 1e18 for tick 0
        assertGt(price, 0);
    }

    function test_GetPrice_UniswapTWAP_WithQuoteToken() public {
        // Setup Chainlink feed for quote token (USDC) first
        MockChainlinkAggregator usdcFeed = new MockChainlinkAggregator(int256(USDC_PRICE), 8);
        oracle.setChainlinkFeed(address(usdc), address(usdcFeed));

        // Setup Uniswap pool with USDC as quote token
        uniswapPool.setTickCumulatives(0, 0);
        oracle.setUniswapPool(address(testToken), address(uniswapPool), 1800, address(usdc));

        uint256 price = oracle.getPrice(address(testToken));
        assertGt(price, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        NO PRICE FEED TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPrice_RevertsOnNoPriceFeed() public {
        vm.expectRevert(abi.encodeWithSelector(PriceOracle.NoPriceFeed.selector, address(testToken)));
        oracle.getPrice(address(testToken));
    }

    /*//////////////////////////////////////////////////////////////
                      IPRICE ORACLE INTERFACE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPriceWithTimestamp_Success() public {
        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));

        (uint256 price, uint256 updatedAt) = oracle.getPriceWithTimestamp(address(testToken));

        assertEq(price, 100e18);
        assertEq(updatedAt, block.timestamp);
    }

    function test_HasValidPrice_ReturnsTrue() public {
        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));

        bool isValid = oracle.hasValidPrice(address(testToken));
        assertTrue(isValid);
    }

    function test_HasValidPrice_ReturnsFalse_NoFeed() public {
        bool isValid = oracle.hasValidPrice(address(testToken));
        assertFalse(isValid);
    }

    function test_HasValidPrice_ReturnsFalse_StalePrice() public {
        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));

        // Warp to a reasonable timestamp first
        vm.warp(10000);
        chainlinkFeed.setUpdatedAt(block.timestamp - 2 hours);

        bool isValid = oracle.hasValidPrice(address(testToken));
        assertFalse(isValid);
    }

    /*//////////////////////////////////////////////////////////////
                         UTILITY FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HasPriceFeed_ReturnsTrue_Chainlink() public {
        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));

        assertTrue(oracle.hasPriceFeed(address(testToken)));
    }

    function test_HasPriceFeed_ReturnsTrue_Uniswap() public {
        oracle.setUniswapPool(address(testToken), address(uniswapPool), 1800, address(0));

        assertTrue(oracle.hasPriceFeed(address(testToken)));
    }

    function test_HasPriceFeed_ReturnsFalse() public {
        assertFalse(oracle.hasPriceFeed(address(testToken)));
    }

    function test_GetPriceSource_Chainlink() public {
        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));

        string memory source = oracle.getPriceSource(address(testToken));
        assertEq(source, "Chainlink");
    }

    function test_GetPriceSource_UniswapTWAP() public {
        oracle.setUniswapPool(address(testToken), address(uniswapPool), 1800, address(0));

        string memory source = oracle.getPriceSource(address(testToken));
        assertEq(source, "UniswapV3TWAP");
    }

    function test_GetPriceSource_None() public {
        string memory source = oracle.getPriceSource(address(testToken));
        assertEq(source, "None");
    }

    function test_ConvertAmount_Success() public {
        // Setup feeds
        MockChainlinkAggregator tokenFeed = new MockChainlinkAggregator(int256(100e8), 8); // $100
        MockChainlinkAggregator usdcFeed = new MockChainlinkAggregator(int256(1e8), 8);    // $1

        oracle.setChainlinkFeed(address(testToken), address(tokenFeed));
        oracle.setChainlinkFeed(address(usdc), address(usdcFeed));

        // Convert 1 testToken ($100) to USDC ($1)
        uint256 converted = oracle.convertAmount(address(testToken), address(usdc), 1e18);

        // 1 testToken = 100 USDC
        assertEq(converted, 100e18);
    }

    function test_ConvertAmount_ZeroAmount() public {
        uint256 converted = oracle.convertAmount(address(testToken), address(usdc), 0);
        assertEq(converted, 0);
    }

    function test_ConvertAmount_SameToken() public {
        uint256 amount = 100e18;
        uint256 converted = oracle.convertAmount(address(testToken), address(testToken), amount);
        assertEq(converted, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          PRIORITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPrice_ChainlinkPriorityOverUniswap() public {
        // Setup both Chainlink and Uniswap for same token
        oracle.setChainlinkFeed(address(testToken), address(chainlinkFeed));
        oracle.setUniswapPool(address(testToken), address(uniswapPool), 1800, address(0));

        // Get price data to check source
        PriceOracle.PriceData memory data = oracle.getPriceData(address(testToken));

        // Should use Chainlink (higher priority)
        assertEq(data.source, "Chainlink");
    }

    /*//////////////////////////////////////////////////////////////
                          NATIVE TOKEN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPrice_NativeToken() public {
        oracle.setChainlinkFeed(address(0), address(ethUsdFeed));

        uint256 price = oracle.getPrice(address(0));
        assertEq(price, 2000e18); // $2000 scaled to 18 decimals
    }
}
