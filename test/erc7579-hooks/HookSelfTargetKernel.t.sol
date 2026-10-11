// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./HookKernelBase.sol";
import { SpendingLimitHook } from "../../src/erc7579-hooks/SpendingLimitHook.sol";
import { PolicyHook } from "../../src/erc7579-hooks/PolicyHook.sol";
import { AuditHook } from "../../src/erc7579-hooks/AuditHook.sol";
import { HealthFactorHook } from "../../src/erc7579-hooks/HealthFactorHook.sol";
import { HookExecutionDataLib } from "../../src/erc7579-hooks/HookExecutionDataLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A monitored execution must not reconfigure its own hook (SLH-2 / HOOK-3)
contract HookSelfTargetKernelTest is HookKernelBase {
    HookTestToken internal token;

    function setUp() public {
        _baseSetUp();
        token = new HookTestToken();
    }

    function _account(uint256 salt) internal returns (address account) {
        account = _createAccount(salt);
        token.mint(account, 10_000 ether);
        vm.deal(account, 10 ether);
    }

    function _forbidden(address target) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(HookExecutionDataLib.ForbiddenExecutionTarget.selector, target);
    }

    function _slhAccount(uint256 salt) internal returns (address account, ECDSAValidator v, SpendingLimitHook slh) {
        account = _account(salt);
        slh = new SpendingLimitHook();
        address[] memory t = new address[](1);
        t[0] = address(token);
        uint256[] memory l = new uint256[](1);
        l[0] = 100 ether;
        uint256[] memory p = new uint256[](1);
        p[0] = 1 days;
        v = _installDelegateValidator(account, IHook(address(slh)), abi.encodePacked(hex"ff", abi.encode(t, l, p)));
    }

    // ============ SpendingLimitHook ============

    function test_SpendingLimit_RejectsRaisingOwnLimitInBatch() public {
        (address account, ECDSAValidator v, SpendingLimitHook slh) = _slhAccount(1);
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution({
            target: address(slh),
            value: 0,
            callData: abi.encodeCall(SpendingLimitHook.setSpendingLimit, (address(token), 1e30, 1 days))
        });
        execs[1] = Execution({
            target: address(token), value: 0, callData: abi.encodeCall(IERC20.transfer, (attacker, 5000 ether))
        });
        _assertOpReverts(account, address(v), _executeBatch(execs), _forbidden(address(slh)));
        assertEq(token.balanceOf(attacker), 0);
        assertEq(slh.getSpendingLimit(account, address(token)).limit, 100 ether);
    }

    function test_SpendingLimit_RejectsRemovingOwnLimit() public {
        (address account, ECDSAValidator v, SpendingLimitHook slh) = _slhAccount(2);
        _assertOpReverts(
            account,
            address(v),
            _executeSingle(address(slh), 0, abi.encodeCall(SpendingLimitHook.removeSpendingLimit, (address(token)))),
            _forbidden(address(slh))
        );
        assertTrue(slh.getSpendingLimit(account, address(token)).isEnabled);
    }

    /// @dev execute(self, execute(...)) runs the inner executions without this hook
    function test_SpendingLimit_RejectsNestedSelfExecute() public {
        (address account, ECDSAValidator v, SpendingLimitHook slh) = _slhAccount(3);
        bytes memory raise = _executeSingle(
            address(slh), 0, abi.encodeCall(SpendingLimitHook.setSpendingLimit, (address(token), 1e30, 1 days))
        );
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution({ target: account, value: 0, callData: raise });
        execs[1] = Execution({
            target: address(token), value: 0, callData: abi.encodeCall(IERC20.transfer, (attacker, 5000 ether))
        });
        _assertOpReverts(account, address(v), _executeBatch(execs), _forbidden(account));
        assertEq(token.balanceOf(attacker), 0);
    }

    // ============ PolicyHook ============

    function test_Policy_RejectsSelfConfiguration() public {
        address account = _account(4);
        PolicyHook policy = new PolicyHook();
        ECDSAValidator v = _installDelegateValidator(
            account,
            IHook(address(policy)),
            abi.encodePacked(hex"ff", abi.encode(PolicyHook.PolicyMode.BLOCKLIST, false))
        );
        vm.prank(account);
        policy.addBlockedTarget(address(token));

        _assertOpReverts(
            account,
            address(v),
            _executeSingle(address(policy), 0, abi.encodeCall(PolicyHook.removeBlockedTarget, (address(token)))),
            _forbidden(address(policy))
        );
        assertTrue(policy.isTargetBlocked(account, address(token)));
    }

    // ============ AuditHook ============

    function _auditAccount(uint256 salt) internal returns (address account, ECDSAValidator v, AuditHook audit) {
        account = _account(salt);
        audit = new AuditHook();
        v = _installDelegateValidator(
            account, IHook(address(audit)), abi.encodePacked(hex"ff", abi.encode(uint256(1 ether), uint256(1 days)))
        );
    }

    function test_Audit_RejectsSelfConfiguration() public {
        (address account, ECDSAValidator v, AuditHook audit) = _auditAccount(5);
        _assertOpReverts(
            account,
            address(v),
            _executeSingle(address(audit), 0, abi.encodeCall(AuditHook.setConfig, (type(uint256).max, 0))),
            _forbidden(address(audit))
        );
        assertEq(audit.getConfig(account).flaggedDelay, 1 days);
    }

    /// @dev queueFlaggedTransaction stays reachable from the monitored path
    function test_Audit_AllowsQueueingThroughHookedPath() public {
        (address account, ECDSAValidator v, AuditHook audit) = _auditAccount(6);
        bytes memory inner = _executeSingle(attacker, 5 ether, "");
        assertTrue(
            _sendOp(
                account,
                address(v),
                _executeSingle(
                    address(audit), 0, abi.encodeCall(AuditHook.queueFlaggedTransaction, (attacker, 5 ether, inner))
                )
            ),
            "queueing passes"
        );
        vm.warp(2 days);
        assertTrue(_sendOp(account, address(v), inner), "queued transfer passes after the delay");
        assertEq(attacker.balance, 5 ether);
    }

    // ============ HealthFactorHook ============

    function test_HealthFactor_RejectsSelfConfiguration() public {
        address account = _account(7);
        HealthFactorHook hf = new HealthFactorHook(address(0xbeef));
        ECDSAValidator v =
            _installDelegateValidator(account, IHook(address(hf)), abi.encodePacked(hex"ff", abi.encode(1.2e18, true)));
        _assertOpReverts(
            account,
            address(v),
            _executeSingle(address(hf), 0, abi.encodeCall(HealthFactorHook.setEnabled, (false))),
            _forbidden(address(hf))
        );
        assertTrue(hf.isEnabled(account));
    }
}
