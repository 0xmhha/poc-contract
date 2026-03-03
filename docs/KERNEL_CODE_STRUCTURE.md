# Kernel Contract 코드 구조 정리

> `src/erc7579-smartaccount/` 내 Kernel 관련 스마트 컨트랙트의 디렉터리·역할·의존 관계 정리

---

## 1. 디렉터리 구조 개요

```
src/erc7579-smartaccount/
├── Kernel.sol                    # 메인 Smart Account 구현체 (ERC-7579 + ERC-4337)
├── core/                         # 검증·실행·훅·셀렉터 관리 (추상 컨트랙트)
│   ├── ValidationManager.sol    # 루트/플러그인 검증, Permission, Nonce
│   ├── SelectorManager.sol      # fallback 셀렉터 → 모듈 매핑
│   ├── HookManager.sol          # preCheck/postCheck 훅 호출, Gas Limit 관리
│   └── ExecutorManager.sol      # Executor 등록 및 훅
├── factory/
│   ├── KernelFactory.sol        # ERC-1967 Proxy 계정 생성
│   └── FactoryStaker.sol        # EntryPoint 스테이킹 관리
├── interfaces/                   # ERC-4337 / ERC-7579 인터페이스
├── types/                        # Custom types, Constants, Structs
└── utils/                        # 라이브러리 및 헬퍼
```

---

## 2. 메인 컨트랙트: Kernel.sol

### 2.1 상속·구현 관계

```
Kernel
  implements: IAccount, IAccountExecute, IERC7579Account
  inherits:   ValidationManager
                ├── EIP712
                ├── SelectorManager
                ├── HookManager
                └── ExecutorManager
```

- **IAccount**: ERC-4337 `validateUserOp`, `isValidSignature`
- **IAccountExecute**: EntryPoint가 호출하는 `executeUserOp`
- **IERC7579Account**: `installModule`, `uninstallModule`, `execute`, `supportsModule` 등
- **ValidationManager**: EIP712 + SelectorManager + HookManager + ExecutorManager (검증·훅·실행·셀렉터 통합)

### 2.2 책임 구분

| 영역 | 함수·동작 | 비고 |
|------|-----------|------|
| **생명주기** | `initialize`, `changeRootValidator`, `upgradeTo` | EIP-7702 prefix 체크, 루트 Validator 설정 |
| **ERC-4337** | `validateUserOp`, `executeUserOp` | EntryPoint 전용 modifier, nonce 디코딩(v3), executionHook 저장 |
| **실행** | `execute`, `executeFromExecutor` | onlyEntryPointOrSelfOrRoot / Executor 훅 |
| **fallback** | `fallback()` | SelectorConfig → preHook → call/delegatecall → postHook |
| **모듈 관리** | `installModule`, `uninstallModule`, `forceUninstallModule`, `replaceModule` | 설치/제거/강제제거/원자적 교체 |
| **모듈 설정** | `grantAccess`, `installValidations`, `uninstallValidation`, `invalidateNonce` | Validator/Permission 세부 관리 |
| **보안 설정** | `setHookGasLimit`, `setDelegatecallWhitelist`, `setEnforceDelegatecallWhitelist` | Hook Gas Limit, Delegatecall 화이트리스트 |
| **수신·토큰** | `receive`, `onERC721Received`, `onERC1155Received`, `onERC1155BatchReceived` | ETH·NFT 수신 |
| **조회** | `supportsModule`, `isModuleInstalled`, `accountId`, `supportsExecutionMode` | ERC-7579 계정 ID `kernel.advanced.0.3.3` |

### 2.3 접근 제어

| Modifier | 적용 대상 | 동작 |
|----------|-----------|------|
| `onlyEntryPoint` | `validateUserOp`, `executeUserOp` | `msg.sender == ENTRYPOINT` 검사 |
| `onlyEntryPointOrSelfOrRoot` | `execute`, `installModule`, `uninstallModule`, `forceUninstallModule`, `replaceModule`, `changeRootValidator`, `upgradeTo` 등 | EntryPoint / self / root validator hook 기반 preCheck/postCheck |
| `nonReentrantModuleOp` | `installModule`, `uninstallModule`, `forceUninstallModule`, `replaceModule`, `installValidations` | EIP-1153 transient storage 기반 재진입 방지 |

### 2.4 이벤트

