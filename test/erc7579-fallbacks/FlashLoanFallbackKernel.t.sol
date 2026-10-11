// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { KernelModuleTestBase } from "../utils/KernelModuleTestBase.sol";
import { FlashLoanFallback } from "../../src/erc7579-fallbacks/FlashLoanFallback.sol";
import { MockERC20, MockFlashLoanProvider } from "./mocks/MockFallbackAccount.sol";

/// @notice FlashLoanFallback installed on a real Kernel account.
/// @dev Regression: AAVE executeOperation and ERC-3156 onFlashLoan ignored `initiator`, so anyone could
///      start a loan to the account through a whitelisted pull-based lender and the account paid the premium.
contract FlashLoanFallbackKernelTest is KernelModuleTestBase {
    FlashLoanFallback internal flf;
    MockFlashLoanProvider internal lender;
    MockERC20 internal token;
    address internal account;
    address internal attacker = makeAddr("attacker");

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
        _execAsAccount(account, address(flf), abi.encodeCall(FlashLoanFallback.addToWhitelist, (address(lender))));
        // Pull-based lenders collect repayment from the account's own allowance
        _execAsAccount(account, address(token), abi.encodeCall(MockERC20.approve, (address(lender), type(uint256).max)));
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
        _execAsAccount(
            account,
            address(lender),
            abi.encodeCall(MockFlashLoanProvider.flashLoanERC3156, (account, address(token), LOAN, ""))
        );

        assertEq(token.balanceOf(account), 1000 ether - FEE);
        assertEq(flf.getFlashLoanLog(account, 0).initiatorHash, keccak256(abi.encodePacked(account)));
    }

    function test_Aave_AccountInitiatedLoanSucceeds() public {
        _execAsAccount(account, address(lender), _aaveLoan());

        assertEq(token.balanceOf(account), 1000 ether - FEE);
        assertEq(flf.getFlashLoanLog(account, 0).initiatorHash, keccak256(abi.encodePacked(account)));
    }
}
