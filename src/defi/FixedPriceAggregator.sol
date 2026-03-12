// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title FixedPriceAggregator
 * @notice Chainlink AggregatorV3Interface compatible feed that returns a fixed price.
 *         Always returns `block.timestamp` as `updatedAt` so the price never goes stale.
 *         Intended for PoC / testnet use only — NOT for production.
 *
 * @dev Deploy with the desired fixed price and Chainlink-style decimals.
 *      The PriceOracle will scale the answer to 18 decimals automatically.
 *
 * Example — 1 USDC = 1500 KRWC:
 *   price  = 1500 * 1e8 = 150_000_000_000  (8 decimals)
 *   decimals = 8
 */
contract FixedPriceAggregator {
    int256 public immutable fixedPrice;
    uint8 public immutable priceDecimals;

    constructor(int256 _price, uint8 _decimals) {
        require(_price > 0, "Price must be positive");
        fixedPrice = _price;
        priceDecimals = _decimals;
    }

    function decimals() external view returns (uint8) {
        return priceDecimals;
    }

    function description() external pure returns (string memory) {
        return "Fixed Price Feed (PoC)";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, fixedPrice, block.timestamp, block.timestamp, 1);
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, fixedPrice, block.timestamp, block.timestamp, 1);
    }
}
