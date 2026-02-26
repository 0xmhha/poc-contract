// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { PackedUserOperation } from "../erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { IAccount, ValidationData } from "./interfaces/IAccount.sol";
import { IEntryPoint } from "../erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { IAccountExecute } from "./interfaces/IAccountExecute.sol";
import { IERC7579Account } from "./interfaces/IERC7579Account.sol";
import { ModuleLib } from "./utils/ModuleLib.sol";
import {
    ValidationManager,
    ValidationMode,
    ValidationId,
    ValidatorLib,
    ValidationType,
    PermissionId
} from "./core/ValidationManager.sol";
import { IValidator, IHook, IExecutor } from "./interfaces/IERC7579Modules.sol";
import { ExecLib } from "./utils/ExecLib.sol";
import { ExecMode, CallType, ExecType, ExecModeSelector, ExecModePayload } from "./types/Types.sol";
import {
    CALLTYPE_SINGLE,
    CALLTYPE_DELEGATECALL,
    ERC1967_IMPLEMENTATION_SLOT,
    VALIDATION_TYPE_ROOT,
    VALIDATION_TYPE_VALIDATOR,
    VALIDATION_TYPE_PERMISSION,
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_EXECUTOR,
    MODULE_TYPE_FALLBACK,
    MODULE_TYPE_HOOK,
    MODULE_TYPE_POLICY,
    MODULE_TYPE_SIGNER,
    HOOK_MODULE_NOT_INSTALLED,
    HOOK_MODULE_INSTALLED,
    HOOK_ONLY_ENTRYPOINT,
    EXECTYPE_TRY,
    EXECTYPE_DEFAULT,
    EXEC_MODE_DEFAULT,
    CALLTYPE_BATCH,
    EIP7702_PREFIX
} from "./types/Constants.sol";

import { InstallExecutorDataFormat, InstallFallbackDataFormat, InstallValidatorDataFormat } from "./types/Structs.sol";

