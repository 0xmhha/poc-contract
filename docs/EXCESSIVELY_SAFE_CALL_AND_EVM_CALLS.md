# ExcessivelySafeCall 동작 방식 및 컨트랙트 호출 방식 정리

> EVM의 call/staticcall/delegatecall, raw calldata vs ABI selector, ExcessivelySafeCall 포함한 모든 호출 방식의 유사점·차이·장단점 정리

---

## 1. ExcessivelySafeCall이 하는 일

### 1.1 목적

**호출받는 컨트랙트를 거의 신뢰하지 않을 때** 사용한다.  
일반 `call()`과의 차이는 **반환 데이터(returndata)를 복사할 최대 바이트 수를 제한**한다는 점이다.

- 악의적 컨트랙트가 수 MB 크기의 returndata를 돌려주면, 호출자가 전부 복사하다가 **OOG(Out of Gas)** 가 나서 revert할 수 있다.
- ExcessivelySafeCall은 **returndata 복사량을 `_maxCopy` 바이트로 제한**해서, 이런 DoS를 막는다.

### 1.2 제공하는 함수 (2종만 존재)

| 함수 | EVM opcode | 용도 |
|------|------------|------|
| **excessivelySafeCall** | `call` | ETH 전송 가능, 상태 변경 가능한 외부 호출 |
| **excessivelySafeStaticCall** | `staticcall` | ETH 전송·상태 변경 불가, view/순수 조회용 |

**delegatecall 버전은 없다.** 라이브러리 코드에 delegatecall 래퍼가 없음.

### 1.3 excessivelySafeCall 동작 (의사 코드)

```
입력: _target, _gas, _value, _maxCopy, _calldata (bytes memory)

1. _returnData = new bytes(_maxCopy)  // 최대 _maxCopy 크기 버퍼

2. assembly:
   _success := call(_gas, _target, _value,
                    add(_calldata, 0x20), mload(_calldata),  // inloc, inlen
                    0, 0)  // outloc=0, outlen=0 → returndata는 메모리에 안 쓰고, 나중에 returndatasize/returndatacopy로 처리

3. _toCopy = min(returndatasize(), _maxCopy)   // 복사할 양 상한

4. returndatacopy(_returnData[32:], 0, _toCopy)
   mstore(_returnData, _toCopy)  // length

5. return (_success, _returnData)
```

- **실제 호출**: EVM `call` 한 번 (gas, target, value, calldata 전달).
- **반환 처리**: returndata는 **전부 복사하지 않고**, 최대 `_maxCopy` 바이트만 복사해 `bytes`로 돌려준다.  
  그래서 callee가 아무리 큰 데이터를 돌려줘도 호출자 쪽 메모리/가스가 폭증하지 않는다.

### 1.4 excessivelySafeStaticCall 동작

위와 동일한 로직이지만, assembly 안에서 **`call` 대신 `staticcall`** 을 쓴다.

- `staticcall`: ETH 전송 불가(`_value` 없음), callee가 상태를 바꾸면 revert.
- returndata 캡핑 방식은 `excessivelySafeCall`과 같다.

### 1.5 ModuleLib에서의 사용 예

```solidity
ExcessivelySafeCall.excessivelySafeCall(
    module,           // _target
    gasleft(),        // _gas
    0,                // _value (ETH 0)
    0,                // _maxCopy → returndata 0바이트만 복사 (안 씀)
    abi.encodeWithSelector(IModule.onUninstall.selector, deinitData)  // _calldata
);
```

- **호출 종류**: 일반 **call** (ETH 0, 상태 변경 가능).
- **calldata**: ABI 인코딩으로 **함수 selector + 인자** 지정 (`onUninstall(deinitData)`).
- **반환**: `(bool success, bytes memory)`. `_maxCopy=0`이라 returndata는 비어 있음.  
  **revert 여부**: callee가 revert해도 **호출자(caller)는 revert하지 않고** `success == false`만 받는다. (일반 `call`이면 revert 전파됨 — 아래 2.2 참고.)

---

## 2. call / staticcall / delegatecall 구분