| 이벤트 | 발생 시점 |
|--------|-----------|
| `Received(address sender, uint256 amount)` | ETH 수신 (receive) |
| `Upgraded(address indexed implementation)` | upgradeTo 호출 시 |
| `ModuleInstalled(uint256 moduleTypeId, address module)` | 모듈 설치 완료 |
| `ModuleUninstalled(uint256 moduleTypeId, address module)` | 모듈 제거 완료 |
| `ModuleUninstallResult(uint256 moduleType, address module, bool onUninstallSuccess)` | forceUninstallModule 시 onUninstall 결과 |
| `DelegatecallWhitelistUpdated(address indexed target, bool allowed)` | delegatecall 화이트리스트 변경 |
| `DelegatecallWhitelistEnforced(bool enforce)` | 화이트리스트 적용 모드 변경 |
| `HookGasLimitSet(address indexed hook, uint256 gasLimit)` | Hook gas limit 설정 |
| `RootValidatorUpdated(ValidationId rootValidator)` | 루트 Validator 변경 |
| `ValidatorInstalled / ValidatorUninstalled` | Validator 설치/제거 |
| `SelectorSet(bytes4 selector, ValidationId vId, bool allowed)` | selector 접근 권한 변경 |

### 2.5 커스텀 에러

| 에러 | 용도 |
|------|------|
| `ExecutionReverted()` | 실행 revert |
| `InvalidExecutor()` | 미등록 Executor |
| `InvalidFallback()` | 잘못된 Fallback |
| `InvalidCallType()` | 미지원 CallType |
| `OnlyExecuteUserOp()` | executeUserOp만 허용되는 경로 |
| `InvalidModuleType()` | 잘못된 모듈 타입 |
| `InvalidCaller()` | 권한 없는 호출자 |
| `InvalidSelector()` | 잘못된 selector |
| `InitConfigError(uint256 idx)` | 초기화 설정 오류 |
| `AlreadyInitialized()` | 중복 초기화 |
| `ModuleAlreadyInstalled(uint256 moduleType, address module)` | 이미 설치된 모듈 |
| `ModuleNotInstalled(uint256 moduleType, address module)` | 미설치 모듈 |
| `ModuleOnUninstallFailed(uint256 moduleType, address module)` | onUninstall 실패 (uninstallModule에서 revert) |
| `ExecutorCannotCallSelf()` | Executor가 self 호출 시도 |
| `Reentrancy()` | 모듈 작업 재진입 감지 |
| `DelegatecallTargetNotWhitelisted(address target)` | 화이트리스트에 없는 delegatecall 대상 |

---

## 3. Core 계층 (추상 컨트랙트)

### 3.1 ValidationManager.sol

- **역할**: 루트 Validator, 플러그인 Validator/Permission, nonce, allowedSelectors, ERC-1271 검증
- **저장소**: `ValidationStorage` (slot `VALIDATION_MANAGER_STORAGE_SLOT`)
  - `rootValidator`, `currentNonce`, `validNonceFrom`
  - `validationConfig[ValidationId]` → `ValidationConfig{ nonce, hook }`
  - `allowedSelectors[vId][selector]`
  - `permissionConfig[PermissionId]` → `PermissionConfig{ permissionFlag, signer, policyData[] }`
- **주요 내부 함수**: `_validateUserOp`, `_setRootValidator`, `_installValidation` / `_installValidations`, `_grantAccess`, `_clearValidationData`, `_verifySignature`, `_invalidateNonce`, `_uninstallPermission`, `_installPermission`, `_toWrappedHash`, `_buildChainAgnosticDomainSeparator`
- **의존**: EIP712, SelectorManager, HookManager, ExecutorManager, ValidatorLib, KernelValidationResult, Constants

### 3.2 SelectorManager.sol

- **역할**: fallback에서 사용할 selector → (hook, target, callType) 매핑
- **저장소**: `SelectorStorage` (slot `SELECTOR_MANAGER_STORAGE_SLOT`)
  - `selectorConfig[bytes4]` → `SelectorConfig{ hook, target, callType }`
- **주요 내부 함수**: `_selectorConfig`, `_installSelector`, `_clearSelectorData`
- CallType: `CALLTYPE_SINGLE`(일반 call), `CALLTYPE_DELEGATECALL` 지원

### 3.3 HookManager.sol

- **역할**: 실행 전/후 훅 호출 (preCheck → context → postCheck), Hook Gas Limit 관리
- **저장소**:
  - `HookGasLimitStorage` (slot `_HOOK_GAS_LIMIT_SLOT`) — hook별 gas limit 매핑
  - Hook 참조는 ValidationManager/ExecutorManager/SelectorManager의 config에서 관리
