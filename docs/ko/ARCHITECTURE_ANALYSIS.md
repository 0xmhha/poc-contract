# POC Contract Architecture Analysis

본 문서는 POC 컨트랙트의 주요 설계 결정사항, placeholder 분석, 그리고 향후 프로덕션 구현 시 고려해야 할 사항들을 정리합니다.

## 목차

1. [Universal Router Command Placeholders](#1-universal-router-command-placeholders)
2. [P256 Precompile 요구사항 (WebAuthnValidator)](#2-p256-precompile-요구사항-webauthnvalidator)
3. [AutoSwapPlugin 단순화 설명](#3-autoswapplugin-단순화-설명)
4. [FraudProofVerifier 서명 검증](#4-fraudproofverifier-서명-검증)

---

## 1. Universal Router Command Placeholders

### 1.1 개요

Universal Router의 `Commands.sol`은 라우터가 실행할 수 있는 명령어들을 정의합니다. Uniswap은 향후 확장을 위해 여러 placeholder 슬롯을 예약해 두었습니다.

**파일 위치**: `src/dex/universal-router/libraries/Commands.sol`

### 1.2 현재 Command 구조

| 범위 | 용도 | 사용된 슬롯 | Placeholder |
|------|------|------------|-------------|
| `0x00-0x07` | V3 Swap & 기본 작업 | 0x00-0x06 | **0x07** |
| `0x08-0x0f` | V2 Swap & Permit | 0x08-0x0e | **0x0f** |
| `0x10-0x20` | V4 & Position Manager | 0x10-0x14 | **0x15-0x20** |
| `0x21-0x3f` | Sub-plan 실행 | 0x21 | **0x22-0x3f** |
| `0x40-0x5f` | 3rd party 통합 | 0x40 (Across) | **0x41-0x5f** |

### 1.3 현재 구현된 Commands

```solidity
// 첫 번째 블록 (0x00-0x07)
V3_SWAP_EXACT_IN       = 0x00;  // V3 정확한 입력 스왑
V3_SWAP_EXACT_OUT      = 0x01;  // V3 정확한 출력 스왑
PERMIT2_TRANSFER_FROM  = 0x02;  // Permit2 전송
PERMIT2_PERMIT_BATCH   = 0x03;  // Permit2 배치 승인
SWEEP                  = 0x04;  // 토큰 스윕
TRANSFER               = 0x05;  // 토큰 전송
PAY_PORTION            = 0x06;  // 비율 지불
// 0x07 - PLACEHOLDER

// 두 번째 블록 (0x08-0x0f)
V2_SWAP_EXACT_IN              = 0x08;  // V2 정확한 입력 스왑
V2_SWAP_EXACT_OUT             = 0x09;  // V2 정확한 출력 스왑
PERMIT2_PERMIT                = 0x0a;  // Permit2 단일 승인
WRAP_ETH                      = 0x0b;  // ETH → WETH
UNWRAP_WETH                   = 0x0c;  // WETH → ETH
PERMIT2_TRANSFER_FROM_BATCH   = 0x0d;  // Permit2 배치 전송
BALANCE_CHECK_ERC20           = 0x0e;  // ERC20 잔액 확인
// 0x0f - PLACEHOLDER

// 세 번째 블록 (0x10-0x20)
V4_SWAP                       = 0x10;  // V4 스왑
V3_POSITION_MANAGER_PERMIT    = 0x11;  // V3 Position Permit
V3_POSITION_MANAGER_CALL      = 0x12;  // V3 Position 호출
V4_INITIALIZE_POOL            = 0x13;  // V4 풀 초기화
V4_POSITION_MANAGER_CALL      = 0x14;  // V4 Position 호출
// 0x15-0x20 - PLACEHOLDER

// 네 번째 블록 (0x21-0x3f)
EXECUTE_SUB_PLAN              = 0x21;  // 서브플랜 실행
// 0x22-0x3f - PLACEHOLDER

// 3rd Party 영역 (0x40-0x5f)
ACROSS_V4_DEPOSIT_V3          = 0x40;  // Across 브릿지 통합
// 0x41-0x5f - PLACEHOLDER
```

### 1.4 예상되는 향후 확장

#### 1.4.1 `0x07` Placeholder (첫 번째 블록)

| 예상 Command | 설명 |
|-------------|------|
| `V3_SWAP_EXACT_IN_SINGLE` | 단일 풀 exact input 최적화 (가스 절약) |
| `PERMIT2_APPROVAL` | 통합 승인 커맨드 |
| `CALLBACK_HANDLER` | 플래시론/콜백 전용 커맨드 |

#### 1.4.2 `0x0f` Placeholder (두 번째 블록)

| 예상 Command | 설명 |
|-------------|------|
| `BALANCE_CHECK_NATIVE` | ETH 잔액 검증 |
| `MULTI_CALL_BATCH` | 다중 호출 배치 최적화 |
| `FEE_ON_TRANSFER_SWEEP` | Fee-on-transfer 토큰 처리 |

#### 1.4.3 `0x15-0x20` Placeholders (V4 영역)

| 예상 Command | 설명 |
|-------------|------|
| `V4_POSITION_MANAGER_PERMIT` | V4 Position NFT Permit |
| `V4_DONATE` | Hook 기반 기부 기능 |
| `V4_FLASH_LOAN` | V4 네이티브 플래시론 |
| `V4_HOOKS_CALLBACK` | 커스텀 훅 콜백 처리 |
| `V4_ORACLE_INTEGRATION` | 오라클 통합 (TWAP 등) |
| `V4_MULTI_HOP_OPTIMIZED` | 다중 홉 가스 최적화 |

#### 1.4.4 `0x22-0x3f` Placeholders (서브플랜 영역)

| 예상 Command | 설명 |
|-------------|------|
| `CONDITIONAL_EXECUTE` | 조건부 실행 (if-else 로직) |
| `DEADLINE_CHECK` | 마감 시간 검증 커맨드 |
| `REVERT_ON_CONDITION` | 조건부 리버트 |
| `MEV_PROTECTION` | MEV 보호 로직 (슬리피지 체크) |
| `GAS_REBATE` | 가스 환불 처리 |
| `LOOP_EXECUTE` | 반복 실행 |

#### 1.4.5 `0x41-0x5f` Placeholders (3rd Party 영역)

| 예상 Command | 설명 |
|-------------|------|
| `0x41` | Stargate 브릿지 통합 |
| `0x42` | LayerZero OFT 스왑 |
| `0x43` | Chainlink CCIP 통합 |
| `0x44` | Axelar GMP 통합 |
| `0x45` | Wormhole 통합 |
| `0x46-0x5f` | 추가 DEX/브릿지 통합 |

### 1.5 설계 패턴 인사이트

1. **Nested If-Block 최적화**
   - 커맨드를 8개씩 그룹화하여 가스 효율 극대화
   - 자주 사용되는 커맨드를 낮은 번호에 배치

2. **확장성 설계**
   - 각 블록에 1-2개 placeholder 예비
   - 하위 호환성 유지하면서 기능 추가 가능

3. **버전 분리**
   - V2, V3, V4가 별도 블록에 위치
   - 버전별 독립적 업그레이드 가능

4. **통합 지향**
   - Third-party를 위한 전용 영역 (0x40+)
   - 에코시스템 확장 용이

---

## 2. P256 Precompile 요구사항 (WebAuthnValidator)

### 2.1 개요

WebAuthnValidator는 WebAuthn/Passkey 인증을 위해 P256 (secp256r1) 곡선 서명 검증이 필요합니다. 이는 EIP-7212에서 정의한 precompile을 통해 효율적으로 수행됩니다.

**파일 위치**: `src/erc7579-validators/WebAuthnValidator.sol`

### 2.2 EIP-7212 P256VERIFY Precompile 스펙

#### Precompile 주소
```
0x0000000000000000000000000000000000000100 (0x100)
```

#### 입력 포맷 (160 bytes)

| 오프셋 | 크기 | 필드 | 설명 |
|--------|------|------|------|
| 0 | 32 bytes | `hash` | 메시지 해시 (SHA-256) |
| 32 | 32 bytes | `r` | 서명 r 값 |
| 64 | 32 bytes | `s` | 서명 s 값 |
| 96 | 32 bytes | `pubKeyX` | 공개키 X 좌표 |
| 128 | 32 bytes | `pubKeyY` | 공개키 Y 좌표 |

#### 출력 포맷 (32 bytes)

| 값 | 의미 |
|----|------|
| `1` (uint256) | 유효한 서명 |
| `0` 또는 empty | 유효하지 않은 서명 |

### 2.3 현재 구현

```solidity
function _verifyP256Signature(
    bytes32 hash,
    uint256 r,
    uint256 s,
    uint256 pubKeyX,
    uint256 pubKeyY
) internal view returns (bool) {
    // EIP-7212 P256VERIFY precompile 호출
    bytes memory input = abi.encodePacked(hash, r, s, pubKeyX, pubKeyY);

    (bool success, bytes memory output) = address(0x100).staticcall(input);

    if (success && output.length == 32) {
        return abi.decode(output, (uint256)) == 1;
    }

    // Precompile 미지원 시 false 반환
    return false;
}
```

### 2.4 체인별 지원 현황

| 체인 | EIP-7212 지원 | 상태 | 비고 |
|------|--------------|------|------|
| Ethereum Mainnet | ❌ | 미지원 | Pectra 업그레이드에서 검토 중 |
| Arbitrum One | ❌ | 미지원 | 계획 없음 |
| Optimism | ❌ | 미지원 | 계획 없음 |
| **Base** | ✅ | **지원** | Precompile 활성화됨 |
| **zkSync Era** | ✅ | **지원** | Native 지원 |
| **Polygon zkEVM** | ✅ | **지원** | Native 지원 |
| Scroll | ❌ | 미지원 | 검토 중 |
| Linea | ❌ | 미지원 | 검토 중 |

### 2.5 Fallback 옵션

Precompile이 지원되지 않는 체인에서는 다음 라이브러리 중 하나를 사용할 수 있습니다:

#### 옵션 1: FCL (Fresh Crypto Lib)

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

#### 옵션 2: Daimo P256Verifier

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

#### 옵션 3: Solady P256

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

### 2.6 가스 비용 비교

| 방식 | 예상 가스 비용 | 비고 |
|------|---------------|------|
| EIP-7212 Precompile | ~3,450 gas | 최적 |
| Daimo P256Verifier | ~100,000-150,000 gas | 최적화된 라이브러리 |
| FCL Library | ~200,000-300,000 gas | 범용 라이브러리 |
| Solady P256 | ~150,000-200,000 gas | 가스 최적화 |

### 2.7 권장 구현 전략

```solidity
function _verifyP256Signature(
    bytes32 hash,
    uint256 r,
    uint256 s,
    uint256 pubKeyX,
    uint256 pubKeyY
) internal view returns (bool) {
    // 1. 먼저 precompile 시도
    bytes memory input = abi.encodePacked(hash, r, s, pubKeyX, pubKeyY);
    (bool success, bytes memory output) = address(0x100).staticcall(input);

    if (success && output.length == 32) {
        return abi.decode(output, (uint256)) == 1;
    }

    // 2. Fallback: Solady P256 라이브러리 사용
    return P256.verify(hash, r, s, pubKeyX, pubKeyY);
}
```

### 2.8 WebAuthn 서명 검증 플로우

```
┌─────────────────────────────────────────────────────────────────┐
│                    WebAuthn 서명 검증 플로우                      │
└─────────────────────────────────────────────────────────────────┘

1. User Operation 수신
   └── signature = authenticatorData + clientDataJson + (r, s)

2. Challenge 검증
   └── clientDataJson에서 challenge(userOpHash) 확인

3. 메시지 해시 계산
   └── messageHash = SHA256(authenticatorData || SHA256(clientDataJson))

4. P256 서명 검증
   ├── EIP-7212 Precompile 시도 (0x100)
   │   └── 성공 시 결과 반환
   └── 실패 시 Fallback 라이브러리 사용

5. 검증 결과 반환
   └── VALIDATION_SUCCESS (0) 또는 VALIDATION_FAILED (1)
```

---

## 3. AutoSwapPlugin 단순화 설명

### 3.1 개요

AutoSwapPlugin은 ERC-7579 Executor 플러그인으로, DCA(Dollar Cost Averaging), 지정가 주문, 손절매 등의 자동화된 거래 기능을 제공합니다. 현재 POC 버전에서는 스왑 실행 로직이 단순화되어 있습니다.

**파일 위치**: `src/erc7579-plugins/AutoSwapPlugin.sol`

### 3.2 현재 구현 (단순화 버전)

```solidity
function _executeSwap(
    address account,
    Order storage order
) internal returns (uint256 amountOut) {
    // 단순화된 swap 호출 데이터 생성
    bytes memory swapCall = abi.encodeWithSignature(
        "swap(address,address,uint256,uint256,address)",
        order.tokenIn,
        order.tokenOut,
        order.amountIn,
        order.amountOutMin,
        account
    );

    // Smart Account를 통해 실행
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

    // 결과 디코딩
    if (results.length > 0 && results[0].length >= 32) {
        amountOut = abi.decode(results[0], (uint256));
    }
}
```

### 3.3 단순화된 부분

| 항목 | 현재 (POC) | 프로덕션 요구사항 |
|------|-----------|------------------|
| DEX 라우터 | 고정 주소 (`DEX_ROUTER`) | 동적 라우터 선택 |
| 스왑 경로 | 단일 직접 스왑 | 멀티홉 최적 경로 |
| 가격 검증 | 기본 slippage만 | 오라클 기반 검증 |
| 에러 처리 | 기본 revert | 상세 에러 코드 |
| 가스 최적화 | 없음 | 배치 처리, 경로 캐싱 |
| DEX 통합 | 단일 DEX | 다중 DEX 어그리게이션 |

### 3.4 프로덕션 구현 요구사항

#### 3.4.1 DEXIntegration 컨트랙트 통합

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

function _executeSwap(
    address account,
    Order storage order
) internal returns (uint256 amountOut) {
    // DEXIntegration 컨트랙트 사용
    bytes memory swapCall = abi.encodeCall(
        IDEXIntegration.swapExactInput,
        (
            order.tokenIn,
            order.tokenOut,
            order.amountIn,
            order.amountOutMin,
            order.poolFee,
            account,
            block.timestamp + 300
        )
    );

    // ... 실행 로직
}
```

#### 3.4.2 다중 DEX 라우팅

```solidity
struct SwapRoute {
    address[] path;
    uint24[] fees;
    address dex;
    uint256 expectedOutput;
}

function _findBestRoute(
    address tokenIn,
    address tokenOut,
    uint256 amountIn
) internal view returns (SwapRoute memory bestRoute) {
    // Uniswap V3 경로 확인
    SwapRoute memory v3Route = _getV3Route(tokenIn, tokenOut, amountIn);

    // Uniswap V2 경로 확인
    SwapRoute memory v2Route = _getV2Route(tokenIn, tokenOut, amountIn);

    // SushiSwap 경로 확인
    SwapRoute memory sushiRoute = _getSushiRoute(tokenIn, tokenOut, amountIn);

    // 최적 경로 선택
    if (v3Route.expectedOutput >= v2Route.expectedOutput &&
        v3Route.expectedOutput >= sushiRoute.expectedOutput) {
        return v3Route;
    } else if (v2Route.expectedOutput >= sushiRoute.expectedOutput) {
        return v2Route;
    } else {
        return sushiRoute;
    }
}
```

#### 3.4.3 멀티홉 스왑

```solidity
function _executeMultihopSwap(
    address account,
    Order storage order,
    SwapRoute memory route
) internal returns (uint256 amountOut) {
    // 경로 인코딩 (V3 스타일)
    bytes memory path = _encodePath(route.path, route.fees);

    ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
        path: path,
        recipient: account,
        deadline: block.timestamp + 300,
        amountIn: order.amountIn,
        amountOutMinimum: order.amountOutMin
    });

    bytes memory swapCall = abi.encodeCall(
        ISwapRouter.exactInput,
        params
    );

    // Smart Account를 통해 실행
    // ...
}

function _encodePath(
    address[] memory tokens,
    uint24[] memory fees
) internal pure returns (bytes memory path) {
    require(tokens.length == fees.length + 1, "Invalid path");

    path = abi.encodePacked(tokens[0]);
    for (uint256 i = 0; i < fees.length; i++) {
        path = abi.encodePacked(path, fees[i], tokens[i + 1]);
    }
}
```

#### 3.4.4 오라클 기반 슬리피지 보호

```solidity
interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
}

function _executeSwapWithOracleProtection(
    address account,
    Order storage order
) internal returns (uint256 amountOut) {
    // 오라클 가격 조회
    uint256 priceIn = oracle.getPrice(order.tokenIn);
    uint256 priceOut = oracle.getPrice(order.tokenOut);

    // 예상 출력 계산
    uint256 expectedOut = (order.amountIn * priceIn) / priceOut;

    // 최대 허용 슬리피지 (예: 1%)
    uint256 minAcceptable = expectedOut * (100 - maxSlippageBps) / 100;

    // 스왑 실행
    amountOut = _executeSwap(account, order);

    // 슬리피지 검증
    require(amountOut >= minAcceptable, "Excessive slippage");

    return amountOut;
}
```

#### 3.4.5 배치 처리 및 가스 최적화

```solidity
function executeOrdersBatch(
    address account,
    bytes32[] calldata orderIds
) external returns (uint256[] memory amountsOut) {
    amountsOut = new uint256[](orderIds.length);

    // 동일 토큰 쌍 그룹화
    OrderGroup[] memory groups = _groupOrders(account, orderIds);

    for (uint256 i = 0; i < groups.length; i++) {
        // 그룹별 단일 스왑 실행 (가스 절약)
        uint256 totalAmountIn = _sumAmounts(groups[i]);
        uint256 totalAmountOut = _executeGroupSwap(account, groups[i], totalAmountIn);

        // 결과 분배
        _distributeResults(groups[i], totalAmountOut, amountsOut);
    }
}
```

### 3.5 아키텍처 비교

#### POC 아키텍처

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
  단일 직접 스왑
```

#### 프로덕션 아키텍처

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

### 3.6 단순화의 이유

1. **POC 목적 달성**: 핵심 로직(주문 트리거, 상태 관리, 실행 플로우) 검증에 집중
2. **복잡성 분리**: DEX 통합의 복잡성을 별도 컨트랙트로 분리
3. **테스트 용이성**: 단순한 인터페이스로 단위 테스트 작성 용이
4. **빠른 프로토타이핑**: 기본 기능 검증 후 프로덕션 기능 추가 가능

---

## 4. FraudProofVerifier 서명 검증

### 4.1 개요

FraudProofVerifier의 `_verifyInvalidSignatureProof` 함수는 브릿지 요청의 서명 유효성을 검증하여 사기 증명을 판단합니다.

**파일 위치**: `src/bridge/FraudProofVerifier.sol`

### 4.2 구현 상세

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

    // Evidence 디코딩: BridgeMessage 구조체 + signatures 배열
    (
        BridgeValidator.BridgeMessage memory message,
        bytes[] memory signatures
    ) = abi.decode(proof.evidence, (BridgeValidator.BridgeMessage, bytes[]));

    // 기본 검증
    if (signatures.length == 0) return false;

    // BridgeValidator를 통한 서명 검증
    try BridgeValidator(bridgeValidator).verifySignaturesView(message, signatures) returns (
        bool valid,
        uint256 validCount
    ) {
        // 서명이 유효하지 않으면 사기 증명 성공
        if (!valid) {
            return true;
        }

        // requestId 불일치 확인
        if (message.requestId != proof.requestId) {
            return true;
        }

        return false; // 서명 유효 → 사기 아님
    } catch {
        // 호출 실패 시 사기 증거로 간주
        return true;
    }
}
```

### 4.3 Evidence 포맷

```solidity
// Evidence 인코딩
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
    signatures  // bytes[] - MPC 서명 배열
);
```

### 4.4 검증 로직 플로우

```
┌─────────────────────────────────────────────────────────────────┐
│              Invalid Signature Proof 검증 플로우                  │
└─────────────────────────────────────────────────────────────────┘

