// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BasePaymaster } from "./BasePaymaster.sol";
import { IPriceOracle } from "./interfaces/IPriceOracle.sol";
import { IEntryPoint } from "../erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { UserOperationLib } from "../erc4337-entrypoint/UserOperationLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { PaymasterDataLib } from "./PaymasterDataLib.sol";
import { PaymasterPayload } from "./PaymasterPayload.sol";

/**
 * @title ERC20Paymaster
 * @notice A paymaster that accepts ERC-20 tokens for gas payment
 * @dev Users can pay for gas with approved ERC-20 tokens instead of native currency.
 *      The paymaster uses a price oracle to convert between token and native currency.
 *      A markup is applied to cover price volatility and operational costs.
 *
 * PaymasterData format (envelope):
 *   [envelope with type=ERC20, payload=ABI(Erc20Payload)]
 *   No trailing signature – oracle-based, no signer verification.
 *
 * Flow:
 * 1. User pre-approves tokens to this paymaster
 * 2. validatePaymasterUserOp decodes envelope, checks balance and calculates max token cost
 * 3. postOp transfers actual token cost from user to paymaster
 */
contract ERC20Paymaster is BasePaymaster {
    using SafeERC20 for IERC20;
    using UserOperationLib for PackedUserOperation;

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
    event GasPaidWithToken(address indexed sender, address indexed token, uint256 tokenAmount, uint256 gasCost);

    error UnsupportedToken(address token);
    error InsufficientTokenBalance(uint256 required, uint256 available);
    error InsufficientTokenAllowance(uint256 required, uint256 available);
    error InvalidMarkup(uint256 markup);
    error OracleCannotBeZero();
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error InvalidPrice();
    error InvalidTokenDecimals(address token);

    /**
     * @notice Constructor
     * @param _entryPoint The EntryPoint contract address
     * @param _owner The owner of this paymaster
     * @param _oracle Price oracle address
     * @param _markup Initial markup in basis points (e.g., 1000 = 10%)
     */
    constructor(IEntryPoint _entryPoint, address _owner, IPriceOracle _oracle, uint256 _markup)
        BasePaymaster(_entryPoint, _owner)
    {
        if (address(_oracle) == address(0)) revert OracleCannotBeZero();
        if (_markup < MIN_MARKUP || _markup > MAX_MARKUP) revert InvalidMarkup(_markup);

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
            // Cache and validate decimals for supported tokens
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
        // Get token price (how much ETH per token in 18 decimals)
        (uint256 tokenPrice, uint256 updatedAt) = oracle.getPriceWithTimestamp(token);

        // Sanity check: reject zero or invalid price
        if (tokenPrice == 0) revert InvalidPrice();

        // Check staleness
        if (block.timestamp - updatedAt > MAX_PRICE_STALENESS) {
            revert StalePrice(updatedAt, MAX_PRICE_STALENESS);
        }

        // Get token decimals
        uint8 decimals = tokenDecimals[token];
        if (decimals == 0) {
            decimals = IERC20Metadata(token).decimals();
        }

        // Calculate: tokenAmount = (ethCost * 10^tokenDecimals * (10000 + markup)) / (tokenPrice * 10000)
        // This gives us the amount of tokens needed to cover ethCost + markup
        tokenAmount = (ethCost * (10 ** decimals) * (BASIS_POINTS + markup)) / (tokenPrice * BASIS_POINTS);

        return tokenAmount;
    }

    /**
     * @notice Internal validation logic
     * @param userOp The user operation
     * @param userOpHash Hash of the user operation
     * @param maxCost Maximum cost in native currency
     * @return context Encoded PostOpContext
     * @return validationData Packed validation data with time range
     */
    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        internal
        view
        override
        returns (bytes memory context, uint256 validationData)
    {
        (userOpHash); // silence unused warning

        bytes calldata paymasterData = _parsePaymasterData(userOp.paymasterAndData);

        // Decode envelope (no trailing signature for ERC20)
        PaymasterDataLib.Envelope memory env = PaymasterDataLib.decode(paymasterData);

        // Verify paymaster type
        if (env.paymasterType != uint8(PaymasterDataLib.PaymasterType.ERC20)) {
            revert PaymasterDataLib.InvalidType(env.paymasterType);
        }

        // Decode type-specific payload
        PaymasterPayload.Erc20Payload memory payload = PaymasterPayload.decodeErc20(env.payload);

        // Check token is supported
        if (!supportedTokens[payload.token]) {
            revert UnsupportedToken(payload.token);
        }

        // Calculate max token cost
        uint256 maxTokenCost = getTokenAmount(payload.token, maxCost);

        // Check user has enough balance and allowance.
        //
        // [EIP-4337 Bundler Compatibility Warning — External Storage Read in Validation]
        //   These calls read storage from an external ERC-20 contract during validation.
        //   EIP-4337's associated storage rule restricts which storage slots can be accessed
        //   during validation. Arbitrary ERC-20 contract reads may violate this rule, causing
        //   strict bundlers to reject the UserOp.
        //   Options to resolve:
        //   (A) Remove balance/allowance checks here; rely on _postOp's safeTransferFrom failure
        //   (B) Operate as a staked paymaster to relax the storage access restriction
        uint256 balance = IERC20(payload.token).balanceOf(userOp.sender);
        if (balance < maxTokenCost) {
            revert InsufficientTokenBalance(maxTokenCost, balance);
        }

        uint256 allowance = IERC20(payload.token).allowance(userOp.sender, address(this));
        if (allowance < maxTokenCost) {
            revert InsufficientTokenAllowance(maxTokenCost, allowance);
        }

        // Encode context for postOp
        context = abi.encode(
            PostOpContext({ sender: userOp.sender, token: payload.token, maxTokenCost: maxTokenCost, maxCost: maxCost })
        );

        return (context, _packValidationDataSuccess(env.validUntil, env.validAfter));
    }

    /**
     * @notice Post-operation handler - collect token payment
     * @param mode Operation result mode
     * @param context Encoded PostOpContext
     * @param actualGasCost Actual gas cost in native currency
     * @param actualUserOpFeePerGas Actual fee per gas
     */
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        override
    {
        (actualUserOpFeePerGas); // silence unused warning

        // Decode context
        PostOpContext memory ctx = abi.decode(context, (PostOpContext));

        // Calculate actual token cost based on actual gas used
        // Use proportion: actualTokenCost = maxTokenCost * actualGasCost / maxCost
        uint256 actualTokenCost;
        if (ctx.maxCost > 0) {
            actualTokenCost = (ctx.maxTokenCost * actualGasCost) / ctx.maxCost;
        }

        // Minimum charge to prevent dust attacks
        if (actualTokenCost == 0) {
            actualTokenCost = 1;
        }

        // Transfer tokens from user to paymaster
        // Note: This will fail if user doesn't have enough balance or allowance
        // In that case, the postOp will revert and the paymaster loses the gas cost
        if (mode != PostOpMode.postOpReverted) {
            IERC20(ctx.token).safeTransferFrom(ctx.sender, address(this), actualTokenCost);
            emit GasPaidWithToken(ctx.sender, ctx.token, actualTokenCost, actualGasCost);
        }
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
}
