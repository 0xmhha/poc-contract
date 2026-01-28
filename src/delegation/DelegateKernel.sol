// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IDelegationRegistry } from "./DelegationRegistry.sol";

/**
 * @title IDelegateKernel
 * @notice Interface for the EIP-7702 Delegate Kernel
 */
interface IDelegateKernel {
    /* //////////////////////////////////////////////////////////////
                                 STRUCTS
    ////////////////////////////////////////////////////////////// */

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    struct ExecutionResult {
        bool success;
        bytes returnData;
    }

    /* //////////////////////////////////////////////////////////////
                                 EVENTS
    ////////////////////////////////////////////////////////////// */

    event Initialized(address indexed owner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DelegatedExecution(
        bytes32 indexed delegationId,
        address indexed delegatee,
        address indexed target,
        uint256 value
    );
    event BatchExecuted(uint256 callCount, uint256 successCount);
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event RecoveryInitiated(address indexed newOwner, uint256 executeAfter);
    event RecoveryCancelled();
    event RecoveryExecuted(address indexed newOwner);

    /* //////////////////////////////////////////////////////////////
                                 ERRORS
    ////////////////////////////////////////////////////////////// */

    error AlreadyInitialized();
    error NotInitialized();
    error Unauthorized();
    error InvalidOwner();
    error InvalidTarget();
    error ExecutionFailed();
    error InvalidDelegation();
    error DelegationExpired();
    error SelectorNotAllowed();
    error InsufficientBalance();
    error InvalidGuardian();
    error RecoveryNotInitiated();
    error RecoveryDelayNotPassed();
    error RecoveryAlreadyInitiated();
}

/**
 * @title DelegateKernel
 * @notice EIP-7702 compliant Smart Account with delegation support
 * @dev Designed to be set as the code for an EOA via EIP-7702 delegation
 *
 * EIP-7702 allows EOAs to temporarily delegate their code to a contract.
 * This contract provides:
 *   - Owner-based access control (EOA owner)
 *   - Delegation-based execution via DelegationRegistry
 *   - Batch execution support
 *   - Guardian-based recovery
 *   - ERC-1271 signature validation
 *
 * Usage:
 *   1. EOA signs EIP-7702 authorization pointing to this contract
 *   2. Transaction includes the authorization
 *   3. EOA gains smart account capabilities for that transaction
 */
contract DelegateKernel is IDelegateKernel, ReentrancyGuard {
    using ECDSA for bytes32;

    /* //////////////////////////////////////////////////////////////
                              CONSTANTS
    ////////////////////////////////////////////////////////////// */

    /// @notice EIP-1271 magic value
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0x1626ba7e;

    /// @notice Recovery delay (48 hours)
    uint256 public constant RECOVERY_DELAY = 48 hours;

    /// @notice Minimum guardians required for recovery
    uint256 public constant MIN_GUARDIANS_FOR_RECOVERY = 2;

    /* //////////////////////////////////////////////////////////////
                            STATE VARIABLES
    ////////////////////////////////////////////////////////////// */

    /// @notice The owner of this account (typically the EOA address)
    address public owner;

    /// @notice Whether the account has been initialized
    bool public initialized;

    /// @notice The delegation registry contract
    IDelegationRegistry public delegationRegistry;

    /// @notice Guardians who can initiate recovery
    mapping(address guardian => bool) public guardians;

    /// @notice Number of guardians
    uint256 public guardianCount;

    /// @notice Recovery state
    address public pendingRecoveryOwner;
    uint256 public recoveryInitiatedAt;

    /// @notice Nonce for replay protection
    uint256 public nonce;

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Constructor - sets immutable delegation registry
     * @dev In EIP-7702 context, this code is delegated to, so constructor runs once at deployment
     */
    constructor() {
        // Prevent implementation from being initialized
        initialized = true;
    }

    /* //////////////////////////////////////////////////////////////
                            INITIALIZATION
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Initialize the account with an owner
     * @param _owner The owner address (typically msg.sender for EIP-7702)
     * @param _delegationRegistry The delegation registry address
     */
    function initialize(address _owner, address _delegationRegistry) external {
        if (initialized) revert AlreadyInitialized();
        if (_owner == address(0)) revert InvalidOwner();

        owner = _owner;
        delegationRegistry = IDelegationRegistry(_delegationRegistry);
        initialized = true;

        emit Initialized(_owner);
    }

    /**
     * @notice Initialize the account for EIP-7702 context
     * @dev In EIP-7702, the EOA address becomes the owner
     * @param _delegationRegistry The delegation registry address
     */
    function initializeEIP7702(address _delegationRegistry) external {
        if (initialized) revert AlreadyInitialized();

        // In EIP-7702 context, address(this) is the EOA
        owner = address(this);
        delegationRegistry = IDelegationRegistry(_delegationRegistry);
        initialized = true;

        emit Initialized(address(this));
    }

    /* //////////////////////////////////////////////////////////////
                              MODIFIERS
    ////////////////////////////////////////////////////////////// */

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyInitialized() {
        if (!initialized) revert NotInitialized();
        _;
    }

    /* //////////////////////////////////////////////////////////////
                          EXECUTION FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Execute a single call
     * @param target The target address
     * @param value The ETH value to send
     * @param data The calldata
     * @return result The execution result
     */
    function execute(address target, uint256 value, bytes calldata data)
        external
        payable
        onlyOwner
        onlyInitialized
        nonReentrant
        returns (bytes memory result)
    {
        return _execute(target, value, data);
    }

    /**
     * @notice Execute a batch of calls
     * @param calls Array of calls to execute
     * @return results Array of execution results
     */
    function executeBatch(Call[] calldata calls)
        external
        payable
        onlyOwner
        onlyInitialized
        nonReentrant
        returns (ExecutionResult[] memory results)
    {
        results = new ExecutionResult[](calls.length);
        uint256 successCount = 0;

        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory returnData) = calls[i].target.call{ value: calls[i].value }(
                calls[i].data
            );
            results[i] = ExecutionResult({ success: success, returnData: returnData });
            if (success) successCount++;
        }

