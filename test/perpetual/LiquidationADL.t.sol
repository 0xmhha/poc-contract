// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { PerpetualEngine } from "../../src/perpetual/PerpetualEngine.sol";
import { PositionManager } from "../../src/perpetual/core/PositionManager.sol";
import { MarginManager } from "../../src/perpetual/core/MarginManager.sol";
import { OrderManager } from "../../src/perpetual/core/OrderManager.sol";
import { Liquidator } from "../../src/perpetual/core/Liquidator.sol";
import { ADLEngine } from "../../src/perpetual/core/ADLEngine.sol";
import { InsuranceFund } from "../../src/perpetual/core/InsuranceFund.sol";
import { PerpetualTypes } from "../../src/perpetual/libraries/PerpetualTypes.sol";
import { PerpetualErrors } from "../../src/perpetual/libraries/PerpetualErrors.sol";
import { PerpetualEvents } from "../../src/perpetual/libraries/PerpetualEvents.sol";
import { PerpetualMath } from "../../src/perpetual/libraries/PerpetualMath.sol";
import { MarkPriceMock } from "./mocks/MarkPriceMock.sol";

contract SixDecimalCollateralMock is ERC20 {
    constructor() ERC20("Six decimal", "SIX") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract PerpetualCollateralMock is ERC20 {
    constructor() ERC20("Collateral", "COL") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Integration tests use the real ledgers, token transfers and insurance fund.
contract LiquidationADLTest is Test {
    PerpetualCollateralMock internal token;
    PerpetualEngine internal engine;
    PositionManager internal pm;
    MarginManager internal mm;
    OrderManager internal om;
    Liquidator internal liquidator;
    ADLEngine internal adl;
    InsuranceFund internal insurance;
    MarkPriceMock internal oracle;
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");
    uint32 internal market;

    function setUp() public {
        assertEq(block.chainid, 31337, "tests must target Anvil 31337");
        vm.warp(1000);
        token = new PerpetualCollateralMock();
        engine = new PerpetualEngine(admin, address(token));
        pm = new PositionManager(admin);
        mm = new MarginManager(admin, address(token));
        om = new OrderManager(admin);
        liquidator = new Liquidator(admin, address(token));
        adl = new ADLEngine(admin);
        insurance = new InsuranceFund(admin, address(token), 1000e18);
        oracle = new MarkPriceMock();
        vm.startPrank(admin);
        pm.setEngine(address(engine));
        mm.setEngine(address(engine));
        om.setEngine(address(engine));
        pm.setLiquidator(address(liquidator));
        pm.setADLEngine(address(adl));
        mm.setLiquidator(address(liquidator));
        mm.setADLEngine(address(adl));
        liquidator.setPositionManager(address(pm));
        liquidator.setMarginManager(address(mm));
        liquidator.setInsuranceFund(address(insurance));
        liquidator.setADLEngine(address(adl));
        adl.setPositionManager(address(pm));
        adl.setMarginManager(address(mm));
        adl.setInsuranceFund(address(insurance));
        adl.setLiquidator(address(liquidator));
        insurance.setLiquidator(address(liquidator));
        engine.setComponents(
            address(pm), address(mm), address(om), address(liquidator), address(insurance), address(adl)
        );
        market = engine.createMarket("BASE", "COL", _config());
        engine.setOracles(market, address(oracle), address(oracle));
        vm.stopPrank();
        oracle.setPrice(market, 100e18);
    }

    function _config() internal pure returns (PerpetualTypes.MarketConfig memory config) {
        config.maxLeverage = 100;
        config.maintenanceMarginBps = 500;
        config.initialMarginBps = 1000;
        config.liquidationFeeBps = 100;
        config.maxPositionSize = 1000e18;
        config.maxOpenInterest = 10000e18;
    }

    function _open(address trader, PerpetualTypes.PositionSide side, uint128 size, uint128 margin)
        internal
        returns (bytes32 key)
    {
        token.mint(trader, margin);
        vm.startPrank(trader);
        token.approve(address(mm), margin);
        mm.deposit(margin);
        vm.stopPrank();
        vm.startPrank(admin);
        mm.lockMargin(trader, margin);
        key = pm.openPosition(trader, market, side, size, margin, 10, 100e18);
        vm.stopPrank();
    }

    function _fund(uint256 amount) internal {
        token.mint(admin, amount);
        vm.startPrank(admin);
        token.approve(address(insurance), amount);
        insurance.adminDeposit(amount);
        vm.stopPrank();
    }

    function _liquidate(bytes32 key) internal returns (uint256 size, uint256 reward) {
        vm.prank(keeper);
        return liquidator.liquidate(key);
    }

    function _bankruptLong(uint256 cover) internal returns (bytes32 key, bytes32 counterparty) {
        key = _open(alice, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        counterparty = _open(bob, PerpetualTypes.PositionSide.Short, 10e18, 100e18);
        if (cover != 0) _fund(cover);
        oracle.setPrice(market, 80e18);
        _liquidate(key);
    }

    function test_LiquidationUsesLivePriceAndSettlesAllLedgers() public {
        bytes32 key = _open(alice, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        (bool canLiq,) = liquidator.canLiquidate(key);
        assertFalse(canLiq);
        oracle.setPrice(market, 94e18);
        (canLiq,) = liquidator.canLiquidate(key);
        assertTrue(canLiq);
        PerpetualTypes.LiquidationInfo memory info = liquidator.getLiquidationInfo(key);
        assertEq(info.trader, alice);
        assertEq(info.marketId, market);
        assertEq(info.price, 94e18);
        assertEq(info.pnl, -60e18);
        assertEq(info.liquidationFee, 9.4e18);
        assertEq(info.remainingMargin, 30.6e18);
        vm.expectEmit(true, true, true, true, address(liquidator));
        emit PerpetualEvents.PositionLiquidated(key, alice, keeper, 10e18, 94e18, -60e18, 9.4e18);
        (uint256 size, uint256 reward) = _liquidate(key);
        assertEq(size, 10e18);
        assertEq(reward, 4.7e18);
        assertEq(uint8(pm.getPosition(key).status), uint8(PerpetualTypes.PositionStatus.Liquidated));
        assertEq(pm.getPosition(key).size, 0);
        assertEq(pm.getOpenInterest(market, PerpetualTypes.PositionSide.Long), 0);
        assertEq(pm.getMarketPositions(market, PerpetualTypes.PositionSide.Long).length, 0);
        assertEq(pm.getTraderPositions(alice).length, 0);
        assertEq(mm.getLockedMargin(alice), 0);
        assertEq(mm.getAvailableMargin(alice), 30.6e18);
        assertEq(insurance.getMarketBalance(market), 2.35e18);
        assertEq(token.balanceOf(address(insurance)), 2.35e18);
        assertEq(liquidator.getPendingReward(keeper), 4.7e18);
        vm.prank(keeper);
        assertEq(liquidator.claimReward(), 4.7e18);
        assertEq(token.balanceOf(keeper), 4.7e18);
        vm.prank(admin);
        liquidator.withdrawProtocolFees(admin, 2.35e18);
        assertEq(token.balanceOf(address(liquidator)), 0);
        (uint256 count, uint256 value, uint256 fees) = liquidator.getLiquidationStats(market);
        assertEq(count, 1);
        assertEq(value, 940e18);
        assertEq(fees, 9.4e18);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.PositionNotOpen.selector, key));
        liquidator.liquidate(key);
    }

    function test_ShortLiquidationUsesActualMarket() public {
        bytes32 key = _open(alice, PerpetualTypes.PositionSide.Short, 10e18, 100e18);
        oracle.setPrice(market, 106e18);
        (uint256 size,) = _liquidate(key);
        assertEq(size, 10e18);
        assertEq(mm.getAvailableMargin(alice), 29.4e18);
        assertEq(pm.getOpenInterest(market, PerpetualTypes.PositionSide.Short), 0);
    }

    function test_PartialLiquidationPreservesResidualMarginFundingAndInterest() public {
        bytes32 key = _open(alice, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        oracle.setPrice(market, 94e18);
        vm.prank(admin);
        pm.updateCumulativeFundingIndex(market, 1e18);
        vm.prank(keeper);
        (uint256 size, uint256 reward) = liquidator.partialLiquidate(key, 5e18);
        assertEq(size, 5e18);
        assertEq(reward, 2.35e18);
        assertEq(pm.getPosition(key).size, 5e18);
        assertEq(pm.getPosition(key).margin, 50e18);
        assertEq(pm.getPositionResult(key).accumulatedFunding, 5e18);
        assertEq(mm.getLockedMargin(alice), 50e18);
        assertEq(mm.getAvailableMargin(alice), 10.3e18);
        assertEq(pm.getOpenInterest(market, PerpetualTypes.PositionSide.Long), 5e18);
        _liquidate(key);
        assertEq(mm.getAvailableMargin(alice), 20.6e18);
    }

    function test_PartialLiquidationRejectsBankruptcyAndDust() public {
        bytes32 key = _open(alice, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        oracle.setPrice(market, 80e18);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.PartialLiquidationNotAllowed.selector, key));
        liquidator.partialLiquidate(key, 5e18);
        oracle.setPrice(market, 94e18);
        vm.prank(admin);
        liquidator.setMinLiquidationSize(market, 3e18);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.PartialLiquidationNotAllowed.selector, key));
        liquidator.partialLiquidate(key, 8e18);
        vm.expectRevert(PerpetualErrors.ZeroSize.selector);
        liquidator.partialLiquidate(key, 0);
        _liquidate(key);
    }

    function test_LiquidationFeeCannotCreateDebtOrUnfundedRewards() public {
        bytes32 key = _open(alice, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        oracle.setPrice(market, 90.1e18);
        (, uint256 reward) = _liquidate(key);
        assertEq(reward, 0.5e18);
        assertEq(mm.getAvailableMargin(alice), 0);
        assertEq(token.balanceOf(address(liquidator)), 0.75e18);
        assertEq(token.balanceOf(address(insurance)), 0.25e18);
        assertEq(adl.getBankruptcy(key).remainingDeficit, 0);
    }

    function test_BatchLiquidationSkipsInvalidAndCreditsOriginalKeeper() public {
        bytes32 first = _open(alice, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        bytes32 second = _open(bob, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        bytes32 healthy = _open(carol, PerpetualTypes.PositionSide.Short, 10e18, 100e18);
        oracle.setPrice(market, 94e18);
        bytes32[] memory keys = new bytes32[](5);
        keys[0] = bytes32(uint256(123));
        keys[1] = first;
        keys[2] = first;
        keys[3] = healthy;
        keys[4] = second;
        vm.prank(keeper);
        (uint256 count, uint256 reward) = liquidator.batchLiquidate(keys);
        assertEq(count, 2);
        assertEq(reward, 9.4e18);
        assertEq(liquidator.getPendingReward(keeper), reward);
        assertEq(liquidator.getPendingReward(address(liquidator)), 0);
        assertEq(pm.getMarketPositions(market, PerpetualTypes.PositionSide.Long).length, 0);
    }

    function test_InsuranceCoverageTransfersAssetsAndAvoidsADL() public {
        (bytes32 key,) = _bankruptLong(100e18);
        assertEq(insurance.getTotalBalance(), 0);
        assertEq(token.balanceOf(address(insurance)), 0);
        assertEq(token.balanceOf(address(mm)), 300e18);
        assertEq(adl.getBankruptcy(key).remainingDeficit, 0);
        assertEq(mm.getAvailableMargin(alice), 0);
    }

    function test_ADLUsesOnlyUncoveredDebtAndPreservesSolvency() public {
        (bytes32 key, bytes32 counterparty) = _bankruptLong(50e18);
        assertEq(adl.getBankruptcy(key).remainingDeficit, 50e18);
        (bool needed, uint256 deficit) = adl.shouldTriggerADL(market);
        assertTrue(needed);
        assertEq(deficit, 50e18);
        PerpetualTypes.ADLInfo memory info = adl.getADLInfo(counterparty);
        assertEq(info.trader, bob);
        assertEq(info.unrealizedPnL, 200e18);
        assertGt(info.priority, 0);
        vm.prank(admin);
        assertEq(adl.executeADL(key, counterparty, 10e18), 10e18);
        assertEq(pm.getPosition(counterparty).size, 0);
        assertEq(mm.getLockedMargin(bob), 0);
        assertEq(mm.getAvailableMargin(bob), 250e18);
        assertEq(token.balanceOf(address(mm)), mm.getAvailableMargin(bob));
        assertEq(adl.getBankruptcy(key).remainingDeficit, 0);
        assertFalse(adl.isADLActive(market));
        assertEq(adl.getADLLevel(market), 0);
        (uint256 events, uint256 volume,) = adl.getADLStats(market);
        assertEq(events, 1);
        assertEq(volume, 10e18);
        vm.prank(admin);
        vm.expectRevert(PerpetualErrors.ADLNotRequired.selector);
        adl.executeADL(key, counterparty, 1e18);
    }

    function test_AutoADLProcessesMultipleLiveCandidates() public {
        bytes32 key = _open(alice, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        bytes32 first = _open(bob, PerpetualTypes.PositionSide.Short, 5e18, 50e18);
        bytes32 second = _open(carol, PerpetualTypes.PositionSide.Short, 5e18, 50e18);
        oracle.setPrice(market, 80e18);
        _liquidate(key);
        vm.prank(admin);
        (uint128 size, uint256 count) = adl.autoExecuteADL(key);
        assertEq(size, 10e18);
        assertEq(count, 2);
        assertEq(pm.getPosition(first).size, 0);
        assertEq(pm.getPosition(second).size, 0);
        assertEq(mm.getAvailableMargin(bob), 100e18);
        assertEq(mm.getAvailableMargin(carol), 100e18);
        assertEq(token.balanceOf(address(mm)), mm.getAvailableMargin(bob) + mm.getAvailableMargin(carol));
    }

    function test_BatchADLPreservesAuthorizationAndResolvesPartialDebt() public {
        (bytes32 key, bytes32 counterparty) = _bankruptLong(0);
        bytes32[] memory keys = new bytes32[](2);
        uint128[] memory sizes = new uint128[](2);
        keys[0] = counterparty;
        keys[1] = counterparty;
        sizes[0] = 4e18;
        sizes[1] = 6e18;
        vm.prank(admin);
        assertEq(adl.batchExecuteADL(key, keys, sizes), 10e18);
        assertEq(adl.getBankruptcy(key).remainingDeficit, 0);
        assertEq(mm.getAvailableMargin(bob), 200e18);
    }

    function test_BatchADLRollsBackOnInvalidCandidate() public {
        (bytes32 key, bytes32 counterparty) = _bankruptLong(0);
        bytes32[] memory keys = new bytes32[](2);
        uint128[] memory sizes = new uint128[](2);
        keys[0] = counterparty;
        keys[1] = bytes32(uint256(1));
        sizes[0] = 4e18;
        sizes[1] = 6e18;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.NotADLCandidate.selector, keys[1]));
        adl.batchExecuteADL(key, keys, sizes);
        assertEq(pm.getPosition(counterparty).size, 10e18);
        assertEq(adl.getBankruptcy(key).remainingDeficit, 100e18);
        assertEq(mm.getLockedMargin(bob), 100e18);
    }

    function test_ADLRejectsUnregisteredHealthyAndWrongSidePositions() public {
        bytes32 long = _open(alice, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        bytes32 otherLong = _open(carol, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        bytes32 short = _open(bob, PerpetualTypes.PositionSide.Short, 10e18, 100e18);
        vm.startPrank(admin);
        adl.setADLActive(market, true);
        vm.expectRevert(PerpetualErrors.ADLNotRequired.selector);
        adl.executeADL(long, short, 1e18);
        vm.stopPrank();
        oracle.setPrice(market, 80e18);
        _liquidate(long);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.NotADLCandidate.selector, otherLong));
        adl.executeADL(long, otherLong, 1e18);
    }

    function test_ADLRejectsInsufficientProfitWithoutReducingPosition() public {
        (bytes32 key, bytes32 counterparty) = _bankruptLong(0);
        oracle.setPrice(market, 95e18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.NotADLCandidate.selector, counterparty));
        adl.executeADL(key, counterparty, 10e18);
        assertEq(pm.getPosition(counterparty).size, 10e18);
        assertEq(adl.getBankruptcy(key).remainingDeficit, 100e18);
    }

    function test_PrioritiesRefreshWithPriceAndClosedPositionsDisappear() public {
        bytes32 first = _open(bob, PerpetualTypes.PositionSide.Short, 10e18, 100e18);
        bytes32 second = _open(carol, PerpetualTypes.PositionSide.Short, 10e18, 200e18);
        oracle.setPrice(market, 80e18);
        vm.prank(admin);
        adl.updatePriorityQueue(market, PerpetualTypes.PositionSide.Short);
        bytes32[] memory targets = adl.getADLTargets(market, PerpetualTypes.PositionSide.Short, 10);
        assertEq(targets.length, 2);
        assertEq(targets[0], first);
        assertEq(targets[1], second);
        vm.prank(admin);
        pm.closePosition(first, 80e18);
        targets = adl.getADLTargets(market, PerpetualTypes.PositionSide.Short, 10);
        assertEq(targets.length, 1);
        assertEq(targets[0], second);
        oracle.setPrice(market, 110e18);
        assertEq(adl.getADLTargets(market, PerpetualTypes.PositionSide.Short, 10).length, 0);
    }

    function test_ADLForBankruptShortUsesOppositeSide() public {
        bytes32 key = _open(alice, PerpetualTypes.PositionSide.Short, 10e18, 100e18);
        _open(bob, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        oracle.setPrice(market, 120e18);
        _liquidate(key);
        vm.prank(admin);
        (uint128 size, uint256 count) = adl.autoExecuteADL(key);
        assertEq(size, 10e18);
        assertEq(count, 1);
        assertEq(mm.getAvailableMargin(bob), 200e18);
        assertEq(token.balanceOf(address(mm)), 200e18);
    }

    function test_SettlementEndpointsRejectUntrustedCallers() public {
        bytes32 key = _open(alice, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.Unauthorized.selector, keeper));
        pm.reduceForLiquidation(key, 1e18, 100e18);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.Unauthorized.selector, keeper));
        pm.reduceForADL(key, 1e18, 100e18);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.Unauthorized.selector, keeper));
        mm.settleLiquidation(alice, 100e18, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.Unauthorized.selector, keeper));
        mm.settleADL(alice, 100e18, 100e18, 1e18);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.Unauthorized.selector, keeper));
        adl.registerBankruptcy(key, market, PerpetualTypes.PositionSide.Long, 10e18, 1e18);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.Unauthorized.selector, keeper));
        adl.executeADL(key, key, 1e18);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.Unauthorized.selector, keeper));
        liquidator.liquidateFor(key, keeper);
        vm.stopPrank();
    }

    function test_OracleFailureNeverFallsBackToSyntheticPrice() public {
        bytes32 key = _open(alice, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        oracle.setFails(true);
        vm.expectRevert("oracle unavailable");
        liquidator.liquidate(key);
        vm.expectRevert("oracle unavailable");
        adl.getADLInfo(key);
        assertEq(pm.getPosition(key).size, 10e18);
    }

    function test_OracleRejectsStaleZeroFutureAndMissingData() public {
        oracle.setTimestamp(market, uint64(block.timestamp - 301));
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.StalePriceData.selector, market, 699, 300));
        pm.getMarkPrice(market);
        oracle.setPrice(market, 0);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.InvalidPriceData.selector, market, 0));
        pm.getMarkPrice(market);
        oracle.setPrice(market, 100e18);
        oracle.setTimestamp(market, uint64(block.timestamp + 1));
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.InvalidPriceData.selector, market, 100e18));
        pm.getMarkPrice(market);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.PriceNotAvailable.selector, 999));
        pm.getMarkPrice(999);
    }

    function test_EngineDepositOpenAndCloseUseConfiguredPrice() public {
        token.mint(alice, 100e18);
        vm.startPrank(alice);
        token.approve(address(engine), 100e18);
        engine.depositMargin(100e18);
        (bytes32 key, uint128 price) = engine.openMarketPosition(market, PerpetualTypes.PositionSide.Long, 10e18, 100);
        assertEq(price, 100e18);
        assertEq(token.balanceOf(address(mm)), 100e18);
        assertEq(pm.getPosition(key).margin, 100e18);
        assertEq(pm.getMarketConfig(market).maintenanceMarginBps, 500);
        oracle.setPrice(market, 101e18);
        assertEq(engine.closePosition(key, 100), 10e18);
        assertEq(mm.getAvailableMargin(alice), 110e18);
        vm.stopPrank();
    }

    function test_MarketConfigUpdatesReachLiquidationLedger() public {
        PerpetualTypes.MarketConfig memory config = _config();
        config.maintenanceMarginBps = 600;
        vm.prank(admin);
        engine.updateMarketConfig(market, config);
        assertEq(pm.getMarketConfig(market).maintenanceMarginBps, 600);
    }

    function test_LiquidationPriceIncludesFundingAndCurrentNotional() public {
        bytes32 key = _open(alice, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        assertEq(liquidator.getLiquidationPrice(key), uint256(900e18) * 10000 / (10 * 9500));
        vm.prank(admin);
        pm.updateCumulativeFundingIndex(market, 1e18);
        assertEq(liquidator.getLiquidationPrice(key), uint256(910e18) * 10000 / (10 * 9500));
    }

    function test_UnresolvedDebtBlocksOrdinaryExitEvenWhenADLIsPaused() public {
        (, bytes32 counterparty) = _bankruptLong(0);
        vm.startPrank(admin);
        adl.setADLActive(market, false);
        vm.expectRevert(
            abi.encodeWithSelector(PerpetualErrors.InvalidParameter.selector, "market has unresolved ADL debt")
        );
        pm.closePosition(counterparty, 80e18);
        vm.expectRevert(
            abi.encodeWithSelector(PerpetualErrors.InvalidParameter.selector, "market has unresolved ADL debt")
        );
        pm.decreasePosition(counterparty, 1e18, 80e18);
        vm.expectRevert(
            abi.encodeWithSelector(PerpetualErrors.InvalidParameter.selector, "market has unresolved ADL debt")
        );
        pm.removeMargin(counterparty, 1e18);
        vm.stopPrank();
        assertEq(pm.getPosition(counterparty).size, 10e18);
        assertEq(mm.getLockedMargin(bob), 100e18);
    }

    function test_UnsupportedCollateralAndCrossMarginAreRejected() public {
        SixDecimalCollateralMock six = new SixDecimalCollateralMock();
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.TokenNotSupported.selector, address(six)));
        new MarginManager(admin, address(six));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PerpetualErrors.InvalidMarginMode.selector, PerpetualTypes.MarginMode.Cross)
        );
        engine.setMarginMode(market, PerpetualTypes.MarginMode.Cross);
    }

    function test_MarketOracleSeparatesPricesAndRisk() public {
        vm.startPrank(admin);
        uint32 other = engine.createMarket("OTHER", "COL", _config());
        MarkPriceMock second = new MarkPriceMock();
        engine.setOracles(other, address(second), address(second));
        vm.stopPrank();
        second.setPrice(other, 10e18);
        oracle.setPrice(market, 94e18);
        assertEq(pm.getMarkPrice(other), 10e18);
        assertEq(pm.getMarkPrice(market), 94e18);
        vm.prank(admin);
        (uint128 price,) = om.executeMarketOrder(bob, other, PerpetualTypes.PositionSide.Short, 1e18, 0);
        assertEq(price, 10e18);
    }

    function test_PriceMoveAfterLiquidationCannotInflateADLPayout() public {
        (bytes32 key, bytes32 counterparty) = _bankruptLong(0);
        oracle.setPrice(market, 70e18);
        vm.prank(admin);
        adl.executeADL(key, counterparty, 10e18);
        assertEq(mm.getAvailableMargin(bob), 200e18);
        assertEq(mm.getAvailableMargin(bob), token.balanceOf(address(mm)));
    }

    function test_MultipleBankruptciesKeepMarketBlockedUntilAllDebtIsResolved() public {
        bytes32 first = _open(alice, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        bytes32 second = _open(carol, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        bytes32 counterparty = _open(bob, PerpetualTypes.PositionSide.Short, 20e18, 200e18);
        oracle.setPrice(market, 80e18);
        _liquidate(first);
        _liquidate(second);
        assertEq(adl.getMarketDeficit(market), 200e18);
        vm.startPrank(admin);
        adl.executeADL(first, counterparty, 10e18);
        assertTrue(adl.isADLActive(market));
        assertEq(adl.getMarketDeficit(market), 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(PerpetualErrors.InvalidParameter.selector, "market has unresolved ADL debt")
        );
        pm.closePosition(counterparty, 80e18);
        adl.executeADL(second, counterparty, 10e18);
        vm.stopPrank();
        assertFalse(adl.isADLActive(market));
        assertEq(adl.getMarketDeficit(market), 0);
        assertEq(mm.getAvailableMargin(bob), token.balanceOf(address(mm)));
    }

    function test_BankruptcyCannotBeRegisteredTwice() public {
        (bytes32 key,) = _bankruptLong(0);
        vm.prank(address(liquidator));
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.InvalidParameter.selector, "invalid bankruptcy"));
        adl.registerBankruptcy(key, market, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        assertEq(adl.getMarketDeficit(market), 100e18);
    }

    function test_NoCandidatesAndBadSizesCannotConsumeDebt() public {
        (bytes32 key, bytes32 counterparty) = _bankruptLong(0);
        vm.startPrank(admin);
        vm.expectRevert(PerpetualErrors.ZeroSize.selector);
        adl.executeADL(key, counterparty, 0);
        vm.expectRevert(
            abi.encodeWithSelector(PerpetualErrors.ExceedsPositionSize.selector, counterparty, 11e18, 10e18)
        );
        adl.executeADL(key, counterparty, 11e18);
        oracle.setPrice(market, 101e18);
        vm.expectRevert(
            abi.encodeWithSelector(PerpetualErrors.NoADLCandidates.selector, market, PerpetualTypes.PositionSide.Short)
        );
        adl.autoExecuteADL(key);
        vm.stopPrank();
        assertEq(adl.getMarketDeficit(market), 100e18);
    }

    function test_LiquidationRollsBackIfBadDebtCannotBeRegistered() public {
        bytes32 key = _open(alice, PerpetualTypes.PositionSide.Long, 10e18, 100e18);
        vm.prank(admin);
        adl.setLiquidator(admin);
        oracle.setPrice(market, 80e18);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.Unauthorized.selector, address(liquidator)));
        liquidator.liquidate(key);
        assertEq(pm.getPosition(key).size, 10e18);
        assertEq(mm.getLockedMargin(alice), 100e18);
        assertEq(mm.getCrossMarginAccount(alice).balance, 100e18);
    }

    function test_BatchBoundsAndFeeBounds() public {
        bytes32[] memory positions = new bytes32[](21);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.InvalidParameter.selector, "too many positions"));
        liquidator.batchLiquidate(positions);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.InvalidFeeRate.selector, 131070, 500));
        liquidator.setLiquidationFees(type(uint16).max, type(uint16).max, 0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PerpetualErrors.InvalidParameter.selector, "array length mismatch"));
        adl.batchExecuteADL(bytes32(0), positions, new uint128[](0));
    }

    function test_LargeMulDivIntermediateDoesNotOverflow() public pure {
        uint256 large = 1 << 200;
        assertEq(PerpetualMath.mulDiv(large, 1 << 100, 1 << 100), large);
    }

    function testFuzz_PartialADLRoundingCannotOvercollect(uint96 requested) public {
        (bytes32 key, bytes32 counterparty) = _bankruptLong(0);
        uint128 size = uint128(bound(uint256(requested), 1e18, 9e18));
        vm.startPrank(admin);
        adl.executeADL(key, counterparty, size);
        adl.executeADL(key, counterparty, 10e18 - size);
        vm.stopPrank();
        assertEq(adl.getMarketDeficit(market), 0);
        assertLe(mm.getAvailableMargin(bob), token.balanceOf(address(mm)));
        assertApproxEqAbs(mm.getAvailableMargin(bob), 200e18, 2);
    }

    function testFuzz_ADLConservesCollateralAfterPartialInsurance(uint96 covered) public {
        uint256 amount = bound(uint256(covered), 0, 100e18 - 1);
        (bytes32 key, bytes32 counterparty) = _bankruptLong(amount);
        vm.prank(admin);
        adl.executeADL(key, counterparty, 10e18);
        assertEq(mm.getAvailableMargin(bob), 200e18 + amount);
        assertEq(token.balanceOf(address(mm)), mm.getAvailableMargin(bob));
        assertEq(adl.getBankruptcy(key).remainingDeficit, 0);
        assertEq(insurance.getTotalBalance(), token.balanceOf(address(insurance)));
    }
}
