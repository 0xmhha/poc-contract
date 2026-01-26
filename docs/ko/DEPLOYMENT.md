# 배포 가이드

StableNet PoC 컨트랙트 배포에 대한 상세 가이드입니다.

## 컨트랙트 아키텍처 개요

프로젝트는 **13개 도메인**에 걸쳐 **96개 Solidity 파일**로 구성됩니다:

| 도메인 | 컨트랙트 | 설명 |
|--------|----------|------|
| Tokens | USDC, wKRC | 스테이블코인 (6 decimals) + Wrapped 네이티브 토큰 (18 decimals) |
| ERC-4337 EntryPoint | 10개 | UserOperation 싱글톤, 논스/스테이크 관리 |
| ERC-7579 Smart Account | 32개 | 모듈형 Kernel 계정 (프록시 패턴) |
| Validators | 5개 | ECDSA, Weighted, MultiChain, WebAuthn, MultiSig |
| Paymasters | 5개 | Verifying, ERC20, Sponsor, Permit2 |
| Executors | 2개 | SessionKey, RecurringPayment |
| Hooks & Fallbacks | 4개 | Audit, SpendingLimit, TokenReceiver, FlashLoan |
| Bridge | 6개 | SecureBridge (MPC + Optimistic + Guardian 보안 레이어) |
| Privacy | 3개 | 스텔스 주소 (ERC-5564/6538) + PrivateBank |
| DeFi | 2개 | PriceOracle (Chainlink/TWAP) + DEXIntegration |
| Compliance | 4개 | KYC, AuditLogger, ProofOfReserve, RegulatoryRegistry |
| Subscription | 2개 | ERC-7715 PermissionManager + SubscriptionManager |
| Permit2 | 8개 | 서명 기반 토큰 전송 |

## 배포 스크립트 구조

```
script/
├── DeployAll.s.sol               # 통합 배포 (전체 44개 컨트랙트)
├── deploy-contract/
│   ├── DeployTokens.s.sol        # USDC, wKRC
│   ├── DeployEntryPoint.s.sol    # EntryPoint
│   ├── DeployKernel.s.sol        # Kernel + KernelFactory + FactoryStaker
│   ├── DeployPaymasters.s.sol    # 모든 Paymaster
│   ├── DeployValidators.s.sol    # 모든 Validator (5개)
│   ├── DeployExecutors.s.sol     # SessionKey, RecurringPayment
│   ├── DeployHooks.s.sol         # AuditHook, SpendingLimitHook
│   ├── DeployFallbacks.s.sol     # TokenReceiver, FlashLoan
│   ├── DeployPlugins.s.sol       # AutoSwap, MicroLoan, OnRamp
│   ├── DeployBridge.s.sol        # 브릿지 컴포넌트 6종
│   ├── DeployPrivacy.s.sol       # Stealth + PrivateBank
│   ├── DeployDeFi.s.sol          # PriceOracle, DEXIntegration
│   ├── DeployCompliance.s.sol    # KYC, Audit, PoR, Regulatory
│   ├── DeployPermit2.s.sol       # Permit2
│   └── DeploySubscription.s.sol  # ERC7715 + SubscriptionManager
└── utils/
    ├── DeploymentAddresses.sol   # 주소 캐싱 및 JSON 관리
    ├── DeployConstants.sol       # 공유 상수
    └── StringUtils.sol           # 문자열 유틸리티
```

## 배포 순서 (의존성)

### Layer 0 (의존성 없음)

온체인 의존성이 없으며, 순서와 관계없이 배포 가능합니다.

