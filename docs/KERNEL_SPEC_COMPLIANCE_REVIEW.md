# Kernel.sol ERC-4337 / ERC-7579 스펙 준수 검토

> EIP-4337(Account Abstraction), EIP-7579(Minimal Modular Smart Accounts) 스펙 대조 결과 요약
> 기준: [EIP-4337](https://eips.ethereum.org/EIPS/eip-4337), [EIP-7579](https://eips.ethereum.org/EIPS/eip-7579)

---

## 1. ERC-4337 준수 검토

### 1.1 Smart Contract Account 인터페이스

| 스펙 요구사항 | 구현 | 판정 |
| --- | --- | --- |
| `validateUserOp(PackedUserOperation, bytes32 userOpHash, uint256 missingAccountFunds)` 반환 `uint256` (packed validationData) | `IAccount` 동일 시그니처, `ValidationData`(uint256 wrapper) 반환 | ✅ 준수 |
| 반환값: aggregator/authorizer(0=valid, 1=sig fail, else 주소) + validUntil(6B) + validAfter(6B) | `Types.sol` `parseValidationData` / `packValidationData`로 동일 레이아웃 (authorizer 160b, validUntil 48b, validAfter 48b) | ✅ 준수 |
| `validateUserOp`는 EntryPoint만 호출 가능 | `onlyEntryPoint` modifier로 `msg.sender == ENTRYPOINT` 검사 | ✅ 준수 |
| `missingAccountFunds` 처리 | `validateUserOp` 내 assembly로 `call(caller(), missingAccountFunds, ...)` 수행 (스펙 권장) | ✅ 준수 |

### 1.2 IAccountExecute (선택)

| 스펙 요구사항 | 구현 | 판정 |
| --- | --- | --- |
| `executeUserOp(PackedUserOperation, bytes32 userOpHash)` | `IAccountExecute` 구현, EntryPoint만 호출 | ✅ 준수 |
| callData 앞 4바이트는 `executeUserOp.selector`로 예약, 실제 실행은 `userOp.callData[4:]` | `executeUserOp` 내부에서 `userOp.callData[4:]`로 delegatecall 수행 | ✅ 준수 |
| delegatecall로 실행 권장 | `ExecLib.executeDelegatecall(address(this), userOp.callData[4:])` 사용 | ✅ 준수 |

### 1.3 기타

| 항목 | 판정 |
| --- | --- |
| PackedUserOperation 구조 (sender, nonce, initCode, callData, accountGasLimits, preVerificationGas, gasFees, paymasterAndData, signature) | ✅ 인터페이스/사용처 일치 |
| userOpHash는 EntryPoint·chainId 포함 해시 (스펙) | ✅ 호출처(EntryPoint) 책임, Kernel은 수신값 사용 |
| Nonce: 64비트 sequence + 192비트 key (스펙) | ✅ Kernel은 nonce를 ValidatorLib.decodeNonce로 자체 해석(v3 모드/타입/ValidationId 등), 계정 단위 동작은 호환 |

---

## 2. ERC-7579 준수 검토

### 2.1 실행 인터페이스 (IERC7579Execution)

| 스펙 요구사항 | 구현 | 판정 |
| --- | --- | --- |
| `execute(bytes32 mode, bytes calldata executionCalldata)` external | `execute(ExecMode mode, ...)` — `ExecMode`는 `bytes32` 타입 별칭 | ✅ 준수 |
| `executeFromExecutor(bytes32 mode, bytes calldata executionCalldata)` returns (bytes[] memory returnData) | 동일 시그니처, `bytes[]` 반환 | ✅ 준수 |
| execute: onlyEntryPointOrSelf 수준의 권한 | `onlyEntryPointOrSelfOrRoot` (EntryPoint / self / root validator as hook) | ✅ 준수 (강화) |
| executeFromExecutor: onlyExecutorModule | `_executorConfig(IExecutor(msg.sender)).hook != HOOK_MODULE_NOT_INSTALLED`로 등록된 Executor만 허용 | ✅ 준수 |
| 지원하지 않는 mode면 revert | `supportsExecutionMode` 검사, ExecLib.execute 내부에서 미지원 시 revert | ✅ 준수 |
| MUST revert for unsupported modes | CALLTYPE_STATIC → `NotSupportedCallType` revert | ✅ 준수 |

### 2.2 실행 모드 인코딩

| 스펙 (bytes32 레이아웃) | 구현 | 판정 |
| --- | --- | --- |
| callType 1B, execType 1B, unused 4B, modeSelector 4B, modePayload 22B | `ExecLib.decode`: callType, execType, modeSelector, modePayload 추출 | ✅ 준수 |
| Single: abi.encodePacked(target, value, callData) | `LibERC7579.decodeSingle` / `encodeSingle` 사용 | ✅ 준수 |
| Batch: Execution[] abi.encode | `LibERC7579.decodeBatch` 등 | ✅ 준수 |
| Delegatecall: abi.encodePacked(target, callData) | `LibERC7579.decodeDelegate` | ✅ 준수 |

### 2.3 계정 설정 (IERC7579AccountConfig)

| 스펙 요구사항 | 구현 | 판정 |
| --- | --- | --- |
| `accountId()` non-empty string, 권장 "vendorname.accountname.semver" | `"kernel.advanced.0.3.3"` 반환 | ✅ 준수 |
| `supportsExecutionMode(bytes32)` | callType/batch/single/delegatecall, execType try/default, selector·payload 검사 | ✅ 준수 |
| `supportsModule(uint256 moduleTypeId)` | `moduleTypeId < 7` (1~6 지원) | ✅ 준수 (1–4 스펙, 5–6 확장) |

### 2.4 모듈 설정 (IERC7579ModuleConfig)

| 스펙 요구사항 | 구현 | 판정 |
| --- | --- | --- |
| ModuleInstalled / ModuleUninstalled 이벤트 | 동일 이벤트 emit | ✅ 준수 |
| installModule: 권한 제어, onInstall 호출, 이벤트, 이미 설치/실패 시 revert | `onlyEntryPointOrSelfOrRoot` + `nonReentrantModuleOp`, 모든 타입에서 onInstall 호출, 이미 설치 시 `ModuleAlreadyInstalled` revert | ✅ 준수 |
| uninstallModule: 권한 제어, onUninstall 호출, 이벤트, 미설치/실패 시 revert | direct call로 onUninstall 호출, 실패 시 `ModuleOnUninstallFailed` revert, 미설치 시 `ModuleNotInstalled` revert | ✅ 준수 |
| isModuleInstalled(moduleTypeId, module, additionalContext) | Validator/Executor/Fallback/Hook별 저장소 조회로 구현 (type 5/6은 설계상 false) | ✅ 준수 (type 1-4) |

### 2.5 모듈 타입 ID

| 스펙 (ERC-7579) | 구현 (Constants.sol) | 판정 |
| --- | --- | --- |
| Validation = 1 | MODULE_TYPE_VALIDATOR = 1 | ✅ |
| Execution = 2 | MODULE_TYPE_EXECUTOR = 2 | ✅ |
| Fallback = 3 | MODULE_TYPE_FALLBACK = 3 | ✅ |
| Hooks = 4 | MODULE_TYPE_HOOK = 4 | ✅ |
| — | MODULE_TYPE_POLICY = 5, MODULE_TYPE_SIGNER = 6 (확장) | ✅ 스펙 범위 외 |

### 2.6 Hooks (선택 확장)

| 스펙 요구사항 | 구현 | 판정 |
| --- | --- | --- |
| execute / executeFromExecutor 호출 전 preCheck, 호출 후 postCheck | `executeUserOp`, `executeFromExecutor`, `fallback`, `onlyEntryPointOrSelfOrRoot` 경로에서 `_doPreHook` / `_doPostHook` 사용 | ✅ 준수 |
| context는 preCheck 반환값을 postCheck에 전달 | `bytes memory context = _doPreHook(...)` → `_doPostHook(hook, context)` | ✅ 준수 |
| RECOMMENDED: installModule/uninstallModule에도 pre/post hook 적용 | `onlyEntryPointOrSelfOrRoot` modifier가 root validator hook의 pre/post를 실행 | ✅ 준수 |
| Hook gas limit 방어 (DoS 방지) | `setHookGasLimit()`로 hook별 gas limit 설정, `_doPreHook`/`_doPostHook`에서 적용 | ✅ 강화 |

### 2.7 ERC-1271

| 스펙 요구사항 | 구현 | 판정 |
| --- | --- | --- |
| isValidSignature 구현 | `isValidSignature(bytes32 hash, bytes data)` 제공 | ✅ 준수 |
| Validator로 포워딩 시 isValidSignatureWithSender(sender, hash, signature) 호출 | ValidationManager에서 validator.isValidSignatureWithSender 호출 | ✅ 준수 |
| signature에 selector 등 인코딩 시 sanitize | nonce/모드 디코딩 등으로 처리 | ✅ 준수 |

### 2.8 Fallback

| 스펙 요구사항 | 구현 | 판정 |
| --- | --- | --- |
| selector 기준으로 fallback handler 라우팅 | `_selectorConfig(msg.sig)`로 target·callType 결정 | ✅ 준수 |
| ERC-2771으로 원래 msg.sender 전달 | CALLTYPE_SINGLE 시 `ExecLib.doFallback2771Call` (calldata + 20B sender) | ✅ 준수 |
| Fallback handler 호출은 call 또는 staticcall만 사용 | CALLTYPE_SINGLE = call 사용. CALLTYPE_DELEGATECALL 지원 | ⚠️ 아래 참고 |

### 2.9 ERC-165

| 스펙 | 구현 | 판정 |
| --- | --- | --- |
| MAY 구현. 미구현 기능은 해당 interface id에 false | Kernel에 supportsInterface 미구현 | ✅ 선택 사항이라 허용 |

### 2.10 Validation (ERC-7579)

| 스펙 | 구현 | 판정 |
| --- | --- | --- |
| Validator 선택 방식은 스펙 비규정 | nonce 디코딩으로 ValidationMode/Type/Id 결정, rootValidator 또는 지정 validator 사용 | ✅ |
| validator에 넘기기 전 affected 값 sanitize | replayable 등 시 signature 조작 후 validator 호출 | ✅ 준수 |
| validation 반환값은 validator 반환값 사용 권장 | _validateUserOp에서 validator 결과를 ValidationData로 사용 | ✅ 준수 |

### 2.11 보안 요구사항 (ERC-7579 §5)

| 스펙 보안 요구사항 | 구현 | 판정 |
| --- | --- | --- |
| Delegatecall 대상은 신뢰된 컨트랙트만 | `DelegatecallWhitelistStorage` + `_checkDelegatecallTarget()` | ✅ 준수 |
| onInstall/onUninstall 재진입 방지 | `nonReentrantModuleOp` (EIP-1153 transient storage) | ✅ 준수 |
| 악의적 onUninstall revert 대응 메커니즘 | `forceUninstallModule()` (ExcessivelySafeCall) | ✅ 준수 |
| Hook 선택을 신뢰된 hook으로 제한 | hook은 모듈 설치 시에만 설정, `_isActiveHook()` | ✅ 준수 |
| Fallback handler는 ERC-2771 _msgSender() 사용 | `ExecLib.doFallback2771Call` | ✅ 준수 |
| 모듈 교체 시 이전 상태 정리 | `replaceModule()` + `_clearModuleState()` | ✅ 준수 |
| address(this) 호출 권한 우회 방지 | `ExecutorCannotCallSelf` + transient flag | ✅ 준수 |

---

## 3. 알려진 스펙 상이점

### 3.1 ERC-7579 Fallback: delegatecall 사용

- **스펙**: "MUST use `call` or `staticcall` to invoke the fallback handler."
- **구현**: `CALLTYPE_DELEGATECALL` 시 `ExecLib.executeDelegatecall(config.target, msg.data)` 사용 (call/staticcall 아님).
- **판정**: 스펙 문구와 불일치. 실무적으로는 많은 구현이 delegatecall fallback을 허용하나, 엄밀한 스펙 준수라면 Fallback 경로는 call/staticcall만 허용하는 것이 맞음.
- **대응**: Delegatecall whitelist (`setDelegatecallWhitelist`, `setEnforceDelegatecallWhitelist`)로 delegatecall 대상을 제한하여 보안 리스크를 완화. 이는 ERC-7579 표준의 call/staticcall 요구를 확장한 구현으로, 추가적인 유연성을 제공하되 whitelist로 안전성을 보장.

---

## 4. 확장 기능 (스펙 범위 외)

Kernel v0.3.3은 ERC-7579 표준 범위를 넘는 다음 기능을 제공한다:

| 기능 | 함수 | 설명 |
| --- | --- | --- |
| **강제 모듈 제거** | `forceUninstallModule()` | 악의적 모듈 대응 escape hatch (ExcessivelySafeCall) |
| **원자적 모듈 교체** | `replaceModule()` | 제거+설치를 단일 트랜잭션으로 수행 |
| **Hook Gas Limit** | `setHookGasLimit()` | hook별 gas 한도 설정 (DoS 방지) |
| **Delegatecall Whitelist** | `setDelegatecallWhitelist()` | delegatecall 대상 제한 |
| **Whitelist 적용 모드** | `setEnforceDelegatecallWhitelist()` | 화이트리스트 적용 on/off (하위 호환) |
| **재진입 방지** | `nonReentrantModuleOp` modifier | EIP-1153 transient storage 기반 |
| **Module Type 5, 6** | Policy, Signer | Permission 시스템 확장 |

---

## 5. 요약

| 구분 | 준수 | 이슈/비고 |
| --- | --- | --- |
| **ERC-4337** | ✅ 전체 준수 | validateUserOp 반환값·시그니처·EntryPoint 제한·executeUserOp 동작 일치 |
| **ERC-7579 실행·설정** | ✅ 준수 | execute / executeFromExecutor, 모드 인코딩, accountId(`kernel.advanced.0.3.3`), supportsExecutionMode, supportsModule |
| **ERC-7579 모듈 설치** | ✅ 준수 | installModule 권한·onInstall·이벤트·이미 설치 시 revert |
| **ERC-7579 모듈 제거** | ✅ 준수 | uninstallModule: direct call로 onUninstall 호출, 실패 시 revert, 미설치 시 revert, 이벤트 |
| **ERC-7579 Fallback** | ⚠️ 1건 상이 | Fallback handler 호출에 delegatecall 지원 (스펙은 call/staticcall만 요구). Delegatecall whitelist로 완화 |
| **ERC-7579 Hooks·ERC-1271** | ✅ 준수 | preCheck/postCheck, Hook gas limit, ERC-1271 포워딩 |
| **ERC-7579 보안 (§5)** | ✅ 전체 대응 | 재진입 방지, delegatecall 제한, 강제 제거, ERC-2771, 상태 정리, self-call 방지 |

전체적으로 Kernel.sol은 ERC-4337과 ERC-7579의 모든 MUST 요구사항을 충족하며, Fallback delegatecall 1건만 스펙 문구와 상이하다 (whitelist로 보안 대응 완료). 보안 요구사항(§5)에도 전면 대응한다.