EVM 수준에서 컨트랙트를 “실행”하는 방식은 세 가지다.

| 구분 | call | staticcall | delegatecall |
|------|------|------------|--------------|
| **Opcode** | `CALL` | `STATICCALL` | `DELEGATECALL` |
| **실행 컨텍스트** | 대상 주소의 **코드**를 **대상의 컨텍스트**에서 실행 | 같은데 **읽기 전용** (상태 변경 시 revert) | **현재 컨트랙트의 컨텍스트**에서, **대상의 코드**만 실행 |
| **msg.sender** | 호출한 컨트랙트 주소 | 동일 | **변경 없음** (원래 트랜잭션 발신자 유지) |
| **msg.value** | 전달 가능 | **0만 허용** | **0만 허용** |
| **storage** | 대상 컨트랙트의 storage | 대상의 storage (쓰기 시 revert) | **호출자(현재 컨트랙트)의 storage** |
| **selfdestruct / ETH 수신** | 대상 주소 기준 | 대상 기준 (제한적) | **호출자 주소** 기준 |
| **반환** | (success, data) | (success, data) | (success, data) |

### 2.1 call

- “다른 컨트랙트의 함수를 **그 컨트랙트 맥락에서** 한 번 실행”한다.
- ETH 보낼 수 있고, 대상의 storage를 바꿀 수 있다.
- Solidity: `(bool ok, bytes memory data) = target.call{gas: g, value: v}(cd)` 또는 `target.func{value: v}()` (내부적으로 call).

### 2.2 staticcall

- call과 비슷하지만 **실행이 read-only**라고 가정한다.
- 상태 변경(sstore, create, call with value, selfdestruct 등)을 하면 **전체 트랜잭션이 revert**한다.
- view/pure 함수나 조회 전용 로직에 사용.

### 2.3 delegatecall

- “**지금 이 컨트랙트의** storage/balance/주소로, **대상의 코드**만 가져와 실행”한다.
- `msg.sender`, `address(this)`는 **호출자 컨트랙트** 그대로다.
- 프록시/업그레이드 패턴, 라이브러리 호출에 쓰인다.
- **위험**: 대상 코드를 완전히 신뢰해야 함. 악의적 코드면 호출자 storage/ETH를 망가뜨릴 수 있다.

### 2.4 revert 전파

- **일반 call/staticcall/delegatecall**: callee가 revert하면 **호출자도 revert** (revert 메시지/데이터 전파).
- **ExcessivelySafeCall**: 내부적으로 `call`/`staticcall`을 쓰지만, **returndata 크기만 제한**할 뿐, **revert 자체를 “삼키는” 장치는 이 라이브러리에는 없다.**  
  단, Solidity의 일반 `contract.func()` 호출은 실패 시 revert하고, **low-level `call()`은 실패 시 false만 반환하고 revert하지 않는다.**  
  ExcessivelySafeCall은 low-level `call`을 assembly로 하므로, **callee가 revert하면 `_success == false`로 반환되고, 호출자 트랜잭션은 그대로 진행**한다 (호출자가 반환값을 보고 revert하도록 하지 않는 한).  
  따라서 “ExcessivelySafeCall을 쓰면 callee revert가 호출자까지 전파되지 않는다”는 의미에서는 **revert를 삼키는 것처럼 동작**한다.

---

## 3. Calldata 넣는 두 가지 방식

컨트랙트에 “이 함수 이 인자로 실행해라”를 넘기는 방법은 두 가지다.

### 3.1 Raw calldata (바이트열 그대로)

- **형식**: `bytes memory` 또는 `bytes calldata`.  
  앞 4바이트 = 함수 selector (함수 시그니처 keccak256 앞 4바이트), 그 뒤 = ABI 인코딩된 인자.
- **만드는 방법**:
  - 직접: `bytes.concat(bytes4(selector), abi.encode(arg1, arg2))`
  - 또는 `abi.encodeWithSelector(selector, arg1, arg2)` → 이게 곧 “selector + 인자” raw calldata와 동일한 bytes.
