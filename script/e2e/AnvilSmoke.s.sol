// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { KernelFactory } from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";
import { FactoryStaker } from "../../src/erc7579-smartaccount/factory/FactoryStaker.sol";
import { ValidationManager } from "../../src/erc7579-smartaccount/core/ValidationManager.sol";
import { IPolicy, ISigner } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { IValidator, IHook } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { PermissionId, ValidationId } from "../../src/erc7579-smartaccount/types/Types.sol";
import {
    HOOK_MODULE_INSTALLED,
    CALLTYPE_SINGLE,
    EXECTYPE_DEFAULT,
    EXEC_MODE_DEFAULT,
    MODULE_TYPE_POLICY,
    MODULE_TYPE_SIGNER
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import { ValidatorLib } from "../../src/erc7579-smartaccount/utils/ValidationTypeLib.sol";
import { ExecLib, ExecModePayload } from "../../src/erc7579-smartaccount/utils/ExecLib.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

/// @notice End-to-end smoke test against a local anvil deployment (deployments/<chainId>/addresses.json)
/// @dev Usage:
///        forge script script/e2e/AnvilSmoke.s.sol --rpc-url http://127.0.0.1:8545 \
///          --private-key <anvil key 0, the FactoryStaker owner> --broadcast --gas-estimate-multiplier 200
///      The multiplier matters: eth_estimateGas does not cover the EntryPoint inner-call gas checks,
///      and an under-funded handleOps reverts on chain (0xdeaddead) even though simulation passes.
///      1. checks the deployment left KernelFactory approved on FactoryStaker
///      2. UserOp #1: deploys an ECDSA Kernel account through initCode (FactoryStaker) and sends 0.1 ETH
///      3. UserOp #2: a second transfer from the deployed account (no initCode)
///      4. checks ERC-1271 accepts a passing permission policy and rejects a failing one (#32)
///      Signs with anvil key 1 as the account owner. Refuses to run unless the node is anvil.
contract AnvilSmokeScript is Script {
    // anvil default account 1 (public test key)
    uint256 internal constant OWNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    IEntryPoint internal entryPoint;
    KernelFactory internal factory;
    FactoryStaker internal staker;
    address internal ecdsaValidator;
    address internal recipient = address(0xBEEF);

    function run() external {
        require(block.chainid == 31337 && _isAnvil(), "Anvil 31337 only");
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), "/addresses.json"));
        entryPoint = IEntryPoint(vm.parseJsonAddress(json, ".entryPoint"));
        factory = KernelFactory(vm.parseJsonAddress(json, ".kernelFactory"));
        staker = FactoryStaker(vm.parseJsonAddress(json, ".factoryStaker"));
        ecdsaValidator = vm.parseJsonAddress(json, ".ecdsaValidator");
        address owner = vm.addr(OWNER_KEY);

        ValidationId vId = ValidatorLib.validatorToIdentifier(IValidator(ecdsaValidator));
        bytes memory initData = abi.encodeCall(
            Kernel.initialize, (vId, IHook(HOOK_MODULE_INSTALLED), abi.encodePacked(owner), hex"", new bytes[](0))
        );
        bytes32 salt = keccak256(abi.encode("anvil-smoke", block.timestamp));
        address account = factory.getAddress(initData, salt);
        require(account.code.length == 0, "account already exists");
        require(staker.approved(factory), "deployment did not approve KernelFactory on FactoryStaker");
        uint256 recipientBefore = recipient.balance;

        vm.startBroadcast();
        entryPoint.depositTo{ value: 1 ether }(account);
        (bool funded,) = account.call{ value: 1 ether }("");
        require(funded, "fund account");

        bytes memory initCode = abi.encodePacked(
            address(staker), abi.encodeCall(FactoryStaker.deployWithFactory, (factory, initData, salt))
        );
        _handleOp(account, initCode, _transfer(0.1 ether));
        require(account.code.length > 0, "account not deployed");
        require(recipient.balance == recipientBefore + 0.1 ether, "transfer #1");

        _handleOp(account, hex"", _transfer(0.2 ether));
        require(recipient.balance == recipientBefore + 0.3 ether, "transfer #2");
        vm.stopBroadcast();

        _checkPermissionSignatures(account);
        console.log("account:", account);
        console.log("accountId:", Kernel(payable(account)).accountId());
        console.log("recipient received (wei):", recipient.balance - recipientBefore);
        console.log("SMOKE OK");
    }

    function _checkPermissionSignatures(address account) internal {
        vm.startBroadcast();
        AnvilPermissionSigner signer = new AnvilPermissionSigner();
        AnvilSignaturePolicy rejecting = new AnvilSignaturePolicy(1);
        AnvilSignaturePolicy passing = new AnvilSignaturePolicy(0);
        vm.stopBroadcast();
        vm.startBroadcast(OWNER_KEY);
        _installPermission(account, PermissionId.wrap(0xaabbccdd), rejecting, signer);
        _installPermission(account, PermissionId.wrap(0xddccbbaa), passing, signer);
        vm.stopBroadcast();
        bytes32 digest = keccak256("anvil permission signature policy");
        require(
            Kernel(payable(account)).isValidSignature(digest, hex"02aabbccddff") != 0x1626ba7e,
            "rejecting signature policy was bypassed"
        );
        require(
            Kernel(payable(account)).isValidSignature(digest, hex"02ddccbbaaff") == 0x1626ba7e,
            "passing signature policy was rejected"
        );
        console.log("PERMISSION POLICY OK");
    }

    function _installPermission(address account, PermissionId id, IPolicy policy, ISigner signer) internal {
        ValidationId[] memory ids = new ValidationId[](1);
        ids[0] = ValidatorLib.permissionToIdentifier(id);
        ValidationManager.ValidationConfig[] memory configs = new ValidationManager.ValidationConfig[](1);
        uint32 nonce = Kernel(payable(account)).currentNonce();
        configs[0] =
            ValidationManager.ValidationConfig({ nonce: nonce == 0 ? 1 : nonce, hook: IHook(HOOK_MODULE_INSTALLED) });
        bytes[] memory entries = new bytes[](2);
        entries[0] = abi.encodePacked(bytes2(0), address(policy));
        entries[1] = abi.encodePacked(bytes2(0), address(signer));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(entries);
        Kernel(payable(account)).installValidations(ids, configs, data, new bytes[](1));
    }

    function _isAnvil() internal returns (bool) {
        try vm.rpc("web3_clientVersion", "[]") returns (bytes memory version) {
            // Older forge returns the raw string bytes, newer forge an ABI-encoded string
            if (version.length >= 64 && uint256(bytes32(version)) == 0x20) {
                version = bytes(abi.decode(version, (string)));
            }
            bytes memory prefix = bytes("anvil/");
            if (version.length < prefix.length) return false;
            for (uint256 i = 0; i < prefix.length; i++) {
                if (version[i] != prefix[i]) return false;
            }
            return true;
        } catch {
            return false;
        }
    }

    function _transfer(uint256 amount) internal view returns (bytes memory) {
        return abi.encodeCall(
            Kernel.execute,
            (
                ExecLib.encode(CALLTYPE_SINGLE, EXECTYPE_DEFAULT, EXEC_MODE_DEFAULT, ExecModePayload.wrap(bytes22(0))),
                ExecLib.encodeSingle(recipient, amount, "")
            )
        );
    }

    function _handleOp(address account, bytes memory initCode, bytes memory callData) internal {
        PackedUserOperation memory op = PackedUserOperation({
            sender: account,
            nonce: entryPoint.getNonce(account, 0),
            initCode: initCode,
            callData: callData,
            // verificationGasLimit covers account deployment; callGasLimit only a plain transfer. EntryPoint
            // requires the tx to carry callGasLimit up front, so oversized limits fail with AA95.
            accountGasLimits: bytes32(abi.encodePacked(uint128(400_000), uint128(100_000))),
            preVerificationGas: 100_000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(50 gwei))),
            paymasterAndData: hex"",
            signature: hex""
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, ECDSA.toEthSignedMessageHash(entryPoint.getUserOpHash(op)));
        op.signature = abi.encodePacked(r, s, v);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        entryPoint.handleOps(ops, payable(msg.sender));
    }
}

/// @dev Local-only fixtures for the ERC-1271 permission-policy smoke test.
contract AnvilSignaturePolicy is IPolicy {
    uint256 private immutable _verdict;

    constructor(uint256 verdict) {
        require(block.chainid == 31337, "local fixture only");
        _verdict = verdict;
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
        return 0;
    }

    function checkSignaturePolicy(bytes32, address, bytes32, bytes calldata) external view returns (uint256) {
        return _verdict;
    }
}

contract AnvilPermissionSigner is ISigner {
    constructor() {
        require(block.chainid == 31337, "local fixture only");
    }
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
