// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IHook } from "../interfaces/IERC7579Modules.sol";
import { ModuleLib } from "../utils/ModuleLib.sol";
import { IERC7579Account } from "../interfaces/IERC7579Account.sol";
import { MODULE_TYPE_HOOK } from "../types/Constants.sol";

abstract contract HookManager {
    // keccak256("kernel.hookGasLimit")
    bytes32 private constant _HOOK_GAS_LIMIT_SLOT = 0x70c2e706a3e44ddaec14078dc596cc85f5d44d6458f35f27f509afdd4a35b54b;

    struct HookGasLimitStorage {
        mapping(IHook => uint256) gasLimit;
    }

    event HookGasLimitSet(address indexed hook, uint256 gasLimit);

    function _hookGasLimitStorage() internal pure returns (HookGasLimitStorage storage s) {
        bytes32 slot = _HOOK_GAS_LIMIT_SLOT;
        assembly {
            s.slot := slot
        }
    }

    // Hook is activated on these scenarios
    // - on 4337 flow, userOp.calldata starts with executeUserOp.selector && validator requires hook
    // - executeFromExecutor() is invoked and executor requires hook
    // - when fallback function has been invoked and fallback requires hook => native functions will not invoke hook

    /// @dev Calls hook.preCheck with optional gas limit.
    ///      gasLimit == 0 means unlimited (default, backward compatible).
    function _doPreHook(IHook hook, uint256 value, bytes calldata callData) internal returns (bytes memory context) {
        uint256 limit = _hookGasLimitStorage().gasLimit[hook];
        if (limit == 0) {
            context = hook.preCheck(msg.sender, value, callData);
        } else {
            context = hook.preCheck{gas: limit}(msg.sender, value, callData);
        }
    }

    /// @dev Calls hook.postCheck with optional gas limit.
    function _doPostHook(IHook hook, bytes memory context) internal {
        uint256 limit = _hookGasLimitStorage().gasLimit[hook];
        if (limit == 0) {
            hook.postCheck(context);
        } else {
            hook.postCheck{gas: limit}(context);
        }
    }

    // @notice if hook is not initialized before, kernel will call hook.onInstall no matter what flag it shows, with
    // hookData[1:] @param hookData is encoded into (1bytes flag + actual hookdata) flag is for identifying if the hook
    // has to be initialized or not
    function _installHook(IHook hook, bytes calldata hookData) internal {
        if (address(hook) == address(0) || address(hook) == address(1)) {
            return;
        }
        if (!hook.isInitialized(address(this)) || (hookData.length > 0 && bytes1(hookData[0]) == bytes1(0xff))) {
            // if hook is not installed, it should call onInstall
            // 0xff means you want to explicitly call install hook
            hook.onInstall(hookData[1:]);
        }
        emit IERC7579Account.ModuleInstalled(MODULE_TYPE_HOOK, address(hook));
    }

    // @param hookData encoded as (1bytes flag + actual hookdata) flag is for identifying if the hook has to be
    // initialized or not
    function _uninstallHook(IHook hook, bytes calldata hookData) internal {
        if (address(hook) == address(0) || address(hook) == address(1)) {
            return;
        }
        if (bytes1(hookData[0]) == bytes1(0xff)) {
            // 0xff means you want to call uninstall hook
            ModuleLib.uninstallModule(address(hook), hookData[1:]);
        }
        emit IERC7579Account.ModuleUninstalled(MODULE_TYPE_HOOK, address(hook));
    }
}
