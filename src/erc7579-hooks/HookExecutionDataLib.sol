// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title HookExecutionDataLib
 * @notice Shared library for extracting execution data from potentially wrapped calldata
 * @dev Used by ERC-7579 Hook modules (PolicyHook, SpendingLimitHook, AuditHook) to decode
 *      the actual execution target, value, and calldata from Account Abstraction execution paths.
 *
 *      Supports three calldata layouts:
 *      1. executeFromExecutor path: selector(4) + ABI-encoded (ExecMode, bytes executionCalldata)
 *      2. executeUserOp path: ABI-encoded (ExecMode, bytes executionCalldata) with selector stripped
 *      3. Direct/raw path: target(20) || value(32) || calldata(variable)
 *
 *      All functions are `internal pure` so they get inlined at compile time (no DELEGATECALL overhead).
 */
library HookExecutionDataLib {
    /// @notice Known function selector for wrapper calldata detection (executeFromExecutor path)
    bytes4 internal constant EXECUTE_FROM_EXECUTOR_SELECTOR =
        bytes4(keccak256("executeFromExecutor(bytes32,bytes)"));

    /**
     * @notice Extract the actual execution target, value, and calldata from potentially wrapped msgData
     * @dev In the Account Abstraction path, msgData may be:
     *      - executeUserOp path: ABI-encoded (ExecMode, executionCalldata) with selector already stripped
     *      - executeFromExecutor path: selector + ABI-encoded (ExecMode, executionCalldata)
     *      - Direct path: raw execution calldata (target[0:20] || value[20:52] || calldata[52:])
     *      This function detects the wrapper format and extracts the inner execution data.
     * @param msgData The calldata passed to preCheck
     * @param msgValue The ETH value passed to preCheck
     * @return target The execution target address
     * @return value The ETH value for the execution
     * @return execCalldata The inner calldata (selector + arguments) being called on the target
     */
    function extractExecutionData(bytes calldata msgData, uint256 msgValue)
        internal
        pure
        returns (address target, uint256 value, bytes calldata execCalldata)
    {
        // Path 1: executeFromExecutor wrapper — starts with 4-byte selector
        if (msgData.length >= 4) {
            bytes4 selector = bytes4(msgData[0:4]);

            if (selector == EXECUTE_FROM_EXECUTOR_SELECTOR) {
                if (msgData.length >= 100) {
                    bytes calldata abiPayload = msgData[4:];
                    return decodeAbiWrappedExecution(abiPayload, msgValue);
                }
            }

            // Path 2: executeUserOp path — selector already stripped, data is abi.encode(ExecMode, bytes)
            if (msgData.length >= 96) {
                uint256 offset = uint256(bytes32(msgData[32:64]));
                if (offset == 0x40) {
                    return decodeAbiWrappedExecution(msgData, msgValue);
                }
            }
        }

        // Path 3: Raw execution calldata — target[0:20] || value[20:52] || calldata[52:]
        if (msgData.length >= 20) {
            target = address(bytes20(msgData[0:20]));
        }
        if (msgData.length >= 52) {
            value = uint256(bytes32(msgData[20:52]));
        } else {
            value = msgValue;
        }
        if (msgData.length > 52) {
            execCalldata = msgData[52:];
        } else {
            execCalldata = msgData[0:0];
        }
    }

    /**
     * @notice Decode ABI-encoded (ExecMode, bytes executionCalldata) and extract raw execution data
     * @param abiPayload ABI-encoded payload: ExecMode(32) + offset(32) + length(32) + executionCalldata
     * @param msgValue Fallback value if inner calldata doesn't contain value
     * @return target The execution target address
     * @return value The ETH value for the execution
     * @return execCalldata The inner calldata being called on the target
     */
    function decodeAbiWrappedExecution(bytes calldata abiPayload, uint256 msgValue)
        internal
        pure
        returns (address target, uint256 value, bytes calldata execCalldata)
    {
        if (abiPayload.length < 96) {
            if (abiPayload.length >= 20) {
                target = address(bytes20(abiPayload[0:20]));
            }
            value = msgValue;
            execCalldata = abiPayload[0:0];
            return (target, value, execCalldata);
        }

        uint256 dataLength = uint256(bytes32(abiPayload[64:96]));
        uint256 dataStart = 96;
        uint256 dataEnd = dataStart + dataLength;

        if (dataEnd > abiPayload.length) {
            if (abiPayload.length >= 20) {
                target = address(bytes20(abiPayload[0:20]));
            }
            value = msgValue;
            execCalldata = abiPayload[0:0];
            return (target, value, execCalldata);
        }

        bytes calldata innerData = abiPayload[dataStart:dataEnd];

        if (innerData.length >= 20) {
            target = address(bytes20(innerData[0:20]));
        }
        if (innerData.length >= 52) {
            value = uint256(bytes32(innerData[20:52]));
        } else {
            value = msgValue;
        }
        if (innerData.length > 52) {
            execCalldata = innerData[52:];
        } else {
            execCalldata = innerData[0:0];
        }
    }
}
