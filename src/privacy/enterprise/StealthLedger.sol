// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title IStealthLedger
 * @notice Interface for Enterprise Stealth Ledger
 */
interface IStealthLedger {
    /* //////////////////////////////////////////////////////////////
                                 STRUCTS
    ////////////////////////////////////////////////////////////// */

    struct Balance {
        address token;
        uint256 amount;
        uint256 lastUpdated;
        bool active;
    }

    struct Transaction {
        bytes32 stealthAddressHash;
        address token;
        uint256 amount;
        TransactionType txType;
        uint256 timestamp;
        bytes32 relatedTxId;
    }

    enum TransactionType {
        DEPOSIT,
        WITHDRAWAL,
        TRANSFER,
        FEE
    }

    /* //////////////////////////////////////////////////////////////
                                 EVENTS
    ////////////////////////////////////////////////////////////// */

    event BalanceUpdated(bytes32 indexed stealthAddressHash, address indexed token, uint256 newBalance, int256 delta);

    event TransactionRecorded(
        bytes32 indexed txId, bytes32 indexed stealthAddressHash, TransactionType txType, uint256 amount
    );

    event VaultAuthorized(address indexed vault, bool authorized);

    /* //////////////////////////////////////////////////////////////
                                 ERRORS
    ////////////////////////////////////////////////////////////// */

    error UnauthorizedVault();
    error InsufficientBalance();
    error InvalidStealthAddress();
    error InvalidAmount();
    error TransactionNotFound();
}

/**
 * @title StealthLedger
 * @notice Enterprise-grade ledger for tracking stealth address balances
 * @dev Provides balance tracking and transaction history for stealth addresses
 *
 * Features:
 *   - Multi-token balance tracking per stealth address
 *   - Transaction history with categorization
 *   - Vault authorization system
 *   - Audit trail for compliance
 */
