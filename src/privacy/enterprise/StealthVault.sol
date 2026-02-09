// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IStealthVault
 * @notice Interface for Enterprise Stealth Vault
 */
interface IStealthVault {
    /* //////////////////////////////////////////////////////////////
                                 STRUCTS
    ////////////////////////////////////////////////////////////// */

    struct Deposit {
        address depositor;
        address token;
        uint256 amount;
        bytes32 stealthAddress; // Hashed stealth address for privacy
        uint256 timestamp;
        bool withdrawn;
    }

    /* //////////////////////////////////////////////////////////////
                                 EVENTS
    ////////////////////////////////////////////////////////////// */

    event StealthDeposit(
        bytes32 indexed depositId,
        address indexed depositor,
        address indexed token,
        uint256 amount,
        bytes32 stealthAddressHash
    );

    event StealthWithdrawal(bytes32 indexed depositId, address indexed recipient, uint256 amount);

    event EmergencyWithdrawal(
        bytes32 indexed depositId, address indexed admin, address indexed recipient, uint256 amount
    );

    /* //////////////////////////////////////////////////////////////
                                 ERRORS
    ////////////////////////////////////////////////////////////// */

    error InvalidAmount();
    error InvalidStealthAddress();
    error DepositNotFound();
    error AlreadyWithdrawn();
    error InvalidProof();
    error Unauthorized();
    error TransferFailed();
}

/**
 * @title StealthVault
 * @notice Enterprise-grade vault for stealth address deposits
 * @dev Provides secure deposit/withdrawal with privacy-preserving stealth addresses
 *
 * Features:
 *   - Multi-token support (ETH + ERC20)
 *   - Stealth address-based deposits
 *   - Role-based access control
 *   - Emergency withdrawal capability
 *   - Audit logging integration
 */
