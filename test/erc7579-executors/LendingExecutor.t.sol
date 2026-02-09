// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { LendingExecutor } from "../../src/erc7579-executors/LendingExecutor.sol";
import { IModule } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { ExecMode } from "../../src/erc7579-smartaccount/types/Types.sol";
import { MODULE_TYPE_EXECUTOR } from "../../src/erc7579-smartaccount/types/Constants.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title LendingExecutor Test
 * @notice TDD RED Phase - Tests for ERC-7579 LendingExecutor module
 * @dev Tests lending operations (supply/withdraw/borrow/repay) via Smart Account
 */
contract LendingExecutorTest is Test {
    LendingExecutor public executor;

    // Mock addresses
    address public owner;
    address public account; // Smart Account
    address public lendingPool;

    // Mock tokens
    MockERC20 public usdc;
    MockERC20 public weth;

    // Constants
    uint256 public constant INITIAL_BALANCE = 10000 ether;
    uint256 public constant HEALTH_FACTOR_THRESHOLD = 1e18; // 1.0

    function setUp() public {
        owner = makeAddr("owner");
        account = makeAddr("smartAccount");
        lendingPool = makeAddr("lendingPool");

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Deploy LendingExecutor
        executor = new LendingExecutor(lendingPool);

        // Setup mock balances
        usdc.mint(account, INITIAL_BALANCE);
        weth.mint(account, INITIAL_BALANCE);
    }

    // =========================================================================
    // Module Interface Tests
    // =========================================================================

    function test_isModuleType_ReturnsTrue_ForExecutor() public view {
        assertTrue(executor.isModuleType(MODULE_TYPE_EXECUTOR));
    }

    function test_isModuleType_ReturnsFalse_ForOtherTypes() public view {
        assertFalse(executor.isModuleType(1)); // Validator
        assertFalse(executor.isModuleType(3)); // Fallback
        assertFalse(executor.isModuleType(4)); // Hook
    }

    function test_onInstall_WithEmptyData_Succeeds() public {
        vm.prank(account);
        executor.onInstall(bytes(""));

        assertTrue(executor.isInitialized(account));
    }

    function test_onInstall_WithAllowedAssets_SetsAssets() public {
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(weth);

        uint256 minHealthFactor = 1.5e18; // 1.5
        uint256 maxBorrowLimit = 1000 ether;

        bytes memory installData = abi.encode(assets, minHealthFactor, maxBorrowLimit);

        vm.prank(account);
        executor.onInstall(installData);

        assertTrue(executor.isAssetAllowed(account, address(usdc)));
        assertTrue(executor.isAssetAllowed(account, address(weth)));
    }

    function test_onInstall_SetsMinHealthFactor() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);

        uint256 minHealthFactor = 1.5e18;
        uint256 maxBorrowLimit = 1000 ether;

        bytes memory installData = abi.encode(assets, minHealthFactor, maxBorrowLimit);

        vm.prank(account);
        executor.onInstall(installData);

        assertEq(executor.getMinHealthFactor(account), minHealthFactor);
    }

    function test_onUninstall_ClearsState() public {
        // Install first
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        bytes memory installData = abi.encode(assets, 1.5e18, 1000 ether);

        vm.prank(account);
        executor.onInstall(installData);

        // Then uninstall
        vm.prank(account);
        executor.onUninstall(bytes(""));

        assertFalse(executor.isInitialized(account));
        assertFalse(executor.isAssetAllowed(account, address(usdc)));
    }

    function test_isInitialized_ReturnsFalse_BeforeInstall() public view {
        assertFalse(executor.isInitialized(account));
    }

    // =========================================================================
    // Asset Management Tests
    // =========================================================================

    function test_addAllowedAsset_AddsAsset() public {
        _installExecutor();

        vm.prank(account);
        executor.addAllowedAsset(address(weth));

        assertTrue(executor.isAssetAllowed(account, address(weth)));
    }

    function test_addAllowedAsset_RevertsIf_NotInitialized() public {
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IModule.NotInitialized.selector, account));
        executor.addAllowedAsset(address(usdc));
    }

    function test_addAllowedAsset_RevertsIf_ZeroAddress() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(LendingExecutor.InvalidAsset.selector);
        executor.addAllowedAsset(address(0));
    }

    function test_addAllowedAsset_RevertsIf_AlreadyAllowed() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(LendingExecutor.AssetAlreadyAllowed.selector);
        executor.addAllowedAsset(address(usdc));
    }

    function test_removeAllowedAsset_RemovesAsset() public {
        _installExecutor();

        vm.prank(account);
        executor.removeAllowedAsset(address(usdc));

        assertFalse(executor.isAssetAllowed(account, address(usdc)));
    }

    function test_removeAllowedAsset_RevertsIf_NotAllowed() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(LendingExecutor.AssetNotAllowed.selector);
        executor.removeAllowedAsset(address(weth)); // Not in initial list
    }

    function test_getAllowedAssets_ReturnsAllAssets() public {
        _installExecutor();

        address[] memory assets = executor.getAllowedAssets(account);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(usdc));
    }

    // =========================================================================
    // Configuration Tests
    // =========================================================================

    function test_setMinHealthFactor_UpdatesFactor() public {
        _installExecutor();

        uint256 newMinHf = 2e18; // 2.0

        vm.prank(account);
        executor.setMinHealthFactor(newMinHf);

        assertEq(executor.getMinHealthFactor(account), newMinHf);
    }

    function test_setMinHealthFactor_RevertsIf_BelowThreshold() public {
        _installExecutor();

        uint256 tooLow = 0.5e18; // 0.5 - below 1.0 threshold

        vm.prank(account);
        vm.expectRevert(LendingExecutor.InvalidHealthFactor.selector);
        executor.setMinHealthFactor(tooLow);
    }

    function test_setMaxBorrowLimit_UpdatesLimit() public {
        _installExecutor();

        uint256 newLimit = 5000 ether;

        vm.prank(account);
        executor.setMaxBorrowLimit(newLimit);

        assertEq(executor.getMaxBorrowLimit(account), newLimit);
    }

    function test_getAccountConfig_ReturnsCorrectConfig() public {
        _installExecutor();

        (uint256 minHealthFactor, uint256 maxBorrowLimit, uint256 totalBorrowed, bool isActive) =
            executor.getAccountConfig(account);

        assertEq(minHealthFactor, 1.5e18);
        assertEq(maxBorrowLimit, 1000 ether);
        assertEq(totalBorrowed, 0);
        assertTrue(isActive);
    }

    // =========================================================================
    // Supply Tests
    // =========================================================================

    function test_supply_Succeeds() public {
        _installExecutorWithMockLendingPool();

        uint256 amount = 100 ether;

        vm.prank(account);
        executor.supply(address(usdc), amount);

        // Verify supply was recorded
        uint256 supplied = executor.getSuppliedAmount(account, address(usdc));
        assertEq(supplied, amount);
    }

    function test_supply_RevertsIf_AssetNotAllowed() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(LendingExecutor.AssetNotAllowed.selector);
        executor.supply(address(weth), 100 ether); // weth not allowed
    }

    function test_supply_RevertsIf_ZeroAmount() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(LendingExecutor.InvalidAmount.selector);
        executor.supply(address(usdc), 0);
    }

    function test_supply_RevertsIf_Paused() public {
        _installExecutor();

        vm.prank(account);
        executor.pause();

        vm.prank(account);
        vm.expectRevert(LendingExecutor.OperationsPaused.selector);
        executor.supply(address(usdc), 100 ether);
    }

    function test_supply_EmitsSuppliedEvent() public {
        _installExecutorWithMockLendingPool();

        vm.prank(account);
        vm.expectEmit(true, true, false, true);
        emit LendingExecutor.Supplied(account, address(usdc), 100 ether);

        executor.supply(address(usdc), 100 ether);
    }

    // =========================================================================
    // Withdraw Tests
    // =========================================================================

    function test_withdraw_Succeeds() public {
        _installExecutorWithMockLendingPool();

        // Supply first
        vm.prank(account);
        executor.supply(address(usdc), 100 ether);

        // Then withdraw
        vm.prank(account);
        executor.withdraw(address(usdc), 50 ether);

        uint256 remaining = executor.getSuppliedAmount(account, address(usdc));
        assertEq(remaining, 50 ether);
    }

    function test_withdraw_FullAmount() public {
        _installExecutorWithMockLendingPool();

        vm.prank(account);
        executor.supply(address(usdc), 100 ether);

        vm.prank(account);
        executor.withdraw(address(usdc), type(uint256).max); // Withdraw all

        uint256 remaining = executor.getSuppliedAmount(account, address(usdc));
        assertEq(remaining, 0);
    }

    function test_withdraw_RevertsIf_AssetNotAllowed() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(LendingExecutor.AssetNotAllowed.selector);
        executor.withdraw(address(weth), 100 ether);
    }

    function test_withdraw_EmitsWithdrawnEvent() public {
        _installExecutorWithMockLendingPool();

        vm.prank(account);
        executor.supply(address(usdc), 100 ether);

        vm.prank(account);
        vm.expectEmit(true, true, false, true);
        emit LendingExecutor.Withdrawn(account, address(usdc), 50 ether);

        executor.withdraw(address(usdc), 50 ether);
    }

    // =========================================================================
    // Borrow Tests
    // =========================================================================

    function test_borrow_Succeeds() public {
        _installExecutorWithMockLendingPool();

        uint256 amount = 100 ether;

        vm.prank(account);
        executor.borrow(address(usdc), amount);

        uint256 borrowed = executor.getBorrowedAmount(account, address(usdc));
        assertEq(borrowed, amount);
    }

    function test_borrow_RevertsIf_ExceedsMaxBorrowLimit() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(LendingExecutor.ExceedsBorrowLimit.selector);
        executor.borrow(address(usdc), 2000 ether); // Exceeds 1000 ether limit
    }

    function test_borrow_RevertsIf_AssetNotAllowed() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(LendingExecutor.AssetNotAllowed.selector);
        executor.borrow(address(weth), 100 ether);
    }

    function test_borrow_RevertsIf_ZeroAmount() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(LendingExecutor.InvalidAmount.selector);
        executor.borrow(address(usdc), 0);
    }

    function test_borrow_UpdatesTotalBorrowed() public {
        _installExecutorWithMockLendingPool();

        vm.prank(account);
        executor.borrow(address(usdc), 100 ether);

        vm.prank(account);
        executor.borrow(address(usdc), 50 ether);

        (,, uint256 totalBorrowed,) = executor.getAccountConfig(account);
        assertEq(totalBorrowed, 150 ether);
    }

    function test_borrow_EmitsBorrowedEvent() public {
        _installExecutorWithMockLendingPool();

        vm.prank(account);
        vm.expectEmit(true, true, false, true);
        emit LendingExecutor.Borrowed(account, address(usdc), 100 ether);

        executor.borrow(address(usdc), 100 ether);
    }

    // =========================================================================
    // Repay Tests
    // =========================================================================

    function test_repay_Succeeds() public {
        _installExecutorWithMockLendingPool();

        // Borrow first
        vm.prank(account);
        executor.borrow(address(usdc), 100 ether);

        // Then repay
        vm.prank(account);
        executor.repay(address(usdc), 50 ether);

        uint256 remaining = executor.getBorrowedAmount(account, address(usdc));
        assertEq(remaining, 50 ether);
    }

    function test_repay_FullAmount() public {
        _installExecutorWithMockLendingPool();

        vm.prank(account);
        executor.borrow(address(usdc), 100 ether);

        vm.prank(account);
        executor.repay(address(usdc), type(uint256).max); // Repay all

        uint256 remaining = executor.getBorrowedAmount(account, address(usdc));
        assertEq(remaining, 0);
    }

    function test_repay_UpdatesTotalBorrowed() public {
        _installExecutorWithMockLendingPool();

        vm.prank(account);
        executor.borrow(address(usdc), 100 ether);

        vm.prank(account);
        executor.repay(address(usdc), 40 ether);

        (,, uint256 totalBorrowed,) = executor.getAccountConfig(account);
        assertEq(totalBorrowed, 60 ether);
    }

    function test_repay_EmitsRepaidEvent() public {
        _installExecutorWithMockLendingPool();

        vm.prank(account);
        executor.borrow(address(usdc), 100 ether);

        vm.prank(account);
        vm.expectEmit(true, true, false, true);
        emit LendingExecutor.Repaid(account, address(usdc), 50 ether);

        executor.repay(address(usdc), 50 ether);
    }

    // =========================================================================
    // Emergency Functions Tests
    // =========================================================================

    function test_pause_PausesOperations() public {
        _installExecutor();

        vm.prank(account);
        executor.pause();

        assertTrue(executor.isPaused(account));
    }

    function test_unpause_UnpausesOperations() public {
        _installExecutor();

        vm.prank(account);
        executor.pause();

        vm.prank(account);
        executor.unpause();

        assertFalse(executor.isPaused(account));
    }

    // =========================================================================
    // View Functions Tests
    // =========================================================================

    function test_getLendingPool_ReturnsCorrectAddress() public view {
        assertEq(executor.getLendingPool(), lendingPool);
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_setMinHealthFactor_ValidRange(uint256 hf) public {
        vm.assume(hf >= HEALTH_FACTOR_THRESHOLD && hf <= 10e18); // 1.0 to 10.0

        _installExecutor();

        vm.prank(account);
        executor.setMinHealthFactor(hf);

        assertEq(executor.getMinHealthFactor(account), hf);
    }

    function testFuzz_setMaxBorrowLimit_AnyValue(uint256 limit) public {
        vm.assume(limit > 0 && limit <= type(uint128).max);

        _installExecutor();

        vm.prank(account);
        executor.setMaxBorrowLimit(limit);

        assertEq(executor.getMaxBorrowLimit(account), limit);
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _installExecutor() internal {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);

        uint256 minHealthFactor = 1.5e18;
        uint256 maxBorrowLimit = 1000 ether;

        bytes memory installData = abi.encode(assets, minHealthFactor, maxBorrowLimit);

        vm.prank(account);
        executor.onInstall(installData);
    }

    function _installExecutorWithMockLendingPool() internal {
        // Deploy mock lending pool
        MockLendingPool mockPool = new MockLendingPool();

        // Redeploy executor with mock pool
        executor = new LendingExecutor(address(mockPool));

        // Deploy mock smart account
        MockSmartAccount mockAccount = new MockSmartAccount(address(executor));
        account = address(mockAccount);

        // Install executor
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(weth);

        bytes memory installData = abi.encode(assets, 1.5e18, 1000 ether);

        vm.prank(account);
        executor.onInstall(installData);

        // Give mock account tokens
        usdc.mint(account, INITIAL_BALANCE * 10);
        weth.mint(account, INITIAL_BALANCE * 10);

        // Give mock pool tokens for borrows
        usdc.mint(address(mockPool), INITIAL_BALANCE * 100);
        weth.mint(address(mockPool), INITIAL_BALANCE * 100);
    }
}

