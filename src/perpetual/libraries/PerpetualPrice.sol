// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IMarkPriceOracle } from "../interfaces/IMarkPriceOracle.sol";
import { PerpetualTypes } from "./PerpetualTypes.sol";
import { PerpetualErrors } from "./PerpetualErrors.sol";

/// @notice Reads an 18-decimal mark price and rejects missing, future or stale data.
library PerpetualPrice {
    uint256 internal constant MAX_PRICE_AGE = 5 minutes;

    function read(address oracle, uint32 marketId) internal view returns (uint128) {
        if (oracle == address(0)) revert PerpetualErrors.PriceNotAvailable(marketId);
        PerpetualTypes.MarkPriceData memory data = IMarkPriceOracle(oracle).getMarkPriceData(marketId);
        if (data.markPrice == 0 || data.timestamp > block.timestamp) {
            revert PerpetualErrors.InvalidPriceData(marketId, int256(uint256(data.markPrice)));
        }
        if (data.timestamp == 0 || block.timestamp - data.timestamp > MAX_PRICE_AGE) {
            revert PerpetualErrors.StalePriceData(marketId, data.timestamp, MAX_PRICE_AGE);
        }
        return data.markPrice;
    }
}
