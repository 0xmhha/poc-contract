# 배포 가이드

StableNet PoC 컨트랙트 배포에 대한 상세 가이드입니다.

## 배포 스크립트 구조

```
script/
├── deploy/
│   ├── DeployDevnet.s.sol      # 원클릭 개발용 배포
│   ├── DeployERC4337.s.sol     # ERC-4337 Account Abstraction
│   ├── DeployERC7579.s.sol     # ERC-7579 Modular Smart Account
│   ├── DeployPrivacy.s.sol     # Privacy (ERC-5564/6538)
│   └── DeployCompliance.s.sol  # Compliance
├── utils/
│   └── DeploymentAddresses.sol # 주소 관리 유틸리티
└── DeployOrchestrator.s.sol    # 전체 오케스트레이터
```

## 배포 순서 (의존성)

```
Layer 0 (의존성 없음)
├── EntryPoint
├── Validators (ECDSA, Weighted, MultiChain)
├── Executors (SessionKey, RecurringPayment)
├── Hooks (Audit, SpendingLimit)
├── Fallbacks (TokenReceiver, FlashLoan)
├── ERC5564Announcer, ERC6538Registry
└── KYCRegistry, AuditLogger, ProofOfReserve

Layer 1 (Layer 0 의존)
├── Kernel → EntryPoint
├── VerifyingPaymaster → EntryPoint
├── ERC20Paymaster → EntryPoint, PriceOracle
└── PrivateBank → ERC5564Announcer, ERC6538Registry

Layer 2 (Layer 1 의존)
├── KernelFactory → Kernel
└── SubscriptionManager → ERC7715PermissionManager
```

## 로컬 배포 (Anvil)

### 1. Anvil 시작

```bash
# Prague 하드포크 활성화 (EIP-7702 지원)
anvil --chain-id 31337 --block-time 1 --hardfork prague

# 옵션 설명
# --chain-id: 체인 ID (31337 = 로컬)
# --block-time: 블록 생성 간격 (초)
# --hardfork: 하드포크 버전
```

### 2. 원클릭 배포 (필수 컨트랙트만)

개발 및 테스트용으로 필수 컨트랙트만 빠르게 배포합니다.

```bash
forge script script/deploy/DeployDevnet.s.sol:DeployDevnetScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

배포되는 컨트랙트:
- EntryPoint
- Kernel + KernelFactory
- ECDSAValidator
- VerifyingPaymaster
- ERC5564Announcer + ERC6538Registry

### 3. 카테고리별 배포

#### ERC-4337 Account Abstraction

```bash
forge script script/deploy/DeployERC4337.s.sol:DeployERC4337Script \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

개별 배포:
```bash
# EntryPoint만
forge script script/deploy/DeployERC4337.s.sol:DeployEntryPointOnlyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

#### ERC-7579 Modular Smart Account

```bash
forge script script/deploy/DeployERC7579.s.sol:DeployERC7579Script \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

개별 배포:
```bash
# Kernel + Factory만
forge script script/deploy/DeployERC7579.s.sol:DeployKernelOnlyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Validators만
forge script script/deploy/DeployERC7579.s.sol:DeployValidatorsOnlyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

#### Privacy (ERC-5564/6538)

```bash
forge script script/deploy/DeployPrivacy.s.sol:DeployPrivacyScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

개별 배포:
```bash
# Stealth 컨트랙트만
forge script script/deploy/DeployPrivacy.s.sol:DeployStealthOnlyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# PrivateBank만 (Announcer, Registry 필요)
forge script script/deploy/DeployPrivacy.s.sol:DeployPrivateBankOnlyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

#### Compliance

```bash
forge script script/deploy/DeployCompliance.s.sol:DeployComplianceScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

개별 배포:
```bash
# KYCRegistry만
forge script script/deploy/DeployCompliance.s.sol:DeployKYCRegistryOnlyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

### 4. 전체 배포 (Orchestrator)

모든 컨트랙트를 의존성 순서대로 배포합니다.

```bash
forge script script/DeployOrchestrator.s.sol:DeployOrchestratorScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

레이어별 배포:
```bash
# Layer 0만
DEPLOY_LAYER=0 forge script script/DeployOrchestrator.s.sol:DeployOrchestratorScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Layer 1만
DEPLOY_LAYER=1 forge script script/DeployOrchestrator.s.sol:DeployOrchestratorScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Layer 2만
DEPLOY_LAYER=2 forge script script/DeployOrchestrator.s.sol:DeployOrchestratorScript \
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
forge script script/deploy/DeployERC4337.s.sol:DeployERC4337Script \
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
  "entryPoint": "0x...",
  "kernel": "0x...",
  "kernelFactory": "0x...",
  "ecdsaValidator": "0x...",
  "verifyingPaymaster": "0x...",
  "erc5564Announcer": "0x...",
  "erc6538Registry": "0x..."
}
```

## Paymaster 펀딩

배포 후 Paymaster가 가스를 후원하려면 ETH를 예치해야 합니다.

```bash
# FundPaymasterScript 사용
forge script script/deploy/DeployDevnet.s.sol:FundPaymasterScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

# 또는 cast로 직접 예치
cast send <ENTRYPOINT_ADDRESS> "depositTo(address)" <PAYMASTER_ADDRESS> \
  --value 10ether \
  --rpc-url http://127.0.0.1:8545
```

## 트러블슈팅

### 1. CreateCollision 오류

이미 같은 주소에 컨트랙트가 배포되어 있습니다.

```bash
# 해결: Anvil 재시작
# 터미널에서 Anvil 종료 후 재시작
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
# 1. DeployERC4337 (EntryPoint)
# 2. DeployERC7579 (Kernel - EntryPoint 필요)
# 3. DeployPrivacy
# 4. DeployCompliance
```