contract StealthLedger is IStealthLedger, AccessControl, Pausable, ReentrancyGuard {
    /* //////////////////////////////////////////////////////////////
                                 ROLES
    ////////////////////////////////////////////////////////////// */

    bytes32 public constant LEDGER_ADMIN_ROLE = keccak256("LEDGER_ADMIN_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    /* //////////////////////////////////////////////////////////////
                            STATE VARIABLES
    ////////////////////////////////////////////////////////////// */

    /// @notice Mapping from stealth address hash to token to balance
    mapping(bytes32 stealthHash => mapping(address token => Balance)) public balances;

    /// @notice Mapping from transaction ID to transaction details
    mapping(bytes32 txId => Transaction) public transactions;

    /// @notice Mapping from stealth address hash to transaction IDs
    mapping(bytes32 stealthHash => bytes32[]) public stealthTransactions;

    /// @notice Authorized vaults that can update balances
    mapping(address vault => bool) public authorizedVaults;

    /// @notice Total transaction count
    uint256 public transactionCount;

    /// @notice Total balance by token across all stealth addresses
    mapping(address token => uint256) public totalBalances;

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    ////////////////////////////////////////////////////////////// */

    constructor(address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(LEDGER_ADMIN_ROLE, _admin);
    }

    /* //////////////////////////////////////////////////////////////
                              MODIFIERS
    ////////////////////////////////////////////////////////////// */

    modifier onlyAuthorizedVault() {
        _checkAuthorizedVault();
        _;
    }

    function _checkAuthorizedVault() internal view {
        if (!authorizedVaults[msg.sender]) revert UnauthorizedVault();
    }

    /* //////////////////////////////////////////////////////////////
                         BALANCE MANAGEMENT
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Credit balance to a stealth address
     * @param stealthAddressHash The stealth address hash
     * @param token The token address
     * @param amount The amount to credit
     * @return txId The transaction ID
     */
    function creditBalance(bytes32 stealthAddressHash, address token, uint256 amount)
        external
        onlyAuthorizedVault
        whenNotPaused
        nonReentrant
        returns (bytes32 txId)
    {
        if (stealthAddressHash == bytes32(0)) revert InvalidStealthAddress();
        if (amount == 0) revert InvalidAmount();

        Balance storage balance = balances[stealthAddressHash][token];

        balance.token = token;
        balance.amount += amount;
        balance.lastUpdated = block.timestamp;
        balance.active = true;

        totalBalances[token] += amount;

        txId = _recordTransaction(stealthAddressHash, token, amount, TransactionType.DEPOSIT, bytes32(0));

        // casting to 'int256' is safe because amount is bounded by token supply which fits in int256
        // forge-lint: disable-next-line(unsafe-typecast)
        emit BalanceUpdated(stealthAddressHash, token, balance.amount, int256(amount));
    }

    /**
     * @notice Debit balance from a stealth address
     * @param stealthAddressHash The stealth address hash
     * @param token The token address
     * @param amount The amount to debit
     * @return txId The transaction ID
     */
    function debitBalance(bytes32 stealthAddressHash, address token, uint256 amount)
        external
        onlyAuthorizedVault
        whenNotPaused
        nonReentrant
        returns (bytes32 txId)
    {
        if (stealthAddressHash == bytes32(0)) revert InvalidStealthAddress();
        if (amount == 0) revert InvalidAmount();

        Balance storage balance = balances[stealthAddressHash][token];

        if (balance.amount < amount) revert InsufficientBalance();

        balance.amount -= amount;
        balance.lastUpdated = block.timestamp;

        totalBalances[token] -= amount;

        txId = _recordTransaction(stealthAddressHash, token, amount, TransactionType.WITHDRAWAL, bytes32(0));

        // casting to 'int256' is safe because amount is bounded by token supply which fits in int256
        // forge-lint: disable-next-line(unsafe-typecast)
        emit BalanceUpdated(stealthAddressHash, token, balance.amount, -int256(amount));
    }

    /**
     * @notice Transfer balance between stealth addresses
     * @param fromHash The source stealth address hash
     * @param toHash The destination stealth address hash
     * @param token The token address
     * @param amount The amount to transfer
     * @return fromTxId The source transaction ID
     * @return toTxId The destination transaction ID
     */
    function transferBalance(bytes32 fromHash, bytes32 toHash, address token, uint256 amount)
        external
        onlyAuthorizedVault
        whenNotPaused
        nonReentrant
        returns (bytes32 fromTxId, bytes32 toTxId)
    {
        if (fromHash == bytes32(0) || toHash == bytes32(0)) revert InvalidStealthAddress();
        if (amount == 0) revert InvalidAmount();

        Balance storage fromBalance = balances[fromHash][token];

        if (fromBalance.amount < amount) revert InsufficientBalance();

        // Debit from source
        fromBalance.amount -= amount;
        fromBalance.lastUpdated = block.timestamp;

        // Credit to destination
        Balance storage toBalance = balances[toHash][token];
        toBalance.token = token;
        toBalance.amount += amount;
        toBalance.lastUpdated = block.timestamp;
        toBalance.active = true;

        // Record transactions
        fromTxId = _recordTransaction(fromHash, token, amount, TransactionType.TRANSFER, bytes32(0));
        toTxId = _recordTransaction(toHash, token, amount, TransactionType.TRANSFER, fromTxId);

        // Link transactions
        transactions[fromTxId].relatedTxId = toTxId;

        // casting to 'int256' is safe because amount is bounded by token supply which fits in int256
        // forge-lint: disable-next-line(unsafe-typecast)
        emit BalanceUpdated(fromHash, token, fromBalance.amount, -int256(amount));
        // forge-lint: disable-next-line(unsafe-typecast)
        emit BalanceUpdated(toHash, token, toBalance.amount, int256(amount));
    }

    /**
     * @notice Record a fee deduction
     * @param stealthAddressHash The stealth address hash
     * @param token The token address
     * @param amount The fee amount
     * @return txId The transaction ID
     */
    function recordFee(bytes32 stealthAddressHash, address token, uint256 amount)
        external
        onlyAuthorizedVault
        whenNotPaused
        returns (bytes32 txId)
    {
        if (stealthAddressHash == bytes32(0)) revert InvalidStealthAddress();
        if (amount == 0) revert InvalidAmount();

        Balance storage balance = balances[stealthAddressHash][token];

        if (balance.amount < amount) revert InsufficientBalance();

        balance.amount -= amount;
        balance.lastUpdated = block.timestamp;

        totalBalances[token] -= amount;

        txId = _recordTransaction(stealthAddressHash, token, amount, TransactionType.FEE, bytes32(0));

        // casting to 'int256' is safe because amount is bounded by token supply which fits in int256
        // forge-lint: disable-next-line(unsafe-typecast)
        emit BalanceUpdated(stealthAddressHash, token, balance.amount, -int256(amount));
    }

    /**
     * @notice Internal function to record a transaction
     */
    function _recordTransaction(
        bytes32 stealthAddressHash,
        address token,
        uint256 amount,
        TransactionType txType,
        bytes32 relatedTxId
    ) internal returns (bytes32 txId) {
        txId = keccak256(abi.encodePacked(stealthAddressHash, token, amount, txType, block.timestamp, transactionCount));

        transactions[txId] = Transaction({
            stealthAddressHash: stealthAddressHash,
            token: token,
            amount: amount,
            txType: txType,
            timestamp: block.timestamp,
            relatedTxId: relatedTxId
        });

        stealthTransactions[stealthAddressHash].push(txId);
        transactionCount++;

        emit TransactionRecorded(txId, stealthAddressHash, txType, amount);
    }

    /* //////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Get balance for a stealth address and token
     * @param stealthAddressHash The stealth address hash
     * @param token The token address
     * @return balance The balance details
     */
    function getBalance(bytes32 stealthAddressHash, address token) external view returns (Balance memory) {
        return balances[stealthAddressHash][token];
    }

    /**
     * @notice Get transaction details
     * @param txId The transaction ID
     * @return transaction The transaction details
     */
    function getTransaction(bytes32 txId) external view returns (Transaction memory) {
        return transactions[txId];
    }

    /**
     * @notice Get all transactions for a stealth address
     * @param stealthAddressHash The stealth address hash
     * @return txIds Array of transaction IDs
     */
    function getStealthTransactions(bytes32 stealthAddressHash) external view returns (bytes32[] memory) {
        return stealthTransactions[stealthAddressHash];
    }

    /**
     * @notice Get transaction count for a stealth address
     * @param stealthAddressHash The stealth address hash
     * @return count The number of transactions
     */
    function getTransactionCount(bytes32 stealthAddressHash) external view returns (uint256) {
        return stealthTransactions[stealthAddressHash].length;
    }

    /**
     * @notice Get transactions with pagination
     * @param stealthAddressHash The stealth address hash
     * @param offset The starting index
     * @param limit The maximum number of transactions to return
     * @return txIds Array of transaction IDs
     */
    function getTransactionsPaginated(bytes32 stealthAddressHash, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory txIds)
    {
        bytes32[] storage allTxIds = stealthTransactions[stealthAddressHash];
        uint256 total = allTxIds.length;

        if (offset >= total) {
            return new bytes32[](0);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        txIds = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            txIds[i - offset] = allTxIds[i];
        }
    }

    /* //////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Authorize a vault to update balances
     * @param vault The vault address
     * @param authorized Whether the vault is authorized
     */
    function setVaultAuthorization(address vault, bool authorized) external onlyRole(LEDGER_ADMIN_ROLE) {
        authorizedVaults[vault] = authorized;
        emit VaultAuthorized(vault, authorized);
    }

    /**
     * @notice Pause the ledger
     */
    function pause() external onlyRole(LEDGER_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the ledger
     */
    function unpause() external onlyRole(LEDGER_ADMIN_ROLE) {
        _unpause();
    }
}
