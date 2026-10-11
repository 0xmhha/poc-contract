// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { KernelFactory } from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";
import { ECDSAValidator } from "../../src/erc7579-validators/ECDSAValidator.sol";
import { IValidator, IHook } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { ValidationId, ExecMode, ExecModePayload } from "../../src/erc7579-smartaccount/types/Types.sol";
import {
    MODULE_TYPE_EXECUTOR,
    MODULE_TYPE_FALLBACK,
    HOOK_MODULE_INSTALLED,
    CALLTYPE_SINGLE,
    EXECTYPE_DEFAULT,
    EXEC_MODE_DEFAULT
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import { ValidatorLib } from "../../src/erc7579-smartaccount/utils/ValidationTypeLib.sol";
import { ExecLib } from "../../src/erc7579-smartaccount/utils/ExecLib.sol";

/// @notice Deploys a real Kernel account (ECDSA root validator) so module tests run
///         against Kernel's actual execution encoding and fallback routing instead of mocks.
abstract contract KernelModuleTestBase is Test {
    EntryPoint internal entryPoint;
    Kernel internal kernelImpl;
    KernelFactory internal kernelFactory;
    ECDSAValidator internal rootValidator;

    address internal owner;

    function _deployKernel() internal {
        owner = makeAddr("kernelOwner");
        entryPoint = new EntryPoint();
        kernelImpl = new Kernel(IEntryPoint(address(entryPoint)));
        kernelFactory = new KernelFactory(address(kernelImpl), IEntryPoint(address(entryPoint)));
        rootValidator = new ECDSAValidator();
    }

    /// @dev Creates an account whose root validator is ECDSA(owner); the owner can call admin functions directly
    function _createAccount(uint256 salt) internal returns (address account) {
        ValidationId vId = ValidatorLib.validatorToIdentifier(IValidator(address(rootValidator)));
        bytes memory initData = abi.encodeCall(
            Kernel.initialize, (vId, IHook(HOOK_MODULE_INSTALLED), abi.encodePacked(owner), hex"", new bytes[](0))
        );
        vm.prank(address(entryPoint.senderCreator()));
        account = kernelFactory.createAccount(initData, bytes32(salt));
    }

    function _installExecutor(address account, address module, bytes memory executorData) internal {
        vm.prank(owner);
        Kernel(payable(account))
            .installModule(
                MODULE_TYPE_EXECUTOR,
                module,
                abi.encodePacked(bytes20(HOOK_MODULE_INSTALLED), abi.encode(executorData, bytes("")))
            );
    }

    /// @dev Installs `module` as a CALL-type fallback handler for `selector`
    function _installFallback(address account, address module, bytes4 selector, bytes memory moduleData) internal {
        vm.prank(owner);
        Kernel(payable(account))
            .installModule(
                MODULE_TYPE_FALLBACK,
                module,
                abi.encodePacked(
                    selector,
                    bytes20(HOOK_MODULE_INSTALLED),
                    abi.encode(abi.encodePacked(CALLTYPE_SINGLE, moduleData), bytes(""))
                )
            );
    }

    /// @dev Has the account call `target` with `data` (single execution, signed off by the root owner)
    function _execAsAccount(address account, address target, bytes memory data) internal {
        vm.prank(owner);
        Kernel(payable(account)).execute(_singleMode(), ExecLib.encodeSingle(target, 0, data));
    }

    function _singleMode() internal pure returns (ExecMode) {
        return ExecLib.encode(CALLTYPE_SINGLE, EXECTYPE_DEFAULT, EXEC_MODE_DEFAULT, ExecModePayload.wrap(bytes22(0)));
    }
}
