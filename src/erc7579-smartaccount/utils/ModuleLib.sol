// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IModule } from "../interfaces/IERC7579Modules.sol";

library ModuleLib {
    event ModuleUninstallResult(address module, bool result);

    function uninstallModule(address module, bytes memory deinitData) internal returns (bool result) {
        bytes memory data = abi.encodeWithSelector(IModule.onUninstall.selector, deinitData);
        // Emergency removal ignores returndata, including a maliciously large revert payload.
        assembly ("memory-safe") {
            result := call(gas(), module, 0, add(data, 0x20), mload(data), 0, 0)
        }
        emit ModuleUninstallResult(module, result);
    }
}
