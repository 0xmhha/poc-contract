// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";
import { IEntryPoint } from "../../src/erc7579-smartaccount/interfaces/IEntryPoint.sol";
import { IStakeManager } from "../../src/erc4337-entrypoint/interfaces/IStakeManager.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { KernelFactory } from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";
import { ECDSAValidator } from "../../src/erc7579-validators/ECDSAValidator.sol";
import { IValidator, IHook } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import { ValidationId, ExecMode } from "../../src/erc7579-smartaccount/types/Types.sol";
import {
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_EXECUTOR,
    HOOK_MODULE_INSTALLED,
    CALLTYPE_SINGLE,
    EXECTYPE_DEFAULT,
    EXEC_MODE_DEFAULT
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import { ValidatorLib } from "../../src/erc7579-smartaccount/utils/ValidationTypeLib.sol";
import { ExecLib, ExecModePayload } from "../../src/erc7579-smartaccount/utils/ExecLib.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

contract KernelTest is Test {
    EntryPoint public entryPoint;
    Kernel public kernelImpl;
    KernelFactory public kernelFactory;
    ECDSAValidator public ecdsaValidator;

    address public owner;
    uint256 public ownerKey;
    address public beneficiary;

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

        // Deploy KernelFactory
        kernelFactory = new KernelFactory(address(kernelImpl));

        // Deploy ECDSAValidator
        ecdsaValidator = new ECDSAValidator();
    }

    /*//////////////////////////////////////////////////////////////
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

    /*//////////////////////////////////////////////////////////////
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

        // Create account through factory
        bytes32 salt = bytes32(uint256(1));
        address accountAddr = kernelFactory.createAccount(initData, salt);

        assertNotEq(accountAddr, address(0), "Account should be created");

        // Verify account is initialized
        Kernel account = Kernel(payable(accountAddr));
        assertEq(account.accountId(), "kernel.advanced.v0.3.3", "Account ID should match");
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

        // Create account
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

        address first = kernelFactory.createAccount(initData, salt);
        address second = kernelFactory.createAccount(initData, salt);

        assertEq(first, second, "Same salt should produce same address");
    }

    /*//////////////////////////////////////////////////////////////
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

    /*//////////////////////////////////////////////////////////////
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

    /*//////////////////////////////////////////////////////////////
                        EXECUTION MODE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SupportsDefaultExecutionMode() public {
        address account = _createKernelAccount(owner);
        ExecMode mode = _encodeSimpleSingle();
        assertTrue(Kernel(payable(account)).supportsExecutionMode(mode), "Should support default execution mode");
    }

    /*//////////////////////////////////////////////////////////////
                        USER OPERATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HandleOps_SimpleExecution() public {
        // Create and fund account
        address account = _createKernelAccount(owner);
        vm.deal(account, 10 ether);

        // Deposit to EntryPoint - must be called by owner due to ECDSAValidator preCheck hook
        vm.prank(owner);
        Kernel(payable(account)).execute(
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
        Kernel(payable(account)).execute(
            _encodeSimpleSingle(),
            abi.encodePacked(address(entryPoint), uint256(5 ether), abi.encodeCall(IStakeManager.depositTo, (account)))
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
        vm.expectRevert();
        entryPoint.handleOps(ops, payable(beneficiary));
    }

    /*//////////////////////////////////////////////////////////////
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

    /*//////////////////////////////////////////////////////////////
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

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _createKernelAccount(address accountOwner) internal returns (address) {
        ValidationId rootValidator = ValidatorLib.validatorToIdentifier(IValidator(address(ecdsaValidator)));
        bytes memory validatorData = abi.encodePacked(accountOwner);
        bytes[] memory initConfig = new bytes[](0);

        bytes memory initData = abi.encodeCall(
            Kernel.initialize, (rootValidator, IHook(HOOK_MODULE_INSTALLED), validatorData, hex"", initConfig)
        );

        bytes32 salt = bytes32(uint256(uint160(accountOwner)));
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