```
Layer 0 ── 의존성 없음
│
├── 토큰
│   ├── wKRC                          # 생성자 인자 없음
│   └── USDC                          # constructor(owner_)
│
├── ERC-4337
│   └── EntryPoint                    # 생성자 인자 없음 (싱글톤)
│
├── Permit2
│   └── Permit2                       # 생성자 인자 없음
│
├── Validator
│   ├── ECDSAValidator                # 생성자 인자 없음
│   ├── WeightedECDSAValidator        # 생성자 인자 없음
│   ├── MultiChainValidator           # 생성자 인자 없음
│   ├── MultiSigValidator             # 생성자 인자 없음
│   └── WebAuthnValidator             # 생성자 인자 없음
│
├── Executor
│   ├── SessionKeyExecutor
│   └── RecurringPaymentExecutor
│
├── Hook
│   ├── AuditHook
│   └── SpendingLimitHook
│
├── Fallback
│   ├── TokenReceiverFallback
│   └── FlashLoanFallback
│
├── Privacy
│   ├── ERC5564Announcer              # 생성자 인자 없음
│   └── ERC6538Registry               # constructor(owner_)
│
├── Bridge (일부)
│   ├── BridgeRateLimiter             # Ownable
│   └── FraudProofVerifier            # 생성자 인자 없음
│
├── DeFi
│   └── PriceOracle                   # 피드는 배포 후 등록
│
├── Compliance
│   ├── KYCRegistry                   # constructor(owner_)
│   ├── AuditLogger                   # constructor(owner_)
│   ├── ProofOfReserve                # constructor(owner_)
│   └── RegulatoryRegistry            # constructor(owner_)
│
└── Subscription
    └── ERC7715PermissionManager      # constructor(owner_)
```

### Layer 1 (Layer 0 의존)

Layer 0 주소가 생성자 파라미터로 필요합니다.

```
Layer 1 ── Layer 0 의존
│
├── ERC-7579
│   └── Kernel (구현체)               # constructor(entryPoint)
│
├── Validator
│   └── MultiChainValidator           # constructor(owner_, kernel_)
│
├── Paymaster
│   ├── VerifyingPaymaster            # constructor(entryPoint, owner_, verifyingSigner)
│   ├── SponsorPaymaster              # constructor(entryPoint, owner_)
│   └── ERC20Paymaster                # constructor(entryPoint, owner_, priceOracle, markup)
│
├── Privacy
│   └── PrivateBank                   # constructor(announcer, registry, owner_)
│
├── Bridge
│   ├── BridgeValidator               # constructor(signers_[], threshold_)
│   ├── BridgeGuardian                # constructor(guardians_[], threshold_)
│   └── OptimisticVerifier            # constructor(challengePeriod, challengeBond, reward)
│
├── DeFi
│   └── DEXIntegration                # constructor(wKRC)
│
└── Subscription
    └── SubscriptionManager           # constructor(permissionManager, owner_)
```

### Layer 2 (Layer 1 의존)

Layer 1 주소가 필요합니다.

```
Layer 2 ── Layer 1 의존
│
├── ERC-7579
│   └── KernelFactory                 # constructor(kernelImpl) — CREATE2 프록시
│
├── Paymaster
│   └── Permit2Paymaster              # constructor(entryPoint, owner_, priceOracle, permit2, markup)
│
└── Bridge
    └── SecureBridge                   # constructor(bridgeValidator, optimisticVerifier,
                                      #             rateLimiter, guardian, feeRecipient)
```

### 배포 후 초기화: 컨트랙트 간 연결 (Cross-Contract Wiring)

생성자에서 설정할 수 없는 양방향 참조 및 구성을 설정합니다.

```
Post-Deploy ── 컨트랙트 간 연결
│
├── Bridge 연결
│   ├── OptimisticVerifier.setFraudProofVerifier(FraudProofVerifier)
│   ├── OptimisticVerifier.setAuthorizedCaller(SecureBridge)
│   ├── FraudProofVerifier.setOptimisticVerifier(OptimisticVerifier)
│   └── FraudProofVerifier.setBridgeValidator(BridgeValidator)
│
├── 토큰 설정
│   ├── USDC.addMinter(paymasterAddr)        # Minter 역할 부여
│   ├── USDC.addMinter(bridgeAddr)
│   └── SecureBridge: 체인별 지원 토큰 매핑
│
├── Oracle 설정
│   ├── PriceOracle.setChainlinkFeed(token, feedAddr)
│   └── PriceOracle.setUniswapPool(token, pool, twapPeriod, quoteToken)
│
├── Paymaster 설정
│   ├── Paymaster.deposit() via EntryPoint    # 가스 후원용 ETH 예치
│   └── ERC20Paymaster: 지원 토큰 화이트리스트
│
├── Bridge 설정
│   ├── BridgeRateLimiter: 토큰별 한도 설정
│   ├── BridgeGuardian: Guardian 주소 등록
│   └── SecureBridge: 지원 체인 활성화
│
└── Privacy 설정
    └── ERC6538Registry: 스텔스 메타 주소 등록
```

### 배포 후 초기화: 계정 수준 설정

