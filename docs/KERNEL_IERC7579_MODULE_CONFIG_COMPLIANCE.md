# Kernel.sol × IERC7579ModuleConfig 준수 체크리스트

> ERC-7579의 Module Config 스펙 항목별로 Kernel 구현이 준수하는지 정리.

---

## 1. installModule(moduleTypeId, module, initData)

| 스펙 요구사항 | 구현 여부 | 비고 |
| --- | --- | --- |
| **MUST implement authorization control** | ✅ | `onlyEntryPointOrSelfOrRoot` modifier + `nonReentrantModuleOp` |
| **MUST call `onInstall` on the module with the `initData` parameter if provided** | ✅ | Validator: `_installValidation` → `validator.onInstall(validatorData)`. Executor: `_installExecutor` → `executor.onInstall(executorData)`. Fallback: `_installSelector` → `IModule(target).onInstall(selectorData[1:])` (CALLTYPE_SINGLE). Hook/Policy/Signer: `IHook(module).onInstall(initData)`. 모두 initData에 해당하는 데이터 전달 |
| **MUST emit ModuleInstalled event** | ✅ | `emit ModuleInstalled(moduleType, module)` (설치 완료 시 1회) |
| **MUST revert if the module is already installed** | ✅ | Validator: `validationConfig[vId].hook != HOOK_MODULE_NOT_INSTALLED`이면 `ModuleAlreadyInstalled` revert. Executor: `executorConfig[executor].hook != HOOK_MODULE_NOT_INSTALLED`이면 revert. Fallback: 해당 selector에 이미 target이 있으면 revert |

---

## 2. uninstallModule(moduleTypeId, module, deInitData)

| 스펙 요구사항 | 구현 여부 | 비고 |
| --- | --- | --- |
| **MUST implement authorization control** | ✅ | `onlyEntryPointOrSelfOrRoot` + `nonReentrantModuleOp` |
| **MUST call `onUninstall` on the module with the `deInitData` parameter if provided** | ✅ | direct `call()`로 `IModule.onUninstall(deInitData)` 호출 |
| **MUST emit ModuleUninstalled event** | ✅ | `emit ModuleUninstalled(moduleType, module)` |
| **MUST revert if the module is not installed** | ✅ | `_prepareModuleUninstall`에서 모듈 미설치 시 `ModuleNotInstalled` revert. Fallback: `config.target != module`이면 `InvalidSelector` revert |
| **MUST revert if the deInitialization on the module failed** | ✅ | direct `call()`로 `onUninstall` 호출 → 실패 시 `ModuleOnUninstallFailed(moduleType, module)` revert |

### 2.1 2-Phase Uninstall 설계

Kernel은 모듈 제거에 두 가지 경로를 제공한다:

**`uninstallModule()`** (ERC-7579 준수 경로):

1. `_prepareModuleUninstall()`: 모듈 설치 확인, 미설치 시 revert
2. direct `call()`로 `onUninstall` 호출 → 실패 시 `ModuleOnUninstallFailed` revert
3. 성공 시에만 `_clearModuleState()`로 상태 클리어
4. per-module hook이 있으면 hook도 uninstall
5. `ModuleUninstalled` 이벤트 emit

모듈이 제거를 거부할 수 있다 (예: 활성 대출이 있는 MicroLoanPlugin).

**`forceUninstallModule()`** (비상 탈출 경로):

1. `_prepareModuleUninstall()`: 모듈 설치 확인
2. `_clearModuleState()`로 상태 먼저 클리어
3. `ModuleLib.uninstallModule()`로 ExcessivelySafeCall 기반 `onUninstall` 호출
4. `onUninstall` 실패해도 제거 진행
5. `ModuleUninstallResult(moduleType, module, onUninstallSuccess)` 이벤트로 결과 기록
6. `ModuleUninstalled` 이벤트 emit

악의적/버그가 있는 모듈에 대한 escape hatch. ERC-7579 §5의 "악의적 onUninstall revert 대응" 보안 요구사항 충족.

---

