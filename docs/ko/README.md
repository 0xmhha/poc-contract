# StableNet PoC Contracts

StableNet 스마트 컨트랙트 PoC (Proof of Concept) 저장소입니다.

ERC-4337 Account Abstraction, ERC-7579 Modular Smart Account, 스텔스 주소 (ERC-5564/6538), 규제 준수 컨트랙트를 포함합니다.

## 요구사항

| 도구 | 버전 | 설명 |
|-----|------|------|
| Foundry | ≥1.0.0 | Solidity 개발 툴킷 |
| Solidity | 0.8.28 | 스마트 컨트랙트 언어 |
| Anvil | ≥1.0.0 | 로컬 이더리움 노드 |

### Foundry 설치

```bash
# Foundry 설치
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 버전 확인
forge --version
anvil --version
```

## Quick Start

### 1. 의존성 설치

```bash
# 서브모듈 초기화 및 업데이트
git submodule update --init --recursive

# 또는 forge로 직접 설치
forge install
```

### 2. 환경 설정

```bash
# .env 파일 생성
cp .env.example .env

# .env 파일 편집하여 필요한 값 설정
```

### 3. 빌드

```bash
# 전체 빌드
forge build

# 빠른 빌드 (개발용, IR 비활성화)
forge build --profile fast
```

### 4. 테스트

```bash
# 전체 테스트
forge test

# 상세 로그와 함께 테스트
forge test -vvv

# 특정 테스트만 실행
forge test --match-test testKernelDeployment
```

### 5. 로컬 배포 (Anvil)

```bash
# 터미널 1: Anvil 시작 (Prague 하드포크)
anvil --chain-id 31337 --block-time 1 --hardfork prague

# 터미널 2: 컨트랙트 배포 (필수 컨트랙트만)
# Anvil 출력에 표시된 기본 계정 중 하나 사용
forge script script/deploy/DeployDevnet.s.sol:DeployDevnetScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# 전체 컨트랙트 배포
forge script script/DeployOrchestrator.s.sol:DeployOrchestratorScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast
```

배포된 주소는 `deployments/<chainId>/addresses.json`에 저장됩니다.

## 컨트랙트 구조

```
src/
├── erc4337-entrypoint/     # ERC-4337 EntryPoint
├── erc4337-paymaster/      # Paymaster (가스 후원)
├── erc7579-smartaccount/   # ERC-7579 Kernel Smart Account
├── erc7579-validators/     # 서명 검증 모듈
├── erc7579-executors/      # 실행 모듈
├── erc7579-hooks/          # 훅 모듈
├── erc7579-fallbacks/      # Fallback 모듈
├── privacy/                # 스텔스 주소 (ERC-5564/6538)
├── compliance/             # 규제 준수
├── tokens/                 # 토큰 컨트랙트
└── defi/                   # DeFi 컴포넌트
```

## 카테고리별 배포

### ERC-4337 Account Abstraction

EntryPoint, Paymaster 등 Account Abstraction 핵심 컨트랙트

```bash
forge script script/deploy/DeployERC4337.s.sol:DeployERC4337Script \
  --rpc-url <RPC_URL> --broadcast
```

| 컨트랙트 | 설명 |
|---------|------|
| EntryPoint | UserOperation 처리의 핵심 진입점 |
| VerifyingPaymaster | 서명 기반 가스 후원 |
| ERC20Paymaster | ERC20 토큰으로 가스비 지불 |

### ERC-7579 Modular Smart Account

모듈러 스마트 계정 및 플러그인 모듈

```bash
forge script script/deploy/DeployERC7579.s.sol:DeployERC7579Script \
  --rpc-url <RPC_URL> --broadcast
```

| 컨트랙트 | 설명 |
|---------|------|
| Kernel | 모듈러 스마트 계정 구현체 |
| KernelFactory | Kernel 계정 생성 팩토리 |
| ECDSAValidator | ECDSA 서명 검증 |
| WeightedECDSAValidator | 가중치 기반 다중 서명 |
| SessionKeyExecutor | 세션 키 실행 모듈 |
| SpendingLimitHook | 지출 한도 훅 |

### Privacy (ERC-5564/6538)

스텔스 주소 기반 프라이버시 컨트랙트

```bash
forge script script/deploy/DeployPrivacy.s.sol:DeployPrivacyScript \
  --rpc-url <RPC_URL> --broadcast
```

| 컨트랙트 | 설명 |
|---------|------|
| ERC5564Announcer | 스텔스 주소 공지 |
| ERC6538Registry | 스텔스 메타 주소 등록 |
| PrivateBank | 프라이빗 입출금 |

### Compliance

규제 준수 및 감사 컨트랙트

```bash
forge script script/deploy/DeployCompliance.s.sol:DeployComplianceScript \
  --rpc-url <RPC_URL> --broadcast
```

| 컨트랙트 | 설명 |
|---------|------|
| KYCRegistry | KYC 상태 관리 |
| AuditLogger | 감사 로그 기록 |
| ProofOfReserve | 준비금 증명 |

## 환경 변수

| 변수 | 설명 | 기본값 |
|-----|------|-------|
| `ADMIN_ADDRESS` | 관리자 주소 | 배포자 |
| `VERIFYING_SIGNER` | Paymaster 서명자 | 관리자 |
| `SKIP_EXISTING` | 기존 배포 스킵 | true |
| `RPC_URL_LOCAL` | 로컬 RPC URL | - |
| `RPC_URL_SEPOLIA` | Sepolia RPC URL | - |

## 문서

상세 문서는 현재 폴더를 참조하세요:

- [배포 가이드](./DEPLOYMENT.md) - 상세 배포 방법
- [아키텍처](./ARCHITECTURE.md) - 컨트랙트 구조 및 의존성
- [개발 가이드](./DEVELOPMENT.md) - 개발 워크플로우

## 프로젝트 설정

### foundry.toml 주요 설정

```toml
[profile.default]
solc = "0.8.28"
evm_version = "prague"
optimizer = true
optimizer_runs = 200
via_ir = true
```

## 라이선스

MIT License