contract StealthVault is IStealthVault, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* //////////////////////////////////////////////////////////////
                                 ROLES
    ////////////////////////////////////////////////////////////// */

    bytes32 public constant VAULT_ADMIN_ROLE = keccak256("VAULT_ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /* //////////////////////////////////////////////////////////////
                              CONSTANTS
    ////////////////////////////////////////////////////////////// */

    /// @notice Address representing native ETH
    address public constant NATIVE_TOKEN = address(0);

    /// @notice Maximum deposit amount (1M tokens with 18 decimals)
    uint256 public constant MAX_DEPOSIT = 1_000_000 ether;

    /* //////////////////////////////////////////////////////////////
                            STATE VARIABLES
    ////////////////////////////////////////////////////////////// */

    /// @notice Mapping from deposit ID to Deposit struct
    mapping(bytes32 depositId => Deposit) public deposits;

    /// @notice Mapping from stealth address hash to deposit IDs
    mapping(bytes32 stealthHash => bytes32[]) public stealthDeposits;

    /// @notice Mapping from depositor to their deposit IDs
    mapping(address depositor => bytes32[]) public depositorDeposits;

    /// @notice Total deposits by token
    mapping(address token => uint256) public totalDeposits;

    /// @notice Total deposit count
    uint256 public depositCount;

    /// @notice Stealth Ledger contract for balance tracking
    address public stealthLedger;

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    ////////////////////////////////////////////////////////////// */

    constructor(address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(VAULT_ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
    }

    /* //////////////////////////////////////////////////////////////
                          DEPOSIT FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Deposit native ETH to a stealth address
     * @param stealthAddressHash The hash of the stealth address
     * @return depositId The unique deposit ID
     */
    // depositETH follows the standard naming convention for ETH deposit functions
    // forge-lint: disable-next-line(mixed-case-function)
    function depositETH(bytes32 stealthAddressHash)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (bytes32 depositId)
    {
        if (msg.value == 0 || msg.value > MAX_DEPOSIT) revert InvalidAmount();
        if (stealthAddressHash == bytes32(0)) revert InvalidStealthAddress();

        depositId = _createDeposit(msg.sender, NATIVE_TOKEN, msg.value, stealthAddressHash);

        emit StealthDeposit(depositId, msg.sender, NATIVE_TOKEN, msg.value, stealthAddressHash);
    }

    /**
     * @notice Deposit ERC20 tokens to a stealth address
     * @param token The token address
     * @param amount The amount to deposit
     * @param stealthAddressHash The hash of the stealth address
     * @return depositId The unique deposit ID
     */
    function depositToken(address token, uint256 amount, bytes32 stealthAddressHash)
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 depositId)
    {
        if (token == address(0)) revert InvalidAmount();
        if (amount == 0 || amount > MAX_DEPOSIT) revert InvalidAmount();
        if (stealthAddressHash == bytes32(0)) revert InvalidStealthAddress();

        // Transfer tokens to vault
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        depositId = _createDeposit(msg.sender, token, amount, stealthAddressHash);

        emit StealthDeposit(depositId, msg.sender, token, amount, stealthAddressHash);
    }

    /**
     * @notice Internal function to create a deposit record
     */
    function _createDeposit(address depositor, address token, uint256 amount, bytes32 stealthAddressHash)
        internal
        returns (bytes32 depositId)
    {
        depositId = keccak256(
            abi.encodePacked(depositor, token, amount, stealthAddressHash, block.timestamp, depositCount)
        );

        deposits[depositId] = Deposit({
            depositor: depositor,
            token: token,
            amount: amount,
            stealthAddress: stealthAddressHash,
            timestamp: block.timestamp,
            withdrawn: false
        });

        stealthDeposits[stealthAddressHash].push(depositId);
        depositorDeposits[depositor].push(depositId);
        totalDeposits[token] += amount;
        depositCount++;
    }

    /* //////////////////////////////////////////////////////////////
                         WITHDRAWAL FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Withdraw funds using stealth proof
     * @param depositId The deposit ID to withdraw
     * @param recipient The recipient address
     * @param proof The stealth proof (signature proving ownership of stealth address)
     */
    function withdraw(bytes32 depositId, address recipient, bytes calldata proof) external whenNotPaused nonReentrant {
        Deposit storage deposit = deposits[depositId];

        if (deposit.depositor == address(0)) revert DepositNotFound();
        if (deposit.withdrawn) revert AlreadyWithdrawn();

        // Verify proof (simplified - in production, use proper stealth address verification)
        if (!_verifyStealthProof(deposit.stealthAddress, recipient, proof)) {
            revert InvalidProof();
        }

        deposit.withdrawn = true;
        totalDeposits[deposit.token] -= deposit.amount;

        // Transfer funds
        if (deposit.token == NATIVE_TOKEN) {
            (bool success,) = recipient.call{ value: deposit.amount }("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(deposit.token).safeTransfer(recipient, deposit.amount);
        }

        emit StealthWithdrawal(depositId, recipient, deposit.amount);
    }

    /**
     * @notice Verify stealth proof
     * @dev Simplified implementation - in production, implement proper stealth address verification
     */
    function _verifyStealthProof(bytes32 stealthHash, address recipient, bytes calldata proof)
        internal
        pure
        returns (bool)
    {
        // Simplified verification: proof must be the pre-image that hashes to stealthHash
        // In production, this would verify the stealth address derivation
        if (proof.length < 20) return false;

        bytes32 computedHash = keccak256(abi.encodePacked(recipient, proof));
        return computedHash == stealthHash;
    }

    /* //////////////////////////////////////////////////////////////
                         EMERGENCY FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Emergency withdraw (admin only)
     * @param depositId The deposit ID
     * @param recipient The recipient address
     */
    function emergencyWithdraw(bytes32 depositId, address recipient) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        Deposit storage deposit = deposits[depositId];

        if (deposit.depositor == address(0)) revert DepositNotFound();
        if (deposit.withdrawn) revert AlreadyWithdrawn();

        deposit.withdrawn = true;
        totalDeposits[deposit.token] -= deposit.amount;

        // Transfer funds
        if (deposit.token == NATIVE_TOKEN) {
            (bool success,) = recipient.call{ value: deposit.amount }("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(deposit.token).safeTransfer(recipient, deposit.amount);
        }

        emit EmergencyWithdrawal(depositId, msg.sender, recipient, deposit.amount);
    }

    /* //////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Get deposit details
     * @param depositId The deposit ID
     * @return deposit The deposit details
     */
    function getDeposit(bytes32 depositId) external view returns (Deposit memory) {
        return deposits[depositId];
    }

    /**
     * @notice Get deposits by stealth address hash
     * @param stealthHash The stealth address hash
     * @return depositIds Array of deposit IDs
     */
    function getStealthDeposits(bytes32 stealthHash) external view returns (bytes32[] memory) {
        return stealthDeposits[stealthHash];
    }

    /**
     * @notice Get deposits by depositor
     * @param depositor The depositor address
     * @return depositIds Array of deposit IDs
     */
    function getDepositorDeposits(address depositor) external view returns (bytes32[] memory) {
        return depositorDeposits[depositor];
    }

    /**
     * @notice Get total balance for a token
     * @param token The token address (address(0) for ETH)
     * @return balance The total balance
     */
    function getTotalBalance(address token) external view returns (uint256) {
        return totalDeposits[token];
    }

    /* //////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Set the stealth ledger address
     * @param _stealthLedger The stealth ledger address
     */
    function setStealthLedger(address _stealthLedger) external onlyRole(VAULT_ADMIN_ROLE) {
        stealthLedger = _stealthLedger;
    }

    /**
     * @notice Pause the vault
     */
    function pause() external onlyRole(VAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the vault
     */
    function unpause() external onlyRole(VAULT_ADMIN_ROLE) {
        _unpause();
    }

    /* //////////////////////////////////////////////////////////////
                          RECEIVE / FALLBACK
    ////////////////////////////////////////////////////////////// */

    receive() external payable { }
}
