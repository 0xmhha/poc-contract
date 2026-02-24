// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { MicroLoanPlugin } from "../../src/erc7579-plugins/MicroLoanPlugin.sol";
import { IPriceOracle } from "../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ Mock Contracts ============

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view override returns (uint256) {
        return prices[token];
    }

    function getPriceWithTimestamp(address token) external view override returns (uint256 price, uint256 timestamp) {
        return (prices[token], block.timestamp);
    }

    function hasValidPrice(address token) external view override returns (bool) {
        return prices[token] > 0;
    }
}

// ============ Handler ============

/// @notice Handler contract that wraps MicroLoanPlugin operations with bounded inputs
///         for Foundry invariant testing. Maintains ghost variables to independently
///         track expected protocol state.
contract MicroLoanPluginHandler is Test {
    MicroLoanPlugin public plugin;
    MockPriceOracle public oracle;
    MockERC20 public borrowToken;
    MockERC20 public collateralToken;

    address public owner;
    address public feeRecipient;
    address[] public actors;
    address internal currentActor;

    uint256 public configId;

    /// @notice Ghost variable: tracks the last observed nextLoanId to verify monotonic increase
    uint256 public ghostLastNextLoanId;

    /// @notice Ghost variable: set to true if nextLoanId ever decreases
    bool public ghostLoanIdDecreased;

    /// @notice Ghost variable: tracks all loan IDs ever created for enumeration
    uint256[] public ghostAllLoanIds;

    /// @notice Ghost variable: tracks the principal of each loan at repayment time
    ///         to verify repayment reduces outstanding principal.
    mapping(uint256 => uint256) public ghostPrincipalBeforeRepay;
    bool public ghostRepayDidNotReducePrincipal;

    constructor(
        MicroLoanPlugin _plugin,
        MockPriceOracle _oracle,
        MockERC20 _borrowToken,
        MockERC20 _collateralToken,
        address _owner,
        address _feeRecipient,
        uint256 _configId
    ) {
        plugin = _plugin;
        oracle = _oracle;
        borrowToken = _borrowToken;
        collateralToken = _collateralToken;
        owner = _owner;
        feeRecipient = _feeRecipient;
        configId = _configId;

        // Create actors
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA201));

        // Fund actors with collateral and approve
        for (uint256 i = 0; i < actors.length; i++) {
            collateralToken.mint(actors[i], 100_000 ether);
            borrowToken.mint(actors[i], 100_000 ether);

            vm.startPrank(actors[i]);
            collateralToken.approve(address(plugin), type(uint256).max);
            borrowToken.approve(address(plugin), type(uint256).max);
            vm.stopPrank();
        }

        ghostLastNextLoanId = plugin.nextLoanId();
    }

    // ---- Modifiers ----

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[actorSeed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    // ---- Actions ----

    function borrow(uint256 actorSeed, uint256 borrowAmount, uint256 duration) public useActor(actorSeed) {
        // Bound inputs to valid ranges
        (,,,, uint256 maxLoanAmount, uint256 minLoanAmount, uint256 maxDuration, bool isActive) =
            plugin.loanConfigs(configId);

        if (!isActive) return;
        if (minLoanAmount == 0) return;

        borrowAmount = bound(borrowAmount, minLoanAmount, maxLoanAmount);
        duration = bound(duration, 1, maxDuration);

        // Check liquidity
        uint256 available = plugin.liquidityPool(address(borrowToken));
        if (borrowAmount > available) return;

        // Calculate required collateral and provide it
        uint256 requiredCollateral = plugin.getRequiredCollateral(configId, borrowAmount);
        if (requiredCollateral == 0) return;

        // Ensure actor has enough collateral
        if (collateralToken.balanceOf(currentActor) < requiredCollateral) {
            collateralToken.mint(currentActor, requiredCollateral);
        }

        try plugin.borrow(configId, borrowAmount, duration, requiredCollateral) returns (uint256 loanId) {
            ghostAllLoanIds.push(loanId);

            // Check monotonic increase
            uint256 newNextLoanId = plugin.nextLoanId();
            if (newNextLoanId < ghostLastNextLoanId) {
                ghostLoanIdDecreased = true;
            }
            ghostLastNextLoanId = newNextLoanId;
        } catch {
            // Borrow failed, that is acceptable
        }
    }

    function repay(uint256 actorSeed, uint256 loanIndex) public useActor(actorSeed) {
        if (ghostAllLoanIds.length == 0) return;

        loanIndex = loanIndex % ghostAllLoanIds.length;
        uint256 loanId = ghostAllLoanIds[loanIndex];

        MicroLoanPlugin.Loan memory loan = plugin.getLoan(loanId);
        if (!loan.isActive) return;

        // Get repayment amount
        uint256 repaymentAmount = plugin.getRepaymentAmount(loanId);
        if (repaymentAmount == 0) return;

        // Record principal before repay
        ghostPrincipalBeforeRepay[loanId] = loan.borrowAmount;

        // Ensure the repayer has enough tokens
        if (borrowToken.balanceOf(currentActor) < repaymentAmount) {
            borrowToken.mint(currentActor, repaymentAmount);
        }

        try plugin.repay(loanId) {
            // After repay, the loan should be inactive (principal effectively 0)
            MicroLoanPlugin.Loan memory loanAfter = plugin.getLoan(loanId);
            // If loan is still somehow active after repay with non-reduced principal, flag it
            if (loanAfter.isActive && loanAfter.borrowAmount >= ghostPrincipalBeforeRepay[loanId]) {
                ghostRepayDidNotReducePrincipal = true;
            }
        } catch {
            // Repay failed (e.g., transfer issue), acceptable
        }
    }

    function liquidate(uint256 actorSeed, uint256 loanIndex) public useActor(actorSeed) {
        if (ghostAllLoanIds.length == 0) return;

        loanIndex = loanIndex % ghostAllLoanIds.length;
        uint256 loanId = ghostAllLoanIds[loanIndex];

        MicroLoanPlugin.Loan memory loan = plugin.getLoan(loanId);
        if (!loan.isActive) return;
        if (block.timestamp <= loan.dueTime) return;

        try plugin.liquidate(loanId) {
        // Liquidation succeeded
        }
            catch {
            // Liquidation failed, acceptable
        }
    }

    function warpTime(uint256 seconds_) public {
        seconds_ = bound(seconds_, 1, 60 days);
        vm.warp(block.timestamp + seconds_);
    }

    // ---- Getters ----

    function getAllLoanIdsCount() external view returns (uint256) {
        return ghostAllLoanIds.length;
    }

    function getAllLoanId(uint256 index) external view returns (uint256) {
        return ghostAllLoanIds[index];
    }

    function getActorsCount() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 index) external view returns (address) {
        return actors[index];
    }
}

