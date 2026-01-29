// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title IDelegationRegistry
 * @notice Interface for the Delegation Registry
 */
interface IDelegationRegistry {
    /* //////////////////////////////////////////////////////////////
                                 ENUMS
    ////////////////////////////////////////////////////////////// */

    enum DelegationStatus {
        INACTIVE,
        ACTIVE,
        REVOKED,
        EXPIRED
    }

    enum DelegationType {
        FULL,           // Full account control
        EXECUTOR,       // Can execute transactions
        VALIDATOR,      // Can validate operations
        LIMITED         // Limited permissions (specific selectors)
    }

    /* //////////////////////////////////////////////////////////////
                                 STRUCTS
    ////////////////////////////////////////////////////////////// */

    struct Delegation {
        address delegator;
        address delegatee;
        DelegationType delegationType;
        DelegationStatus status;
        uint256 startTime;
        uint256 endTime;
        uint256 spendingLimit;
        uint256 spentAmount;
        bytes4[] allowedSelectors;
    }

    struct DelegationParams {
        address delegatee;
        DelegationType delegationType;
        uint256 duration;
        uint256 spendingLimit;
        bytes4[] allowedSelectors;
    }

    /* //////////////////////////////////////////////////////////////
                                 EVENTS
    ////////////////////////////////////////////////////////////// */

    event DelegationCreated(
        bytes32 indexed delegationId,
        address indexed delegator,
        address indexed delegatee,
        DelegationType delegationType,
        uint256 endTime
    );

    event DelegationRevoked(bytes32 indexed delegationId, address indexed revokedBy);

    event DelegationUsed(
        bytes32 indexed delegationId,
        address indexed delegatee,
        uint256 amount
    );

    event DelegationExpired(bytes32 indexed delegationId);

    /* //////////////////////////////////////////////////////////////
                                 ERRORS
    ////////////////////////////////////////////////////////////// */

    error InvalidDelegatee();
    error InvalidDuration();
    error DelegationNotFound();
    error DelegationNotActive();
    error DelegationExpiredError();
    error UnauthorizedDelegatee();
    error SpendingLimitExceeded();
    error SelectorNotAllowed();
    error InvalidSignature();
    error DelegationAlreadyExists();

    /* //////////////////////////////////////////////////////////////
                                FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    function getDelegation(bytes32 delegationId) external view returns (Delegation memory);
    function isDelegationValidForSelector(bytes32 delegationId, bytes4 selector) external view returns (bool isValid);
    function useDelegation(bytes32 delegationId, uint256 amount) external;
    function hasDelegation(address delegator, address delegatee) external view returns (bool hasActiveDelegation);
}

/**
 * @title DelegationRegistry
 * @notice Registry for managing EIP-7702 delegations
 * @dev Allows accounts to delegate control to other addresses with configurable permissions
 *
 * Features:
 *   - Multiple delegation types (Full, Executor, Validator, Limited)
 *   - Time-bound delegations with expiry
 *   - Spending limits per delegation
 *   - Selector-based access control for Limited delegations
 *   - Signature-based delegation creation (meta-transactions)
 *   - Multi-delegation support per account
 */
contract DelegationRegistry is IDelegationRegistry, AccessControl, Pausable, ReentrancyGuard, EIP712 {
    using ECDSA for bytes32;

    /* //////////////////////////////////////////////////////////////
                                 ROLES
    ////////////////////////////////////////////////////////////// */

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /* //////////////////////////////////////////////////////////////
                              CONSTANTS
    ////////////////////////////////////////////////////////////// */

    /// @notice Maximum delegation duration (365 days)
    uint256 public constant MAX_DELEGATION_DURATION = 365 days;

    /// @notice Minimum delegation duration (1 hour)
    uint256 public constant MIN_DELEGATION_DURATION = 1 hours;

    /// @notice EIP-712 type hash for delegation creation
    bytes32 public constant DELEGATION_TYPEHASH = keccak256(
        "Delegation(address delegator,address delegatee,uint8 delegationType,uint256 duration,uint256 spendingLimit,uint256 nonce)"
    );

    /* //////////////////////////////////////////////////////////////
                            STATE VARIABLES
    ////////////////////////////////////////////////////////////// */

    /// @notice Mapping from delegation ID to Delegation struct
    mapping(bytes32 delegationId => Delegation) public delegations;

    /// @notice Mapping from delegator to their delegation IDs
    mapping(address delegator => bytes32[]) public delegatorDelegations;

    /// @notice Mapping from delegatee to delegations they received
    mapping(address delegatee => bytes32[]) public delegateeDelegations;

    /// @notice Nonce for each delegator (for signature replay protection)
    mapping(address delegator => uint256) public nonces;

    /// @notice Total number of delegations created
    uint256 public totalDelegations;

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    ////////////////////////////////////////////////////////////// */

    constructor() EIP712("DelegationRegistry", "1") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /* //////////////////////////////////////////////////////////////
                          DELEGATION MANAGEMENT
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Create a new delegation
     * @param params Delegation parameters
     * @return delegationId The unique ID of the created delegation
     */
    function createDelegation(DelegationParams calldata params)
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 delegationId)
    {
        return _createDelegation(msg.sender, params);
    }

