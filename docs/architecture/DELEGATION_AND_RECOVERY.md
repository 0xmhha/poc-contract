# Delegation & Recovery 아키텍처 결정 문서

> **작성일**: 2025-01-29
> **상태**: 승인 대기
> **관련 디렉토리**: `src/delegation/`, `src/erc7579-smartaccount/`, `src/erc7579-validators/`

---

## 1. 배경 및 문제점

### 1.1 현재 상태

프로젝트에 두 가지 위임/스마트 계정 시스템이 중복 구현되어 있음:

| 시스템 | 위치 | 용도 |
|--------|------|------|
| **ERC-7579 Kernel** | `src/erc7579-smartaccount/` | 모듈식 스마트 계정 |
| **DelegateKernel** | `src/delegation/` | EIP-7702 위임 계정 |

### 1.2 중복 분석 결과

```
기능 비교
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
기능                    │ Kernel + ERC-7579    │ DelegateKernel
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
스마트 계정 코어         │ ✅ Kernel.sol        │ ✅ DelegateKernel.sol
EIP-7702 지원           │ ✅ VALIDATION_TYPE_7702 │ ✅ 전용 구현
세션키/위임             │ ✅ SessionKeyExecutor │ ✅ DelegationRegistry
시간 제한               │ ✅ validAfter/Until   │ ✅ startTime/endTime
지출 한도               │ ✅ spendingLimit      │ ✅ spendingLimit
셀렉터 화이트리스트      │ ✅ Permission.selector│ ✅ allowedSelectors
ERC-1271 서명           │ ✅ isValidSignature   │ ✅ isValidSignature
Guardian 복구           │ ❌ 없음 (모듈 필요)   │ ✅ 내장
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**결론**: `src/delegation/`은 `Kernel + SessionKeyExecutor`와 대부분 중복됨

---

## 2. 아키텍처 결정

### 2.1 결정 사항

| 항목 | 결정 | 이유 |
|------|------|------|
| `src/delegation/` | **삭제** | 중복 코드, ERC-7579로 대체 가능 |
| Guardian 복구 | **하이브리드** | 안전성 + 유연성 균형 |
| Emergency Escape | **Kernel에 내장** | 최후의 안전장치 필요 |
| 일반 복구 | **모듈로 구현** | 업그레이드 가능성 확보 |

### 2.2 하이브리드 복구 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│                        Kernel.sol                           │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Emergency Escape Hatch (내장, ~50줄)                 │  │
│  │  ─────────────────────────────────────────────────────│  │
│  │  • emergencyRecoveryAddress: 배포 시 설정, 불변       │  │
│  │  • EMERGENCY_DELAY: 30일                              │  │
│  │  • 조건: 30일 비활성 + emergencyRecoveryAddress 호출  │  │
│  │  • 역할: 모든 모듈이 실패해도 복구 가능한 최후 수단   │  │
│  └───────────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                    ERC-7579 Validator Modules               │
│  ┌─────────────────┐ ┌─────────────────┐ ┌───────────────┐  │
│  │ Guardian        │ │ Social          │ │ Timelock      │  │
│  │ Recovery        │ │ Recovery        │ │ Recovery      │  │
│  │ Validator       │ │ Validator       │ │ Validator     │  │
│  │ ───────────────│ │ ────────────────│ │ ──────────────│  │
│  │ • N-of-M 승인  │ │ • 친구 서명     │ │ • 시간 잠금   │  │
│  │ • 48시간 딜레이│ │ • 소셜 그래프   │ │ • 자동 실행   │  │
│  │ • 취소 가능    │ │ • 신뢰 점수     │ │ • 조건부 복구 │  │
│  └─────────────────┘ └─────────────────┘ └───────────────┘  │
│              ↑ 선택적 설치, 업그레이드 가능                  │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 왜 하이브리드인가?

#### 모듈만 사용할 때의 위험

```
시나리오: 복구 모듈 버그 발생
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. GuardianRecoveryValidator 설치
2. 모듈에 치명적 버그 발견
3. 복구 시도 → 실패
4. rootValidator 접근 불가
5. 계정 영구 잠금
6. ❌ 자금 손실
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### 하이브리드 사용 시

