// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title AuditLogger
 * @notice Immutable on-chain audit logging for regulatory compliance
 * @dev Records all regulatory activities with tamper-proof storage
 *
 * Key Features:
 *   - Immutable audit log entries (append-only)
 *   - Multi-type action classification
 *   - Jurisdiction and legal basis tracking
 *   - Efficient query by actor, target, type, and time
 *   - Retention policy management
 */
contract AuditLogger is AccessControl, ReentrancyGuard {
    // ============ Roles ============
    bytes32 public constant LOGGER_ROLE = keccak256("LOGGER_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    // ============ Enums ============
    enum ActionType {
        TRACE_REQUEST, // 0 - Trace request created
        TRACE_APPROVAL, // 1 - Trace request approved
        TRACE_EXECUTION, // 2 - Trace request executed
        DATA_ACCESS, // 3 - Data accessed by regulator
        REPORT_GENERATION, // 4 - Compliance report generated
        KYC_UPDATE, // 5 - KYC status changed
        RESERVE_VERIFY, // 6 - Reserve verification performed
        SANCTIONS_UPDATE, // 7 - Sanctions list updated
        CONFIG_CHANGE, // 8 - System configuration changed
        EMERGENCY_ACTION, // 9 - Emergency action taken
        CUSTOM // 10 - Custom action type
    }

    enum Severity {
        INFO, // 0 - Informational
        LOW, // 1 - Low importance
        MEDIUM, // 2 - Medium importance
        HIGH, // 3 - High importance
        CRITICAL // 4 - Critical event
    }

    // ============ Structs ============
    struct AuditLog {
        uint256 id;
        uint256 timestamp;
        address actor;
        ActionType actionType;
        address targetAccount;
        bytes32 dataHash; // Hash of action data
        string jurisdiction;
        bytes32 legalBasisHash; // Hash of legal basis document
        Severity severity;
        string description;
        bytes32 correlationId; // Link related entries
        bool isRegulatorAction;
    }

    struct AuditStats {
        uint256 totalLogs;
        uint256 traceRequests;
        uint256 traceApprovals;
        uint256 traceExecutions;
        uint256 dataAccesses;
        uint256 kycUpdates;
        uint256 reserveVerifications;
        uint256 emergencyActions;
    }

    // ============ State Variables ============
    AuditLog[] public auditLogs;

    // Indexes for efficient queries
    mapping(address => uint256[]) public logsByActor;
    mapping(address => uint256[]) public logsByTarget;
    mapping(ActionType => uint256[]) public logsByType;
    mapping(bytes32 => uint256[]) public logsByCorrelation;

    // Statistics
    AuditStats public stats;

    // Retention settings (for off-chain archiving guidance)
    uint256 public retentionPeriod;

    // ============ Events ============
    event AuditLogCreated(
        uint256 indexed logId,
        address indexed actor,
        ActionType actionType,
        address indexed targetAccount,
        bytes32 dataHash,
        Severity severity
    );

    event TraceActivityLogged(
        uint256 indexed logId,
        address indexed regulator,
        address indexed target,
        ActionType actionType,
        bytes32 legalBasisHash
    );

    event EmergencyLogged(uint256 indexed logId, address indexed actor, string description, Severity severity);

    event RetentionPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    // ============ Errors ============
    error InvalidAddress();
    error InvalidActionType();
    error EmptyDescription();
    error LogNotFound();

    // ============ Constructor ============
    constructor(address admin, uint256 _retentionPeriod) {
        if (admin == address(0)) revert InvalidAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(LOGGER_ROLE, admin);
        _grantRole(AUDITOR_ROLE, admin);

        retentionPeriod = _retentionPeriod > 0 ? _retentionPeriod : 7 * 365 days; // Default 7 years
    }

    // ============ Logging Functions ============

    /**
     * @notice Create a general audit log entry
     * @param actionType Type of action
     * @param targetAccount Target of the action
     * @param dataHash Hash of action data
     * @param jurisdiction Jurisdiction code
     * @param legalBasisHash Hash of legal basis
     * @param severity Severity level
     * @param description Human-readable description
     * @param correlationId ID to link related entries
     * @param isRegulatorAction True if action by regulator
     * @return logId The ID of the created log
     */
    function createLog(
        ActionType actionType,
        address targetAccount,
        bytes32 dataHash,
        string calldata jurisdiction,
        bytes32 legalBasisHash,
        Severity severity,
        string calldata description,
        bytes32 correlationId,
        bool isRegulatorAction
    ) external onlyRole(LOGGER_ROLE) nonReentrant returns (uint256 logId) {
        logId = auditLogs.length;

        AuditLog memory log = AuditLog({
            id: logId,
            timestamp: block.timestamp,
            actor: msg.sender,
            actionType: actionType,
            targetAccount: targetAccount,
            dataHash: dataHash,
            jurisdiction: jurisdiction,
            legalBasisHash: legalBasisHash,
            severity: severity,
            description: description,
            correlationId: correlationId,
            isRegulatorAction: isRegulatorAction
        });

        auditLogs.push(log);

        // Update indexes
        logsByActor[msg.sender].push(logId);
        if (targetAccount != address(0)) {
            logsByTarget[targetAccount].push(logId);
        }
        logsByType[actionType].push(logId);
        if (correlationId != bytes32(0)) {
            logsByCorrelation[correlationId].push(logId);
        }

        // Update stats
        _updateStats(actionType);

        emit AuditLogCreated(logId, msg.sender, actionType, targetAccount, dataHash, severity);
    }

    /**
     * @notice Log a trace-related activity
     * @param actionType Type of trace action (REQUEST, APPROVAL, EXECUTION)
     * @param regulator Regulator address
     * @param target Target account
     * @param legalBasisHash Legal basis hash
     * @param traceRequestId Request ID for correlation
     * @return logId The ID of the created log
     */
    function logTraceActivity(
        ActionType actionType,
        address regulator,
        address target,
        bytes32 legalBasisHash,
        uint256 traceRequestId
    ) external onlyRole(LOGGER_ROLE) nonReentrant returns (uint256 logId) {
        if (
            actionType != ActionType.TRACE_REQUEST && actionType != ActionType.TRACE_APPROVAL
                && actionType != ActionType.TRACE_EXECUTION
        ) {
            revert InvalidActionType();
        }

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 correlationId = keccak256(abi.encodePacked("TRACE", traceRequestId));
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 dataHash = keccak256(abi.encodePacked(regulator, target, traceRequestId, block.timestamp));

        string memory description;
        if (actionType == ActionType.TRACE_REQUEST) {
            description = "Trace request created";
        } else if (actionType == ActionType.TRACE_APPROVAL) {
            description = "Trace request approved";
        } else {
            description = "Trace request executed";
        }

        logId = auditLogs.length;

        AuditLog memory log = AuditLog({
            id: logId,
            timestamp: block.timestamp,
            actor: regulator,
            actionType: actionType,
            targetAccount: target,
            dataHash: dataHash,
            jurisdiction: "",
            legalBasisHash: legalBasisHash,
            severity: Severity.HIGH,
            description: description,
            correlationId: correlationId,
            isRegulatorAction: true
        });

        auditLogs.push(log);

        // Update indexes
        logsByActor[regulator].push(logId);
        logsByTarget[target].push(logId);
        logsByType[actionType].push(logId);
        logsByCorrelation[correlationId].push(logId);

        // Update stats
        _updateStats(actionType);

        emit TraceActivityLogged(logId, regulator, target, actionType, legalBasisHash);
        emit AuditLogCreated(logId, regulator, actionType, target, dataHash, Severity.HIGH);
    }

    /**
     * @notice Log a KYC status update
     * @param account Account whose KYC was updated
     * @param oldStatus Old KYC status
     * @param newStatus New KYC status
     * @param provider KYC provider address
     * @return logId The ID of the created log
     */
    function logKycUpdate(address account, uint8 oldStatus, uint8 newStatus, address provider)
        external
        onlyRole(LOGGER_ROLE)
        nonReentrant
        returns (uint256 logId)
    {
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 dataHash = keccak256(abi.encodePacked(account, oldStatus, newStatus, provider, block.timestamp));

        logId = auditLogs.length;

        AuditLog memory log = AuditLog({
            id: logId,
            timestamp: block.timestamp,
            actor: provider,
            actionType: ActionType.KYC_UPDATE,
            targetAccount: account,
            dataHash: dataHash,
            jurisdiction: "",
            legalBasisHash: bytes32(0),
            severity: Severity.MEDIUM,
            description: "KYC status updated",
            correlationId: bytes32(0),
            isRegulatorAction: false
        });

        auditLogs.push(log);

        // Update indexes
        logsByActor[provider].push(logId);
        logsByTarget[account].push(logId);
        logsByType[ActionType.KYC_UPDATE].push(logId);

        // Update stats
        stats.totalLogs++;
        stats.kycUpdates++;

        emit AuditLogCreated(logId, provider, ActionType.KYC_UPDATE, account, dataHash, Severity.MEDIUM);
    }

    /**
     * @notice Log a reserve verification
     * @param totalSupply Total supply at verification
     * @param totalReserve Total reserve at verification
     * @param reserveRatio Reserve ratio in basis points
     * @param isHealthy Whether reserve is healthy
     * @return logId The ID of the created log
     */
    function logReserveVerification(uint256 totalSupply, uint256 totalReserve, uint256 reserveRatio, bool isHealthy)
        external
        onlyRole(LOGGER_ROLE)
        nonReentrant
        returns (uint256 logId)
    {
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 dataHash =
            keccak256(abi.encodePacked(totalSupply, totalReserve, reserveRatio, isHealthy, block.timestamp));

        Severity severity = isHealthy ? Severity.INFO : Severity.CRITICAL;
        string memory description = isHealthy ? "Reserve verification passed" : "Reserve verification failed";

        logId = auditLogs.length;

        AuditLog memory log = AuditLog({
            id: logId,
            timestamp: block.timestamp,
            actor: msg.sender,
            actionType: ActionType.RESERVE_VERIFY,
            targetAccount: address(0),
            dataHash: dataHash,
            jurisdiction: "",
            legalBasisHash: bytes32(0),
            severity: severity,
            description: description,
            correlationId: bytes32(0),
            isRegulatorAction: false
        });

        auditLogs.push(log);

        // Update indexes
        logsByActor[msg.sender].push(logId);
        logsByType[ActionType.RESERVE_VERIFY].push(logId);

        // Update stats
        stats.totalLogs++;
        stats.reserveVerifications++;

        emit AuditLogCreated(logId, msg.sender, ActionType.RESERVE_VERIFY, address(0), dataHash, severity);
    }

    /**
     * @notice Log an emergency action
     * @param actor Actor who took the action
     * @param description Description of emergency action
     * @param severity Severity level
     * @return logId The ID of the created log
     */
    function logEmergencyAction(address actor, string calldata description, Severity severity)
        external
        onlyRole(LOGGER_ROLE)
        nonReentrant
        returns (uint256 logId)
    {
        if (bytes(description).length == 0) revert EmptyDescription();

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 dataHash = keccak256(abi.encodePacked(actor, description, block.timestamp));

        logId = auditLogs.length;

        AuditLog memory log = AuditLog({
            id: logId,
            timestamp: block.timestamp,
            actor: actor,
            actionType: ActionType.EMERGENCY_ACTION,
            targetAccount: address(0),
            dataHash: dataHash,
            jurisdiction: "",
            legalBasisHash: bytes32(0),
            severity: severity,
            description: description,
            correlationId: bytes32(0),
            isRegulatorAction: true
        });

        auditLogs.push(log);

        // Update indexes
        logsByActor[actor].push(logId);
        logsByType[ActionType.EMERGENCY_ACTION].push(logId);

        // Update stats
        stats.totalLogs++;
        stats.emergencyActions++;

        emit EmergencyLogged(logId, actor, description, severity);
        emit AuditLogCreated(logId, actor, ActionType.EMERGENCY_ACTION, address(0), dataHash, severity);
    }

    /**
     * @notice Log data access by a regulator
     * @param regulator Regulator accessing data
     * @param targetAccount Account whose data was accessed
     * @param dataType Type of data accessed (hashed)
     * @param legalBasisHash Legal basis for access
     * @return logId The ID of the created log
     */
    function logDataAccess(address regulator, address targetAccount, bytes32 dataType, bytes32 legalBasisHash)
        external
        onlyRole(LOGGER_ROLE)
        nonReentrant
        returns (uint256 logId)
    {
        if (regulator == address(0)) revert InvalidAddress();
        if (targetAccount == address(0)) revert InvalidAddress();

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 dataHash = keccak256(abi.encodePacked(regulator, targetAccount, dataType, block.timestamp));

        logId = auditLogs.length;

        AuditLog memory log = AuditLog({
            id: logId,
            timestamp: block.timestamp,
            actor: regulator,
            actionType: ActionType.DATA_ACCESS,
            targetAccount: targetAccount,
            dataHash: dataHash,
            jurisdiction: "",
            legalBasisHash: legalBasisHash,
            severity: Severity.HIGH,
            description: "Regulatory data access",
            correlationId: bytes32(0),
            isRegulatorAction: true
        });

        auditLogs.push(log);

        // Update indexes
        logsByActor[regulator].push(logId);
        logsByTarget[targetAccount].push(logId);
        logsByType[ActionType.DATA_ACCESS].push(logId);

        // Update stats
        stats.totalLogs++;
        stats.dataAccesses++;

        emit AuditLogCreated(logId, regulator, ActionType.DATA_ACCESS, targetAccount, dataHash, Severity.HIGH);
    }

    // ============ Internal Functions ============

    function _updateStats(ActionType actionType) internal {
        stats.totalLogs++;

        if (actionType == ActionType.TRACE_REQUEST) {
            stats.traceRequests++;
        } else if (actionType == ActionType.TRACE_APPROVAL) {
            stats.traceApprovals++;
        } else if (actionType == ActionType.TRACE_EXECUTION) {
            stats.traceExecutions++;
        } else if (actionType == ActionType.DATA_ACCESS) {
            stats.dataAccesses++;
        } else if (actionType == ActionType.KYC_UPDATE) {
            stats.kycUpdates++;
        } else if (actionType == ActionType.RESERVE_VERIFY) {
            stats.reserveVerifications++;
        } else if (actionType == ActionType.EMERGENCY_ACTION) {
            stats.emergencyActions++;
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get a specific audit log
     * @param logId ID of the log
     * @return AuditLog struct
     */
    function getLog(uint256 logId) external view returns (AuditLog memory) {
        if (logId >= auditLogs.length) revert LogNotFound();
        return auditLogs[logId];
    }

    /**
     * @notice Get total number of logs
     * @return count Total logs
     */
    function getLogCount() external view returns (uint256) {
        return auditLogs.length;
    }

    /**
     * @notice Get logs by actor
     * @param actor Actor address
     * @return Array of log IDs
     */
    function getLogsByActor(address actor) external view returns (uint256[] memory) {
        return logsByActor[actor];
    }

    /**
     * @notice Get logs by target
     * @param target Target address
     * @return Array of log IDs
     */
    function getLogsByTarget(address target) external view returns (uint256[] memory) {
        return logsByTarget[target];
    }

    /**
     * @notice Get logs by action type
     * @param actionType Action type
     * @return Array of log IDs
     */
    function getLogsByType(ActionType actionType) external view returns (uint256[] memory) {
        return logsByType[actionType];
    }

    /**
     * @notice Get logs by correlation ID
     * @param correlationId Correlation ID
     * @return Array of log IDs
     */
    function getLogsByCorrelation(bytes32 correlationId) external view returns (uint256[] memory) {
        return logsByCorrelation[correlationId];
    }

    /**
     * @notice Get logs within a time range
     * @param startTime Start timestamp
     * @param endTime End timestamp
     * @return logIds Array of log IDs in range
     */
    function getLogsInRange(uint256 startTime, uint256 endTime) external view returns (uint256[] memory logIds) {
        uint256 count = 0;

        // First pass: count matching logs
        for (uint256 i = 0; i < auditLogs.length; i++) {
            if (auditLogs[i].timestamp >= startTime && auditLogs[i].timestamp <= endTime) {
                count++;
            }
        }

        // Second pass: collect matching IDs
        logIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < auditLogs.length; i++) {
            if (auditLogs[i].timestamp >= startTime && auditLogs[i].timestamp <= endTime) {
                logIds[index] = i;
                index++;
            }
        }
    }

    /**
     * @notice Get recent logs (paginated)
     * @param offset Starting offset from most recent
     * @param limit Maximum number of logs to return
     * @return logs Array of AuditLog structs
     */
    function getRecentLogs(uint256 offset, uint256 limit) external view returns (AuditLog[] memory logs) {
        uint256 total = auditLogs.length;
        if (offset >= total) {
            return new AuditLog[](0);
        }

        uint256 startIndex = total - offset - 1;
        uint256 count = startIndex + 1 < limit ? startIndex + 1 : limit;

        logs = new AuditLog[](count);
        for (uint256 i = 0; i < count; i++) {
            logs[i] = auditLogs[startIndex - i];
        }
    }

    /**
     * @notice Get audit statistics
     * @return AuditStats struct
     */
    function getStats() external view returns (AuditStats memory) {
        return stats;
    }

    /**
     * @notice Check if a log is within retention period
     * @param logId ID of the log
     * @return withinRetention True if within retention
     */
    function isWithinRetention(uint256 logId) external view returns (bool) {
        if (logId >= auditLogs.length) revert LogNotFound();
        return block.timestamp - auditLogs[logId].timestamp <= retentionPeriod;
    }

    /**
     * @notice Get logs that are past retention (for archiving)
     * @param limit Maximum number to return
     * @return logIds Array of log IDs past retention
     */
    function getLogsPastRetention(uint256 limit) external view returns (uint256[] memory logIds) {
        uint256 count = 0;
        uint256 cutoff = block.timestamp - retentionPeriod;

        // First pass: count
        for (uint256 i = 0; i < auditLogs.length && count < limit; i++) {
            if (auditLogs[i].timestamp < cutoff) {
                count++;
            }
        }

        // Second pass: collect
        logIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < auditLogs.length && index < count; i++) {
            if (auditLogs[i].timestamp < cutoff) {
                logIds[index] = i;
                index++;
            }
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Update retention period
     * @param newPeriod New retention period in seconds
     */
    function setRetentionPeriod(uint256 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldPeriod = retentionPeriod;
        retentionPeriod = newPeriod;
        emit RetentionPeriodUpdated(oldPeriod, newPeriod);
    }

    /**
     * @notice Grant logger role to an address
     * @param account Address to grant role
     */
    function grantLoggerRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        _grantRole(LOGGER_ROLE, account);
    }

    /**
     * @notice Revoke logger role from an address
     * @param account Address to revoke role
     */
    function revokeLoggerRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(LOGGER_ROLE, account);
    }
}
