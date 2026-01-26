// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title DeployConstants
 * @notice Shared deployment constants used across multiple scripts
 * @dev Centralizes default values to eliminate duplication
 */
library DeployConstants {
    // Compliance defaults
    uint256 constant DEFAULT_RETENTION_PERIOD = 365 days;
    uint256 constant DEFAULT_AUTO_PAUSE_THRESHOLD = 3;

    // Bridge defaults
    uint256 constant DEFAULT_CHALLENGE_PERIOD = 1 days;
    uint256 constant DEFAULT_CHALLENGE_BOND = 1 ether;
    uint256 constant DEFAULT_CHALLENGER_REWARD = 0.5 ether;

    // Paymaster defaults
    uint256 constant DEFAULT_MARKUP = 1000; // 10%
}
