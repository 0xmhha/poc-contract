// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BasePaymaster} from "./BasePaymaster.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IPermit2} from "./interfaces/IPermit2.sol";
import {IEntryPoint} from "../erc4337-entrypoint/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "../erc4337-entrypoint/UserOperationLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title Permit2Paymaster
 * @notice A paymaster that uses Uniswap Permit2 for gasless token approvals
 * @dev Combines Permit2 signature-based approvals with ERC-20 gas payment.
 *      Users don't need to pre-approve tokens - they sign a Permit2 permit instead.
 *
 * PaymasterData format:
 *   [0:20]   - token address
 *   [20:36]  - amount (uint128) - maximum amount to permit
 *   [36:42]  - expiration (uint48) - permit expiration timestamp
 *   [42:48]  - nonce (uint48) - permit2 nonce
 *   [48:113] - signature (65 bytes) - Permit2 signature
 *
 * Flow:
 * 1. User signs Permit2 permit off-chain
 * 2. validatePaymasterUserOp executes permit to approve this paymaster
 * 3. postOp transfers tokens using Permit2's transferFrom
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
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Maximum staleness for price data (1 hour)
    uint256 public constant MAX_PRICE_STALENESS = 1 hours;

    /// @notice Supported tokens whitelist
    mapping(address => bool) public supportedTokens;

    /// @notice Cached token decimals
    mapping(address => uint8) public tokenDecimals;

    /// @notice Minimum paymaster data length
    /// 20 (token) + 16 (amount) + 6 (expiration) + 6 (nonce) + 65 (signature) = 113
    uint256 private constant MIN_PAYMASTER_DATA_LENGTH = 113;

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
    event GasPaidWithPermit2(
        address indexed sender,
        address indexed token,
        uint256 tokenAmount,
        uint256 gasCost
    );

    error UnsupportedToken(address token);
    error InvalidMarkup(uint256 markup);
    error OracleCannotBeZero();
    error Permit2CannotBeZero();
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error InvalidPaymasterDataLength();
    error PermitFailed();
    error TransferFailed();

    /**
     * @notice Constructor
     * @param _entryPoint The EntryPoint contract address
     * @param _owner The owner of this paymaster
     * @param _permit2 Permit2 contract address
     * @param _oracle Price oracle address
     * @param _markup Initial markup in basis points
     */
    constructor(
        IEntryPoint _entryPoint,
        address _owner,
        IPermit2 _permit2,
        IPriceOracle _oracle,
        uint256 _markup
    ) BasePaymaster(_entryPoint, _owner) {
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
        supportedTokens[token] = supported;
        if (supported && tokenDecimals[token] == 0) {
            tokenDecimals[token] = IERC20Metadata(token).decimals();
        }
        emit TokenSupported(token, supported);
    }

    /**
     * @notice Withdraw collected tokens
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
        emit TokensWithdrawn(token, to, amount);
    }

    /**
     * @notice Calculate the token amount required for a given ETH cost
     * @param token The ERC-20 token address
     * @param ethCost The cost in ETH (wei)
     * @return tokenAmount The required token amount
     */
    function getTokenAmount(
        address token,
        uint256 ethCost
    ) public view returns (uint256 tokenAmount) {
        (uint256 tokenPrice, uint256 updatedAt) = oracle.getPriceWithTimestamp(token);

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
     * @return validationData Validation result
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) internal override returns (bytes memory context, uint256 validationData) {
        (userOpHash); // silence unused warning

        bytes calldata paymasterData = _parsePaymasterData(userOp.paymasterAndData);

        if (paymasterData.length < MIN_PAYMASTER_DATA_LENGTH) {
            revert InvalidPaymasterDataLength();
        }

        // Parse paymaster data
        address token = address(bytes20(paymasterData[0:20]));
        uint160 permitAmount = uint160(bytes20(paymasterData[20:40]));
        uint48 expiration = uint48(bytes6(paymasterData[40:46]));
        uint48 nonce = uint48(bytes6(paymasterData[46:52]));
        bytes calldata signature = paymasterData[52:117];

        // Check token is supported
        if (!supportedTokens[token]) {
            revert UnsupportedToken(token);
        }

        // Calculate max token cost
        uint256 maxTokenCost = getTokenAmount(token, maxCost);

        // Execute Permit2 permit to approve this paymaster
        IPermit2.PermitSingle memory permitSingle = IPermit2.PermitSingle({
            details: IPermit2.PermitDetails({
                token: token,
                amount: permitAmount,
                expiration: expiration,
                nonce: nonce
            }),
            spender: address(this),
            sigDeadline: expiration
        });

        // Try to execute permit (may fail if already permitted or signature invalid)
        try PERMIT2.permit(userOp.sender, permitSingle, signature) {
            // Permit successful
        } catch {
            // Check if there's existing allowance via Permit2
            (uint160 existingAmount, uint48 existingExpiration,) = PERMIT2.allowance(
                userOp.sender,
                token,
                address(this)
            );

            // Verify existing allowance is sufficient
            if (existingAmount < maxTokenCost || existingExpiration < block.timestamp) {
                revert PermitFailed();
            }
        }

        // Encode context for postOp
        context = abi.encode(
            PostOpContext({
                sender: userOp.sender,
                token: token,
                maxTokenCost: maxTokenCost,
                maxCost: maxCost
            })
        );

        return (context, 0);
    }

    /**
     * @notice Post-operation handler - collect token payment via Permit2
     * @param mode Operation result mode
     * @param context Encoded PostOpContext
     * @param actualGasCost Actual gas cost in native currency
     * @param actualUserOpFeePerGas Actual fee per gas (unused)
     */
    function _postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal override {
        (actualUserOpFeePerGas); // silence unused warning

        PostOpContext memory ctx = abi.decode(context, (PostOpContext));

        // Calculate actual token cost
        uint256 actualTokenCost;
        if (ctx.maxCost > 0) {
            actualTokenCost = (ctx.maxTokenCost * actualGasCost) / ctx.maxCost;
        }

        if (actualTokenCost == 0) {
            actualTokenCost = 1;
        }

        // Transfer tokens via Permit2
        if (mode != PostOpMode.postOpReverted) {
            // Casting to 'uint160' is safe because actualTokenCost is derived from gas costs
            // which are bounded by block gas limit and will never exceed uint160 max value
            // forge-lint: disable-next-line(unsafe-typecast)
            uint160 transferAmount = uint160(actualTokenCost);

            PERMIT2.transferFrom(
                ctx.sender,
                address(this),
                transferAmount,
                ctx.token
            );

            emit GasPaidWithPermit2(ctx.sender, ctx.token, actualTokenCost, actualGasCost);
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
    function getQuote(
        address token,
        uint256 gasLimit,
        uint256 maxFeePerGas
    ) external view returns (uint256 tokenAmount) {
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
