# Code Quality Review Report — ERC-7579 모듈 미해결 이슈

**Initial Review Date:** 2026-03-09
**Last Updated:** 2026-03-12
**Scope:** `src/erc7579-*` 디렉토리 전체
**Status:** 비 ERC-7579 이슈 25건 수정 완료, ERC-7579 모듈 미해결 이슈 아래 참조

---

## Executive Summary

원본 리뷰에서 발견된 48건 중 **25건은 수정 완료**되었습니다 (bridge, defi, privacy, subscription, compliance 모듈).

본 문서는 **ERC-7579 모듈에 한정된 미해결 이슈**만 포함합니다.

### 원본(kernel-7579-plugins) 동일 이슈 — 무시

아래 이슈는 원본 Kernel/ZeroDev 코드에도 동일하게 존재하는 패턴으로, 원본 코드 품질에 맞춰 **의도적으로 현행 유지**합니다:

| 이슈 | 파일 | 사유 |
|------|------|------|
| ~~C-02~~ | ExecutorManager.sol | 원본 Kernel과 동일한 조건문 구조. 데이터 없는 모듈에서 onInstall revert를 무시하는 의도적 설계 |
| ~~C-07~~ | ECDSAValidator.sol | 원본 Kernel ECDSAValidator와 동일. 재설치 방어 없음은 원본 설계 |
| ~~C-08~~ | MultiChainValidator.sol | 원본 Kernel에서 직접 가져온 코드. C-07과 동일 패턴 |

### 수정 완료 이슈

| 이슈 | 파일 | 수정 내용 |
|------|------|----------|
| ~~H-13~~ | WebAuthnValidator.sol | P256 Solidity fallback 라이브러리(Daimo P256Verifier) 추가. EIP-7212 미지원 체인에서도 동작 |
| ~~H-14~~ | SpendingLimitHook.sol | 잔고 기반 설계로 전면 재작성. approve 추적 문제 해결 |
| ~~M-06~~ | SpendingLimitHook.sol | H-14와 동일 (중복) |

### 미해결 이슈 집계

| Severity | 미해결 |
|----------|--------|
| CRITICAL | 3 |
| HIGH | 2 |
| MEDIUM | 7 |
| LOW | 5 |
| **Total** | **17** |

### 핵심 위험 패턴

1. **접근 제어 누락** — 서명 건너뛰기, 무제한 주문 생성 (C-09, C-10)
2. **임의 코드 실행** — FlashLoanFallback이 검증 없이 임의 외부 호출 수행 (C-06)
3. **CEI 위반 및 상태 불일치** — 외부 호출 후 state 변경, 캐시 발산, 미초기화 상태 (H-12, M-17, M-18)

---

## CRITICAL Issues (5건)

### ~~C-02: ExecutorManager — 조건문 논리 반전~~ (원본 동일 — 무시)

- **File:** `src/erc7579-smartaccount/core/ExecutorManager.sol:32-38`
- **Confidence:** 95%
- **Status:** 원본 Kernel과 동일한 코드. 의도적 설계로 판단하여 현행 유지.
- **영향:** executor 설치 실패가 무시되어, 비정상 executor가 smart account에 등록됨

#### 문제 상세

`_installExecutor`에서 `executorData.length` 기반 분기가 정확히 반대로 구현되어 있습니다:

```solidity
// 현재 코드 (반전됨)
if (executorData.length == 0) {
    // 데이터가 없을 때 → low-level call (반환값 무시)
    (bool success,) = address(executor).call(
        abi.encodeWithSelector(IModule.onInstall.selector, executorData)
    );
    (success); // return value intentionally ignored ← 위험
} else {
    // 데이터가 있을 때 → 직접 호출 (revert 전파)
    executor.onInstall(executorData);
}
```

**의도된 동작:**
- 데이터가 **있을 때** → low-level call로 에러 핸들링 (복잡한 초기화)
- 데이터가 **없을 때** → 직접 호출 (단순 초기화)

**실제 동작:**
- 데이터가 있는 executor 설치 시, `onInstall`이 revert해도 설치가 성공한 것으로 처리됨
- 미초기화 상태의 executor가 smart account에서 실행 권한을 가짐

#### 수정 방안

```solidity
if (executorData.length > 0) {
    (bool success,) = address(executor).call(
        abi.encodeWithSelector(IModule.onInstall.selector, executorData)
    );
    if (!success) revert ExecutorInstallFailed();
} else {
    executor.onInstall(executorData);
}
```

---

### C-06: FlashLoanFallback — 임의 외부 호출

- **File:** `src/erc7579-fallbacks/FlashLoanFallback.sol:481-488`
- **Confidence:** 95%
- **영향:** smart account의 모든 자산 탈취 가능

#### 문제 상세

