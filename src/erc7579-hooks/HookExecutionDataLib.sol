// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC7579Account } from "../erc7579-smartaccount/interfaces/IERC7579Account.sol";
import { CallType } from "../erc7579-smartaccount/types/Types.sol";
import { CALLTYPE_SINGLE, CALLTYPE_BATCH, CALLTYPE_DELEGATECALL } from "../erc7579-smartaccount/types/Constants.sol";
import { LibERC7579 } from "solady/accounts/LibERC7579.sol";

/**
 * @title HookExecutionDataLib
 * @notice Shared library for decoding the executions behind the msgData Kernel passes to hooks
 * @dev Used by ERC-7579 Hook modules (PolicyHook, SpendingLimitHook, AuditHook, HealthFactorHook).
 *
 *      Kernel passes the following msgData to `preCheck`:
 *      1. `execute` (root hook, and executeUserOp, which strips only its own selector):
 *         execute.selector(4) || abi.encode(ExecMode, bytes executionCalldata)
 *      2. `executeFromExecutor`:
 *         executeFromExecutor.selector(4) || abi.encode(ExecMode, bytes executionCalldata)
 *      3. Any other account function (installModule, uninstallModule, fallback selectors, or a
 *         non-execute selector reached through executeUserOp): the raw call to the account.
 *
 *      For layouts 1 and 2 the bytes argument is located through its ABI offset (as Kernel's ABI
 *      decoder reads it) and decoded per the ExecMode call type with the same LibERC7579 decoders
 *      Kernel uses to execute. Layout 3 is reported as a single call whose target is the account
 *      itself (the hook's `msg.sender`).
 *
 *      Callers iterate executions with `getExecutionCount` + `getExecution`. Unsupported call types
 *      and malformed encodings revert (fail closed).
 */
library HookExecutionDataLib {
    /// @notice Kernel `execute(bytes32,bytes)` selector
    bytes4 internal constant EXECUTE_SELECTOR = IERC7579Account.execute.selector;

    /// @notice Kernel `executeFromExecutor(bytes32,bytes)` selector
    bytes4 internal constant EXECUTE_FROM_EXECUTOR_SELECTOR = IERC7579Account.executeFromExecutor.selector;

    error UnsupportedCallType(CallType callType);
    error InvalidExecutionCalldata();

    /**
     * @notice Number of executions encoded in msgData
     * @param msgData The calldata passed to preCheck
     * @return isExecute True if msgData is an execute/executeFromExecutor call
     * @return callType CallType of the ExecMode (CALLTYPE_SINGLE when isExecute is false)
     * @return count Number of executions (1 for single, delegatecall and non-execute calls)
     */
    function getExecutionCount(bytes calldata msgData)
        internal
        pure
        returns (bool isExecute, CallType callType, uint256 count)
    {
        bytes calldata executionCalldata;
        (isExecute, callType, executionCalldata) = decodeExecuteCalldata(msgData);
        if (!isExecute) return (false, CALLTYPE_SINGLE, 1);
        if (callType == CALLTYPE_BATCH) {
            count = LibERC7579.decodeBatch(executionCalldata).length;
        } else if (callType == CALLTYPE_SINGLE || callType == CALLTYPE_DELEGATECALL) {
            count = 1;
        } else {
            revert UnsupportedCallType(callType);
        }
    }

    /**
     * @notice Decode the i-th execution encoded in msgData
     * @dev For CALLTYPE_DELEGATECALL the delegate is returned as target and value is 0.
     *      For non-execute msgData the account itself is returned as target.
     * @param msgData The calldata passed to preCheck
     * @param msgValue The ETH value passed to preCheck
     * @param index Execution index (< count from getExecutionCount)
     * @return target The execution target (delegate for delegatecall)
     * @return value The ETH value for the execution
     * @return data The calldata executed on the target
     */
    function getExecution(bytes calldata msgData, uint256 msgValue, uint256 index)
        internal
        view
        returns (address target, uint256 value, bytes calldata data)
    {
        (bool isExecute, CallType callType, bytes calldata executionCalldata) = decodeExecuteCalldata(msgData);
        if (!isExecute) {
            if (index != 0) revert InvalidExecutionCalldata();
            return (msg.sender, msgValue, msgData);
        }
        if (callType == CALLTYPE_BATCH) {
            bytes32[] calldata pointers = LibERC7579.decodeBatch(executionCalldata);
            if (index >= pointers.length) revert InvalidExecutionCalldata();
            (target, value, data) = LibERC7579.getExecution(pointers, index);
            // getExecution loads the full target word and Kernel calls its low 160 bits: clean it here
            // instead of relying on compiler cleanup at each use
            assembly ("memory-safe") {
                target := shr(96, shl(96, target))
            }
            return (target, value, data);
        }
        if (index != 0) revert InvalidExecutionCalldata();
        if (callType == CALLTYPE_SINGLE) {
            return LibERC7579.decodeSingle(executionCalldata);
        }
        if (callType == CALLTYPE_DELEGATECALL) {
            (target, data) = LibERC7579.decodeDelegate(executionCalldata);
            return (target, 0, data);
        }
        revert UnsupportedCallType(callType);
    }

    /**
     * @notice Split execute/executeFromExecutor calldata into CallType and executionCalldata
     * @dev Follows the ABI offset of the bytes argument and checks bounds like the ABI decoder.
     * @param msgData The calldata passed to preCheck
     * @return isExecute True if msgData starts with the execute or executeFromExecutor selector
     * @return callType CallType of the ExecMode
     * @return executionCalldata The bytes executionCalldata argument
     */
    function decodeExecuteCalldata(bytes calldata msgData)
        internal
        pure
        returns (bool isExecute, CallType callType, bytes calldata executionCalldata)
    {
        executionCalldata = msgData[0:0];
        if (msgData.length < 4) return (false, callType, executionCalldata);
        bytes4 selector = bytes4(msgData[0:4]);
        if (selector != EXECUTE_SELECTOR && selector != EXECUTE_FROM_EXECUTOR_SELECTOR) {
            return (false, callType, executionCalldata);
        }
        // selector(4) + ExecMode(32) + offset(32)
        if (msgData.length < 68) revert InvalidExecutionCalldata();
        uint256 offset = uint256(bytes32(msgData[36:68]));
        // The length word must lie inside the arguments area, which starts at byte 4
        if (offset > msgData.length - 36) revert InvalidExecutionCalldata();
        uint256 lengthPos = 4 + offset;
        uint256 length = uint256(bytes32(msgData[lengthPos:lengthPos + 32]));
        if (length > msgData.length - lengthPos - 32) revert InvalidExecutionCalldata();
        isExecute = true;
        callType = CallType.wrap(msgData[4]);
        executionCalldata = msgData[lengthPos + 32:lengthPos + 32 + length];
    }
}
