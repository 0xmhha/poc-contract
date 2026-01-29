// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title IRoleManager
 * @notice Interface for Enterprise Role Manager
 */
interface IRoleManager {
    /* //////////////////////////////////////////////////////////////
                                 STRUCTS
    ////////////////////////////////////////////////////////////// */

    struct RoleInfo {
        bytes32 roleId;
        string name;
        string description;
        uint256 createdAt;
        bool active;
        uint256 memberCount;
    }

    struct RoleAssignment {
        address account;
        bytes32 roleId;
        uint256 assignedAt;
        uint256 expiresAt;
        address assignedBy;
        bool active;
    }

    struct Permission {
        bytes4 selector;
        address target;
        bool allowed;
    }

    /* //////////////////////////////////////////////////////////////
                                 EVENTS
    ////////////////////////////////////////////////////////////// */

    event RoleCreated(
        bytes32 indexed roleId,
        string name,
        address indexed creator
    );

    event RoleUpdated(
        bytes32 indexed roleId,
        string name,
        address indexed updater
    );

    event RoleDeactivated(
        bytes32 indexed roleId,
        address indexed deactivator
    );

    event RoleAssigned(
        bytes32 indexed roleId,
        address indexed account,
        address indexed assigner,
        uint256 expiresAt
    );

    event CustomRoleRevoked(
        bytes32 indexed roleId,
        address indexed account,
        address indexed revoker
    );

    event PermissionGranted(
        bytes32 indexed roleId,
        bytes4 indexed selector,
        address indexed target
    );

    event PermissionRevoked(
        bytes32 indexed roleId,
        bytes4 indexed selector,
        address indexed target
    );

    /* //////////////////////////////////////////////////////////////
                                 ERRORS
    ////////////////////////////////////////////////////////////// */

    error RoleAlreadyExists();
    error RoleNotFound();
    error RoleNotActive();
    error InvalidRoleName();
    error InvalidAccount();
    error AlreadyAssigned();
    error NotAssigned();
    error AssignmentExpired();
    error PermissionDenied();
    error InvalidTarget();
}

/**
 * @title RoleManager
 * @notice Enterprise-grade role-based access control manager
 * @dev Extends OpenZeppelin AccessControl with custom role management features
 *
 * Features:
 *   - Custom role creation with metadata
 *   - Time-bound role assignments
 *   - Fine-grained permission management
 *   - Role hierarchy support
 *   - Audit trail for all role operations
 */
