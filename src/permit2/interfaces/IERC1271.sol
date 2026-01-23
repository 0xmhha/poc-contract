// SPDX-License-Identifier: MIT
// Copyright (c) 2022 Uniswap Labs
// Adapted for StableNet PoC - Solidity version updated to ^0.8.28
pragma solidity ^0.8.28;

interface IERC1271 {
    /// @dev Should return whether the signature provided is valid for the provided data
    /// @param hash      Hash of the data to be signed
    /// @param signature Signature byte array associated with _data
    /// @return magicValue The bytes4 magic value 0x1626ba7e
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue);
}
