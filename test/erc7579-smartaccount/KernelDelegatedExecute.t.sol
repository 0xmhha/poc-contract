// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { RootHookBase } from "./KernelRootHook.t.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { ECDSAValidator } from "../../src/erc7579-validators/ECDSAValidator.sol";
import { IValidator, IHook } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { ValidationId } from "../../src/erc7579-smartaccount/types/Types.sol";
import { HOOK_MODULE_INSTALLED } from "../../src/erc7579-smartaccount/types/Constants.sol";
import { ValidatorLib } from "../../src/erc7579-smartaccount/utils/ValidationTypeLib.sol";
import { SpendingLimitHook } from "../../src/erc7579-hooks/SpendingLimitHook.sol";

/// @notice Documents what granting `execute` to a non-root validator allows (see docs/FEATURES.md)
/// @dev execute may target the account itself and self-calls pass onlyEntryPointOrSelfOrRoot, so a
///      delegated validator without a hook can replace the root validator. A hook that rejects
///      self-targeted executions closes that path.
contract KernelDelegatedExecuteTest is RootHookBase {
    function setUp() public {
        _baseSetUp();
    }

    /// @dev execute(account, changeRootValidator(delegated)): the delegated validator makes itself root
    function _takeOverOp(address account, ECDSAValidator delegated) internal pure returns (bytes memory) {
        ValidationId vId = ValidatorLib.validatorToIdentifier(IValidator(address(delegated)));
        bytes memory change =
            abi.encodeCall(Kernel.changeRootValidator, (vId, IHook(HOOK_MODULE_INSTALLED), hex"", hex""));
        return _executeSingle(account, 0, change);
    }

    function test_DelegatedExecuteWithoutHook_CanReplaceRootValidator() public {
        address account = _createAccount(IHook(HOOK_MODULE_INSTALLED), hex"", 1);
        ECDSAValidator delegated = _installDelegateValidator(account, IHook(HOOK_MODULE_INSTALLED), hex"");

        // Without a hook the UserOp calls execute directly
        assertTrue(_sendOpWithCallData(account, address(delegated), _takeOverOp(account, delegated)));
        assertEq(
            ValidationId.unwrap(Kernel(payable(account)).rootValidator()),
            ValidationId.unwrap(ValidatorLib.validatorToIdentifier(IValidator(address(delegated))))
        );
    }

    function test_DelegatedExecuteWithSelfRejectingHook_CannotReplaceRootValidator() public {
        address account = _createAccount(IHook(HOOK_MODULE_INSTALLED), hex"", 2);
        SpendingLimitHook hook = new SpendingLimitHook();
        ECDSAValidator delegated = _installDelegateValidator(account, IHook(address(hook)), hex"00"); // flag byte, no
        // config
        ValidationId rootBefore = Kernel(payable(account)).rootValidator();

        // Control: the same validator and hook can still run an ordinary execution
        vm.deal(account, 1 ether);
        assertTrue(_sendOp(account, address(delegated), _executeSingle(beneficiary, 0.1 ether, "")));

        assertFalse(_sendOp(account, address(delegated), _takeOverOp(account, delegated)));
        assertEq(ValidationId.unwrap(Kernel(payable(account)).rootValidator()), ValidationId.unwrap(rootBefore));
    }
}
