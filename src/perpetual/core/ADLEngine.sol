// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IADLEngine } from "../interfaces/IADLEngine.sol";
import { IPositionManager } from "../interfaces/IPositionManager.sol";
import { IMarginManager } from "../interfaces/IMarginManager.sol";
import { IInsuranceFund } from "../interfaces/IInsuranceFund.sol";
import { PerpetualTypes } from "../libraries/PerpetualTypes.sol";
import { PerpetualMath } from "../libraries/PerpetualMath.sol";
import { PerpetualErrors } from "../libraries/PerpetualErrors.sol";
import { PerpetualEvents } from "../libraries/PerpetualEvents.sol";
import { Constants } from "../../common/libraries/Constants.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Testnet isolated-margin ADL: reduces profitable opposite-side positions
///         and withholds realized profit to resolve registered, insurance-uncovered debt.
/// @dev Positions and funding-adjusted priorities are read live. No arbitrary debt can
///      be supplied by keepers, and no fees or unrelated collateral fund the haircut.
contract ADLEngine is IADLEngine, ReentrancyGuard {
    uint256 private constant PRECISION = Constants.PRECISION;
    uint256 private constant BPS_PRECISION = Constants.BPS_PRECISION;
    uint8 public constant MAX_ADL_LEVEL = 5;
    uint256 public constant MAX_ADL_BATCH_SIZE = 50;
    uint256[5] public DEFAULT_LEVEL_THRESHOLDS = [8000, 6000, 4000, 2000, 1000];

    struct Bankruptcy {
        uint32 marketId;
        PerpetualTypes.PositionSide side;
        uint128 remainingSize;
        uint128 settlementMarkPrice;
        uint256 remainingDeficit;
    }

    struct ADLStats {
        uint256 totalADLEvents;
        uint256 totalADLVolume;
        uint256 lastADLTime;
    }

    mapping(bytes32 => Bankruptcy) private _bankruptcies;
    mapping(bytes32 => bool) private _registered;
    mapping(uint32 => uint256) private _marketDeficits;
    mapping(uint32 => bool) private _adlActive;
    mapping(uint32 => uint8) private _adlLevels;
    mapping(uint32 => ADLStats) private _adlStats;
    mapping(uint8 => uint256) private _levelThresholds;
    mapping(uint32 => mapping(PerpetualTypes.PositionSide => bytes32[])) private _priorityQueues;
    address private _admin;
    address private _engine;
    address private _liquidator;
    IInsuranceFund private _insuranceFund;
    IPositionManager private _positionManager;
    IMarginManager private _marginManager;

    event BankruptcyRegistered(bytes32 indexed positionKey, uint32 indexed marketId, uint128 size, uint256 deficit);
    event DeficitResolved(bytes32 indexed positionKey, uint256 haircut, uint256 remainingDeficit);

    modifier onlyAuthorized() {
        if (msg.sender != _admin && msg.sender != _engine) revert PerpetualErrors.Unauthorized(msg.sender);
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != _admin) revert PerpetualErrors.Unauthorized(msg.sender);
        _;
    }

    constructor(address admin) {
        if (admin == address(0)) revert PerpetualErrors.ZeroAddress();
        _admin = admin;
        for (uint8 i = 0; i < MAX_ADL_LEVEL; i++) {
            _levelThresholds[i + 1] = DEFAULT_LEVEL_THRESHOLDS[i];
        }
    }

    function isADLActive(uint32 marketId) external view override returns (bool) {
        return _adlActive[marketId];
    }

    function getADLLevel(uint32 marketId) external view override returns (uint8) {
        return _adlLevels[marketId];
    }

    function getMarketDeficit(uint32 marketId) external view override returns (uint256) {
        return _marketDeficits[marketId];
    }

    function getBankruptcy(bytes32 key) external view returns (Bankruptcy memory) {
        return _bankruptcies[key];
    }

    function getADLPriority(bytes32 key) external view override returns (uint256) {
        return _info(key).priority;
    }

    function getADLInfo(bytes32 key) external view override returns (PerpetualTypes.ADLInfo memory) {
        return _info(key);
    }

    function getADLTargets(uint32 marketId, PerpetualTypes.PositionSide side, uint256 limit)
        external
        view
        override
        returns (bytes32[] memory)
    {
        return _targets(marketId, side, limit);
    }

    function shouldTriggerADL(uint32 marketId) external view override returns (bool, uint256 deficit) {
        if (address(_insuranceFund) == address(0)) revert PerpetualErrors.NotInitialized();
        deficit = _marketDeficits[marketId];
        if (deficit > 0) return (true, deficit);
        uint256 threshold =
            PerpetualMath.mulDiv(_insuranceFund.getTargetAmount(), _insuranceFund.getADLThreshold(), BPS_PRECISION);
        uint256 balance = _insuranceFund.getTotalBalance();
        return (balance < threshold, balance < threshold ? threshold - balance : 0);
    }

    function getADLStats(uint32 marketId) external view override returns (uint256, uint256, uint256) {
        ADLStats storage stats = _adlStats[marketId];
        return (stats.totalADLEvents, stats.totalADLVolume, stats.lastADLTime);
    }

    function registerBankruptcy(
        bytes32 key,
        uint32 marketId,
        PerpetualTypes.PositionSide side,
        uint128 size,
        uint256 deficit
    ) external override {
        if (msg.sender != _liquidator) revert PerpetualErrors.Unauthorized(msg.sender);
        _requireConfigured();
        PerpetualTypes.Position memory pos = _positionManager.getPosition(key);
        if (
            _registered[key] || size == 0 || deficit == 0 || pos.openedAt == 0
                || pos.status != PerpetualTypes.PositionStatus.Liquidated || pos.marketId != marketId
                || pos.side != side
        ) {
            revert PerpetualErrors.InvalidParameter("invalid bankruptcy");
        }
        _registered[key] = true;
        _bankruptcies[key] = Bankruptcy(marketId, side, size, _positionManager.getMarkPrice(marketId), deficit);
        _marketDeficits[marketId] += deficit;
        _adlActive[marketId] = true;
        uint256 ratio = _insuranceFund.getFundingRatio();
        uint8 level = 1;
        for (uint8 i = 1; i <= MAX_ADL_LEVEL; i++) {
            if (ratio < _levelThresholds[i]) level = i;
        }
        _adlLevels[marketId] = level;
        emit BankruptcyRegistered(key, marketId, size, deficit);
    }

    function executeADL(bytes32 bankruptKey, bytes32 counterpartyKey, uint128 size)
        external
        override
        onlyAuthorized
        nonReentrant
        returns (uint128)
    {
        return _execute(bankruptKey, counterpartyKey, size);
    }

    function batchExecuteADL(bytes32 bankruptKey, bytes32[] calldata keys, uint128[] calldata sizes)
        external
        override
        onlyAuthorized
        nonReentrant
        returns (uint128 totalExecuted)
    {
        if (keys.length != sizes.length) revert PerpetualErrors.InvalidParameter("array length mismatch");
        if (keys.length > MAX_ADL_BATCH_SIZE) revert PerpetualErrors.InvalidParameter("batch size exceeded");
        for (uint256 i = 0; i < keys.length; i++) {
            totalExecuted += _execute(bankruptKey, keys[i], sizes[i]);
        }
    }

    function autoExecuteADL(bytes32 bankruptKey)
        external
        override
        onlyAuthorized
        nonReentrant
        returns (uint128 totalExecuted, uint256 adlCount)
    {
        _requireConfigured();
        Bankruptcy storage debt = _bankruptcies[bankruptKey];
        if (!_adlActive[debt.marketId] || debt.remainingDeficit == 0) revert PerpetualErrors.ADLNotRequired();
        PerpetualTypes.PositionSide side = _opposite(debt.side);
        bytes32[] memory targets = _targets(debt.marketId, side, MAX_ADL_BATCH_SIZE);
        for (uint256 i = 0; i < targets.length && debt.remainingSize != 0; i++) {
            PerpetualTypes.Position memory pos = _positionManager.getPosition(targets[i]);
            uint128 size = pos.size < debt.remainingSize ? pos.size : debt.remainingSize;
            if (!_canSettle(debt, targets[i], pos, size)) continue;
            totalExecuted += _execute(bankruptKey, targets[i], size);
            adlCount++;
        }
        if (adlCount == 0) revert PerpetualErrors.NoADLCandidates(debt.marketId, side);
    }

    function updatePriorityQueue(uint32 marketId, PerpetualTypes.PositionSide side) external override onlyAuthorized {
        bytes32[] memory targets = _targets(marketId, side, MAX_ADL_BATCH_SIZE);
        _priorityQueues[marketId][side] = targets;
        emit PerpetualEvents.ADLPriorityUpdated(marketId, side, targets.length == 0 ? 0 : _info(targets[0]).priority);
    }

    function setADLActive(uint32 marketId, bool active) external override onlyAdmin {
        _adlActive[marketId] = active;
    }

    function setADLLevel(uint32 marketId, uint8 level) external onlyAdmin {
        if (level > MAX_ADL_LEVEL) revert PerpetualErrors.InvalidParameter("invalid ADL level");
        _adlLevels[marketId] = level;
    }

    function setADLLevelThreshold(uint8 level, uint256 threshold) external override onlyAdmin {
        if (level == 0 || level > MAX_ADL_LEVEL || threshold > BPS_PRECISION) {
            revert PerpetualErrors.InvalidParameter("invalid ADL threshold");
        }
        _levelThresholds[level] = threshold;
    }

    function setEngine(address engine) external onlyAdmin {
        if (engine == address(0)) revert PerpetualErrors.ZeroAddress();
        _engine = engine;
    }

    function setLiquidator(address liquidator) external onlyAdmin {
        if (liquidator == address(0)) revert PerpetualErrors.ZeroAddress();
        _liquidator = liquidator;
    }

    function setPositionManager(address manager) external onlyAdmin {
        if (manager == address(0)) revert PerpetualErrors.ZeroAddress();
        _positionManager = IPositionManager(manager);
    }

    function setMarginManager(address manager) external onlyAdmin {
        if (manager == address(0)) revert PerpetualErrors.ZeroAddress();
        _marginManager = IMarginManager(manager);
    }

    function setInsuranceFund(address fund) external onlyAdmin {
        if (fund == address(0)) revert PerpetualErrors.ZeroAddress();
        _insuranceFund = IInsuranceFund(fund);
    }

    function _requireConfigured() internal view {
        if (
            address(_positionManager) == address(0) || address(_marginManager) == address(0)
                || address(_insuranceFund) == address(0)
        ) revert PerpetualErrors.NotInitialized();
    }

    function _info(bytes32 key) internal view returns (PerpetualTypes.ADLInfo memory info) {
        _requireConfigured();
        PerpetualTypes.Position memory pos = _positionManager.getPosition(key);
        if (pos.openedAt == 0) revert PerpetualErrors.PositionNotFound(key);
        info.positionKey = key;
        info.trader = pos.trader;
        if (pos.status != PerpetualTypes.PositionStatus.Open) return info;
        PerpetualTypes.PositionResult memory result = _positionManager.getPositionResult(key);
        info.unrealizedPnL = result.unrealizedPnL - result.accumulatedFunding;
        if (result.equity != 0) {
            uint256 value = PerpetualMath.mulDiv(pos.size, _positionManager.getMarkPrice(pos.marketId), PRECISION);
            info.leverage = PerpetualMath.mulDiv(value, PRECISION, result.equity);
            if (info.unrealizedPnL > 0) {
                uint256 pnlRatio = PerpetualMath.mulDiv(uint256(info.unrealizedPnL), PRECISION, result.equity);
                info.priority = PerpetualMath.mulDiv(pnlRatio, info.leverage, PRECISION);
            }
        }
    }

    function _targets(uint32 marketId, PerpetualTypes.PositionSide side, uint256 limit)
        internal
        view
        returns (bytes32[] memory targets)
    {
        _requireConfigured();
        bytes32[] memory keys = _positionManager.getMarketPositions(marketId, side);
        uint256 capacity = limit < MAX_ADL_BATCH_SIZE ? limit : MAX_ADL_BATCH_SIZE;
        if (capacity > keys.length) capacity = keys.length;
        targets = new bytes32[](capacity);
        uint256[] memory priorities = new uint256[](capacity);
        uint256 count;
        for (uint256 i = 0; i < keys.length && capacity != 0; i++) {
            uint256 priority = _info(keys[i]).priority;
            if (priority == 0) continue;
            uint256 index;
            while (index < count && priority <= priorities[index]) index++;
            if (index == capacity) continue;
            if (count < capacity) count++;
            for (uint256 j = count - 1; j > index; j--) {
                targets[j] = targets[j - 1];
                priorities[j] = priorities[j - 1];
            }
            targets[index] = keys[i];
            priorities[index] = priority;
        }
        assembly ("memory-safe") { mstore(targets, count) }
    }

    function _execute(bytes32 bankruptKey, bytes32 counterpartyKey, uint128 size) internal returns (uint128) {
        _requireConfigured();
        Bankruptcy storage debt = _bankruptcies[bankruptKey];
        if (!_adlActive[debt.marketId] || debt.remainingDeficit == 0) revert PerpetualErrors.ADLNotRequired();
        PerpetualTypes.Position memory pos = _positionManager.getPosition(counterpartyKey);
        if (
            pos.openedAt == 0 || pos.status != PerpetualTypes.PositionStatus.Open || pos.marketId != debt.marketId
                || pos.side != _opposite(debt.side) || _info(counterpartyKey).priority == 0
        ) {
            revert PerpetualErrors.NotADLCandidate(counterpartyKey);
        }
        if (size == 0) revert PerpetualErrors.ZeroSize();
        if (size > pos.size || size > debt.remainingSize) {
            revert PerpetualErrors.ExceedsPositionSize(
                counterpartyKey, size, pos.size < debt.remainingSize ? pos.size : debt.remainingSize
            );
        }
        uint256 haircut = PerpetualMath.mulDivRoundUp(debt.remainingDeficit, size, debt.remainingSize);
        if (!_canSettle(debt, counterpartyKey, pos, size)) revert PerpetualErrors.NotADLCandidate(counterpartyKey);
        uint128 price = debt.settlementMarkPrice;
        (uint256 released, int256 pnl) = _positionManager.reduceForADL(counterpartyKey, size, price);
        if (pnl <= 0 || uint256(pnl) < haircut) revert PerpetualErrors.NotADLCandidate(counterpartyKey);
        _marginManager.settleADL(pos.trader, released, pnl, haircut);
        debt.remainingSize -= size;
        debt.remainingDeficit -= haircut;
        _marketDeficits[debt.marketId] -= haircut;
        if (debt.remainingDeficit == 0) debt.remainingSize = 0;
        if (_marketDeficits[debt.marketId] == 0) {
            _adlActive[debt.marketId] = false;
            _adlLevels[debt.marketId] = 0;
        }
        ADLStats storage stats = _adlStats[debt.marketId];
        stats.totalADLEvents++;
        stats.totalADLVolume += size;
        stats.lastADLTime = block.timestamp;
        emit PerpetualEvents.ADLExecuted(bankruptKey, counterpartyKey, debt.marketId, size, price);
        emit DeficitResolved(bankruptKey, haircut, debt.remainingDeficit);
        return size;
    }

    function _canSettle(Bankruptcy storage debt, bytes32 key, PerpetualTypes.Position memory pos, uint128 size)
        internal
        view
        returns (bool)
    {
        bool isLong = pos.side == PerpetualTypes.PositionSide.Long;
        int256 funding = _positionManager.getFundingPayment(key, size);
        int256 settlementPnL =
            PerpetualMath.calculateRealizedPnL(pos.entryPrice, debt.settlementMarkPrice, size, isLong) - funding;
        int256 livePnL = PerpetualMath.calculateRealizedPnL(
            pos.entryPrice, _positionManager.getMarkPrice(pos.marketId), size, isLong
        ) - funding;
        uint256 haircut = PerpetualMath.mulDivRoundUp(debt.remainingDeficit, size, debt.remainingSize);
        return settlementPnL > 0 && uint256(settlementPnL) >= haircut && settlementPnL - int256(haircut) <= livePnL;
    }

    function _opposite(PerpetualTypes.PositionSide side) internal pure returns (PerpetualTypes.PositionSide) {
        return
            side == PerpetualTypes.PositionSide.Long
                ? PerpetualTypes.PositionSide.Short
                : PerpetualTypes.PositionSide.Long;
    }
}
