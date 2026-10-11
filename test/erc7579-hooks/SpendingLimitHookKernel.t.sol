// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./HookKernelBase.sol";
import { SpendingLimitHook } from "../../src/erc7579-hooks/SpendingLimitHook.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice SpendingLimitHook must not let a monitored execution grant allowances on a limited token (SLH-1)
contract SpendingLimitHookKernelTest is HookKernelBase {
    HookTestToken internal token;
    SpendingLimitHook internal slh;

    function setUp() public {
        _baseSetUp();
        token = new HookTestToken();
        slh = new SpendingLimitHook();
    }

    /// @dev Account whose delegate key is limited to 100 TKN per day
    function _limitedAccount(uint256 salt) internal returns (address account, ECDSAValidator v) {
        account = _createAccount(salt);
        token.mint(account, 10_000 ether);
        address[] memory t = new address[](1);
        t[0] = address(token);
        uint256[] memory l = new uint256[](1);
        l[0] = 100 ether;
        uint256[] memory p = new uint256[](1);
        p[0] = 1 days;
        v = _installDelegateValidator(account, IHook(address(slh)), abi.encodePacked(hex"ff", abi.encode(t, l, p)));
    }

    function test_TransferWithinLimitPasses() public {
        (address account, ECDSAValidator v) = _limitedAccount(1);
        assertTrue(
            _sendOp(
                account,
                address(v),
                _executeSingle(address(token), 0, abi.encodeCall(IERC20.transfer, (beneficiary, 40 ether)))
            )
        );
        assertEq(slh.getRemainingAllowance(account, address(token)), 60 ether);
    }

    function test_RejectsApproveOnLimitedToken() public {
        (address account, ECDSAValidator v) = _limitedAccount(2);
        _assertOpReverts(
            account,
            address(v),
            _executeSingle(address(token), 0, abi.encodeCall(IERC20.approve, (attacker, type(uint256).max))),
            abi.encodeWithSelector(
                SpendingLimitHook.AllowanceChangeNotAllowed.selector, address(token), IERC20.approve.selector
            )
        );
        assertEq(token.allowance(account, attacker), 0);

        vm.prank(attacker);
        vm.expectRevert();
        token.transferFrom(account, attacker, 5000 ether);
    }

    function test_RejectsApproveInsideBatch() public {
        (address account, ECDSAValidator v) = _limitedAccount(3);
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution({
            target: address(token), value: 0, callData: abi.encodeCall(IERC20.transfer, (beneficiary, 1 ether))
        });
        execs[1] = Execution({
            target: address(token), value: 0, callData: abi.encodeCall(IERC20.approve, (attacker, 5000 ether))
        });
        _assertOpReverts(
            account,
            address(v),
            _executeBatch(execs),
            abi.encodeWithSelector(
                SpendingLimitHook.AllowanceChangeNotAllowed.selector, address(token), IERC20.approve.selector
            )
        );
        assertEq(token.allowance(account, attacker), 0);
    }

    /// @dev Revoking an allowance with approve(spender, 0) cannot spend the token and stays allowed
    function test_ApproveZeroRevokeOnLimitedTokenPasses() public {
        (address account, ECDSAValidator v) = _limitedAccount(6);
        vm.prank(account);
        token.approve(attacker, 50 ether);

        assertTrue(
            _sendOp(
                account, address(v), _executeSingle(address(token), 0, abi.encodeCall(IERC20.approve, (attacker, 0)))
            ),
            "revoke passes"
        );
        assertEq(token.allowance(account, attacker), 0);
        assertEq(slh.getRemainingAllowance(account, address(token)), 100 ether);
    }

    /// @dev A delegate runs as the account and could approve (or reconfigure the hook) unseen
    function test_RejectsDelegatecall() public {
        (address account, ECDSAValidator v) = _limitedAccount(4);
        HookTestApproveDelegate impl = new HookTestApproveDelegate();
        _assertOpReverts(
            account,
            address(v),
            _executeDelegatecall(
                address(impl), abi.encodeCall(HookTestApproveDelegate.approveAll, (address(token), attacker))
            ),
            abi.encodeWithSelector(SpendingLimitHook.DelegatecallNotAllowed.selector)
        );
        assertEq(token.allowance(account, attacker), 0);
    }

    function test_ApproveOnUnlimitedTokenPasses() public {
        (address account, ECDSAValidator v) = _limitedAccount(5);
        HookTestToken other = new HookTestToken();
        assertTrue(
            _sendOp(
                account,
                address(v),
                _executeSingle(address(other), 0, abi.encodeCall(IERC20.approve, (beneficiary, 1 ether)))
            )
        );
        assertEq(other.allowance(account, beneficiary), 1 ether);
    }
}
