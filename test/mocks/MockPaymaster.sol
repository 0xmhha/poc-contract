// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { IPaymaster } from "../../src/erc4337-entrypoint/interfaces/IPaymaster.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";

/**
 * @title MockPaymaster
 * @notice A simple mock paymaster for testing EntryPoint functionality
 */
contract MockPaymaster is IPaymaster {
    IEntryPoint public immutable ENTRY_POINT;
    address public owner;

    uint256 public validateCount;
    uint256 public postOpCount;

    error NotOwner();
    error NotEntryPoint();

    constructor(IEntryPoint _entryPoint) {
        ENTRY_POINT = _entryPoint;
        owner = msg.sender;
    }

    modifier onlyEntryPoint() {
        if (msg.sender != address(ENTRY_POINT)) revert NotEntryPoint();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @inheritdoc IPaymaster
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        validateCount++;

        // Simple validation - always approve for testing
        // In production, this would verify payment conditions
        (userOp, userOpHash, maxCost); // Silence unused variable warnings

        // Return sender as context for postOp
        context = abi.encode(userOp.sender);
        validationData = 0; // Success
    }

    /// @inheritdoc IPaymaster
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external onlyEntryPoint {
        postOpCount++;

        // Simple post-op - just track that it was called
        (mode, context, actualGasCost, actualUserOpFeePerGas); // Silence unused variable warnings
    }

    /// @notice Deposit funds to EntryPoint for this paymaster
    function deposit() external payable {
        ENTRY_POINT.depositTo{ value: msg.value }(address(this));
    }

    /// @notice Get current deposit in EntryPoint
    function getDeposit() external view returns (uint256) {
        return ENTRY_POINT.balanceOf(address(this));
    }

    /// @notice Add stake to EntryPoint
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        ENTRY_POINT.addStake{ value: msg.value }(unstakeDelaySec);
    }

    /// @notice Unlock stake
    function unlockStake() external onlyOwner {
        ENTRY_POINT.unlockStake();
    }

    /// @notice Withdraw stake after delay
    function withdrawStake(address payable withdrawAddress) external onlyOwner {
        ENTRY_POINT.withdrawStake(withdrawAddress);
    }

    receive() external payable {}
}
