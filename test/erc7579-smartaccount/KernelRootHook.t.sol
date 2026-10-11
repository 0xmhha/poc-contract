// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, Vm } from "forge-std/Test.sol";
import { EntryPoint } from "../../src/erc4337-entrypoint/EntryPoint.sol";
import { IEntryPoint } from "../../src/erc4337-entrypoint/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "../../src/erc4337-entrypoint/interfaces/PackedUserOperation.sol";
import { Kernel } from "../../src/erc7579-smartaccount/Kernel.sol";
import { KernelFactory } from "../../src/erc7579-smartaccount/factory/KernelFactory.sol";
import { ECDSAValidator } from "../../src/erc7579-validators/ECDSAValidator.sol";
import { IValidator, IHook } from "../../src/erc7579-smartaccount/interfaces/IERC7579Modules.sol";
import {
    ValidationId,
    ExecMode,
    CallType,
    ExecType,
    ExecModeSelector
} from "../../src/erc7579-smartaccount/types/Types.sol";
import {
    MODULE_TYPE_VALIDATOR,
    HOOK_MODULE_INSTALLED,
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    CALLTYPE_STATIC,
    CALLTYPE_DELEGATECALL,
    EXECTYPE_TRY,
    EXECTYPE_DEFAULT,
    EXEC_MODE_DEFAULT
} from "../../src/erc7579-smartaccount/types/Constants.sol";
import { ValidatorLib } from "../../src/erc7579-smartaccount/utils/ValidationTypeLib.sol";
import { ExecLib, ExecModePayload } from "../../src/erc7579-smartaccount/utils/ExecLib.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { SpendingLimitHook } from "../../src/erc7579-hooks/SpendingLimitHook.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RootHookToken is ERC20 {
    constructor(string memory n) ERC20(n, n) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Hook that counts preCheck/postCheck calls per account
contract CountingHook is IHook {
    mapping(address => uint256) public preChecks;
    mapping(address => uint256) public postChecks;

    function onInstall(bytes calldata) external payable { }
    function onUninstall(bytes calldata) external payable { }

    function isModuleType(uint256 t) external pure returns (bool) {
        return t == 4;
    }

    function isInitialized(address) external pure returns (bool) {
        return true;
    }

    function preCheck(address, uint256, bytes calldata) external payable returns (bytes memory) {
        preChecks[msg.sender]++;
        return hex"";
    }

    function postCheck(bytes calldata) external payable {
        postChecks[msg.sender]++;
    }
}

abstract contract RootHookBase is Test {
    EntryPoint internal entryPoint;
    Kernel internal kernelImpl;
    KernelFactory internal kernelFactory;
    ECDSAValidator internal rootValidator;
    address internal senderCreator;

    address internal owner;
    uint256 internal ownerKey;
    address internal delegate; // session/delegated key holder
    uint256 internal delegateKey;
    address internal beneficiary = makeAddr("beneficiary");

    bytes32 internal constant USEROP_EVENT_SIG =
        keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");

    function _baseSetUp() internal {
        (owner, ownerKey) = makeAddrAndKey("owner");
        (delegate, delegateKey) = makeAddrAndKey("delegate");
        entryPoint = new EntryPoint();
        kernelImpl = new Kernel(IEntryPoint(address(entryPoint)));
        kernelFactory = new KernelFactory(address(kernelImpl), IEntryPoint(address(entryPoint)), address(0));
        rootValidator = new ECDSAValidator();
        senderCreator = address(entryPoint.senderCreator());
    }

    /// @dev root = ECDSA(owner) with optional root hook
    function _createAccount(IHook rootHook, bytes memory rootHookData, uint256 salt)
        internal
        returns (address account)
    {
        ValidationId vId = ValidatorLib.validatorToIdentifier(IValidator(address(rootValidator)));
        bytes memory initData =
            abi.encodeCall(Kernel.initialize, (vId, rootHook, abi.encodePacked(owner), rootHookData, new bytes[](0)));
        vm.prank(senderCreator);
        account = kernelFactory.createAccount(initData, bytes32(salt));
        vm.deal(address(this), 100 ether);
        entryPoint.depositTo{ value: 10 ether }(account);
    }

    /// @dev Installs a second ECDSA validator (delegate key) with `hook`, granted the `execute` selector
    function _installDelegateValidator(address account, IHook hook, bytes memory hookData)
        internal
        returns (ECDSAValidator v)
    {
        v = new ECDSAValidator();
        bytes memory initData = abi.encodePacked(
            bytes20(address(hook)),
            abi.encode(abi.encodePacked(delegate), hookData, abi.encodePacked(Kernel.execute.selector))
        );
        vm.prank(owner);
        Kernel(payable(account)).installModule(MODULE_TYPE_VALIDATOR, address(v), initData);
    }

    function _mode(CallType ct) internal pure returns (ExecMode) {
        return ExecLib.encode(ct, EXECTYPE_DEFAULT, EXEC_MODE_DEFAULT, ExecModePayload.wrap(bytes22(0)));
    }

    function _executeSingle(address target, uint256 value, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeCall(Kernel.execute, (_mode(CALLTYPE_SINGLE), ExecLib.encodeSingle(target, value, data)));
    }

    /// @dev Sends a UserOp whose callData = executeUserOp.selector || innerExecuteCalldata.
    ///      validator == address(0) -> root validation (nonce key 0), signed by owner.
    ///      otherwise -> VALIDATION_TYPE_VALIDATOR with that validator, signed by delegate.
    ///      Returns the EntryPoint's UserOperationEvent.success flag.
    function _sendOp(address account, address validator, bytes memory innerExecuteCalldata)
        internal
        returns (bool success)
    {
        return _sendOpWithCallData(
            account, validator, abi.encodePacked(Kernel.executeUserOp.selector, innerExecuteCalldata)
        );
    }

    /// @dev Same as _sendOp with the UserOp callData given as is (e.g. execute(...) for a validator without a hook)
    function _sendOpWithCallData(address account, address validator, bytes memory callData)
        internal
        returns (bool success)
    {
        uint192 key = validator == address(0)
            ? uint192(0)
            : ValidatorLib.encodeAsNonceKey(bytes1(0x00), bytes1(0x01), bytes20(validator), 0);
        uint256 nonce = entryPoint.getNonce(account, key);
        PackedUserOperation memory op = PackedUserOperation({
            sender: account,
            nonce: nonce,
            initCode: hex"",
            callData: callData,
            accountGasLimits: bytes32(abi.encodePacked(uint128(2_000_000), uint128(3_000_000))),
            preVerificationGas: 100_000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(10 gwei))),
            paymasterAndData: hex"",
            signature: hex""
        });
        bytes32 h = entryPoint.getUserOpHash(op);
        uint256 pk = validator == address(0) ? ownerKey : delegateKey;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ECDSA.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        vm.recordLogs();
        vm.prank(beneficiary, beneficiary);
        entryPoint.handleOps(ops, payable(beneficiary));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(entryPoint) && logs[i].topics[0] == USEROP_EVENT_SIG) {
                (, success,,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                found = true;
            }
        }
        require(found, "no UserOperationEvent");
    }
}

