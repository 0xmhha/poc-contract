// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { KernelFactory } from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";
import { ECDSAValidator } from "../../src/erc7579-validators/ECDSAValidator.sol";
import { IValidator, IHook } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { ValidationId } from "../../src/erc7579-smartaccount/types/Types.sol";
import {
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_EXECUTOR,
    MODULE_TYPE_FALLBACK,
    HOOK_MODULE_INSTALLED
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import { ValidatorLib } from "../../src/erc7579-smartaccount/utils/ValidationTypeLib.sol";
import { ExecLib } from "../../src/erc7579-smartaccount/utils/ExecLib.sol";
import { ExecMode, ExecModePayload, CallType } from "../../src/erc7579-smartaccount/types/Types.sol";
import {
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    EXECTYPE_DEFAULT,
    EXEC_MODE_DEFAULT
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import { Execution } from "../../src/erc7579-smartaccount/types/Structs.sol";

/// @notice Minimal executor mock for guard testing
contract MockGuardExecutor {
    function onInstall(bytes calldata) external payable { }
    function onUninstall(bytes calldata) external payable { }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 2;
    }
}

/// @notice Minimal fallback mock for guard testing
contract MockGuardFallback {
    function onInstall(bytes calldata) external payable { }
    function onUninstall(bytes calldata) external payable { }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 3;
    }
}

/// @notice Executor whose onUninstall always reverts
contract RevertingUninstallExecutor {
    function onInstall(bytes calldata) external payable { }

    function onUninstall(bytes calldata) external payable {
        revert("onUninstall failed");
    }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 2;
    }
}

/// @notice Executor that tries to make the account call itself (privilege escalation)
contract SelfCallingExecutor {
    function onInstall(bytes calldata) external payable { }
    function onUninstall(bytes calldata) external payable { }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 2;
    }

    /// @dev Single execution whose target is the account itself
    function directSelfCall(address account, bytes calldata selfCallData) external {
        Kernel(payable(account))
            .executeFromExecutor(_mode(CALLTYPE_SINGLE), ExecLib.encodeSingle(account, 0, selfCallData));
    }

    /// @dev Batch: item 0 re-enters executeFromExecutor (clearing a non-nesting flag on return),
    ///      item 1 makes the account call itself.
    function nestedSelfCall(address account, bytes calldata selfCallData) external {
        Execution[] memory executions = new Execution[](2);
        executions[0] =
            Execution({ target: address(this), value: 0, callData: abi.encodeCall(this.reenter, (account)) });
        executions[1] = Execution({ target: account, value: 0, callData: selfCallData });
        Kernel(payable(account)).executeFromExecutor(_mode(CALLTYPE_BATCH), ExecLib.encodeBatch(executions));
    }

    function reenter(address account) external {
        Kernel(payable(account))
            .executeFromExecutor(_mode(CALLTYPE_SINGLE), ExecLib.encodeSingle(address(0xdead), 0, ""));
    }

    function _mode(CallType callType) internal pure returns (ExecMode) {
        return ExecLib.encode(callType, EXECTYPE_DEFAULT, EXEC_MODE_DEFAULT, ExecModePayload.wrap(bytes22(0)));
    }
}

