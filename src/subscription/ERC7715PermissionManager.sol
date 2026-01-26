// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title IERC7715PermissionManager
 * @notice Interface for ERC-7715 Permission Manager
 * @dev Based on ERC-7715 JSON-RPC permission methods, adapted for on-chain management
 */
interface IERC7715PermissionManager {
    /* //////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidPermissionType();
    error PermissionExpired();
    error PermissionNotFound();
    error PermissionAlreadyExists();
    error InvalidSignature();
    error UnauthorizedCaller();
    error InvalidExpiryTime();
    error AdjustmentNotAllowed();
    error InsufficientAllowance();
    error InvalidTarget();
    error PermissionPaused();

    /* //////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PermissionGranted(
        bytes32 indexed permissionId,
        address indexed granter,
        address indexed grantee,
        string permissionType,
        uint256 expiry
    );

    event PermissionRevoked(bytes32 indexed permissionId, address indexed granter, address indexed grantee);

    event PermissionAdjusted(bytes32 indexed permissionId, bytes oldData, bytes newData);

    event PermissionUsed(bytes32 indexed permissionId, address indexed user, uint256 amount);

    /* //////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Base permission structure (ERC-7715 compatible)
    struct Permission {
        string permissionType; // Type identifier (e.g., "native-token-recurring-allowance")
        bool isAdjustmentAllowed; // Whether permission parameters can be modified
        bytes data; // Permission-specific encoded data
    }

    /// @notice Rule that can be applied to permissions
    struct Rule {
        string ruleType; // Type of rule (e.g., "expiry", "rate-limit")
        bytes data; // Rule-specific encoded data
    }

    /// @notice Full permission record stored on-chain
    struct PermissionRecord {
        address granter; // Account that granted the permission
        address grantee; // Account that received the permission
        uint256 chainId; // Chain where permission is valid
        address target; // Target contract for permission
        Permission permission; // Permission details
        Rule[] rules; // Applied rules
        uint256 createdAt; // Creation timestamp
        bool active; // Whether permission is active
    }

    /* //////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function grantPermission(address grantee, address target, Permission calldata permission, Rule[] calldata rules)
        external
        returns (bytes32 permissionId);

    function grantPermissionWithSignature(
        address granter,
        address grantee,
        address target,
        Permission calldata permission,
        Rule[] calldata rules,
        bytes calldata signature
    ) external returns (bytes32 permissionId);

    function revokePermission(bytes32 permissionId) external;

    function adjustPermission(bytes32 permissionId, bytes calldata newData) external;

    function usePermission(bytes32 permissionId, uint256 amount) external returns (bool);

    function getPermission(bytes32 permissionId) external view returns (PermissionRecord memory);

    function isPermissionValid(bytes32 permissionId) external view returns (bool);

    function getPermissionId(
        address granter,
        address grantee,
        address target,
        string calldata permissionType,
        uint256 nonce
    ) external pure returns (bytes32);
}

/**
 * @title ERC7715PermissionManager
 * @notice On-chain permission management based on ERC-7715 specification
 * @dev Manages permissions for DApps to execute actions on behalf of users
 *
 * Permission Types Supported:
 *   - native-token-recurring-allowance: Recurring native token allowance
 *   - erc20-recurring-allowance: Recurring ERC-20 token allowance
 *   - session-key: General session key permissions
 *   - subscription: Subscription-based permissions
 *
 * Rule Types Supported:
 *   - expiry: Permission expires at specified timestamp
 *   - rate-limit: Limits usage per time period
 *   - spending-limit: Maximum spending per transaction/period
 */
contract ERC7715PermissionManager is IERC7715PermissionManager, Ownable, ReentrancyGuard {
    using ECDSA for bytes32;

    /* //////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping of permission ID to permission record
    mapping(bytes32 => PermissionRecord) public permissions;

    /// @notice Nonce for each granter (replay protection)
    mapping(address => uint256) public nonces;

    /// @notice Permission type registry (type hash => supported)
    mapping(bytes32 => bool) public supportedPermissionTypes;

    /// @notice Usage tracking per permission
    mapping(bytes32 => uint256) public permissionUsage;

    /// @notice Daily/period usage tracking
    mapping(bytes32 => mapping(uint256 => uint256)) public periodUsage;

    /// @notice Authorized executors (can call usePermission)
    mapping(address => bool) public authorizedExecutors;

    /// @notice Global pause flag
    bool public paused;

    /// @notice EIP-712 domain separator
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice EIP-712 type hash for permission grants
    bytes32 public constant PERMISSION_GRANT_TYPEHASH = keccak256(
        "PermissionGrant(address granter,address grantee,address target,bytes32 permissionTypeHash,bytes32 dataHash,uint256 nonce,uint256 deadline)"
    );

    /* //////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() Ownable(msg.sender) {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ERC7715PermissionManager"),
                keccak256("1.0"),
                block.chainid,
                address(this)
            )
        );

        // Register default permission types
        _registerPermissionType("native-token-recurring-allowance");
        _registerPermissionType("erc20-recurring-allowance");
        _registerPermissionType("session-key");
        _registerPermissionType("subscription");
        _registerPermissionType("spending-limit");
    }

    /* //////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier whenNotPaused() {
        _checkNotPaused();
        _;
    }

    modifier onlyAuthorizedExecutor() {
        _checkAuthorizedExecutor();
        _;
    }

    function _checkNotPaused() internal view {
        if (paused) revert PermissionPaused();
    }

    function _checkAuthorizedExecutor() internal view {
        if (!authorizedExecutors[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedCaller();
        }
    }

    /* //////////////////////////////////////////////////////////////
                        PERMISSION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Grant a permission directly
     * @param grantee Address receiving the permission
     * @param target Target contract for the permission
     * @param permission Permission details
     * @param rules Rules to apply to the permission
     * @return permissionId Unique identifier for the permission
     */
    function grantPermission(address grantee, address target, Permission calldata permission, Rule[] calldata rules)
        external
        override
        whenNotPaused
        returns (bytes32 permissionId)
    {
        return _grantPermission(msg.sender, grantee, target, permission, rules);
    }

    /**
     * @notice Grant a permission with signature (meta-transaction)
     * @param granter Address granting the permission
     * @param grantee Address receiving the permission
     * @param target Target contract for the permission
     * @param permission Permission details
     * @param rules Rules to apply to the permission
     * @param signature EIP-712 signature from granter
     * @return permissionId Unique identifier for the permission
     */
    function grantPermissionWithSignature(
        address granter,
        address grantee,
        address target,
        Permission calldata permission,
        Rule[] calldata rules,
        bytes calldata signature
    ) external override whenNotPaused returns (bytes32 permissionId) {
        // Build and verify signature
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 structHash = keccak256(
            abi.encode(
                PERMISSION_GRANT_TYPEHASH,
                granter,
                grantee,
                target,
                keccak256(bytes(permission.permissionType)),
                keccak256(permission.data),
                nonces[granter],
                block.timestamp + 1 hours // Deadline
            )
        );

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        address recovered = digest.recover(signature);
        if (recovered != granter || recovered == address(0)) {
            revert InvalidSignature();
        }

        return _grantPermission(granter, grantee, target, permission, rules);
    }

    /**
     * @notice Internal function to grant permission
     */
    function _grantPermission(
        address granter,
        address grantee,
        address target,
        Permission calldata permission,
        Rule[] calldata rules
    ) internal returns (bytes32 permissionId) {
        // Validate permission type
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 typeHash = keccak256(bytes(permission.permissionType));
        if (!supportedPermissionTypes[typeHash]) {
            revert InvalidPermissionType();
        }

        if (target == address(0)) revert InvalidTarget();

        // Generate permission ID
        uint256 nonce = nonces[granter]++;
        permissionId = getPermissionId(granter, grantee, target, permission.permissionType, nonce);

        // Check for existing permission
        if (permissions[permissionId].createdAt != 0) {
            revert PermissionAlreadyExists();
        }

        // Validate rules
        uint256 expiry = _validateAndExtractExpiry(rules);

        // Store permission
        PermissionRecord storage record = permissions[permissionId];
        record.granter = granter;
        record.grantee = grantee;
        record.chainId = block.chainid;
        record.target = target;
        record.permission = permission;
        record.createdAt = block.timestamp;
        record.active = true;

        // Store rules
        for (uint256 i = 0; i < rules.length; i++) {
            record.rules.push(rules[i]);
        }

        emit PermissionGranted(permissionId, granter, grantee, permission.permissionType, expiry);
    }

    /**
     * @notice Revoke a permission
     * @param permissionId Permission to revoke
     */
    function revokePermission(bytes32 permissionId) external override {
        PermissionRecord storage record = permissions[permissionId];

        if (record.createdAt == 0) revert PermissionNotFound();
        if (record.granter != msg.sender && msg.sender != owner()) {
            revert UnauthorizedCaller();
        }

        record.active = false;

        emit PermissionRevoked(permissionId, record.granter, record.grantee);
    }

    /**
     * @notice Adjust permission parameters
     * @param permissionId Permission to adjust
     * @param newData New permission data
     */
    function adjustPermission(bytes32 permissionId, bytes calldata newData) external override {
        PermissionRecord storage record = permissions[permissionId];

        if (record.createdAt == 0) revert PermissionNotFound();
        if (!record.active) revert PermissionNotFound();
        if (record.granter != msg.sender) revert UnauthorizedCaller();
        if (!record.permission.isAdjustmentAllowed) revert AdjustmentNotAllowed();

        bytes memory oldData = record.permission.data;
        record.permission.data = newData;

        emit PermissionAdjusted(permissionId, oldData, newData);
    }

    /**
     * @notice Use a permission (consume allowance)
     * @param permissionId Permission to use
     * @param amount Amount to consume
     * @return success Whether the usage was successful
     */
    function usePermission(bytes32 permissionId, uint256 amount)
        external
        override
        onlyAuthorizedExecutor
        nonReentrant
        returns (bool success)
    {
        PermissionRecord storage record = permissions[permissionId];

        if (record.createdAt == 0) revert PermissionNotFound();
        if (!record.active) revert PermissionNotFound();

        // Check expiry
        uint256 expiry = _getExpiry(record.rules);
        if (expiry != 0 && block.timestamp > expiry) {
            revert PermissionExpired();
        }

        // Check spending limit
        uint256 limit = _getSpendingLimit(record.permission.data);
        if (limit > 0) {
            uint256 currentPeriod = block.timestamp / 1 days;
            if (periodUsage[permissionId][currentPeriod] + amount > limit) {
                revert InsufficientAllowance();
            }
            periodUsage[permissionId][currentPeriod] += amount;
        }

        permissionUsage[permissionId] += amount;

        emit PermissionUsed(permissionId, msg.sender, amount);

        return true;
    }

    /* //////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get permission details
     * @param permissionId Permission ID
     * @return record The permission record
     */
    function getPermission(bytes32 permissionId) external view override returns (PermissionRecord memory record) {
        record = permissions[permissionId];
        if (record.createdAt == 0) revert PermissionNotFound();
    }

    /**
     * @notice Check if a permission is valid
     * @param permissionId Permission ID
     * @return valid Whether the permission is valid
     */
    function isPermissionValid(bytes32 permissionId) external view override returns (bool valid) {
        PermissionRecord storage record = permissions[permissionId];

        if (record.createdAt == 0) return false;
        if (!record.active) return false;

        // Check expiry
        uint256 expiry = _getExpiry(record.rules);
        if (expiry != 0 && block.timestamp > expiry) {
            return false;
        }

        return true;
    }

    /**
     * @notice Generate permission ID
     * @param granter Address granting permission
     * @param grantee Address receiving permission
     * @param target Target contract
     * @param permissionType Type of permission
     * @param nonce Nonce value
     * @return Permission ID
     */
    function getPermissionId(
        address granter,
        address grantee,
        address target,
        string calldata permissionType,
        uint256 nonce
    ) public pure override returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encodePacked(granter, grantee, target, permissionType, nonce));
    }

    /**
     * @notice Get remaining allowance for a permission
     * @param permissionId Permission ID
     * @return remaining Remaining allowance
     */
    function getRemainingAllowance(bytes32 permissionId) external view returns (uint256 remaining) {
        PermissionRecord storage record = permissions[permissionId];
        if (record.createdAt == 0) return 0;

        uint256 limit = _getSpendingLimit(record.permission.data);
        if (limit == 0) return type(uint256).max;

        uint256 currentPeriod = block.timestamp / 1 days;
        uint256 used = periodUsage[permissionId][currentPeriod];

        return used >= limit ? 0 : limit - used;
    }

    /**
     * @notice Get total usage for a permission
     * @param permissionId Permission ID
     * @return Total usage amount
     */
    function getTotalUsage(bytes32 permissionId) external view returns (uint256) {
        return permissionUsage[permissionId];
    }

    /**
     * @notice Check if a permission type is supported
     * @param permissionType Type to check
     * @return Whether the type is supported
     */
    function isPermissionTypeSupported(string calldata permissionType) external view returns (bool) {
        return supportedPermissionTypes[keccak256(bytes(permissionType))];
    }

    /* //////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register a new permission type
     * @param permissionType Type to register
     */
    function registerPermissionType(string calldata permissionType) external onlyOwner {
        _registerPermissionType(permissionType);
    }

    function _registerPermissionType(string memory permissionType) internal {
        supportedPermissionTypes[keccak256(bytes(permissionType))] = true;
    }

    /**
     * @notice Unregister a permission type
     * @param permissionType Type to unregister
     */
    function unregisterPermissionType(string calldata permissionType) external onlyOwner {
        supportedPermissionTypes[keccak256(bytes(permissionType))] = false;
    }

    /**
     * @notice Add an authorized executor
     * @param executor Address to authorize
     */
    function addAuthorizedExecutor(address executor) external onlyOwner {
        authorizedExecutors[executor] = true;
    }

    /**
     * @notice Remove an authorized executor
     * @param executor Address to deauthorize
     */
    function removeAuthorizedExecutor(address executor) external onlyOwner {
        authorizedExecutors[executor] = false;
    }

    /**
     * @notice Pause/unpause the contract
     * @param _paused New pause state
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    /* //////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validate rules and extract expiry time
     * @param rules Array of rules
     * @return expiry Expiry timestamp (0 if no expiry rule)
     */
    function _validateAndExtractExpiry(Rule[] calldata rules) internal view returns (uint256 expiry) {
        for (uint256 i = 0; i < rules.length; i++) {
            if (keccak256(bytes(rules[i].ruleType)) == keccak256("expiry")) {
                expiry = abi.decode(rules[i].data, (uint256));
                if (expiry != 0 && expiry <= block.timestamp) {
                    revert InvalidExpiryTime();
                }
            }
        }
    }

    /**
     * @notice Get expiry from rules array
     * @param rules Array of rules
     * @return expiry Expiry timestamp
     */
    function _getExpiry(Rule[] storage rules) internal view returns (uint256 expiry) {
        for (uint256 i = 0; i < rules.length; i++) {
            if (keccak256(bytes(rules[i].ruleType)) == keccak256("expiry")) {
                return abi.decode(rules[i].data, (uint256));
            }
        }
    }

    /**
     * @notice Get spending limit from permission data
     * @param data Permission data
     * @return limit Spending limit (0 if no limit)
     */
    function _getSpendingLimit(bytes memory data) internal pure returns (uint256 limit) {
        if (data.length >= 32) {
            limit = abi.decode(data, (uint256));
        }
    }
}
