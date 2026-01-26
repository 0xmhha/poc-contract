# 아키텍처

StableNet PoC 컨트랙트의 구조와 설계에 대한 문서입니다.

## 전체 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│                     User / DApp                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    ERC-4337 Layer                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  EntryPoint │  │  Paymaster  │  │      Bundler        │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    ERC-7579 Layer                            │
│  ┌─────────────────────────────────────────────────────────┐│
│  │                    Kernel (Smart Account)                ││
│  │  ┌───────────┐ ┌───────────┐ ┌───────┐ ┌───────────┐   ││
│  │  │ Validator │ │ Executor  │ │ Hook  │ │ Fallback  │   ││
│  │  └───────────┘ └───────────┘ └───────┘ └───────────┘   ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Application Layer                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   Privacy   │  │ Compliance  │  │       DeFi          │  │
│  │  (Stealth)  │  │  (KYC/AML)  │  │  (Tokens, Oracle)   │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## ERC-4337 Account Abstraction

### EntryPoint

UserOperation의 진입점으로, 모든 AA 트랜잭션을 처리합니다.

```
src/erc4337-entrypoint/
├── EntryPoint.sol           # 메인 진입점
├── SenderCreator.sol        # 계정 생성 헬퍼
├── StakeManager.sol         # 스테이킹 관리
└── interfaces/
    ├── IEntryPoint.sol
    ├── IAccount.sol
    └── IPaymaster.sol
```

**주요 기능:**
- `handleOps()`: UserOperation 배치 처리
- `simulateValidation()`: 검증 시뮬레이션
- `depositTo()`: Paymaster 예치금 관리

### Paymaster

가스비를 대신 지불하는 컨트랙트입니다.

```
src/erc4337-paymaster/
├── BasePaymaster.sol        # 기본 Paymaster
├── VerifyingPaymaster.sol   # 서명 검증 기반
├── ERC20Paymaster.sol       # ERC20 토큰 결제
└── interfaces/
    └── IPriceOracle.sol
```

**VerifyingPaymaster 흐름:**
```
1. 사용자 → Paymaster 서버에 서명 요청
2. Paymaster 서버 → 조건 확인 후 서명 반환
3. 사용자 → UserOperation에 paymasterAndData 포함
4. EntryPoint → Paymaster.validatePaymasterUserOp() 호출
5. Paymaster → 서명 검증 후 가스비 지불
```

## ERC-7579 Modular Smart Account

### Kernel

모듈러 스마트 계정 구현체입니다.

```
src/erc7579-smartaccount/
├── Kernel.sol               # 메인 스마트 계정
├── factory/
│   └── KernelFactory.sol    # 계정 생성 팩토리
├── types/
│   └── Types.sol            # 타입 정의
└── interfaces/
    ├── IKernel.sol
    └── IERC7579*.sol
```

**모듈 타입:**

| 타입 | 역할 | 인터페이스 |
|-----|------|-----------|
| Validator | 트랜잭션 서명 검증 | `IValidator` |
| Executor | 트랜잭션 실행 | `IExecutor` |
| Hook | 실행 전/후 로직 | `IHook` |
| Fallback | fallback 함수 처리 | `IFallback` |

### Validators

트랜잭션 서명을 검증하는 모듈입니다.

```
src/erc7579-validators/
├── ECDSAValidator.sol           # 단일 ECDSA 서명
├── WeightedECDSAValidator.sol   # 가중치 다중 서명
├── MultiChainValidator.sol      # 멀티체인 서명
├── MultiSigValidator.sol        # 다중 서명 검증
└── WebAuthnValidator.sol        # WebAuthn/Passkey 검증
```

**ECDSAValidator:**
- 단일 소유자의 ECDSA 서명 검증
- 가장 기본적인 검증 방식

**WeightedECDSAValidator:**
- 여러 서명자에 가중치 부여
- 임계값 이상 가중치 필요

**MultiSigValidator:**
- 다중 서명 검증
- m-of-n 임계값 설정 가능

**WebAuthnValidator:**
- WebAuthn/Passkey 인증 지원
- P256 (secp256r1) 곡선 검증 필요

### Executors

트랜잭션을 실행하는 모듈입니다.

