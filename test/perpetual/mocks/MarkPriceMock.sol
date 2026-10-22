// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PerpetualTypes } from "../../../src/perpetual/libraries/PerpetualTypes.sol";

contract MarkPriceMock {
    mapping(uint32 => PerpetualTypes.MarkPriceData) private _prices;
    bool public fails;

    function setPrice(uint32 marketId, uint128 price) external {
        _prices[marketId] = PerpetualTypes.MarkPriceData(price, price, 0, 0, uint64(block.timestamp));
    }

    function setTimestamp(uint32 marketId, uint64 timestamp) external {
        _prices[marketId].timestamp = timestamp;
    }

    function setFails(bool value) external {
        fails = value;
    }

    function getMarkPriceData(uint32 marketId) external view returns (PerpetualTypes.MarkPriceData memory) {
        require(!fails, "oracle unavailable");
        return _prices[marketId];
    }
}
