// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SwapRouter } from "../../src/defi/SwapRouter.sol";
import { IUniswapV3SwapRouter } from "../../src/defi/interfaces/ISwapRouter.sol";
import { ISignatureTransfer } from "../../src/permit2/interfaces/ISignatureTransfer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock contracts
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockWKRC {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract MockUniswapV3SwapRouter {
    uint256 public mockAmountOut = 1900e6; // Default 1900 USDC for 1 ETH

    function setMockAmountOut(uint256 _amount) external {
        mockAmountOut = _amount;
    }

    function exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        // Transfer tokens from sender
        require(IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "Transfer failed");

        // Mock: transfer output tokens
        MockERC20(params.tokenOut).mint(params.recipient, mockAmountOut);

        return mockAmountOut;
    }

    function exactInput(IUniswapV3SwapRouter.ExactInputParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        // Decode first token from path (first 20 bytes)
        address tokenIn = address(bytes20(params.path[:20]));

        // Transfer tokens from sender
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "Transfer failed");

        return mockAmountOut;
    }
}

contract MockUniswapV3Quoter {
    uint256 public mockQuote = 1900e6;

    function setMockQuote(uint256 _quote) external {
        mockQuote = _quote;
    }

    function quoteExactInputSingle(address, address, uint24, uint256, uint160) external view returns (uint256) {
        return mockQuote;
    }

    function quoteExactOutputSingle(address, address, uint24, uint256, uint160) external view returns (uint256) {
        return mockQuote;
    }
}

contract MockUniswapV3Factory {
    mapping(bytes32 => address) public pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        bytes32 key = keccak256(abi.encodePacked(tokenA < tokenB ? tokenA : tokenB, tokenA < tokenB ? tokenB : tokenA, fee));
        pools[key] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        bytes32 key = keccak256(abi.encodePacked(tokenA < tokenB ? tokenA : tokenB, tokenA < tokenB ? tokenB : tokenA, fee));
        return pools[key];
    }
}

contract MockPermit2 {
    function permitTransferFrom(
        ISignatureTransfer.PermitTransferFrom calldata,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        address from,
        bytes calldata
    ) external {
        // Mock: just transfer directly (intentionally using address(0) for mock)
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(address(0)).transferFrom(from, transferDetails.to, transferDetails.requestedAmount);
    }
}