```
src/erc7579-executors/
├── SessionKeyExecutor.sol       # 세션 키 기반 실행
└── RecurringPaymentExecutor.sol # 반복 결제
```

**SessionKeyExecutor:**
- 제한된 권한의 세션 키 발급
- 시간/금액/대상 제한 가능

### Hooks

실행 전/후에 호출되는 모듈입니다.

```
src/erc7579-hooks/
├── AuditHook.sol           # 감사 로그
└── SpendingLimitHook.sol   # 지출 한도
```

**SpendingLimitHook:**
- 일일/월간 지출 한도 설정
- 한도 초과 시 트랜잭션 거부

### Fallbacks

fallback 함수를 처리하는 모듈입니다.

```
src/erc7579-fallbacks/
├── TokenReceiverFallback.sol   # ERC721/1155 수신
└── FlashLoanFallback.sol       # 플래시론 지원
```

## Privacy (ERC-5564/6538)

스텔스 주소 기반 프라이버시 시스템입니다.

```
src/privacy/
├── ERC5564Announcer.sol    # 스텔스 주소 공지
├── ERC6538Registry.sol     # 메타 주소 등록
└── PrivateBank.sol         # 프라이빗 입출금
```

### 스텔스 주소 흐름

```
┌──────────────────────────────────────────────────────────────┐
│ 1. 수신자: 스텔스 메타 주소 등록                               │
│    Registry.registerKeys(spendingPubKey, viewingPubKey)      │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 송신자: 스텔스 주소 생성                                    │
│    stealthAddress = generateStealthAddress(metaAddress)       │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 송신자: 자금 전송 + 공지                                    │
│    transfer(stealthAddress, amount)                           │
│    Announcer.announce(ephemeralPubKey, metadata)             │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 수신자: 공지 스캔 및 자금 수령                               │
│    for announcement in Announcer.getAnnouncements():          │
│        if canDecrypt(announcement): claimFunds()              │
└──────────────────────────────────────────────────────────────┘
```

## Compliance

규제 준수를 위한 컨트랙트입니다.

```
src/compliance/
├── KYCRegistry.sol          # KYC 상태 관리
├── AuditLogger.sol          # 감사 로그
├── ProofOfReserve.sol       # 준비금 증명
└── RegulatoryRegistry.sol   # 규제 기관 등록 및 추적 승인
```

### KYCRegistry

```solidity
enum KYCLevel {
    NONE,        // 미인증
    BASIC,       // 기본 인증
    ADVANCED,    // 고급 인증
    INSTITUTIONAL // 기관 인증
}
```

### AuditLogger

불변의 감사 로그를 기록합니다.

```solidity
struct AuditLog {
    address account;
    bytes32 action;
    bytes data;
    uint256 timestamp;
}
```

### ProofOfReserve

준비금을 온체인에서 증명합니다.

```solidity
struct Reserve {
    address asset;
    uint256 amount;
    bytes32 proof;
    uint256 timestamp;
}
```

## 컨트랙트 의존성 그래프

```
                    ┌─────────────┐
                    │  EntryPoint │
                    └──────┬──────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
    ┌──────────┐    ┌──────────┐    ┌──────────────┐
    │  Kernel  │    │Paymaster │    │ERC20Paymaster│
    └────┬─────┘    └──────────┘    └──────┬───────┘
         │                                  │
         ▼                                  ▼
    ┌──────────┐                      ┌──────────┐
    │  Factory │                      │  Oracle  │
    └──────────┘                      └──────────┘

    ┌──────────┐    ┌──────────┐
    │Announcer │◄───│PrivateBank│
    └──────────┘    └──────────┘
         ▲               │
         └───────────────┘
              Registry
```

## 보안 고려사항

### 1. 접근 제어
- 모든 관리 함수는 `onlyOwner` 또는 역할 기반 접근 제어
- 모듈 설치/제거는 계정 소유자만 가능

### 2. 재진입 방지
- `ReentrancyGuard` 사용
- 상태 변경 후 외부 호출

### 3. 서명 검증
- EIP-712 타입 해시 사용
- 리플레이 공격 방지 (nonce, chainId)

### 4. 업그레이드
- Kernel은 프록시 패턴 미사용 (immutable)
- 모듈 교체로 기능 업그레이드