- **호출**:  
  `target.call(cd)` 또는 `target.call(abi.encodeWithSelector(..., ...))`.  
  target은 “이 바이트열을 그대로 받아서 실행”한다.  
  즉, **어떤 함수가 불릴지는 전적으로 이 bytes 앞 4바이트(selector) + 전체 인코딩에 달려 있다.**

### 3.2 ABI + contract 함수 selector (지정 함수 호출)

- **형식**: Solidity 단에서 “특정 함수”를 지정해서 호출하는 방식.
- **만드는 방법**:
  - `abi.encodeWithSelector(IModule.onUninstall.selector, deinitData)`  
    → `onUninstall(bytes)`의 selector + `deinitData` 한 개 인자 인코딩.
  - 또는 `abi.encodeWithSignature("onUninstall(bytes)", deinitData)` (문자열에서 selector 계산).
- **의미**:  
  “이 컨트랙트의 **이 함수**를 **이 인자**로 호출해라”를, **같은 ABI 규칙(selector + 인자 인코딩)** 으로 bytes로 만든 뒤, low-level call에 넣는 것이다.  
  결과적으로 **넣는 calldata 내용은 3.1과 같은 raw bytes**다.  
  차이는 “컴파일 타임에 함수가 정해져 있고, 타입이 맞는지 컴파일러가 검사해 준다”는 점이다.

### 3.3 정리

| 방식 | Calldata 내용 | 장점 | 단점 |
|------|----------------|------|------|
| **Raw calldata** | 직접 bytes 구성 (selector + abi.encode 등) | 유연함, 동적 선택 가능 | selector/인자 실수 시 런타임에만 드러남 |
| **ABI + selector** | `abi.encodeWithSelector(Interface.func.selector, args...)` | 함수/인자 타입 체크, 가독성 | 호출할 함수를 코드에 고정해야 함 |

둘 다 최종적으로는 **같은 형태의 bytes (selector 4B + 인자)** 가 되어, `call(cd)`로 보내면 동일하게 “지정한 함수”가 실행된다.

---

## 4. 컨트랙트를 실행하는 “모든” 방식 비교

실행 경로를 크게 나누면 아래와 같다.

### 4.1 고수준 호출 (Solidity)

- **방식**: `Contract c = Contract(addr); c.func(args);` 또는 `IContract(addr).func(args);`
- **내부**: 컴파일러가 적절한 `call`/`staticcall`을 만들고, calldata는 `abi.encodeWithSelector(func.selector, ...)` 형태.
- **revert**: 실패 시 **호출자 트랜잭션까지 revert**.

### 4.2 Low-level call

- **방식**: `addr.call{gas, value}(cd)` 또는 assembly `call(gas, addr, value, inloc, inlen, outloc, outlen)`.
- **calldata**: 직접 bytes (보통 `abi.encodeWithSelector(...)`로 만든다).
- **revert**: callee가 revert해도 **호출자 쪽에서는 false 반환** (revert 전파 안 함, unless 호출자가 반환값 보고 revert 처리).

### 4.3 Low-level staticcall

- **방식**: `addr.staticcall(cd)` 또는 assembly `staticcall(...)`.
- **제한**: value=0, callee가 상태 변경 시 revert.
- **revert**: call과 마찬가지로, low-level이면 호출자는 true/false만 받고, 전파는 호출자 코드에 따라 결정.

### 4.4 Low-level delegatecall

- **방식**: `addr.delegatecall(cd)` 또는 assembly `delegatecall(...)`.
- **컨텍스트**: 호출자의 storage/balance/address(this)/msg.sender.
- **revert**: callee revert 시 호출자도 revert (일반적으로).

### 4.5 ExcessivelySafeCall (call / staticcall만)

- **방식**:  
  `excessivelySafeCall(target, gas, value, maxCopy, calldata)` → 내부적으로 **call**.  
  `excessivelySafeStaticCall(target, gas, maxCopy, calldata)` → 내부적으로 **staticcall**.
- **차이**: returndata를 **최대 maxCopy 바이트만** 복사.  
  내부가 low-level call/staticcall이므로, **callee revert 시 success=false 반환, 호출자 트랜잭션은 계속 진행** (revert “삼킴” 효과).
