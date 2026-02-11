// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal mock Chainlink aggregator for local testing
contract MockChainlinkFeed {
    uint8 public decimals;
    int256 public price;
    string public description;

    constructor(uint8 _decimals, int256 _price, string memory _description) {
        decimals = _decimals;
        price = _price;
        description = _description;
    }

    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    ) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }

    function setPrice(int256 _price) external {
        price = _price;
    }
}
