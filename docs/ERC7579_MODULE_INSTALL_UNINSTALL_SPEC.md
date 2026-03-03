# ERC-7579 모듈 설치/제거 스펙 요약

> 출처: [EIP-7579 – Minimal Modular Smart Accounts](https://eips.ethereum.org/EIPS/eip-7579)

---

## 1. 표준 여부

**맞다.** 모듈을 추가/제거하는 방식은 **ERC-7579**에서 표준으로 정리되어 있다.

- **스마트 계정(Account)** 쪽: `installModule` / `uninstallModule` 로 모듈을 붙이거나 뗀다.
- **모듈(Module)** 쪽: 계정이 호출하는 `onInstall` / `onUninstall` 로 초기화/정리한다.

---

## 2. 계정(Account) 스펙 – Module Config

스마트 계정은 **IERC7579ModuleConfig** 를 구현해야 한다.

### 2.1 인터페이스

```solidity
interface IERC7579ModuleConfig {
    event ModuleInstalled(uint256 moduleTypeId, address module);
    event ModuleUninstalled(uint256 moduleTypeId, address module);

    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) external;

    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) external;

    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata additionalContext)
        external view returns (bool);
}
```

### 2.2 installModule

| 요구사항 | 스펙 문구 |
|----------|------------|
| 권한 | **MUST** implement authorization control |
| 모듈 호출 | **MUST** call `onInstall` on the module with the `initData` parameter **if provided** |
| 이벤트 | **MUST** emit `ModuleInstalled` event |
| 실패 시 | **MUST** revert if the module is **already installed** or the **initialization on the module failed** |

- `moduleTypeId`: 모듈 타입 (1=Validator, 2=Executor, 3=Fallback, 4=Hook)
- `module`: 모듈 컨트랙트 주소
- `initData`: 모듈의 `onInstall(data)` 에 넘길 데이터 (비어 있으면 onInstall 호출은 “if provided”에 따라 선택 가능)

### 2.3 uninstallModule

| 요구사항 | 스펙 문구 |
|----------|------------|
| 권한 | **MUST** implement authorization control |
| 모듈 호출 | **MUST** call `onUninstall` on the module with the `deInitData` parameter **if provided** |
| 이벤트 | **MUST** emit `ModuleUninstalled` event |
| 실패 시 | **MUST** revert if the module is **not installed** or the **deInitialization on the module failed** |

- `moduleTypeId`, `module`: 위와 동일
- `deInitData`: 모듈의 `onUninstall(data)` 에 넘길 데이터

### 2.4 모듈 타입 ID (스펙 정의)

| moduleTypeId | 타입 |
|--------------|------|
| 1 | Validation (Validator) |
| 2 | Execution (Executor) |
| 3 | Fallback |
| 4 | Hooks |

---

## 3. 모듈(Module) 스펙 – IERC7579Module

모듈은 **IERC7579Module** 를 구현해야 한다.

### 3.1 인터페이스

```solidity
interface IERC7579Module {
    /**
     * @dev Called by the smart account during installation of the module
     * @param data arbitrary data that may be required on the module during `onInstall` initialization
     * MUST revert on error (e.g. if module is already enabled)
     */
    function onInstall(bytes calldata data) external;

    /**
     * @dev Called by the smart account during uninstallation of the module
     * @param data arbitrary data that may be required on the module during `onUninstall` de-initialization
     * MUST revert on error
     */
    function onUninstall(bytes calldata data) external;

    /**
     * @dev Returns boolean value if module is a certain type
     * @param moduleTypeId the module type ID according the ERC-7579 spec
     * MUST return true if the module is of the given type and false otherwise
     */
    function isModuleType(uint256 moduleTypeId) external view returns (bool);

    /**
     * @dev Returns if the module was already initialized for a provided smart account
     */
    function isInitialized(address smartAccount) external view returns (bool);
}
```

### 3.2 onInstall / onUninstall

| 함수 | 역할 | 스펙 |
|------|------|------|
| **onInstall(bytes data)** | 계정이 `installModule` 할 때 **계정이** 모듈을 호출 | **MUST** revert on error (e.g. if module is already enabled) |
| **onUninstall(bytes data)** | 계정이 `uninstallModule` 할 때 **계정이** 모듈을 호출 | **MUST** revert on error |

즉, “설치/제거 방식”이 표준으로 정리된 내용은 다음과 같다.

- 계정: `installModule(moduleTypeId, module, initData)` / `uninstallModule(moduleTypeId, module, deInitData)` 로 추가/제거.
- 계정이 **반드시** 해당 모듈의 `onInstall(initData)` / `onUninstall(deInitData)` 를 호출해야 하고,
- 설치 실패(이미 설치됨 or onInstall 실패) 또는 제거 실패(미설치 or onUninstall 실패) 시 계정은 **반드시 revert** 해야 한다.

---

## 4. 흐름 요약

```
[설치]
  User / EntryPoint
    → Account.installModule(moduleTypeId, module, initData)
         → (권한 체크)
         → Module.onInstall(initData)   ← 스펙: MUST call if provided, MUST revert on init failure
         → (저장소에 모듈 등록)
         → emit ModuleInstalled(moduleTypeId, module)

[제거]
  User / EntryPoint
    → Account.uninstallModule(moduleTypeId, module, deInitData)
         → (권한 체크)
         → Module.onUninstall(deInitData)   ← 스펙: MUST call if provided, MUST revert on deinit failure
         → (저장소에서 모듈 제거)
         → emit ModuleUninstalled(moduleTypeId, module)
```

---

## 5. 이 프로젝트(Kernel)와의 대응

| 스펙 | Kernel 구현 |
|------|-------------|
| installModule(moduleTypeId, module, initData) | `Kernel.installModule` (Validator/Executor/Fallback/Hook/Policy/Signer 분기, 각자 onInstall 호출) |
| uninstallModule(moduleTypeId, module, deInitData) | `Kernel.uninstallModule` (동일 분기, `ModuleLib.uninstallModule` 등으로 onUninstall 호출) |
| ModuleInstalled / ModuleUninstalled 이벤트 | emit 함 |
| onInstall 실패 시 revert | 각 경로에서 직접 호출하므로 revert 전파됨 |
| onUninstall 실패 시 revert | 스펙상 MUST revert인데, 현재 `ModuleLib`는 ExcessivelySafeCall로 실패를 삼켜서 **스펙과 불일치** (상세는 `KERNEL_SPEC_COMPLIANCE_REVIEW.md` 참고) |

정리하면, **install/uninstall 로 모듈을 추가/제거하는 방식은 ERC-7579에 표준으로 정의되어 있고**, 위 스펙대로 계정은 `installModule`/`uninstallModule` 를 제공하고, 그 안에서 모듈의 `onInstall`/`onUninstall` 를 호출하는 구조가 맞다.