`_executeCallback`이 caller가 제공한 임의 `(address, bytes)` 쌍으로 `.call()`을 실행합니다. 등록된 callback 경로(callbackId 기반) 외에, **직접 decode 경로**가 검증 없이 존재합니다:

```solidity
function _executeCallback(address smartAccount, bytes memory data) internal {
    if (data.length == 32) {
        // 경로 1: 등록된 callback (안전)
        bytes32 callbackId = abi.decode(data, (bytes32));
        FlashLoanCallback storage callback = accountStorage[smartAccount].callbacks[callbackId];
        if (callback.target == address(0)) revert CallbackNotRegistered(callbackId);
        (bool success,) = callback.target.call(callback.callData);
        // ...
    } else if (data.length > 0) {
        // 경로 2: 직접 decode (위험) — 임의 target + callData
        (address target, bytes memory callData) = abi.decode(data, (address, bytes));
        if (target != address(0)) {
            (bool success,) = target.call(callData);  // ← 검증 없는 임의 실행
        }
    }
}
```

**공격 시나리오:**
1. 공격자가 flash loan을 요청하며 `data`에 `(smartAccountAddress, transferAllTokens)` 인코딩
2. `_executeCallback`이 smart account 자체를 target으로 임의 함수 실행
3. Reentrancy guard 없이 smart account의 토큰을 탈취

#### 수정 방안

- 경로 2 (직접 decode) 완전 제거, callback 등록 경로만 허용
- 또는 target whitelist + reentrancy guard 추가:

```solidity
} else if (data.length > 0) {
    (address target, bytes memory callData) = abi.decode(data, (address, bytes));
    if (target == smartAccount) revert CannotCallSelf();
    if (!accountStorage[smartAccount].allowedTargets[target]) revert TargetNotAllowed(target);
    (bool success,) = target.call(callData);
}
```

---

### ~~C-07: ECDSAValidator — 재설치 방어 누락~~ (원본 동일 — 무시)

- **File:** `src/erc7579-validators/ECDSAValidator.sol:26-29`
- **Confidence:** 92%
- **Status:** 원본 Kernel ECDSAValidator와 동일한 코드. 원본 코드 품질에 맞춰 현행 유지.
- **영향:** smart account 제어권 탈취

#### 문제 상세

`onInstall`에 `AlreadyInitialized` 체크가 없어 재설치 시 owner가 무조건 덮어써집니다:

```solidity
function onInstall(bytes calldata _data) external payable override {
    // ← _isInitialized(msg.sender) 체크 없음
    address owner = address(bytes20(_data[0:20]));
    ecdsaValidatorStorage[msg.sender].owner = owner;  // 무조건 덮어쓰기
    emit OwnerRegistered(msg.sender, owner);
}
```

반면 `onUninstall`은 올바르게 초기화 상태를 검증합니다:

```solidity
function onUninstall(bytes calldata) external payable override {
    if (!_isInitialized(msg.sender)) revert NotInitialized(msg.sender);  // ← 검증 있음
    delete ecdsaValidatorStorage[msg.sender];
}
```

**공격 시나리오:**
ERC-7579 account가 모듈 관리에 취약점이 있거나, 다른 executor가 `onInstall`을 호출할 수 있는 경우, 공격자가 자신의 주소를 owner로 설정하여 계정 탈취

#### 수정 방안

```solidity
function onInstall(bytes calldata _data) external payable override {
    if (_isInitialized(msg.sender)) revert AlreadyInitialized(msg.sender);
    address owner = address(bytes20(_data[0:20]));
    ecdsaValidatorStorage[msg.sender].owner = owner;
    emit OwnerRegistered(msg.sender, owner);
}
```

---

### ~~C-08: MultiChainValidator — 재설치 방어 누락~~ (원본 동일 — 무시)

- **File:** `src/erc7579-validators/MultiChainValidator.sol:30-33`
- **Confidence:** 92%
- **Status:** 원본 Kernel에서 직접 가져온 코드. C-07과 동일하게 현행 유지.
- **영향:** C-07과 동일 — smart account 제어권 탈취

C-07과 **동일한 코드 패턴**입니다. `onInstall`에서 owner를 무조건 덮어씁니다.

```solidity
function onInstall(bytes calldata _data) external payable override {
    // ← _isInitialized(msg.sender) 체크 없음
    address owner = address(bytes20(_data[0:20]));
    ecdsaValidatorStorage[msg.sender].owner = owner;
    emit OwnerRegistered(msg.sender, owner);
}
```

**수정 방안:** C-07과 동일하게 `_isInitialized` 가드 추가.

---

### C-09: WeightedECDSAValidator — Paymaster 경로 서명 검증 건너뛰기

- **File:** `src/erc7579-validators/WeightedECDSAValidator.sol:246-256`
- **Confidence:** 90%
- **영향:** 서명 없이 트랜잭션 실행 가능

