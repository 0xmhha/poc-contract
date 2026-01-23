// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Uniswap Labs
// Adapted for StableNet PoC - Solidity version updated to ^0.8.28
pragma solidity ^0.8.28;

/// @notice Shared errors between signature based transfers and allowance based transfers.

/// @notice Thrown when validating an inputted signature that is stale
/// @param signatureDeadline The timestamp at which a signature is no longer valid
error SignatureExpired(uint256 signatureDeadline);

/// @notice Thrown when validating that the inputted nonce has not been used
error InvalidNonce();
