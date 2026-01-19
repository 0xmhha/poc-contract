// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IPriceOracle
 * @notice Interface for price oracles used by ERC20Paymaster
 * @dev Implementations can use Chainlink, Uniswap TWAP, or other price sources
 */
interface IPriceOracle {
    /**
     * @notice Get the price of a token in native currency (ETH) terms
     * @param token The token address (address(0) for native currency)
     * @return price The price with 18 decimals precision
     *         For ERC-20 tokens: how much native currency (wei) per 1 token (in token decimals)
     *         For native currency (address(0)): always returns 1e18
     */
    function getPrice(address token) external view returns (uint256 price);

    /**
     * @notice Get the price and last update timestamp
     * @param token The token address
     * @return price The price with 18 decimals precision
     * @return updatedAt Timestamp of last price update
     */
    function getPriceWithTimestamp(
        address token
    ) external view returns (uint256 price, uint256 updatedAt);

    /**
     * @notice Check if the oracle has a valid price for a token
     * @param token The token address
     * @return True if a valid price exists
     */
    function hasValidPrice(address token) external view returns (bool);
}