#### 문제 상세

`validateUserOp`에서 paymaster가 존재할 때, approved proposal을 **서명 검증 없이** 실행합니다:

```solidity
} else if (proposal.status == ProposalStatus.Approved || passed) {
    if (userOp.paymasterAndData.length == 0
        || address(bytes20(userOp.paymasterAndData[0:20])) == address(0))
    {
        // paymaster 없음 → 서명 검증 수행
        address signer = ECDSA.recover(
            ECDSA.toEthSignedMessageHash(userOpHash), userOp.signature
        );
        if (guardian[signer][msg.sender].weight != 0) {
            proposal.status = ProposalStatus.Executed;
            return packValidationData(proposal.validAfter, ValidUntil.wrap(0));
        }
    } else {
        // paymaster 있음 → 서명 검증 건너뛰기 ← 위험
        proposal.status = ProposalStatus.Executed;
        return packValidationData(proposal.validAfter, ValidUntil.wrap(0));
    }
}
```

**공격 시나리오:**
1. 정상적으로 proposal이 `Approved` 상태에 도달
2. 공격자가 해당 `callDataAndNonceHash`를 참조하는 userOp을 구성
3. paymaster를 지정하여 서명 검증 우회
4. guardian 서명 없이 트랜잭션 실행

#### 수정 방안

paymaster 존재 여부와 관계없이 항상 서명 검증:

```solidity
} else if (proposal.status == ProposalStatus.Approved || passed) {
    address signer = ECDSA.recover(
        ECDSA.toEthSignedMessageHash(userOpHash), userOp.signature
    );
    if (guardian[signer][msg.sender].weight != 0) {
        proposal.status = ProposalStatus.Executed;
        return packValidationData(proposal.validAfter, ValidUntil.wrap(0));
    }
}
```

---

### C-10: OnRampPlugin — createOrder 접근 제어 없음

- **File:** `src/erc7579-plugins/OnRampPlugin.sol:303-344`
- **Confidence:** 88%
- **영향:** plugin 토큰 잔고 탈취, griefing

#### 문제 상세

`createOrder`에 접근 제어가 없어 **누구나** 임의 providerId로 주문을 생성할 수 있습니다:

```solidity
function createOrder(
    bytes32 orderId,
    uint256 providerId,
    address recipient,
    uint256 fiatAmount,
    string calldata fiatCurrency,
    uint256 cryptoAmount,
    uint256 exchangeRate
) external {  // ← 접근 제어 없음
    Provider storage provider = providers[providerId];
    if (provider.status != ProviderStatus.ACTIVE) revert ProviderNotActive();
    // ... KYC, 한도 체크만 수행
    orders[orderId] = Order({...});
}
```

**문제점:**
- 합법적 provider 서명의 replay로 주문 생성 → 토큰 인출
- 대량 주문 생성으로 provider의 일일 한도 소진 (griefing)
- front-running으로 정상 주문 가로채기

#### 수정 방안

```solidity
function createOrder(...) external {
    Provider storage provider = providers[providerId];
    if (msg.sender != provider.signer) revert UnauthorizedCaller();
    // ... 나머지 로직
}
```

---

## HIGH Issues (4건)

### H-11: LendingExecutor — Approval 미해제

- **File:** `src/erc7579-executors/LendingExecutor.sol:493-505, 533-545`
- **Confidence:** 85%
- **영향:** 잔여 approval을 통한 자금 유출

#### 문제 상세

`_executeSupply`와 `_executeRepay`에서 `approve(LENDING_POOL, amount)` 호출 후 **revoke하지 않습니다**:

```solidity
function _executeSupply(address account, address asset, uint256 amount) internal {
    // approve 설정
    bytes memory approveCall = abi.encodeWithSelector(IERC20.approve.selector, LENDING_POOL, amount);
    IERC7579Account(account).executeFromExecutor(execMode, approveExecData);

    // deposit 실행
    bytes memory depositCall = abi.encodeWithSignature("deposit(address,uint256)", asset, amount);
    IERC7579Account(account).executeFromExecutor(execMode, depositExecData);

    // ← approve(0) 누락
}
```

같은 프로젝트의 `SwapExecutor._executeSwapSingle`은 올바르게 `approve(0)` 패턴을 사용하고 있어 **패턴 불일치**입니다.

**위험:** LENDING_POOL 컨트랙트가 악의적이거나 취약점이 있을 경우, 남아있는 approval로 smart account 자금 인출 가능

#### 수정 방안

deposit/repay 후 `approve(0)` 추가:

```solidity
// deposit 실행 후
bytes memory revokeCall = abi.encodeWithSelector(IERC20.approve.selector, LENDING_POOL, 0);
bytes memory revokeExecData = abi.encodePacked(asset, uint256(0), revokeCall);
IERC7579Account(account).executeFromExecutor(execMode, revokeExecData);
```

