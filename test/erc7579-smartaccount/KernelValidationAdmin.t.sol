// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { RootHookBase } from "./KernelRootHook.t.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { ValidationManager } from "../../src/erc7579-smartaccount/core/ValidationManager.sol";
import { ECDSAValidator } from "../../src/erc7579-validators/ECDSAValidator.sol";
import { IValidator, IHook } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { ValidationId } from "../../src/erc7579-smartaccount/types/Types.sol";
import { HOOK_MODULE_INSTALLED, MAGIC_VALUE_SIG_REPLAYABLE } from "../../src/erc7579-smartaccount/types/Constants.sol";
import { ValidatorLib } from "../../src/erc7579-smartaccount/utils/ValidationTypeLib.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

/// @notice Kernel validation management through the real EntryPoint: installValidations,
///         uninstallValidation, revokeSelectors, and chain-agnostic (replayable) UserOp signatures.
///         None of these paths had a test before.
contract KernelValidationAdminTest is RootHookBase {
    address internal recipient = makeAddr("recipient");
    address internal account;

    function setUp() public {
        _baseSetUp();
        account = _createAccount(IHook(HOOK_MODULE_INSTALLED), hex"", 1);
        vm.deal(account, 10 ether);
    }

    function _vId(address validator) internal pure returns (ValidationId) {
        return ValidatorLib.validatorToIdentifier(IValidator(validator));
    }

    function _transfer(uint256 amount) internal view returns (bytes memory) {
        return _executeSingle(recipient, amount, "");
    }

    /// @dev Builds a UserOp. validator == address(0): root validation signed by owner; otherwise that
    ///      validator signed by delegate. replayable: sign the chain-agnostic hash behind the magic prefix.
    function _op(address validator, bytes memory callData, bool replayable)
        internal
        view
        returns (PackedUserOperation[] memory ops)
    {
        uint192 key = validator == address(0)
            ? uint192(0)
            : ValidatorLib.encodeAsNonceKey(bytes1(0x00), bytes1(0x01), bytes20(validator), 0);
        PackedUserOperation memory op = PackedUserOperation({
            sender: account,
            nonce: entryPoint.getNonce(account, key),
            initCode: hex"",
            callData: callData,
            accountGasLimits: bytes32(abi.encodePacked(uint128(1_000_000), uint128(1_000_000))),
            preVerificationGas: 100_000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(10 gwei))),
            paymasterAndData: hex"",
            signature: hex""
        });
        bytes32 h = replayable
            ? Kernel(payable(account)).replayableUserOpHash(op, address(entryPoint))
            : entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(validator == address(0) ? ownerKey : delegateKey, ECDSA.toEthSignedMessageHash(h));
        op.signature = replayable ? abi.encodePacked(MAGIC_VALUE_SIG_REPLAYABLE, r, s, v) : abi.encodePacked(r, s, v);
        ops = new PackedUserOperation[](1);
        ops[0] = op;
    }

    /// @dev Nonce a fresh validation must carry: _installValidation bumps currentNonce only when the
    ///      stored nonce (0 for a new validation) equals it, then requires config.nonce == currentNonce
    function _nextValidationNonce() internal view returns (uint32) {
        uint32 current = Kernel(payable(account)).currentNonce();
        return current == 0 ? 1 : current;
    }

    /// @dev Kernel.validateUserOp reverts with InvalidValidator, which the EntryPoint reports as AA23
    function _expectValidatorRejected() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPoint.FailedOpWithRevert.selector,
                0,
                "AA23 reverted",
                abi.encodeWithSelector(ValidationManager.InvalidValidator.selector)
            )
        );
    }

    function _handle(PackedUserOperation[] memory ops) internal {
        vm.prank(beneficiary, beneficiary);
        entryPoint.handleOps(ops, payable(beneficiary));
    }

    // ============ installValidations ============

    function test_InstallValidations_DelegateCanExecuteAfterGrant() public {
        ECDSAValidator v = new ECDSAValidator();
        ValidationId[] memory vIds = new ValidationId[](1);
        vIds[0] = _vId(address(v));
        ValidationManager.ValidationConfig[] memory configs = new ValidationManager.ValidationConfig[](1);
        configs[0] =
            ValidationManager.ValidationConfig({ nonce: _nextValidationNonce(), hook: IHook(HOOK_MODULE_INSTALLED) });
        bytes[] memory validatorData = new bytes[](1);
        validatorData[0] = abi.encodePacked(delegate);
        bytes[] memory hookData = new bytes[](1);

        vm.startPrank(owner);
        Kernel(payable(account)).installValidations(vIds, configs, validatorData, hookData);
        Kernel(payable(account)).grantAccess(vIds[0], Kernel.execute.selector, true);
        vm.stopPrank();

        assertEq(address(Kernel(payable(account)).validationConfig(vIds[0]).hook), HOOK_MODULE_INSTALLED);
        _handle(_op(address(v), _transfer(1 ether), false));
        assertEq(recipient.balance, 1 ether);
    }

    function test_InstallValidations_RejectsWrongNonce() public {
        ECDSAValidator v = new ECDSAValidator();
        ValidationId[] memory vIds = new ValidationId[](1);
        vIds[0] = _vId(address(v));
        ValidationManager.ValidationConfig[] memory configs = new ValidationManager.ValidationConfig[](1);
        configs[0] = ValidationManager.ValidationConfig({
            nonce: Kernel(payable(account)).currentNonce() + 5, hook: IHook(HOOK_MODULE_INSTALLED)
        });
        bytes[] memory validatorData = new bytes[](1);
        validatorData[0] = abi.encodePacked(delegate);

        vm.prank(owner);
        vm.expectRevert(ValidationManager.InvalidNonce.selector);
        Kernel(payable(account)).installValidations(vIds, configs, validatorData, new bytes[](1));
    }

    // ============ uninstallValidation ============

    function test_UninstallValidation_DelegateCanNoLongerValidate() public {
        ECDSAValidator v = _installDelegateValidator(account, IHook(HOOK_MODULE_INSTALLED), hex"");
        _handle(_op(address(v), _transfer(1 ether), false));

        vm.prank(owner);
        Kernel(payable(account)).uninstallValidation(_vId(address(v)), hex"", hex"");

        assertEq(address(Kernel(payable(account)).validationConfig(_vId(address(v))).hook), address(0));
        (address storedOwner) = v.ecdsaValidatorStorage(account);
        assertEq(storedOwner, address(0), "validator onUninstall clears the owner");

        PackedUserOperation[] memory ops = _op(address(v), _transfer(1 ether), false);
        _expectValidatorRejected();
        _handle(ops);
        assertEq(recipient.balance, 1 ether);
    }

    function test_UninstallValidation_RejectsRootValidator() public {
        ValidationId root = Kernel(payable(account)).rootValidator();
        vm.prank(owner);
        vm.expectRevert(ValidationManager.RootValidatorCannotBeRemoved.selector);
        Kernel(payable(account)).uninstallValidation(root, hex"", hex"");
    }

    // ============ revokeSelectors ============

    function test_RevokeSelectors_BlocksDelegatedExecute() public {
        ECDSAValidator v = _installDelegateValidator(account, IHook(HOOK_MODULE_INSTALLED), hex"");
        ValidationId vId = _vId(address(v));
        assertTrue(Kernel(payable(account)).isAllowedSelector(vId, Kernel.execute.selector));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Kernel.execute.selector;
        vm.prank(owner);
        Kernel(payable(account)).revokeSelectors(vId, selectors);

        assertFalse(Kernel(payable(account)).isAllowedSelector(vId, Kernel.execute.selector));
        PackedUserOperation[] memory ops = _op(address(v), _transfer(1 ether), false);
        _expectValidatorRejected();
        _handle(ops);
        assertEq(recipient.balance, 0);
    }

    // ============ replayable (chain-agnostic) signatures ============

    /// @dev The replayable hash leaves out the chain id, so one signature validates the same UserOp
    ///      on another chain where the account has the same address and nonce
    function test_ReplayableSignature_ValidOnAnotherChain() public {
        PackedUserOperation[] memory ops = _op(address(0), _transfer(1 ether), true);
        uint256 snapshot = vm.snapshotState();

        _handle(ops);
        assertEq(recipient.balance, 1 ether);

        vm.revertToState(snapshot);
        vm.chainId(block.chainid + 1);
        _handle(ops);
        assertEq(recipient.balance, 1 ether);
    }

    /// @dev Control: a regular signature commits to the chain id and fails elsewhere
    function test_RegularSignature_InvalidOnAnotherChain() public {
        PackedUserOperation[] memory ops = _op(address(0), _transfer(1 ether), false);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        _handle(ops);
        assertEq(recipient.balance, 0);
    }

    function test_ReplayableUserOpHash_IgnoresChainIdButBindsEntryPoint() public {
        PackedUserOperation memory op = _op(address(0), _transfer(1 ether), false)[0];
        bytes32 h = Kernel(payable(account)).replayableUserOpHash(op, address(entryPoint));

        vm.chainId(block.chainid + 1);
        assertEq(Kernel(payable(account)).replayableUserOpHash(op, address(entryPoint)), h);
        assertTrue(Kernel(payable(account)).replayableUserOpHash(op, address(0xE)) != h);
        assertTrue(h != entryPoint.getUserOpHash(op));
    }
}