사용자별 계정 생성 및 모듈 설치입니다.

```
Account Setup ── 계정별 설정
│
├── KernelFactory.createAccount()             # CREATE2 결정적 생성
├── Kernel.installValidator(ECDSAValidator)    # 인증 모듈
├── Kernel.installExecutor(SessionKeyExecutor) # 자동화 모듈
├── Kernel.installHook(SpendingLimitHook)      # 가드 모듈
└── Kernel.installFallback(TokenReceiverFallback) # ERC721/1155 수신
```

## 의존성 흐름도

```
                    ┌─────────────┐
                    │  EntryPoint  │
                    └──────┬──────┘
              ┌────────────┼────────────────┐
              v            v                v
         ┌────────┐  ┌──────────────┐  ┌────────────────┐
         │ Kernel │  │ Verifying    │  │ Sponsor        │
         │        │  │ Paymaster    │  │ Paymaster      │
         └───┬────┘  └──────────────┘  └────────────────┘
             v
      ┌──────────────┐     ┌─────────────┐
      │ KernelFactory│     │ PriceOracle │
      └──────────────┘     └──────┬──────┘
                                  │
                      ┌───────────┼───────────┐
                      v           v           v
               ┌────────────┐ ┌──────────┐ ┌────────────────┐
               │ ERC20      │ │ Permit2  │ │ DEXIntegration │
               │ Paymaster  │ │ Paymaster│ │ (+ wKRC)       │
               └────────────┘ └──────────┘ └────────────────┘

  ┌──────────────────┐  ┌───────────────┐
  │ ERC5564Announcer │  │ ERC6538       │
  │                  │  │ Registry      │
  └────────┬─────────┘  └───────┬───────┘
           └────────┬───────────┘
                    v
             ┌─────────────┐
             │ PrivateBank  │
             └─────────────┘

  ┌───────────────┐ ┌──────────────────┐ ┌──────────────┐ ┌──────────────┐
  │ BridgeRate    │ │ FraudProof       │ │ Bridge       │ │ Bridge       │
  │ Limiter       │ │ Verifier         │ │ Validator    │ │ Guardian     │
  └───────┬───────┘ └────────┬─────────┘ └──────┬───────┘ └──────┬───────┘
          │                  │                   │                │
          │    ┌─────────────────────┐           │                │
          │    │ OptimisticVerifier  │───────────│────────────────│
          │    └──────────┬──────────┘           │                │
          │               │                      │                │
          └───────┬───────┴──────────────────────┴────────────────┘
                  v
           ┌──────────────┐
           │ SecureBridge  │ ── Post-Deploy: FraudProof <-> Optimistic 연결
           └──────────────┘

  ┌──────────────────────┐
  │ ERC7715Permission    │
  │ Manager              │
  └──────────┬───────────┘
             v
  ┌──────────────────────┐
  │ SubscriptionManager  │
  └──────────────────────┘
```

## 로컬 배포 (Anvil)

### 1. Anvil 시작

```bash
# Prague 하드포크 활성화 (EIP-7702 지원)
anvil --chain-id 31337 --block-time 1 --hardfork prague
```

### 2. 전체 배포 (DeployAll)

모든 컨트랙트를 의존성 순서대로 배포합니다 (6단계, 44개 컨트랙트).