---

### H-12: StakingExecutor — CEI 위반 (unstake)

- **File:** `src/erc7579-executors/StakingExecutor.sol:323-344`
- **Confidence:** 85%
- **영향:** 외부 호출 실패 시 state 불일치, cross-contract reentrancy 리스크

#### 문제 상세

`unstake`에서 **외부 호출 후** state를 업데이트합니다. 같은 컨트랙트의 `stake`/`stakeWithLock`은 올바르게 CEI를 따르고 있어 불일치합니다:

```solidity
function unstake(address pool, uint256 amount) external {
    // Checks
    _checkInitialized(msg.sender);
    if (amount == 0) revert InvalidAmount();

    // Interactions (외부 호출 먼저) ← CEI 위반
    bytes memory callData = abi.encodeWithSelector(IStakingPool.unstake.selector, amount);
    _executeFromAccount(msg.sender, pool, 0, callData);

    // Effects (state 업데이트 나중에)
    if (stakedAmounts[msg.sender][pool] >= amount) {
        stakedAmounts[msg.sender][pool] -= amount;
    } else {
        stakedAmounts[msg.sender][pool] = 0;
    }
}
```

#### 수정 방안

state 업데이트를 외부 호출 전으로 이동:

```solidity
function unstake(address pool, uint256 amount) external {
    _checkInitialized(msg.sender);
    if (amount == 0) revert InvalidAmount();

    // Effects 먼저
    if (stakedAmounts[msg.sender][pool] >= amount) {
        stakedAmounts[msg.sender][pool] -= amount;
    } else {
        stakedAmounts[msg.sender][pool] = 0;
    }

    // Interactions 나중에
    bytes memory callData = abi.encodeWithSelector(IStakingPool.unstake.selector, amount);
    _executeFromAccount(msg.sender, pool, 0, callData);
}
```

---

### ~~H-13: WebAuthnValidator — EIP-7212 없는 체인에서 Silent Fail~~ (수정 완료)

- **File:** `src/erc7579-validators/WebAuthnValidator.sol:594-603`
- **Confidence:** 88%
- **Status:** P256.sol 라이브러리 추가 (EIP-7212 precompile → Daimo P256Verifier fallback). 수정 완료.
- **영향:** 설치된 smart account가 거래 불능 상태에 빠짐

#### 문제 상세

EIP-7212 P256 precompile (`address(0x100)`)이 없는 체인에서 서명 검증이 **조용히 실패**합니다:

```solidity
(bool success, bytes memory output) = address(0x100).staticcall(input);

if (success && output.length == 32) {
    return abi.decode(output, (uint256)) == 1;
}

// Fallback 미구현 — 항상 false 반환
// "For now, return false if precompile is not available"
return false;
```

**결과:**
1. EIP-7212 미지원 체인에서 WebAuthnValidator 설치 → 성공 (검증 없음)
2. 이후 모든 `validateUserOp` 호출 → 서명 검증 실패 → 트랜잭션 거부
3. smart account가 영구적으로 거래 불능 상태
4. 사용자 에러 메시지 없음 (silent fail)

#### 수정 방안

**Option 1:** Solidity P256 fallback 라이브러리 통합 (FCL 또는 Daimo P256Verifier):

```solidity
if (success && output.length == 32) {
    return abi.decode(output, (uint256)) == 1;
}
// Fallback to Solidity-based P256 verification
return P256Verifier.verify(hash, r, s, pubKeyX, pubKeyY);
```

**Option 2:** `onInstall`에서 precompile 가용성 검증:

```solidity
function onInstall(bytes calldata _data) external payable override {
    // Precompile availability check
    (bool success,) = address(0x100).staticcall(hex"00");
    if (!success) revert P256PrecompileNotAvailable();
    // ... 기존 설치 로직
}
```

---

### ~~H-14: SpendingLimitHook — approve 추적 오류~~ (수정 완료)

- **File:** `src/erc7579-hooks/SpendingLimitHook.sol:165-169`
- **Confidence:** 82%
- **Status:** 잔고 기반 설계로 전면 재작성. calldata 파싱 제거, pre/post 잔고 비교 방식 적용. 수정 완료.
- **영향:** spending limit이 실제 지출 없이 소진됨, 실제 지출은 미추적

#### 문제 상세

ERC-20 `approve(spender, amount)` 호출이 spending limit에 차감됩니다:

```solidity
} else if (selector == APPROVE_SELECTOR && execCalldata.length >= 68) {
    uint256 amount = uint256(bytes32(execCalldata[36:68]));
    _checkAndRecordSpending(msg.sender, target, amount);  // ← approve도 지출로 차감
    return abi.encode(target, amount);
}
```