        emit BatchExecuted(calls.length, successCount);
        return results;
    }

    /**
     * @notice Execute via delegation
     * @param delegationId The delegation ID from DelegationRegistry
     * @param target The target address
     * @param value The ETH value to send
     * @param data The calldata
     * @return result The execution result
     */
    function executeWithDelegation(
        bytes32 delegationId,
        address target,
        uint256 value,
        bytes calldata data
    )
        external
        payable
        onlyInitialized
        nonReentrant
        returns (bytes memory result)
    {
        // Validate delegation
        IDelegationRegistry.Delegation memory delegation = delegationRegistry.getDelegation(
            delegationId
        );

        if (delegation.delegator != owner) revert InvalidDelegation();
        if (delegation.delegatee != msg.sender) revert Unauthorized();
        if (
            delegation.status != IDelegationRegistry.DelegationStatus.ACTIVE
        ) revert InvalidDelegation();
        if (block.timestamp > delegation.endTime) revert DelegationExpired();

        // Check selector permission for LIMITED delegations
        if (delegation.delegationType == IDelegationRegistry.DelegationType.LIMITED) {
            bytes4 selector = bytes4(data[:4]);
            if (!delegationRegistry.isDelegationValidForSelector(delegationId, selector)) {
                revert SelectorNotAllowed();
            }
        }

        // Record spending if value > 0
        if (value > 0) {
            delegationRegistry.useDelegation(delegationId, value);
        }

        emit DelegatedExecution(delegationId, msg.sender, target, value);

        return _execute(target, value, data);
    }

    /**
     * @notice Internal execute function
     */
    function _execute(address target, uint256 value, bytes calldata data)
        internal
        returns (bytes memory result)
    {
        if (target == address(0)) revert InvalidTarget();
        if (value > address(this).balance) revert InsufficientBalance();

        (bool success, bytes memory returnData) = target.call{ value: value }(data);
        if (!success) {
            // Bubble up revert reason
            if (returnData.length > 0) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }
            revert ExecutionFailed();
        }

        return returnData;
    }

    /* //////////////////////////////////////////////////////////////
                          SIGNATURE VALIDATION
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice EIP-1271 signature validation
     * @param hash The hash that was signed
     * @param signature The signature bytes
     * @return magicValue EIP-1271 magic value if valid
     */
    function isValidSignature(bytes32 hash, bytes calldata signature)
        external
        view
        returns (bytes4 magicValue)
    {
        address signer = hash.recover(signature);

        if (signer == owner) {
            return EIP1271_MAGIC_VALUE;
        }

        // Check if signer has a valid delegation
        if (address(delegationRegistry) != address(0)) {
            if (delegationRegistry.hasDelegation(owner, signer)) {
                return EIP1271_MAGIC_VALUE;
            }
        }

        return bytes4(0);
    }

    /* //////////////////////////////////////////////////////////////
                          GUARDIAN MANAGEMENT
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Add a guardian
     * @param guardian The guardian address to add
     */
    function addGuardian(address guardian) external onlyOwner onlyInitialized {
        if (guardian == address(0) || guardian == owner) revert InvalidGuardian();
        if (guardians[guardian]) revert InvalidGuardian();

        guardians[guardian] = true;
        guardianCount++;

        emit GuardianAdded(guardian);
    }

    /**
     * @notice Remove a guardian
     * @param guardian The guardian address to remove
     */
    function removeGuardian(address guardian) external onlyOwner onlyInitialized {
        if (!guardians[guardian]) revert InvalidGuardian();

        guardians[guardian] = false;
        guardianCount--;

        emit GuardianRemoved(guardian);
    }

    /* //////////////////////////////////////////////////////////////
                          RECOVERY FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Initiate recovery (guardian only)
     * @param newOwner The new owner address
     */
    function initiateRecovery(address newOwner) external onlyInitialized {
        if (!guardians[msg.sender]) revert Unauthorized();
        if (newOwner == address(0)) revert InvalidOwner();
        if (pendingRecoveryOwner != address(0)) revert RecoveryAlreadyInitiated();
        if (guardianCount < MIN_GUARDIANS_FOR_RECOVERY) revert Unauthorized();

        pendingRecoveryOwner = newOwner;
        recoveryInitiatedAt = block.timestamp;

        emit RecoveryInitiated(newOwner, block.timestamp + RECOVERY_DELAY);
    }

    /**
     * @notice Cancel recovery (owner only)
     */
    function cancelRecovery() external onlyOwner onlyInitialized {
        if (pendingRecoveryOwner == address(0)) revert RecoveryNotInitiated();

        pendingRecoveryOwner = address(0);
        recoveryInitiatedAt = 0;

        emit RecoveryCancelled();
    }

    /**
     * @notice Execute recovery after delay
     */
    function executeRecovery() external onlyInitialized {
        if (pendingRecoveryOwner == address(0)) revert RecoveryNotInitiated();
        if (block.timestamp < recoveryInitiatedAt + RECOVERY_DELAY) {
            revert RecoveryDelayNotPassed();
        }

        address previousOwner = owner;
        address newOwner = pendingRecoveryOwner;

        owner = newOwner;
        pendingRecoveryOwner = address(0);
        recoveryInitiatedAt = 0;

        emit OwnershipTransferred(previousOwner, newOwner);
        emit RecoveryExecuted(newOwner);
    }

    /* //////////////////////////////////////////////////////////////
                          OWNERSHIP FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Transfer ownership
     * @param newOwner The new owner address
     */
    function transferOwnership(address newOwner) external onlyOwner onlyInitialized {
        if (newOwner == address(0)) revert InvalidOwner();

        address previousOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /* //////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Check if an address is a guardian
     * @param account The address to check
     * @return isGuardian True if the address is a guardian
     */
    function isGuardian(address account) external view returns (bool) {
        return guardians[account];
    }

    /**
     * @notice Get recovery info
     * @return pendingOwner The pending recovery owner
     * @return initiatedAt When recovery was initiated
     * @return canExecuteAt When recovery can be executed
     */
    function getRecoveryInfo()
        external
        view
        returns (address pendingOwner, uint256 initiatedAt, uint256 canExecuteAt)
    {
        return (
            pendingRecoveryOwner,
            recoveryInitiatedAt,
            recoveryInitiatedAt > 0 ? recoveryInitiatedAt + RECOVERY_DELAY : 0
        );
    }

    /* //////////////////////////////////////////////////////////////
                          RECEIVE / FALLBACK
    ////////////////////////////////////////////////////////////// */

    receive() external payable { }

    fallback() external payable { }
}