1. Evidence 디코딩
   └── BridgeMessage + signatures 추출

2. 기본 검증
   ├── evidence 길이 > 0
   ├── bridgeValidator 주소 설정됨
   └── signatures 배열 비어있지 않음

3. BridgeValidator.verifySignaturesView() 호출
   ├── 메시지 해시 계산 (EIP-712)
   ├── 각 서명 복구 및 signer 확인
   └── threshold 충족 여부 확인

4. 결과 판단
   ├── 서명 무효 (valid=false) → 사기 증명 성공
   ├── requestId 불일치 → 사기 증명 성공
   ├── 호출 실패 (catch) → 사기 증명 성공
   └── 서명 유효 → 사기 아님

5. 결과 반환
   └── true: 사기 증명됨 / false: 사기 아님
```

---

## 변경 이력

| 날짜 | 버전 | 설명 |
|------|------|------|
| 2024-01-20 | 1.0.0 | 초기 문서 작성 |

---

## 참고 자료

- [EIP-7212: Precompiled contract for secp256r1 curve support](https://eips.ethereum.org/EIPS/eip-7212)
- [ERC-7579: Minimal Modular Smart Accounts](https://eips.ethereum.org/EIPS/eip-7579)
- [Uniswap Universal Router](https://github.com/Uniswap/universal-router)
- [WebAuthn Specification](https://www.w3.org/TR/webauthn-2/)
