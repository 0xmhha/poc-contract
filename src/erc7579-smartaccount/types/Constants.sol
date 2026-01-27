// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { CallType, ExecType, ExecModeSelector } from "./Types.sol";
import { PassFlag, ValidationMode, ValidationType } from "./Types.sol";
import { ValidationData } from "./Types.sol";

// --- ERC7579 calltypes ---
// Default CallType
CallType constant CALLTYPE_SINGLE = CallType.wrap(0x00);
// Batched CallType
CallType constant CALLTYPE_BATCH = CallType.wrap(0x01);
CallType constant CALLTYPE_STATIC = CallType.wrap(0xFE);
// @dev Implementing delegatecall is OPTIONAL!
// implement delegatecall with extreme care.
CallType constant CALLTYPE_DELEGATECALL = CallType.wrap(0xFF);

// --- ERC7579 exectypes ---
// @dev default behavior is to revert on failure
// To allow very simple accounts to use mode encoding, the default behavior is to revert on failure
// Since this is value 0x00, no additional encoding is required for simple accounts
ExecType constant EXECTYPE_DEFAULT = ExecType.wrap(0x00);
// @dev account may elect to change execution behavior. For example "try exec" / "allow fail"
ExecType constant EXECTYPE_TRY = ExecType.wrap(0x01);

// --- ERC7579 mode selector ---
ExecModeSelector constant EXEC_MODE_DEFAULT = ExecModeSelector.wrap(bytes4(0x00_000_000));

// --- Kernel permission skip flags ---
PassFlag constant SKIP_USEROP = PassFlag.wrap(0x0_001);
PassFlag constant SKIP_SIGNATURE = PassFlag.wrap(0x0_002);

// --- Kernel validation modes ---
ValidationMode constant VALIDATION_MODE_DEFAULT = ValidationMode.wrap(0x00);
ValidationMode constant VALIDATION_MODE_ENABLE = ValidationMode.wrap(0x01);
ValidationMode constant VALIDATION_MODE_INSTALL = ValidationMode.wrap(0x02);

// --- Kernel validation types ---
ValidationType constant VALIDATION_TYPE_ROOT = ValidationType.wrap(0x00);
ValidationType constant VALIDATION_TYPE_7702 = ValidationType.wrap(0x00);
ValidationType constant VALIDATION_TYPE_VALIDATOR = ValidationType.wrap(0x01);
ValidationType constant VALIDATION_TYPE_PERMISSION = ValidationType.wrap(0x02);

// --- Kernel Hook constants ---
address constant HOOK_MODULE_NOT_INSTALLED = address(0);
address constant HOOK_MODULE_INSTALLED = address(1);
address constant HOOK_ONLY_ENTRYPOINT = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);

// --- EIP7702 constants ---
bytes3 constant EIP7702_PREFIX = bytes3(0xef0_100);

// --- storage slots ---
// bytes32(uint256(keccak256('kernel.v3.selector')) - 1)
bytes32 constant SELECTOR_MANAGER_STORAGE_SLOT =
    0x7_c34_134_9a4_360_fdd_5d5_bc0_7e6_9f3_25d_c6a_aea_3eb_018_b3e_0ea_7e5_3cc_0bb_0d6_f3b;
// bytes32(uint256(keccak256('kernel.v3.executor')) - 1)
bytes32 constant EXECUTOR_MANAGER_STORAGE_SLOT =
    0x1_bbe_e31_73d_bdc_223_633_258_c9f_337_a0f_ff8_115_f20_6d3_02b_ea0_ed3_eac_003_b68_b86;
// bytes32(uint256(keccak256('kernel.v3.hook')) - 1)
bytes32 constant HOOK_MANAGER_STORAGE_SLOT =
    0x4_605_d5f_70b_b60_509_4b2_e76_1ec_cdc_27b_ed9_a36_2d8_612_792_676_bf3_fb9_b12_832_ffc;
// bytes32(uint256(keccak256('kernel.v3.validation')) - 1)
bytes32 constant VALIDATION_MANAGER_STORAGE_SLOT =
    0x7_bca_a2c_ed2_a71_450_ed5_a9a_1b4_848_e8e_520_6db_c3f_060_11e_595_f7f_554_28c_c6f_84f;
bytes32 constant ERC1967_IMPLEMENTATION_SLOT =
    0x3_608_94a_13b_a1a_321_066_7c8_284_92d_b98_dca_3e2_076_cc3_735_a92_0a3_ca5_05d_382_bbc;

bytes32 constant MAGIC_VALUE_SIG_REPLAYABLE = keccak256("kernel.replayable.signature");

// --- Kernel validation nonce incremental size limit ---
uint32 constant MAX_NONCE_INCREMENT_SIZE = 10;

// -- EIP712 type hash ---
bytes32 constant ENABLE_TYPE_HASH =
    0xb_17a_b12_24a_ca0_d42_55e_f81_61a_caf_2ac_121_b8f_aa3_2a4_b22_58c_912_cc5_f83_08c_505;
bytes32 constant KERNEL_WRAPPER_TYPE_HASH =
    0x1_547_321_c37_4af_de8_a59_1d9_72a_084_b07_1c5_94c_275_e36_724_931_ff9_6c2_5f2_999_c83;

// --- ERC constants ---
// ERC4337 constants
uint256 constant SIG_VALIDATION_FAILED_UINT = 1;
uint256 constant SIG_VALIDATION_SUCCESS_UINT = 0;
ValidationData constant SIG_VALIDATION_FAILED = ValidationData.wrap(SIG_VALIDATION_FAILED_UINT);

// ERC-1271 constants
bytes4 constant ERC1271_MAGICVALUE = 0x16_26b_a7e;
bytes4 constant ERC1271_INVALID = 0xff_fff_fff;

uint256 constant MODULE_TYPE_VALIDATOR = 1;
uint256 constant MODULE_TYPE_EXECUTOR = 2;
uint256 constant MODULE_TYPE_FALLBACK = 3;
uint256 constant MODULE_TYPE_HOOK = 4;
uint256 constant MODULE_TYPE_POLICY = 5;
uint256 constant MODULE_TYPE_SIGNER = 6;
