// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BasePaymaster } from "./BasePaymaster.sol";
import { IPriceOracle } from "./interfaces/IPriceOracle.sol";
import { IPermit2 } from "../permit2/interfaces/IPermit2.sol";
import { IAllowanceTransfer } from "../permit2/interfaces/IAllowanceTransfer.sol";
import { IEntryPoint } from "../erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { UserOperationLib } from "../erc4337-entrypoint/UserOperationLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { PaymasterDataLib } from "./PaymasterDataLib.sol";
import { PaymasterPayload } from "./PaymasterPayload.sol";

/**
 * @title Permit2Paymaster
 * @notice A paymaster that uses Uniswap Permit2 for gasless token approvals
 * @dev Combines Permit2 signature-based approvals with ERC-20 gas payment.
 *      Users don't need to pre-approve tokens - they sign a Permit2 permit instead.
 *
 * PaymasterData format (envelope):
 *   [envelope with type=PERMIT2, payload=ABI(Permit2Payload)]
 *   Permit2 signature goes inside the Permit2Payload (user's sig, not paymaster's).
 *   No trailing paymaster signature.
 *
 * [Staking Requirement]
 *   This paymaster returns non-empty context and uses postOp, which requires staking
 *   on the EntryPoint per ERC-7562. It also calls Permit2.permit() and Permit2.transferFrom()
 *   during validation (external storage writes), which strictly requires staking.
 *   Call addStake() after deployment.
 *
 * Flow:
 * 1. User signs Permit2 permit off-chain
 * 2. validatePaymasterUserOp decodes envelope, executes permit to approve this paymaster,
 *    and pre-charges the max token cost through Permit2's transferFrom
 * 3. postOp refunds the unused part of the pre-charge to the user
 *
 * Pre-charging matters: if postOp reverts, the EntryPoint rolls back the user's execution
 * but still charges this paymaster's deposit. Collecting tokens only in postOp would let a
 * user with too small a permit or balance get gas for free.
 */
