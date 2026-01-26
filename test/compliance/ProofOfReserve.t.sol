// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ProofOfReserve } from "../../src/compliance/ProofOfReserve.sol";

// Mock contracts
contract MockAggregatorV3 {
    uint8 public decimals = 18;
    string public description = "Test Reserve Oracle";
    uint256 public version = 1;

    int256 private _answer;
    uint80 private _roundId;
    uint256 private _updatedAt;

    constructor() {
        _roundId = 1;
        _answer = int256(1000 ether);
        _updatedAt = block.timestamp;
    }

    function setLatestRoundData(uint80 roundId, int256 answer, uint256 updatedAt) external {
        _roundId = roundId;
        _answer = answer;
        _updatedAt = updatedAt;
    }

    function setDecimals(uint8 _decimals) external {
        decimals = _decimals;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}

contract MockStablecoin {
    uint256 private _totalSupply;

    function setTotalSupply(uint256 supply) external {
        _totalSupply = supply;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }
}

contract ProofOfReserveTest is Test {
    ProofOfReserve public por;
    MockAggregatorV3 public oracle;
    MockStablecoin public stablecoin;

    address public owner;

    event OracleConfigured(address indexed oracle, uint8 decimals, uint256 heartbeat);
    event StablecoinConfigured(address indexed stablecoin);
    event ReserveVerified(
        uint256 indexed verificationId, uint256 totalSupply, uint256 totalReserve, uint256 reserveRatio, bool isHealthy
    );
    event ReserveHealthy(uint256 reserveRatio);
    event ReserveUnhealthy(uint256 totalSupply, uint256 totalReserve, uint256 reserveRatio);
    event AutoPauseTriggered(uint256 reserveRatio, uint256 consecutiveUnhealthy);
    event AutoPauseThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event AutoPauseToggled(bool enabled);

    function setUp() public {
        owner = makeAddr("owner");

        vm.startPrank(owner);
        por = new ProofOfReserve(owner, 3);
        oracle = new MockAggregatorV3();
        stablecoin = new MockStablecoin();

        stablecoin.setTotalSupply(1000 ether);
        oracle.setLatestRoundData(1, int256(1000 ether), block.timestamp);

        por.configureOracle(address(oracle), 1 hours);
        por.configureStablecoin(address(stablecoin));
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor_InitializesCorrectly() public view {
        assertEq(por.owner(), owner);
        assertEq(por.autoPauseThreshold(), 3);
        assertTrue(por.autoPauseEnabled());
    }

    function test_Constructor_DefaultThreshold() public {
        vm.prank(owner);
        ProofOfReserve newPor = new ProofOfReserve(owner, 0);
        assertEq(newPor.autoPauseThreshold(), 3);
    }

    // ============ Oracle Configuration Tests ============

    function test_ConfigureOracle_Success() public {
        MockAggregatorV3 newOracle = new MockAggregatorV3();
        newOracle.setLatestRoundData(1, int256(1000 ether), block.timestamp);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit OracleConfigured(address(newOracle), 18, 2 hours);
        por.configureOracle(address(newOracle), 2 hours);

        ProofOfReserve.OracleConfig memory config = por.getOracleConfig();
        assertEq(config.oracle, address(newOracle));
        assertEq(config.decimals, 18);
        assertEq(config.heartbeat, 2 hours);
        assertTrue(config.isActive);
    }

    function test_ConfigureOracle_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ProofOfReserve.InvalidAddress.selector);
        por.configureOracle(address(0), 1 hours);
    }

    function test_ConfigureOracle_RevertsOnInvalidHeartbeat() public {
        MockAggregatorV3 newOracle = new MockAggregatorV3();

        vm.prank(owner);
        vm.expectRevert(ProofOfReserve.InvalidHeartbeat.selector);
        por.configureOracle(address(newOracle), 0);

        vm.prank(owner);
        vm.expectRevert(ProofOfReserve.InvalidHeartbeat.selector);
        por.configureOracle(address(newOracle), 25 hours);
    }

    function test_ConfigureOracle_RevertsOnInvalidOracleData() public {
        MockAggregatorV3 badOracle = new MockAggregatorV3();
        badOracle.setLatestRoundData(0, int256(1000 ether), block.timestamp);

        vm.prank(owner);
        vm.expectRevert(ProofOfReserve.InvalidOracleData.selector);
        por.configureOracle(address(badOracle), 1 hours);
    }

    function test_ConfigureOracle_RevertsOnNegativeAnswer() public {
        MockAggregatorV3 badOracle = new MockAggregatorV3();
        badOracle.setLatestRoundData(1, -1, block.timestamp);

        vm.prank(owner);
        vm.expectRevert(ProofOfReserve.InvalidOracleData.selector);
        por.configureOracle(address(badOracle), 1 hours);
    }

    function test_ConfigureOracle_RevertsOnStaleData() public {
        // Set a reasonable timestamp to avoid underflow when subtracting 25 hours
        vm.warp(2 days);

        MockAggregatorV3 staleOracle = new MockAggregatorV3();
        staleOracle.setLatestRoundData(1, int256(1000 ether), block.timestamp - 25 hours);

        vm.prank(owner);
        vm.expectRevert(ProofOfReserve.StaleOracleData.selector);
        por.configureOracle(address(staleOracle), 1 hours);
    }

    // ============ Stablecoin Configuration Tests ============

    function test_ConfigureStablecoin_Success() public {
        MockStablecoin newStablecoin = new MockStablecoin();

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit StablecoinConfigured(address(newStablecoin));
        por.configureStablecoin(address(newStablecoin));

        assertEq(address(por.stablecoin()), address(newStablecoin));
    }

    function test_ConfigureStablecoin_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ProofOfReserve.InvalidAddress.selector);
        por.configureStablecoin(address(0));
    }

    // ============ Verification Tests ============

    function test_VerifyReserve_Healthy() public {
        // Reserve = Supply = 100%
        oracle.setLatestRoundData(1, int256(1000 ether), block.timestamp);
        stablecoin.setTotalSupply(1000 ether);

        ProofOfReserve.ReserveStatus memory status = por.verifyReserve();

        assertTrue(status.isHealthy);
        assertEq(status.reserveRatio, 10_000); // 100%
        assertEq(status.totalSupply, 1000 ether);
        assertEq(status.totalReserve, 1000 ether);
        assertEq(por.verificationCount(), 1);
    }

    function test_VerifyReserve_HealthyOverCollateralized() public {
        // Reserve > Supply = >100%
        oracle.setLatestRoundData(1, int256(1200 ether), block.timestamp);
        stablecoin.setTotalSupply(1000 ether);

        ProofOfReserve.ReserveStatus memory status = por.verifyReserve();

        assertTrue(status.isHealthy);
        assertEq(status.reserveRatio, 12_000); // 120%
    }

    function test_VerifyReserve_Unhealthy() public {
        // Reserve < Supply = <100%
        oracle.setLatestRoundData(1, int256(900 ether), block.timestamp);
        stablecoin.setTotalSupply(1000 ether);

        ProofOfReserve.ReserveStatus memory status = por.verifyReserve();

        assertFalse(status.isHealthy);
        assertEq(status.reserveRatio, 9000); // 90%
        assertEq(por.unhealthyCount(), 1);
    }

    function test_VerifyReserve_EmitsEvents() public {
        oracle.setLatestRoundData(1, int256(1000 ether), block.timestamp);
        stablecoin.setTotalSupply(1000 ether);

        vm.expectEmit(true, false, false, true);
        emit ReserveVerified(1, 1000 ether, 1000 ether, 10_000, true);
        vm.expectEmit(false, false, false, true);
        emit ReserveHealthy(10_000);
        por.verifyReserve();
    }

    function test_VerifyReserve_ResetsUnhealthyCountOnHealthy() public {
        // First verification: unhealthy
        oracle.setLatestRoundData(1, int256(900 ether), block.timestamp);
        por.verifyReserve();
        assertEq(por.unhealthyCount(), 1);

        // Second verification: healthy
        oracle.setLatestRoundData(2, int256(1000 ether), block.timestamp);
        por.verifyReserve();
        assertEq(por.unhealthyCount(), 0);
    }

    function test_VerifyReserve_AutoPause() public {
        oracle.setLatestRoundData(1, int256(900 ether), block.timestamp);
        stablecoin.setTotalSupply(1000 ether);

        // Need 3 consecutive unhealthy to trigger auto-pause
        por.verifyReserve();
        assertFalse(por.paused());

        oracle.setLatestRoundData(2, int256(900 ether), block.timestamp);
        por.verifyReserve();
        assertFalse(por.paused());

        oracle.setLatestRoundData(3, int256(900 ether), block.timestamp);
        vm.expectEmit(false, false, false, true);
        emit AutoPauseTriggered(9000, 3);
        por.verifyReserve();
        assertTrue(por.paused());
    }

    function test_VerifyReserve_RevertsOnOracleNotConfigured() public {
        vm.prank(owner);
        ProofOfReserve newPor = new ProofOfReserve(owner, 3);

        vm.expectRevert(ProofOfReserve.OracleNotConfigured.selector);
        newPor.verifyReserve();
    }

    function test_VerifyReserve_RevertsOnOracleInactive() public {
        vm.prank(owner);
        por.deactivateOracle();

        vm.expectRevert(ProofOfReserve.OracleInactive.selector);
        por.verifyReserve();
    }

    function test_VerifyReserve_RevertsOnStablecoinNotConfigured() public {
        vm.startPrank(owner);
        ProofOfReserve newPor = new ProofOfReserve(owner, 3);
        newPor.configureOracle(address(oracle), 1 hours);
        vm.stopPrank();

        vm.expectRevert(ProofOfReserve.StablecoinNotConfigured.selector);
        newPor.verifyReserve();
    }

    function test_VerifyReserve_HandlesZeroSupply() public {
        stablecoin.setTotalSupply(0);

        ProofOfReserve.ReserveStatus memory status = por.verifyReserve();

        assertTrue(status.isHealthy);
        assertEq(status.reserveRatio, 10_000); // 100% when no supply
    }

    // ============ View Function Tests ============

    function test_GetCurrentStatus() public {
        oracle.setLatestRoundData(1, int256(1100 ether), block.timestamp);
        stablecoin.setTotalSupply(1000 ether);

        (uint256 totalSupply, uint256 totalReserve, uint256 reserveRatio, bool isHealthy) = por.getCurrentStatus();

        assertEq(totalSupply, 1000 ether);
        assertEq(totalReserve, 1100 ether);
        assertEq(reserveRatio, 11_000); // 110%
        assertTrue(isHealthy);
    }

    function test_GetLastStatus() public {
        por.verifyReserve();

        ProofOfReserve.ReserveStatus memory status = por.getLastStatus();
        assertEq(status.totalSupply, 1000 ether);
    }

    function test_GetHistoricalStatus() public {
        por.verifyReserve();

        oracle.setLatestRoundData(2, int256(1100 ether), block.timestamp);
        por.verifyReserve();

        ProofOfReserve.ReserveStatus memory status0 = por.getHistoricalStatus(0);
        ProofOfReserve.ReserveStatus memory status1 = por.getHistoricalStatus(1);

        assertEq(status0.totalReserve, 1000 ether);
        assertEq(status1.totalReserve, 1100 ether);
    }

    function test_GetHistoryCount() public {
        assertEq(por.getHistoryCount(), 0);

        por.verifyReserve();
        assertEq(por.getHistoryCount(), 1);

        oracle.setLatestRoundData(2, int256(1000 ether), block.timestamp);
        por.verifyReserve();
        assertEq(por.getHistoryCount(), 2);
    }

    function test_IsVerificationNeeded() public {
        (bool needed, string memory reason) = por.isVerificationNeeded();
        assertTrue(needed);
        assertEq(reason, "Never verified");

        por.verifyReserve();

        (needed, reason) = por.isVerificationNeeded();
        assertFalse(needed);
        assertEq(reason, "");

        vm.warp(block.timestamp + 2 hours);
        (needed, reason) = por.isVerificationNeeded();
        assertTrue(needed);
        assertEq(reason, "Heartbeat exceeded");
    }

    function test_CheckMintAllowed() public {
        oracle.setLatestRoundData(1, int256(1100 ether), block.timestamp);
        stablecoin.setTotalSupply(1000 ether);

        // Mint 100 more would still maintain 100%
        (bool sufficient, uint256 projectedRatio) = por.checkMintAllowed(100 ether);
        assertTrue(sufficient);
        assertEq(projectedRatio, 10_000); // Exactly 100%

        // Mint 101 more would drop below 100%
        (sufficient, projectedRatio) = por.checkMintAllowed(101 ether);
        assertFalse(sufficient);
        assertLt(projectedRatio, 10_000);
    }

    // ============ Admin Function Tests ============

    function test_SetAutoPauseThreshold() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit AutoPauseThresholdUpdated(3, 5);
        por.setAutoPauseThreshold(5);

        assertEq(por.autoPauseThreshold(), 5);
    }

    function test_SetAutoPauseThreshold_RevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(ProofOfReserve.InvalidThreshold.selector);
        por.setAutoPauseThreshold(0);
    }

    function test_SetAutoPauseEnabled() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit AutoPauseToggled(false);
        por.setAutoPauseEnabled(false);

        assertFalse(por.autoPauseEnabled());
    }

    function test_DeactivateOracle() public {
        vm.prank(owner);
        por.deactivateOracle();

        ProofOfReserve.OracleConfig memory config = por.getOracleConfig();
        assertFalse(config.isActive);
    }

    function test_ReactivateOracle() public {
        vm.prank(owner);
        por.deactivateOracle();

        vm.prank(owner);
        por.reactivateOracle();

        ProofOfReserve.OracleConfig memory config = por.getOracleConfig();
        assertTrue(config.isActive);
    }

    function test_ReactivateOracle_RevertsOnNotConfigured() public {
        vm.startPrank(owner);
        ProofOfReserve newPor = new ProofOfReserve(owner, 3);
        vm.expectRevert(ProofOfReserve.OracleNotConfigured.selector);
        newPor.reactivateOracle();
        vm.stopPrank();
    }

    function test_Pause() public {
        vm.prank(owner);
        por.pause();
        assertTrue(por.paused());
    }

    function test_Unpause() public {
        vm.prank(owner);
        por.pause();

        vm.prank(owner);
        por.unpause();
        assertFalse(por.paused());
    }

    function test_ResetUnhealthyCount() public {
        oracle.setLatestRoundData(1, int256(900 ether), block.timestamp);
        por.verifyReserve();
        assertEq(por.unhealthyCount(), 1);

        vm.prank(owner);
        por.resetUnhealthyCount();
        assertEq(por.unhealthyCount(), 0);
    }

    // ============ Decimal Handling Tests ============

    function test_VerifyReserve_HandlesLowerDecimals() public {
        MockAggregatorV3 lowDecimalOracle = new MockAggregatorV3();
        lowDecimalOracle.setDecimals(8);
        lowDecimalOracle.setLatestRoundData(1, int256(1000 * 1e8), block.timestamp); // 1000 with 8 decimals

        vm.prank(owner);
        por.configureOracle(address(lowDecimalOracle), 1 hours);

        stablecoin.setTotalSupply(1000 ether);

        ProofOfReserve.ReserveStatus memory status = por.verifyReserve();
        assertTrue(status.isHealthy);
        assertEq(status.totalReserve, 1000 ether);
    }
}