```
시나리오: 복구 모듈 버그 발생
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. GuardianRecoveryValidator 설치
2. 모듈에 치명적 버그 발견
3. 복구 시도 → 실패
4. 30일 대기
5. Emergency Escape 사용
6. ✅ 계정 복구 성공
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 3. 구현 계획

### 3.1 Phase 1: 중복 코드 삭제

```bash
# 삭제 대상
rm -rf src/delegation/DelegateKernel.sol
rm -rf src/delegation/DelegationRegistry.sol

# 관련 테스트도 삭제
rm -rf test/delegation/

# 배포 스크립트에서 제거
# script/deploy-contract/에서 delegation 관련 코드 제거
```

### 3.2 Phase 2: Kernel Emergency Escape 추가

```solidity
// src/erc7579-smartaccount/Kernel.sol 수정

contract Kernel is IAccount, IAccountExecute, IERC7579Account, ValidationManager {
    // ============ Emergency Recovery ============

    /// @notice 비상 복구 주소 (배포 시 설정, 불변)
    address public immutable emergencyRecoveryAddress;

    /// @notice 마지막 활동 시간
    uint256 public lastActivityTimestamp;

    /// @notice 비상 복구 딜레이 (30일)
    uint256 public constant EMERGENCY_DELAY = 30 days;

    /// @notice 활동 기록 modifier
    modifier recordActivity() {
        lastActivityTimestamp = block.timestamp;
        _;
    }

    /// @notice 비상 복구 실행
    /// @dev 30일 비활성 상태에서만 emergencyRecoveryAddress가 호출 가능
    /// @param newRootValidator 새로운 root validator
    function emergencyRecovery(ValidationId newRootValidator) external {
        if (msg.sender != emergencyRecoveryAddress) {
            revert Unauthorized();
        }
        if (block.timestamp <= lastActivityTimestamp + EMERGENCY_DELAY) {
            revert RecoveryDelayNotPassed();
        }
        if (ValidationId.unwrap(newRootValidator) == bytes21(0)) {
            revert InvalidValidator();
        }

        _setRootValidator(newRootValidator);
        lastActivityTimestamp = block.timestamp;

        emit EmergencyRecoveryExecuted(newRootValidator);
    }

    // 기존 함수들에 recordActivity modifier 추가
    function execute(...) external payable onlyEntryPointOrSelfOrRoot recordActivity { ... }
    function validateUserOp(...) external payable onlyEntryPoint recordActivity { ... }
}
```

### 3.3 Phase 3: GuardianRecoveryValidator 모듈 구현

```solidity
// src/erc7579-validators/GuardianRecoveryValidator.sol

contract GuardianRecoveryValidator is IValidator {

    struct GuardianConfig {
        address[] guardians;          // Guardian 목록
        uint256 threshold;            // 승인 필요 수 (N-of-M)
        uint256 recoveryDelay;        // 복구 딜레이 (예: 48시간)
    }

    struct RecoveryRequest {
        ValidationId newRootValidator;
        uint256 initiatedAt;
        uint256 approvalCount;
        mapping(address => bool) approvals;
    }

    // account => config
    mapping(address => GuardianConfig) public configs;

    // account => recovery request
    mapping(address => RecoveryRequest) public recoveryRequests;

    // ============ IValidator Implementation ============

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external returns (uint256 validationData);

    function isValidSignatureWithSender(
        address sender,
        bytes32 hash,
        bytes calldata signature
    ) external view returns (bytes4);

    // ============ Guardian Management ============

    function addGuardian(address guardian) external;
    function removeGuardian(address guardian) external;
    function updateThreshold(uint256 newThreshold) external;

    // ============ Recovery Flow ============

    function initiateRecovery(
        address account,
        ValidationId newRootValidator
    ) external;

    function approveRecovery(address account) external;

    function executeRecovery(address account) external;

    function cancelRecovery(address account) external;
}
```

### 3.4 Phase 4: 테스트 및 문서화

```
test/erc7579-validators/
└── GuardianRecoveryValidator.t.sol
    ├── test_InitializeWithGuardians
    ├── test_AddRemoveGuardian
    ├── test_InitiateRecovery
    ├── test_ApproveRecovery_ThresholdMet
    ├── test_ExecuteRecovery_AfterDelay
    ├── test_CancelRecovery_ByOwner
    ├── test_RevertWhen_DelayNotPassed
    ├── test_RevertWhen_ThresholdNotMet
    └── test_EmergencyEscape_WhenModuleFails
