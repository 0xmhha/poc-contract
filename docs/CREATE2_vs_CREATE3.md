# CREATE2 vs CREATE3 비교 분석

## 개요

EVM에서 컨트랙트를 결정론적(deterministic) 주소에 배포하는 두 가지 방법을 비교한다.
EntryPoint와 같은 싱글톤 컨트랙트를 모든 체인에서 동일한 주소로 배포하기 위해 사용한다.

---

## EVM의 컨트랙트 생성 방식

| 방식 | Opcode | 주소 결정 요소 |
|------|--------|---------------|
| CREATE | `0xf0` | `keccak256(RLP(deployer, nonce))` |
| CREATE2 | `0xf5` | `keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))` |
| CREATE3 | CREATE2 + CREATE 조합 | `deployer + salt` (initCode 무관) |

> **initCode**: 컨트랙트의 컴파일된 creation bytecode + ABI-encoded constructor arguments.
> EVM이 initCode를 실행하면 runtime bytecode가 반환되어 체인에 저장된다.

---

## CREATE2

### 주소 계산 공식

```
address = keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))[12:]
```

### 동작 방식

```
Deployer ──CREATE2──> Contract
                      (initCode가 주소에 영향)
```

### 장점

- EVM 네이티브 opcode (EIP-1014)
- 단일 트랜잭션으로 배포 완료
- 가스비가 상대적으로 저렴
- 배포 전 주소 예측 가능

### 단점

- **initCode가 주소 계산에 포함됨**
  - 컨트랙트 코드 한 줄 수정 → 주소 변경
  - constructor 인자 변경 → 주소 변경
  - Solidity 컴파일러 버전 변경 → 주소 변경
  - optimizer 설정 변경 → 주소 변경
- 동일 주소 유지를 위해 바이트코드를 완전히 동일하게 관리해야 함
- 크로스체인 배포 시 컴파일 환경까지 일치시켜야 함

### 주소가 바뀌는 상황 예시

```solidity
// v1: 주소 = 0xABC...
contract EntryPoint {
    uint256 public version = 1;
}

// v2: 코드 변경 → initCode 변경 → 주소 = 0xDEF... (다른 주소!)
contract EntryPoint {
    uint256 public version = 2;
}
```

---

## CREATE3

### 주소 계산 공식

```
proxy_address  = keccak256(0xff ++ deployer ++ salt ++ keccak256(PROXY_INITCODE))[12:]
final_address  = keccak256(RLP(proxy_address, 1))[12:]
```

`PROXY_INITCODE`는 상수이므로, **salt와 deployer만으로 최종 주소가 결정**된다.

### 동작 방식 (2단계)

```
Step 1:  Deployer ──CREATE2──> Proxy (고정된 미니 컨트랙트)
Step 2:  Proxy    ──CREATE───> Contract (실제 배포할 컨트랙트)

┌──────────────────────────────────────────────────────────┐
│  Step 1: CREATE2로 프록시 배포                            │
│                                                          │
│  proxy = CREATE2(deployer, salt, PROXY_INITCODE)         │
│                                                          │
│  PROXY_INITCODE = 0x67363d3d37363d34f03d5260086018f3     │
│  → calldata를 받아서 CREATE를 실행하는 15바이트 미니 코드  │
│  → 항상 동일한 바이트코드이므로 proxy 주소도 항상 동일     │
├──────────────────────────────────────────────────────────┤
│  Step 2: 프록시가 CREATE로 실제 컨트랙트 배포             │
│                                                          │
│  final = CREATE(proxy_address, nonce=1, initCode)        │
│                                                          │
│  → proxy_address가 고정 + nonce가 항상 1 (첫 트랜잭션)   │
│  → initCode가 무엇이든 final_address는 동일              │
└──────────────────────────────────────────────────────────┘
```

### 장점

- **initCode와 무관하게 주소 결정**
  - 컨트랙트 코드 수정해도 주소 유지
  - constructor 인자 변경해도 주소 유지
  - 컴파일러/optimizer 설정 변경해도 주소 유지
- 크로스체인 배포 시 동일 salt만 사용하면 동일 주소 보장
- Solady 라이브러리에서 검증된 구현 제공

### 단점

- 2단계 배포로 인한 추가 가스비 (프록시 생성 비용)
- EVM 네이티브가 아닌 라이브러리 레벨 패턴
- 동일 salt로 재배포 불가 (프록시가 이미 존재하므로)

### 주소가 유지되는 예시

```solidity
// v1: salt = keccak256("entrypoint-v1") → 주소 = 0xABC...
contract EntryPoint {
    uint256 public version = 1;
}

// v2: 같은 salt 사용 → 주소 = 0xABC... (동일!)
// (단, 같은 deployer에서 같은 salt로는 한 번만 배포 가능)
contract EntryPoint {
    uint256 public version = 2;
}
```

---

## 비교 요약

| 항목 | CREATE2 | CREATE3 |
|------|---------|---------|
| **주소 결정 요소** | deployer + salt + initCode | deployer + salt |
| **initCode 의존성** | 있음 (바이트코드가 주소에 영향) | 없음 |
| **코드 수정 시 주소** | 변경됨 | **유지됨** |
| **컴파일러 변경 시** | 변경됨 | **유지됨** |
| **가스비** | 더 저렴 | 프록시 생성분 추가 (~수만 gas) |
| **배포 단계** | 1단계 | 2단계 (프록시 경유) |
| **동일 salt 재배포** | 가능 (selfdestruct 후) | 불가 |
| **EVM 네이티브** | O (EIP-1014) | X (라이브러리 패턴) |
| **크로스체인 일관성** | 컴파일 환경까지 동일해야 함 | salt만 동일하면 됨 |
| **적합한 사용처** | initCode가 고정된 컨트랙트 | 싱글톤, 크로스체인 배포 |

---

## 이 프로젝트에서의 선택: CREATE3

EntryPoint 배포에 CREATE3을 선택한 이유:

1. **크로스체인 주소 일관성**: 모든 체인에서 동일한 EntryPoint 주소 보장
2. **코드 변경에 대한 유연성**: 버그 수정이나 업그레이드 시에도 주소 유지 가능
3. **컴파일 환경 독립**: Solidity 버전이나 optimizer 설정에 무관
4. **검증된 구현**: Solady 라이브러리의 CREATE3 사용 (이미 프로젝트 의존성에 포함)

### 사용 방법 (Solady)

```solidity
import {CREATE3} from "solady/utils/CREATE3.sol";

// 배포
bytes32 salt = keccak256("stable-net-entrypoint-v1");
address deployed = CREATE3.deployDeterministic(
    type(EntryPoint).creationCode,
    salt
);

// 주소 사전 예측 (배포 전에도 가능)
address predicted = CREATE3.predictDeterministicAddress(salt, deployer);
```

---

## 참고 자료

- [EIP-1014: CREATE2](https://eips.ethereum.org/EIPS/eip-1014)
- [Solady CREATE3](https://github.com/vectorized/solady/blob/main/src/utils/CREATE3.sol)
- [0xSequence CREATE3 (원본)](https://github.com/0xSequence/create3)