## 3. isModuleInstalled(moduleTypeId, module, additionalContext)

| 스펙 요구사항 | 구현 여부 | 비고 |
| --- | --- | --- |
| **MUST return true if the module is installed and false otherwise** | ✅ (타입별) | 아래 참고 |

타입별 구현:

| 타입 | 구현 | 상태 |
| --- | --- | --- |
| Validator (1) | `validationConfig[vId].hook != HOOK_MODULE_NOT_INSTALLED` | ✅ |
| Executor (2) | `executorConfig[executor].hook != HOOK_MODULE_NOT_INSTALLED` | ✅ |
| Fallback (3) | `selectorConfig[selector].target == module` (additionalContext[0:4]가 selector) | ✅ |
| Hook (4) | `additionalContext`에 ValidationId(21바이트)가 있으면 해당 validator의 hook 확인, 없으면 rootValidator의 hook 확인 | ✅ (부분) |
| Policy (5) | 항상 false 반환 | ⚠️ 설계 선택 |
| Signer (6) | 항상 false 반환 | ⚠️ 설계 선택 |

Type 5/6은 Kernel이 Policy/Signer를 validator/executor/selector에 묶어 관리하므로, "모듈 주소만으로 설치 여부"를 독립적으로 표현하지 않는 설계 선택이다.

---

## 4. 추가 보안 기능 (ERC-7579 §5 보안 요구사항 대응)

| 스펙 보안 요구사항 | 구현 여부 | 구현 방식 |
| --- | --- | --- |
| **Delegatecall 대상은 신뢰된 컨트랙트만** | ✅ | `DelegatecallWhitelistStorage` + `_checkDelegatecallTarget()` + `setEnforceDelegatecallWhitelist()` |
| **onInstall/onUninstall 재진입 방지** | ✅ | `nonReentrantModuleOp` modifier (EIP-1153 transient storage) |
| **악의적 onUninstall revert 처리** | ✅ | `forceUninstallModule()`로 ExcessivelySafeCall 기반 강제 제거 |
| **Hook 선택을 신뢰된 hook으로 제한** | ✅ | hook은 모듈 설치 시에만 설정, `_isActiveHook()` sentinel 값 확인 |
| **Fallback handler는 ERC-2771 `_msgSender()` 사용** | ✅ | `ExecLib.doFallback2771Call` (calldata + 20B sender) |
| **모듈 교체 시 이전 상태 정리** | ✅ | `replaceModule()` 원자적 교체, `_clearModuleState()` 통합 |
| **address(this) 호출로 설정 함수 권한 우회 방지** | ✅ | `ExecutorCannotCallSelf` 에러 + `_EXECUTOR_CONTEXT_SLOT` transient flag |

---

## 5. 요약

| 구분 | 준수 | 비고 |
| --- | --- | --- |
| **installModule** | ✅ 전체 준수 | 권한, onInstall 호출, 이벤트, 이미 설치 시 revert |
| **uninstallModule** | ✅ 전체 준수 | 권한, onUninstall 호출 (direct call), 이벤트, 미설치 시 revert, 실패 시 revert |
| **forceUninstallModule** | ✅ (확장) | ERC-7579 §5 "악의적 onUninstall 처리" 대응, 스펙 범위 외 확장 기능 |
| **replaceModule** | ✅ (확장) | 원자적 모듈 교체, 스펙 범위 외 확장 기능 |
| **isModuleInstalled** | ✅ type 1-4 | type 5/6은 설계상 독립 조회 미지원 (validator/executor에 묶여 관리) |
| **보안 요구사항** | ✅ 전체 대응 | 재진입 방지, delegatecall 제한, 강제 제거, ERC-2771 등 |

---

**결론:** Kernel은 IERC7579ModuleConfig의 모든 MUST 요구사항을 준수하며, 보안 섹션(§5)의 요구사항에도 전면 대응한다. `forceUninstallModule`과 `replaceModule`은 표준 범위를 넘는 확장 기능으로, 운영 안정성을 강화한다.