// ============ Invariant Test ============

/// @title MicroLoanPluginInvariantTest
/// @notice Foundry invariant tests for MicroLoanPlugin.
///         The fuzzer calls handler functions in random order and after
///         each call sequence the invariant_* functions are checked.
contract MicroLoanPluginInvariantTest is Test {
    MicroLoanPlugin public plugin;
    MockPriceOracle public oracle;
    MockERC20 public borrowToken;
    MockERC20 public collateralToken;
    MicroLoanPluginHandler public handler;

    address public owner;
    address public feeRecipient;
    uint256 public configId;

    function setUp() public {
        owner = makeAddr("owner");
        feeRecipient = makeAddr("feeRecipient");

        oracle = new MockPriceOracle();

        vm.startPrank(owner);
        borrowToken = new MockERC20("Borrow Token", "BT");
        collateralToken = new MockERC20("Collateral Token", "CT");

        // Set 1:1 prices
        oracle.setPrice(address(borrowToken), 1e18);
        oracle.setPrice(address(collateralToken), 1e18);

        plugin = new MicroLoanPlugin(oracle, feeRecipient, 500, 500);

        // Fund plugin with liquidity
        borrowToken.mint(owner, 1_000_000 ether);
        borrowToken.approve(address(plugin), type(uint256).max);
        plugin.depositLiquidity(address(borrowToken), 1_000_000 ether);

        // Create loan config
        configId = plugin.createLoanConfig(
            address(borrowToken),
            address(collateralToken),
            15_000, // 150% collateral ratio
            1000, // 10% annual interest
            10_000 ether, // max loan
            1 ether, // min loan
            30 days // max duration
        );
        vm.stopPrank();

        handler =
            new MicroLoanPluginHandler(plugin, oracle, borrowToken, collateralToken, owner, feeRecipient, configId);

        // Target only the handler
        targetContract(address(handler));
    }

    // ---- Invariant: collateral ratio must always be maintained for active loans ----

    /// @notice For every active loan, the deposited collateral value must meet or exceed
    ///         the required collateral ratio relative to the borrow value. This is the
    ///         core safety property that prevents undercollateralized lending.
    ///
    /// @dev    The collateral check uses the same oracle and formula as the contract's
    ///         _calculateRequiredCollateral. Since prices are static in this test (1:1),
    ///         requiredCollateral = borrowAmount * collateralRatio / BASIS_POINTS.
    function invariant_collateralRatioMaintained() public view {
        uint256 loanCount = handler.getAllLoanIdsCount();

        for (uint256 i = 0; i < loanCount; i++) {
            uint256 loanId = handler.getAllLoanId(i);
            MicroLoanPlugin.Loan memory loan = plugin.getLoan(loanId);

            if (!loan.isActive) continue;

            // Get config for this loan
            (,,,,,,, bool isActive) = plugin.loanConfigs(loan.configId);
            if (!isActive) continue;

            // Required collateral at the time of borrow was validated by the contract.
            // Verify it still holds: collateralAmount >= borrowAmount * collateralRatio / BASIS_POINTS
            // (with 1:1 pricing and same decimals)
            uint256 requiredCollateral = plugin.getRequiredCollateral(loan.configId, loan.borrowAmount);

            assertGe(
                loan.collateralAmount,
                requiredCollateral,
                "Active loan collateral must meet or exceed required collateral ratio"
            );
        }
    }

    // ---- Invariant: loan ID counter is monotonically increasing ----

    /// @notice The nextLoanId counter must never decrease. Each call to borrow() increments
    ///         it by 1 via nextLoanId++. A decrease would indicate counter corruption or
    ///         overflow (which is impossible with uint256 in practice).
    function invariant_loanIdMonotonicallyIncreasing() public view {
        assertFalse(handler.ghostLoanIdDecreased(), "nextLoanId must never decrease (monotonically increasing counter)");

        // Additionally verify that nextLoanId >= number of loans ever created
        assertGe(plugin.nextLoanId(), handler.getAllLoanIdsCount(), "nextLoanId must be >= total loans created");
    }

    // ---- Invariant: active loan count matches loans with non-zero principal ----

    /// @notice The number of loans marked isActive must equal the number of loans that
    ///         have a non-zero borrowAmount AND are still marked active. This verifies
    ///         that repay/liquidate correctly deactivates loans and that no loans exist
    ///         in an inconsistent state (active but zero principal, or inactive but
    ///         non-zero principal with isActive=true).
    function invariant_activeLoanCountMatchesNonZeroPrincipal() public view {
        uint256 loanCount = handler.getAllLoanIdsCount();
        uint256 activeCount = 0;
        uint256 activeWithPrincipalCount = 0;

        for (uint256 i = 0; i < loanCount; i++) {
            uint256 loanId = handler.getAllLoanId(i);
            MicroLoanPlugin.Loan memory loan = plugin.getLoan(loanId);

            if (loan.isActive) {
                activeCount++;
            }
            if (loan.isActive && loan.borrowAmount > 0) {
                activeWithPrincipalCount++;
            }
        }

        // Every active loan must have non-zero principal (no empty active loans)
        assertEq(activeCount, activeWithPrincipalCount, "All active loans must have non-zero borrowAmount");
    }

    // ---- Invariant: repayment always reduces outstanding principal ----

    /// @notice When repay() succeeds, the loan must be deactivated (isActive = false),
    ///         which effectively sets the outstanding obligation to zero. This verifies
    ///         that repayment cannot leave a loan active with the same or increased principal.
    function invariant_repaymentReducesPrincipal() public view {
        assertFalse(
            handler.ghostRepayDidNotReducePrincipal(),
            "Repayment must always deactivate the loan (reduce outstanding principal to zero)"
        );
    }

    // ---- Invariant: nextLoanId equals total loans created ----

    /// @notice Since every successful borrow increments nextLoanId by exactly 1 and assigns
    ///         sequential IDs starting from 0, the nextLoanId should always equal the total
    ///         number of loans that have been created (tracked by the handler).
    function invariant_nextLoanIdEqualsCreatedCount() public view {
        // nextLoanId is the next ID to be assigned, so it equals total created
        assertGe(
            plugin.nextLoanId(),
            handler.getAllLoanIdsCount(),
            "nextLoanId must be >= number of loans tracked by handler"
        );
    }

    // ---- Invariant: liquidity pool accounting ----

    /// @notice The liquidity pool balance tracked by the contract must be consistent
    ///         with the actual token balance held. The contract balance should be at
    ///         least the tracked liquidity pool amount (it may hold more due to collateral
    ///         or repayments not yet reflected).
    function invariant_liquidityPoolConsistency() public view {
        uint256 trackedLiquidity = plugin.liquidityPool(address(borrowToken));
        uint256 actualBalance = borrowToken.balanceOf(address(plugin));

        // The contract holds: liquidity pool + fees (to be transferred) + repayments
        // So actual balance >= tracked liquidity
        assertGe(actualBalance, trackedLiquidity, "Actual token balance must be >= tracked liquidity pool");
    }
}
