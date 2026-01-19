// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceOracle} from "../../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";

/**
 * @title MockPriceOracle
 * @notice Mock price oracle for testing
 */
contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public prices;
    mapping(address => uint256) public timestamps;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
        timestamps[token] = block.timestamp;
    }

    function setPriceWithTimestamp(address token, uint256 price, uint256 timestamp) external {
        prices[token] = price;
        timestamps[token] = timestamp;
    }

    function getPrice(address token) external view override returns (uint256) {
        if (token == address(0)) {
            return 1e18; // 1 ETH = 1 ETH
        }
        return prices[token];
    }

    function getPriceWithTimestamp(address token) external view override returns (uint256 price, uint256 updatedAt) {
        if (token == address(0)) {
            return (1e18, block.timestamp);
        }
        return (prices[token], timestamps[token]);
    }

    function hasValidPrice(address token) external view override returns (bool) {
        return token == address(0) || prices[token] > 0;
    }
}