```

---

## 4. 최종 디렉토리 구조

```
src/
├── erc7579-smartaccount/
│   ├── Kernel.sol                      # + Emergency Escape (~50줄 추가)
│   ├── core/
│   │   ├── ValidationManager.sol
│   │   ├── ExecutorManager.sol
│   │   ├── HookManager.sol
│   │   └── SelectorManager.sol
│   └── ...
│
├── erc7579-validators/
│   ├── ECDSAValidator.sol
│   ├── MultiSigValidator.sol
│   ├── WeightedECDSAValidator.sol
│   ├── MultiChainValidator.sol
│   ├── WebAuthnValidator.sol
│   └── GuardianRecoveryValidator.sol   # 신규 추가
│
├── erc7579-executors/
│   ├── SessionKeyExecutor.sol          # 위임/세션키 기능 담당
│   └── RecurringPaymentExecutor.sol
│
└── delegation/                          # ❌ 삭제 예정
    ├── DelegateKernel.sol              # 삭제
    └── DelegationRegistry.sol          # 삭제
```

---

## 5. 마이그레이션 가이드

### 5.1 DelegateKernel 사용자 → Kernel 마이그레이션

| DelegateKernel 기능 | Kernel 대체 방법 |
|---------------------|------------------|
| `execute()` | `Kernel.execute()` |
| `executeBatch()` | `Kernel.execute()` with batch mode |
| `executeWithDelegation()` | `SessionKeyExecutor.executeAsSessionKey()` |
| `addGuardian()` | `GuardianRecoveryValidator.addGuardian()` |
| `initiateRecovery()` | `GuardianRecoveryValidator.initiateRecovery()` |
| EIP-7702 서명 | `VALIDATION_TYPE_7702` 사용 |

### 5.2 DelegationRegistry 사용자 → SessionKeyExecutor 마이그레이션

| DelegationRegistry 기능 | SessionKeyExecutor 대체 방법 |
|------------------------|------------------------------|
| `createDelegation()` | `addSessionKey()` + `grantPermission()` |
| `revokeDelegation()` | `revokeSessionKey()` |
| `useDelegation()` | 자동 추적 (spentAmount) |
| Spending limit | `spendingLimit` 파라미터 |
| Selector whitelist | `grantPermission(target, selector)` |

---

## 6. 결정 근거 요약

| 원칙 | 적용 |
|------|------|
| **DRY (Don't Repeat Yourself)** | 중복 코드 삭제 |
| **단일 책임 원칙** | 복구 로직을 전용 모듈로 분리 |
| **방어적 프로그래밍** | Emergency Escape로 최악의 상황 대비 |
| **표준 준수** | ERC-7579 모듈 시스템 활용 |
| **단순함이 보안** | Emergency Escape는 최소한의 단순 로직 |

---

## 7. 참고 자료

- [ERC-7579: Minimal Modular Smart Accounts](https://eips.ethereum.org/EIPS/eip-7579)
- [EIP-7702: Set EOA account code](https://eips.ethereum.org/EIPS/eip-7702)
- [ERC-4337: Account Abstraction](https://eips.ethereum.org/EIPS/eip-4337)
- [Kernel v3 Documentation](https://docs.zerodev.app/)

---

## 8. 변경 이력

| 날짜 | 변경 내용 | 작성자 |
|------|----------|--------|
| 2025-01-29 | 초안 작성 | - |