contract SwapRouterTest is Test {
    SwapRouter public router;
    MockUniswapV3SwapRouter public mockSwapRouter;
    MockUniswapV3Quoter public mockQuoter;
    MockUniswapV3Factory public mockFactory;
    MockPermit2 public mockPermit2;
    MockWKRC public wkrc;
    MockERC20 public usdc;
    MockERC20 public weth;

    address public owner;
    address public user;

    uint24 constant FEE_LOW = 500;
    uint24 constant FEE_MEDIUM = 3000;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");

        // Deploy mocks
        mockSwapRouter = new MockUniswapV3SwapRouter();
        mockQuoter = new MockUniswapV3Quoter();
        mockFactory = new MockUniswapV3Factory();
        mockPermit2 = new MockPermit2();
        wkrc = new MockWKRC();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);

        // Deploy router
        vm.prank(owner);
        router = new SwapRouter(
            address(mockSwapRouter),
            address(mockQuoter),
            address(mockFactory),
            address(mockPermit2),
            address(wkrc)
        );

        // Setup pools
        mockFactory.setPool(address(wkrc), address(usdc), FEE_LOW, address(1)); // Mock pool address
        mockFactory.setPool(address(wkrc), address(usdc), FEE_MEDIUM, address(2));
        mockFactory.setPool(address(weth), address(usdc), FEE_MEDIUM, address(3));

        // Fund user
        vm.deal(user, 100 ether);
        usdc.mint(user, 10_000e6);
        weth.mint(user, 10 ether);

        // Approve router
        vm.startPrank(user);
        usdc.approve(address(router), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_constructor() public view {
        assertEq(address(router.swapRouter()), address(mockSwapRouter));
        assertEq(address(router.quoter()), address(mockQuoter));
        assertEq(address(router.factory()), address(mockFactory));
        assertEq(address(router.permit2()), address(mockPermit2));
        assertEq(address(router.wkrc()), address(wkrc));
        assertEq(router.owner(), owner);
    }

    function test_constructor_revertIfZeroRouter() public {
        vm.expectRevert(SwapRouter.ZeroAddress.selector);
        new SwapRouter(address(0), address(mockQuoter), address(mockFactory), address(mockPermit2), address(wkrc));
    }

    function test_constructor_revertIfZeroWkrc() public {
        vm.expectRevert(SwapRouter.ZeroAddress.selector);
        new SwapRouter(address(mockSwapRouter), address(mockQuoter), address(mockFactory), address(mockPermit2), address(0));
    }

    // ============ Admin Tests ============

    function test_setSwapRouter() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(owner);
        router.setSwapRouter(newRouter);
        assertEq(address(router.swapRouter()), newRouter);
    }

    function test_setSwapRouter_revertIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        router.setSwapRouter(makeAddr("newRouter"));
    }

    function test_setQuoter() public {
        address newQuoter = makeAddr("newQuoter");
        vm.prank(owner);
        router.setQuoter(newQuoter);
        assertEq(address(router.quoter()), newQuoter);
    }

    function test_setFactory() public {
        address newFactory = makeAddr("newFactory");
        vm.prank(owner);
        router.setFactory(newFactory);
        assertEq(address(router.factory()), newFactory);
    }

    function test_setPermit2() public {
        address newPermit2 = makeAddr("newPermit2");
        vm.prank(owner);
        router.setPermit2(newPermit2);
        assertEq(address(router.permit2()), newPermit2);
    }

    // ============ Quote Tests ============

    function test_getQuote() public {
        mockQuoter.setMockQuote(2000e6);

        (uint256 amountOut, bytes memory path) = router.getQuote(address(wkrc), address(usdc), 1 ether);

        assertEq(amountOut, 2000e6);
        assertEq(path.length, 43); // token(20) + fee(3) + token(20)
    }

    function test_getQuote_revertIfNoLiquidity() public {
        // Query for a pair with no pools
        MockERC20 unknownToken = new MockERC20("Unknown", "UNK", 18);

        vm.expectRevert(SwapRouter.NoLiquidityFound.selector);
        router.getQuote(address(unknownToken), address(usdc), 1 ether);
    }

    function test_quoteExactInputSingle() public {
        mockQuoter.setMockQuote(1950e6);

        uint256 amountOut = router.quoteExactInputSingle(address(wkrc), address(usdc), 1 ether, FEE_MEDIUM);

        assertEq(amountOut, 1950e6);
    }

    // ============ Utility Tests ============

    function test_encodePath() public view {
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(wkrc);
        tokens[2] = address(weth);

        uint24[] memory fees = new uint24[](2);
        fees[0] = FEE_LOW;
        fees[1] = FEE_MEDIUM;

        bytes memory path = router.encodePath(tokens, fees);

        // Path should be: token(20) + fee(3) + token(20) + fee(3) + token(20) = 66 bytes
        assertEq(path.length, 66);
    }

    function test_encodePath_revertIfInvalidLength() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(wkrc);

        uint24[] memory fees = new uint24[](2); // Should be 1
        fees[0] = FEE_LOW;
        fees[1] = FEE_MEDIUM;

        vm.expectRevert(SwapRouter.InvalidPath.selector);
        router.encodePath(tokens, fees);
    }

    function test_calculateMinOutput() public view {
        uint256 expectedOutput = 1000e6;
        uint256 slippageBps = 50; // 0.5%

        uint256 minOutput = router.calculateMinOutput(expectedOutput, slippageBps);

        // 1000 * (10000 - 50) / 10000 = 995
        assertEq(minOutput, 995e6);
    }

    function test_calculateMinOutput_capsAtMaxSlippage() public view {
        uint256 expectedOutput = 1000e6;
        uint256 slippageBps = 1000; // 10% - exceeds max

        uint256 minOutput = router.calculateMinOutput(expectedOutput, slippageBps);

        // Should cap at 5% (500 bps): 1000 * (10000 - 500) / 10000 = 950
        assertEq(minOutput, 950e6);
    }

    function test_poolExists() public view {
        assertTrue(router.poolExists(address(wkrc), address(usdc), FEE_LOW));
        assertTrue(router.poolExists(address(wkrc), address(usdc), FEE_MEDIUM));
        assertFalse(router.poolExists(address(wkrc), address(usdc), 10_000)); // FEE_HIGH not set
    }

    function test_getAvailablePools() public view {
        uint24[] memory fees = router.getAvailablePools(address(wkrc), address(usdc));

        assertEq(fees.length, 2);
        assertEq(fees[0], FEE_LOW);
        assertEq(fees[1], FEE_MEDIUM);
    }

    // ============ Validation Tests ============

    function test_exactInputSingle_revertIfZeroAmount() public {
        SwapRouter.ExactInputSingleParams memory params = SwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(wkrc),
            fee: FEE_MEDIUM,
            recipient: user,
            deadline: block.timestamp + 1 hours,
            amountIn: 0, // Zero amount
            amountOutMinimum: 0
        });

        vm.prank(user);
        vm.expectRevert(SwapRouter.ZeroAmount.selector);
        router.exactInputSingle(params);
    }

    function test_exactInputSingle_revertIfDeadlineExpired() public {
        SwapRouter.ExactInputSingleParams memory params = SwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(wkrc),
            fee: FEE_MEDIUM,
            recipient: user,
            deadline: block.timestamp - 1, // Expired
            amountIn: 1000e6,
            amountOutMinimum: 0
        });

        vm.prank(user);
        vm.expectRevert(SwapRouter.DeadlineExpired.selector);
        router.exactInputSingle(params);
    }

    function test_exactInputSingle_revertIfInvalidFee() public {
        SwapRouter.ExactInputSingleParams memory params = SwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(wkrc),
            fee: 999, // Invalid fee
            recipient: user,
            deadline: block.timestamp + 1 hours,
            amountIn: 1000e6,
            amountOutMinimum: 0
        });

        vm.prank(user);
        vm.expectRevert(SwapRouter.InvalidFee.selector);
        router.exactInputSingle(params);
    }

    function test_exactInput_revertIfInvalidPath() public {
        SwapRouter.ExactInputParams memory params = SwapRouter.ExactInputParams({
            path: hex"1234", // Too short
            recipient: user,
            deadline: block.timestamp + 1 hours,
            amountIn: 1000e6,
            amountOutMinimum: 0
        });

        vm.prank(user);
        vm.expectRevert(SwapRouter.InvalidPath.selector);
        router.exactInput(params);
    }

    // ============ Fee Tier Tests ============

    function test_validFeeTiers() public view {
        assertEq(router.FEE_LOWEST(), 100);
        assertEq(router.FEE_LOW(), 500);
        assertEq(router.FEE_MEDIUM(), 3000);
        assertEq(router.FEE_HIGH(), 10_000);
    }
}