// =========================================================================
// Mock Contracts
// =========================================================================

contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract MockLendingPool {
    mapping(address => mapping(address => uint256)) public deposits;
    mapping(address => mapping(address => uint256)) public borrows;

    function deposit(address asset, uint256 amount) external {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "transfer failed");
        deposits[asset][msg.sender] += amount;
    }

    function withdraw(address asset, uint256 amount) external {
        if (amount == type(uint256).max) {
            amount = deposits[asset][msg.sender];
        }
        deposits[asset][msg.sender] -= amount;
        require(IERC20(asset).transfer(msg.sender, amount), "transfer failed");
    }

    function borrow(address asset, uint256 amount) external {
        borrows[asset][msg.sender] += amount;
        require(IERC20(asset).transfer(msg.sender, amount), "transfer failed");
    }

    function repay(address asset, uint256 amount) external {
        if (amount == type(uint256).max) {
            amount = borrows[asset][msg.sender];
        }
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "transfer failed");
        borrows[asset][msg.sender] -= amount;
    }

    function getDepositBalance(address asset, address user) external view returns (uint256) {
        return deposits[asset][user];
    }

    function getBorrowBalance(address asset, address user) external view returns (uint256) {
        return borrows[asset][user];
    }
}

/**
 * @notice Mock Smart Account for testing
 */
contract MockSmartAccount {
    address public executor;

    constructor(address _executor) {
        executor = _executor;
    }

    function executeFromExecutor(ExecMode, bytes calldata executionData) external returns (bytes[] memory returnData) {
        require(msg.sender == executor, "Only executor");

        // Decode execution data: target (20 bytes) + value (32 bytes) + calldata
        address target = address(bytes20(executionData[0:20]));
        uint256 value = uint256(bytes32(executionData[20:52]));
        bytes memory data = executionData[52:];

        // Execute the call
        (bool success, bytes memory result) = target.call{ value: value }(data);
        require(success, "Execution failed");

        returnData = new bytes[](1);
        returnData[0] = result;
    }

    receive() external payable { }
}
