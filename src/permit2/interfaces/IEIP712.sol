// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Uniswap Labs
// Adapted for StableNet PoC - Solidity version updated to ^0.8.28
pragma solidity ^0.8.28;

interface IEIP712 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