contract Permit2Paymaster is BasePaymaster {
    using SafeERC20 for IERC20;
    using UserOperationLib for PackedUserOperation;

    /// @notice Permit2 contract address
    IPermit2 public immutable PERMIT2;

    /// @notice Price oracle for token/ETH conversion
    IPriceOracle public oracle;

    /// @notice Markup percentage in basis points (100 = 1%, 10000 = 100%)
    uint256 public markup;

    /// @notice Minimum markup (5%)
    uint256 public constant MIN_MARKUP = 500;

    /// @notice Maximum markup (50%)
    uint256 public constant MAX_MARKUP = 5000;

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Maximum staleness for price data (1 hour)
    uint256 public constant MAX_PRICE_STALENESS = 1 hours;

    /// @notice Minimum token charge to prevent dust/zero-cost attacks
    uint256 public constant MIN_TOKEN_CHARGE = 1;

    /// @notice Supported tokens whitelist
    mapping(address => bool) public supportedTokens;

    /// @notice Cached token decimals
    mapping(address => uint8) public tokenDecimals;

    /// @notice PostOp context structure
    struct PostOpContext {
        address sender;
        address token;
        uint256 maxTokenCost;
        uint256 maxCost;
    }

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event MarkupUpdated(uint256 oldMarkup, uint256 newMarkup);
    event TokenSupported(address indexed token, bool supported);
    event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);
    event GasPaidWithPermit2(address indexed sender, address indexed token, uint256 tokenAmount, uint256 gasCost);

    error UnsupportedToken(address token);
    error InvalidMarkup(uint256 markup);
    error OracleCannotBeZero();
    error Permit2CannotBeZero();
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error InvalidPrice();
    error PermitFailed();
    error TransferFailed();
    error InvalidTokenDecimals(address token);

    /**
     * @notice Constructor
     * @param _entryPoint The EntryPoint contract address
     * @param _owner The owner of this paymaster
     * @param _permit2 Permit2 contract address
     * @param _oracle Price oracle address
     * @param _markup Initial markup in basis points
     */
    constructor(IEntryPoint _entryPoint, address _owner, IPermit2 _permit2, IPriceOracle _oracle, uint256 _markup)
        BasePaymaster(_entryPoint, _owner)
    {
        if (address(_permit2) == address(0)) revert Permit2CannotBeZero();
        if (address(_oracle) == address(0)) revert OracleCannotBeZero();
        if (_markup < MIN_MARKUP || _markup > MAX_MARKUP) revert InvalidMarkup(_markup);

        PERMIT2 = _permit2;
        oracle = _oracle;
        markup = _markup;
    }

    /**
     * @notice Set the price oracle
     * @param _oracle New oracle address
     */
    function setOracle(IPriceOracle _oracle) external onlyOwner {
        if (address(_oracle) == address(0)) revert OracleCannotBeZero();
        address oldOracle = address(oracle);
        oracle = _oracle;
        emit OracleUpdated(oldOracle, address(_oracle));
    }

    /**
     * @notice Set the markup percentage
     * @param _markup New markup in basis points
     */
    function setMarkup(uint256 _markup) external onlyOwner {
        if (_markup < MIN_MARKUP || _markup > MAX_MARKUP) revert InvalidMarkup(_markup);
        uint256 oldMarkup = markup;
        markup = _markup;
        emit MarkupUpdated(oldMarkup, _markup);
    }

    /**
     * @notice Add or remove a supported token
     * @param token Token address
     * @param supported Whether the token is supported
     */
    function setSupportedToken(address token, bool supported) external onlyOwner {
        if (supported) {
            uint8 decimals = IERC20Metadata(token).decimals();
            if (decimals == 0) revert InvalidTokenDecimals(token);
            tokenDecimals[token] = decimals;
        }
        supportedTokens[token] = supported;
        emit TokenSupported(token, supported);
    }

    /**
     * @notice Withdraw collected tokens
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawTokens(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
        emit TokensWithdrawn(token, to, amount);
    }

    /**
     * @notice Calculate the token amount required for a given ETH cost
     * @param token The ERC-20 token address
     * @param ethCost The cost in ETH (wei)
     * @return tokenAmount The required token amount
     */
    function getTokenAmount(address token, uint256 ethCost) public view returns (uint256 tokenAmount) {
        (uint256 tokenPrice, uint256 updatedAt) = oracle.getPriceWithTimestamp(token);

        // Sanity check: reject zero or invalid price (consistent with ERC20Paymaster)
        if (tokenPrice == 0) revert InvalidPrice();

        if (block.timestamp - updatedAt > MAX_PRICE_STALENESS) {
            revert StalePrice(updatedAt, MAX_PRICE_STALENESS);
        }

        uint8 decimals = tokenDecimals[token];
        if (decimals == 0) {
            decimals = IERC20Metadata(token).decimals();
        }

        tokenAmount = (ethCost * (10 ** decimals) * (BASIS_POINTS + markup)) / (tokenPrice * BASIS_POINTS);
        return tokenAmount;
    }

    /**
     * @notice Internal validation logic
     * @param userOp The user operation
     * @param userOpHash Hash of the user operation (unused)
     * @param maxCost Maximum cost in native currency
     * @return context Encoded PostOpContext
     * @return validationData Validation result with time range
     */
    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        internal
        override
        returns (bytes memory context, uint256 validationData)
    {
        (userOpHash); // silence unused warning

        bytes calldata paymasterData = _parsePaymasterData(userOp.paymasterAndData);

        // Decode envelope (no trailing signature for Permit2)
        PaymasterDataLib.Envelope memory env = PaymasterDataLib.decode(paymasterData);

        // Verify paymaster type
        if (env.paymasterType != uint8(PaymasterDataLib.PaymasterType.PERMIT2)) {
            revert PaymasterDataLib.InvalidType(env.paymasterType);
        }

        // Decode type-specific payload
        PaymasterPayload.Permit2Payload memory payload = PaymasterPayload.decodePermit2(env.payload);

        // Check token is supported
        if (!supportedTokens[payload.token]) {
            revert UnsupportedToken(payload.token);
        }

        // Calculate max token cost (never below the minimum charge collected in postOp)
        uint256 maxTokenCost = getTokenAmount(payload.token, maxCost);
        if (maxTokenCost < MIN_TOKEN_CHARGE) {
            maxTokenCost = MIN_TOKEN_CHARGE;
        }

        // Execute Permit2 permit to approve this paymaster
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: payload.token,
                amount: payload.permitAmount,
                expiration: payload.permitExpiration,
                nonce: payload.permitNonce
            }),
            spender: address(this),
            sigDeadline: payload.permitExpiration
        });

        // Try to execute permit (may fail if already permitted or signature invalid).
        //
        // [EIP-4337 Bundler Compatibility Warning — External State Change in Validation]
        //   CRITICAL: PERMIT2.permit() modifies external contract state (Permit2 allowance nonces)
        //   during the validation phase. EIP-4337 simulation rules forbid external storage writes
        //   in validation — standard bundlers (Stackup, Pimlico, Alchemy, etc.) will almost
        //   certainly reject this UserOp during simulation.
        //   This is a stronger violation than internal senderNonce++ because it touches storage
        //   owned by an external contract (Permit2), not the paymaster itself.
        //   Options to resolve:
        //   (A) Move Permit2 permit execution to _postOp (execution phase)
        //   (B) Require users to pre-approve via Permit2 before submitting the UserOp
        //   (C) Operate exclusively with trusted bundlers and document this constraint
        try PERMIT2.permit(userOp.sender, permitSingle, payload.permitSig) {
        // Permit successful
        }
        catch {
            // Check if there's existing allowance via Permit2
            (uint160 existingAmount, uint48 existingExpiration,) =
                PERMIT2.allowance(userOp.sender, payload.token, address(this));

            // Verify existing allowance is sufficient
            if (existingAmount < maxTokenCost || existingExpiration < block.timestamp) {
                revert PermitFailed();
            }
        }

        // Pre-charge so the paymaster is paid even if postOp later reverts. This is a second
        // external storage write in validation (same bundler constraint as permit above), and
        // it reverts here if the permitted amount or the user's balance is too small.
        PERMIT2.transferFrom(userOp.sender, address(this), SafeCast.toUint160(maxTokenCost), payload.token);

        // Encode context for postOp
        context = abi.encode(
            PostOpContext({ sender: userOp.sender, token: payload.token, maxTokenCost: maxTokenCost, maxCost: maxCost })
        );

        return (context, _packValidationDataSuccess(env.validUntil, env.validAfter));
    }

    /**
     * @notice Post-operation handler - refund the unused part of the pre-charge
     * @param mode Operation result mode
     * @param context Encoded PostOpContext
     * @param actualGasCost Actual gas cost in native currency
     * @param actualUserOpFeePerGas Actual fee per gas (unused)
     */
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        override
    {
        (actualUserOpFeePerGas); // silence unused warning

        PostOpContext memory ctx = abi.decode(context, (PostOpContext));

        // Calculate actual token cost
        uint256 actualTokenCost;
        if (ctx.maxCost > 0) {
            actualTokenCost = (ctx.maxTokenCost * actualGasCost) / ctx.maxCost;
        }

        // Minimum charge to prevent zero-cost exploitation
        if (actualTokenCost < MIN_TOKEN_CHARGE) {
            actualTokenCost = MIN_TOKEN_CHARGE;
        }
        if (actualTokenCost > ctx.maxTokenCost) {
            actualTokenCost = ctx.maxTokenCost;
        }

        // Refund the unused pre-charge directly (the paymaster holds the tokens now).
        // In v0.9, the EntryPoint settles from prefund if postOp reverts — it does NOT
        // re-call postOp with postOpReverted mode. This guard is kept for safety.
        if (mode != PostOpMode.postOpReverted) {
            uint256 refund = ctx.maxTokenCost - actualTokenCost;
            if (refund > 0) {
                IERC20(ctx.token).safeTransfer(ctx.sender, refund);
            }

            emit GasPaidWithPermit2(ctx.sender, ctx.token, actualTokenCost, actualGasCost);
        }
    }

    /**
     * @notice Refresh cached token decimals from the token contract
     * @param token Token address
     */
    function refreshTokenDecimals(address token) external onlyOwner {
        if (!supportedTokens[token]) revert UnsupportedToken(token);
        uint8 decimals = IERC20Metadata(token).decimals();
        if (decimals == 0) revert InvalidTokenDecimals(token);
        tokenDecimals[token] = decimals;
    }

    /**
     * @notice Check if a token is supported
     * @param token The token address
     * @return True if supported
     */
    function isTokenSupported(address token) external view returns (bool) {
        return supportedTokens[token];
    }

    /**
     * @notice Get quote for gas payment
     * @param token The token address
     * @param gasLimit Estimated gas limit
     * @param maxFeePerGas Maximum fee per gas
     * @return tokenAmount Estimated token cost with markup
     */
    function getQuote(address token, uint256 gasLimit, uint256 maxFeePerGas)
        external
        view
        returns (uint256 tokenAmount)
    {
        uint256 maxCost = gasLimit * maxFeePerGas;
        return getTokenAmount(token, maxCost);
    }

    /**
     * @notice Get Permit2 contract address
     * @return The Permit2 contract address
     */
    function getPermit2() external view returns (address) {
        return address(PERMIT2);
    }
}
