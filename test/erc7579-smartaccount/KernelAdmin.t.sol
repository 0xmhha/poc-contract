// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { KernelFactory } from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";
import { ECDSAValidator } from "../../src/erc7579-validators/ECDSAValidator.sol";
import { IValidator, IHook } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { ValidationId, ExecMode, ExecModePayload, CallType } from "../../src/erc7579-smartaccount/types/Types.sol";
import {
    MODULE_TYPE_EXECUTOR,
    HOOK_MODULE_INSTALLED,
    ERC1967_IMPLEMENTATION_SLOT,
    VALIDATION_MANAGER_STORAGE_SLOT,
    CALLTYPE_SINGLE,
    CALLTYPE_DELEGATECALL,
    EXECTYPE_DEFAULT,
    EXEC_MODE_DEFAULT
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import { ValidationManager } from "../../src/erc7579-smartaccount/core/ValidationManager.sol";
import { ValidatorLib } from "../../src/erc7579-smartaccount/utils/ValidationTypeLib.sol";
import { ExecLib } from "../../src/erc7579-smartaccount/utils/ExecLib.sol";

/// @notice Hook whose preCheck burns a fixed amount of gas, used to exercise setHookGasLimit
contract GasBurningHook {
    uint256 public constant BURN_ITERATIONS = 2000;
    uint256 internal _sink;

    function onInstall(bytes calldata) external payable { }
    function onUninstall(bytes calldata) external payable { }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 4;
    }

    /// @dev Reports initialized so Kernel skips onInstall and does not slice empty hookData
    function isInitialized(address) external pure returns (bool) {
        return true;
    }

    function preCheck(address, uint256, bytes calldata) external payable returns (bytes memory) {
        uint256 acc;
        for (uint256 i = 0; i < BURN_ITERATIONS; i++) {
            acc = uint256(keccak256(abi.encode(acc, i)));
        }
        _sink = acc;
        return "";
    }

    function postCheck(bytes calldata) external payable { }
}

/// @notice Executor that issues a single call or a delegatecall through executeFromExecutor
contract AdminTestExecutor {
    function onInstall(bytes calldata) external payable { }
    function onUninstall(bytes calldata) external payable { }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 2;
    }

    function callThrough(address account, address target) external {
        Kernel(payable(account)).executeFromExecutor(_mode(CALLTYPE_SINGLE), ExecLib.encodeSingle(target, 0, ""));
    }

    function delegatecallThrough(address account, address target, bytes calldata data) external {
        Kernel(payable(account)).executeFromExecutor(_mode(CALLTYPE_DELEGATECALL), abi.encodePacked(target, data));
    }

    function _mode(CallType callType) internal pure returns (ExecMode) {
        return ExecLib.encode(callType, EXECTYPE_DEFAULT, EXEC_MODE_DEFAULT, ExecModePayload.wrap(bytes22(0)));
    }
}

/// @notice Delegatecall target that writes a marker into the caller's storage
contract DelegateMarker {
    bytes32 public constant MARKER_SLOT = keccak256("kernel.admin.test.marker");

    function mark() external {
        bytes32 slot = MARKER_SLOT;
        assembly ("memory-safe") {
            sstore(slot, 1)
        }
    }
}

/// @notice Delegatecall target that overwrites the root validator slot of ValidationManager
contract RootValidatorOverwriter {
    function overwrite(address newValidator) external {
        bytes32 slot = VALIDATION_MANAGER_STORAGE_SLOT;
        bytes21 vId = bytes21(abi.encodePacked(bytes1(0x01), newValidator));
        assembly ("memory-safe") {
            sstore(slot, shr(88, vId))
        }
    }
}