**문제점 2가지:**
1. `approve`는 토큰 이동이 아닌 **allowance 부여**인데, 실제 이동 없이 한도가 소진됨
2. approve된 spender가 이후 `transferFrom`을 호출하면, 이는 spender의 트랜잭션이므로 **hook이 감지 불가** → 실제 지출은 미추적

#### 수정 방안

```solidity
// approve를 spending limit에서 제외
} else if (selector == APPROVE_SELECTOR && execCalldata.length >= 68) {
    // approve는 allowance 부여이므로 spending limit에서 추적하지 않음
    // 주의: approved spender의 transferFrom은 hook 범위 외
    return abi.encode(target, uint256(0));
}
```

---

## MEDIUM Issues (9건)

### ~~M-06: SpendingLimitHook — H-14와 동일~~ (수정 완료)

H-14를 참조하십시오. 동일 이슈의 중복 보고입니다. 잔고 기반 재작성으로 해결됨.

---

### M-07: WeightedECDSAValidator — approveWithSig guardian 미검증

- **File:** `src/erc7579-validators/WeightedECDSAValidator.sol:155-177`
- **Confidence:** 85%
- **영향:** 비인가 서명자가 proposal 승인에 참여

#### 문제 상세

`approveWithSig`에서 recovered signer가 실제로 **등록된 guardian인지 검증하지 않습니다**:

```solidity
for (uint256 i = 0; i < sigCount; i++) {
    address signer = ECDSA.recover(
        _hashTypedData(keccak256(abi.encode(...))),
        sigs[i * 65:(i + 1) * 65]
    );
    VoteStorage storage vote = voteStatus[_callDataAndNonceHash][signer][_kernel];
    require(vote.status == VoteStatus.NA, "Already voted");
    vote.status = VoteStatus.Approved;
    // ← guardian[signer][_kernel].weight 검증 없음
}
```

weight가 0인 non-guardian의 vote도 storage에 기록됩니다. `getApproval`이 weight를 합산할 때 무시되지만, storage 오염과 이벤트 혼란을 야기합니다.

#### 수정 방안

```solidity
address signer = ECDSA.recover(...);
require(guardian[signer][_kernel].weight != 0, "Not a guardian");
```

---

### M-08: AuditHook — 재설치 시 stale 데이터 잔존

- **File:** `src/erc7579-hooks/AuditHook.sol:86-108`
- **Confidence:** 80%
- **영향:** 이전 설치의 blocklist/auditLog가 재설치 후에도 유지

#### 문제 상세

`onUninstall` 후 `auditLog`, `blocklist`, `pendingExecutions`가 삭제되지 않습니다. `onInstall`에 `AlreadyInitialized` 가드가 없어, 재설치 시 config만 덮어쓰고 이전 데이터가 그대로 남습니다:

```solidity
function onInstall(bytes calldata data) external payable override {
    // ← AlreadyInitialized 체크 없음
    if (data.length == 0) {
        accountStorage[msg.sender].config = AccountConfig({...});
    } else {
        // config만 설정, 기존 blocklist/auditLog/pendingExecutions 유지
    }
}
```

#### 수정 방안

`onInstall`에 초기화 가드를 추가하거나, `onUninstall`에서 모든 관련 데이터를 정리합니다.

---

### M-09: PolicyHook — 빈 데이터 설치 시 미초기화 상태

- **File:** `src/erc7579-hooks/PolicyHook.sol:112-123`
- **Confidence:** 80%
- **영향:** 설치된 hook이 모든 트랜잭션을 차단

#### 문제 상세

`data.length == 0`일 때 `isInitialized = true` 설정 없이 조기 반환합니다:

```solidity
function onInstall(bytes calldata data) external payable override {
    if (data.length == 0) return;  // ← isInitialized 미설정

    (PolicyMode mode, bool strict) = abi.decode(data, (PolicyMode, bool));
    AccountStorage storage store = accountStorage[msg.sender];
    store.mode = mode;
    store.isStrict = strict;
    store.isInitialized = true;  // ← data가 있을 때만 설정
}
```

**결과:** 기본 `ALLOWLIST` 모드에 allowed target이 없으므로, 모든 트랜잭션이 차단됩니다.

#### 수정 방안

```solidity
function onInstall(bytes calldata data) external payable override {
    AccountStorage storage store = accountStorage[msg.sender];
    store.isInitialized = true;  // 항상 설정

    if (data.length == 0) return;
    (PolicyMode mode, bool strict) = abi.decode(data, (PolicyMode, bool));
    store.mode = mode;
    store.isStrict = strict;
}
```

---

### M-10: RecurringPaymentExecutor — 외부 자기 호출 패턴

- **File:** `src/erc7579-executors/RecurringPaymentExecutor.sol:261-267`
- **Confidence:** 82%
- **영향:** 불필요한 ABI 오버헤드, reentrancy 표면 확대

