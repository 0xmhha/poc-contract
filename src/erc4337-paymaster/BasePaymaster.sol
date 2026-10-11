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
 *
 * ## EIP-4337 Public Mempool Compatibility Policy
 *
 * **Decision: Private/Trusted Bundler Only (PoC Phase)**
 *
 * Several derived paymasters perform state changes during the validation phase
 * (`_validatePaymasterUserOp`), which violates EIP-4337 simulation determinism rules.
 * Public mempool bundlers (Stackup, Pimlico, Alchemy, etc.) will reject these operations.
 *
 * Known validation-phase violations:
 *   - VerifyingPaymaster: `senderNonce[sender]++` (internal storage write)
 *   - SponsorPaymaster:   `senderNonce[sender]++` (internal storage write)
 *   - Permit2Paymaster:   `PERMIT2.permit()` and `PERMIT2.transferFrom()` pre-charge
 *                         (external contract state writes — most severe)
 *   - ERC20Paymaster:     `safeTransferFrom()` pre-charge (external token storage write)
 *
 * The token paymasters pre-charge the max token cost during validation on purpose: if
 * postOp reverts, the EntryPoint still charges the paymaster's deposit, so collecting
 * tokens only in postOp would let users get gas for free. Do not move the token transfer
 * to `_postOp`.
 *
 * For future public mempool support, the following changes are required:
 *   1. Move `senderNonce++` to `_postOp` or remove in favor of EntryPoint's built-in nonce
 *   2. Require Permit2 pre-approval before UserOp submission instead of calling
 *      `PERMIT2.permit()` in validation
 *   3. Operate ERC20Paymaster and Permit2Paymaster as staked paymasters to relax the
 *      associated storage rules
 *
 * See individual contract warnings for detailed remediation guidance.
 */
abstract contract BasePaymaster is IPaymaster, Ownable {
    IEntryPoint public immutable ENTRYPOINT;

    /// @notice Minimum deposit required to use this paymaster
    uint256 public constant MIN_DEPOSIT = 0.01 ether;

    /// @notice Maximum `paymasterPostOpGasLimit` accepted by paymasters that use postOp
    /// @dev The user picks the postOp gas limit (paymasterAndData[36:52]) and the EntryPoint
    ///      charges this paymaster's deposit 10% of the unused part of it (when more than
    ///      40k gas is unused), on top of the postOp gas actually used. Neither amount is in
    ///      the `actualGasCost` passed to postOp. The cap bounds that cost. Measured postOp
    ///      usage is about 8k gas for the ERC20/Permit2 refund and about 45k gas for the
    ///      SponsorPaymaster settlement (first spend of a campaign), so 150k leaves a wide margin
    ///      and matches the postOp limit the paymaster proxy requests for the token paymasters.
    ///      SponsorPaymaster needs the cap because its signature does not cover this field.
    uint256 public constant MAX_POSTOP_GAS_LIMIT = 150_000;

    error OnlyEntryPoint();
    error InsufficientDeposit(uint256 required, uint256 available);
    error WithdrawFailed();
    error PostOpGasLimitTooHigh(uint256 limit, uint256 maxLimit);

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
        if (msg.value < MIN_DEPOSIT) revert InsufficientDeposit(MIN_DEPOSIT, msg.value);
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
     * @notice Reject a UserOp whose paymasterPostOpGasLimit exceeds MAX_POSTOP_GAS_LIMIT
     * @param userOp The user operation (the EntryPoint guarantees the static paymaster fields)
     */
    function _checkPostOpGasLimit(PackedUserOperation calldata userOp) internal pure {
        uint256 postOpGasLimit = UserOperationLib.unpackPostOpGasLimit(userOp);
        if (postOpGasLimit > MAX_POSTOP_GAS_LIMIT) {
            revert PostOpGasLimitTooHigh(postOpGasLimit, MAX_POSTOP_GAS_LIMIT);
        }
    }

    // ============ Envelope Helpers ============

    /// @notice EIP-712-like domain typehash (must match SDK/proxy)
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address entryPoint,address paymaster)");

    /**
     * @notice Compute the domain separator for hashing
     * @return The EIP-712-like domain separator
     */
    function _computeDomainSeparator() internal view returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("StableNetPaymaster"),
                keccak256("1"),
                block.chainid,
                address(ENTRYPOINT),
                address(this)
            )
        );
    }

    /**
     * @notice Compute a core hash of the UserOp fields (excluding paymasterAndData and signature)
     * @param userOp The packed user operation
     * @return The core hash
     */
    function _computeUserOpCoreHash(PackedUserOperation calldata userOp) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees
            )
        );
    }

    /**
     * @notice Receive function to accept ETH deposits
     */
    receive() external payable {
        deposit();
    }
}
