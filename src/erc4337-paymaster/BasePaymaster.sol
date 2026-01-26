// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPaymaster } from "../erc4337-entrypoint/interfaces/IPaymaster.sol";
import { IEntryPoint } from "../erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { UserOperationLib } from "../erc4337-entrypoint/UserOperationLib.sol";
import { _packValidationData } from "../erc4337-entrypoint/Helpers.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BasePaymaster
 * @notice Abstract base contract for all Paymasters
 * @dev Provides common functionality for ERC-4337 Paymasters:
 *      - EntryPoint reference and access control
 *      - Deposit and stake management
 *      - Helper functions for validation data
 */
abstract contract BasePaymaster is IPaymaster, Ownable {
    IEntryPoint public immutable ENTRYPOINT;

    /// @notice Minimum deposit required to use this paymaster
    uint256 public constant MIN_DEPOSIT = 0.01 ether;

    error OnlyEntryPoint();
    error InsufficientDeposit(uint256 required, uint256 available);
    error WithdrawFailed();

    /**
     * @notice Restricts function access to EntryPoint only
     */
    modifier onlyEntryPoint() {
        _checkEntryPoint();
        _;
    }

    function _checkEntryPoint() internal view {
        if (msg.sender != address(ENTRYPOINT)) {
            revert OnlyEntryPoint();
        }
    }

    /**
     * @notice Constructor
     * @param _entryPoint The EntryPoint contract address
     * @param _owner The owner of this paymaster
     */
    constructor(IEntryPoint _entryPoint, address _owner) Ownable(_owner) {
        ENTRYPOINT = _entryPoint;
    }

    /**
     * @notice Validate a paymaster user operation
     * @dev Must verify sender is EntryPoint. Implements IPaymaster interface.
     * @param userOp The user operation
     * @param userOpHash Hash of the user operation
     * @param maxCost Maximum cost of this transaction
     * @return context Context to be passed to postOp
     * @return validationData Validation result and time range
     */
    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        external
        override
        onlyEntryPoint
        returns (bytes memory context, uint256 validationData)
    {
        return _validatePaymasterUserOp(userOp, userOpHash, maxCost);
    }

    /**
     * @notice Post-operation handler
     * @dev Called after the user operation execution
     * @param mode Operation result mode
     * @param context Context from validatePaymasterUserOp
     * @param actualGasCost Actual gas cost of the operation
     * @param actualUserOpFeePerGas Actual fee per gas paid
     */
    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        external
        override
        onlyEntryPoint
    {
        _postOp(mode, context, actualGasCost, actualUserOpFeePerGas);
    }

    /**
     * @notice Internal validation logic - to be implemented by derived contracts
     * @param userOp The user operation
     * @param userOpHash Hash of the user operation
     * @param maxCost Maximum cost of this transaction
     * @return context Context to be passed to postOp
     * @return validationData Validation result and time range
     */
    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        internal
        virtual
        returns (bytes memory context, uint256 validationData);

    /**
     * @notice Internal post-operation handler - override in derived contracts if needed
     * @param mode Operation result mode
     * @param context Context from validatePaymasterUserOp
     * @param actualGasCost Actual gas cost
     * @param actualUserOpFeePerGas Actual fee per gas
     */
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        virtual
    {
        // Default implementation does nothing
        // Override in derived contracts for custom post-op logic
        (mode, context, actualGasCost, actualUserOpFeePerGas);
    }

    // ============ Deposit Management ============

    /**
     * @notice Add deposit to EntryPoint for this paymaster
     */
    function deposit() public payable {
        ENTRYPOINT.depositTo{ value: msg.value }(address(this));
    }

    /**
     * @notice Withdraw deposit from EntryPoint
     * @param withdrawAddress Address to receive the withdrawal
     * @param amount Amount to withdraw
     */
    function withdrawTo(address payable withdrawAddress, uint256 amount) external onlyOwner {
        ENTRYPOINT.withdrawTo(withdrawAddress, amount);
    }

    /**
     * @notice Get the current deposit balance
     * @return The deposit balance in the EntryPoint
     */
    function getDeposit() public view returns (uint256) {
        return ENTRYPOINT.balanceOf(address(this));
    }

    // ============ Stake Management ============

    /**
     * @notice Add stake to EntryPoint
     * @param unstakeDelaySec Minimum delay before stake can be withdrawn
     */
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        ENTRYPOINT.addStake{ value: msg.value }(unstakeDelaySec);
    }

    /**
     * @notice Unlock the stake (start withdrawal delay)
     */
    function unlockStake() external onlyOwner {
        ENTRYPOINT.unlockStake();
    }

    /**
     * @notice Withdraw the stake after unlock delay
     * @param withdrawAddress Address to receive the stake
     */
    function withdrawStake(address payable withdrawAddress) external onlyOwner {
        ENTRYPOINT.withdrawStake(withdrawAddress);
    }

    // ============ Helper Functions ============

    /**
     * @notice Pack validation data for successful validation
     * @param validUntil Timestamp until which the validation is valid (0 = forever)
     * @param validAfter Timestamp after which the validation is valid
     * @return Packed validation data
     */
    function _packValidationDataSuccess(uint48 validUntil, uint48 validAfter) internal pure returns (uint256) {
        return _packValidationData(false, validUntil, validAfter);
    }

    /**
     * @notice Pack validation data for failed validation
     * @param validUntil Timestamp until which the validation is valid (0 = forever)
     * @param validAfter Timestamp after which the validation is valid
     * @return Packed validation data
     */
    function _packValidationDataFailure(uint48 validUntil, uint48 validAfter) internal pure returns (uint256) {
        return _packValidationData(true, validUntil, validAfter);
    }

    /**
     * @notice Parse paymaster data from the user operation
     * @param paymasterAndData Full paymasterAndData field
     * @return paymasterData The paymaster-specific data (after address and gas limits)
     */
    function _parsePaymasterData(bytes calldata paymasterAndData) internal pure returns (bytes calldata paymasterData) {
        // paymasterAndData layout:
        // [0:20] - paymaster address
        // [20:36] - paymaster validation gas limit (16 bytes)
        // [36:52] - paymaster post-op gas limit (16 bytes)
        // [52:] - paymaster data
        if (paymasterAndData.length > UserOperationLib.PAYMASTER_DATA_OFFSET) {
            return paymasterAndData[UserOperationLib.PAYMASTER_DATA_OFFSET:];
        }
        return paymasterAndData[0:0]; // empty
    }

    /**
     * @notice Receive function to accept ETH deposits
     */
    receive() external payable {
        deposit();
    }
}
