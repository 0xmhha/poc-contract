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
 * 2. validatePaymasterUserOp decodes envelope, calculates max token cost and
 *    pre-charges it from the user
 * 3. postOp refunds the unused part of the pre-charge to the user
 *
 * Pre-charging matters: if postOp reverts, the EntryPoint rolls back the user's execution
 * but still charges this paymaster's deposit. Collecting tokens only in postOp would let a
 * user move the tokens away during execution and get gas for free.
 *
 * [Staking Requirement]
 *   This paymaster returns non-empty context and uses postOp, which requires staking
 *   on the EntryPoint per ERC-7562. Additionally, it reads and writes external ERC-20
 *   storage (balanceOf/allowance/transferFrom) during validation, which also requires
 *   staking to relax associated storage rules. Call addStake() after deployment.
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

    /// @notice Maximum staleness for price data; refresh fixed-price feeds at least daily.
    uint256 public constant MAX_PRICE_STALENESS = 1 days;

    /// @notice Maximum allowed price deviation from cached price (20%)
    uint256 public constant MAX_PRICE_DEVIATION = 2000;

    /// @notice Minimum token charge to prevent dust/zero-cost attacks
    uint256 public constant MIN_TOKEN_CHARGE = 1;

    /// @notice Gas billed in postOp for the cost the EntryPoint charges after `actualGasCost`
    /// @dev `actualGasCost` passed to postOp excludes the postOp gas itself and the 10% penalty
    ///      on unused postOp gas, yet both are charged to this paymaster's deposit. Measured with
    ///      an OpenZeppelin ERC-20, that uncharged cost is about 8.2k gas when no penalty applies
    ///      and about 22.4k gas at MAX_POSTOP_GAS_LIMIT (8.2k + (150k - 7.5k) / 10). 30k covers
    ///      it at the cap with headroom for tokens with a more expensive transfer.
    uint256 public constant POSTOP_GAS_OVERHEAD = 30_000;

    /// @notice Cached reference price per token for circuit breaker
    mapping(address => uint256) public referencePrice;

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
    error PriceDeviationTooHigh(uint256 currentPrice, uint256 refPrice);
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

        // Circuit breaker: reject if price deviates too much from reference
        uint256 refPrice = referencePrice[token];
        if (refPrice > 0) {
            uint256 deviation;
            if (tokenPrice > refPrice) {
                deviation = ((tokenPrice - refPrice) * BASIS_POINTS) / refPrice;
            } else {
                deviation = ((refPrice - tokenPrice) * BASIS_POINTS) / refPrice;
            }
            if (deviation > MAX_PRICE_DEVIATION) {
                revert PriceDeviationTooHigh(tokenPrice, refPrice);
            }
        }

        // Check staleness
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > MAX_PRICE_STALENESS) {
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
        override
        returns (bytes memory context, uint256 validationData)
    {
        (userOpHash); // silence unused warning

        // Bound the postOp gas the user can make this paymaster pay for (see POSTOP_GAS_OVERHEAD)
        _checkPostOpGasLimit(userOp);

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

        // Calculate max token cost (never below the minimum charge collected in postOp)
        uint256 maxTokenCost = getTokenAmount(payload.token, maxCost);
        if (maxTokenCost < MIN_TOKEN_CHARGE) {
            maxTokenCost = MIN_TOKEN_CHARGE;
        }

        // Check user has enough balance and allowance, then pre-charge the max token cost.
        //
        // [EIP-4337 Bundler Compatibility Warning — External Storage Access in Validation]
        //   These calls read and write storage of an external ERC-20 contract during validation.
        //   The touched slots (the sender's and this paymaster's balance, the sender's allowance)
        //   are associated with the sender or this paymaster, which ERC-7562 allows for a
        //   staked paymaster. Unstaked, strict bundlers will reject the UserOp.
        uint256 balance = IERC20(payload.token).balanceOf(userOp.sender);
        if (balance < maxTokenCost) {
            revert InsufficientTokenBalance(maxTokenCost, balance);
        }

        uint256 allowance = IERC20(payload.token).allowance(userOp.sender, address(this));
        if (allowance < maxTokenCost) {
            revert InsufficientTokenAllowance(maxTokenCost, allowance);
        }

        // Pre-charge so the paymaster is paid even if postOp later reverts
        IERC20(payload.token).safeTransferFrom(userOp.sender, address(this), maxTokenCost);

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
     * @param actualUserOpFeePerGas Actual fee per gas
     */
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        override
    {
        // Decode context
        PostOpContext memory ctx = abi.decode(context, (PostOpContext));

        // Calculate actual token cost based on actual gas used
        // Use proportion: actualTokenCost = maxTokenCost * actualGasCost / maxCost
        // actualGasCost excludes the postOp gas and the unused postOp gas penalty, which the
        // EntryPoint charges to the deposit afterwards; bill them as POSTOP_GAS_OVERHEAD.
        // The result is capped at maxTokenCost below, so the refund stays non-negative.
        uint256 actualTokenCost;
        if (ctx.maxCost > 0) {
            uint256 gasCost = actualGasCost + POSTOP_GAS_OVERHEAD * actualUserOpFeePerGas;
            actualTokenCost = (ctx.maxTokenCost * gasCost) / ctx.maxCost;
        }

        // Minimum charge to prevent zero-cost exploitation
        if (actualTokenCost < MIN_TOKEN_CHARGE) {
            actualTokenCost = MIN_TOKEN_CHARGE;
        }
        if (actualTokenCost > ctx.maxTokenCost) {
            actualTokenCost = ctx.maxTokenCost;
        }

        // Refund the unused pre-charge. If this reverts, the EntryPoint rolls back the
        // execution and charges the deposit, but the paymaster keeps the full pre-charge.
        // In v0.9 the EntryPoint does NOT re-call postOp with postOpReverted; the guard
        // below is kept for safety.
        if (mode != PostOpMode.postOpReverted) {
            uint256 refund = ctx.maxTokenCost - actualTokenCost;
            if (refund > 0) {
                IERC20(ctx.token).safeTransfer(ctx.sender, refund);
            }
            emit GasPaidWithToken(ctx.sender, ctx.token, actualTokenCost, actualGasCost);
        }
    }

    /**
     * @notice Update the reference price for circuit breaker
     * @param token Token address
     */
    function updateReferencePrice(address token) external onlyOwner {
        (uint256 tokenPrice,) = oracle.getPriceWithTimestamp(token);
        if (tokenPrice == 0) revert InvalidPrice();
        referencePrice[token] = tokenPrice;
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
}
