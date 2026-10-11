// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { IStakeManager } from "../../src/erc4337-entrypoint/interfaces/IStakeManager.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { KernelFactory } from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";
import { FactoryStaker } from "../../src/erc7579-smartaccount/factory/FactoryStaker.sol";
import { ECDSAValidator } from "../../src/erc7579-validators/ECDSAValidator.sol";
import { MultiSigValidator } from "../../src/erc7579-validators/MultiSigValidator.sol";
import { WeightedECDSAValidator } from "../../src/erc7579-validators/WeightedECDSAValidator.sol";
import { IValidator, IHook } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { ValidationId, ExecMode } from "../../src/erc7579-smartaccount/types/Types.sol";
import {
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_EXECUTOR,
    HOOK_MODULE_INSTALLED,
    CALLTYPE_SINGLE,
    EXECTYPE_DEFAULT,
    EXEC_MODE_DEFAULT,
    ERC1271_MAGICVALUE,
    ERC1271_INVALID,
    KERNEL_WRAPPER_TYPE_HASH
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import { ValidatorLib } from "../../src/erc7579-smartaccount/utils/ValidationTypeLib.sol";
import { ExecLib, ExecModePayload } from "../../src/erc7579-smartaccount/utils/ExecLib.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

contract KernelTest is Test {
    EntryPoint public entryPoint;
    Kernel public kernelImpl;
    KernelFactory public kernelFactory;
    FactoryStaker public factoryStaker;
    ECDSAValidator public ecdsaValidator;

    address public owner;
    uint256 public ownerKey;
    address public beneficiary;
    address public senderCreator;

    // Gas limits for UserOp
    uint128 constant VERIFICATION_GAS_LIMIT = 1_000_000;
    uint128 constant CALL_GAS_LIMIT = 500_000;
    uint256 constant PRE_VERIFICATION_GAS = 100_000;
    uint128 constant MAX_FEE_PER_GAS = 10 gwei;
    uint128 constant MAX_PRIORITY_FEE_PER_GAS = 1 gwei;

    event Received(address sender, uint256 amount);

    function setUp() public {
        // Create test accounts
        (owner, ownerKey) = makeAddrAndKey("owner");
        beneficiary = makeAddr("beneficiary");

        // Deploy EntryPoint
        entryPoint = new EntryPoint();

        // Deploy Kernel implementation
        kernelImpl = new Kernel(IEntryPoint(address(entryPoint)));

        // Deploy FactoryStaker and a KernelFactory that trusts it
        factoryStaker = new FactoryStaker(address(this));
        kernelFactory = new KernelFactory(address(kernelImpl), IEntryPoint(address(entryPoint)), address(factoryStaker));
        factoryStaker.approveFactory(kernelFactory, true);

        // Deploy ECDSAValidator
        ecdsaValidator = new ECDSAValidator();

        // Cache SenderCreator address (immutable after EntryPoint deploy)
        senderCreator = address(entryPoint.senderCreator());
    }

    /* //////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DeploymentContracts() public view {
        assertNotEq(address(entryPoint), address(0), "EntryPoint should be deployed");
        assertNotEq(address(kernelImpl), address(0), "Kernel implementation should be deployed");
        assertNotEq(address(kernelFactory), address(0), "KernelFactory should be deployed");
        assertNotEq(address(ecdsaValidator), address(0), "ECDSAValidator should be deployed");
    }

    function test_KernelFactoryImplementation() public view {
        assertEq(kernelFactory.IMPLEMENTATION(), address(kernelImpl), "Factory should reference correct implementation");
    }

    function test_KernelEntryPoint() public view {
        assertEq(address(kernelImpl.ENTRYPOINT()), address(entryPoint), "Kernel should reference correct EntryPoint");
    }

    /* //////////////////////////////////////////////////////////////
                        ACCOUNT CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateAccount() public {
        // Prepare initialization data
        ValidationId rootValidator = ValidatorLib.validatorToIdentifier(IValidator(address(ecdsaValidator)));
        bytes memory validatorData = abi.encodePacked(owner);
        bytes[] memory initConfig = new bytes[](0);

        bytes memory initData = abi.encodeCall(
            Kernel.initialize, (rootValidator, IHook(HOOK_MODULE_INSTALLED), validatorData, hex"", initConfig)
        );

        // Create account through factory (must call from SenderCreator)
        bytes32 salt = bytes32(uint256(1));
        vm.prank(senderCreator);
        address accountAddr = kernelFactory.createAccount(initData, salt);

        assertNotEq(accountAddr, address(0), "Account should be created");

        // Verify account is initialized
        Kernel account = Kernel(payable(accountAddr));
        assertEq(account.accountId(), "kernel.advanced.0.3.3", "Account ID should match");
    }

    function test_GetAccountAddress() public {
        // Prepare initialization data
        ValidationId rootValidator = ValidatorLib.validatorToIdentifier(IValidator(address(ecdsaValidator)));
        bytes memory validatorData = abi.encodePacked(owner);
        bytes[] memory initConfig = new bytes[](0);

        bytes memory initData = abi.encodeCall(
            Kernel.initialize, (rootValidator, IHook(HOOK_MODULE_INSTALLED), validatorData, hex"", initConfig)
        );

        bytes32 salt = bytes32(uint256(1));

        // Get predicted address
        address predictedAddr = kernelFactory.getAddress(initData, salt);

        // Create account (must call from SenderCreator)
        vm.prank(senderCreator);
        address actualAddr = kernelFactory.createAccount(initData, salt);

        assertEq(predictedAddr, actualAddr, "Predicted address should match actual");
    }

    function test_CreateAccountDeterministic() public {
        // Create same account twice with same salt - should return same address
        ValidationId rootValidator = ValidatorLib.validatorToIdentifier(IValidator(address(ecdsaValidator)));
        bytes memory validatorData = abi.encodePacked(owner);
        bytes[] memory initConfig = new bytes[](0);

        bytes memory initData = abi.encodeCall(
            Kernel.initialize, (rootValidator, IHook(HOOK_MODULE_INSTALLED), validatorData, hex"", initConfig)
        );

        bytes32 salt = bytes32(uint256(42));

        // Must call from SenderCreator
        vm.prank(senderCreator);
        address first = kernelFactory.createAccount(initData, salt);
        vm.prank(senderCreator);
        address second = kernelFactory.createAccount(initData, salt);

        assertEq(first, second, "Same salt should produce same address");
    }

    /* //////////////////////////////////////////////////////////////
                        VALIDATOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ECDSAValidatorInstallation() public {
        address account = _createKernelAccount(owner);

        // Verify validator is installed
        assertTrue(
            Kernel(payable(account)).isModuleInstalled(MODULE_TYPE_VALIDATOR, address(ecdsaValidator), hex""),
            "Validator should be installed"
        );
    }

    function test_ECDSAValidatorOwner() public {
        address account = _createKernelAccount(owner);

        // Check owner is set in validator
        (address storedOwner) = ecdsaValidator.ecdsaValidatorStorage(account);
        assertEq(storedOwner, owner, "Validator should store correct owner");
    }

    /* //////////////////////////////////////////////////////////////
                        MODULE SUPPORT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SupportsValidatorModule() public {
        address account = _createKernelAccount(owner);
        assertTrue(Kernel(payable(account)).supportsModule(MODULE_TYPE_VALIDATOR), "Should support validator module");
    }

    function test_SupportsExecutorModule() public {
        address account = _createKernelAccount(owner);
        assertTrue(Kernel(payable(account)).supportsModule(MODULE_TYPE_EXECUTOR), "Should support executor module");
    }

    /* //////////////////////////////////////////////////////////////
                        EXECUTION MODE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SupportsDefaultExecutionMode() public {
        address account = _createKernelAccount(owner);
        ExecMode mode = _encodeSimpleSingle();
        assertTrue(Kernel(payable(account)).supportsExecutionMode(mode), "Should support default execution mode");
    }

    /// @dev SenderCreator can deploy through the approved FactoryStaker
    function test_FactoryStaker_DeploysWhenCalledBySenderCreator() public {
        bytes memory initData = _ecdsaInitData(owner);
        address predicted = kernelFactory.getAddress(initData, bytes32(0));

        vm.prank(senderCreator);
        address deployed = factoryStaker.deployWithFactory(kernelFactory, initData, bytes32(0));

        assertEq(deployed, predicted, "staker deploys the counterfactual address");
        assertEq(Kernel(payable(deployed)).accountId(), "kernel.advanced.0.3.3");
    }

    /// @dev The staker keeps the "only via EntryPoint" rule: other callers are rejected
    function test_FactoryStaker_RejectsCallerOtherThanSenderCreator() public {
        vm.expectRevert(FactoryStaker.NotCalledFromEntryPoint.selector);
        factoryStaker.deployWithFactory(kernelFactory, _ecdsaInitData(owner), bytes32(0));
    }

    function test_FactoryStaker_RejectsUnapprovedFactory() public {
        factoryStaker.approveFactory(kernelFactory, false);

        vm.prank(senderCreator);
        vm.expectRevert(FactoryStaker.NotApprovedFactory.selector);
        factoryStaker.deployWithFactory(kernelFactory, _ecdsaInitData(owner), bytes32(0));
    }

    /// @dev A KernelFactory that does not name this staker still rejects it
    function test_KernelFactory_RejectsUntrustedStaker() public {
        KernelFactory otherFactory =
            new KernelFactory(address(kernelImpl), IEntryPoint(address(entryPoint)), address(0));
        factoryStaker.approveFactory(otherFactory, true);

        vm.prank(senderCreator);
        vm.expectRevert(KernelFactory.NotCalledFromEntryPoint.selector);
        factoryStaker.deployWithFactory(otherFactory, _ecdsaInitData(owner), bytes32(0));
    }

    function test_KernelFactory_RejectsDirectCallFromStranger() public {
        vm.expectRevert(KernelFactory.NotCalledFromEntryPoint.selector);
        kernelFactory.createAccount(_ecdsaInitData(owner), bytes32(0));
    }

    /// @dev Full ERC-4337 path: initCode names the FactoryStaker, the EntryPoint deploys and runs the op
    function test_HandleOps_DeploysThroughFactoryStaker() public {
        bytes memory initData = _ecdsaInitData(owner);
        address account = kernelFactory.getAddress(initData, bytes32(0));
        vm.deal(account, 10 ether);

        address target = makeAddr("target");
        PackedUserOperation memory userOp = _createUserOp(account, 0, target, 1 ether, hex"");
        userOp.initCode = abi.encodePacked(
            address(factoryStaker),
            abi.encodeCall(FactoryStaker.deployWithFactory, (kernelFactory, initData, bytes32(0)))
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerKey, ECDSA.toEthSignedMessageHash(entryPoint.getUserOpHash(userOp)));
        userOp.signature = abi.encodePacked(r, s, v);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.prank(beneficiary, beneficiary);
        entryPoint.handleOps(ops, payable(beneficiary));

        assertGt(account.code.length, 0, "account deployed through the staker");
        assertEq(target.balance, 1 ether, "deployment op executed");
    }

    /* //////////////////////////////////////////////////////////////
                        USER OPERATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HandleOps_SimpleExecution() public {
        // Create and fund account
        address account = _createKernelAccount(owner);
        vm.deal(account, 10 ether);

        // Deposit to EntryPoint - must be called by owner due to ECDSAValidator preCheck hook
        vm.prank(owner);
        Kernel(payable(account))
            .execute(
                _encodeSimpleSingle(),
                abi.encodePacked(
                    address(entryPoint), uint256(5 ether), abi.encodeCall(IStakeManager.depositTo, (account))
                )
            );

        // Create UserOp for simple ETH transfer
        address target = makeAddr("target");
        PackedUserOperation memory userOp = _createUserOp(account, 0, target, 1 ether, hex"");

        // Sign the UserOp
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, ECDSA.toEthSignedMessageHash(userOpHash));
        userOp.signature = abi.encodePacked(r, s, v);

        // Execute
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        uint256 balanceBefore = target.balance;
        vm.prank(beneficiary, beneficiary);
        entryPoint.handleOps(ops, payable(beneficiary));

        assertEq(target.balance - balanceBefore, 1 ether, "Target should receive ETH");
    }

    function test_HandleOps_InvalidSignature() public {
        // Create and fund account
        address account = _createKernelAccount(owner);
        vm.deal(account, 10 ether);

        // Deposit to EntryPoint - must be called by owner due to ECDSAValidator preCheck hook
        vm.prank(owner);
        Kernel(payable(account))
            .execute(
                _encodeSimpleSingle(),
                abi.encodePacked(
                    address(entryPoint), uint256(5 ether), abi.encodeCall(IStakeManager.depositTo, (account))
                )
            );

        // Create UserOp
        address target = makeAddr("target");
        PackedUserOperation memory userOp = _createUserOp(account, 0, target, 1 ether, hex"");

        // Sign with wrong key
        (, uint256 wrongKey) = makeAddrAndKey("wrongOwner");
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ECDSA.toEthSignedMessageHash(userOpHash));
        userOp.signature = abi.encodePacked(r, s, v);

        // Execute should revert
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.prank(beneficiary, beneficiary);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        entryPoint.handleOps(ops, payable(beneficiary));
    }

    /// @dev A 4-of-5 MultiSig root validator must accept a correctly signed UserOp
    ///      (threshold * 65 previously overflowed uint8 and froze the account)
    function test_HandleOps_MultiSigRootThreshold4() public {
        MultiSigValidator multisig = new MultiSigValidator();
        address[] memory signers = new address[](5);
        uint256[] memory keys = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            (signers[i], keys[i]) = makeAddrAndKey(string(abi.encodePacked("multisig-signer-", vm.toString(i))));
        }
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = i + 1; j < 5; j++) {
                if (signers[j] < signers[i]) {
                    (signers[i], signers[j]) = (signers[j], signers[i]);
                    (keys[i], keys[j]) = (keys[j], keys[i]);
                }
            }
        }

        bytes memory initData = abi.encodeCall(
            Kernel.initialize,
            (
                ValidatorLib.validatorToIdentifier(IValidator(address(multisig))),
                IHook(HOOK_MODULE_INSTALLED),
                abi.encode(signers, uint8(4)),
                hex"",
                new bytes[](0)
            )
        );
        vm.prank(senderCreator);
        address account = kernelFactory.createAccount(initData, bytes32(uint256(4)));
        vm.deal(account, 10 ether);
        entryPoint.depositTo{ value: 5 ether }(account);

        address target = makeAddr("target");
        PackedUserOperation memory userOp = _createUserOp(account, 0, target, 1 ether, hex"");
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        for (uint256 i = 0; i < 4; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], userOpHash);
            userOp.signature = abi.encodePacked(userOp.signature, r, s, v);
        }

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.prank(beneficiary, beneficiary);
        entryPoint.handleOps(ops, payable(beneficiary));

        assertEq(target.balance, 1 ether, "4-of-5 multisig account should execute");
    }

    /// @dev With a weighted root validator, one guardian below the threshold must not
    ///      produce a valid ERC-1271 signature by repeating its own signature
    function test_IsValidSignature_WeightedRootRejectsDuplicateGuardian() public {
        WeightedECDSAValidator weighted = new WeightedECDSAValidator();
        (address high, uint256 highKey) = makeAddrAndKey("weighted-guardian-a");
        (address low, uint256 lowKey) = makeAddrAndKey("weighted-guardian-b");
        if (high < low) {
            (high, low) = (low, high);
            (highKey, lowKey) = (lowKey, highKey);
        }
        address[] memory guardians = new address[](2);
        guardians[0] = high;
        guardians[1] = low;
        uint24[] memory weights = new uint24[](2);
        weights[0] = 100;
        weights[1] = 100;

        bytes memory initData = abi.encodeCall(
            Kernel.initialize,
            (
                ValidatorLib.validatorToIdentifier(IValidator(address(weighted))),
                IHook(HOOK_MODULE_INSTALLED),
                abi.encode(guardians, weights, uint24(150), uint48(0)),
                hex"",
                new bytes[](0)
            )
        );
        vm.prank(senderCreator);
        Kernel account = Kernel(payable(kernelFactory.createAccount(initData, bytes32(uint256(150)))));

        bytes32 hash = keccak256("permit");
        bytes32 wrapped = keccak256(
            abi.encodePacked(
                "\x19\x01",
                keccak256(
                    abi.encode(
                        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                        keccak256("Kernel"),
                        keccak256("0.3.3"),
                        block.chainid,
                        address(account)
                    )
                ),
                keccak256(abi.encode(KERNEL_WRAPPER_TYPE_HASH, hash))
            )
        );
        (uint8 vh, bytes32 rh, bytes32 sh) = vm.sign(highKey, wrapped);
        (uint8 vl, bytes32 rl, bytes32 sl) = vm.sign(lowKey, wrapped);
        bytes memory sigHigh = abi.encodePacked(rh, sh, vh);

        assertEq(
            account.isValidSignature(hash, abi.encodePacked(bytes1(0x00), sigHigh, rl, sl, vl)),
            ERC1271_MAGICVALUE,
            "two guardians reach the threshold"
        );
        assertEq(
            account.isValidSignature(hash, abi.encodePacked(bytes1(0x00), sigHigh, sigHigh)),
            ERC1271_INVALID,
            "duplicated guardian signature must be rejected"
        );
    }

    /// @dev An EIP-7702 delegated EOA has no root hook stored (address(0)); executeUserOp must
    ///      treat that as "no hook" instead of calling preCheck on address(0)
    function test_HandleOps_ExecuteUserOpOn7702Account() public {
        (address eoa, uint256 eoaKey) = makeAddrAndKey("eoa7702");
        vm.signAndAttachDelegation(address(kernelImpl), eoaKey);
        vm.deal(eoa, 10 ether);

        address target = makeAddr("target");
        PackedUserOperation memory userOp = _createUserOp(eoa, 0, target, 1 ether, hex"");
        userOp.callData = abi.encodePacked(Kernel.executeUserOp.selector, userOp.callData);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(eoaKey, ECDSA.toEthSignedMessageHash(entryPoint.getUserOpHash(userOp)));
        userOp.signature = abi.encodePacked(r, s, v);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.prank(beneficiary, beneficiary);
        entryPoint.handleOps(ops, payable(beneficiary));

        assertEq(target.balance, 1 ether, "executeUserOp should run on a 7702 account");
    }

    /* //////////////////////////////////////////////////////////////
                        RECEIVE ETH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ReceiveEth() public {
        address account = _createKernelAccount(owner);

        vm.deal(address(this), 1 ether);
        vm.expectEmit(true, true, false, true);
        emit Received(address(this), 1 ether);
        (bool success,) = account.call{ value: 1 ether }("");

        assertTrue(success, "Should receive ETH");
        assertEq(account.balance, 1 ether, "Account should have received ETH");
    }

    /* //////////////////////////////////////////////////////////////
                        ERC721/1155 RECEIVER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OnERC721Received() public {
        address account = _createKernelAccount(owner);

        bytes4 result = Kernel(payable(account)).onERC721Received(address(0), address(0), 0, hex"");
        assertEq(result, Kernel.onERC721Received.selector, "Should return correct selector");
    }

    function test_OnERC1155Received() public {
        address account = _createKernelAccount(owner);

        bytes4 result = Kernel(payable(account)).onERC1155Received(address(0), address(0), 0, 0, hex"");
        assertEq(result, Kernel.onERC1155Received.selector, "Should return correct selector");
    }

    function test_OnERC1155BatchReceived() public {
        address account = _createKernelAccount(owner);

        uint256[] memory ids = new uint256[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes4 result = Kernel(payable(account)).onERC1155BatchReceived(address(0), address(0), ids, amounts, hex"");
        assertEq(result, Kernel.onERC1155BatchReceived.selector, "Should return correct selector");
    }

    /* //////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _ecdsaInitData(address accountOwner) internal view returns (bytes memory) {
        return abi.encodeCall(
            Kernel.initialize,
            (
                ValidatorLib.validatorToIdentifier(IValidator(address(ecdsaValidator))),
                IHook(HOOK_MODULE_INSTALLED),
                abi.encodePacked(accountOwner),
                hex"",
                new bytes[](0)
            )
        );
    }

    function _createKernelAccount(address accountOwner) internal returns (address) {
        ValidationId rootValidator = ValidatorLib.validatorToIdentifier(IValidator(address(ecdsaValidator)));
        bytes memory validatorData = abi.encodePacked(accountOwner);
        bytes[] memory initConfig = new bytes[](0);

        bytes memory initData = abi.encodeCall(
            Kernel.initialize, (rootValidator, IHook(HOOK_MODULE_INSTALLED), validatorData, hex"", initConfig)
        );

        bytes32 salt = bytes32(uint256(uint160(accountOwner)));

        // KernelFactory requires calls from EntryPoint's SenderCreator
        vm.prank(senderCreator);
        return kernelFactory.createAccount(initData, salt);
    }

    function _createUserOp(address sender, uint256 nonce, address target, uint256 value, bytes memory data)
        internal
        pure
        returns (PackedUserOperation memory)
    {
        // Encode execution calldata
        bytes memory callData =
            abi.encodeCall(Kernel.execute, (_encodeSimpleSingle(), abi.encodePacked(target, value, data)));

        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: hex"",
            callData: callData,
            accountGasLimits: bytes32(abi.encodePacked(VERIFICATION_GAS_LIMIT, CALL_GAS_LIMIT)),
            preVerificationGas: PRE_VERIFICATION_GAS,
            gasFees: bytes32(abi.encodePacked(MAX_PRIORITY_FEE_PER_GAS, MAX_FEE_PER_GAS)),
            paymasterAndData: hex"",
            signature: hex""
        });
    }

    function _encodeSimpleSingle() internal pure returns (ExecMode) {
        return ExecLib.encode(CALLTYPE_SINGLE, EXECTYPE_DEFAULT, EXEC_MODE_DEFAULT, ExecModePayload.wrap(bytes22(0)));
    }
}
