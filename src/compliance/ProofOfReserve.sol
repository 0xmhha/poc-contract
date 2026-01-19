// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title IAggregatorV3
 * @notice Interface for Chainlink Price Feed / Proof of Reserve oracle
 */
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

/**
 * @title IStablecoin
 * @notice Interface for stablecoin total supply query
 */
interface IStablecoin {
    function totalSupply() external view returns (uint256);
}

/**
 * @title ProofOfReserve
 * @notice Verifies 100% reserve backing using Chainlink Proof of Reserve oracles
 * @dev Monitors reserve ratio and triggers auto-pause when reserves are insufficient
 *
 * Key Features:
 *   - Chainlink PoR oracle integration
 *   - 100% minimum reserve ratio enforcement
 *   - Auto-pause on insufficient reserves
 *   - Historical reserve status tracking
 *   - Configurable heartbeat and staleness thresholds
 */
contract ProofOfReserve is Ownable, Pausable, ReentrancyGuard {
    using SafeCast for int256;

    // ============ Constants ============
    uint256 public constant MIN_RESERVE_RATIO = 10000; // 100% in basis points
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DEFAULT_HEARTBEAT = 1 hours;
    uint256 public constant MAX_STALENESS = 24 hours;

    // ============ Structs ============
    struct ReserveStatus {
        uint256 totalSupply;
        uint256 totalReserve;
        uint256 reserveRatio; // in basis points
        uint256 timestamp;
        bool isHealthy;
        uint80 roundId;
    }

    struct OracleConfig {
        address oracle;
        uint8 decimals;
        uint256 heartbeat;
        bool isActive;
    }

    // ============ State Variables ============
    IStablecoin public stablecoin;
    OracleConfig public reserveOracle;

    ReserveStatus public lastStatus;
    ReserveStatus[] public statusHistory;

    uint256 public verificationCount;
    uint256 public lastVerificationTime;
    uint256 public unhealthyCount;
    uint256 public autoPauseThreshold; // Number of consecutive unhealthy before auto-pause

    bool public autoPauseEnabled;

    // ============ Events ============
    event OracleConfigured(
        address indexed oracle,
        uint8 decimals,
        uint256 heartbeat
    );
    event StablecoinConfigured(address indexed stablecoin);
    event ReserveVerified(
        uint256 indexed verificationId,
        uint256 totalSupply,
        uint256 totalReserve,
        uint256 reserveRatio,
        bool isHealthy
    );
    event ReserveHealthy(uint256 reserveRatio);
    event ReserveUnhealthy(
        uint256 totalSupply,
        uint256 totalReserve,
        uint256 reserveRatio
    );
    event AutoPauseTriggered(uint256 reserveRatio, uint256 consecutiveUnhealthy);
    event AutoPauseThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event AutoPauseToggled(bool enabled);

    // ============ Errors ============
    error InvalidAddress();
    error OracleNotConfigured();
    error StablecoinNotConfigured();
    error StaleOracleData();
    error InvalidOracleData();
    error InsufficientReserve();
    error OracleInactive();
    error InvalidHeartbeat();
    error InvalidThreshold();

    // ============ Constructor ============
    constructor(
        address initialOwner,
        uint256 _autoPauseThreshold
    ) Ownable(initialOwner) {
        autoPauseThreshold = _autoPauseThreshold > 0 ? _autoPauseThreshold : 3;
        autoPauseEnabled = true;
    }

    // ============ Configuration Functions ============

    /**
     * @notice Configure the Chainlink Proof of Reserve oracle
     * @param oracle Address of the Chainlink PoR oracle
     * @param heartbeat Expected update frequency
     */
    function configureOracle(
        address oracle,
        uint256 heartbeat
    ) external onlyOwner {
        if (oracle == address(0)) revert InvalidAddress();
        if (heartbeat == 0 || heartbeat > MAX_STALENESS) revert InvalidHeartbeat();

        IAggregatorV3 aggregator = IAggregatorV3(oracle);
        uint8 decimals = aggregator.decimals();

        // Verify oracle is responsive
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = aggregator.latestRoundData();

        if (roundId == 0 || answeredInRound < roundId) revert InvalidOracleData();
        if (answer <= 0) revert InvalidOracleData();
        if (block.timestamp - updatedAt > MAX_STALENESS) revert StaleOracleData();

        reserveOracle = OracleConfig({
            oracle: oracle,
            decimals: decimals,
            heartbeat: heartbeat,
            isActive: true
        });

        emit OracleConfigured(oracle, decimals, heartbeat);
    }

    /**
     * @notice Configure the stablecoin contract
     * @param _stablecoin Address of the stablecoin contract
     */
    function configureStablecoin(address _stablecoin) external onlyOwner {
        if (_stablecoin == address(0)) revert InvalidAddress();

        // Verify stablecoin is responsive
        IStablecoin(_stablecoin).totalSupply();

        stablecoin = IStablecoin(_stablecoin);

        emit StablecoinConfigured(_stablecoin);
    }

    /**
     * @notice Set auto-pause threshold
     * @param threshold Number of consecutive unhealthy verifications before auto-pause
     */
    function setAutoPauseThreshold(uint256 threshold) external onlyOwner {
        if (threshold == 0) revert InvalidThreshold();

        uint256 oldThreshold = autoPauseThreshold;
        autoPauseThreshold = threshold;

        emit AutoPauseThresholdUpdated(oldThreshold, threshold);
    }

    /**
     * @notice Enable or disable auto-pause feature
     * @param enabled True to enable, false to disable
     */
    function setAutoPauseEnabled(bool enabled) external onlyOwner {
        autoPauseEnabled = enabled;
        emit AutoPauseToggled(enabled);
    }

    /**
     * @notice Deactivate the oracle (emergency)
     */
    function deactivateOracle() external onlyOwner {
        reserveOracle.isActive = false;
    }

    /**
     * @notice Reactivate the oracle
     */
    function reactivateOracle() external onlyOwner {
        if (reserveOracle.oracle == address(0)) revert OracleNotConfigured();
        reserveOracle.isActive = true;
    }

    // ============ Verification Functions ============

    /**
     * @notice Verify current reserve status
     * @return status The current reserve status
     */
    function verifyReserve() external nonReentrant returns (ReserveStatus memory status) {
        status = _performVerification();

        // Auto-pause logic
        if (!status.isHealthy) {
            unhealthyCount++;
            emit ReserveUnhealthy(status.totalSupply, status.totalReserve, status.reserveRatio);

            if (autoPauseEnabled && unhealthyCount >= autoPauseThreshold && !paused()) {
                _pause();
                emit AutoPauseTriggered(status.reserveRatio, unhealthyCount);
            }
        } else {
            unhealthyCount = 0;
            emit ReserveHealthy(status.reserveRatio);
        }

        return status;
    }

    /**
     * @notice Internal verification logic
     */
    function _performVerification() internal returns (ReserveStatus memory status) {
        if (reserveOracle.oracle == address(0)) revert OracleNotConfigured();
        if (!reserveOracle.isActive) revert OracleInactive();
        if (address(stablecoin) == address(0)) revert StablecoinNotConfigured();

        // Get reserve data from Chainlink
        IAggregatorV3 aggregator = IAggregatorV3(reserveOracle.oracle);
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = aggregator.latestRoundData();

        // Validate oracle data
        if (roundId == 0 || answeredInRound < roundId) revert InvalidOracleData();
        if (answer <= 0) revert InvalidOracleData();
        if (block.timestamp - updatedAt > reserveOracle.heartbeat * 2) revert StaleOracleData();

        // Get total supply
        uint256 totalSupply = stablecoin.totalSupply();

        // Normalize reserve to same decimals as totalSupply (assuming 18 decimals)
        uint256 totalReserve = answer.toUint256();
        if (reserveOracle.decimals < 18) {
            totalReserve = totalReserve * (10 ** (18 - reserveOracle.decimals));
        } else if (reserveOracle.decimals > 18) {
            totalReserve = totalReserve / (10 ** (reserveOracle.decimals - 18));
        }

        // Calculate reserve ratio in basis points
        uint256 reserveRatio;
        if (totalSupply > 0) {
            reserveRatio = (totalReserve * BASIS_POINTS) / totalSupply;
        } else {
            reserveRatio = BASIS_POINTS; // 100% if no supply
        }

        bool isHealthy = reserveRatio >= MIN_RESERVE_RATIO;

        status = ReserveStatus({
            totalSupply: totalSupply,
            totalReserve: totalReserve,
            reserveRatio: reserveRatio,
            timestamp: block.timestamp,
            isHealthy: isHealthy,
            roundId: roundId
        });

        // Store status
        lastStatus = status;
        statusHistory.push(status);
        verificationCount++;
        lastVerificationTime = block.timestamp;

        emit ReserveVerified(
            verificationCount,
            totalSupply,
            totalReserve,
            reserveRatio,
            isHealthy
        );
    }

    // ============ View Functions ============

    /**
     * @notice Get current reserve status without state changes
     * @return totalSupply Current total supply of stablecoin
     * @return totalReserve Current total reserve amount
     * @return reserveRatio Reserve ratio in basis points
     * @return isHealthy True if reserve ratio meets minimum threshold
     */
    function getCurrentStatus() external view returns (
        uint256 totalSupply,
        uint256 totalReserve,
        uint256 reserveRatio,
        bool isHealthy
    ) {
        if (reserveOracle.oracle == address(0)) revert OracleNotConfigured();
        if (address(stablecoin) == address(0)) revert StablecoinNotConfigured();

        IAggregatorV3 aggregator = IAggregatorV3(reserveOracle.oracle);
        (, int256 answer, , uint256 updatedAt,) = aggregator.latestRoundData();

        if (answer <= 0 || block.timestamp - updatedAt > reserveOracle.heartbeat * 2) {
            return (0, 0, 0, false);
        }

        totalSupply = stablecoin.totalSupply();

        totalReserve = answer.toUint256();
        if (reserveOracle.decimals < 18) {
            totalReserve = totalReserve * (10 ** (18 - reserveOracle.decimals));
        } else if (reserveOracle.decimals > 18) {
            totalReserve = totalReserve / (10 ** (reserveOracle.decimals - 18));
        }

        if (totalSupply > 0) {
            reserveRatio = (totalReserve * BASIS_POINTS) / totalSupply;
        } else {
            reserveRatio = BASIS_POINTS;
        }

        isHealthy = reserveRatio >= MIN_RESERVE_RATIO;
    }

    /**
     * @notice Get the last verification status
     * @return ReserveStatus struct
     */
    function getLastStatus() external view returns (ReserveStatus memory) {
        return lastStatus;
    }

    /**
     * @notice Get historical status by index
     * @param index Index in status history
     * @return ReserveStatus struct
     */
    function getHistoricalStatus(uint256 index) external view returns (ReserveStatus memory) {
        require(index < statusHistory.length, "Index out of bounds");
        return statusHistory[index];
    }

    /**
     * @notice Get number of historical records
     * @return count Number of records
     */
    function getHistoryCount() external view returns (uint256) {
        return statusHistory.length;
    }

    /**
     * @notice Check if reserve verification is needed
     * @return needed True if verification is recommended
     * @return reason Reason string
     */
    function isVerificationNeeded() external view returns (bool needed, string memory reason) {
        if (lastVerificationTime == 0) {
            return (true, "Never verified");
        }

        if (block.timestamp - lastVerificationTime > reserveOracle.heartbeat) {
            return (true, "Heartbeat exceeded");
        }

        if (!lastStatus.isHealthy) {
            return (true, "Last status unhealthy");
        }

        return (false, "");
    }

    /**
     * @notice Get oracle configuration
     * @return OracleConfig struct
     */
    function getOracleConfig() external view returns (OracleConfig memory) {
        return reserveOracle;
    }

    /**
     * @notice Check if reserves are sufficient for a mint operation
     * @param mintAmount Amount to mint
     * @return sufficient True if reserves would remain sufficient
     * @return projectedRatio Projected reserve ratio after mint
     */
    function checkMintAllowed(
        uint256 mintAmount
    ) external view returns (bool sufficient, uint256 projectedRatio) {
        if (reserveOracle.oracle == address(0) || address(stablecoin) == address(0)) {
            return (false, 0);
        }

        IAggregatorV3 aggregator = IAggregatorV3(reserveOracle.oracle);
        (, int256 answer, , ,) = aggregator.latestRoundData();

        if (answer <= 0) return (false, 0);

        uint256 totalReserve = answer.toUint256();
        if (reserveOracle.decimals < 18) {
            totalReserve = totalReserve * (10 ** (18 - reserveOracle.decimals));
        } else if (reserveOracle.decimals > 18) {
            totalReserve = totalReserve / (10 ** (reserveOracle.decimals - 18));
        }

        uint256 newTotalSupply = stablecoin.totalSupply() + mintAmount;

        if (newTotalSupply > 0) {
            projectedRatio = (totalReserve * BASIS_POINTS) / newTotalSupply;
        } else {
            projectedRatio = BASIS_POINTS;
        }

        sufficient = projectedRatio >= MIN_RESERVE_RATIO;
    }

    // ============ Admin Functions ============

    /**
     * @notice Pause the contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency function to clear unhealthy count
     * @dev Should only be used after manual verification
     */
    function resetUnhealthyCount() external onlyOwner {
        unhealthyCount = 0;
    }
}
