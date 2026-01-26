// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { AuditLogger } from "../../src/compliance/AuditLogger.sol";

contract AuditLoggerTest is Test {
    AuditLogger public logger;

    address public admin;
    address public loggerRole;
    address public target;

    event AuditLogCreated(
        uint256 indexed logId,
        address indexed actor,
        AuditLogger.ActionType actionType,
        address indexed targetAccount,
        bytes32 dataHash,
        AuditLogger.Severity severity
    );
    event TraceActivityLogged(
        uint256 indexed logId,
        address indexed regulator,
        address indexed target,
        AuditLogger.ActionType actionType,
        bytes32 legalBasisHash
    );
    event EmergencyLogged(
        uint256 indexed logId, address indexed actor, string description, AuditLogger.Severity severity
    );
    event RetentionPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    function setUp() public {
        admin = makeAddr("admin");
        loggerRole = makeAddr("logger");
        target = makeAddr("target");

        vm.prank(admin);
        logger = new AuditLogger(admin, 7 * 365 days);

        vm.prank(admin);
        logger.grantLoggerRole(loggerRole);
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertTrue(logger.hasRole(logger.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(logger.hasRole(logger.LOGGER_ROLE(), admin));
        assertTrue(logger.hasRole(logger.AUDITOR_ROLE(), admin));
        assertEq(logger.retentionPeriod(), 7 * 365 days);
    }

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(AuditLogger.InvalidAddress.selector);
        new AuditLogger(address(0), 7 * 365 days);
    }

    function test_Constructor_DefaultRetentionOnZero() public {
        vm.prank(admin);
        AuditLogger newLogger = new AuditLogger(admin, 0);
        assertEq(newLogger.retentionPeriod(), 7 * 365 days);
    }

    // ============ CreateLog Tests ============

    function test_CreateLog_Success() public {
        bytes32 dataHash = keccak256("test data");
        bytes32 legalBasisHash = keccak256("legal basis");
        bytes32 correlationId = keccak256("correlation");

        vm.prank(loggerRole);
        uint256 logId = logger.createLog(
            AuditLogger.ActionType.CONFIG_CHANGE,
            target,
            dataHash,
            "US",
            legalBasisHash,
            AuditLogger.Severity.MEDIUM,
            "Configuration changed",
            correlationId,
            false
        );

        assertEq(logId, 0);
        assertEq(logger.getLogCount(), 1);

        AuditLogger.AuditLog memory log = logger.getLog(0);
        assertEq(log.id, 0);
        assertEq(log.actor, loggerRole);
        assertEq(uint8(log.actionType), uint8(AuditLogger.ActionType.CONFIG_CHANGE));
        assertEq(log.targetAccount, target);
        assertEq(log.dataHash, dataHash);
        assertEq(keccak256(bytes(log.jurisdiction)), keccak256(bytes("US")));
        assertEq(log.legalBasisHash, legalBasisHash);
        assertEq(uint8(log.severity), uint8(AuditLogger.Severity.MEDIUM));
        assertEq(log.correlationId, correlationId);
        assertFalse(log.isRegulatorAction);
    }

    function test_CreateLog_EmitsEvent() public {
        bytes32 dataHash = keccak256("test data");

        vm.prank(loggerRole);
        vm.expectEmit(true, true, true, true);
        emit AuditLogCreated(
            0, loggerRole, AuditLogger.ActionType.CONFIG_CHANGE, target, dataHash, AuditLogger.Severity.LOW
        );
        logger.createLog(
            AuditLogger.ActionType.CONFIG_CHANGE,
            target,
            dataHash,
            "",
            bytes32(0),
            AuditLogger.Severity.LOW,
            "Test",
            bytes32(0),
            false
        );
    }

    function test_CreateLog_UpdatesIndexes() public {
        vm.prank(loggerRole);
        logger.createLog(
            AuditLogger.ActionType.CONFIG_CHANGE,
            target,
            bytes32(0),
            "",
            bytes32(0),
            AuditLogger.Severity.INFO,
            "Test",
            bytes32(0),
            false
        );

        uint256[] memory byActor = logger.getLogsByActor(loggerRole);
        assertEq(byActor.length, 1);
        assertEq(byActor[0], 0);

        uint256[] memory byTarget = logger.getLogsByTarget(target);
        assertEq(byTarget.length, 1);
        assertEq(byTarget[0], 0);

        uint256[] memory byType = logger.getLogsByType(AuditLogger.ActionType.CONFIG_CHANGE);
        assertEq(byType.length, 1);
        assertEq(byType[0], 0);
    }

    function test_CreateLog_RevertsOnUnauthorized() public {
        vm.prank(target);
        vm.expectRevert();
        logger.createLog(
            AuditLogger.ActionType.CONFIG_CHANGE,
            target,
            bytes32(0),
            "",
            bytes32(0),
            AuditLogger.Severity.INFO,
            "Test",
            bytes32(0),
            false
        );
    }

    // ============ LogTraceActivity Tests ============

    function test_LogTraceActivity_Request() public {
        bytes32 legalBasisHash = keccak256("legal basis");

        vm.prank(loggerRole);
        uint256 logId =
            logger.logTraceActivity(AuditLogger.ActionType.TRACE_REQUEST, loggerRole, target, legalBasisHash, 1);

        AuditLogger.AuditLog memory log = logger.getLog(logId);
        assertEq(uint8(log.actionType), uint8(AuditLogger.ActionType.TRACE_REQUEST));
        assertEq(log.actor, loggerRole);
        assertEq(log.targetAccount, target);
        assertEq(log.legalBasisHash, legalBasisHash);
        assertEq(uint8(log.severity), uint8(AuditLogger.Severity.HIGH));
        assertTrue(log.isRegulatorAction);

        AuditLogger.AuditStats memory stats = logger.getStats();
        assertEq(stats.traceRequests, 1);
    }

    function test_LogTraceActivity_Approval() public {
        vm.prank(loggerRole);
        logger.logTraceActivity(AuditLogger.ActionType.TRACE_APPROVAL, loggerRole, target, bytes32(0), 1);

        AuditLogger.AuditStats memory stats = logger.getStats();
        assertEq(stats.traceApprovals, 1);
    }

    function test_LogTraceActivity_Execution() public {
        vm.prank(loggerRole);
        logger.logTraceActivity(AuditLogger.ActionType.TRACE_EXECUTION, loggerRole, target, bytes32(0), 1);

        AuditLogger.AuditStats memory stats = logger.getStats();
        assertEq(stats.traceExecutions, 1);
    }

    function test_LogTraceActivity_RevertsOnInvalidType() public {
        vm.prank(loggerRole);
        vm.expectRevert(AuditLogger.InvalidActionType.selector);
        logger.logTraceActivity(AuditLogger.ActionType.KYC_UPDATE, loggerRole, target, bytes32(0), 1);
    }

    function test_LogTraceActivity_CorrelationId() public {
        vm.prank(loggerRole);
        logger.logTraceActivity(AuditLogger.ActionType.TRACE_REQUEST, loggerRole, target, bytes32(0), 123);

        vm.prank(loggerRole);
        logger.logTraceActivity(AuditLogger.ActionType.TRACE_APPROVAL, loggerRole, target, bytes32(0), 123);

        bytes32 correlationId = keccak256(abi.encodePacked("TRACE", uint256(123)));
        uint256[] memory correlated = logger.getLogsByCorrelation(correlationId);
        assertEq(correlated.length, 2);
    }

    // ============ LogKycUpdate Tests ============

    function test_LogKycUpdate_Success() public {
        address provider = makeAddr("kycProvider");

        vm.prank(loggerRole);
        uint256 logId = logger.logKycUpdate(target, 0, 2, provider);

        AuditLogger.AuditLog memory log = logger.getLog(logId);
        assertEq(uint8(log.actionType), uint8(AuditLogger.ActionType.KYC_UPDATE));
        assertEq(log.actor, provider);
        assertEq(log.targetAccount, target);
        assertEq(uint8(log.severity), uint8(AuditLogger.Severity.MEDIUM));
        assertFalse(log.isRegulatorAction);

        AuditLogger.AuditStats memory stats = logger.getStats();
        assertEq(stats.kycUpdates, 1);
    }

    // ============ LogReserveVerification Tests ============

    function test_LogReserveVerification_Healthy() public {
        vm.prank(loggerRole);
        uint256 logId = logger.logReserveVerification(1000 ether, 1100 ether, 11_000, true);

        AuditLogger.AuditLog memory log = logger.getLog(logId);
        assertEq(uint8(log.actionType), uint8(AuditLogger.ActionType.RESERVE_VERIFY));
        assertEq(uint8(log.severity), uint8(AuditLogger.Severity.INFO));

        AuditLogger.AuditStats memory stats = logger.getStats();
        assertEq(stats.reserveVerifications, 1);
    }

    function test_LogReserveVerification_Unhealthy() public {
        vm.prank(loggerRole);
        uint256 logId = logger.logReserveVerification(1000 ether, 900 ether, 9000, false);

        AuditLogger.AuditLog memory log = logger.getLog(logId);
        assertEq(uint8(log.severity), uint8(AuditLogger.Severity.CRITICAL));
    }

    // ============ LogEmergencyAction Tests ============

    function test_LogEmergencyAction_Success() public {
        vm.prank(loggerRole);
        uint256 logId = logger.logEmergencyAction(admin, "Emergency pause activated", AuditLogger.Severity.CRITICAL);

        AuditLogger.AuditLog memory log = logger.getLog(logId);
        assertEq(uint8(log.actionType), uint8(AuditLogger.ActionType.EMERGENCY_ACTION));
        assertEq(log.actor, admin);
        assertEq(uint8(log.severity), uint8(AuditLogger.Severity.CRITICAL));
        assertTrue(log.isRegulatorAction);

        AuditLogger.AuditStats memory stats = logger.getStats();
        assertEq(stats.emergencyActions, 1);
    }

    function test_LogEmergencyAction_RevertsOnEmptyDescription() public {
        vm.prank(loggerRole);
        vm.expectRevert(AuditLogger.EmptyDescription.selector);
        logger.logEmergencyAction(admin, "", AuditLogger.Severity.HIGH);
    }

    // ============ LogDataAccess Tests ============

    function test_LogDataAccess_Success() public {
        address regulator = makeAddr("regulator");
        bytes32 dataType = keccak256("transaction_history");
        bytes32 legalBasisHash = keccak256("court_order");

        vm.prank(loggerRole);
        uint256 logId = logger.logDataAccess(regulator, target, dataType, legalBasisHash);

        AuditLogger.AuditLog memory log = logger.getLog(logId);
        assertEq(uint8(log.actionType), uint8(AuditLogger.ActionType.DATA_ACCESS));
        assertEq(log.actor, regulator);
        assertEq(log.targetAccount, target);
        assertEq(log.legalBasisHash, legalBasisHash);
        assertEq(uint8(log.severity), uint8(AuditLogger.Severity.HIGH));
        assertTrue(log.isRegulatorAction);

        AuditLogger.AuditStats memory stats = logger.getStats();
        assertEq(stats.dataAccesses, 1);
    }

    function test_LogDataAccess_RevertsOnZeroRegulator() public {
        vm.prank(loggerRole);
        vm.expectRevert(AuditLogger.InvalidAddress.selector);
        logger.logDataAccess(address(0), target, bytes32(0), bytes32(0));
    }

    function test_LogDataAccess_RevertsOnZeroTarget() public {
        vm.prank(loggerRole);
        vm.expectRevert(AuditLogger.InvalidAddress.selector);
        logger.logDataAccess(loggerRole, address(0), bytes32(0), bytes32(0));
    }

    // ============ View Function Tests ============

    function test_GetLog_RevertsOnNotFound() public {
        vm.expectRevert(AuditLogger.LogNotFound.selector);
        logger.getLog(999);
    }

    function test_GetLogsInRange() public {
        // Set a reasonable starting timestamp to avoid underflow
        uint256 baseTime = 1 days;
        vm.warp(baseTime);

        // Create log 0 at baseTime
        vm.prank(loggerRole);
        logger.createLog(
            AuditLogger.ActionType.CONFIG_CHANGE,
            target,
            bytes32(0),
            "",
            bytes32(0),
            AuditLogger.Severity.INFO,
            "Test1",
            bytes32(0),
            false
        );

        vm.warp(baseTime + 1 hours);

        // Create log 1 at baseTime + 1 hour
        vm.prank(loggerRole);
        logger.createLog(
            AuditLogger.ActionType.CONFIG_CHANGE,
            target,
            bytes32(0),
            "",
            bytes32(0),
            AuditLogger.Severity.INFO,
            "Test2",
            bytes32(0),
            false
        );

        vm.warp(baseTime + 2 hours);

        // Create log 2 at baseTime + 2 hours
        vm.prank(loggerRole);
        logger.createLog(
            AuditLogger.ActionType.CONFIG_CHANGE,
            target,
            bytes32(0),
            "",
            bytes32(0),
            AuditLogger.Severity.INFO,
            "Test3",
            bytes32(0),
            false
        );

        // Query range from baseTime to baseTime + 2 hours - should include all 3 logs
        uint256[] memory allLogs = logger.getLogsInRange(baseTime, baseTime + 2 hours);
        assertEq(allLogs.length, 3);

        // Query range from baseTime + 30 min to baseTime + 2 hours - should include logs 1 and 2
        uint256[] memory laterLogs = logger.getLogsInRange(baseTime + 30 minutes, baseTime + 2 hours);
        assertEq(laterLogs.length, 2);
    }

    function test_GetRecentLogs() public {
        // Create multiple logs
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(loggerRole);
            logger.createLog(
                AuditLogger.ActionType.CONFIG_CHANGE,
                target,
                bytes32(0),
                "",
                bytes32(0),
                AuditLogger.Severity.INFO,
                "Test",
                bytes32(0),
                false
            );
        }

        // Get recent logs with pagination
        AuditLogger.AuditLog[] memory recent = logger.getRecentLogs(0, 3);
        assertEq(recent.length, 3);
        assertEq(recent[0].id, 4); // Most recent first
        assertEq(recent[1].id, 3);
        assertEq(recent[2].id, 2);
    }

    function test_GetRecentLogs_ReturnsEmptyOnOffset() public {
        vm.prank(loggerRole);
        logger.createLog(
            AuditLogger.ActionType.CONFIG_CHANGE,
            target,
            bytes32(0),
            "",
            bytes32(0),
            AuditLogger.Severity.INFO,
            "Test",
            bytes32(0),
            false
        );

        AuditLogger.AuditLog[] memory recent = logger.getRecentLogs(10, 5);
        assertEq(recent.length, 0);
    }

    function test_IsWithinRetention() public {
        vm.prank(loggerRole);
        logger.createLog(
            AuditLogger.ActionType.CONFIG_CHANGE,
            target,
            bytes32(0),
            "",
            bytes32(0),
            AuditLogger.Severity.INFO,
            "Test",
            bytes32(0),
            false
        );

        assertTrue(logger.isWithinRetention(0));

        // Warp past retention
        vm.warp(block.timestamp + 8 * 365 days);
        assertFalse(logger.isWithinRetention(0));
    }

    function test_GetLogsPastRetention() public {
        // Set timestamp large enough to avoid underflow when subtracting retention period (7 years)
        // Retention period is 7 * 365 days, so we need timestamp > 7 * 365 days
        vm.warp(8 * 365 days);

        vm.prank(loggerRole);
        logger.createLog(
            AuditLogger.ActionType.CONFIG_CHANGE,
            target,
            bytes32(0),
            "",
            bytes32(0),
            AuditLogger.Severity.INFO,
            "Test",
            bytes32(0),
            false
        );

        // Log is fresh, so not past retention
        uint256[] memory pastRetention = logger.getLogsPastRetention(10);
        assertEq(pastRetention.length, 0);

        // Warp past retention period (8 more years)
        vm.warp(block.timestamp + 8 * 365 days);
        pastRetention = logger.getLogsPastRetention(10);
        assertEq(pastRetention.length, 1);
    }

    // ============ Admin Function Tests ============

    function test_SetRetentionPeriod() public {
        uint256 newPeriod = 10 * 365 days;

        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit RetentionPeriodUpdated(7 * 365 days, newPeriod);
        logger.setRetentionPeriod(newPeriod);

        assertEq(logger.retentionPeriod(), newPeriod);
    }

    function test_GrantLoggerRole() public {
        address newLogger = makeAddr("newLogger");

        vm.prank(admin);
        logger.grantLoggerRole(newLogger);

        assertTrue(logger.hasRole(logger.LOGGER_ROLE(), newLogger));
    }

    function test_GrantLoggerRole_RevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(AuditLogger.InvalidAddress.selector);
        logger.grantLoggerRole(address(0));
    }

    function test_RevokeLoggerRole() public {
        vm.prank(admin);
        logger.revokeLoggerRole(loggerRole);

        assertFalse(logger.hasRole(logger.LOGGER_ROLE(), loggerRole));
    }

    // ============ Stats Tests ============

    function test_Stats_UpdateCorrectly() public {
        vm.startPrank(loggerRole);

        logger.logTraceActivity(AuditLogger.ActionType.TRACE_REQUEST, loggerRole, target, bytes32(0), 1);
        logger.logTraceActivity(AuditLogger.ActionType.TRACE_APPROVAL, loggerRole, target, bytes32(0), 1);
        logger.logTraceActivity(AuditLogger.ActionType.TRACE_EXECUTION, loggerRole, target, bytes32(0), 1);
        logger.logKycUpdate(target, 0, 2, loggerRole);
        logger.logReserveVerification(1000 ether, 1000 ether, 10_000, true);
        logger.logEmergencyAction(admin, "Test", AuditLogger.Severity.HIGH);
        logger.logDataAccess(loggerRole, target, bytes32(0), bytes32(0));

        vm.stopPrank();

        AuditLogger.AuditStats memory stats = logger.getStats();
        assertEq(stats.totalLogs, 7);
        assertEq(stats.traceRequests, 1);
        assertEq(stats.traceApprovals, 1);
        assertEq(stats.traceExecutions, 1);
        assertEq(stats.kycUpdates, 1);
        assertEq(stats.reserveVerifications, 1);
        assertEq(stats.emergencyActions, 1);
        assertEq(stats.dataAccesses, 1);
    }
}
