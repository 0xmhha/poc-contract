// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";

/**
 * @title StringUtils
 * @notice Shared string utilities for deployment scripts
 * @dev Provides address parsing, substring, and trim operations
 */
library StringUtils {
    /**
     * @notice Parse a comma-separated string of addresses
     * @param _vm The Vm cheatcode interface
     * @param input Comma-separated address string (e.g., "0xAbc,0xDef")
     * @return parsed Array of parsed addresses
     */
    function parseAddresses(Vm _vm, string memory input) internal pure returns (address[] memory parsed) {
        bytes memory inputBytes = bytes(input);
        if (inputBytes.length == 0) {
            return new address[](0);
        }

        uint256 segments = 1;
        for (uint256 i = 0; i < inputBytes.length; i++) {
            if (inputBytes[i] == ",") {
                segments++;
            }
        }

        parsed = new address[](segments);
        uint256 index;
        uint256 start;
        for (uint256 i = 0; i <= inputBytes.length; i++) {
            if (i == inputBytes.length || inputBytes[i] == ",") {
                string memory part = trim(substring(input, start, i));
                if (bytes(part).length != 0) {
                    parsed[index] = _vm.parseAddress(part);
                    index++;
                }
                start = i + 1;
            }
        }

        assembly {
            mstore(parsed, index)
        }
    }

    /**
     * @notice Generate default addresses using deployer + deterministic derivation
     * @param deployer The deployer address (used as first element)
     * @param saltPrefix Prefix for deterministic address generation
     * @param count Number of addresses to generate
     * @return defaultAddrs Array of generated addresses
     */
    function defaultAddresses(address deployer, string memory saltPrefix, uint256 count)
        internal
        pure
        returns (address[] memory defaultAddrs)
    {
        defaultAddrs = new address[](count);
        defaultAddrs[0] = deployer;
        for (uint256 i = 1; i < count; i++) {
            defaultAddrs[i] = address(uint160(uint256(keccak256(abi.encodePacked(saltPrefix, i)))));
        }
    }

    /**
     * @notice Extract a substring from a string
     * @param str Source string
     * @param start Start index (inclusive)
     * @param end End index (exclusive)
     * @return The extracted substring
     */
    function substring(string memory str, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (end <= start) {
            return "";
        }
        bytes memory result = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            result[i] = strBytes[start + i];
        }
        return string(result);
    }

    /**
     * @notice Remove leading and trailing spaces from a string
     * @param str Input string
     * @return The trimmed string
     */
    function trim(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        uint256 start;
        uint256 end = strBytes.length;
        while (start < strBytes.length && strBytes[start] == 0x20) {
            start++;
        }
        while (end > start && strBytes[end - 1] == 0x20) {
            end--;
        }
        if (end <= start) {
            return "";
        }
        bytes memory result = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            result[i] = strBytes[start + i];
        }
        return string(result);
    }
}
