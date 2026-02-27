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

    function setUp() public {
        (owner, ownerKey) = makeAddrAndKey("owner");

        entryPoint = new EntryPoint();
        kernelImpl = new Kernel(IEntryPoint(address(entryPoint)));
        kernelFactory = new KernelFactory(address(kernelImpl));
        ecdsaValidator = new ECDSAValidator();
        mockExecutor = new MockGuardExecutor();
        mockFallback = new MockGuardFallback();
        revertingExecutor = new RevertingUninstallExecutor();
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

    function test_UninstallModule_OnUninstallFailed_StillRemovesModule() public {
        address account = _createKernelAccount();

        // Install executor whose onUninstall always reverts
        vm.prank(account);
        Kernel(payable(account)).installModule(MODULE_TYPE_EXECUTOR, address(revertingExecutor), _executorInitData());
        assertTrue(Kernel(payable(account)).isModuleInstalled(MODULE_TYPE_EXECUTOR, address(revertingExecutor), hex""));

        // Uninstall should succeed even when onUninstall reverts
        // (ExcessivelySafeCall catches the revert, module is removed regardless)
        vm.prank(account);
        Kernel(payable(account)).uninstallModule(MODULE_TYPE_EXECUTOR, address(revertingExecutor), hex"");

        // Module must be removed
        assertFalse(Kernel(payable(account)).isModuleInstalled(MODULE_TYPE_EXECUTOR, address(revertingExecutor), hex""));
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
        return kernelFactory.createAccount(initData, salt);
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