#### 문제 상세

`executePaymentBatch`가 `this.executePayment(...)` 으로 **외부 자기 호출**합니다:

```solidity
function executePaymentBatch(address account, uint256[] calldata scheduleIds)
    external returns (uint256 successCount)
{
    for (uint256 i = 0; i < scheduleIds.length; i++) {
        try this.executePayment(account, scheduleIds[i]) {  // ← 외부 self-call
            successCount++;
        } catch (bytes memory reason) {
            emit PaymentBatchFailed(account, scheduleIds[i], reason);
        }
    }
}
```

외부 호출은 ABI encode/decode 오버헤드가 있고, reentrancy guard를 우회할 수 있습니다.

#### 수정 방안

`_executePaymentInternal` internal 함수로 리팩토링:

```solidity
for (uint256 i = 0; i < scheduleIds.length; i++) {
    try this._executePaymentInternal(account, scheduleIds[i]) {
        // 위의 패턴 대신:
    }
}
// → internal 함수 추출 후 직접 호출
```

---

### M-11: AutoSwapPlugin — Oracle Price 이중 조회

- **File:** `src/erc7579-plugins/AutoSwapPlugin.sol:409-430`
- **Confidence:** 80%
- **영향:** 이벤트에 기록된 가격과 실제 판단 가격 불일치

#### 문제 상세

`executeOrder`에서 oracle price를 **두 번** 조회합니다:

1. `_isOrderTriggered(order)` 내에서 trigger 조건 판단 시 조회
2. 스왑 실행 후 이벤트 방출 시 `_getCurrentPrice(order.tokenIn, order.tokenOut)` 재조회

```solidity
if (!_isOrderTriggered(order)) revert OrderNotTriggered();  // ← 1차 조회
// ... 스왑 실행 ...
uint256 currentPrice = _getCurrentPrice(order.tokenIn, order.tokenOut);  // ← 2차 조회
emit OrderExecuted(account, orderId, order.amountIn, amountOut, currentPrice);
```

스왑 자체가 가격에 영향을 미치므로, 1차와 2차 조회 결과가 다를 수 있습니다.

#### 수정 방안

price를 한 번만 조회하여 일관되게 사용:

```solidity
uint256 currentPrice = _getCurrentPrice(order.tokenIn, order.tokenOut);
if (!_isOrderTriggeredAtPrice(order, currentPrice)) revert OrderNotTriggered();
// ... 스왑 실행 ...
emit OrderExecuted(account, orderId, order.amountIn, amountOut, currentPrice);
```

---

### M-12: HookExecutionDataLib — 취약한 Calldata 파싱 휴리스틱

- **File:** `src/erc7579-hooks/HookExecutionDataLib.sol:39-73`
- **Confidence:** 80%
- **영향:** 모든 hook (PolicyHook, SpendingLimitHook, AuditHook)이 잘못된 target/value 추출

#### 문제 상세

execution path 감지가 **offset 값 기반 휴리스틱**에 의존합니다:

```solidity
// Path 2: offset == 0x40이면 ABI-wrapped execution으로 판단
if (msgData.length >= 96) {
    uint256 offset = uint256(bytes32(msgData[32:64]));
    if (offset == 0x40) {
        return decodeAbiWrappedExecution(msgData, msgValue);
    }
}

// Path 3: 그 외 → raw execution으로 판단
if (msgData.length >= 20) {
    target = address(bytes20(msgData[0:20]));
}
```

**위험:** ERC-7579 calldata 인코딩이 변경되거나, 실제 데이터의 두 번째 32바이트가 우연히 `0x40`이면 잘못된 path로 분기합니다.

#### 수정 방안

selector 기반 dispatch 도입 또는 calldata layout 버전 체크.

---

### M-15: RecurringPaymentExecutor — SafeERC20 미사용

- **File:** `src/erc7579-executors/RecurringPaymentExecutor.sol:~400`
- **Confidence:** 80%
- **영향:** non-reverting ERC-20 토큰에서 전송 실패 무시

#### 문제 상세

`_executeTokenPayment`에서 `IERC20.transfer` selector를 직접 사용합니다:

```solidity
bytes memory transferCall = abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount);
```

일부 ERC-20 토큰(USDT 등)은 `transfer`에서 `false`를 반환하되 revert하지 않습니다. 반환값을 검증하지 않으면 전송 실패가 무시됩니다.

#### 수정 방안

`SafeERC20.safeTransfer` 사용 또는 execute 결과에서 반환값 검증.

---

### M-16: AuditHook — Delay Queue Hash 불일치

- **File:** `src/erc7579-hooks/AuditHook.sol:163-164`
- **Confidence:** 80%
- **영향:** 고액 거래가 영구 차단