/// @title ERC-7579 Module Guard Tests
/// @notice Tests for installModule/uninstallModule compliance guards added in ERC-7579 fix
contract KernelModuleGuardsTest is Test {
    EntryPoint public entryPoint;
    Kernel public kernelImpl;
    KernelFactory public kernelFactory;
    ECDSAValidator public ecdsaValidator;
    MockGuardExecutor public mockExecutor;
    MockGuardFallback public mockFallback;
    RevertingUninstallExecutor public revertingExecutor;

    address public owner;
    uint256 public ownerKey;
    address public senderCreator;

    function setUp() public {
        (owner, ownerKey) = makeAddrAndKey("owner");

        entryPoint = new EntryPoint();
        kernelImpl = new Kernel(IEntryPoint(address(entryPoint)));
        kernelFactory = new KernelFactory(address(kernelImpl), IEntryPoint(address(entryPoint)), address(0));
        ecdsaValidator = new ECDSAValidator();
        mockExecutor = new MockGuardExecutor();
        mockFallback = new MockGuardFallback();
        revertingExecutor = new RevertingUninstallExecutor();

        senderCreator = address(entryPoint.senderCreator());
    }

    /* //////////////////////////////////////////////////////////////
                    installModule — AlreadyInstalled
    //////////////////////////////////////////////////////////////*/

    function test_InstallModule_ValidatorAlreadyInstalled_Reverts() public {
        address account = _createKernelAccount();

        // ECDSAValidator already installed as root validator via initialize()
        bytes memory initData = _validatorInitData(owner);

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                Kernel.ModuleAlreadyInstalled.selector, MODULE_TYPE_VALIDATOR, address(ecdsaValidator)
            )
        );
        Kernel(payable(account)).installModule(MODULE_TYPE_VALIDATOR, address(ecdsaValidator), initData);
    }

    function test_InstallModule_ExecutorAlreadyInstalled_Reverts() public {
        address account = _createKernelAccount();
        bytes memory initData = _executorInitData();

        // First install succeeds
        vm.prank(account);
        Kernel(payable(account)).installModule(MODULE_TYPE_EXECUTOR, address(mockExecutor), initData);

        // Second install reverts
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(Kernel.ModuleAlreadyInstalled.selector, MODULE_TYPE_EXECUTOR, address(mockExecutor))
        );
        Kernel(payable(account)).installModule(MODULE_TYPE_EXECUTOR, address(mockExecutor), initData);
    }

    function test_InstallModule_FallbackAlreadyInstalled_Reverts() public {
        address account = _createKernelAccount();
        bytes4 selector = bytes4(0x12345678);
        bytes memory initData = _fallbackInitData(selector);

        // First install succeeds
        vm.prank(account);
        Kernel(payable(account)).installModule(MODULE_TYPE_FALLBACK, address(mockFallback), initData);

        // Second install on same selector reverts
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(Kernel.ModuleAlreadyInstalled.selector, MODULE_TYPE_FALLBACK, address(mockFallback))
        );
        Kernel(payable(account)).installModule(MODULE_TYPE_FALLBACK, address(mockFallback), initData);
    }

    /* //////////////////////////////////////////////////////////////
                    uninstallModule — NotInstalled
    //////////////////////////////////////////////////////////////*/

    function test_UninstallModule_ValidatorNotInstalled_Reverts() public {
        address account = _createKernelAccount();

        // A validator that was never installed
        ECDSAValidator uninstalledValidator = new ECDSAValidator();

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                Kernel.ModuleNotInstalled.selector, MODULE_TYPE_VALIDATOR, address(uninstalledValidator)
            )
        );
        Kernel(payable(account)).uninstallModule(MODULE_TYPE_VALIDATOR, address(uninstalledValidator), hex"");
    }

    function test_UninstallModule_ExecutorNotInstalled_Reverts() public {
        address account = _createKernelAccount();

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(Kernel.ModuleNotInstalled.selector, MODULE_TYPE_EXECUTOR, address(mockExecutor))
        );
        Kernel(payable(account)).uninstallModule(MODULE_TYPE_EXECUTOR, address(mockExecutor), hex"");
    }

    function test_UninstallModule_FallbackNotInstalled_Reverts() public {
        address account = _createKernelAccount();
        bytes4 selector = bytes4(0x12345678);

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(Kernel.ModuleNotInstalled.selector, MODULE_TYPE_FALLBACK, address(mockFallback))
        );
        Kernel(payable(account))
            .uninstallModule(MODULE_TYPE_FALLBACK, address(mockFallback), abi.encodePacked(selector));
    }

    /* //////////////////////////////////////////////////////////////
                    uninstallModule — OnUninstallFailed
    //////////////////////////////////////////////////////////////*/

    function test_UninstallModule_OnUninstallFailed_Reverts() public {
        address account = _createKernelAccount();

        // Install executor whose onUninstall always reverts
        vm.prank(account);
        Kernel(payable(account)).installModule(MODULE_TYPE_EXECUTOR, address(revertingExecutor), _executorInitData());
        assertTrue(Kernel(payable(account)).isModuleInstalled(MODULE_TYPE_EXECUTOR, address(revertingExecutor), hex""));

        // Uninstall should revert with ModuleOnUninstallFailed
        // (Kernel propagates the onUninstall failure to the caller)
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                Kernel.ModuleOnUninstallFailed.selector, MODULE_TYPE_EXECUTOR, address(revertingExecutor)
            )
        );
        Kernel(payable(account)).uninstallModule(MODULE_TYPE_EXECUTOR, address(revertingExecutor), hex"");

        // Module remains installed because uninstall reverted
        assertTrue(Kernel(payable(account)).isModuleInstalled(MODULE_TYPE_EXECUTOR, address(revertingExecutor), hex""));
    }

    /* //////////////////////////////////////////////////////////////
                    Positive — Fresh install & lifecycle
    //////////////////////////////////////////////////////////////*/

    function test_InstallModule_FreshExecutor_Succeeds() public {
        address account = _createKernelAccount();

        vm.prank(account);
        Kernel(payable(account)).installModule(MODULE_TYPE_EXECUTOR, address(mockExecutor), _executorInitData());

        assertTrue(Kernel(payable(account)).isModuleInstalled(MODULE_TYPE_EXECUTOR, address(mockExecutor), hex""));
    }

    function test_InstallModule_FreshFallback_Succeeds() public {
        address account = _createKernelAccount();
        bytes4 selector = bytes4(0xaabbccdd);

        vm.prank(account);
        Kernel(payable(account)).installModule(MODULE_TYPE_FALLBACK, address(mockFallback), _fallbackInitData(selector));

        assertTrue(
            Kernel(payable(account))
                .isModuleInstalled(MODULE_TYPE_FALLBACK, address(mockFallback), abi.encodePacked(selector))
        );
    }

    function test_UninstallModule_InstalledExecutor_Succeeds() public {
        address account = _createKernelAccount();

        // Install
        vm.prank(account);
        Kernel(payable(account)).installModule(MODULE_TYPE_EXECUTOR, address(mockExecutor), _executorInitData());
        assertTrue(Kernel(payable(account)).isModuleInstalled(MODULE_TYPE_EXECUTOR, address(mockExecutor), hex""));

        // Uninstall
        vm.prank(account);
        Kernel(payable(account)).uninstallModule(MODULE_TYPE_EXECUTOR, address(mockExecutor), hex"");
        assertFalse(Kernel(payable(account)).isModuleInstalled(MODULE_TYPE_EXECUTOR, address(mockExecutor), hex""));
    }

    function test_UninstallModule_InstalledFallback_Succeeds() public {
        address account = _createKernelAccount();
        bytes4 selector = bytes4(0xaabbccdd);

        // Install
        vm.prank(account);
        Kernel(payable(account)).installModule(MODULE_TYPE_FALLBACK, address(mockFallback), _fallbackInitData(selector));

        // Uninstall
        vm.prank(account);
        Kernel(payable(account))
            .uninstallModule(MODULE_TYPE_FALLBACK, address(mockFallback), abi.encodePacked(selector));
        assertFalse(
            Kernel(payable(account))
                .isModuleInstalled(MODULE_TYPE_FALLBACK, address(mockFallback), abi.encodePacked(selector))
        );
    }

    function test_ReinstallAfterUninstall_Executor_Succeeds() public {
        address account = _createKernelAccount();
        bytes memory initData = _executorInitData();

        // Install → Uninstall → Re-install
        vm.prank(account);
        Kernel(payable(account)).installModule(MODULE_TYPE_EXECUTOR, address(mockExecutor), initData);

        vm.prank(account);
        Kernel(payable(account)).uninstallModule(MODULE_TYPE_EXECUTOR, address(mockExecutor), hex"");

        vm.prank(account);
        Kernel(payable(account)).installModule(MODULE_TYPE_EXECUTOR, address(mockExecutor), initData);

        assertTrue(Kernel(payable(account)).isModuleInstalled(MODULE_TYPE_EXECUTOR, address(mockExecutor), hex""));
    }

    function test_ReinstallAfterUninstall_Fallback_Succeeds() public {
        address account = _createKernelAccount();
        bytes4 selector = bytes4(0xaabbccdd);
        bytes memory initData = _fallbackInitData(selector);

        // Install → Uninstall → Re-install
        vm.prank(account);
        Kernel(payable(account)).installModule(MODULE_TYPE_FALLBACK, address(mockFallback), initData);

        vm.prank(account);
        Kernel(payable(account))
            .uninstallModule(MODULE_TYPE_FALLBACK, address(mockFallback), abi.encodePacked(selector));

        vm.prank(account);
        Kernel(payable(account)).installModule(MODULE_TYPE_FALLBACK, address(mockFallback), initData);

        assertTrue(
            Kernel(payable(account))
                .isModuleInstalled(MODULE_TYPE_FALLBACK, address(mockFallback), abi.encodePacked(selector))
        );
    }

    /* //////////////////////////////////////////////////////////////
                    executor context — no self-call escalation
    //////////////////////////////////////////////////////////////*/

    function test_ExecutorDirectSelfCall_Reverts() public {
        address account = _createKernelAccount();
        SelfCallingExecutor executor = _installSelfCallingExecutor(account);
        bytes memory escalate = _installExecutorCall(address(new MockGuardExecutor()));

        vm.expectRevert(Kernel.ExecutorCannotCallSelf.selector);
        executor.directSelfCall(account, escalate);
    }

    /// @dev Regression: the executor-context flag must survive a nested executeFromExecutor.
    ///      Before the fix the inner call reset the flag to 0 and the later self-call succeeded.
    function test_ExecutorNestedSelfCall_Reverts() public {
        address account = _createKernelAccount();
        SelfCallingExecutor executor = _installSelfCallingExecutor(account);
        MockGuardExecutor rogue = new MockGuardExecutor();

        vm.expectRevert(Kernel.ExecutorCannotCallSelf.selector);
        executor.nestedSelfCall(account, _installExecutorCall(address(rogue)));

        assertFalse(Kernel(payable(account)).isModuleInstalled(MODULE_TYPE_EXECUTOR, address(rogue), ""));
    }

    function test_KernelRuntimeFitsEip170() public view {
        assertLe(address(kernelImpl).code.length, 24_576);
    }

    function test_ForceUninstallIgnoresCallbackRevert() public {
        Kernel account = Kernel(payable(_createKernelAccount()));
        vm.startPrank(address(account));
        account.installModule(MODULE_TYPE_EXECUTOR, address(revertingExecutor), _executorInitData());
        account.forceUninstallModule(MODULE_TYPE_EXECUTOR, address(revertingExecutor), "");
        vm.stopPrank();
        assertFalse(account.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(revertingExecutor), ""));
    }

    function test_ReplaceExecutorIsAtomic() public {
        Kernel account = Kernel(payable(_createKernelAccount()));
        MockGuardExecutor replacement = new MockGuardExecutor();
        vm.startPrank(address(account));
        account.installModule(MODULE_TYPE_EXECUTOR, address(mockExecutor), _executorInitData());
        account.replaceModule(
            MODULE_TYPE_EXECUTOR, address(mockExecutor), "", address(replacement), _executorInitData()
        );
        vm.stopPrank();
        assertFalse(account.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(mockExecutor), ""));
        assertTrue(account.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(replacement), ""));
    }

    function test_ReplaceRejectingOldModuleKeepsOriginal() public {
        Kernel account = Kernel(payable(_createKernelAccount()));
        vm.startPrank(address(account));
        account.installModule(MODULE_TYPE_EXECUTOR, address(revertingExecutor), _executorInitData());
        vm.expectRevert(
            abi.encodeWithSelector(
                Kernel.ModuleOnUninstallFailed.selector, MODULE_TYPE_EXECUTOR, address(revertingExecutor)
            )
        );
        account.replaceModule(
            MODULE_TYPE_EXECUTOR, address(revertingExecutor), "", address(mockExecutor), _executorInitData()
        );
        vm.stopPrank();
        assertTrue(account.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(revertingExecutor), ""));
        assertFalse(account.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(mockExecutor), ""));
    }

    function test_ReplaceInvalidNewModuleRestoresOriginal() public {
        Kernel account = Kernel(payable(_createKernelAccount()));
        vm.startPrank(address(account));
        account.installModule(MODULE_TYPE_EXECUTOR, address(mockExecutor), _executorInitData());
        vm.expectRevert(Kernel.InvalidModuleType.selector);
        account.replaceModule(
            MODULE_TYPE_EXECUTOR, address(mockExecutor), "", address(mockFallback), _executorInitData()
        );
        vm.stopPrank();
        assertTrue(account.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(mockExecutor), ""));
    }

    /* //////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _createKernelAccount() internal returns (address) {
        ValidationId rootValidator = ValidatorLib.validatorToIdentifier(IValidator(address(ecdsaValidator)));
        bytes memory validatorData = abi.encodePacked(owner);
        bytes[] memory initConfig = new bytes[](0);

        bytes memory initData = abi.encodeCall(
            Kernel.initialize, (rootValidator, IHook(HOOK_MODULE_INSTALLED), validatorData, hex"", initConfig)
        );

        bytes32 salt = bytes32(uint256(uint160(owner)));

        // KernelFactory requires calls from EntryPoint's SenderCreator
        vm.prank(senderCreator);
        return kernelFactory.createAccount(initData, salt);
    }

    function _installSelfCallingExecutor(address account) internal returns (SelfCallingExecutor executor) {
        executor = new SelfCallingExecutor();
        vm.prank(account);
        Kernel(payable(account)).installModule(MODULE_TYPE_EXECUTOR, address(executor), _executorInitData());
    }

    function _installExecutorCall(address module) internal pure returns (bytes memory) {
        return abi.encodeCall(Kernel.installModule, (MODULE_TYPE_EXECUTOR, module, _executorInitData()));
    }

    /// @dev Validator initData: hook(20) + abi.encode(validatorData, hookData, selectorData)
    function _validatorInitData(address validatorOwner) internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes20(HOOK_MODULE_INSTALLED), abi.encode(abi.encodePacked(validatorOwner), bytes(""), bytes(""))
        );
    }

    /// @dev Executor initData: hook(20) + abi.encode(executorData, hookData)
    function _executorInitData() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes20(HOOK_MODULE_INSTALLED), abi.encode(bytes(""), bytes("")));
    }

    /// @dev Fallback initData: selector(4) + hook(20) + abi.encode(selectorData, hookData)
    ///      selectorData[0] = 0x00 (CALLTYPE_SINGLE)
    function _fallbackInitData(bytes4 selector) internal pure returns (bytes memory) {
        return abi.encodePacked(selector, bytes20(HOOK_MODULE_INSTALLED), abi.encode(hex"00", bytes("")));
    }
}