/// @title Kernel admin function tests
/// @notice Covers access control and state effects of the onlyEntryPointOrSelfOrRoot admin
///         functions: upgradeTo, changeRootValidator, grantAccess, setHookGasLimit and the
///         delegatecall whitelist.
contract KernelAdminTest is Test {
    EntryPoint public entryPoint;
    Kernel public kernelImpl;
    KernelFactory public kernelFactory;
    ECDSAValidator public ecdsaValidator;
    DelegateMarker public marker;

    address public owner;
    address public stranger;
    address public senderCreator;
    Kernel public account;

    string internal constant NOT_OWNER = "ECDSAValidator: sender is not owner";

    function setUp() public {
        owner = makeAddr("owner");
        stranger = makeAddr("stranger");

        entryPoint = new EntryPoint();
        kernelImpl = new Kernel(IEntryPoint(address(entryPoint)));
        kernelFactory = new KernelFactory(address(kernelImpl), IEntryPoint(address(entryPoint)), address(0));
        ecdsaValidator = new ECDSAValidator();
        marker = new DelegateMarker();
        senderCreator = address(entryPoint.senderCreator());

        account = Kernel(payable(_createAccount(ecdsaValidator, owner)));
    }

    /* //////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @dev Every admin function must reject a caller that is not the EntryPoint, the account
    ///      itself or the root validator's owner.
    function test_AdminFunctions_RejectStranger() public {
        bytes[] memory calls = _adminCalls();
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(stranger);
            (bool success, bytes memory ret) = address(account).call(calls[i]);
            assertFalse(success, "stranger call succeeded");
            assertEq(ret, abi.encodeWithSignature("Error(string)", NOT_OWNER), "unexpected revert reason");
        }
    }

    function test_AdminFunctions_AllowEntryPoint() public {
        bytes[] memory calls = _adminCalls();
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(address(entryPoint));
            (bool success,) = address(account).call(calls[i]);
            assertTrue(success, "EntryPoint call failed");
        }
    }

    /// @dev The ECDSA root validator doubles as a hook, so its owner may call admin functions directly.
    function test_AdminFunctions_AllowRootOwner() public {
        bytes[] memory calls = _adminCalls();
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(owner);
            (bool success,) = address(account).call(calls[i]);
            assertTrue(success, "root owner call failed");
        }
    }

    /* //////////////////////////////////////////////////////////////
                                upgradeTo
    //////////////////////////////////////////////////////////////*/

    function test_UpgradeTo_UpdatesImplementationSlot() public {
        Kernel newImpl = new Kernel(IEntryPoint(address(entryPoint)));

        vm.expectEmit(true, false, false, false, address(account));
        emit Kernel.Upgraded(address(newImpl));
        vm.prank(address(entryPoint));
        account.upgradeTo(address(newImpl));

        assertEq(_implementation(address(account)), address(newImpl));
    }

    function test_UpgradeTo_RejectsImplementationWithoutCode() public {
        address before = _implementation(address(account));
        address[2] memory targets = [address(0), makeAddr("eoa")];

        for (uint256 i = 0; i < targets.length; i++) {
            vm.prank(address(entryPoint));
            // Kernel reverts without data here; it has no bytecode headroom for a custom error
            vm.expectRevert(bytes(""));
            account.upgradeTo(targets[i]);
        }

        assertEq(_implementation(address(account)), before);
    }

    function test_UpgradeTo_StrangerCannotChangeImplementation() public {
        address before = _implementation(address(account));

        vm.prank(stranger);
        vm.expectRevert(bytes(NOT_OWNER));
        account.upgradeTo(address(0xBEEF));

        assertEq(_implementation(address(account)), before);
    }

    /* //////////////////////////////////////////////////////////////
                            changeRootValidator
    //////////////////////////////////////////////////////////////*/

    function test_ChangeRootValidator_TransfersOwnership() public {
        address newOwner = makeAddr("newOwner");
        ECDSAValidator newValidator = new ECDSAValidator();
        ValidationId newVId = _vId(newValidator);

        vm.prank(address(entryPoint));
        account.changeRootValidator(newVId, IHook(HOOK_MODULE_INSTALLED), abi.encodePacked(newOwner), "");

        assertEq(ValidationId.unwrap(account.rootValidator()), ValidationId.unwrap(newVId));

        // Old owner loses direct admin access
        vm.prank(owner);
        vm.expectRevert(bytes(NOT_OWNER));
        account.setHookGasLimit(IHook(address(0x1234)), 1);

        // New owner gains it
        vm.prank(newOwner);
        account.setHookGasLimit(IHook(address(0x1234)), 1);
    }

    function test_ChangeRootValidator_RejectsZeroValidator() public {
        vm.prank(address(entryPoint));
        vm.expectRevert(ValidationManager.InvalidValidator.selector);
        account.changeRootValidator(ValidationId.wrap(bytes21(0)), IHook(HOOK_MODULE_INSTALLED), "", "");
    }

    function test_ChangeRootValidator_StrangerCannotTakeOver() public {
        ECDSAValidator attackerValidator = new ECDSAValidator();
        ValidationId before = account.rootValidator();

        vm.prank(stranger);
        vm.expectRevert(bytes(NOT_OWNER));
        account.changeRootValidator(
            _vId(attackerValidator), IHook(HOOK_MODULE_INSTALLED), abi.encodePacked(stranger), ""
        );

        assertEq(ValidationId.unwrap(account.rootValidator()), ValidationId.unwrap(before));
    }

    /* //////////////////////////////////////////////////////////////
                                grantAccess
    //////////////////////////////////////////////////////////////*/

    function test_GrantAccess_TogglesSelector() public {
        ValidationId vId = _vId(new ECDSAValidator());
        bytes4 selector = Kernel.execute.selector;
        assertFalse(account.isAllowedSelector(vId, selector));

        vm.prank(address(entryPoint));
        account.grantAccess(vId, selector, true);
        assertTrue(account.isAllowedSelector(vId, selector));

        vm.prank(address(entryPoint));
        account.grantAccess(vId, selector, false);
        assertFalse(account.isAllowedSelector(vId, selector));
    }

    /* //////////////////////////////////////////////////////////////
                              setHookGasLimit
    //////////////////////////////////////////////////////////////*/

    function test_SetHookGasLimit_CapsHookExecution() public {
        GasBurningHook hook = new GasBurningHook();
        AdminTestExecutor executor = _installExecutor(IHook(address(hook)));

        // Unlimited by default: the expensive hook runs and the call succeeds
        executor.callThrough(address(account), address(0xdead));

        // A cap below the hook's cost makes the hook, and so the execution, fail
        vm.prank(address(entryPoint));
        account.setHookGasLimit(IHook(address(hook)), 20_000);
        vm.expectRevert();
        executor.callThrough(address(account), address(0xdead));

        // Resetting to 0 restores unlimited gas
        vm.prank(address(entryPoint));
        account.setHookGasLimit(IHook(address(hook)), 0);
        executor.callThrough(address(account), address(0xdead));
    }

    /* //////////////////////////////////////////////////////////////
                          delegatecall whitelist
    //////////////////////////////////////////////////////////////*/

    function test_DelegatecallWhitelist_NotEnforcedByDefault() public {
        vm.prank(address(entryPoint));
        account.execute(_delegateMode(), _delegateCalldata());

        assertEq(_marker(), 1);
    }

    function test_DelegatecallWhitelist_EnforcedBlocksUnlistedTarget() public {
        vm.prank(address(entryPoint));
        account.setEnforceDelegatecallWhitelist(true);

        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(Kernel.DelegatecallTargetNotWhitelisted.selector, address(marker)));
        account.execute(_delegateMode(), _delegateCalldata());

        assertEq(_marker(), 0);
    }

    function test_DelegatecallWhitelist_EnforcedAllowsListedTarget() public {
        vm.startPrank(address(entryPoint));
        account.setEnforceDelegatecallWhitelist(true);
        account.setDelegatecallWhitelist(address(marker), true);
        account.execute(_delegateMode(), _delegateCalldata());
        vm.stopPrank();

        assertEq(_marker(), 1);
    }

    function test_DelegatecallWhitelist_RemovedTargetIsBlocked() public {
        vm.startPrank(address(entryPoint));
        account.setEnforceDelegatecallWhitelist(true);
        account.setDelegatecallWhitelist(address(marker), true);
        account.setDelegatecallWhitelist(address(marker), false);

        vm.expectRevert(abi.encodeWithSelector(Kernel.DelegatecallTargetNotWhitelisted.selector, address(marker)));
        account.execute(_delegateMode(), _delegateCalldata());
        vm.stopPrank();
    }

    /// @dev Executors cannot delegatecall at all, whatever the whitelist state: a delegatecall
    ///      runs in the account's context and would bypass ExecutorCannotCallSelf
    function test_ExecutorDelegatecall_RejectedByDefault() public {
        AdminTestExecutor executor = _installExecutor(IHook(HOOK_MODULE_INSTALLED));

        vm.expectRevert(Kernel.InvalidCallType.selector);
        executor.delegatecallThrough(address(account), address(marker), abi.encodeCall(DelegateMarker.mark, ()));

        assertEq(_marker(), 0);
    }

    function test_ExecutorDelegatecall_RejectedWhenWhitelistEnforced() public {
        AdminTestExecutor executor = _installExecutor(IHook(HOOK_MODULE_INSTALLED));

        vm.prank(address(entryPoint));
        account.setEnforceDelegatecallWhitelist(true);

        vm.expectRevert(Kernel.InvalidCallType.selector);
        executor.delegatecallThrough(address(account), address(marker), abi.encodeCall(DelegateMarker.mark, ()));

        assertEq(_marker(), 0);
    }

    function test_ExecutorDelegatecall_RejectedForWhitelistedTarget() public {
        AdminTestExecutor executor = _installExecutor(IHook(HOOK_MODULE_INSTALLED));

        vm.startPrank(address(entryPoint));
        account.setEnforceDelegatecallWhitelist(true);
        account.setDelegatecallWhitelist(address(marker), true);
        vm.stopPrank();

        vm.expectRevert(Kernel.InvalidCallType.selector);
        executor.delegatecallThrough(address(account), address(marker), abi.encodeCall(DelegateMarker.mark, ()));

        assertEq(_marker(), 0);
    }

    /// @dev An executor delegatecall must not be able to replace the root validator
    function test_ExecutorDelegatecall_CannotReplaceRootValidator() public {
        AdminTestExecutor executor = _installExecutor(IHook(HOOK_MODULE_INSTALLED));
        RootValidatorOverwriter overwriter = new RootValidatorOverwriter();
        ValidationId rootBefore = account.rootValidator();

        vm.expectRevert(Kernel.InvalidCallType.selector);
        executor.delegatecallThrough(
            address(account), address(overwriter), abi.encodeCall(RootValidatorOverwriter.overwrite, (stranger))
        );

        assertEq(ValidationId.unwrap(account.rootValidator()), ValidationId.unwrap(rootBefore));
    }

    /* //////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev One harmless call per admin function; used for the access control loops
    function _adminCalls() internal returns (bytes[] memory calls) {
        calls = new bytes[](6);
        calls[0] = abi.encodeCall(Kernel.upgradeTo, (address(kernelImpl)));
        calls[1] = abi.encodeCall(
            Kernel.changeRootValidator,
            (_vId(ecdsaValidator), IHook(HOOK_MODULE_INSTALLED), abi.encodePacked(owner), bytes(""))
        );
        calls[2] = abi.encodeCall(Kernel.grantAccess, (_vId(new ECDSAValidator()), Kernel.execute.selector, true));
        calls[3] = abi.encodeCall(Kernel.setHookGasLimit, (IHook(address(0x1234)), 100_000));
        calls[4] = abi.encodeCall(Kernel.setDelegatecallWhitelist, (address(marker), true));
        calls[5] = abi.encodeCall(Kernel.setEnforceDelegatecallWhitelist, (true));
    }

    function _createAccount(ECDSAValidator validator, address validatorOwner) internal returns (address) {
        bytes memory initData = abi.encodeCall(
            Kernel.initialize,
            (_vId(validator), IHook(HOOK_MODULE_INSTALLED), abi.encodePacked(validatorOwner), hex"", new bytes[](0))
        );
        vm.prank(senderCreator);
        return kernelFactory.createAccount(initData, bytes32(uint256(uint160(validatorOwner))));
    }

    /// @dev Executor initData: hook(20) + abi.encode(executorData, hookData)
    function _installExecutor(IHook hook) internal returns (AdminTestExecutor executor) {
        executor = new AdminTestExecutor();
        bytes memory initData = abi.encodePacked(bytes20(address(hook)), abi.encode(bytes(""), bytes("")));
        vm.prank(address(account));
        account.installModule(MODULE_TYPE_EXECUTOR, address(executor), initData);
    }

    function _vId(ECDSAValidator validator) internal pure returns (ValidationId) {
        return ValidatorLib.validatorToIdentifier(IValidator(address(validator)));
    }

    function _delegateMode() internal pure returns (ExecMode) {
        return
            ExecLib.encode(CALLTYPE_DELEGATECALL, EXECTYPE_DEFAULT, EXEC_MODE_DEFAULT, ExecModePayload.wrap(bytes22(0)));
    }

    function _delegateCalldata() internal view returns (bytes memory) {
        return abi.encodePacked(address(marker), abi.encodeCall(DelegateMarker.mark, ()));
    }

    function _marker() internal view returns (uint256) {
        return uint256(vm.load(address(account), marker.MARKER_SLOT()));
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }
}