#### 문제 상세

`preCheck`의 `_getTxHash`는 **outer msgData** (Kernel의 execute selector 포함)로 hash를 생성하지만, `queueFlaggedTransaction`은 **inner (target, value, callData)** 로 hash를 생성합니다:

```solidity
// preCheck에서:
bytes32 txHash = _getTxHash(msg.sender, target, execValue, msgData);  // outer msgData

// queueFlaggedTransaction에서:
bytes32 txHash = keccak256(abi.encodePacked(msg.sender, target, value, callData));  // inner callData
```

Hash 불일치로 queue된 트랜잭션의 hash와 실행 시점의 hash가 달라, 고액 거래가 영구 차단될 수 있습니다.

#### 수정 방안

동일한 데이터 소스로 hash를 생성하도록 통일합니다.

---

### M-17: LendingExecutor — 캐시된 Borrow State 발산

- **File:** `src/erc7579-executors/LendingExecutor.sol:376-377`
- **Confidence:** 80%
- **영향:** borrow limit이 stale 데이터에 기반하여 과다/과소 차입 허용

#### 문제 상세

`borrowedAmounts`와 `totalBorrowed`가 **내부적으로만** 추적됩니다:

```solidity
if (store.config.maxBorrowLimit > 0
    && store.config.totalBorrowed + amount > store.config.maxBorrowLimit) {
    revert ExceedsBorrowLimit();
}
store.borrowedAmounts[asset] += amount;
store.config.totalBorrowed += amount;
```

다른 executor나 직접 호출을 통한 borrow/repay는 이 캐시에 반영되지 않습니다. 시간이 지남에 따라 캐시와 실제 pool state가 발산합니다.

#### 수정 방안

실제 lending pool에서 live borrow 금액을 조회하도록 변경:

```solidity
uint256 actualBorrowed = ILendingPool(LENDING_POOL).getBorrowBalance(account, asset);
if (store.config.maxBorrowLimit > 0 && actualBorrowed + amount > store.config.maxBorrowLimit) {
    revert ExceedsBorrowLimit();
}
```

---

### M-18: SessionKeyExecutor — isInitialized 오보

- **File:** `src/erc7579-executors/SessionKeyExecutor.sol:131`
- **Confidence:** 82%
- **영향:** 모듈 이중 설치 또는 실행 거부

#### 문제 상세

`isInitialized`가 `activeSessionKeys.length > 0`만 검사합니다:

```solidity
function isInitialized(address smartAccount) external view override returns (bool) {
    return accountStorage[smartAccount].activeSessionKeys.length > 0;
}
```

모든 session key를 해지하면 `isInitialized`가 `false`를 반환합니다. ERC-7579 account가 모듈 미설치로 판단하여:
- 이중 `onInstall` 호출 (데이터 초기화 위험)
- executor 실행 거부

#### 수정 방안

별도 `_initialized` 플래그 도입:

```solidity
function isInitialized(address smartAccount) external view override returns (bool) {
    return accountStorage[smartAccount]._initialized;
}
```

---

## LOW Issues (5건)

### L-05: Pragma Version 불일치

- **Files:** `src/erc7579-validators/WeightedECDSAValidator.sol:3`, `MultiChainValidator.sol:3`
- **Confidence:** 85%

두 파일이 `pragma solidity ^0.8.0`을 사용합니다. 코드베이스의 나머지는 `^0.8.28`입니다.

`^0.8.0`은 0.8.0~0.8.x 전체를 허용하여, 초기 0.8.x 버전의 known bug (ABI encoder v2 관련 등)에 노출될 수 있습니다.

**수정:** `^0.8.28`로 통일.

---

### L-06: SessionKeyExecutor — validUntil=0 의미 미정의

- **File:** `src/erc7579-executors/SessionKeyExecutor.sol:384-388`
- **Confidence:** 82%

```solidity
function _validateSession(SessionKeyConfig storage session) internal view {
    if (!session.isActive) revert SessionKeyNotActive();
    if (block.timestamp < session.validAfter) revert SessionKeyNotYetValid();
    if (block.timestamp > session.validUntil) revert SessionKeyExpired();
}
```

`validUntil == 0`이면 `block.timestamp > 0`이 항상 true이므로 session key가 **즉시 만료**됩니다. "만료 없음" 의도였다면 별도 처리가 필요합니다.

**수정:** `if (session.validUntil != 0 && block.timestamp > session.validUntil) revert SessionKeyExpired();`

---

### L-07: MicroLoanPlugin — 제3자 대출 상환 허용

- **File:** `src/erc7579-plugins/MicroLoanPlugin.sol:309-348`
- **Confidence:** 80%

`repay(uint256 loanId)`에 호출자 제한이 없어 **누구나** 다른 사람의 대출을 상환할 수 있습니다:

