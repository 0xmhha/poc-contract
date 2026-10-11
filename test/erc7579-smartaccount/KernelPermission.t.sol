// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { RootHookBase } from "./KernelRootHook.t.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { ValidationManager } from "../../src/erc7579-smartaccount/core/ValidationManager.sol";
import { IHook, IPolicy, ISigner } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { ValidationId, PermissionId } from "../../src/erc7579-smartaccount/types/Types.sol";
import {
    HOOK_MODULE_INSTALLED,
    MODULE_TYPE_POLICY,
    MODULE_TYPE_SIGNER
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import { ValidatorLib } from "../../src/erc7579-smartaccount/utils/ValidationTypeLib.sol";

/// @dev Policy with a fixed verdict for UserOps and for signatures (0 = pass, 1 = fail)
contract FixedPolicy is IPolicy {
    uint256 internal immutable USEROP_RESULT;
    uint256 internal immutable SIG_RESULT;

    constructor(uint256 userOpResult, uint256 sigResult) {
        USEROP_RESULT = userOpResult;
        SIG_RESULT = sigResult;
    }

    function onInstall(bytes calldata) external payable { }
    function onUninstall(bytes calldata) external payable { }

    function isModuleType(uint256 t) external pure returns (bool) {
        return t == MODULE_TYPE_POLICY;
    }

    function isInitialized(address) external pure returns (bool) {
        return true;
    }

    function checkUserOpPolicy(bytes32, PackedUserOperation calldata) external payable returns (uint256) {
        return USEROP_RESULT;
    }

    function checkSignaturePolicy(bytes32, address, bytes32, bytes calldata) external view returns (uint256) {
        return SIG_RESULT;
    }
}

/// @dev Signer that accepts everything
contract AcceptAllSigner is ISigner {
    function onInstall(bytes calldata) external payable { }
    function onUninstall(bytes calldata) external payable { }

    function isModuleType(uint256 t) external pure returns (bool) {
        return t == MODULE_TYPE_SIGNER;
    }

    function isInitialized(address) external pure returns (bool) {
        return true;
    }

    function checkUserOpSignature(bytes32, PackedUserOperation calldata, bytes32) external payable returns (uint256) {
        return 0;
    }

    function checkSignature(bytes32, address, bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

contract KernelPermissionTest is RootHookBase {
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;
    PermissionId internal constant PID = PermissionId.wrap(bytes4(0xaabbccdd));

    address internal account;
    AcceptAllSigner internal signer;

    function setUp() public {
        _baseSetUp();
        account = _createAccount(IHook(HOOK_MODULE_INSTALLED), hex"", 1);
        signer = new AcceptAllSigner();
    }

    function _installPermission(IPolicy policy) internal {
        _installPermission(policy, bytes2(0), bytes2(0));
    }

    /// @dev Installs permission PID = [policy, signer] through installValidations and grants it
    ///      execute. The signer entry's flag is the permission flag (SKIP_USEROP 0x0001,
    ///      SKIP_SIGNATURE 0x0002); the policy entry's flag skips that policy for the same cases.
    function _installPermission(IPolicy policy, bytes2 policyFlag, bytes2 permissionFlag) internal {
        ValidationId[] memory vIds = new ValidationId[](1);
        vIds[0] = ValidatorLib.permissionToIdentifier(PID);
        ValidationManager.ValidationConfig[] memory configs = new ValidationManager.ValidationConfig[](1);
        uint32 current = Kernel(payable(account)).currentNonce();
        configs[0] = ValidationManager.ValidationConfig({
            nonce: current == 0 ? 1 : current, hook: IHook(HOOK_MODULE_INSTALLED)
        });
        bytes[] memory entries = new bytes[](2);
        entries[0] = abi.encodePacked(policyFlag, address(policy));
        entries[1] = abi.encodePacked(permissionFlag, address(signer));
        bytes[] memory validatorData = new bytes[](1);
        validatorData[0] = abi.encode(entries);

        vm.startPrank(owner);
        Kernel(payable(account)).installValidations(vIds, configs, validatorData, new bytes[](1));
        Kernel(payable(account)).grantAccess(vIds[0], Kernel.execute.selector, true);
        vm.stopPrank();
    }

    /// @dev UserOp validated by permission PID; signature 0xff = no policy data, empty signer part
    function _permissionOp(bytes memory callData) internal view returns (PackedUserOperation[] memory ops) {
        uint192 key = ValidatorLib.encodeAsNonceKey(bytes1(0x00), bytes1(0x02), bytes20(PermissionId.unwrap(PID)), 0);
        ops = new PackedUserOperation[](1);
        ops[0] = PackedUserOperation({
            sender: account,
            nonce: entryPoint.getNonce(account, key),
            initCode: hex"",
            callData: callData,
            accountGasLimits: bytes32(abi.encodePacked(uint128(1_000_000), uint128(1_000_000))),
            preVerificationGas: 100_000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(10 gwei))),
            paymasterAndData: hex"",
            signature: hex"ff"
        });
    }

    function _handle(PackedUserOperation[] memory ops) internal {
        vm.prank(beneficiary, beneficiary);
        entryPoint.handleOps(ops, payable(beneficiary));
    }

    function _transferOp() internal returns (PackedUserOperation[] memory) {
        vm.deal(account, 10 ether);
        return _permissionOp(_executeSingle(makeAddr("recipient"), 1 ether, ""));
    }

    /// @dev ERC-1271 signature through permission PID, with no policy data and an empty signer part
    function _permissionSig() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x02), PermissionId.unwrap(PID), bytes1(0xff));
    }

    function test_IsValidSignature_RejectedWhenPolicyRejects() public {
        _installPermission(new FixedPolicy(0, 1));
        assertTrue(
            Kernel(payable(account)).isValidSignature(keccak256("msg"), _permissionSig()) != ERC1271_MAGIC,
            "a signature policy that fails must make the signature invalid"
        );
    }

    /// @dev A policy flagged SKIP_SIGNATURE is not consulted for signatures
    function test_IsValidSignature_SkipsPolicyFlaggedSkipSignature() public {
        _installPermission(new FixedPolicy(0, 1), bytes2(0x0002), bytes2(0));
        assertEq(Kernel(payable(account)).isValidSignature(keccak256("msg"), _permissionSig()), ERC1271_MAGIC);
    }

    function test_IsValidSignature_RevertsWhenPermissionSkipsSignatures() public {
        _installPermission(new FixedPolicy(0, 0), bytes2(0), bytes2(0x0002));
        vm.expectRevert(ValidationManager.PermissionNotAlllowedForSignature.selector);
        Kernel(payable(account)).isValidSignature(keccak256("msg"), _permissionSig());
    }

    // ============ UserOps through a permission ============

    function test_UserOp_ExecutesWhenPolicyPasses() public {
        _installPermission(new FixedPolicy(0, 0));
        _handle(_transferOp());
        assertEq(makeAddr("recipient").balance, 1 ether);
    }

    function test_UserOp_RejectedWhenPolicyRejects() public {
        _installPermission(new FixedPolicy(1, 0));
        PackedUserOperation[] memory ops = _transferOp();
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        _handle(ops);
    }

    function test_UserOp_RejectedWhenPermissionSkipsUserOps() public {
        _installPermission(new FixedPolicy(0, 0), bytes2(0), bytes2(0x0001));
        PackedUserOperation[] memory ops = _transferOp();
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPoint.FailedOpWithRevert.selector,
                0,
                "AA23 reverted",
                abi.encodeWithSelector(ValidationManager.PermissionNotAlllowedForUserOp.selector)
            )
        );
        _handle(ops);
    }

    function test_IsValidSignature_AcceptedWhenPolicyPasses() public {
        _installPermission(new FixedPolicy(0, 0));
        assertEq(Kernel(payable(account)).isValidSignature(keccak256("msg"), _permissionSig()), ERC1271_MAGIC);
    }
}