- **주요 함수**: `_doPreHook`, `_doPostHook`, `_installHook`, `_uninstallHook`
- `_doPreHook`/`_doPostHook`: gas limit이 설정된 경우 해당 gas limit 내에서 hook 실행
- Hook 설치 시 `hookData[0] == 0xff`이면 명시적 onInstall; uninstall 시 `hookData[0] == 0xff`이면 onUninstall 호출

### 3.4 ExecutorManager.sol

- **역할**: Executor 등록 및 executor별 훅
- **저장소**: `ExecutorStorage` (slot `EXECUTOR_MANAGER_STORAGE_SLOT`)
  - `executorConfig[IExecutor]` → `ExecutorConfig{ hook }`
- **주요 내부 함수**: `_executorConfig`, `_installExecutor`, `_installExecutorWithoutInit`, `_clearExecutorData`

---

## 4. 모듈 관리 내부 함수

Kernel.sol의 모듈 관리 핵심 내부 함수:

| 함수 | 역할 |
|------|------|
| `_installModuleInternal(moduleType, module, initData)` | installModule/replaceModule 공통 설치 로직 (Validator/Executor/Fallback/Hook/Policy/Signer 분기) |
| `_prepareModuleUninstall(moduleType, module, deInitData)` | 모듈 설치 확인 및 deInitData offset 반환, 미설치 시 revert |
| `_clearModuleState(moduleType, module, deInitData)` | 모듈 상태 저장소 클리어 (Validator/Executor/Fallback 분기) |
| `_extractModuleHook(moduleType, module, deInitData)` | 모듈에 연결된 per-module hook 추출 |
| `_isActiveHook(hook)` | hook이 실제 컨트랙트인지 확인 (sentinel 값이 아닌지) |
| `_postCheckHook(hookRet)` | root validator hook의 postCheck 실행 |
| `_checkDelegatecallTarget(target)` | delegatecall 화이트리스트 검사 |

---

## 5. 보안 기능

### 5.1 Delegatecall Whitelist

- **저장소**: `DelegatecallWhitelistStorage` (slot `keccak256("kernel.delegatecallWhitelist")`)
  - `mapping(address => bool) allowed` — 허용된 delegatecall 대상
  - `bool enforceWhitelist` — 적용 여부 (기본값 false, 하위 호환)
- `execute()`와 `executeFromExecutor()`에서 CALLTYPE_DELEGATECALL 시 `_checkDelegatecallTarget()` 검사
- 미등록 대상에 delegatecall 시 `DelegatecallTargetNotWhitelisted` revert

### 5.2 Reentrancy Guard (nonReentrantModuleOp)

- EIP-1153 transient storage (`tload`/`tstore`) 기반
- `_MODULE_INSTALL_LOCK_SLOT` 사용
- `installModule`, `uninstallModule`, `forceUninstallModule`, `replaceModule`, `installValidations`에 적용
- 재진입 감지 시 `Reentrancy()` revert

### 5.3 2-Phase Module Uninstall

- **`uninstallModule`**: direct call로 `onUninstall` 호출 → 실패 시 `ModuleOnUninstallFailed` revert → 모듈이 제거를 거부 가능 (ERC-7579 준수)
- **`forceUninstallModule`**: 상태 먼저 클리어 → ExcessivelySafeCall로 `onUninstall` → 실패해도 제거 진행 (비상 탈출 경로)

---

## 6. Factory

### 6.1 KernelFactory.sol

- **역할**: ERC-1967 Proxy를 deterministic하게 생성
- **저장**: `IMPLEMENTATION` (immutable) — Kernel 구현체 주소
- **함수**:
  - `createAccount(bytes data, bytes32 salt)`: `actualSalt = keccak256(data, salt)` → `LibClone.createDeterministicERC1967` → 미배포 시 `account.call(data)`로 초기화
  - `getAddress(bytes data, bytes32 salt)`: 동일 salt로 생성될 주소 예측

### 6.2 FactoryStaker.sol

- **역할**: Factory의 EntryPoint 스테이킹 관리 (Ownable)
- 배포·운영 가이드는 `docs/KERNEL_ARCHITECTURE.md` 참고

---

## 7. 인터페이스 (interfaces/)

