// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { KernelFactory } from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";
import { FactoryStaker } from "../../src/erc7579-smartaccount/factory/FactoryStaker.sol";
import { IValidator, IHook } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { ValidationId } from "../../src/erc7579-smartaccount/types/Types.sol";
import {
    HOOK_MODULE_INSTALLED,
    CALLTYPE_SINGLE,
    EXECTYPE_DEFAULT,
    EXEC_MODE_DEFAULT
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
        require(_isAnvil(), "anvil only");
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

        console.log("account:", account);
        console.log("accountId:", Kernel(payable(account)).accountId());
        console.log("recipient received (wei):", recipient.balance - recipientBefore);
        console.log("SMOKE OK");
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