contract RoleManager is IRoleManager, AccessControl, Pausable {
    /* //////////////////////////////////////////////////////////////
                                 ROLES
    ////////////////////////////////////////////////////////////// */

    bytes32 public constant ROLE_ADMIN = keccak256("ROLE_ADMIN");
    bytes32 public constant ROLE_ASSIGNER = keccak256("ROLE_ASSIGNER");
    bytes32 public constant PERMISSION_ADMIN = keccak256("PERMISSION_ADMIN");

    /* //////////////////////////////////////////////////////////////
                            STATE VARIABLES
    ////////////////////////////////////////////////////////////// */

    /// @notice Mapping from role ID to role info
    mapping(bytes32 roleId => RoleInfo) public roles;

    /// @notice Mapping from account to role ID to assignment
    mapping(address account => mapping(bytes32 roleId => RoleAssignment)) public assignments;

    /// @notice Mapping from role ID to account addresses
    mapping(bytes32 roleId => address[]) public roleMembers;

    /// @notice Mapping from role ID to selector to target to permission
    mapping(bytes32 roleId => mapping(bytes4 selector => mapping(address target => bool))) public permissions;

    /// @notice Mapping from role ID to its admin role
    mapping(bytes32 roleId => bytes32) public roleAdmins;

    /// @notice Array of all role IDs
    bytes32[] public allRoles;

    /// @notice Total number of roles
    uint256 public roleCount;

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    ////////////////////////////////////////////////////////////// */

    constructor(address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ROLE_ADMIN, _admin);
        _grantRole(ROLE_ASSIGNER, _admin);
        _grantRole(PERMISSION_ADMIN, _admin);

        // Create default system roles
        _createSystemRole(ROLE_ADMIN, "Role Admin", "Can create and manage roles");
        _createSystemRole(ROLE_ASSIGNER, "Role Assigner", "Can assign roles to accounts");
        _createSystemRole(PERMISSION_ADMIN, "Permission Admin", "Can manage role permissions");
    }

    /* //////////////////////////////////////////////////////////////
                          ROLE MANAGEMENT
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Create a new custom role
     * @param roleId The unique role identifier
     * @param name The role name
     * @param description The role description
     */
    function createRole(
        bytes32 roleId,
        string calldata name,
        string calldata description
    )
        external
        onlyRole(ROLE_ADMIN)
        whenNotPaused
    {
        if (roles[roleId].createdAt != 0) revert RoleAlreadyExists();
        if (bytes(name).length == 0) revert InvalidRoleName();

        roles[roleId] = RoleInfo({
            roleId: roleId,
            name: name,
            description: description,
            createdAt: block.timestamp,
            active: true,
            memberCount: 0
        });

        allRoles.push(roleId);
        roleAdmins[roleId] = ROLE_ADMIN;
        roleCount++;

        emit RoleCreated(roleId, name, msg.sender);
    }

    /**
     * @notice Update role metadata
     * @param roleId The role ID
     * @param name The new role name
     * @param description The new role description
     */
    function updateRole(
        bytes32 roleId,
        string calldata name,
        string calldata description
    )
        external
        onlyRole(ROLE_ADMIN)
        whenNotPaused
    {
        if (roles[roleId].createdAt == 0) revert RoleNotFound();
        if (bytes(name).length == 0) revert InvalidRoleName();

        roles[roleId].name = name;
        roles[roleId].description = description;

        emit RoleUpdated(roleId, name, msg.sender);
    }

    /**
     * @notice Deactivate a role
     * @param roleId The role ID to deactivate
     */
    function deactivateRole(bytes32 roleId)
        external
        onlyRole(ROLE_ADMIN)
        whenNotPaused
    {
        if (roles[roleId].createdAt == 0) revert RoleNotFound();

        roles[roleId].active = false;

        emit RoleDeactivated(roleId, msg.sender);
    }

    /**
     * @notice Set the admin role for a role
     * @param roleId The role ID
     * @param adminRoleId The admin role ID
     */
    function setRoleAdmin(bytes32 roleId, bytes32 adminRoleId)
        external
        onlyRole(ROLE_ADMIN)
    {
        if (roles[roleId].createdAt == 0) revert RoleNotFound();

        roleAdmins[roleId] = adminRoleId;
        _setRoleAdmin(roleId, adminRoleId);
    }

    /**
     * @notice Internal function to create system roles
     */
    function _createSystemRole(bytes32 roleId, string memory name, string memory description) internal {
        roles[roleId] = RoleInfo({
            roleId: roleId,
            name: name,
            description: description,
            createdAt: block.timestamp,
            active: true,
            memberCount: 0
        });

        allRoles.push(roleId);
        roleCount++;
    }

    /* //////////////////////////////////////////////////////////////
                        ROLE ASSIGNMENT
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Assign a role to an account
     * @param roleId The role ID
     * @param account The account address
     * @param expiresAt The expiration timestamp (0 for no expiration)
     */
    function assignRole(
        bytes32 roleId,
        address account,
        uint256 expiresAt
    )
        external
        onlyRole(ROLE_ASSIGNER)
        whenNotPaused
    {
        if (roles[roleId].createdAt == 0) revert RoleNotFound();
        if (!roles[roleId].active) revert RoleNotActive();
        if (account == address(0)) revert InvalidAccount();

        RoleAssignment storage assignment = assignments[account][roleId];

        if (assignment.active) revert AlreadyAssigned();

        assignment.account = account;
        assignment.roleId = roleId;
        assignment.assignedAt = block.timestamp;
        assignment.expiresAt = expiresAt;
        assignment.assignedBy = msg.sender;
        assignment.active = true;

        roleMembers[roleId].push(account);
        roles[roleId].memberCount++;

        // Grant the OpenZeppelin role
        _grantRole(roleId, account);

        emit RoleAssigned(roleId, account, msg.sender, expiresAt);
    }

    /**
     * @notice Revoke a role from an account
     * @param roleId The role ID
     * @param account The account address
     */
    function revokeRoleAssignment(bytes32 roleId, address account)
        external
        onlyRole(ROLE_ASSIGNER)
        whenNotPaused
    {
        RoleAssignment storage assignment = assignments[account][roleId];

        if (!assignment.active) revert NotAssigned();

        assignment.active = false;
        roles[roleId].memberCount--;

        // Revoke the OpenZeppelin role
        _revokeRole(roleId, account);

        emit CustomRoleRevoked(roleId, account, msg.sender);
    }

    /**
     * @notice Check if a role assignment is valid (not expired)
     * @param roleId The role ID
     * @param account The account address
     * @return isValid True if the assignment is valid
     */
    function isAssignmentValid(bytes32 roleId, address account) public view returns (bool) {
        RoleAssignment storage assignment = assignments[account][roleId];

        if (!assignment.active) return false;
        if (assignment.expiresAt != 0 && block.timestamp > assignment.expiresAt) return false;

        return true;
    }

    /**
     * @notice Cleanup expired assignments (callable by anyone)
     * @param roleId The role ID
     * @param account The account to check
     */
    function cleanupExpiredAssignment(bytes32 roleId, address account) external {
        RoleAssignment storage assignment = assignments[account][roleId];

        if (!assignment.active) return;
        if (assignment.expiresAt == 0) return;
        if (block.timestamp <= assignment.expiresAt) return;

        assignment.active = false;
        roles[roleId].memberCount--;

        _revokeRole(roleId, account);

        emit CustomRoleRevoked(roleId, account, address(this));
    }

    /* //////////////////////////////////////////////////////////////
                        PERMISSION MANAGEMENT
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Grant permission to a role for a specific function
     * @param roleId The role ID
     * @param selector The function selector
     * @param target The target contract address
     */
    function grantPermission(
        bytes32 roleId,
        bytes4 selector,
        address target
    )
        external
        onlyRole(PERMISSION_ADMIN)
        whenNotPaused
    {
        if (roles[roleId].createdAt == 0) revert RoleNotFound();
        if (target == address(0)) revert InvalidTarget();

        permissions[roleId][selector][target] = true;

        emit PermissionGranted(roleId, selector, target);
    }

    /**
     * @notice Revoke permission from a role
     * @param roleId The role ID
     * @param selector The function selector
     * @param target The target contract address
     */
    function revokePermission(
        bytes32 roleId,
        bytes4 selector,
        address target
    )
        external
        onlyRole(PERMISSION_ADMIN)
        whenNotPaused
    {
        permissions[roleId][selector][target] = false;

        emit PermissionRevoked(roleId, selector, target);
    }

    /**
     * @notice Check if an account has permission for a specific operation
     * @param account The account address
     * @param selector The function selector
     * @param target The target contract address
     * @return hasPermission True if the account has permission
     */
    function checkPermission(
        address account,
        bytes4 selector,
        address target
    ) external view returns (bool) {
        // Check all roles assigned to the account
        for (uint256 i = 0; i < allRoles.length; i++) {
            bytes32 roleId = allRoles[i];

            if (isAssignmentValid(roleId, account) && permissions[roleId][selector][target]) {
                return true;
            }
        }

        return false;
    }

    /* //////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Get role info
     * @param roleId The role ID
     * @return info The role info
     */
    function getRoleInfo(bytes32 roleId) external view returns (RoleInfo memory) {
        return roles[roleId];
    }

    /**
     * @notice Get role assignment for an account
     * @param account The account address
     * @param roleId The role ID
     * @return assignment The role assignment
     */
    function getAssignment(address account, bytes32 roleId)
        external
        view
        returns (RoleAssignment memory)
    {
        return assignments[account][roleId];
    }

    /**
     * @notice Get all members of a role
     * @param roleId The role ID
     * @return members Array of member addresses
     */
    function getRoleMembers(bytes32 roleId) external view returns (address[] memory) {
        return roleMembers[roleId];
    }

    /**
     * @notice Get all roles
     * @return roleIds Array of all role IDs
     */
    function getAllRoles() external view returns (bytes32[] memory) {
        return allRoles;
    }

    /**
     * @notice Get all active roles for an account
     * @param account The account address
     * @return activeRoles Array of active role IDs
     */
    function getAccountRoles(address account) external view returns (bytes32[] memory) {
        uint256 count = 0;

        // Count active roles
        for (uint256 i = 0; i < allRoles.length; i++) {
            if (isAssignmentValid(allRoles[i], account)) {
                count++;
            }
        }

        // Build result array
        bytes32[] memory activeRoles = new bytes32[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < allRoles.length; i++) {
            if (isAssignmentValid(allRoles[i], account)) {
                activeRoles[index] = allRoles[i];
                index++;
            }
        }

        return activeRoles;
    }

    /* //////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /**
     * @notice Pause the manager
     */
    function pause() external onlyRole(ROLE_ADMIN) {
        _pause();
    }

    /**
     * @notice Unpause the manager
     */
    function unpause() external onlyRole(ROLE_ADMIN) {
        _unpause();
    }
}
