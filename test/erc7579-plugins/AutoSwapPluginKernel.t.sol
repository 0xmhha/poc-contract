// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { KernelModuleTestBase } from "../utils/KernelModuleTestBase.sol";
import { AutoSwapPlugin } from "../../src/erc7579-plugins/AutoSwapPlugin.sol";
import { IPriceOracle } from "../../src/erc4337-paymaster/interfaces/IPriceOracle.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockPriceOracle } from "./AutoSwapPlugin.t.sol";

contract AutoSwapTestToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Constant-product pool exposing the router call AutoSwapPlugin makes
contract AutoSwapTestRouter {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 out)
    {
        uint256 reserveIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 reserveOut = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        out = reserveOut * amountIn / (reserveIn + amountIn);
        require(out >= minOut, "slippage");
        IERC20(tokenOut).transfer(recipient, out);
    }
}

/// @notice Front-runs a due DCA order, executes it (executeOrder is permissionless), then back-runs
contract AutoSwapSandwicher {
    function attack(
        AutoSwapPlugin plugin,
        AutoSwapTestRouter router,
        IERC20 a,
        IERC20 b,
        address victim,
        uint256 orderId,
        uint256 front
    ) external {
        a.approve(address(router), type(uint256).max);
        b.approve(address(router), type(uint256).max);
        uint256 gotB = router.swap(address(a), address(b), front, 0, address(this));
        plugin.executeOrder(victim, orderId);
        router.swap(address(b), address(a), gotB, 0, address(this));
    }
}

/// @notice AutoSwapPlugin installed as an executor on a real Kernel account.
/// @dev Regression: DCA orders swapped with amountOutMin = 0, so anyone could sandwich a due order
///      and take nearly all of its output.
contract AutoSwapPluginKernelTest is KernelModuleTestBase {
    AutoSwapPlugin internal plugin;
    MockPriceOracle internal oracle;
    AutoSwapTestRouter internal router;
    AutoSwapTestToken internal tokenA;
    AutoSwapTestToken internal tokenB;
    address internal account;

    uint256 internal constant DCA_AMOUNT = 100 ether;

    function _setUp(uint8 decimalsB, uint256 slippageBps) internal {
        _deployKernel();
        account = _createAccount(0);

        tokenA = new AutoSwapTestToken("A", 18);
        tokenB = new AutoSwapTestToken("B", decimalsB);
        oracle = new MockPriceOracle();
        oracle.setPrice(address(tokenA), 1e18);
        oracle.setPrice(address(tokenB), 1e18); // 1 A = 1 B per whole token
        router = new AutoSwapTestRouter();
        tokenA.mint(address(router), 100_000 ether);
        tokenB.mint(address(router), 100_000 * 10 ** decimalsB);

        plugin = new AutoSwapPlugin(IPriceOracle(address(oracle)), address(router));
        _installExecutor(account, address(plugin), "");
        tokenA.mint(account, 1000 ether);
        _execAsAccount(account, address(tokenA), abi.encodeCall(IERC20.approve, (address(router), type(uint256).max)));
        _execAsAccount(
            account,
            address(plugin),
            abi.encodeCall(
                AutoSwapPlugin.createDcaOrder,
                (address(tokenA), address(tokenB), DCA_AMOUNT, 1 days, 10, 0, slippageBps)
            )
        );
    }

    function test_DcaSandwichReverts() public {
        _setUp(18, 0);
        AutoSwapSandwicher attacker = new AutoSwapSandwicher();
        tokenA.mint(address(attacker), 900_000 ether);

        vm.expectRevert();
        attacker.attack(plugin, router, tokenA, tokenB, account, 0, 900_000 ether);

        assertEq(tokenA.balanceOf(account), 1000 ether);
        assertEq(tokenB.balanceOf(account), 0);
        assertEq(plugin.getOrder(account, 0).executionsRemaining, 10);
    }

    function test_DcaExecutesAtFairPrice() public {
        _setUp(18, 0);

        plugin.executeOrder(account, 0);

        uint256 out = tokenB.balanceOf(account);
        assertGe(out, DCA_AMOUNT * 99 / 100);
        assertEq(tokenA.balanceOf(account), 900 ether);
        assertEq(plugin.getOrder(account, 0).executionsRemaining, 9);
    }

    /// @dev Oracle prices are per whole token; the minimum output must be scaled to tokenOut's decimals
    function test_DcaExecutesAcrossDecimals() public {
        _setUp(6, 0);

        plugin.executeOrder(account, 0);

        assertGe(tokenB.balanceOf(account), 99e6);
    }

    function test_DcaRespectsOrderSlippage() public {
        _setUp(18, 50); // 0.5%
        // Thin the B side so the swap returns ~99.1 B for 100 A: within the 1% default bound,
        // beyond this order's 0.5% bound
        vm.prank(address(router));
        tokenB.transfer(address(1), 800 ether);

        vm.expectRevert();
        plugin.executeOrder(account, 0);
    }
}