- **delegatecall**: **없음.**

---

## 5. 유사점과 차이점 요약

### 5.1 유사점

- 모두 **특정 주소의 코드를 실행**한다 (delegatecall은 “현재 컨텍스트에서” 실행).
- **calldata**는 공통으로 “4바이트 selector + ABI 인코딩 인자” 형태를 쓴다.
- **반환**은 (success, returndata) 형태로 받을 수 있다 (고수준에서는 예외로 처리).

### 5.2 차이점

| 항목 | call | staticcall | delegatecall | ExcessivelySafeCall |
|------|------|------------|--------------|---------------------|
| 컨텍스트 | callee | callee (read-only) | **caller** | call 또는 staticcall과 동일 |
| ETH 전송 | 가능 | 불가 | 불가 | call 버전만 가능 |
| 상태 변경 | callee storage | 불가(시 revert) | **caller storage** | call/staticcall 따름 |
| returndata 크기 제한 | 없음 | 없음 | 없음 | **있음 (maxCopy)** |
| callee revert 시 호출자 | low-level이면 false만 반환 | 동일 | 보통 revert 전파 | **false 반환, 호출자 revert 안 함** |

---

## 6. 장단점 정리

### 6.1 call

- **장점**: 일반적인 외부 호출, ETH/상태 변경 가능, 사용법 단순.
- **단점**: 악의적 callee가 큰 returndata로 DoS 가능; low-level 사용 시 revert 미전파로 실패 처리 누락 가능.

### 6.2 staticcall

- **장점**: 상태 변경 불가로 “조회만” 할 때 안전, view 호출에 적합.
- **단점**: ETH/상태 변경이 필요하면 쓸 수 없음.

### 6.3 delegatecall

- **장점**: 프록시/라이브러리 패턴, 호출자 storage 재사용.
- **단점**: 보안 위험 큼(대상 코드가 호출자 상태/ETH 통제), 잘못 쓰면 컨트랙트 파괴.

### 6.4 Raw calldata로 call

- **장점**: 동적으로 함수/인자 구성 가능.
- **단점**: selector/인자 인코딩 실수 시 런타임에만 드러남.

### 6.5 ABI + selector로 호출

- **장점**: 타입·함수명이 코드에 드러나고, 컴파일 타임 체크.
- **단점**: 호출할 함수가 코드에 고정됨.

### 6.6 ExcessivelySafeCall

- **장점**:  
  - returndata DoS 방지 (maxCopy 제한).  
  - callee revert 시 호출자가 **선택적으로** 실패만 받고 계속 진행 가능 (예: ModuleLib.uninstallModule에서 onUninstall 실패해도 계정이 revert 안 하도록).
- **단점**:  
  - **delegatecall 없음.**  
  - 스펙(ERC-7579)은 “onUninstall 실패 시 MUST revert”인데, 현재 사용 방식은 그와 어긋남.  
  - returndata를 잘라쓰므로, 호출자가 반환값을 풀어 쓸 때는 maxCopy/잘림을 고려해야 함.

---

## 7. 한 줄 요약

- **ExcessivelySafeCall**: **call** 또는 **staticcall**만 제공하며, **returndata 복사량을 제한**해 DoS를 막고, low-level call이라 **callee revert 시 false만 반환**해 “revert를 삼키는” 효과가 있다. **delegatecall은 지원하지 않는다.**
- **call / staticcall / delegatecall**: 실행 **컨텍스트**(누리 storage, 누가 msg.sender인지)와 **ETH·상태 변경 허용 여부**가 다르다.
- **calldata**: “raw bytes”로 넘기든, “ABI + selector”로 넘기든, 최종 형태는 **selector 4B + 인자**이고, 지정 함수 호출은 둘 다 같은 방식이다.
- **실행 방식별**: 고수준 호출은 revert 전파, low-level call/staticcall은 false 반환, ExcessivelySafeCall은 false + returndata 캡 제한, delegatecall은 별도이고 ExcessivelySafeCall에는 없다.
