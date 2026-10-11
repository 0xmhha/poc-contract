// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, Vm } from "forge-std/Test.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { KernelFactory } from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";
import { ECDSAValidator } from "../../src/erc7579-validators/ECDSAValidator.sol";
import { IValidator, IHook } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { ValidationId, ExecMode, CallType } from "../../src/erc7579-smartaccount/types/Types.sol";
import {
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_EXECUTOR,
    HOOK_MODULE_INSTALLED,
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    CALLTYPE_DELEGATECALL,
    EXECTYPE_DEFAULT,
    EXEC_MODE_DEFAULT
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import { ValidatorLib } from "../../src/erc7579-smartaccount/utils/ValidationTypeLib.sol";
import { ExecLib, ExecModePayload } from "../../src/erc7579-smartaccount/utils/ExecLib.sol";
import { Execution } from "../../src/erc7579-smartaccount/types/Structs.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract HookTestToken is ERC20 {
    constructor() ERC20("TKN", "TKN") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Executor that forwards to Kernel.executeFromExecutor
contract HookTestExecutor {
    function onInstall(bytes calldata) external payable { }
    function onUninstall(bytes calldata) external payable { }

    function isModuleType(uint256 t) external pure returns (bool) {
        return t == MODULE_TYPE_EXECUTOR;
    }

    function isInitialized(address) external pure returns (bool) {
        return true;
    }

    function run(address account, ExecMode mode, bytes calldata data) external {
        Kernel(payable(account)).executeFromExecutor(mode, data);
    }
}

/// @notice Delegatecall target: approves `spender` for `token` as the calling account
contract HookTestApproveDelegate {
    function approveAll(address token, address spender) external {
        ERC20(token).approve(spender, type(uint256).max);
    }
}

/// @notice Real Kernel + EntryPoint setup that drives hooks through Kernel's own call paths
abstract contract HookKernelBase is Test {
    EntryPoint internal entryPoint;
    Kernel internal kernelImpl;
    KernelFactory internal kernelFactory;
    ECDSAValidator internal rootValidator;
    address internal senderCreator;

    address internal owner;
    uint256 internal ownerKey;
    address internal delegate; // restricted (hooked) key
    uint256 internal delegateKey;
    address internal attacker = makeAddr("attacker");
    address internal beneficiary = makeAddr("beneficiary");

    bytes32 internal constant USEROP_EVENT_SIG =
        keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    bytes32 internal constant REVERT_REASON_SIG = keccak256("UserOperationRevertReason(bytes32,address,uint256,bytes)");

    /// @dev Revert data of the last UserOp sent with _sendOp (empty on success)
    bytes internal lastRevertReason;

    function _baseSetUp() internal {
        (owner, ownerKey) = makeAddrAndKey("owner");
        (delegate, delegateKey) = makeAddrAndKey("delegate");
        entryPoint = new EntryPoint();
        kernelImpl = new Kernel(IEntryPoint(address(entryPoint)));
        kernelFactory = new KernelFactory(address(kernelImpl), IEntryPoint(address(entryPoint)));
        rootValidator = new ECDSAValidator();
        senderCreator = address(entryPoint.senderCreator());
    }

    /// @dev Root = ECDSA(owner) without a root hook
    function _createAccount(uint256 salt) internal returns (address account) {
        ValidationId vId = ValidatorLib.validatorToIdentifier(IValidator(address(rootValidator)));
        bytes memory initData = abi.encodeCall(
            Kernel.initialize, (vId, IHook(HOOK_MODULE_INSTALLED), abi.encodePacked(owner), hex"", new bytes[](0))
        );
        vm.prank(senderCreator);
        account = kernelFactory.createAccount(initData, bytes32(salt));
        vm.deal(address(this), 100 ether);
        entryPoint.depositTo{ value: 10 ether }(account);
    }

    /// @dev Installs an ECDSA validator for `delegate` with `hook`, granted the `execute` selector
    function _installDelegateValidator(address account, IHook hook, bytes memory hookData)
        internal
        returns (ECDSAValidator v)
    {
        v = new ECDSAValidator();
        bytes memory initData = abi.encodePacked(
            bytes20(address(hook)),
            abi.encode(abi.encodePacked(delegate), hookData, abi.encodePacked(Kernel.execute.selector))
        );
        vm.prank(owner);
        Kernel(payable(account)).installModule(MODULE_TYPE_VALIDATOR, address(v), initData);
    }

    /// @dev Installs a forwarding executor with `hook`
    function _installExecutor(address account, IHook hook, bytes memory hookData)
        internal
        returns (HookTestExecutor ex)
    {
        ex = new HookTestExecutor();
        vm.prank(owner);
        Kernel(payable(account))
            .installModule(
                MODULE_TYPE_EXECUTOR,
                address(ex),
                abi.encodePacked(bytes20(address(hook)), abi.encode(bytes(""), hookData))
            );
    }

    function _mode(CallType ct) internal pure returns (ExecMode) {
        return ExecLib.encode(ct, EXECTYPE_DEFAULT, EXEC_MODE_DEFAULT, ExecModePayload.wrap(bytes22(0)));
    }

    function _executeSingle(address target, uint256 value, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeCall(Kernel.execute, (_mode(CALLTYPE_SINGLE), ExecLib.encodeSingle(target, value, data)));
    }

    function _executeBatch(Execution[] memory execs) internal pure returns (bytes memory) {
        return abi.encodeCall(Kernel.execute, (_mode(CALLTYPE_BATCH), ExecLib.encodeBatch(execs)));
    }

    function _executeDelegatecall(address target, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeCall(Kernel.execute, (_mode(CALLTYPE_DELEGATECALL), abi.encodePacked(target, data)));
    }

    /// @dev Sends a UserOp with callData = executeUserOp.selector || innerCalldata, signed by the
    ///      delegate key for `validator`. Returns the UserOperationEvent success flag.
    function _sendOp(address account, address validator, bytes memory innerCalldata) internal returns (bool success) {
        uint192 key = ValidatorLib.encodeAsNonceKey(bytes1(0x00), bytes1(0x01), bytes20(validator), 0);
        PackedUserOperation memory op = PackedUserOperation({
            sender: account,
            nonce: entryPoint.getNonce(account, key),
            initCode: hex"",
            callData: abi.encodePacked(Kernel.executeUserOp.selector, innerCalldata),
            accountGasLimits: bytes32(abi.encodePacked(uint128(2_000_000), uint128(3_000_000))),
            preVerificationGas: 100_000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(10 gwei))),
            paymasterAndData: hex"",
            signature: hex""
        });
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegateKey, ECDSA.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        vm.recordLogs();
        vm.prank(beneficiary, beneficiary);
        entryPoint.handleOps(ops, payable(beneficiary));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        delete lastRevertReason;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(entryPoint)) continue;
            if (logs[i].topics[0] == USEROP_EVENT_SIG) {
                (, success,,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                found = true;
            } else if (logs[i].topics[0] == REVERT_REASON_SIG) {
                (, lastRevertReason) = abi.decode(logs[i].data, (uint256, bytes));
            }
        }
        require(found, "no UserOperationEvent");
    }

    /// @dev Sends the UserOp and asserts it failed with `reason`
    function _assertOpReverts(address account, address validator, bytes memory innerCalldata, bytes memory reason)
        internal
    {
        assertFalse(_sendOp(account, validator, innerCalldata), "UserOp must fail");
        assertEq(lastRevertReason, reason, "revert reason");
    }
}