| 파일 | 용도 |
|------|------|
| **IAccount.sol** | `validateUserOp`, `isValidSignature` (ValidationData 반환) |
| **IAccountExecute.sol** | `executeUserOp(userOp, userOpHash)` |
| **IEntryPoint.sol** | ERC-4337 EntryPoint (IStakeManager, INonceManager 상속) |
| **IERC7579Account.sol** | install/uninstall module, execute, supportsModule, isModuleInstalled, accountId, supportsExecutionMode |
| **IERC7579Modules.sol** | IModule, IValidator, IExecutor, IHook, IFallback, IPolicy, ISigner |
| **PackedUserOperation.sol** | Packed UserOp 구조체 |
| **IStakeManager.sol**, **INonceManager.sol** | EntryPoint 의존 |
| **IPaymaster.sol**, **IAggregator.sol**, **IEntryPointSimulations.sol** | ERC-4337 확장 |

---

## 8. 타입·상수 (types/)

| 파일 | 내용 |
|------|------|
| **Types.sol** | ExecMode, CallType, ExecType, ExecModeSelector, ExecModePayload, ValidationMode, ValidationId, ValidationType, PermissionId, PolicyData, PassFlag, ValidationData 등 custom type 및 비교 함수 |
| **Constants.sol** | CALLTYPE_*, EXECTYPE_*, ValidationMode/Type, HOOK_*, EIP7702_PREFIX, Storage slot 상수, EIP712 type hash, MODULE_TYPE_* 등 |
| **Structs.sol** | InstallValidatorDataFormat, InstallExecutorDataFormat, InstallFallbackDataFormat, Permission 관련 구조체 등 |

---

## 9. 유틸리티 (utils/)

| 파일 | 역할 |
|------|------|
| **ValidationTypeLib.sol** | ValidatorLib: ValidationId↔Validator/PermissionId, getType, decodeNonce, validatorToIdentifier 등 |
| **ExecLib.sol** | execute(ExecMode, calldata), executeDelegatecall, doFallback2771Call, decode(mode) 등 실행 헬퍼 |
| **ModuleLib.sol** | 모듈 설치/제거 시 공통 호출 래퍼 (ExcessivelySafeCall 기반) |
| **KernelValidationResult.sol** | _intersectValidationData 등 검증 결과 조합 |
| **Utils.sol** | calldataKeccak, getSender 등 공용 유틸 |

---

## 10. 데이터 흐름 요약

1. **계정 생성**: KernelFactory.createAccount(initData, salt) → Proxy 배포 → Kernel.initialize(...)
2. **UserOp 검증**: EntryPoint → Kernel.validateUserOp → ValidatorLib.decodeNonce → _validateUserOp (Validator/Permission) → executionHook[userOpHash] 저장
3. **UserOp 실행**: EntryPoint → Kernel.executeUserOp → preHook(있으면) → ExecLib.executeDelegatecall(self, callData) → postHook
4. **fallback 호출**: selector → SelectorConfig → preHook(있으면) → call/delegatecall(target) → postHook
5. **Executor 실행**: Kernel.executeFromExecutor → _executorConfig(sender).hook 확인 → preHook → ExecLib.execute → postHook
6. **직접 실행**: Kernel.execute(execMode, calldata) — onlyEntryPointOrSelfOrRoot
7. **모듈 제거**: uninstallModule → _prepareModuleUninstall → direct call onUninstall → _clearModuleState → emit
8. **강제 제거**: forceUninstallModule → _prepareModuleUninstall → _clearModuleState → ExcessivelySafeCall onUninstall → emit
9. **모듈 교체**: replaceModule → _prepareModuleUninstall → _clearModuleState → _installModuleInternal (원자적)

---

## 11. 관련 파일 (프로젝트 내)

| 구분 | 경로 |
|------|------|
| 아키텍처 문서 | `docs/KERNEL_ARCHITECTURE.md` |
| 스펙 준수 검토 | `docs/KERNEL_SPEC_COMPLIANCE_REVIEW.md` |
| 모듈 설정 준수 | `docs/KERNEL_IERC7579_MODULE_CONFIG_COMPLIANCE.md` |
| 배포 스크립트 | `script/deploy-contract/DeployKernel.s.sol` |
| 테스트 | `test/erc7579-smartaccount/Kernel.t.sol` |
| Echidna | `test/echidna/EchidnaKernel.sol` |
| 검증 결과 타입 | `src/erc7579-smartaccount/utils/KernelValidationResult.sol` |

---

이 문서는 Kernel contract 코드의 구조를 분석·정리한 것이며, 배포·사용 방식·EIP-7702 통합은 `KERNEL_ARCHITECTURE.md`를 참고하면 된다.