```bash
forge script script/DeployAll.s.sol:DeployAllScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

### 3. 도메인별 배포

```bash
# 토큰
FOUNDRY_PROFILE=tokens forge script script/deploy-contract/DeployTokens.s.sol:DeployTokensScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# ERC-4337 EntryPoint
FOUNDRY_PROFILE=entrypoint forge script script/deploy-contract/DeployEntryPoint.s.sol:DeployEntryPointScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# ERC-7579 Kernel + Factory
FOUNDRY_PROFILE=smartaccount forge script script/deploy-contract/DeployKernel.s.sol:DeployKernelScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Validators
FOUNDRY_PROFILE=validators forge script script/deploy-contract/DeployValidators.s.sol:DeployValidatorsScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Paymasters (EntryPoint, PriceOracle 필요)
FOUNDRY_PROFILE=paymaster forge script script/deploy-contract/DeployPaymasters.s.sol:DeployPaymastersScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Executors
FOUNDRY_PROFILE=executors forge script script/deploy-contract/DeployExecutors.s.sol:DeployExecutorsScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Hooks
FOUNDRY_PROFILE=hooks forge script script/deploy-contract/DeployHooks.s.sol:DeployHooksScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Fallbacks
FOUNDRY_PROFILE=fallbacks forge script script/deploy-contract/DeployFallbacks.s.sol:DeployFallbacksScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Bridge (6개 컴포넌트 전체)
FOUNDRY_PROFILE=bridge forge script script/deploy-contract/DeployBridge.s.sol:DeployBridgeScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Privacy
FOUNDRY_PROFILE=privacy forge script script/deploy-contract/DeployPrivacy.s.sol:DeployPrivacyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# DeFi (PriceOracle + DEXIntegration)
FOUNDRY_PROFILE=defi forge script script/deploy-contract/DeployDeFi.s.sol:DeployDeFiScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Compliance
FOUNDRY_PROFILE=compliance forge script script/deploy-contract/DeployCompliance.s.sol:DeployComplianceScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Subscription
FOUNDRY_PROFILE=subscription forge script script/deploy-contract/DeploySubscription.s.sol:DeploySubscriptionScript \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

## 테스트넷 배포 (Sepolia)

### 1. 환경 설정

```bash
# .env 파일에 설정 추가
RPC_URL_SEPOLIA=https://sepolia.infura.io/v3/YOUR_API_KEY
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_KEY
```

### 2. 배포

```bash
forge script script/DeployAll.s.sol:DeployAllScript \
  --rpc-url $RPC_URL_SEPOLIA \
  --broadcast \
  --verify
```

## 환경 변수

| 변수 | 설명 | 기본값 |
|-----|------|-------|
| `ADMIN_ADDRESS` | 관리자 주소 | 배포자 |
| `VERIFYING_SIGNER` | Paymaster 서명자 | 관리자 |
| `SKIP_EXISTING` | 기존 배포 스킵 | true |
| `DEPLOY_LAYER` | 배포할 레이어 (0, 1, 2, all) | all |
| `AUDIT_RETENTION_PERIOD` | 감사 로그 보관 기간 | 365일 |
| `POR_REQUIRED_CONFIRMATIONS` | 준비금 증명 확인 수 | 3 |

## 배포 결과

배포된 주소는 JSON 파일로 저장됩니다:

```
deployments/
├── 31337/
│   └── addresses.json    # 로컬 (Anvil)
├── 11155111/
│   └── addresses.json    # Sepolia
└── 1/
    └── addresses.json    # Mainnet
```

### addresses.json 예시

```json
{
  "wKRC": "0x...",
  "usdc": "0x...",
  "entryPoint": "0x...",
  "permit2": "0x...",
  "kernel": "0x...",
  "kernelFactory": "0x...",
  "ecdsaValidator": "0x...",
  "weightedEcdsaValidator": "0x...",
  "multiSigValidator": "0x...",
  "webAuthnValidator": "0x...",
  "multiChainValidator": "0x...",
  "verifyingPaymaster": "0x...",
  "sponsorPaymaster": "0x...",
  "erc20Paymaster": "0x...",
  "permit2Paymaster": "0x...",
  "sessionKeyExecutor": "0x...",
  "recurringPaymentExecutor": "0x...",
  "auditHook": "0x...",
  "spendingLimitHook": "0x...",
  "tokenReceiverFallback": "0x...",
  "flashLoanFallback": "0x...",
  "bridgeValidator": "0x...",
  "optimisticVerifier": "0x...",
  "bridgeRateLimiter": "0x...",
  "bridgeGuardian": "0x...",
  "fraudProofVerifier": "0x...",
  "secureBridge": "0x...",
  "erc5564Announcer": "0x...",
  "erc6538Registry": "0x...",
  "privateBank": "0x...",
  "priceOracle": "0x...",
  "dexIntegration": "0x...",
  "kycRegistry": "0x...",
  "auditLogger": "0x...",
  "proofOfReserve": "0x...",
  "regulatoryRegistry": "0x...",
  "erc7715PermissionManager": "0x...",
  "subscriptionManager": "0x..."
}
```

## 배포 후 설정

### PriceOracle 피드 등록

> **중요**: PriceOracle은 배포 후 피드 등록이 필요합니다. 등록된 피드 없이 가격 조회 시 `NoPriceFeed` 오류가 발생합니다.

#### Chainlink 피드 등록

