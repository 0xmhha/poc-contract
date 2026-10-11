// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { KernelModuleTestBase } from "../utils/KernelModuleTestBase.sol";
import { FlashLoanFallback } from "../../src/erc7579-fallbacks/FlashLoanFallback.sol";
import { MockERC20, MockFlashLoanProvider } from "./mocks/MockFallbackAccount.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { ExecLib } from "../../src/erc7579-smartaccount/utils/ExecLib.sol";
import { Execution } from "../../src/erc7579-smartaccount/types/Structs.sol";
import { ExecModePayload } from "../../src/erc7579-smartaccount/types/Types.sol";
import {
    CALLTYPE_BATCH,
    EXECTYPE_DEFAULT,
    EXEC_MODE_DEFAULT
} from "../../src/erc7579-smartaccount/types/Constants.sol";

/// @notice FlashLoanFallback installed on a real Kernel account.
/// @dev Regressions:
///      - AAVE executeOperation and ERC-3156 onFlashLoan ignored `initiator`, so anyone could start a loan
///        to the account through a whitelisted pull-based lender and the account paid the premium.
///      - Strategy calls and Uniswap/Balancer repayment ran from the module's own address, while the
///        borrowed funds sit on the account, so push-based loans could never be repaid.
contract FlashLoanFallbackKernelTest is KernelModuleTestBase {
    FlashLoanFallback internal flf;
    MockFlashLoanProvider internal lender;
    MockERC20 internal token;
    address internal account;
    address internal attacker = makeAddr("attacker");
    address internal payee = makeAddr("payee");

    uint256 internal constant LOAN = 100_000 ether;
    uint256 internal constant FEE = LOAN * 9 / 10_000;

    function setUp() public {
        _deployKernel();
        account = _createAccount(0);

        flf = new FlashLoanFallback();
        lender = new MockFlashLoanProvider();
        token = new MockERC20("Token", "TKN");
        token.mint(address(lender), 1_000_000 ether);
        token.mint(account, 1000 ether);

        bytes memory config = abi.encode(true, true); // require whitelist, log loans
        _installFallback(account, address(flf), FlashLoanFallback.executeOperation.selector, config);
        _installFallback(account, address(flf), FlashLoanFallback.onFlashLoan.selector, config);
        _installFallback(account, address(flf), FlashLoanFallback.uniswapV3FlashCallback.selector, config);
        _installFallback(account, address(flf), FlashLoanFallback.receiveFlashLoan.selector, config);
        // Strategy calls and repayment run as the account
        _installExecutor(account, address(flf), "");
        _execAsAccount(account, address(flf), abi.encodeCall(FlashLoanFallback.addToWhitelist, (address(lender))));
    }

    function _aaveLoan() internal view returns (bytes memory) {
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = LOAN;
        return abi.encodeCall(
            MockFlashLoanProvider.flashLoan, (account, assets, amounts, new uint256[](1), account, "", uint16(0))
        );
    }

    /// @dev One account transaction: announce the loan to the module, then take it
    function _loanAsAccount(bytes memory loanCall) internal {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(address(flf), 0, abi.encodeCall(FlashLoanFallback.beginFlashLoan, (address(lender))));
        calls[1] = Execution(address(lender), 0, loanCall);
        vm.prank(owner);
        Kernel(payable(account))
            .execute(
                ExecLib.encode(CALLTYPE_BATCH, EXECTYPE_DEFAULT, EXEC_MODE_DEFAULT, ExecModePayload.wrap(bytes22(0))),
                ExecLib.encodeBatch(calls)
            );
    }

    function test_ERC3156_RevertsWhenThirdPartyInitiates() public {
        vm.prank(attacker);
        vm.expectRevert();
        lender.flashLoanERC3156(account, address(token), LOAN, "");

        assertEq(token.balanceOf(account), 1000 ether);
        assertEq(flf.getFlashLoanLogLength(account), 0);
    }

    function test_Aave_RevertsWhenThirdPartyInitiates() public {
        vm.prank(attacker);
        (bool ok,) = address(lender).call(_aaveLoan());

        assertFalse(ok);
        assertEq(token.balanceOf(account), 1000 ether);
        assertEq(flf.getFlashLoanLogLength(account), 0);
    }

    function test_ERC3156_AccountInitiatedLoanSucceeds() public {
        _loanAsAccount(abi.encodeCall(MockFlashLoanProvider.flashLoanERC3156, (account, address(token), LOAN, "")));

        assertEq(token.balanceOf(account), 1000 ether - FEE);
        assertEq(token.allowance(account, address(lender)), 0);
        assertEq(flf.getFlashLoanLog(account, 0).initiatorHash, keccak256(abi.encodePacked(account)));
    }

    function test_Aave_AccountInitiatedLoanSucceeds() public {
        _loanAsAccount(_aaveLoan());

        assertEq(token.balanceOf(account), 1000 ether - FEE);
        assertEq(token.allowance(account, address(lender)), 0);
        assertEq(flf.getFlashLoanLog(account, 0).initiatorHash, keccak256(abi.encodePacked(account)));
    }

    function test_Uniswap_RepaysFromAccount() public {
        _loanAsAccount(abi.encodeCall(MockFlashLoanProvider.uniswapFlash, (account, address(token), LOAN, "")));

        assertEq(token.balanceOf(account), 1000 ether - FEE);
        assertEq(token.balanceOf(address(flf)), 0);
        assertEq(flf.getFlashLoanLogLength(account), 1);
    }

    function test_Balancer_RepaysFromAccount() public {
        _loanAsAccount(abi.encodeCall(MockFlashLoanProvider.balancerFlashLoan, (account, address(token), LOAN, "")));

        assertEq(token.balanceOf(account), 1000 ether - FEE);
        assertEq(token.balanceOf(address(flf)), 0);
        assertEq(flf.getFlashLoanLogLength(account), 1);
    }

    /// @dev The strategy step must act with the borrowed funds, which only the account holds
    function test_Strategy_RunsAsAccount() public {
        bytes memory strategy = abi.encode(address(token), abi.encodeCall(MockERC20.transfer, (payee, 1 ether)));
        _loanAsAccount(
            abi.encodeCall(MockFlashLoanProvider.balancerFlashLoan, (account, address(token), LOAN, strategy))
        );

        assertEq(token.balanceOf(payee), 1 ether);
        assertEq(token.balanceOf(account), 1000 ether - FEE - 1 ether);
    }

    /// @dev Balancer lets anyone name the account as recipient; without the announcement check the
    ///      attacker's userData would run as the account
    function test_Balancer_RevertsWhenThirdPartyInitiates() public {
        bytes memory drain = abi.encode(address(token), abi.encodeCall(MockERC20.transfer, (attacker, 1000 ether)));

        vm.prank(attacker);
        vm.expectRevert();
        lender.balancerFlashLoan(account, address(token), LOAN, drain);

        assertEq(token.balanceOf(account), 1000 ether);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(flf.getFlashLoanLogLength(account), 0);
    }

    /// @dev An announcement left over from an earlier call in the same transaction covers one callback only
    function test_Balancer_RevertsAfterAnnouncementConsumed() public {
        _loanAsAccount(abi.encodeCall(MockFlashLoanProvider.balancerFlashLoan, (account, address(token), LOAN, "")));

        bytes memory drain = abi.encode(address(token), abi.encodeCall(MockERC20.transfer, (attacker, 1 ether)));
        vm.prank(attacker);
        vm.expectRevert();
        lender.balancerFlashLoan(account, address(token), LOAN, drain);

        assertEq(token.balanceOf(attacker), 0);
    }
}
