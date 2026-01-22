# POC Contract Architecture Analysis

This document summarizes key design decisions, placeholder analysis, and considerations for future production implementation.

> **[한국어](./ko/ARCHITECTURE_ANALYSIS.md)**

## Table of Contents

1. [Universal Router Command Placeholders](#1-universal-router-command-placeholders)
2. [P256 Precompile Requirements (WebAuthnValidator)](#2-p256-precompile-requirements-webauthnvalidator)
3. [AutoSwapPlugin Simplification](#3-autoswapplugin-simplification)
4. [FraudProofVerifier Signature Verification](#4-fraudproofverifier-signature-verification)

---

## 1. Universal Router Command Placeholders

### 1.1 Overview

Universal Router's `Commands.sol` defines commands the router can execute. Uniswap has reserved several placeholder slots for future expansion.

**File Location**: `src/dex/universal-router/libraries/Commands.sol`

### 1.2 Current Command Structure

| Range | Purpose | Used Slots | Placeholder |
|-------|---------|------------|-------------|
| `0x00-0x07` | V3 Swap & Basic Operations | 0x00-0x06 | **0x07** |
| `0x08-0x0f` | V2 Swap & Permit | 0x08-0x0e | **0x0f** |
| `0x10-0x20` | V4 & Position Manager | 0x10-0x14 | **0x15-0x20** |
| `0x21-0x3f` | Sub-plan Execution | 0x21 | **0x22-0x3f** |
| `0x40-0x5f` | 3rd Party Integration | 0x40 (Across) | **0x41-0x5f** |

### 1.3 Currently Implemented Commands

```solidity
// First block (0x00-0x07)
V3_SWAP_EXACT_IN       = 0x00;  // V3 exact input swap
V3_SWAP_EXACT_OUT      = 0x01;  // V3 exact output swap
PERMIT2_TRANSFER_FROM  = 0x02;  // Permit2 transfer
PERMIT2_PERMIT_BATCH   = 0x03;  // Permit2 batch approval
SWEEP                  = 0x04;  // Token sweep
TRANSFER               = 0x05;  // Token transfer
PAY_PORTION            = 0x06;  // Portion payment
// 0x07 - PLACEHOLDER

// Second block (0x08-0x0f)
V2_SWAP_EXACT_IN              = 0x08;  // V2 exact input swap
V2_SWAP_EXACT_OUT             = 0x09;  // V2 exact output swap
PERMIT2_PERMIT                = 0x0a;  // Permit2 single approval
WRAP_ETH                      = 0x0b;  // ETH → WETH
UNWRAP_WETH                   = 0x0c;  // WETH → ETH
PERMIT2_TRANSFER_FROM_BATCH   = 0x0d;  // Permit2 batch transfer
BALANCE_CHECK_ERC20           = 0x0e;  // ERC20 balance check
// 0x0f - PLACEHOLDER

// Third block (0x10-0x20)
V4_SWAP                       = 0x10;  // V4 swap
V3_POSITION_MANAGER_PERMIT    = 0x11;  // V3 Position Permit
V3_POSITION_MANAGER_CALL      = 0x12;  // V3 Position call
V4_INITIALIZE_POOL            = 0x13;  // V4 pool initialization
V4_POSITION_MANAGER_CALL      = 0x14;  // V4 Position call
// 0x15-0x20 - PLACEHOLDER

// Fourth block (0x21-0x3f)
EXECUTE_SUB_PLAN              = 0x21;  // Sub-plan execution
// 0x22-0x3f - PLACEHOLDER

// 3rd Party area (0x40-0x5f)
ACROSS_V4_DEPOSIT_V3          = 0x40;  // Across bridge integration
// 0x41-0x5f - PLACEHOLDER
```

### 1.4 Expected Future Expansion

#### 1.4.1 `0x07` Placeholder (First Block)

| Expected Command | Description |
|-----------------|-------------|
| `V3_SWAP_EXACT_IN_SINGLE` | Single pool exact input optimization (gas savings) |
| `PERMIT2_APPROVAL` | Unified approval command |
| `CALLBACK_HANDLER` | Flashloan/callback dedicated command |

#### 1.4.2 `0x0f` Placeholder (Second Block)

| Expected Command | Description |
|-----------------|-------------|
| `BALANCE_CHECK_NATIVE` | ETH balance verification |
| `MULTI_CALL_BATCH` | Multi-call batch optimization |
| `FEE_ON_TRANSFER_SWEEP` | Fee-on-transfer token handling |

#### 1.4.3 `0x15-0x20` Placeholders (V4 Area)

| Expected Command | Description |
|-----------------|-------------|
| `V4_POSITION_MANAGER_PERMIT` | V4 Position NFT Permit |
| `V4_DONATE` | Hook-based donation feature |
| `V4_FLASH_LOAN` | V4 native flash loan |
| `V4_HOOKS_CALLBACK` | Custom hook callback handling |
| `V4_ORACLE_INTEGRATION` | Oracle integration (TWAP, etc.) |
| `V4_MULTI_HOP_OPTIMIZED` | Multi-hop gas optimization |

#### 1.4.4 `0x22-0x3f` Placeholders (Sub-plan Area)

| Expected Command | Description |
|-----------------|-------------|
| `CONDITIONAL_EXECUTE` | Conditional execution (if-else logic) |
| `DEADLINE_CHECK` | Deadline verification command |
| `REVERT_ON_CONDITION` | Conditional revert |
| `MEV_PROTECTION` | MEV protection logic (slippage check) |
| `GAS_REBATE` | Gas rebate handling |
| `LOOP_EXECUTE` | Loop execution |

#### 1.4.5 `0x41-0x5f` Placeholders (3rd Party Area)

| Expected Command | Description |
|-----------------|-------------|
| `0x41` | Stargate bridge integration |
| `0x42` | LayerZero OFT swap |
| `0x43` | Chainlink CCIP integration |
| `0x44` | Axelar GMP integration |
| `0x45` | Wormhole integration |
| `0x46-0x5f` | Additional DEX/bridge integrations |

### 1.5 Design Pattern Insights

1. **Nested If-Block Optimization**
   - Commands grouped in sets of 8 for gas efficiency
   - Frequently used commands placed at lower numbers

2. **Extensibility Design**
   - 1-2 placeholder reserves in each block
   - Features can be added while maintaining backward compatibility

3. **Version Separation**
   - V2, V3, V4 located in separate blocks
   - Independent upgrades possible per version

4. **Integration-Oriented**
   - Dedicated area for third-party (0x40+)
   - Easy ecosystem expansion

---

## 2. P256 Precompile Requirements (WebAuthnValidator)

### 2.1 Overview

WebAuthnValidator requires P256 (secp256r1) curve signature verification for WebAuthn/Passkey authentication. This is efficiently performed through the precompile defined in EIP-7212.

**File Location**: `src/erc7579-validators/WebAuthnValidator.sol`

### 2.2 EIP-7212 P256VERIFY Precompile Spec

#### Precompile Address
```
0x0000000000000000000000000000000000000100 (0x100)
```

#### Input Format (160 bytes)

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 32 bytes | `hash` | Message hash (SHA-256) |
| 32 | 32 bytes | `r` | Signature r value |
| 64 | 32 bytes | `s` | Signature s value |
| 96 | 32 bytes | `pubKeyX` | Public key X coordinate |
| 128 | 32 bytes | `pubKeyY` | Public key Y coordinate |

#### Output Format (32 bytes)

| Value | Meaning |
|-------|---------|
| `1` (uint256) | Valid signature |
| `0` or empty | Invalid signature |

### 2.3 Current Implementation

```solidity
function _verifyP256Signature(
    bytes32 hash,
    uint256 r,
    uint256 s,
    uint256 pubKeyX,
    uint256 pubKeyY
) internal view returns (bool) {
    // Call EIP-7212 P256VERIFY precompile
    bytes memory input = abi.encodePacked(hash, r, s, pubKeyX, pubKeyY);

    (bool success, bytes memory output) = address(0x100).staticcall(input);

    if (success && output.length == 32) {
        return abi.decode(output, (uint256)) == 1;
    }

    // Return false if precompile not supported
    return false;
}
```

### 2.4 Chain Support Status

| Chain | EIP-7212 Support | Status | Notes |
|-------|-----------------|--------|-------|
| Ethereum Mainnet | ❌ | Not supported | Under review for Pectra upgrade |
| Arbitrum One | ❌ | Not supported | No plans |
| Optimism | ❌ | Not supported | No plans |
| **Base** | ✅ | **Supported** | Precompile activated |
| **zkSync Era** | ✅ | **Supported** | Native support |
| **Polygon zkEVM** | ✅ | **Supported** | Native support |
| Scroll | ❌ | Not supported | Under review |
| Linea | ❌ | Not supported | Under review |

### 2.5 Fallback Options

For chains that don't support the precompile, use one of these libraries:

#### Option 1: FCL (Fresh Crypto Lib)

```solidity
import {FCL_Elliptic_ZZ} from "FreshCryptoLib/FCL_elliptic.sol";

function _verifyP256SignatureFCL(
    bytes32 hash,
    uint256 r,
    uint256 s,
    uint256 pubKeyX,
    uint256 pubKeyY
) internal view returns (bool) {
    return FCL_Elliptic_ZZ.ecdsa_verify(
        uint256(hash),
        r,
        s,
        pubKeyX,
        pubKeyY
    );
}
```

#### Option 2: Daimo P256Verifier

```solidity
import {P256Verifier} from "daimo-eth/P256Verifier.sol";

function _verifyP256SignatureDaimo(
    bytes32 hash,
    uint256 r,
    uint256 s,
    uint256 pubKeyX,
    uint256 pubKeyY
) internal view returns (bool) {
    return P256Verifier.verify(hash, r, s, pubKeyX, pubKeyY);
}
```

#### Option 3: Solady P256

```solidity
import {P256} from "solady/utils/P256.sol";

function _verifyP256SignatureSolady(
    bytes32 hash,
    uint256 r,
    uint256 s,
    uint256 pubKeyX,
    uint256 pubKeyY
) internal view returns (bool) {
    return P256.verify(hash, r, s, pubKeyX, pubKeyY);
}
```

### 2.6 Gas Cost Comparison

| Method | Estimated Gas Cost | Notes |
|--------|-------------------|-------|
| EIP-7212 Precompile | ~3,450 gas | Optimal |
| Daimo P256Verifier | ~100,000-150,000 gas | Optimized library |
| FCL Library | ~200,000-300,000 gas | General-purpose library |
| Solady P256 | ~150,000-200,000 gas | Gas optimized |

### 2.7 Recommended Implementation Strategy

```solidity
function _verifyP256Signature(
    bytes32 hash,
    uint256 r,
    uint256 s,
    uint256 pubKeyX,
    uint256 pubKeyY
) internal view returns (bool) {
    // 1. Try precompile first
    bytes memory input = abi.encodePacked(hash, r, s, pubKeyX, pubKeyY);
    (bool success, bytes memory output) = address(0x100).staticcall(input);

    if (success && output.length == 32) {
        return abi.decode(output, (uint256)) == 1;
    }

    // 2. Fallback: Use Solady P256 library
    return P256.verify(hash, r, s, pubKeyX, pubKeyY);
}
```

### 2.8 WebAuthn Signature Verification Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    WebAuthn Signature Verification Flow          │
└─────────────────────────────────────────────────────────────────┘

1. Receive User Operation
   └── signature = authenticatorData + clientDataJson + (r, s)

2. Challenge Verification
   └── Verify challenge(userOpHash) in clientDataJson

3. Calculate Message Hash
   └── messageHash = SHA256(authenticatorData || SHA256(clientDataJson))

4. P256 Signature Verification
   ├── Try EIP-7212 Precompile (0x100)
   │   └── Return result on success
   └── On failure, use Fallback library

5. Return Verification Result
   └── VALIDATION_SUCCESS (0) or VALIDATION_FAILED (1)
```

---

## 3. AutoSwapPlugin Simplification

### 3.1 Overview

AutoSwapPlugin is an ERC-7579 Executor plugin providing automated trading features like DCA (Dollar Cost Averaging), limit orders, and stop-loss. The current POC version has simplified swap execution logic.

**File Location**: `src/erc7579-plugins/AutoSwapPlugin.sol`

### 3.2 Current Implementation (Simplified Version)

```solidity
function _executeSwap(
    address account,
    Order storage order
) internal returns (uint256 amountOut) {
    // Simplified swap call data generation
    bytes memory swapCall = abi.encodeWithSignature(
        "swap(address,address,uint256,uint256,address)",
        order.tokenIn,
        order.tokenOut,
        order.amountIn,
        order.amountOutMin,
        account
    );

    // Execute through Smart Account
    bytes memory execData = abi.encodePacked(
        DEX_ROUTER,
        uint256(0),
        swapCall
    );

    ExecMode execMode = ExecMode.wrap(bytes32(0));
    bytes[] memory results = IERC7579Account(account).executeFromExecutor(
        execMode,
        execData
    );

    // Decode result
    if (results.length > 0 && results[0].length >= 32) {
        amountOut = abi.decode(results[0], (uint256));
    }
}
```

### 3.3 Simplified Components

| Item | Current (POC) | Production Requirement |
|------|---------------|----------------------|
| DEX Router | Fixed address (`DEX_ROUTER`) | Dynamic router selection |
| Swap Path | Single direct swap | Multi-hop optimal path |
| Price Validation | Basic slippage only | Oracle-based validation |
| Error Handling | Basic revert | Detailed error codes |
| Gas Optimization | None | Batch processing, path caching |
| DEX Integration | Single DEX | Multi-DEX aggregation |

### 3.4 Production Implementation Requirements

#### 3.4.1 DEXIntegration Contract Integration

```solidity
interface IDEXIntegration {
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint24 poolFee,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function swapExactInputMultihop(
        bytes memory path,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);
}
```

### 3.5 Architecture Comparison

#### POC Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    POC Architecture                              │
└─────────────────────────────────────────────────────────────────┘

┌──────────────┐    ┌──────────────────┐    ┌──────────────┐
│ AutoSwap     │───▶│ Smart Account    │───▶│ DEX Router   │
│ Plugin       │    │ (ERC-7579)       │    │ (Fixed)      │
└──────────────┘    └──────────────────┘    └──────────────┘
       │
       ▼
  Single Direct Swap
```

#### Production Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                 Production Architecture                          │
└─────────────────────────────────────────────────────────────────┘

┌──────────────┐    ┌──────────────────┐    ┌──────────────────┐
│ AutoSwap     │───▶│ DEXIntegration   │───▶│ Route Optimizer  │
│ Plugin       │    │ Contract         │    │                  │
└──────────────┘    └──────────────────┘    └──────────────────┘
                            │                        │
                            ▼                        ▼
                    ┌──────────────┐         ┌──────────────┐
                    │ Smart Account│         │ Price Oracle │
                    │ (ERC-7579)   │         │              │
                    └──────────────┘         └──────────────┘
                            │
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
     ┌──────────┐    ┌──────────┐    ┌──────────┐
     │ Uniswap  │    │ Sushi    │    │ Curve    │
     │ V3       │    │ Swap     │    │          │
     └──────────┘    └──────────┘    └──────────┘
```

### 3.6 Reasons for Simplification

1. **POC Objective Achievement**: Focus on validating core logic (order triggers, state management, execution flow)
2. **Complexity Separation**: DEX integration complexity separated into dedicated contracts
3. **Test Ease**: Simple interface makes unit test writing easier
4. **Rapid Prototyping**: Add production features after basic functionality validation

---

## 4. FraudProofVerifier Signature Verification

### 4.1 Overview

FraudProofVerifier's `_verifyInvalidSignatureProof` function verifies signature validity of bridge requests to determine fraud proof.

**File Location**: `src/bridge/FraudProofVerifier.sol`

### 4.2 Implementation Details

```solidity
/**
 * @notice Verify invalid signature proof
 * @dev Fraud proof is valid if signatures do NOT pass BridgeValidator verification
 * @param proof The fraud proof containing BridgeMessage and signatures
 * @return isValid True if fraud is proven (signatures are invalid)
 *
 * Evidence format: abi.encode(BridgeValidator.BridgeMessage, bytes[] signatures)
 */
function _verifyInvalidSignatureProof(FraudProof calldata proof) internal view returns (bool) {
    if (proof.evidence.length == 0) return false;
    if (bridgeValidator == address(0)) revert ZeroAddress();

    // Decode evidence: BridgeMessage struct + signatures array
    (
        BridgeValidator.BridgeMessage memory message,
        bytes[] memory signatures
    ) = abi.decode(proof.evidence, (BridgeValidator.BridgeMessage, bytes[]));

    // Basic validation
    if (signatures.length == 0) return false;

    // Verify signatures through BridgeValidator
    try BridgeValidator(bridgeValidator).verifySignaturesView(message, signatures) returns (
        bool valid,
        uint256 validCount
    ) {
        // Fraud proof succeeds if signatures are invalid
        if (!valid) {
            return true;
        }

        // Check requestId mismatch
        if (message.requestId != proof.requestId) {
            return true;
        }

        return false; // Valid signatures → Not fraud
    } catch {
        // Call failure is considered fraud evidence
        return true;
    }
}
```

### 4.3 Evidence Format

```solidity
// Evidence encoding
bytes memory evidence = abi.encode(
    BridgeValidator.BridgeMessage({
        requestId: requestId,
        sender: sender,
        recipient: recipient,
        token: token,
        amount: amount,
        sourceChain: sourceChain,
        targetChain: targetChain,
        nonce: nonce,
        deadline: deadline
    }),
    signatures  // bytes[] - MPC signature array
);
```

### 4.4 Verification Logic Flow

```
┌─────────────────────────────────────────────────────────────────┐
│              Invalid Signature Proof Verification Flow           │
└─────────────────────────────────────────────────────────────────┘

1. Decode Evidence
   └── Extract BridgeMessage + signatures

2. Basic Validation
   ├── evidence length > 0
   ├── bridgeValidator address is set
   └── signatures array not empty

3. Call BridgeValidator.verifySignaturesView()
   ├── Calculate message hash (EIP-712)
   ├── Recover signer from each signature
   └── Check threshold compliance

4. Determine Result
   ├── Invalid signatures (valid=false) → Fraud proof succeeds
   ├── requestId mismatch → Fraud proof succeeds
   ├── Call failure (catch) → Fraud proof succeeds
   └── Valid signatures → Not fraud

5. Return Result
   └── true: Fraud proven / false: Not fraud
```

---

## Change History

| Date | Version | Description |
|------|---------|-------------|
| 2024-01-20 | 1.0.0 | Initial documentation |

---

## References

- [EIP-7212: Precompiled contract for secp256r1 curve support](https://eips.ethereum.org/EIPS/eip-7212)
- [ERC-7579: Minimal Modular Smart Accounts](https://eips.ethereum.org/EIPS/eip-7579)
- [Uniswap Universal Router](https://github.com/Uniswap/universal-router)
- [WebAuthn Specification](https://www.w3.org/TR/webauthn-2/)