```solidity
IPriceOracle oracle = IPriceOracle(PRICE_ORACLE_ADDRESS);

// ETH/USD 피드
oracle.setChainlinkFeed(
    address(0),                                           // 네이티브 토큰
    0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419            // Chainlink ETH/USD
);

// USDC/USD 피드
oracle.setChainlinkFeed(
    USDC_ADDRESS,
    0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6            // Chainlink USDC/USD
);
```

#### Uniswap V3 TWAP 등록

```solidity
oracle.setUniswapPool(
    TOKEN_ADDRESS,
    UNISWAP_POOL_ADDRESS,
    1800,                   // TWAP 기간 (30분)
    address(0)              // 기준 토큰 (address(0) = USD 페깅)
);
```

#### Chainlink 피드 주소 참조

| 네트워크 | 토큰 | 피드 주소 |
|----------|------|-----------|
| Mainnet | ETH/USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| Mainnet | USDC/USD | `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` |
| Mainnet | USDT/USD | `0x3E7d1eAB13ad0104d2750B8863b489D65364e32D` |
| Sepolia | ETH/USD | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| Sepolia | USDC/USD | `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E` |

> **참고**: 항상 [Chainlink Data Feeds](https://docs.chain.link/data-feeds/price-feeds/addresses)에서 피드 주소를 확인하세요.

### Paymaster 펀딩

```bash
# cast로 직접 예치
cast send <ENTRYPOINT_ADDRESS> "depositTo(address)" <PAYMASTER_ADDRESS> \
  --value 10ether \
  --rpc-url http://127.0.0.1:8545
```

### Bridge 설정

```solidity
// 1. Fraud proof 시스템 연결
optimisticVerifier.setFraudProofVerifier(address(fraudProofVerifier));
optimisticVerifier.setAuthorizedCaller(address(secureBridge));
fraudProofVerifier.setOptimisticVerifier(address(optimisticVerifier));
fraudProofVerifier.setBridgeValidator(address(bridgeValidator));

// 2. 토큰별 한도 설정
bridgeRateLimiter.setTokenLimit(USDC_ADDRESS, 1_000_000e6, 24 hours);

// 3. 지원 체인 활성화
secureBridge.enableChain(TARGET_CHAIN_ID);

// 4. 체인 간 토큰 매핑
secureBridge.mapToken(USDC_ADDRESS, TARGET_CHAIN_ID, REMOTE_USDC_ADDRESS);
```

### USDC Minter 역할 설정

```solidity
usdc.addMinter(address(secureBridge));
usdc.addMinter(address(erc20Paymaster));
```

## 주요 배포 파라미터

| 파라미터 | PoC 값 | Mainnet 값 |
|----------|--------|------------|
| Bridge Challenge Period | 6시간 | 24시간 |
| MPC Threshold | 5-of-7 | 5-of-7 |
| Guardian Threshold | 3-of-N | 3-of-N |
| ERC20Paymaster Markup | 10% (1000 bps) | 5-50% |
| Price Staleness | 1시간 | 1시간 |
| USDC Decimals | 6 | 6 |
| wKRC Decimals | 18 | 18 |

## 트러블슈팅

### 1. CreateCollision 오류

이미 같은 주소에 컨트랙트가 배포되어 있습니다.

```bash
# 해결: Anvil 재시작
anvil --chain-id 31337 --hardfork prague
```

### 2. fs_permissions 오류

addresses.json 저장 권한이 없습니다.

```toml
# foundry.toml에 추가
fs_permissions = [
    { access = "read-write", path = "." }
]
```

### 3. 의존성 오류

필요한 컨트랙트가 먼저 배포되지 않았습니다.

```bash
# 해결: 의존성 순서대로 배포
# Layer 0: EntryPoint, 토큰, Validator, Compliance, Privacy (일부), Permit2
# Layer 1: Kernel, Paymaster, Bridge (일부), PrivateBank, DEXIntegration
# Layer 2: KernelFactory, Permit2Paymaster, SecureBridge
# Post-Deploy: 컨트랙트 간 연결 (setFraudProofVerifier 등)
```

### 4. PriceOracle NoPriceFeed 오류

Oracle에 등록된 가격 피드가 없습니다.

```bash
# 해결: 배포 후 피드 등록 필요
# "배포 후 설정 > PriceOracle 피드 등록" 섹션 참조
```
