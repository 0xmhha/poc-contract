// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import {PackedUserOperation} from "./PackedUserOperation.sol";
import {IEntryPoint} from "./IEntryPoint.sol";
import {IStakeManager} from "./IStakeManager.sol";

/**
 * @title IEntryPointSimulations
 * @notice Interface for EntryPoint simulation methods
 * @dev Extends IEntryPoint with simulation capabilities for bundlers
 */
interface IEntryPointSimulations is IEntryPoint {
    /**
     * @notice Return value of simulateHandleOp
     * @param preOpGas Gas used for validation (including preValidationGas)
     * @param paid Actual gas cost paid
     * @param accountValidationData Returned validationData from account
     * @param paymasterValidationData Returned validationData from paymaster
     * @param targetSuccess Whether the target call succeeded
     * @param targetResult Return data from target call
     */
    struct ExecutionResult {
        uint256 preOpGas;
        uint256 paid;
        uint256 accountValidationData;
        uint256 paymasterValidationData;
        bool targetSuccess;
        bytes targetResult;
    }

    /**
     * @notice Aggregator and stake info for validation result
     * @param aggregator The aggregator address (address(0) if none)
     * @param stakeInfo Stake information for the aggregator
     */
    struct AggregatorStakeInfo {
        address aggregator;
        IStakeManager.StakeInfo stakeInfo;
    }

    /**
     * @notice Successful result from simulateValidation
     * @dev If the account returns a signature aggregator the "aggregatorInfo" struct is filled in as well
     * @param returnInfo Gas and time-range returned values
     * @param senderInfo Stake information about the sender
     * @param factoryInfo Stake information about the factory (if any)
     * @param paymasterInfo Stake information about the paymaster (if any)
     * @param aggregatorInfo Signature aggregation info (if the account requires signature aggregator)
     *                       Bundler MUST use it to verify the signature, or reject the UserOperation
     */
    struct ValidationResult {
        ReturnInfo returnInfo;
        IStakeManager.StakeInfo senderInfo;
        IStakeManager.StakeInfo factoryInfo;
        IStakeManager.StakeInfo paymasterInfo;
        AggregatorStakeInfo aggregatorInfo;
    }

    /**
     * @notice Simulate a call to account.validateUserOp and paymaster.validatePaymasterUserOp
     * @dev The node must also verify it doesn't use banned opcodes, and that it doesn't reference storage
     *      outside the account's data
     * @param userOp The user operation to validate
     * @return The validation result structure
     */
    function simulateValidation(PackedUserOperation calldata userOp) external returns (ValidationResult memory);

    /**
     * @notice Simulate full execution of a UserOperation (including both validation and target execution)
     * @dev It performs full validation of the UserOperation, but ignores signature error.
     *      An optional target address is called after the userop succeeds,
     *      and its value is returned (before the entire call is reverted).
     *      Note that in order to collect the the success/failure of the target call, it must be executed
     *      with trace enabled to track the emitted events.
     * @param op The UserOperation to simulate
     * @param target If nonzero, a target address to call after userop simulation. If called,
     *               the targetSuccess and targetResult are set to the return from that call
     * @param targetCallData CallData to pass to target address
     * @return The execution result structure
     */
    function simulateHandleOp(PackedUserOperation calldata op, address target, bytes calldata targetCallData)
        external
        returns (ExecutionResult memory);
}