    /**
     * @notice Create a delegation on behalf of another account using a signature
     * @param delegator The account granting the delegation
     * @param params Delegation parameters
     * @param signature EIP-712 signature from the delegator
     * @return delegationId The unique ID of the created delegation
     */
    function createDelegationWithSignature(
        address delegator,
        DelegationParams calldata params,
        bytes calldata signature
    )
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 delegationId)
    {
        // Verify signature
        bytes32 structHash = keccak256(
            abi.encode(
                DELEGATION_TYPEHASH,
                delegator,
                params.delegatee,
                uint8(params.delegationType),
                params.duration,
                params.spendingLimit,
                nonces[delegator]++
            )
        );

        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = hash.recover(signature);

        if (signer != delegator) {
            revert InvalidSignature();
        }

        return _createDelegation(delegator, params);
    }

    /**
     * @notice Internal function to create a delegation
     */
    function _createDelegation(address delegator, DelegationParams calldata params)
        internal
        returns (bytes32 delegationId)
    {
        // Validate parameters
        if (params.delegatee == address(0) || params.delegatee == delegator) {
            revert InvalidDelegatee();
        }
        if (params.duration < MIN_DELEGATION_DURATION || params.duration > MAX_DELEGATION_DURATION) {
            revert InvalidDuration();
        }

        // Generate unique delegation ID
        delegationId = keccak256(
            abi.encodePacked(delegator, params.delegatee, block.timestamp, totalDelegations)
        );

        // Check if delegation already exists
        if (delegations[delegationId].delegator != address(0)) {
            revert DelegationAlreadyExists();
        }

        // Create delegation
        uint256 endTime = block.timestamp + params.duration;

        delegations[delegationId] = Delegation({
            delegator: delegator,
            delegatee: params.delegatee,
            delegationType: params.delegationType,
            status: DelegationStatus.ACTIVE,
            startTime: block.timestamp,
            endTime: endTime,
            spendingLimit: params.spendingLimit,
            spentAmount: 0,
            allowedSelectors: params.allowedSelectors
        });

        // Update mappings
        delegatorDelegations[delegator].push(delegationId);
        delegateeDelegations[params.delegatee].push(delegationId);
        totalDelegations++;

        emit DelegationCreated(
            delegationId,
            delegator,
            params.delegatee,
            params.delegationType,
            endTime
        );
    }

    /**
     * @notice Revoke a delegation
     * @param delegationId The ID of the delegation to revoke
     */
    function revokeDelegation(bytes32 delegationId) external whenNotPaused {
        Delegation storage delegation = delegations[delegationId];

        if (delegation.delegator == address(0)) {
            revert DelegationNotFound();
        }

        // Only delegator or admin can revoke
        if (msg.sender != delegation.delegator && !hasRole(ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedDelegatee();
        }

        if (delegation.status != DelegationStatus.ACTIVE) {
            revert DelegationNotActive();
        }

        delegation.status = DelegationStatus.REVOKED;

        emit DelegationRevoked(delegationId, msg.sender);
    }

    /**
     * @notice Use a delegation (record spending)
     * @param delegationId The ID of the delegation
     * @param amount The amount being spent
     */
    function useDelegation(bytes32 delegationId, uint256 amount) external whenNotPaused nonReentrant {
        Delegation storage delegation = delegations[delegationId];

        if (delegation.delegator == address(0)) {
            revert DelegationNotFound();
        }

        if (msg.sender != delegation.delegatee) {
            revert UnauthorizedDelegatee();
        }

        if (delegation.status != DelegationStatus.ACTIVE) {
            revert DelegationNotActive();
        }

        if (block.timestamp > delegation.endTime) {
            delegation.status = DelegationStatus.EXPIRED;
            emit DelegationExpired(delegationId);
            revert DelegationExpiredError();
        }

        if (delegation.spendingLimit > 0 && delegation.spentAmount + amount > delegation.spendingLimit) {
            revert SpendingLimitExceeded();
        }

        delegation.spentAmount += amount;

        emit DelegationUsed(delegationId, msg.sender, amount);
    }

    /* //////////////////////////////////////////////////////////////
                            VALIDATION FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Check if a delegation is valid for a given selector
     * @param delegationId The ID of the delegation
     * @param selector The function selector to check
     * @return isValid True if the delegation is valid for the selector
     */
    function isDelegationValidForSelector(bytes32 delegationId, bytes4 selector)
        external
        view
        returns (bool isValid)
    {
        Delegation storage delegation = delegations[delegationId];

        if (delegation.delegator == address(0)) {
            return false;
        }

        if (delegation.status != DelegationStatus.ACTIVE) {
            return false;
        }

        if (block.timestamp > delegation.endTime) {
            return false;
        }

        // Full and Executor delegations allow all selectors
        if (
            delegation.delegationType == DelegationType.FULL ||
            delegation.delegationType == DelegationType.EXECUTOR
        ) {
            return true;
        }

        // Limited delegations check allowed selectors
        if (delegation.delegationType == DelegationType.LIMITED) {
            for (uint256 i = 0; i < delegation.allowedSelectors.length; i++) {
                if (delegation.allowedSelectors[i] == selector) {
                    return true;
                }
            }
            return false;
        }

        return false;
    }

    /**
     * @notice Check if an address has an active delegation from a delegator
     * @param delegator The delegator address
     * @param delegatee The delegatee address
     * @return hasActiveDelegation True if an active delegation exists
     */
    function hasDelegation(address delegator, address delegatee)
        external
        view
        returns (bool hasActiveDelegation)
    {
        bytes32[] storage delegationIds = delegatorDelegations[delegator];

        for (uint256 i = 0; i < delegationIds.length; i++) {
            Delegation storage delegation = delegations[delegationIds[i]];
            if (
                delegation.delegatee == delegatee &&
                delegation.status == DelegationStatus.ACTIVE &&
                block.timestamp <= delegation.endTime
            ) {
                return true;
            }
        }

        return false;
    }

    /* //////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Get delegation details
     * @param delegationId The ID of the delegation
     * @return delegation The delegation details
     */
    function getDelegation(bytes32 delegationId) external view returns (Delegation memory) {
        return delegations[delegationId];
    }

    /**
     * @notice Get all delegations for a delegator
     * @param delegator The delegator address
     * @return delegationIds Array of delegation IDs
     */
    function getDelegatorDelegations(address delegator) external view returns (bytes32[] memory) {
        return delegatorDelegations[delegator];
    }

    /**
     * @notice Get all delegations for a delegatee
     * @param delegatee The delegatee address
     * @return delegationIds Array of delegation IDs
     */
    function getDelegateeDelegations(address delegatee) external view returns (bytes32[] memory) {
        return delegateeDelegations[delegatee];
    }

    /**
     * @notice Get remaining spending limit for a delegation
     * @param delegationId The ID of the delegation
     * @return remaining The remaining spending amount
     */
    function getRemainingSpendingLimit(bytes32 delegationId) external view returns (uint256 remaining) {
        Delegation storage delegation = delegations[delegationId];

        if (delegation.spendingLimit == 0) {
            return type(uint256).max; // Unlimited
        }

        if (delegation.spentAmount >= delegation.spendingLimit) {
            return 0;
        }

        return delegation.spendingLimit - delegation.spentAmount;
    }

    /* //////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Pause the registry
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the registry
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Force expire a delegation (admin only)
     * @param delegationId The ID of the delegation to expire
     */
    function forceExpireDelegation(bytes32 delegationId) external onlyRole(ADMIN_ROLE) {
        Delegation storage delegation = delegations[delegationId];

        if (delegation.delegator == address(0)) {
            revert DelegationNotFound();
        }

        delegation.status = DelegationStatus.EXPIRED;
        emit DelegationExpired(delegationId);
    }
}