```solidity
function repay(uint256 loanId) external {
    // ← msg.sender == loan.borrower 체크 없음
    IERC20(config.borrowToken).safeTransferFrom(msg.sender, address(this), totalRepayment);
    IERC20(config.collateralToken).safeTransfer(loan.borrower, loan.collateralAmount);
}
```

담보는 repayer가 아닌 **borrower에게** 반환됩니다. 공격자가 원치 않는 시점에 강제 상환하여 담보를 반환시키는 griefing이 가능합니다.

**수정:** `if (msg.sender != loan.borrower) revert UnauthorizedRepayer();` 또는 borrower 승인 메커니즘.

---

### L-08: MicroLoanPlugin — onUninstall 에러명 반전

- **File:** `src/erc7579-plugins/MicroLoanPlugin.sol:162-170`
- **Confidence:** 80%

활성 대출이 **있을 때** `LoanNotActive()` 에러로 revert합니다. 의미가 정반대입니다:

```solidity
function onUninstall(bytes calldata) external payable override {
    for (uint256 i = 0; i < userLoanIds.length; i++) {
        if (loans[userLoanIds[i]].isActive) {
            revert LoanNotActive();  // ← 실제로는 "loan IS active"
        }
    }
}
```

**수정:** `error ActiveLoansExist();`로 교체.

---

### L-09: KernelFactory — createAccount senderCreator 제한

- **File:** `src/erc7579-smartaccount/factory/KernelFactory.sol:26`
- **Confidence:** 85%

`createAccount`이 `ENTRYPOINT.senderCreator()`만 호출 가능합니다:

```solidity
if (msg.sender != address(ENTRYPOINT.senderCreator())) {
    revert NotCalledFromEntryPoint();
}
```

`FactoryStaker.deployWithFactory`에서의 직접 호출이 항상 실패합니다. CREATE2 결정론성으로 실제 보안 리스크는 낮지만, `senderCreator` 주소가 변경되면 factory가 완전히 비기능됩니다.

**수정:** `FactoryStaker` 주소도 허용하거나, senderCreator를 동적으로 조회.

---

## Prioritized Fix Order

### Phase 1: Immediate — 자금 직접 리스크 (CRITICAL)

| 순서 | 이슈 | 파일 | 난이도 |
|------|------|------|--------|
| 1 | C-06 | FlashLoanFallback.sol | 낮음 (경로 2 제거) |
| 2 | C-07/C-08 | ECDSAValidator.sol, MultiChainValidator.sol | 낮음 (1줄 추가) |
| 3 | C-09 | WeightedECDSAValidator.sol | 낮음 (else 분기 수정) |
| 4 | C-02 | ExecutorManager.sol | 낮음 (조건 반전) |
| 5 | C-10 | OnRampPlugin.sol | 중간 (접근 제어 설계) |

### Phase 2: High Priority — 기능 장애/보안 약화

| 순서 | 이슈 | 파일 | 난이도 |
|------|------|------|--------|
| 6 | H-13 | WebAuthnValidator.sol | 높음 (P256 fallback 필요) |
| 7 | H-12 | StakingExecutor.sol | 낮음 (코드 순서 변경) |
| 8 | H-11 | LendingExecutor.sol | 낮음 (approve(0) 추가) |
| 9 | H-14 | SpendingLimitHook.sol | 중간 (로직 변경) |

### Phase 3: Medium Priority — 기능 정확성

| 순서 | 이슈 | 파일 | 난이도 |
|------|------|------|--------|
| 10 | M-07 | WeightedECDSAValidator.sol | 낮음 |
| 11 | M-09 | PolicyHook.sol | 낮음 |
| 12 | M-16 | AuditHook.sol | 중간 |
| 13 | M-08 | AuditHook.sol | 중간 |
| 14 | M-10 | RecurringPaymentExecutor.sol | 낮음 |
| 15 | M-15 | RecurringPaymentExecutor.sol | 낮음 |
| 16 | M-11 | AutoSwapPlugin.sol | 낮음 |
| 17 | M-12 | HookExecutionDataLib.sol | 높음 (재설계) |
| 18 | M-17 | LendingExecutor.sol | 중간 |
| 19 | M-18 | SessionKeyExecutor.sol | 낮음 |

### Phase 4: Low Priority — 방어적 개선

| 순서 | 이슈 | 파일 | 난이도 |
|------|------|------|--------|
| 20 | L-05 | WeightedECDSAValidator.sol, MultiChainValidator.sol | 낮음 |
| 21 | L-06 | SessionKeyExecutor.sol | 낮음 |
| 22 | L-08 | MicroLoanPlugin.sol | 낮음 |
| 23 | L-07 | MicroLoanPlugin.sol | 낮음 |
| 24 | L-09 | KernelFactory.sol | 중간 |
