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
import {
    HOOK_MODULE_INSTALLED,
    MAGIC_VALUE_SIG_REPLAYABLE,
    ENABLE_TYPE_HASH
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import { ValidatorLib } from "../../src/erc7579-smartaccount/utils/ValidationTypeLib.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

/// @notice Enable mode: a UserOp whose nonce carries mode 0x01 installs a new validator, approved by a
///         root-validator signature over an EIP-712 digest, and is then validated by that new validator
///         in the same operation. None of this path had a test before.
contract KernelEnableModeTest is RootHookBase {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    address internal recipient = makeAddr("recipient");
    address internal account;
    ECDSAValidator internal v;

    struct EnableArgs {
        uint256 enableKey; // key signing the enable digest (root owner when valid)
        bool replayable; // chain-agnostic enable digest
        bool opReplayable; // chain-agnostic UserOp hash behind the magic prefix
        uint32 nonce; // validation nonce committed to in the enable digest
    }

    function setUp() public {
        _baseSetUp();
        account = _createAccount(IHook(HOOK_MODULE_INSTALLED), hex"", 1);
        vm.deal(account, 10 ether);
        v = new ECDSAValidator();
    }

    function _vId() internal view returns (ValidationId) {
        return ValidatorLib.validatorToIdentifier(IValidator(address(v)));
    }

    /// @dev Nonce the next enable must commit to, mirroring ValidationManager._enableDigest
    function _expectedNonce() internal view returns (uint32) {
        Kernel k = Kernel(payable(account));
        uint32 current = k.currentNonce();
        return k.validationConfig(_vId()).nonce == current ? current + 1 : current;
    }

    function _enableDigest(uint32 nonce, bool replayable) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ENABLE_TYPE_HASH,
                ValidationId.unwrap(_vId()),
                nonce,
                HOOK_MODULE_INSTALLED,
                keccak256(abi.encodePacked(delegate)),
                keccak256(hex""),
                keccak256(abi.encodePacked(Kernel.execute.selector))
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("Kernel"), keccak256("0.3.3"), replayable ? 0 : block.chainid, account
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// @dev Builds an enable-mode UserOp transferring `amount` to recipient. The delegate signs the
    ///      UserOp itself; `a.enableKey` signs the enable digest.
    function _enableOp(uint256 amount, EnableArgs memory a) internal view returns (PackedUserOperation[] memory ops) {
        uint192 key = ValidatorLib.encodeAsNonceKey(bytes1(0x01), bytes1(0x01), bytes20(address(v)), 0);
        PackedUserOperation memory op = PackedUserOperation({
            sender: account,
            nonce: entryPoint.getNonce(account, key),
            initCode: hex"",
            callData: _executeSingle(recipient, amount, ""),
            accountGasLimits: bytes32(abi.encodePacked(uint128(1_000_000), uint128(1_000_000))),
            preVerificationGas: 100_000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(10 gwei))),
            paymasterAndData: hex"",
            signature: hex""
        });

        (uint8 ev, bytes32 er, bytes32 es) = vm.sign(a.enableKey, _enableDigest(a.nonce, a.replayable));
        bytes32 h = a.opReplayable
            ? Kernel(payable(account)).replayableUserOpHash(op, address(entryPoint))
            : entryPoint.getUserOpHash(op);
        (uint8 uv, bytes32 ur, bytes32 us) = vm.sign(delegateKey, ECDSA.toEthSignedMessageHash(h));

        bytes memory packed = abi.encodePacked(
            bytes20(HOOK_MODULE_INSTALLED),
            abi.encode(
                abi.encodePacked(delegate),
                hex"",
                abi.encodePacked(Kernel.execute.selector),
                abi.encodePacked(er, es, ev),
                abi.encodePacked(ur, us, uv)
            )
        );
        op.signature = a.opReplayable ? abi.encodePacked(MAGIC_VALUE_SIG_REPLAYABLE, packed) : packed;
        ops = new PackedUserOperation[](1);
        ops[0] = op;
    }

    function _args() internal view returns (EnableArgs memory) {
        return EnableArgs({ enableKey: ownerKey, replayable: false, opReplayable: false, nonce: _expectedNonce() });
    }

    function _handle(PackedUserOperation[] memory ops) internal {
        vm.prank(beneficiary, beneficiary);
        entryPoint.handleOps(ops, payable(beneficiary));
    }

    function _expectAA23(bytes4 reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPoint.FailedOpWithRevert.selector, 0, "AA23 reverted", abi.encodeWithSelector(reason)
            )
        );
    }

    // ============ happy path ============

    function test_EnableMode_InstallsAndExecutesInOneOp() public {
        uint32 nonce = _expectedNonce();
        _handle(_enableOp(1 ether, _args()));

        Kernel k = Kernel(payable(account));
        assertEq(recipient.balance, 1 ether);
        assertEq(address(k.validationConfig(_vId()).hook), HOOK_MODULE_INSTALLED);
        assertEq(k.validationConfig(_vId()).nonce, nonce);
        assertEq(k.currentNonce(), nonce);
        assertTrue(k.isAllowedSelector(_vId(), Kernel.execute.selector));
        (address storedOwner) = v.ecdsaValidatorStorage(account);
        assertEq(storedOwner, delegate);
    }

    /// @dev After enabling, the validator works in plain validation mode (0x00) without the enable data
    function test_EnableMode_ValidatorUsableAfterwardsInDefaultMode() public {
        _handle(_enableOp(1 ether, _args()));

        uint192 key = ValidatorLib.encodeAsNonceKey(bytes1(0x00), bytes1(0x01), bytes20(address(v)), 0);
        PackedUserOperation memory op = PackedUserOperation({
            sender: account,
            nonce: entryPoint.getNonce(account, key),
            initCode: hex"",
            callData: _executeSingle(recipient, 1 ether, ""),
            accountGasLimits: bytes32(abi.encodePacked(uint128(1_000_000), uint128(1_000_000))),
            preVerificationGas: 100_000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(10 gwei))),
            paymasterAndData: hex"",
            signature: hex""
        });
        (uint8 uv, bytes32 ur, bytes32 us) =
            vm.sign(delegateKey, ECDSA.toEthSignedMessageHash(entryPoint.getUserOpHash(op)));
        op.signature = abi.encodePacked(ur, us, uv);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        _handle(ops);
        assertEq(recipient.balance, 2 ether);
    }

    // ============ rejected enable approvals ============

    /// @dev Only the root validator may approve an enable; a signature from the key being enabled is not enough
    function test_EnableMode_RejectsEnableSignedByNonRoot() public {
        EnableArgs memory a = _args();
        a.enableKey = delegateKey;
        PackedUserOperation[] memory ops = _enableOp(1 ether, a);

        _expectAA23(ValidationManager.EnableNotApproved.selector);
        _handle(ops);
        assertEq(recipient.balance, 0);
        assertEq(address(Kernel(payable(account)).validationConfig(_vId()).hook), address(0));
    }

    /// @dev The digest commits to the validation nonce, so an approval for a stale nonce does not verify
    function test_EnableMode_RejectsWrongNonceInDigest() public {
        EnableArgs memory a = _args();
        a.nonce += 1;
        PackedUserOperation[] memory ops = _enableOp(1 ether, a);

        _expectAA23(ValidationManager.EnableNotApproved.selector);
        _handle(ops);
    }

    /// @dev A chain-bound approval does not verify when the UserOp claims the chain-agnostic form
    function test_EnableMode_RejectsChainBoundSigInReplayableOp() public {
        EnableArgs memory a = _args();
        a.opReplayable = true;
        PackedUserOperation[] memory ops = _enableOp(1 ether, a);

        _expectAA23(ValidationManager.EnableNotApproved.selector);
        _handle(ops);
    }

    /// @dev Reusing an approval after it was consumed fails: the account's nonce moved on, so the
    ///      same signature no longer matches the digest
    function test_EnableMode_ApprovalCannotBeReplayedAfterUninstall() public {
        EnableArgs memory a = _args();
        PackedUserOperation[] memory first = _enableOp(1 ether, a);
        _handle(first);

        vm.prank(owner);
        Kernel(payable(account)).uninstallValidation(_vId(), hex"", hex"");

        // same enable signature (same committed nonce), fresh UserOp
        PackedUserOperation[] memory again = _enableOp(1 ether, a);
        assertTrue(_expectedNonce() != a.nonce);
        _expectAA23(ValidationManager.EnableNotApproved.selector);
        _handle(again);
        assertEq(recipient.balance, 1 ether);
    }

    // ============ replayable enable ============

    /// @dev A chain-agnostic approval enables the same validator on another chain with the same account state
    function test_EnableMode_ReplayableApprovalWorksOnAnotherChain() public {
        EnableArgs memory a = _args();
        a.replayable = true;
        a.opReplayable = true;
        PackedUserOperation[] memory ops = _enableOp(1 ether, a);
        uint256 snapshot = vm.snapshotState();

        _handle(ops);
        assertEq(recipient.balance, 1 ether);

        vm.revertToState(snapshot);
        vm.chainId(block.chainid + 1);
        _handle(ops);
        assertEq(recipient.balance, 1 ether);
        assertTrue(Kernel(payable(account)).isAllowedSelector(_vId(), Kernel.execute.selector));
    }

    // ============ revocation ============

    /// @dev invalidateNonce past the enabled validation's nonce revokes it
    function test_EnableMode_InvalidateNonceRevokesEnabledValidator() public {
        uint32 nonce = _expectedNonce();
        _handle(_enableOp(1 ether, _args()));

        vm.prank(owner);
        Kernel(payable(account)).invalidateNonce(nonce + 1);

        uint192 key = ValidatorLib.encodeAsNonceKey(bytes1(0x00), bytes1(0x01), bytes20(address(v)), 0);
        PackedUserOperation memory op = PackedUserOperation({
            sender: account,
            nonce: entryPoint.getNonce(account, key),
            initCode: hex"",
            callData: _executeSingle(recipient, 1 ether, ""),
            accountGasLimits: bytes32(abi.encodePacked(uint128(1_000_000), uint128(1_000_000))),
            preVerificationGas: 100_000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(10 gwei))),
            paymasterAndData: hex"",
            signature: hex""
        });
        (uint8 uv, bytes32 ur, bytes32 us) =
            vm.sign(delegateKey, ECDSA.toEthSignedMessageHash(entryPoint.getUserOpHash(op)));
        op.signature = abi.encodePacked(ur, us, uv);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        _expectAA23(ValidationManager.InvalidNonce.selector);
        _handle(ops);
        assertEq(recipient.balance, 1 ether);
    }
}
