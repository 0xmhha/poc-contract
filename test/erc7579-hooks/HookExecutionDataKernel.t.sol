// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./HookKernelBase.sol";
import { PolicyHook } from "../../src/erc7579-hooks/PolicyHook.sol";
import { AuditHook } from "../../src/erc7579-hooks/AuditHook.sol";
import { HealthFactorHook } from "../../src/erc7579-hooks/HealthFactorHook.sol";
import { HookExecutionDataLib } from "../../src/erc7579-hooks/HookExecutionDataLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract HookTestLendingPool {
    mapping(address => uint256) public healthFactors;

    function setHealthFactor(address user, uint256 hf) external {
        healthFactors[user] = hf;
    }

    function calculateHealthFactor(address user) external view returns (uint256) {
        return healthFactors[user];
    }

    /// @notice Simulates a borrow that drops the caller below the liquidation threshold
    function drop() external {
        healthFactors[msg.sender] = 0.5e18;
    }
}

contract HookTestDropDelegate {
    function run(HookTestLendingPool pool) external {
        pool.drop();
    }
}

/// @notice Hooks must see the executions Kernel actually runs (HOOK-1, HOOK-2)
contract HookExecutionDataKernelTest is HookKernelBase {
    HookTestToken internal token;
    PolicyHook internal policy;
    AuditHook internal audit;

    function setUp() public {
        _baseSetUp();
        token = new HookTestToken();
        policy = new PolicyHook();
        audit = new AuditHook();
    }

    function _account(uint256 salt) internal returns (address account) {
        account = _createAccount(salt);
        token.mint(account, 10_000 ether);
        vm.deal(account, 10 ether);
    }

    function _policyData(PolicyHook.PolicyMode mode) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"ff", abi.encode(mode, false));
    }

    function _transfer(address to, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC20.transfer, (to, amount));
    }

    // ============ PolicyHook via executeUserOp (execute calldata) ============

    function test_PolicyBlocklist_BlocksTargetViaExecuteUserOp() public {
        address account = _account(1);
        ECDSAValidator v =
            _installDelegateValidator(account, IHook(address(policy)), _policyData(PolicyHook.PolicyMode.BLOCKLIST));
        vm.prank(account);
        policy.addBlockedTarget(address(token));

        _assertOpReverts(
            account,
            address(v),
            _executeSingle(address(token), 0, _transfer(attacker, 5000 ether)),
            abi.encodeWithSelector(PolicyHook.TargetIsBlocked.selector, address(token))
        );
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_PolicyAllowlist_ChecksTargetAndSelectorViaExecuteUserOp() public {
        address account = _account(2);
        ECDSAValidator v =
            _installDelegateValidator(account, IHook(address(policy)), _policyData(PolicyHook.PolicyMode.ALLOWLIST));
        vm.startPrank(account);
        policy.addAllowedTarget(address(token));
        policy.addAllowedSelector(address(token), IERC20.transfer.selector);
        policy.setStrictSelectorMode(address(token), true);
        vm.stopPrank();

        assertTrue(
            _sendOp(account, address(v), _executeSingle(address(token), 0, _transfer(beneficiary, 1 ether))),
            "allowed target and selector must pass"
        );
        assertEq(token.balanceOf(beneficiary), 1 ether);

        bytes memory approveCall = abi.encodeCall(IERC20.approve, (attacker, 1 ether));
        _assertOpReverts(
            account,
            address(v),
            _executeSingle(address(token), 0, approveCall),
            abi.encodeWithSelector(PolicyHook.SelectorNotAllowed.selector, address(token), IERC20.approve.selector)
        );
        assertEq(token.allowance(account, attacker), 0);
    }

    function test_PolicyValueLimit_EnforcedViaExecuteUserOp() public {
        address account = _account(3);
        ECDSAValidator v =
            _installDelegateValidator(account, IHook(address(policy)), _policyData(PolicyHook.PolicyMode.BLOCKLIST));
        vm.prank(account);
        policy.setTargetValueLimit(attacker, 1 ether);

        _assertOpReverts(
            account,
            address(v),
            _executeSingle(attacker, 5 ether, ""),
            abi.encodeWithSelector(PolicyHook.ValueExceedsLimit.selector, attacker, 5 ether, 1 ether)
        );
        assertEq(attacker.balance, 0);
        assertTrue(_sendOp(account, address(v), _executeSingle(attacker, 0.5 ether, "")), "under value limit");
        assertEq(attacker.balance, 0.5 ether);
    }

    // ============ Batch and delegatecall (HOOK-2) ============

    function test_PolicyBlocklist_BlocksTargetInBatchViaExecutor() public {
        address account = _account(4);
        HookTestExecutor ex =
            _installExecutor(account, IHook(address(policy)), _policyData(PolicyHook.PolicyMode.BLOCKLIST));
        vm.prank(account);
        policy.addBlockedTarget(address(token));

        Execution[] memory execs = new Execution[](1);
        execs[0] = Execution({ target: address(token), value: 0, callData: _transfer(attacker, 5000 ether) });
        vm.expectRevert(abi.encodeWithSelector(PolicyHook.TargetIsBlocked.selector, address(token)));
        ex.run(account, _mode(CALLTYPE_BATCH), ExecLib.encodeBatch(execs));
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_PolicyBlocklist_BlocksTargetInBatchViaExecuteUserOp() public {
        address account = _account(5);
        ECDSAValidator v =
            _installDelegateValidator(account, IHook(address(policy)), _policyData(PolicyHook.PolicyMode.BLOCKLIST));
        vm.prank(account);
        policy.addBlockedTarget(address(token));

        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution({ target: beneficiary, value: 1 wei, callData: "" });
        execs[1] = Execution({ target: address(token), value: 0, callData: _transfer(attacker, 5000 ether) });
        _assertOpReverts(
            account,
            address(v),
            _executeBatch(execs),
            abi.encodeWithSelector(PolicyHook.TargetIsBlocked.selector, address(token))
        );
        assertEq(token.balanceOf(attacker), 0);
    }

    /// @dev Value limits apply to the sum sent to a target across a batch, not per execution
    function test_PolicyValueLimit_SumsBatchValuePerTarget() public {
        address account = _account(20);
        ECDSAValidator v =
            _installDelegateValidator(account, IHook(address(policy)), _policyData(PolicyHook.PolicyMode.BLOCKLIST));
        vm.prank(account);
        policy.setTargetValueLimit(attacker, 1 ether);

        Execution[] memory execs = new Execution[](3);
        execs[0] = Execution({ target: attacker, value: 0.5 ether, callData: "" });
        execs[1] = Execution({ target: beneficiary, value: 0.5 ether, callData: "" });
        execs[2] = Execution({ target: attacker, value: 0.6 ether, callData: "" });
        _assertOpReverts(
            account,
            address(v),
            _executeBatch(execs),
            abi.encodeWithSelector(PolicyHook.ValueExceedsLimit.selector, attacker, 1.1 ether, 1 ether)
        );
        assertEq(attacker.balance, 0);

        execs[2].value = 0.5 ether;
        assertTrue(_sendOp(account, address(v), _executeBatch(execs)), "batch sum at the limit");
        assertEq(attacker.balance, 1 ether);
    }

    /// @dev Each execution of a batch counts toward the transaction count limit
    function test_PolicyTxCount_CountsEachBatchExecution() public {
        address account = _account(21);
        ECDSAValidator v =
            _installDelegateValidator(account, IHook(address(policy)), _policyData(PolicyHook.PolicyMode.BLOCKLIST));
        vm.prank(account);
        policy.setTransactionCountLimit(2, 1 days);

        Execution[] memory execs = new Execution[](3);
        for (uint256 i; i < 3; i++) {
            execs[i] = Execution({ target: attacker, value: 1 wei, callData: "" });
        }
        _assertOpReverts(
            account,
            address(v),
            _executeBatch(execs),
            abi.encodeWithSelector(PolicyHook.TransactionCountExceeded.selector)
        );
        assertEq(attacker.balance, 0);

        Execution[] memory two = new Execution[](2);
        two[0] = execs[0];
        two[1] = execs[1];
        assertTrue(_sendOp(account, address(v), _executeBatch(two)), "batch within the count limit");
        assertEq(policy.getRemainingTransactionCount(account), 0);
    }

    /// @dev Kernel calls the low 160 bits of a batch target word; the hook must check the same address
    function test_PolicyBlocklist_BlocksDirtyBatchTarget() public {
        address account = _account(6);
        HookTestExecutor ex =
            _installExecutor(account, IHook(address(policy)), _policyData(PolicyHook.PolicyMode.BLOCKLIST));
        vm.prank(account);
        policy.addBlockedTarget(address(token));

        Execution[] memory execs = new Execution[](1);
        execs[0] = Execution({ target: address(token), value: 0, callData: _transfer(attacker, 5000 ether) });
        bytes memory batch = ExecLib.encodeBatch(execs);
        // abi.encode(Execution[]): [0x00] array offset, [0x20] length, [0x40] element offset, [0x60] target word
        for (uint256 i = 0x60; i < 0x6c; i++) {
            batch[i] = 0xff;
        }
        vm.expectRevert(abi.encodeWithSelector(PolicyHook.TargetIsBlocked.selector, address(token)));
        ex.run(account, _mode(CALLTYPE_BATCH), batch);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_PolicyDelegatecall_RequiresAllowedDelegate() public {
        address account = _account(7);
        ECDSAValidator v =
            _installDelegateValidator(account, IHook(address(policy)), _policyData(PolicyHook.PolicyMode.BLOCKLIST));
        vm.prank(account);
        policy.addBlockedTarget(address(token));
        HookTestApproveDelegate impl = new HookTestApproveDelegate();
        bytes memory call_ = _executeDelegatecall(
            address(impl), abi.encodeCall(HookTestApproveDelegate.approveAll, (address(token), attacker))
        );

        _assertOpReverts(
            account, address(v), call_, abi.encodeWithSelector(PolicyHook.TargetNotAllowed.selector, address(impl))
        );
        assertEq(token.allowance(account, attacker), 0);

        vm.prank(account);
        policy.addAllowedTarget(address(impl));
        assertTrue(_sendOp(account, address(v), call_), "explicitly allowed delegate passes");
    }

    function test_PolicyRejectsUnsupportedCallType() public {
        policy.onInstall(abi.encode(PolicyHook.PolicyMode.BLOCKLIST, false));
        bytes memory msgData = abi.encodeCall(
            Kernel.execute,
            (
                ExecLib.encode(
                    CallType.wrap(0xfe), EXECTYPE_DEFAULT, EXEC_MODE_DEFAULT, ExecModePayload.wrap(bytes22(0))
                ),
                ExecLib.encodeSingle(address(token), 0, _transfer(attacker, 1))
            )
        );
        vm.expectRevert(abi.encodeWithSelector(HookExecutionDataLib.UnsupportedCallType.selector, CallType.wrap(0xfe)));
        policy.preCheck(address(entryPoint), 0, msgData);
    }

    // ============ AuditHook via executeUserOp ============

    function test_AuditFlaggedTransferRequiresQueueViaExecuteUserOp() public {
        address account = _account(8);
        ECDSAValidator v = _installDelegateValidator(
            account, IHook(address(audit)), abi.encodePacked(hex"ff", abi.encode(uint256(1 ether), uint256(1 days)))
        );
        bytes memory inner = _executeSingle(attacker, 5 ether, "");

        bytes32 txHash = keccak256(abi.encodePacked(account, attacker, uint256(5 ether), inner));
        _assertOpReverts(
            account, address(v), inner, abi.encodeWithSelector(AuditHook.TransactionNotQueued.selector, txHash)
        );
        assertEq(attacker.balance, 0);

        vm.prank(account);
        audit.queueFlaggedTransaction(attacker, 5 ether, inner);
        vm.warp(2 days);
        assertTrue(_sendOp(account, address(v), inner), "queued transfer passes after the delay");
        assertEq(attacker.balance, 5 ether);

        AuditHook.AuditEntry memory e = audit.getAuditEntry(account, 0);
        assertEq(e.target, attacker);
        assertEq(e.value, 5 ether);
        assertTrue(e.isFlagged);
    }

    function test_AuditBlocklist_ChecksEveryBatchTarget() public {
        address account = _account(9);
        ECDSAValidator v = _installDelegateValidator(
            account, IHook(address(audit)), abi.encodePacked(hex"ff", abi.encode(uint256(100 ether), uint256(0)))
        );
        vm.prank(account);
        audit.setBlocklist(attacker, true);

        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution({ target: address(token), value: 0, callData: _transfer(beneficiary, 1 ether) });
        execs[1] = Execution({ target: attacker, value: 1 ether, callData: "" });
        _assertOpReverts(
            account,
            address(v),
            _executeBatch(execs),
            abi.encodeWithSelector(AuditHook.AddressBlocked.selector, attacker)
        );
        assertEq(attacker.balance, 0);
    }

    // ============ HealthFactorHook ============

    function _hfSetUp(uint256 salt)
        internal
        returns (address account, ECDSAValidator v, HookTestLendingPool pool, HealthFactorHook hf)
    {
        account = _account(salt);
        pool = new HookTestLendingPool();
        hf = new HealthFactorHook(address(pool));
        v = _installDelegateValidator(account, IHook(address(hf)), abi.encodePacked(hex"ff", abi.encode(1.2e18, true)));
        vm.prank(account);
        hf.addMonitoredTarget(address(pool));
        pool.setHealthFactor(account, 2e18);
    }

    /// @dev Kernel's ABI decoder follows the bytes offset; a non-0x40 offset must not hide the target
    function test_HealthFactor_MonitorsNonCanonicalOffset() public {
        (address account, ECDSAValidator v, HookTestLendingPool pool,) = _hfSetUp(10);
        bytes memory execData = ExecLib.encodeSingle(address(pool), 0, abi.encodeCall(HookTestLendingPool.drop, ()));
        bytes memory inner = abi.encodePacked(
            Kernel.execute.selector,
            ExecMode.unwrap(_mode(CALLTYPE_SINGLE)),
            uint256(0x60), // offset of the bytes argument
            uint256(0), // padding word
            uint256(execData.length),
            execData
        );

        _assertOpReverts(
            account, address(v), inner, abi.encodeWithSelector(HealthFactorHook.HealthFactorTooLow.selector)
        );
        assertEq(pool.healthFactors(account), 2e18);
    }

    function test_HealthFactor_MonitorsDelegatecall() public {
        (address account, ECDSAValidator v, HookTestLendingPool pool,) = _hfSetUp(11);
        HookTestDropDelegate impl = new HookTestDropDelegate();
        bytes memory inner = _executeDelegatecall(address(impl), abi.encodeCall(HookTestDropDelegate.run, (pool)));

        _assertOpReverts(
            account, address(v), inner, abi.encodeWithSelector(HealthFactorHook.HealthFactorTooLow.selector)
        );
        assertEq(pool.healthFactors(account), 2e18);
    }
}
