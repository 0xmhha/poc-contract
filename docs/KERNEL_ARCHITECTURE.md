# Kernel Smart Account Architecture Guide

> ERC-7579 Smart Account (Kernel)의 아키텍처와 EIP-7702 통합 가이드

## 목차

1. [개요](#개요)
2. [Validators 역할](#validators-역할)
3. [Kernel 사용 방식](#kernel-사용-방식)
4. [방식 1: Proxy 모델](#방식-1-proxy-모델-kernelfactory)
5. [방식 2: EIP-7702 모델](#방식-2-eip-7702-모델)
6. [전체 아키텍처](#전체-아키텍처)
7. [배포 및 초기화](#배포-및-초기화)
8. [비교 및 선택 가이드](#비교-및-선택-가이드)

---

## 개요

Kernel은 ERC-7579 표준을 구현한 모듈러 Smart Account입니다. 두 가지 방식으로 사용할 수 있습니다:

1. **Proxy 모델**: KernelFactory를 통해 새로운 Smart Account 주소 생성
2. **EIP-7702 모델**: 기존 EOA가 Kernel을 delegate로 설정하여 Smart Account 기능 획득

### 핵심 컴포넌트

| 컴포넌트 | 역할 |
|---------|------|
| **Kernel** | ERC-7579 Smart Account 구현체 (Singleton) |
| **KernelFactory** | Kernel Proxy 인스턴스 생성 |
| **FactoryStaker** | Factory의 EntryPoint 스테이킹 관리 |
| **Validators** | UserOperation 서명 검증 모듈 |
| **Hooks** | 실행 전/후 로직 (optional) |
| **Executors** | 외부 트리거 실행 모듈 |

---

## Validators 역할

Validator는 **UserOperation의 서명을 검증**하는 ERC-7579 모듈입니다.

### 사용 가능한 Validators

| Validator | 용도 | 사용 사례 |
|-----------|------|----------|
| `ECDSAValidator` | 단일 EOA 서명 검증 | 개인 지갑 |
| `MultiSigValidator` | N-of-M 다중 서명 | 팀/회사 지갑 |
| `WeightedECDSAValidator` | 가중치 기반 다중 서명 | 거버넌스 지갑 |
| `WebAuthnValidator` | 패스키/생체인증 | 모바일 지갑, 하드웨어 키 |
| `MultiChainValidator` | 크로스체인 서명 | 멀티체인 지갑 |

### ECDSAValidator 동작 방식

```solidity
contract ECDSAValidator is IValidator {
    // 각 Smart Account(Kernel)별로 owner 저장
    mapping(address => EcdsaValidatorStorage) public ecdsaValidatorStorage;

    // Kernel이 validator를 설치할 때 호출됨
    function onInstall(bytes calldata _data) external payable {
        address owner = address(bytes20(_data[0:20]));
        ecdsaValidatorStorage[msg.sender].owner = owner;  // msg.sender = Kernel 주소
    }

    // UserOperation 서명 검증
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash)
        external returns (uint256)
    {
        address owner = ecdsaValidatorStorage[msg.sender].owner;
        if (owner == ECDSA.recover(userOpHash, userOp.signature)) {
            return SIG_VALIDATION_SUCCESS_UINT;
        }
        return SIG_VALIDATION_FAILED_UINT;
    }
}
```

### Validator 선택 기준

```
개인 지갑 (단일 사용자)
    └── ECDSAValidator (기본)
    └── WebAuthnValidator (패스키 사용 시)

팀/회사 지갑
    └── MultiSigValidator (2-of-3, 3-of-5 등)
    └── WeightedECDSAValidator (가중치 필요 시)

고급 사용 사례
    └── MultiChainValidator (멀티체인)
    └── Custom Validator (커스텀 로직)
```

---

## Kernel 사용 방식

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Kernel 사용 방식 비교                                 │
├─────────────────────────────────────┬───────────────────────────────────────┤
│     방식 1: Proxy 모델 (ERC-4337)    │      방식 2: EIP-7702 모델             │
│         (KernelFactory 사용)         │      (EOA → Delegate)                 │
├─────────────────────────────────────┼───────────────────────────────────────┤
│                                     │                                       │
│  ┌──────────────┐                   │   ┌──────────────┐                    │
│  │ User (EOA)   │                   │   │ User (EOA)   │                    │
│  │ 0xABC...     │                   │   │ 0xABC...     │                    │
│  └──────┬───────┘                   │   └──────┬───────┘                    │
│         │ 서명                       │          │ EIP-7702 Authorization     │
│         ▼                           │          ▼                            │
│  ┌──────────────┐                   │   ┌──────────────────────────────┐   │
│  │ Smart Wallet │                   │   │ EOA.code = 0xef0100 + Kernel │   │
│  │ (Proxy)      │                   │   │ (EOA가 Kernel 로직 실행)       │   │
│  │ 0xDEF...     │ ← 새 주소         │   │ 0xABC... ← 기존 주소 유지      │   │
│  └──────┬───────┘                   │   └──────┬───────────────────────┘   │
│         │ delegatecall              │          │ 직접 실행                  │
│         ▼                           │          ▼                            │
│  ┌──────────────┐                   │   ┌──────────────┐                    │
│  │ Kernel Impl  │                   │   │ Kernel Impl  │                    │
│  │ (Singleton)  │                   │   │ (Singleton)  │                    │
│  └──────────────┘                   │   └──────────────┘                    │
│                                     │                                       │
│  Storage: Proxy 주소에 저장          │   Storage: EOA 주소에 저장            │
│  주소: 새로운 주소 생성               │   주소: 기존 EOA 주소 유지             │
│                                     │                                       │
└─────────────────────────────────────┴───────────────────────────────────────┘
```

---

## 방식 1: Proxy 모델 (KernelFactory)

### 개요

KernelFactory가 ERC-1967 Proxy를 생성하고, 각 Proxy가 Kernel 구현체를 참조합니다.

### 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│                    Proxy 모델 구조                               │
└─────────────────────────────────────────────────────────────────┘

   ┌─────────────────┐
   │  KernelFactory  │
   │  (Singleton)    │
   └────────┬────────┘
            │ createAccount(initData, salt)
            │
            ├──────────────────────────────────────┐
            │                                      │
            ▼                                      ▼
   ┌─────────────────┐                    ┌─────────────────┐
   │  Proxy (User A) │                    │  Proxy (User B) │
   │  0x1111...      │                    │  0x2222...      │
   │                 │                    │                 │
   │  Storage:       │                    │  Storage:       │
   │  - rootValidator│                    │  - rootValidator│
   │  - owner        │                    │  - owner        │
   └────────┬────────┘                    └────────┬────────┘
            │                                      │
            │ delegatecall                         │ delegatecall
            │                                      │
            └──────────────┬───────────────────────┘
                           │
                           ▼
                  ┌─────────────────┐
                  │  Kernel Impl    │
                  │  (Singleton)    │
                  │  0xKERNEL...    │
                  │                 │
                  │  - 로직만 제공    │
                  │  - 상태 없음      │
                  └─────────────────┘
```

### KernelFactory 코드

```solidity
contract KernelFactory {
    address public immutable IMPLEMENTATION;  // Kernel 구현체 주소

    constructor(address _impl) {
        IMPLEMENTATION = _impl;
    }

    function createAccount(bytes calldata data, bytes32 salt) public payable returns (address) {
        // 1. deterministic salt 생성
        bytes32 actualSalt = keccak256(abi.encodePacked(data, salt));

        // 2. ERC-1967 Proxy 생성 (또는 기존 주소 반환)
        (bool alreadyDeployed, address account) =
            LibClone.createDeterministicERC1967(msg.value, IMPLEMENTATION, actualSalt);

        // 3. 새로 생성된 경우 초기화
        if (!alreadyDeployed) {
            (bool success,) = account.call(data);  // data = initialize() 호출
            if (!success) revert InitializeError();
        }

        return account;
    }

    function getAddress(bytes calldata data, bytes32 salt) public view returns (address) {
        bytes32 actualSalt = keccak256(abi.encodePacked(data, salt));
        return LibClone.predictDeterministicAddressERC1967(IMPLEMENTATION, actualSalt, address(this));
    }
}
```

### 초기화 흐름

```
1. User가 Smart Account 생성 요청
   │
   ▼
2. KernelFactory.createAccount(initData, salt) 호출
   │
   │  initData = Kernel.initialize(
   │    rootValidator,    // ECDSAValidator → ValidationId
   │    hook,             // IHook (optional, address(0))
   │    validatorData,    // owner EOA 주소 (20 bytes)
   │    hookData,         // hook 설정 (empty)
   │    initConfig        // 추가 모듈 설치 (empty array)
   │  )
   │
   ▼
3. ERC-1967 Proxy 생성
   │
   ▼
4. Proxy.call(initData) → Kernel.initialize() 실행
   │
   │  - rootValidator 설정
   │  - Validator.onInstall() 호출 → owner 등록
   │
   ▼
5. Smart Account 준비 완료
```

### 사용 예시 (TypeScript)

```typescript
import { ethers } from "ethers";

// 1. 컨트랙트 인스턴스
const kernelFactory = new ethers.Contract(KERNEL_FACTORY_ADDRESS, KernelFactoryABI, signer);
const kernel = new ethers.Contract(KERNEL_ADDRESS, KernelABI, signer);
const ecdsaValidator = new ethers.Contract(ECDSA_VALIDATOR_ADDRESS, ECDSAValidatorABI, signer);

// 2. ValidationId 생성 (validator 타입 + 주소)
// ValidationId = bytes21 = validationType(1 byte) + address(20 bytes)
const VALIDATION_TYPE_VALIDATOR = 0x01;
const validationId = ethers.utils.hexConcat([
  ethers.utils.hexlify([VALIDATION_TYPE_VALIDATOR]),
  ECDSA_VALIDATOR_ADDRESS
]);

// 3. initialize 호출 데이터 생성
const initData = kernel.interface.encodeFunctionData("initialize", [
  validationId,           // rootValidator
  ethers.constants.AddressZero,  // hook (no hook)
  ownerEOA,               // validatorData (20 bytes owner address)
  "0x",                   // hookData
  []                      // initConfig
]);

// 4. Smart Account 생성
const salt = ethers.utils.randomBytes(32);
const tx = await kernelFactory.createAccount(initData, salt);
const receipt = await tx.wait();

// 5. 생성된 주소 확인
const accountAddress = await kernelFactory.getAddress(initData, salt);
console.log("Smart Account:", accountAddress);
```

---

## 방식 2: EIP-7702 모델

### 개요

EIP-7702를 사용하면 기존 EOA가 스마트 컨트랙트 코드를 delegate로 설정하여 Smart Account 기능을 획득합니다.

### EIP-7702 동작 원리

```
┌─────────────────────────────────────────────────────────────────┐
│                    EIP-7702 Authorization                        │
└─────────────────────────────────────────────────────────────────┘

1. Authorization 서명

   EOA (0xABC...) 서명:
   ┌─────────────────────────────────────────────────────────┐
   │  AUTH = sign(                                           │
   │    MAGIC || chain_id || nonce || address               │
   │  )                                                      │
   │                                                         │
   │  MAGIC = 0x05 (EIP-7702 type)                          │
   │  address = Kernel Implementation 주소                   │
   └─────────────────────────────────────────────────────────┘

2. 트랜잭션 실행 후 EOA 상태

   Before:                          After:
   ┌──────────────────┐            ┌──────────────────────────────┐
   │ EOA (0xABC...)   │            │ EOA (0xABC...)               │
   │                  │    ──▶     │                              │
   │ code: (empty)    │            │ code: 0xef0100 + KernelAddr  │
   │ storage: (empty) │            │ storage: (empty, 초기화 전)   │
   └──────────────────┘            └──────────────────────────────┘

3. 코드 실행 시

   EOA.someFunction() 호출 시:

   ┌──────────────────────────────────────────────────────────────┐
   │  EVM이 EOA.code를 확인                                        │
   │  → 0xef0100 prefix 감지                                       │
   │  → 뒤따르는 20 bytes를 delegate 주소로 해석                    │
   │  → delegate(Kernel)의 코드를 EOA context에서 실행              │
   │  → Storage는 EOA 주소에 저장됨                                 │
   └──────────────────────────────────────────────────────────────┘
```

### EIP-7702 + EntryPoint 통합

```
┌─────────────────────────────────────────────────────────────────┐
│                    EIP-7702 + ERC-4337 흐름                      │
└─────────────────────────────────────────────────────────────────┘

1. UserOperation 생성

   UserOperation {
     sender: 0xABC...,              // EOA 주소
     nonce: ...,
     initCode: 0x7702 + [initData], // EIP-7702 marker
     callData: ...,
     signature: ...
   }

2. EntryPoint 처리

   handleOps() {
     // initCode가 0x7702로 시작하면 EIP-7702 mode
     if (_isEip7702InitCode(initCode)) {
       // sender가 이미 delegate 설정되어 있는지 확인
       address delegate = _getEip7702Delegate(sender);

       // delegate(Kernel)이 맞는지 검증
       require(bytes3(sender.code) == EIP7702_PREFIX);

       // initData가 있으면 초기화 수행
       if (initCode.length > 20) {
         sender.call(initCode[20:]);  // initialize() 호출
       }
     }

     // 이후 일반 ERC-4337 흐름과 동일
     sender.validateUserOp(userOp, userOpHash);
     sender.execute(...);
   }
```

### Kernel의 EIP-7702 지원

```solidity
// Kernel.sol
contract Kernel {
    function initialize(
        ValidationId _rootValidator,
        IHook hook,
        bytes calldata validatorData,
        bytes calldata hookData,
        bytes[] calldata initConfig
    ) external {
        ValidationStorage storage vs = _validationStorage();

        // EIP-7702 체크: 이미 delegate가 설정된 EOA인지 확인
        if (ValidationId.unwrap(vs.rootValidator) != bytes21(0)
            || bytes3(address(this).code) == EIP7702_PREFIX) {
            revert AlreadyInitialized();
        }

        // 초기화 진행...
        _setRootValidator(_rootValidator);
        // ...
    }
}
```

### EIP-7702 Storage 구조

```
┌──────────────────────────────────────────────────────────────────┐
│              EOA with EIP-7702 Delegation                        │
│              (0xABC...)                                          │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Code: 0xef0100 + Kernel Address (23 bytes)                     │
│                                                                  │
│  Storage (Kernel의 storage layout이 EOA에 저장됨):               │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │ Slot 0x...: ValidationStorage                              │ │
│  │   - rootValidator: ValidationId                            │ │
│  │   - currentNonce: uint32                                   │ │
│  │   - validNonceFrom: uint32                                 │ │
│  │   - validationConfig: mapping                              │ │
│  │   - allowedSelectors: mapping                              │ │
│  ├────────────────────────────────────────────────────────────┤ │
│  │ Slot 0x...: ExecutorStorage                                │ │
│  │   - executorConfig: mapping                                │ │
│  ├────────────────────────────────────────────────────────────┤ │
│  │ Slot 0x...: SelectorStorage                                │ │
│  │   - selectorConfig: mapping                                │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  Native Balance: ETH/KRC 보유량 (기존 EOA 잔액 유지)              │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 전체 아키텍처

### UserOperation 실행 흐름

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     전체 실행 흐름                                           │
└─────────────────────────────────────────────────────────────────────────────┘

                    ┌───────────────────┐
                    │    User (EOA)     │
                    │   0xUSER_EOA      │
                    └─────────┬─────────┘
                              │ UserOperation 서명
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Bundler                                             │
│   - UserOperation 수집 (mempool)                                            │
│   - Gas estimation                                                          │
│   - handleOps() 트랜잭션 생성                                                │
└─────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                       EntryPoint                                            │
│                                                                             │
│   handleOps(ops[], beneficiary) {                                           │
│     for each op:                                                            │
│       1. _validatePrepayment()     // 가스비 확인                            │
│       2. sender.validateUserOp()   // 서명 검증                              │
│       3. _executeUserOp()          // 실행                                   │
│     _compensate(beneficiary)       // 가스 환불                              │
│   }                                                                         │
└─────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│              Smart Account (Kernel Proxy 또는 EIP-7702 EOA)                  │
│                                                                             │
│   validateUserOp(userOp, userOpHash) {                                      │
│     1. nonce에서 ValidationMode, ValidationType, ValidationId 추출          │
│     2. rootValidator 또는 지정된 validator 결정                              │
│     3. validator.validateUserOp(userOp, userOpHash) 호출                    │
│     4. hook 설정 확인 및 저장                                                │
│     5. 유효성 검증 결과 반환                                                  │
│   }                                                                         │
│                                                                             │
│   executeUserOp(userOp, userOpHash) {                                       │
│     1. hook.preCheck() (있는 경우)                                          │
│     2. delegatecall로 실제 callData 실행                                     │
│     3. hook.postCheck() (있는 경우)                                         │
│   }                                                                         │
└─────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                       Validator Module                                      │
│                                                                             │
│   validateUserOp(userOp, userOpHash) {                                      │
│     // msg.sender = Smart Account (Kernel) 주소                             │
│     owner = ecdsaValidatorStorage[msg.sender].owner;                        │
│                                                                             │
│     // 서명 검증                                                             │
│     recoveredSigner = ECDSA.recover(userOpHash, userOp.signature);         │
│                                                                             │
│     return (owner == recoveredSigner)                                       │
│            ? SIG_VALIDATION_SUCCESS                                         │
│            : SIG_VALIDATION_FAILED;                                         │
│   }                                                                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 컴포넌트 관계도

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       Component Relationships                               │
└─────────────────────────────────────────────────────────────────────────────┘

                              ┌─────────────┐
                              │ EntryPoint  │
                              │ (Singleton) │
                              └──────┬──────┘
                                     │
              ┌──────────────────────┼──────────────────────┐
              │                      │                      │
              ▼                      ▼                      ▼
     ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
     │ Smart Account A │   │ Smart Account B │   │ Smart Account C │
     │ (Proxy)         │   │ (Proxy)         │   │ (EIP-7702 EOA)  │
     └────────┬────────┘   └────────┬────────┘   └────────┬────────┘
              │                     │                     │
              └──────────┬──────────┴──────────┬──────────┘
                         │                     │
                         ▼                     ▼
                ┌─────────────────┐   ┌─────────────────┐
                │  Kernel Impl    │   │   Validators    │
                │  (Singleton)    │   │  (Singletons)   │
                └─────────────────┘   └─────────────────┘
                                              │
                         ┌────────────────────┼────────────────────┐
                         │                    │                    │
                         ▼                    ▼                    ▼
                ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
                │    ECDSA     │     │   MultiSig   │     │   WebAuthn   │
                │  Validator   │     │  Validator   │     │  Validator   │
                └──────────────┘     └──────────────┘     └──────────────┘
```

---

## 배포 및 초기화

### 배포 순서

```bash
# 1. Phase 0: 기반 인프라
./script/deploy-tokens.sh --broadcast      # wKRC, USDC
./script/deploy-entrypoint.sh --broadcast  # EntryPoint

# 2. Phase 1: Smart Account
./script/deploy-smartaccount.sh --broadcast  # Kernel, KernelFactory, FactoryStaker

# 3. FactoryStaker 설정
./script/stake-factory.sh --stake=1 --approve

# 4. Phase 2: Validators (필수)
./script/deploy-validators.sh --broadcast  # ECDSAValidator, MultiSigValidator, etc.
```

### Smart Account 생성 (Proxy 모델)

```typescript
// 1. 컨트랙트 주소 (배포 후 addresses.json에서 확인)
const KERNEL_FACTORY = "0x...";
const ECDSA_VALIDATOR = "0x...";
const KERNEL_IMPL = "0x...";

// 2. ValidationId 생성
const validationId = ethers.utils.hexConcat([
  "0x01",  // VALIDATION_TYPE_VALIDATOR
  ECDSA_VALIDATOR
]);

// 3. initialize 데이터 인코딩
const iKernel = new ethers.utils.Interface(KernelABI);
const initData = iKernel.encodeFunctionData("initialize", [
  validationId,
  ethers.constants.AddressZero,  // no hook
  ownerAddress,                   // owner EOA (20 bytes)
  "0x",                          // no hook data
  []                             // no additional config
]);

// 4. createAccount 호출
const salt = ethers.utils.id("my-unique-salt");
const accountAddress = await kernelFactory.createAccount(initData, salt);
```

### EIP-7702 초기화

```typescript
// 1. EIP-7702 Authorization 트랜잭션 (체인에 따라 다름)
// 이 단계에서 EOA.code가 0xef0100 + KernelAddr로 설정됨

// 2. UserOperation으로 초기화
const userOp = {
  sender: eoaAddress,  // EIP-7702가 설정된 EOA
  nonce: await entryPoint.getNonce(eoaAddress, 0),
  initCode: ethers.utils.hexConcat([
    "0x7702",  // EIP-7702 marker
    initData   // Kernel.initialize() 호출 데이터
  ]),
  callData: "0x",
  // ... gas params
  signature: await signUserOp(userOp, ownerPrivateKey)
};

// 3. Bundler를 통해 실행
await bundler.sendUserOperation(userOp);
```

---

## 비교 및 선택 가이드

### Proxy vs EIP-7702 비교

| 항목 | Proxy 모델 | EIP-7702 모델 |
|------|-----------|---------------|
| **주소** | 새 주소 생성 | 기존 EOA 주소 유지 |
| **Storage** | Proxy 주소에 저장 | EOA 주소에 저장 |
| **가스 비용** | 더 높음 (proxy hop) | 더 낮음 (직접 실행) |
| **체인 호환성** | 모든 EVM 체인 | EIP-7702 지원 체인만 |
| **되돌리기** | 불가능 (영구 계정) | 가능 (delegate 제거) |
| **기존 자산** | 새 주소로 이동 필요 | 기존 자산 그대로 사용 |
| **복잡도** | 낮음 | 높음 |

### 선택 가이드

```
EIP-7702 사용 권장:
├── 기존 EOA에 많은 자산/토큰/NFT가 있는 경우
├── 주소 변경이 불가능한 경우 (외부 서비스 연동 등)
├── 가스 비용 최적화가 중요한 경우
└── Prague 하드포크 이후 체인 (EIP-7702 지원)

Proxy 모델 사용 권장:
├── 새로운 Smart Account가 필요한 경우
├── 모든 EVM 체인에서 동일한 방식 사용
├── 간단한 구현이 필요한 경우
└── 계정 영구성이 중요한 경우
```

### 주의사항

#### EIP-7702 사용 시

1. **체인 지원 확인**: Prague 하드포크 이후에만 EIP-7702 사용 가능
2. **되돌리기 위험**: delegate 제거 시 storage는 유지되지만 로직 실행 불가
3. **Storage 충돌**: EOA에 기존 storage가 있으면 Kernel storage와 충돌 가능
4. **재초기화 방지**: `AlreadyInitialized` 에러로 중복 초기화 차단

#### Proxy 모델 사용 시

1. **자산 이동**: 기존 EOA의 자산을 새 Smart Account로 이동 필요
2. **주소 변경**: 외부 서비스에 새 주소 등록 필요
3. **Factory Staking**: FactoryStaker가 EntryPoint에 stake 필요 (평판용)

---

## 관련 문서

- `docs/ENTRYPOINT_DEPOSIT_STAKE.md` - EntryPoint Deposit & Stake 가이드
- `DEPLOYMENT_ORDER.md` - 배포 순서 및 스크립트

## 관련 코드

### 컨트랙트
- `src/erc7579-smartaccount/Kernel.sol` - Smart Account 구현체
- `src/erc7579-smartaccount/factory/KernelFactory.sol` - Proxy Factory
- `src/erc7579-smartaccount/factory/FactoryStaker.sol` - Factory Staking
- `src/erc7579-validators/*.sol` - Validator 모듈들
- `src/erc4337-entrypoint/Eip7702Support.sol` - EIP-7702 지원

### 스크립트
- `script/ts/deploy-smartaccount.ts` - Smart Account 배포
- `script/ts/stake-factory.ts` - FactoryStaker 설정