/// @notice HOOK-4: the root validator hook must run once per UserOp, not twice
/// @dev executeUserOp runs the validation hook, then delegatecalls execute(), which runs the root
///      validator hook. When both are the same hook, executeUserOp now leaves it to execute().
contract KernelRootHookTest is RootHookBase {
    RootHookToken internal token;

    function setUp() public {
        _baseSetUp();
        token = new RootHookToken("TKN");
    }

    function _transferOp(uint256 amount) internal view returns (bytes memory) {
        return _executeSingle(address(token), 0, abi.encodeCall(IERC20.transfer, (beneficiary, amount)));
    }

    function test_RootHook_RunsOncePerExecute() public {
        CountingHook hook = new CountingHook();
        address account = _createAccount(IHook(address(hook)), hex"", 1);
        token.mint(account, 100 ether);

        assertTrue(_sendOp(account, address(0), _transferOp(1 ether)));
        assertEq(hook.preChecks(account), 1);
        assertEq(hook.postChecks(account), 1);
    }

    /// @notice Root hook still runs when the inner call is not execute() (execute is the only
    ///         function that runs the root hook itself)
    function test_RootHook_RunsForNonExecuteCall() public {
        CountingHook hook = new CountingHook();
        address account = _createAccount(IHook(address(hook)), hex"", 2);

        assertTrue(_sendOp(account, address(0), abi.encodeCall(Kernel.invalidateNonce, (1))));
        assertEq(hook.preChecks(account), 1);
        assertEq(hook.postChecks(account), 1);
    }

    /// @notice A non-root validator's own hook and the root hook each run once
    function test_DelegateValidatorHook_AndRootHook_EachRunOnce() public {
        CountingHook rootHook = new CountingHook();
        CountingHook delegateHook = new CountingHook();
        address account = _createAccount(IHook(address(rootHook)), hex"", 3);
        token.mint(account, 100 ether);
        ECDSAValidator v = _installDelegateValidator(account, IHook(address(delegateHook)), hex"");

        assertTrue(_sendOp(account, address(v), _transferOp(1 ether)));
        assertEq(delegateHook.preChecks(account), 1);
        assertEq(rootHook.preChecks(account), 1);
    }

    /// @notice SpendingLimitHook as root hook charges each transfer once.
    ///         Before the fix 40 consumed 80 of a 100 limit, and a fresh-period 60 was rejected.
    function test_SpendingLimitRootHook_ChargesOnce() public {
        SpendingLimitHook slh = new SpendingLimitHook();
        address[] memory t = new address[](1);
        t[0] = address(token);
        uint256[] memory l = new uint256[](1);
        l[0] = 100 ether;
        uint256[] memory p = new uint256[](1);
        p[0] = 1 days;
        address account = _createAccount(IHook(address(slh)), abi.encodePacked(hex"ff", abi.encode(t, l, p)), 4);
        token.mint(account, 10_000 ether);

        assertTrue(_sendOp(account, address(0), _transferOp(40 ether)));
        assertEq(slh.getRemainingAllowance(account, address(token)), 60 ether);

        vm.warp(10 days);
        assertTrue(_sendOp(account, address(0), _transferOp(60 ether)));
        assertEq(token.balanceOf(beneficiary), 100 ether);
    }

    /// @notice The raw-word supportsExecutionMode matches the previous field-by-field check
    function testFuzz_SupportsExecutionMode_MatchesReference(bytes32 raw) public {
        address account = _createAccount(IHook(HOOK_MODULE_INSTALLED), hex"", 5);
        ExecMode mode = ExecMode.wrap(raw);
        (CallType callType, ExecType execType, ExecModeSelector selector, ExecModePayload payload) =
            ExecLib.decode(mode);
        bool expected = (callType == CALLTYPE_SINGLE || callType == CALLTYPE_BATCH || callType == CALLTYPE_DELEGATECALL)
            && (ExecType.unwrap(execType) == ExecType.unwrap(EXECTYPE_DEFAULT)
                || ExecType.unwrap(execType) == ExecType.unwrap(EXECTYPE_TRY))
            && ExecModeSelector.unwrap(selector) == ExecModeSelector.unwrap(EXEC_MODE_DEFAULT)
            && ExecModePayload.unwrap(payload) == bytes22(0);
        assertEq(Kernel(payable(account)).supportsExecutionMode(mode), expected);
    }

    function test_SupportsExecutionMode_KnownModes() public {
        address account = _createAccount(IHook(HOOK_MODULE_INSTALLED), hex"", 6);
        Kernel k = Kernel(payable(account));
        assertTrue(k.supportsExecutionMode(_mode(CALLTYPE_SINGLE)));
        assertTrue(k.supportsExecutionMode(_mode(CALLTYPE_BATCH)));
        assertTrue(k.supportsExecutionMode(_mode(CALLTYPE_DELEGATECALL)));
        assertFalse(k.supportsExecutionMode(_mode(CALLTYPE_STATIC)));
        assertTrue(
            k.supportsExecutionMode(
                ExecLib.encode(CALLTYPE_BATCH, EXECTYPE_TRY, EXEC_MODE_DEFAULT, ExecModePayload.wrap(bytes22(0)))
            )
        );
        assertFalse(
            k.supportsExecutionMode(
                ExecLib.encode(
                    CALLTYPE_SINGLE, EXECTYPE_DEFAULT, EXEC_MODE_DEFAULT, ExecModePayload.wrap(bytes22(uint176(1)))
                )
            )
        );
    }
}