contract Kernel is IAccount, IAccountExecute, IERC7579Account, ValidationManager {
    error ExecutionReverted();
    error InvalidExecutor();
    error InvalidFallback();
    error InvalidCallType();
    error OnlyExecuteUserOp();
    error InvalidModuleType();
    error InvalidCaller();
    error InvalidSelector();
    error InitConfigError(uint256 idx);
    error AlreadyInitialized();
    error ModuleAlreadyInstalled(uint256 moduleType, address module);
    error ModuleNotInstalled(uint256 moduleType, address module);
    error ModuleOnUninstallFailed(uint256 moduleType, address module);

    event Received(address sender, uint256 amount);
    event Upgraded(address indexed implementation);

    IEntryPoint public immutable ENTRYPOINT;

    // NOTE : when eip 1153 has been enabled, this can be transient storage
    mapping(bytes32 userOpHash => IHook) internal executionHook;

    constructor(IEntryPoint _entrypoint) {
        ENTRYPOINT = _entrypoint;
        _validationStorage().rootValidator = ValidationId.wrap(bytes21(abi.encodePacked(hex"deadbeef")));
    }

    modifier onlyEntryPoint() {
        _checkEntryPoint();
        _;
    }

    /// @dev Modifier with pre/post hook pattern. Cannot be refactored because:
    ///      1. Pre-hook returns hookRet that must be passed to post-hook
    ///      2. Function body (`_;`) must execute between pre and post hooks
    modifier onlyEntryPointOrSelfOrRoot() {
        bytes memory hookRet = _checkEntryPointOrSelfOrRoot();
        _;
        _postCheckHook(hookRet);
    }

    function _postCheckHook(bytes memory hookRet) internal {
        if (hookRet.length > 0) {
            IValidator validator = ValidatorLib.getValidator(_validationStorage().rootValidator);
            IHook(address(validator)).postCheck(hookRet);
        }
    }

    function _checkEntryPoint() internal view {
        if (msg.sender != address(ENTRYPOINT)) {
            revert InvalidCaller();
        }
    }

    function _checkEntryPointOrSelfOrRoot() internal returns (bytes memory) {
        if (msg.sender != address(ENTRYPOINT) && msg.sender != address(this)) {
            IValidator validator = ValidatorLib.getValidator(_validationStorage().rootValidator);
            if (validator.isModuleType(4)) {
                return IHook(address(validator)).preCheck(msg.sender, msg.value, msg.data);
            } else {
                revert InvalidCaller();
            }
        }
        return "";
    }

    function initialize(
        ValidationId _rootValidator,
        IHook hook,
        bytes calldata validatorData,
        bytes calldata hookData,
        bytes[] calldata initConfig
    ) external {
        ValidationStorage storage vs = _validationStorage();
        if (ValidationId.unwrap(vs.rootValidator) != bytes21(0) || bytes3(address(this).code) == EIP7702_PREFIX) {
            revert AlreadyInitialized();
        }
        if (ValidationId.unwrap(_rootValidator) == bytes21(0)) {
            revert InvalidValidator();
        }
        ValidationType vType = ValidatorLib.getType(_rootValidator);
        if (vType != VALIDATION_TYPE_VALIDATOR && vType != VALIDATION_TYPE_PERMISSION) {
            revert InvalidValidationType();
        }
        _setRootValidator(_rootValidator);
        ValidationConfig memory config = ValidationConfig({ nonce: uint32(1), hook: hook });
        vs.currentNonce = 1;
        _installValidation(_rootValidator, config, validatorData, hookData);
        for (uint256 i = 0; i < initConfig.length; i++) {
            (bool success,) = address(this).call(initConfig[i]);
            if (!success) {
                revert InitConfigError(i);
            }
        }
    }

    function changeRootValidator(
        ValidationId _rootValidator,
        IHook hook,
        bytes calldata validatorData,
        bytes calldata hookData
    ) external payable onlyEntryPointOrSelfOrRoot {
        ValidationStorage storage vs = _validationStorage();
        if (ValidationId.unwrap(_rootValidator) == bytes21(0)) {
            revert InvalidValidator();
        }
        ValidationType vType = ValidatorLib.getType(_rootValidator);
        if (vType != VALIDATION_TYPE_VALIDATOR && vType != VALIDATION_TYPE_PERMISSION) {
            revert InvalidValidationType();
        }
        _setRootValidator(_rootValidator);
        if (_validationStorage().validationConfig[_rootValidator].hook == IHook(HOOK_MODULE_NOT_INSTALLED)) {
            // when new rootValidator is not installed yet
            ValidationConfig memory config = ValidationConfig({ nonce: uint32(vs.currentNonce), hook: hook });
            _installValidation(_rootValidator, config, validatorData, hookData);
        }
    }

    function upgradeTo(address _newImplementation) external payable onlyEntryPointOrSelfOrRoot {
        assembly {
            sstore(ERC1967_IMPLEMENTATION_SLOT, _newImplementation)
        }
        emit Upgraded(_newImplementation);
    }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "Kernel";
        version = "0.3.3";
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    /// @notice Fallback handler that routes unrecognized selectors to installed fallback modules.
    ///
    /// [EIP-4337 / ERC-7579 Spec Conflict — Fallback Sender Context]
    ///   When the EntryPoint calls this account, msg.sender is the EntryPoint address, not the
    ///   original transaction sender. ERC-7579 fallback modules may use msg.sender for access
    ///   control, which would incorrectly reference the EntryPoint instead of the actual caller.
    ///   Resolution: For CALLTYPE_SINGLE fallbacks, we use ERC-2771 style sender appending
    ///   (doFallback2771Call) — the original msg.sender is appended to the calldata so the
    ///   fallback module can extract the true caller from the last 20 bytes. Fallback modules
    ///   must not use msg.sender directly for authorization; they should read the appended sender.
    ///   CALLTYPE_DELEGATECALL fallbacks run in the account's context where msg.sender is preserved.
    fallback() external payable {
        SelectorConfig memory config = _selectorConfig(msg.sig);
        bool success;
        bytes memory result;
        if (address(config.hook) == HOOK_MODULE_NOT_INSTALLED) {
            revert InvalidSelector();
        }
        // action installed
        bytes memory context;
        if (address(config.hook) == HOOK_ONLY_ENTRYPOINT) {
            // for selector manager, address(0) for the hook will default to type(address).max,
            // and this will only allow entrypoints to interact
            if (msg.sender != address(ENTRYPOINT)) {
                revert InvalidCaller();
            }
        } else if (address(config.hook) != HOOK_MODULE_INSTALLED) {
            context = _doPreHook(config.hook, msg.value, msg.data);
        }
        // execute action
        if (config.callType == CALLTYPE_SINGLE) {
            (success, result) = ExecLib.doFallback2771Call(config.target);
        } else if (config.callType == CALLTYPE_DELEGATECALL) {
            (success, result) = ExecLib.executeDelegatecall(config.target, msg.data);
        } else {
            revert NotSupportedCallType();
        }
        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        if (address(config.hook) != HOOK_MODULE_INSTALLED && address(config.hook) != HOOK_ONLY_ENTRYPOINT) {
            _doPostHook(config.hook, context);
        }
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }

    /// @notice Validates a UserOperation — EIP-4337 IAccount implementation with ERC-7579 validator routing.
    ///
    /// [EIP-4337 / ERC-7579 Spec Conflict — validationData Format]
    ///   EIP-4337 requires this function to return a packed uint256 validationData:
    ///     `authorizer(20bytes) | validUntil(6bytes) | validAfter(6bytes)`
    ///   On signature failure, it must return SIG_VALIDATION_FAILED(1) instead of reverting,
    ///   so that bundlers can accurately estimate gas.
    ///   ERC-7579 validator modules may return results in their own format, but when used
    ///   within an EIP-4337 context, they must comply with the above packing format.
    ///   Resolution: ValidationManager._validateUserOp delegates validation to the 7579 validator,
    ///   then merges the result into 4337-compliant validationData via _intersectValidationData.
    ///
    /// [EIP-4337 / ERC-7579 Spec Conflict — Nonce Layer Separation]
    ///   EIP-4337's EntryPoint manages per-account nonces using a 192-bit key + 64-bit sequence.
    ///   ERC-7579 modules (e.g., session keys, permissions) may maintain their own internal nonces.
    ///   Resolution: Kernel uses the first 2 bytes of userOp.nonce for validation mode and bytes[2:22]
    ///   for validator identity, piggybacking on 4337's nonce key space without conflicting with
    ///   its sequential nonce. Module-level nonces (e.g., paymaster senderNonce) are stored in
    ///   separate storage slots.
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        payable
        override
        onlyEntryPoint
        returns (ValidationData validationData)
    {
        ValidationStorage storage vs = _validationStorage();
        // ONLY ENTRYPOINT
        // Major change for v2 => v3
        // 1. instead of packing 4 bytes prefix to userOp.signature to determine the mode, v3 uses userOp.nonce's first
        // 2 bytes to check the mode 2. instead of packing 20 bytes in userOp.signature for enable mode to provide the
        // validator address, v3 uses userOp.nonce[2:22]
        // 3. In v2, only 1 plugin validator(aside from root validator) can access the selector.
        // In v3, you can use more than 1 plugin to use the exact selector, you need to specify the validator address in
        // userOp.nonce[2:22] to use the validator
        (ValidationMode vMode, ValidationType vType, ValidationId vId) = ValidatorLib.decodeNonce(userOp.nonce);
        if (vType == VALIDATION_TYPE_ROOT) {
            vId = vs.rootValidator;
        }
        validationData = _validateUserOp(vMode, vId, userOp, userOpHash);
        ValidationConfig memory vc = vs.validationConfig[vId];
        // allow when nonce is not revoked or vType is sudo
        if (vType != VALIDATION_TYPE_ROOT && vc.nonce < vs.validNonceFrom) {
            revert InvalidNonce();
        }
        IHook execHook = vc.hook;
        if (address(execHook) == HOOK_MODULE_NOT_INSTALLED && vType != VALIDATION_TYPE_ROOT) {
            revert InvalidValidator();
        }
        executionHook[userOpHash] = execHook;

        if (address(execHook) == HOOK_MODULE_INSTALLED || address(execHook) == HOOK_MODULE_NOT_INSTALLED) {
            // does not require hook
            if (vType != VALIDATION_TYPE_ROOT && !vs.allowedSelectors[vId][bytes4(userOp.callData[0:4])]) {
                revert InvalidValidator();
            }
        } else {
            // requires hook
            if (vType != VALIDATION_TYPE_ROOT && !vs.allowedSelectors[vId][bytes4(userOp.callData[4:8])]) {
                revert InvalidValidator();
            }
            if (bytes4(userOp.callData[0:4]) != this.executeUserOp.selector) {
                revert OnlyExecuteUserOp();
            }
        }

        assembly {
            if missingAccountFunds {
                pop(call(gas(), caller(), missingAccountFunds, callvalue(), callvalue(), callvalue(), callvalue()))
                // ignore failure (its EntryPoint's job to verify, not account.)
            }
        }
    }

    function isValidSignature(bytes32 hash, bytes calldata data) external view returns (bytes4) {
        return _verifySignature(hash, data);
    }

    /// @notice Executes a UserOperation's inner callData with pre/post hook support.
    ///
    /// [EIP-4337 / ERC-7579 Spec Conflict — executeUserOp Bridge]
    ///   EIP-4337 defines `executeUserOp(PackedUserOperation, bytes32)` as an optional extension
    ///   (IAccountExecute) that allows the account to receive the full UserOp during execution.
    ///   It must only be called by the EntryPoint.
    ///   ERC-7579 defines `execute(ExecMode, bytes)` as the primary execution interface. The 7579
    ///   spec does not define `executeUserOp` — it is a 4337-specific extension.
    ///   Resolution: This function acts as a bridge. It enforces onlyEntryPoint access, runs
    ///   ERC-7579 pre/post hooks, then delegatecalls to self with the inner callData (stripping
    ///   the 4-byte selector). This routes the inner call through 7579's `execute(ExecMode, bytes)`.
    ///   Validators that require hooks must use this path (enforced by OnlyExecuteUserOp check
    ///   in validateUserOp).
    ///
    /// [EIP-4337 / ERC-7579 Spec Conflict — Hook Determinism and Paymaster Impact]
    ///   EIP-4337 bundlers simulate the full execution including hooks. Non-deterministic hook
    ///   behavior causes simulation-vs-onchain divergence, leading to bundler rejection.
    ///   ERC-7579 hooks (preCheck/postCheck) may perform arbitrary logic, but hooks that depend
    ///   on volatile external state or consume excessive gas undermine bundler compatibility.
    ///   Resolution: Hooks are invoked here in pre/post pattern. If postCheck reverts, the entire
    ///   execution reverts, triggering Paymaster's postOp(opReverted) path. Hook implementations
    ///   should avoid non-deterministic external calls and stay within reasonable gas bounds.
    function executeUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        payable
        override
        onlyEntryPoint
    {
        bytes memory context;
        IHook hook = executionHook[userOpHash];
        bool callHook = address(hook) != HOOK_MODULE_INSTALLED;
        if (callHook) {
            // removed 4bytes selector
            context = _doPreHook(hook, msg.value, userOp.callData[4:]);
        }
        (bool success,) = ExecLib.executeDelegatecall(address(this), userOp.callData[4:]);
        if (!success) {
            revert ExecutionReverted();
        }
        if (callHook) {
            _doPostHook(hook, context);
        }
    }

    function executeFromExecutor(ExecMode execMode, bytes calldata executionCalldata)
        external
        payable
        returns (bytes[] memory returnData)
    {
        // no modifier needed, checking if msg.sender is registered executor will replace the modifier
        IHook hook = _executorConfig(IExecutor(msg.sender)).hook;
        if (address(hook) == HOOK_MODULE_NOT_INSTALLED) {
            revert InvalidExecutor();
        }
        bytes memory context;
        bool callHook = address(hook) != HOOK_MODULE_INSTALLED;
        if (callHook) {
            context = _doPreHook(hook, msg.value, msg.data);
        }
        returnData = ExecLib.execute(execMode, executionCalldata);
        if (callHook) {
            _doPostHook(hook, context);
        }
    }

    function execute(ExecMode execMode, bytes calldata executionCalldata) external payable onlyEntryPointOrSelfOrRoot {
        ValidationStorage storage vs = _validationStorage();
        IHook hook = vs.validationConfig[vs.rootValidator].hook;
        bytes memory context;
        bool callHook = address(hook) != HOOK_MODULE_INSTALLED && address(hook) != HOOK_MODULE_NOT_INSTALLED;
        if (callHook) {
            context = _doPreHook(hook, msg.value, msg.data);
        }
        ExecLib.execute(execMode, executionCalldata);
        if (callHook) {
            _doPostHook(hook, context);
        }
    }

    function installModule(uint256 moduleType, address module, bytes calldata initData)
        external
        payable
        override
        onlyEntryPointOrSelfOrRoot
    {
        if (moduleType == MODULE_TYPE_VALIDATOR) {
            ValidationStorage storage vs = _validationStorage();
            ValidationId vId = ValidatorLib.validatorToIdentifier(IValidator(module));
            if (vs.validationConfig[vId].hook != IHook(HOOK_MODULE_NOT_INSTALLED)) {
                revert ModuleAlreadyInstalled(moduleType, module);
            }
            if (vs.validationConfig[vId].nonce == vs.currentNonce) {
                // only increase currentNonce when vId's currentNonce is same
                unchecked {
                    vs.currentNonce++;
                }
            }
            ValidationConfig memory config =
                ValidationConfig({ nonce: vs.currentNonce, hook: IHook(address(bytes20(initData[0:20]))) });
            InstallValidatorDataFormat calldata data;
            assembly {
                data := add(initData.offset, 20)
            }
            _installValidation(vId, config, data.validatorData, data.hookData);
            if (data.selectorData.length == 4) {
                // NOTE: we don't allow configure on selector data on v3.1+, but using bytes instead of bytes4 for
                // selector data to make sure we are future proof
                _grantAccess(vId, bytes4(data.selectorData[0:4]), true);
            }
        } else if (moduleType == MODULE_TYPE_EXECUTOR) {
            if (address(_executorConfig(IExecutor(module)).hook) != HOOK_MODULE_NOT_INSTALLED) {
                revert ModuleAlreadyInstalled(moduleType, module);
            }
            InstallExecutorDataFormat calldata data;
            assembly {
                data := add(initData.offset, 20)
            }
            IHook hook = IHook(address(bytes20(initData[0:20])));
            _installExecutor(IExecutor(module), data.executorData, hook);
            _installHook(hook, data.hookData);
        } else if (moduleType == MODULE_TYPE_FALLBACK) {
            if (_selectorConfig(bytes4(initData[0:4])).target != address(0)) {
                revert ModuleAlreadyInstalled(moduleType, module);
            }
            InstallFallbackDataFormat calldata data;
            assembly {
                data := add(initData.offset, 24)
            }
            _installSelector(bytes4(initData[0:4]), module, IHook(address(bytes20(initData[4:24]))), data.selectorData);
            _installHook(IHook(address(bytes20(initData[4:24]))), data.hookData);
        } else if (
            moduleType == MODULE_TYPE_HOOK || moduleType == MODULE_TYPE_POLICY || moduleType == MODULE_TYPE_SIGNER
        ) {
            // force call onInstall for hook, policy, signer
            // NOTE: for hook, kernel does not support independent hook install,
            // NOTE: for policy, kernel does not support independent policy install,
            // NOTE: for signer, kernel does not support independent signer install,
            // hook is expected to be paired with proper validator/executor/selector
            // policy is expected to be paired with proper permissionId
            // to "ADD" permission, use "installValidations()" function
            IHook(module).onInstall(initData);
        } else {
            revert InvalidModuleType();
        }
        emit ModuleInstalled(moduleType, module);
    }

    function grantAccess(ValidationId vId, bytes4 selector, bool allow) external payable onlyEntryPointOrSelfOrRoot {
        _grantAccess(vId, selector, allow);
    }

    function installValidations(
        ValidationId[] calldata vIds,
        ValidationConfig[] memory configs,
        bytes[] calldata validationData,
        bytes[] calldata hookData
    ) external payable onlyEntryPointOrSelfOrRoot {
        _installValidations(vIds, configs, validationData, hookData);
    }

    function uninstallValidation(ValidationId vId, bytes calldata deinitData, bytes calldata hookDeinitData)
        external
        payable
        onlyEntryPointOrSelfOrRoot
    {
        IHook hook = _clearValidationData(vId);
        ValidationType vType = ValidatorLib.getType(vId);
        if (vType == VALIDATION_TYPE_VALIDATOR) {
            IValidator validator = ValidatorLib.getValidator(vId);
            ModuleLib.uninstallModule(address(validator), deinitData);
            emit IERC7579Account.ModuleUninstalled(MODULE_TYPE_VALIDATOR, address(validator));
        } else if (vType == VALIDATION_TYPE_PERMISSION) {
            PermissionId permission = ValidatorLib.getPermissionId(vId);
            _uninstallPermission(permission, deinitData);
        } else {
            revert InvalidValidationType();
        }
        _uninstallHook(hook, hookDeinitData);
    }

    function invalidateNonce(uint32 nonce) external payable onlyEntryPointOrSelfOrRoot {
        _invalidateNonce(nonce);
    }

    function uninstallModule(uint256 moduleType, address module, bytes calldata deInitData)
        external
        payable
        override
        onlyEntryPointOrSelfOrRoot
    {
        if (moduleType == MODULE_TYPE_VALIDATOR) {
            ValidationId vId = ValidatorLib.validatorToIdentifier(IValidator(module));
            if (_validationStorage().validationConfig[vId].hook == IHook(HOOK_MODULE_NOT_INSTALLED)) {
                revert ModuleNotInstalled(moduleType, module);
            }
            _clearValidationData(vId);
        } else if (moduleType == MODULE_TYPE_EXECUTOR) {
            if (address(_executorConfig(IExecutor(module)).hook) == HOOK_MODULE_NOT_INSTALLED) {
                revert ModuleNotInstalled(moduleType, module);
            }
            _clearExecutorData(IExecutor(module));
        } else if (moduleType == MODULE_TYPE_FALLBACK) {
            bytes4 selector = bytes4(deInitData[0:4]);
            (, address target) = _clearSelectorData(selector);
            if (target == address(0)) {
                revert ModuleNotInstalled(moduleType, module);
            }
            if (target != module) {
                revert InvalidSelector();
            }
            deInitData = deInitData[4:];
        } else if (moduleType == MODULE_TYPE_HOOK) {
            ValidationId vId = _validationStorage().rootValidator;
            if (_validationStorage().validationConfig[vId].hook == IHook(module)) {
                // when root validator hook is being removed
                // remove hook on root validator to prevent kernel from being locked
                _validationStorage().validationConfig[vId].hook = IHook(HOOK_MODULE_INSTALLED);
            }
            // force call onUninstall for hook
            // NOTE: for hook, kernel does not support independent hook install,
            // hook is expected to be paired with proper validator/executor/selector
        } else if (moduleType == MODULE_TYPE_POLICY || moduleType == MODULE_TYPE_SIGNER) {
            ValidationId rootValidator = _validationStorage().rootValidator;
            bytes32 permissionId = bytes32(deInitData[0:32]);
            if (ValidatorLib.getType(rootValidator) == VALIDATION_TYPE_PERMISSION) {
                if (permissionId == bytes32(PermissionId.unwrap(ValidatorLib.getPermissionId(rootValidator)))) {
                    revert RootValidatorCannotBeRemoved();
                }
            }
            // force call onUninstall for policy
            // NOTE: for policy, kernel does not support independent policy install,
            // policy is expected to be paired with proper permissionId
            // to "REMOVE" permission, use "uninstallValidation()" function
            // NOTE: for signer, kernel does not support independent signer install,
            // signer is expected to be paired with proper permissionId
            // to "REMOVE" permission, use "uninstallValidation()" function
        } else {
            revert InvalidModuleType();
        }
        bool success = ModuleLib.uninstallModule(module, deInitData);
        if (!success) {
            revert ModuleOnUninstallFailed(moduleType, module);
        }
        emit ModuleUninstalled(moduleType, module);
    }

    function supportsModule(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId > 0 && moduleTypeId < 7;
    }

    /// @notice Check if a module is installed.
    ///
    /// [EIP-4337 / ERC-7579 Spec Conflict — Hook Module Observability]
    ///   ERC-7579 requires `isModuleInstalled` to return accurate installation status for all
    ///   supported module types, including hooks (type 4).
    ///   Bundlers and SDKs rely on this function to determine account capabilities before
    ///   constructing UserOps. If an installed hook returns false here, SDK state will be
    ///   inconsistent with the actual on-chain state.
    ///   Resolution: Kernel does not install hooks independently — hooks are always paired with a
    ///   validator, executor, or fallback selector. For MODULE_TYPE_HOOK queries, we check whether
    ///   the module is registered as the hook on the rootValidator's config by default. To query
    ///   a hook on a specific validator, pass the ValidationId via additionalContext (21 bytes).
    function isModuleInstalled(uint256 moduleType, address module, bytes calldata additionalContext)
        external
        view
        override
        returns (bool)
    {
        if (moduleType == MODULE_TYPE_VALIDATOR) {
            return _validationStorage().validationConfig[ValidatorLib.validatorToIdentifier(IValidator(module))].hook
                != IHook(HOOK_MODULE_NOT_INSTALLED);
        } else if (moduleType == MODULE_TYPE_EXECUTOR) {
            return address(_executorConfig(IExecutor(module)).hook) != HOOK_MODULE_NOT_INSTALLED;
        } else if (moduleType == MODULE_TYPE_FALLBACK) {
            return _selectorConfig(bytes4(additionalContext[0:4])).target == module;
        } else if (moduleType == MODULE_TYPE_HOOK) {
            // Hooks are paired with validators/executors/selectors, not independently tracked.
            // Check rootValidator's hook as the primary query path.
            // For specific validator hooks, pass ValidationId via additionalContext.
            if (additionalContext.length >= 21) {
                // additionalContext contains a ValidationId — check that specific validator's hook
                ValidationId vId = ValidationId.wrap(bytes21(additionalContext[0:21]));
                return address(_validationStorage().validationConfig[vId].hook) == module;
            }
            // Default: check rootValidator's hook
            ValidationId rootVId = _validationStorage().rootValidator;
            return address(_validationStorage().validationConfig[rootVId].hook) == module;
        } else {
            return false;
        }
    }

    function accountId() external pure override returns (string memory accountImplementationId) {
        return "kernel.advanced.v0.3.3";
    }

    /// @notice Reports supported execution modes.
    ///
    /// [EIP-4337 / ERC-7579 Spec Conflict — Execution Mode Consistency]
    ///   EIP-4337 requires that userOp.callData maps 1:1 to the account's execution function ABI.
    ///   The bundler simulates the full execution; any mismatch causes simulation-vs-onchain divergence.
    ///   ERC-7579 defines callType values: SINGLE(0x00), BATCH(0x01), STATIC(0xFE), DELEGATECALL(0xFF).
    ///   This function must report only modes that the account actually implements in ExecLib.execute().
    ///   Resolution: CALLTYPE_STATIC (0xFE) is excluded because ExecLib.execute() has no staticcall
    ///   branch. Reporting it as supported would cause clients/SDKs to submit STATIC-mode UserOps
    ///   that revert at runtime, breaking EIP-4337's simulation-execution equivalence guarantee.
    ///   To add STATIC mode support, a staticcall branch must be added to ExecLib.execute() first.
    function supportsExecutionMode(ExecMode mode) external pure override returns (bool) {
        (CallType callType, ExecType execType, ExecModeSelector selector, ExecModePayload payload) =
            ExecLib.decode(mode);
        if (callType != CALLTYPE_BATCH && callType != CALLTYPE_SINGLE && callType != CALLTYPE_DELEGATECALL) {
            return false;
        }

        if (
            ExecType.unwrap(execType) != ExecType.unwrap(EXECTYPE_TRY)
                && ExecType.unwrap(execType) != ExecType.unwrap(EXECTYPE_DEFAULT)
        ) {
            return false;
        }

        if (ExecModeSelector.unwrap(selector) != ExecModeSelector.unwrap(EXEC_MODE_DEFAULT)) {
            return false;
        }

        if (ExecModePayload.unwrap(payload) != bytes22(0)) {
            return false;
        }
        return true;
    }
}
