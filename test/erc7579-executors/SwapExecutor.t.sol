// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SwapExecutor } from "../../src/erc7579-executors/SwapExecutor.sol";
import { IModule } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { ExecMode } from "../../src/erc7579-smartaccount/types/Types.sol";
import { MODULE_TYPE_EXECUTOR } from "../../src/erc7579-smartaccount/types/Constants.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title SwapExecutor Test
 * @notice TDD RED Phase - Tests for ERC-7579 SwapExecutor module
 * @dev Tests Uniswap V3 swap integration via Smart Account
 */
contract SwapExecutorTest is Test {
    SwapExecutor public executor;

    // Mock addresses
    address public owner;
    address public account; // Smart Account
    address public swapRouter;
    address public quoter;

    // Mock tokens
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;

    // Constants
    uint24 public constant FEE_LOW = 500; // 0.05%
    uint24 public constant FEE_MEDIUM = 3000; // 0.3%
    uint24 public constant FEE_HIGH = 10000; // 1%

    uint256 public constant INITIAL_BALANCE = 1000 ether;

    function setUp() public {
        owner = makeAddr("owner");
        account = makeAddr("smartAccount");
        swapRouter = makeAddr("swapRouter");
        quoter = makeAddr("quoter");

        // Deploy mock tokens
        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        tokenC = new MockERC20("Token C", "TKC");

        // Deploy SwapExecutor
        executor = new SwapExecutor(swapRouter, quoter);

        // Setup mock balances
        tokenA.mint(account, INITIAL_BALANCE);
        tokenB.mint(account, INITIAL_BALANCE);
        tokenC.mint(account, INITIAL_BALANCE);
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

    function test_onInstall_WithWhitelistedTokens_SetsTokens() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        uint256 dailyLimit = 100 ether;
        uint256 perSwapLimit = 10 ether;

        bytes memory installData = abi.encode(tokens, dailyLimit, perSwapLimit);

        vm.prank(account);
        executor.onInstall(installData);

        assertTrue(executor.isTokenWhitelisted(account, address(tokenA)));
        assertTrue(executor.isTokenWhitelisted(account, address(tokenB)));
        assertFalse(executor.isTokenWhitelisted(account, address(tokenC)));
    }

    function test_onInstall_SetsLimits() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);

        uint256 dailyLimit = 100 ether;
        uint256 perSwapLimit = 10 ether;

        bytes memory installData = abi.encode(tokens, dailyLimit, perSwapLimit);

        vm.prank(account);
        executor.onInstall(installData);

        (uint256 daily, uint256 perSwap) = executor.getLimits(account);
        assertEq(daily, dailyLimit);
        assertEq(perSwap, perSwapLimit);
    }

    function test_onUninstall_ClearsState() public {
        // Install first
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);
        bytes memory installData = abi.encode(tokens, 100 ether, 10 ether);

        vm.prank(account);
        executor.onInstall(installData);

        // Then uninstall
        vm.prank(account);
        executor.onUninstall(bytes(""));

        assertFalse(executor.isInitialized(account));
        assertFalse(executor.isTokenWhitelisted(account, address(tokenA)));
    }

    function test_isInitialized_ReturnsFalse_BeforeInstall() public view {
        assertFalse(executor.isInitialized(account));
    }

    // =========================================================================
    // Token Whitelist Tests
    // =========================================================================

    function test_addWhitelistedToken_AddsToken() public {
        _installExecutor();

        vm.prank(account);
        executor.addWhitelistedToken(address(tokenC));

        assertTrue(executor.isTokenWhitelisted(account, address(tokenC)));
    }

    function test_addWhitelistedToken_RevertsIf_NotInitialized() public {
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IModule.NotInitialized.selector, account));
        executor.addWhitelistedToken(address(tokenA));
    }

    function test_addWhitelistedToken_RevertsIf_ZeroAddress() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(SwapExecutor.InvalidToken.selector);
        executor.addWhitelistedToken(address(0));
    }

    function test_addWhitelistedToken_RevertsIf_AlreadyWhitelisted() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(SwapExecutor.TokenAlreadyWhitelisted.selector);
        executor.addWhitelistedToken(address(tokenA));
    }

    function test_removeWhitelistedToken_RemovesToken() public {
        _installExecutor();

        vm.prank(account);
        executor.removeWhitelistedToken(address(tokenA));

        assertFalse(executor.isTokenWhitelisted(account, address(tokenA)));
    }

    function test_removeWhitelistedToken_RevertsIf_NotWhitelisted() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(SwapExecutor.TokenNotWhitelisted.selector);
        executor.removeWhitelistedToken(address(tokenC));
    }

    function test_getWhitelistedTokens_ReturnsAllTokens() public {
        _installExecutor();

        address[] memory tokens = executor.getWhitelistedTokens(account);
        assertEq(tokens.length, 2);
    }

    // =========================================================================
    // Limit Management Tests
    // =========================================================================

    function test_setLimits_UpdatesLimits() public {
        _installExecutor();

        uint256 newDailyLimit = 200 ether;
        uint256 newPerSwapLimit = 20 ether;

        vm.prank(account);
        executor.setLimits(newDailyLimit, newPerSwapLimit);

        (uint256 daily, uint256 perSwap) = executor.getLimits(account);
        assertEq(daily, newDailyLimit);
        assertEq(perSwap, newPerSwapLimit);
    }

    function test_setLimits_RevertsIf_PerSwapExceedsDaily() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(SwapExecutor.InvalidLimits.selector);
        executor.setLimits(10 ether, 20 ether); // perSwap > daily
    }

    function test_getDailyUsage_ReturnsCurrentUsage() public {
        _installExecutor();

        uint256 usage = executor.getDailyUsage(account);
        assertEq(usage, 0);
    }

    function test_dailyLimit_ResetsAfter24Hours() public {
        _installExecutorWithMockSwapRouter();

        // Execute a swap to use some limit
        _executeSwap(1 ether);

        uint256 usageBefore = executor.getDailyUsage(account);
        assertGt(usageBefore, 0);

        // Advance time by 24 hours
        vm.warp(block.timestamp + 1 days);

        uint256 usageAfter = executor.getDailyUsage(account);
        assertEq(usageAfter, 0);
    }

    // =========================================================================
    // Swap Execution Tests - Single Hop
    // =========================================================================

    function test_swapExactInputSingle_Succeeds() public {
        _installExecutorWithMockSwapRouter();

        uint256 amountIn = 1 ether;
        uint256 minAmountOut = 0.9 ether;

        vm.prank(account);
        uint256 amountOut = executor.swapExactInputSingle(
            address(tokenA), address(tokenB), FEE_MEDIUM, amountIn, minAmountOut, block.timestamp + 1 hours
        );

        assertGt(amountOut, 0);
    }

    function test_swapExactInputSingle_RevertsIf_TokenNotWhitelisted() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(SwapExecutor.TokenNotWhitelisted.selector);
        executor.swapExactInputSingle(
            address(tokenC), // Not whitelisted
            address(tokenB),
            FEE_MEDIUM,
            1 ether,
            0.9 ether,
            block.timestamp + 1 hours
        );
    }

    function test_swapExactInputSingle_RevertsIf_OutputTokenNotWhitelisted() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(SwapExecutor.TokenNotWhitelisted.selector);
        executor.swapExactInputSingle(
            address(tokenA),
            address(tokenC), // Not whitelisted
            FEE_MEDIUM,
            1 ether,
            0.9 ether,
            block.timestamp + 1 hours
        );
    }

    function test_swapExactInputSingle_RevertsIf_ExceedsPerSwapLimit() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(SwapExecutor.ExceedsPerSwapLimit.selector);
        executor.swapExactInputSingle(
            address(tokenA),
            address(tokenB),
            FEE_MEDIUM,
            20 ether, // Exceeds 10 ether limit
            18 ether,
            block.timestamp + 1 hours
        );
    }

    function test_swapExactInputSingle_RevertsIf_ExceedsDailyLimit() public {
        _installExecutorWithMockSwapRouter();

        // Execute swaps until daily limit is reached
        for (uint256 i = 0; i < 10; i++) {
            _executeSwap(10 ether);
        }

        // Next swap should fail
        vm.prank(account);
        vm.expectRevert(SwapExecutor.ExceedsDailyLimit.selector);
        executor.swapExactInputSingle(
            address(tokenA), address(tokenB), FEE_MEDIUM, 1 ether, 0.9 ether, block.timestamp + 1 hours
        );
    }

    function test_swapExactInputSingle_RevertsIf_DeadlineExpired() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(SwapExecutor.DeadlineExpired.selector);
        executor.swapExactInputSingle(
            address(tokenA),
            address(tokenB),
            FEE_MEDIUM,
            1 ether,
            0.9 ether,
            block.timestamp - 1 // Expired deadline
        );
    }

    function test_swapExactInputSingle_RevertsIf_ZeroAmount() public {
        _installExecutor();

        vm.prank(account);
        vm.expectRevert(SwapExecutor.InvalidAmount.selector);
        executor.swapExactInputSingle(
            address(tokenA),
            address(tokenB),
            FEE_MEDIUM,
            0, // Zero amount
            0,
            block.timestamp + 1 hours
        );
    }

    function test_swapExactInputSingle_UpdatesDailyUsage() public {
        _installExecutorWithMockSwapRouter();

        uint256 usageBefore = executor.getDailyUsage(account);

        _executeSwap(5 ether);

        uint256 usageAfter = executor.getDailyUsage(account);
        assertEq(usageAfter, usageBefore + 5 ether);
    }

    function test_swapExactInputSingle_EmitsSwapExecutedEvent() public {
        _installExecutorWithMockSwapRouter();

        vm.prank(account);
        vm.expectEmit(true, true, true, false);
        emit SwapExecutor.SwapExecuted(
            account,
            address(tokenA),
            address(tokenB),
            1 ether,
            0 // amountOut will be filled by mock
        );

        executor.swapExactInputSingle(
            address(tokenA), address(tokenB), FEE_MEDIUM, 1 ether, 0.9 ether, block.timestamp + 1 hours
        );
    }

    // =========================================================================
    // Swap Execution Tests - Multi Hop
    // =========================================================================

    function test_swapExactInput_MultiHop_Succeeds() public {
        _installExecutorWithMockSwapRouterMultiHop();

        // Path: tokenA -> tokenB -> tokenC
        bytes memory path = abi.encodePacked(address(tokenA), FEE_MEDIUM, address(tokenB), FEE_MEDIUM, address(tokenC));

        uint256 amountIn = 1 ether;
        uint256 minAmountOut = 0.8 ether;

        vm.prank(account);
        uint256 amountOut = executor.swapExactInput(path, amountIn, minAmountOut, block.timestamp + 1 hours);

        assertGt(amountOut, 0);
    }

    function test_swapExactInput_RevertsIf_PathContainsNonWhitelistedToken() public {
        _installExecutor();

        address nonWhitelisted = makeAddr("nonWhitelisted");

        // Path with non-whitelisted intermediate token
        bytes memory path = abi.encodePacked(
            address(tokenA),
            FEE_MEDIUM,
            nonWhitelisted, // Not whitelisted
            FEE_MEDIUM,
            address(tokenB)
        );

        vm.prank(account);
        vm.expectRevert(SwapExecutor.TokenNotWhitelisted.selector);
        executor.swapExactInput(path, 1 ether, 0.8 ether, block.timestamp + 1 hours);
    }

    function test_swapExactInput_RevertsIf_InvalidPath() public {
        _installExecutor();

        bytes memory invalidPath = bytes(""); // Empty path

        vm.prank(account);
        vm.expectRevert(SwapExecutor.InvalidPath.selector);
        executor.swapExactInput(invalidPath, 1 ether, 0.8 ether, block.timestamp + 1 hours);
    }

    // =========================================================================
    // View Functions Tests
    // =========================================================================

    function test_getSwapRouter_ReturnsCorrectAddress() public view {
        assertEq(executor.getSwapRouter(), swapRouter);
    }

    function test_getQuoter_ReturnsCorrectAddress() public view {
        assertEq(executor.getQuoter(), quoter);
    }

    function test_getAccountConfig_ReturnsCorrectConfig() public {
        _installExecutor();

        (uint256 dailyLimit, uint256 perSwapLimit, uint256 dailyUsed, uint256 lastResetTime, bool isActive) =
            executor.getAccountConfig(account);

        assertEq(dailyLimit, 100 ether);
        assertEq(perSwapLimit, 10 ether);
        assertEq(dailyUsed, 0);
        assertGt(lastResetTime, 0);
        assertTrue(isActive);
    }

    // =========================================================================
    // Slippage Protection Tests
    // =========================================================================

    function test_calculateMinOutput_WithSlippage() public view {
        uint256 expectedOutput = 100 ether;
        uint256 slippageBps = 50; // 0.5%

        uint256 minOutput = executor.calculateMinOutput(expectedOutput, slippageBps);

        // 100 ether - 0.5% = 99.5 ether
        assertEq(minOutput, 99.5 ether);
    }

    function test_calculateMinOutput_RevertsIf_SlippageTooHigh() public {
        uint256 expectedOutput = 100 ether;
        uint256 slippageBps = 10001; // > 100%

        vm.expectRevert(SwapExecutor.SlippageTooHigh.selector);
        executor.calculateMinOutput(expectedOutput, slippageBps);
    }

    // =========================================================================
    // Emergency Functions Tests
    // =========================================================================

    function test_pause_PausesSwaps() public {
        _installExecutor();

        vm.prank(account);
        executor.pause();

        assertTrue(executor.isPaused(account));
    }

    function test_unpause_UnpausesSwaps() public {
        _installExecutor();

        vm.prank(account);
        executor.pause();

        vm.prank(account);
        executor.unpause();

        assertFalse(executor.isPaused(account));
    }

    function test_swapExactInputSingle_RevertsIf_Paused() public {
        _installExecutor();

        vm.prank(account);
        executor.pause();

        vm.prank(account);
        vm.expectRevert(SwapExecutor.SwapsPaused.selector);
        executor.swapExactInputSingle(
            address(tokenA), address(tokenB), FEE_MEDIUM, 1 ether, 0.9 ether, block.timestamp + 1 hours
        );
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_setLimits_ValidLimits(uint256 daily, uint256 perSwap) public {
        vm.assume(daily > 0 && daily <= type(uint128).max);
        vm.assume(perSwap > 0 && perSwap <= daily);

        _installExecutor();

        vm.prank(account);
        executor.setLimits(daily, perSwap);

        (uint256 actualDaily, uint256 actualPerSwap) = executor.getLimits(account);
        assertEq(actualDaily, daily);
        assertEq(actualPerSwap, perSwap);
    }

    function testFuzz_calculateMinOutput_ValidSlippage(uint256 amount, uint16 slippageBps) public view {
        vm.assume(amount > 0 && amount <= type(uint128).max);
        vm.assume(slippageBps <= 10000); // Max 100%

        uint256 minOutput = executor.calculateMinOutput(amount, slippageBps);

        uint256 expected = amount - (amount * slippageBps / 10000);
        assertEq(minOutput, expected);
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _installExecutor() internal {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        uint256 dailyLimit = 100 ether;
        uint256 perSwapLimit = 10 ether;

        bytes memory installData = abi.encode(tokens, dailyLimit, perSwapLimit);

        vm.prank(account);
        executor.onInstall(installData);
    }

    function _installExecutorWithMockSwapRouter() internal {
        // Deploy mock swap router
        MockSwapRouter mockRouter = new MockSwapRouter();

        // Redeploy executor with mock router
        executor = new SwapExecutor(address(mockRouter), quoter);

        // Deploy mock smart account that forwards calls to executor
        MockSmartAccount mockAccount = new MockSmartAccount(address(executor));
        account = address(mockAccount);

        // Install
        _installExecutor();

        // Give mock account and router tokens for swaps
        tokenA.mint(account, INITIAL_BALANCE * 10);
        tokenB.mint(account, INITIAL_BALANCE * 10);
        tokenB.mint(address(mockRouter), INITIAL_BALANCE * 10);

        // Approve executor to spend account's tokens
        vm.prank(account);
        tokenA.approve(address(executor), type(uint256).max);
    }

    function _installExecutorWithMockSwapRouterMultiHop() internal {
        // Deploy mock swap router with multi-hop support
        MockSwapRouter mockRouter = new MockSwapRouter();

        // Redeploy executor with mock router
        executor = new SwapExecutor(address(mockRouter), quoter);

        // Deploy mock smart account
        MockSmartAccount mockAccount = new MockSmartAccount(address(executor));
        account = address(mockAccount);

        // Install with all three tokens whitelisted
        address[] memory tokens = new address[](3);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        tokens[2] = address(tokenC);

        bytes memory installData = abi.encode(tokens, 100 ether, 10 ether);

        vm.prank(account);
        executor.onInstall(installData);

        // Give mock account and router tokens for swaps
        tokenA.mint(account, INITIAL_BALANCE * 10);
        tokenB.mint(account, INITIAL_BALANCE * 10);
        tokenC.mint(account, INITIAL_BALANCE * 10);
        tokenB.mint(address(mockRouter), INITIAL_BALANCE * 10);
        tokenC.mint(address(mockRouter), INITIAL_BALANCE * 10);

        // Approve executor to spend account's tokens
        vm.prank(account);
        tokenA.approve(address(executor), type(uint256).max);
    }

    function _executeSwap(uint256 amount) internal {
        vm.prank(account);
        executor.swapExactInputSingle(
            address(tokenA),
            address(tokenB),
            FEE_MEDIUM,
            amount,
            amount * 9 / 10, // 10% slippage tolerance
            block.timestamp + 1 hours
        );
    }
}

// =========================================================================
// Mock Contracts
// =========================================================================

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSwapRouter {
    function exactInputSingle(ISwapRouterMock.ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        // Mock: return 95% of input as output
        amountOut = params.amountIn * 95 / 100;

        // Transfer tokens (simplified mock)
        require(IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "transfer failed");
        require(IERC20(params.tokenOut).transfer(params.recipient, amountOut), "transfer failed");

        return amountOut;
    }

    function exactInput(ISwapRouterMock.ExactInputParams calldata params) external returns (uint256 amountOut) {
        // Mock: return 90% of input as output (multi-hop has more slippage)
        amountOut = params.amountIn * 90 / 100;

        // Extract first and last tokens from path using slice syntax (calldata)
        address tokenIn = address(bytes20(params.path[0:20]));
        // Last token is at the end: path.length - 20
        address tokenOut = address(bytes20(params.path[params.path.length - 20:]));

        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "transfer failed");
        require(IERC20(tokenOut).transfer(params.recipient, amountOut), "transfer failed");

        return amountOut;
    }
}

interface ISwapRouterMock {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
}

/**
 * @notice Mock Smart Account that implements IERC7579Account.executeFromExecutor
 * @dev Simplified implementation for testing SwapExecutor
 */
contract MockSmartAccount {
    address public executor;

    constructor(address _executor) {
        executor = _executor;
    }

    /**
     * @notice Execute a call from an installed executor module
     * @dev Simplified version that just executes the call directly
     */
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
