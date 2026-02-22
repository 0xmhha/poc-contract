# StableNet Contract Deployment Order

> **Note**: This is a temporary document for deployment script organization.
> Delete after deployment scripts are finalized.

## Overview

Total: **42 contracts** across **7 phases** (0-6)

## Deployment Scripts

| Script | Shell Wrapper | Description |
|--------|---------------|-------------|
| `script/ts/deploy-all.ts` | `script/deploy-all.sh` | Full deployment + configuration (one-click) |
| `script/ts/deploy-tokens.ts` | `script/deploy-tokens.sh` | wKRC, USDC tokens |
| `script/ts/deploy-entrypoint.ts` | `script/deploy-entrypoint.sh` | ERC-4337 EntryPoint |
| `script/ts/deploy-smartaccount.ts` | `script/deploy-smartaccount.sh` | Kernel, KernelFactory, FactoryStaker |
| `script/ts/deploy-validators.ts` | `script/deploy-validators.sh` | ERC-7579 Validators (5 contracts) |
| `script/ts/deploy-hooks.ts` | `script/deploy-hooks.sh` | ERC-7579 Hooks (2 contracts) |
| `script/ts/deploy-fallbacks.ts` | `script/deploy-fallbacks.sh` | ERC-7579 Fallbacks (2 contracts) |
| `script/ts/deploy-executors.ts` | `script/deploy-executors.sh` | ERC-7579 Executors (2 contracts) |
| `script/ts/deploy-compliance.ts` | `script/deploy-compliance.sh` | Compliance (4 contracts) |
| `script/ts/deploy-privacy.ts` | `script/deploy-privacy.sh` | Privacy ERC-5564/6538 (3 contracts) |
| `script/ts/deploy-permit2.ts` | `script/deploy-permit2.sh` | Permit2 (1 contract) |
| `script/ts/deploy-uniswap.ts` | `script/deploy-uniswap.sh` | UniswapV3 (4 contracts + pool) |
| `script/ts/deploy-defi.ts` | `script/deploy-defi.sh` | DeFi (3 contracts) |
| `script/ts/deploy-paymasters.ts` | `script/deploy-paymasters.sh` | Paymasters (4 contracts) |
| `script/ts/stake-paymaster.ts` | `script/stake-paymaster.sh` | Paymaster EntryPoint deposit/withdraw |
| `script/ts/configure-paymaster.ts` | `script/configure-paymaster.sh` | Paymaster configuration (tokens, whitelist, budget) |
| `script/ts/transfer-usdc.ts` | `script/transfer-usdc.sh` | USDC transfer utility |
| `script/ts/stake-entrypoint.ts` | `script/stake-entrypoint.sh` | Bundler EntryPoint deposit/stake |
| `script/ts/stake-factory.ts` | `script/stake-factory.sh` | FactoryStaker stake + approve factory |

## Deployment Phases

### Phase 0: Base Infrastructure

| Step | Contract | Script | Profile | Status |
|------|----------|--------|---------|--------|
| 0.1 | wKRC | DeployTokens.s.sol | tokens | ✅ Done |
| 0.2 | USDC | DeployTokens.s.sol | tokens | ✅ Done |
| 0.3 | EntryPoint | DeployEntryPoint.s.sol | entrypoint | ✅ Done |

**Dependencies**: None

---

### Phase 1: ERC-7579 Smart Account

| Step | Contract | Script | Profile | Status |
|------|----------|--------|---------|--------|
| 1.1 | Kernel | DeployKernel.s.sol | smartaccount | ✅ Done |
| 1.2 | KernelFactory | DeployKernel.s.sol | smartaccount | ✅ Done |
| 1.3 | FactoryStaker | DeployKernel.s.sol | smartaccount | ✅ Done |

**Dependencies**: EntryPoint (Phase 0)

**Deployment Command**:
```bash
# Deploy Smart Account (Kernel)
./script/deploy-smartaccount.sh --broadcast          # Deploy
./script/deploy-smartaccount.sh --broadcast --verify # Deploy + Verify
./script/deploy-smartaccount.sh --verify             # Verify only
```

**Post-Deployment**:
- FactoryStaker should stake in EntryPoint for reputation (see `docs/ENTRYPOINT_DEPOSIT_STAKE.md`)

---

### Phase 2: ERC-7579 Modules

> **Note**: ERC-7579 모듈은 Smart Account에 설치하여 기능을 확장합니다.
> 모든 모듈은 `installModule()` 함수를 통해 Smart Account에 설치됩니다.

#### 2.1 Validators

서명 검증 모듈 - UserOperation의 서명을 검증합니다.

| Contract | Description | Script | Profile | Status |
|----------|-------------|--------|---------|--------|
| ECDSAValidator | 기본 ECDSA 서명 검증 (가장 일반적) | DeployValidators.s.sol | validators | ✅ Done |
| WeightedECDSAValidator | 가중치 기반 멀티시그 | DeployValidators.s.sol | validators | ✅ Done |
| MultiChainValidator | 크로스체인 검증 지원 | DeployValidators.s.sol | validators | ✅ Done |
| MultiSigValidator | 표준 멀티시그 검증 | DeployValidators.s.sol | validators | ✅ Done |
| WebAuthnValidator | Passkey/WebAuthn 검증 | DeployValidators.s.sol | validators | ✅ Done |

#### 2.2 Hooks

트랜잭션 실행 전/후 검증 모듈 - 정책 적용 및 감사 로깅에 사용됩니다.

| Contract | Description | Script | Profile | Status |
|----------|-------------|--------|---------|--------|
| SpendingLimitHook | 토큰별 지출 한도 적용 | DeployHooks.s.sol | hooks | ✅ Done |
| AuditHook | 컴플라이언스/감사 로깅 | DeployHooks.s.sol | hooks | ✅ Done |

#### 2.3 Fallbacks

콜백 처리 모듈 - 토큰 수신 및 플래시론 콜백을 처리합니다.

| Contract | Description | Script | Profile | Status |
|----------|-------------|--------|---------|--------|
| TokenReceiverFallback | ERC-721/1155/777 토큰 수신 | DeployFallbacks.s.sol | fallbacks | ✅ Done |
| FlashLoanFallback | 플래시론 콜백 (AAVE, Uniswap 등) | DeployFallbacks.s.sol | fallbacks | ✅ Done |

#### 2.4 Executors

자동화 실행 모듈 - 위임 실행 및 반복 결제에 사용됩니다.

| Contract | Description | Script | Profile | Status |
|----------|-------------|--------|---------|--------|
| SessionKeyExecutor | 임시 세션키 (게임, DeFi 자동화) | DeployExecutors.s.sol | executors | ✅ Done |
| RecurringPaymentExecutor | 반복 결제 (구독, 급여) | DeployExecutors.s.sol | executors | ✅ Done |

**Dependencies**: None (independent modules)

**Deployment Commands**:
```bash
# 2.1 Validators
./script/deploy-validators.sh --broadcast          # Deploy
./script/deploy-validators.sh --broadcast --verify # Deploy + Verify
./script/deploy-validators.sh --verify             # Verify only

# 2.2 Hooks
./script/deploy-hooks.sh --broadcast          # Deploy
./script/deploy-hooks.sh --broadcast --verify # Deploy + Verify
./script/deploy-hooks.sh --verify             # Verify only

# 2.3 Fallbacks
./script/deploy-fallbacks.sh --broadcast          # Deploy
./script/deploy-fallbacks.sh --broadcast --verify # Deploy + Verify
./script/deploy-fallbacks.sh --verify             # Verify only

# 2.4 Executors
./script/deploy-executors.sh --broadcast          # Deploy
./script/deploy-executors.sh --broadcast --verify # Deploy + Verify
./script/deploy-executors.sh --verify             # Verify only
```

**Post-Deployment**:
- Install modules on Smart Accounts via `installModule()`
- See `docs/KERNEL_ARCHITECTURE.md` for module installation guide

---

### Phase 3: Feature Modules

> **Note**: Feature Modules는 규제 준수, 프라이버시, 토큰 승인 기능을 제공합니다.

#### 3.1 Compliance

규제 준수 모듈 - KYC, 감사 로깅, 준비금 증명, 규제기관 관리를 제공합니다.

| Contract | Description | Script | Profile | Status |
|----------|-------------|--------|---------|--------|
| KYCRegistry | KYC 상태 관리 (다중 관할권 지원) | DeployCompliance.s.sol | compliance | ✅ Done |
| AuditLogger | 불변 감사 로깅 (7년 보존) | DeployCompliance.s.sol | compliance | ✅ Done |
| ProofOfReserve | 100% 준비금 검증 (Chainlink PoR) | DeployCompliance.s.sol | compliance | ✅ Done |
| RegulatoryRegistry | 규제기관 관리 (2-of-3 멀티시그) | DeployCompliance.s.sol | compliance | ✅ Done |

#### 3.2 Privacy (ERC-5564/6538)

프라이버시 모듈 - Stealth Address를 통한 프라이버시 보호 입출금 시스템입니다.

| Contract | Description | Script | Profile | Status |
|----------|-------------|--------|---------|--------|
| ERC5564Announcer | Stealth address 알림 시스템 | DeployPrivacy.s.sol | privacy | ✅ Done |
| ERC6538Registry | Stealth meta-address 레지스트리 | DeployPrivacy.s.sol | privacy | ✅ Done |
| PrivateBank | 프라이버시 보호 입출금 | DeployPrivacy.s.sol | privacy | ✅ Done |

#### 3.3 Permit2

토큰 승인 모듈 - Uniswap의 Permit2를 통한 서명 기반 토큰 전송입니다.

| Contract | Description | Script | Profile | Status |
|----------|-------------|--------|---------|--------|
| Permit2 | 서명 기반 토큰 전송 (EIP-712) | DeployPermit2.s.sol | permit2 | ✅ Done |

**Dependencies**: None

**Deployment Commands**:
```bash
# 3.1 Compliance
./script/deploy-compliance.sh --broadcast          # Deploy
./script/deploy-compliance.sh --broadcast --verify # Deploy + Verify
./script/deploy-compliance.sh --verify             # Verify only

# 3.2 Privacy (ERC-5564/6538)
./script/deploy-privacy.sh --broadcast          # Deploy
./script/deploy-privacy.sh --broadcast --verify # Deploy + Verify
./script/deploy-privacy.sh --verify             # Verify only

# 3.3 Permit2
./script/deploy-permit2.sh --broadcast          # Deploy
./script/deploy-permit2.sh --broadcast --verify # Deploy + Verify
./script/deploy-permit2.sh --verify             # Verify only
```

**Environment Variables (Compliance)**:
- `ADMIN_ADDRESS`: 관리자 주소 (기본값: deployer)
- `RETENTION_PERIOD`: AuditLogger 보존 기간 (기본값: 7년)
- `AUTO_PAUSE_THRESHOLD`: ProofOfReserve 자동 일시정지 임계값 (기본값: 3)
- `APPROVER_1`, `APPROVER_2`, `APPROVER_3`: RegulatoryRegistry 승인자

---

### Phase 4: DeFi & Paymasters

#### 4.1 UniswapV3

Uniswap V3 AMM 인프라 - DEX 기능을 제공하며 DeFi 모듈의 기반이 됩니다.

| Contract | Script | Profile | Status |
|----------|--------|---------|--------|
| UniswapV3Factory | deploy-uniswap.ts | uniswap | ✅ Done |
| SwapRouter | deploy-uniswap.ts | uniswap | ✅ Done |
| Quoter | deploy-uniswap.ts | uniswap | ✅ Done |
| NonfungiblePositionManager | deploy-uniswap.ts | uniswap | ✅ Done |
| WKRC/USDC Pool | deploy-uniswap.ts | uniswap | ✅ Done |

> **Note**: WKRC는 NativeCoinAdapter (0x1000)를 사용합니다.

#### 4.2 DeFi

DeFi 핵심 모듈 - 가격 오라클, 대출 풀, 스테이킹 볼트를 제공합니다.

| Contract | Description | Script | Profile | Status |
|----------|-------------|--------|---------|--------|
| PriceOracle | Chainlink + Uniswap V3 TWAP 가격 오라클 | DeployDeFi.s.sol | defi | ✅ Done |
| LendingPool | 담보 기반 대출 풀 (플래시론 지원) | DeployDeFi.s.sol | defi | ✅ Done |
| StakingVault | 시간 잠금 보상형 스테이킹 볼트 | DeployDeFi.s.sol | defi | ✅ Done |

**Dependencies**: Tokens (Phase 0), UniswapV3 (Phase 4.1 - for PriceOracle TWAP)

**Deployment Commands**:
```bash
# 4.1 UniswapV3
./script/deploy-uniswap.sh                           # Dry run
./script/deploy-uniswap.sh --broadcast               # Deploy
./script/deploy-uniswap.sh --broadcast --create-pool # Deploy + Create WKRC/USDC Pool
./script/deploy-uniswap.sh --force                   # Force redeploy

# 4.2 DeFi
./script/deploy-defi.sh                              # Dry run
./script/deploy-defi.sh --broadcast                  # Deploy
./script/deploy-defi.sh --broadcast --verify         # Deploy + Verify
./script/deploy-defi.sh --verify                     # Verify only
```

**Environment Variables (DeFi)**:
- `STAKING_TOKEN`: 스테이킹 토큰 (기본값: WKRC/NativeCoinAdapter 0x1000)
- `REWARD_TOKEN`: 보상 토큰 (기본값: 스테이킹 토큰과 동일)
- `REWARD_RATE`: 초당 보상량 (기본값: 1e15 = 0.001 tokens/sec)
- `LOCK_PERIOD`: 잠금 기간 (기본값: 7일)
- `EARLY_WITHDRAW_PENALTY`: 조기 출금 패널티 (기본값: 1000 = 10%)
- `MIN_STAKE`: 최소 스테이킹량 (기본값: 1e18 = 1 token)
- `MAX_STAKE`: 최대 스테이킹량 (기본값: 0 = 무제한)

**Post-Deployment**:
- PriceOracle: Chainlink feeds 또는 Uniswap V3 pools 설정
- LendingPool: `configureAsset()`로 자산 설정
- StakingVault: `addRewards()`로 보상 추가

#### 4.3 Paymasters

ERC-4337 Paymaster 인프라 - 가스비 후원 및 ERC20 토큰으로 가스비 결제를 지원합니다.

| Contract | Description | Script | Profile | Status |
|----------|-------------|--------|---------|--------|
| VerifyingPaymaster | 오프체인 서명 검증 기반 가스 후원 | DeployPaymasters.s.sol | paymaster | ✅ Done |
| SponsorPaymaster | 예산 기반 가스 후원 (일일 한도) | DeployPaymasters.s.sol | paymaster | ✅ Done |
| ERC20Paymaster | ERC20 토큰으로 가스비 결제 (PriceOracle 필요) | DeployPaymasters.s.sol | paymaster | ✅ Done |
| Permit2Paymaster | Permit2 서명 기반 가스리스 결제 (Permit2 + PriceOracle 필요) | DeployPaymasters.s.sol | paymaster | ✅ Done |

**Dependencies**: EntryPoint (Phase 0), PriceOracle (Phase 4.2), Permit2 (Phase 3.3)

**Deployment Commands**:
```bash
# 4.3 Paymasters
./script/deploy-paymasters.sh                              # Dry run
./script/deploy-paymasters.sh --broadcast                  # Deploy
./script/deploy-paymasters.sh --broadcast --verify         # Deploy + Verify
./script/deploy-paymasters.sh --verify                     # Verify only
./script/deploy-paymasters.sh --broadcast --force          # Force redeploy
./script/deploy-paymasters.sh --broadcast --force --verify # Force redeploy + Verify
```

> **Note**: `--force` 플래그 사용 시에도 의존성 주소(EntryPoint, PriceOracle, Permit2)는
> broadcast 폴더에서 자동으로 로드되어 환경변수로 전달됩니다.

**Environment Variables (Paymasters)**:
- `OWNER_ADDRESS`: Paymaster 소유자 주소 (기본값: deployer)
- `VERIFYING_SIGNER`: 서명 검증자 주소 (기본값: deployer)
- `MARKUP`: 가격 마크업 (기본값: 1000 = 10%)

**Post-Deployment**:

1. **EntryPoint 예치금 입금** (모든 Paymaster 필수):
   ```bash
   # 모든 Paymaster에 1 ETH 예치
   ./script/stake-paymaster.sh --deposit=1 --paymaster=all

   # 특정 Paymaster에만 예치
   ./script/stake-paymaster.sh --deposit=0.5 --paymaster=verifying
   ./script/stake-paymaster.sh --deposit=2 --paymaster=erc20

   # 예치금 확인
   ./script/stake-paymaster.sh --info
   ```

2. **ERC20Paymaster 토큰 설정**:
   ```bash
   # USDC를 지원 토큰으로 추가
   ./script/configure-paymaster.sh add-token <USDC_ADDRESS>

   # 토큰 정보 확인
   ./script/configure-paymaster.sh token-info <USDC_ADDRESS>

   # 마크업 설정 (기본값: 10%)
   ./script/configure-paymaster.sh set-markup 1500  # 15%
   ```

3. **SponsorPaymaster 설정**:
   ```bash
   # 화이트리스트에 주소 추가
   ./script/configure-paymaster.sh whitelist <USER_ADDRESS>

   # 사용자 예산 설정 (0.5 ETH, 1일)
   ./script/configure-paymaster.sh set-budget <USER_ADDRESS> 0.5 86400

   # 기본 예산 설정
   ./script/configure-paymaster.sh set-default-budget 0.1 86400

   # 캠페인 생성 (인터랙티브)
   ./script/configure-paymaster.sh create-campaign

   # 설정 확인
   ./script/configure-paymaster.sh info
   ```

---

### Phase 5: Plugins (Optional)

| Contract | Script | Profile | Status |
|----------|--------|---------|--------|
| AutoSwapPlugin | DeployPlugins.s.sol | plugins | ⏳ Pending |
| MicroLoanPlugin | DeployPlugins.s.sol | plugins | ⏳ Pending |
| OnRampPlugin | DeployPlugins.s.sol | plugins | ⏳ Pending |

**Dependencies**: DeFi (Phase 4)

---

### Phase 6: Subscription & Bridge

#### 6.1 Subscription (ERC-7715)

| Contract | Script | Profile | Status |
|----------|--------|---------|--------|
| ERC7715PermissionManager | DeploySubscription.s.sol | subscription | ⏳ Pending |
| SubscriptionManager | DeploySubscription.s.sol | subscription | ⏳ Pending |

#### 6.2 Bridge

| Contract | Script | Profile | Status |
|----------|--------|---------|--------|
| BridgeValidator | DeployBridge.s.sol | bridge | ⏳ Pending |
| BridgeGuardian | DeployBridge.s.sol | bridge | ⏳ Pending |
| BridgeRateLimiter | DeployBridge.s.sol | bridge | ⏳ Pending |
| OptimisticVerifier | DeployBridge.s.sol | bridge | ⏳ Pending |
| SecureBridge | DeployBridge.s.sol | bridge | ⏳ Pending |

**Dependencies**: None

---

## Deployment Commands

### Individual Deployment Scripts

```bash
# Phase 0: Tokens (wKRC, USDC)
./script/deploy-tokens.sh --broadcast          # Deploy
./script/deploy-tokens.sh --broadcast --verify # Deploy + Verify
./script/deploy-tokens.sh --verify             # Verify only

# Phase 0: EntryPoint
./script/deploy-entrypoint.sh --broadcast          # Deploy
./script/deploy-entrypoint.sh --broadcast --verify # Deploy + Verify
./script/deploy-entrypoint.sh --verify             # Verify only

# Phase 1: Smart Account (Kernel)
./script/deploy-smartaccount.sh --broadcast          # Deploy
./script/deploy-smartaccount.sh --broadcast --verify # Deploy + Verify
./script/deploy-smartaccount.sh --verify             # Verify only

# Phase 2: Validators
./script/deploy-validators.sh --broadcast          # Deploy
./script/deploy-validators.sh --broadcast --verify # Deploy + Verify
./script/deploy-validators.sh --verify             # Verify only

# Phase 2: Hooks
./script/deploy-hooks.sh --broadcast          # Deploy
./script/deploy-hooks.sh --broadcast --verify # Deploy + Verify
./script/deploy-hooks.sh --verify             # Verify only

# Phase 2: Fallbacks
./script/deploy-fallbacks.sh --broadcast          # Deploy
./script/deploy-fallbacks.sh --broadcast --verify # Deploy + Verify
./script/deploy-fallbacks.sh --verify             # Verify only

# Phase 2: Executors
./script/deploy-executors.sh --broadcast          # Deploy
./script/deploy-executors.sh --broadcast --verify # Deploy + Verify
./script/deploy-executors.sh --verify             # Verify only

# Phase 3: Compliance
./script/deploy-compliance.sh --broadcast          # Deploy
./script/deploy-compliance.sh --broadcast --verify # Deploy + Verify
./script/deploy-compliance.sh --verify             # Verify only

# Phase 3: Privacy (ERC-5564/6538)
./script/deploy-privacy.sh --broadcast          # Deploy
./script/deploy-privacy.sh --broadcast --verify # Deploy + Verify
./script/deploy-privacy.sh --verify             # Verify only

# Phase 3: Permit2
./script/deploy-permit2.sh --broadcast          # Deploy
./script/deploy-permit2.sh --broadcast --verify # Deploy + Verify
./script/deploy-permit2.sh --verify             # Verify only

# Phase 4: UniswapV3
./script/deploy-uniswap.sh                           # Dry run
./script/deploy-uniswap.sh --broadcast               # Deploy
./script/deploy-uniswap.sh --broadcast --create-pool # Deploy + Create WKRC/USDC Pool
./script/deploy-uniswap.sh --force                   # Force redeploy

# Phase 4: DeFi
./script/deploy-defi.sh                         # Dry run
./script/deploy-defi.sh --broadcast             # Deploy
./script/deploy-defi.sh --broadcast --verify    # Deploy + Verify
./script/deploy-defi.sh --verify                # Verify only

# Phase 4: Paymasters
./script/deploy-paymasters.sh                              # Dry run
./script/deploy-paymasters.sh --broadcast                  # Deploy
./script/deploy-paymasters.sh --broadcast --verify         # Deploy + Verify
./script/deploy-paymasters.sh --verify                     # Verify only
./script/deploy-paymasters.sh --broadcast --force          # Force redeploy
./script/deploy-paymasters.sh --broadcast --force --verify # Force redeploy + Verify

# Utility: Paymaster EntryPoint Deposit
./script/stake-paymaster.sh --info                    # Check deposit balances
./script/stake-paymaster.sh --deposit=1 --paymaster=all  # Deposit 1 ETH to all
./script/stake-paymaster.sh --deposit=0.5 --paymaster=erc20  # Deposit to specific
./script/stake-paymaster.sh --withdraw=0.5 --paymaster=verifying  # Withdraw

# Utility: Paymaster Configuration
./script/configure-paymaster.sh info                  # Show all configurations
./script/configure-paymaster.sh add-token 0x...       # Add ERC20 token support
./script/configure-paymaster.sh whitelist 0x...       # Add to sponsor whitelist
./script/configure-paymaster.sh set-budget 0x... 0.5 86400  # Set user budget
./script/configure-paymaster.sh create-campaign       # Create campaign (interactive)

# Utility: USDC Transfer
./script/transfer-usdc.sh                      # Transfer 1000 USDC to test account
./script/transfer-usdc.sh --amount=5000        # Transfer 5000 USDC
./script/transfer-usdc.sh --to=0x123...        # Transfer to specific address

# Utility: Bundler EntryPoint Deposit/Stake
./script/stake-entrypoint.sh --info            # Check current deposit/stake
./script/stake-entrypoint.sh --deposit=10      # Deposit 10 ETH/KRC
./script/stake-entrypoint.sh --stake=1         # Stake 1 ETH/KRC

# Utility: FactoryStaker Stake + Approve
./script/stake-factory.sh --info               # Check current stake status
./script/stake-factory.sh --stake=1            # Stake 1 ETH/KRC
./script/stake-factory.sh --approve            # Approve KernelFactory
./script/stake-factory.sh --stake=1 --approve  # Stake + Approve
```

### Full Deployment (All Phases)

```bash
# Dry run
npx ts-node script/ts/deploy.ts --plan

# Deploy all
npx ts-node script/ts/deploy.ts --broadcast

# Force redeploy
npx ts-node script/ts/deploy.ts --broadcast --force
```

### Selective Deployment

```bash
# Deploy specific steps
npx ts-node script/ts/deploy.ts --broadcast --steps=tokens,entrypoint,kernel
```

---

## Dependency Graph

```
Phase 0: Tokens ─────────────────────────────────────────┐
         EntryPoint ──────────────────┐                  │
                                      │                  │
Phase 1: Kernel ◄─────────────────────┘                  │
         KernelFactory                                   │
         FactoryStaker ─── (stake in EntryPoint)         │
                                                         │
Phase 2: Validators (independent)                        │
         Hooks (independent)                             │
         Fallbacks (independent)                         │
         Executors (independent)                         │
                                                         │
Phase 3: Compliance (independent)                        │
         Privacy (independent)                           │
         Permit2 (independent)                           │
                                                         │
Phase 4: DeFi ◄──────────────────────────────────────────┘
         Paymasters ◄── EntryPoint + DeFi
                    └── (deposit/stake in EntryPoint)
                                      │
Phase 5: Plugins ◄────────────────────┘ (optional)

Phase 6: Subscription (independent)
         Bridge (independent)
```

---

## Progress Tracking

- [x] Phase 0: Base Infrastructure
  - [x] wKRC, USDC (Tokens)
  - [x] EntryPoint
- [x] Phase 1: Smart Account (Kernel)
  - [x] Kernel
  - [x] KernelFactory
  - [x] FactoryStaker
- [x] Phase 2: ERC-7579 Modules
  - [x] Validators (ECDSAValidator, WeightedECDSAValidator, MultiChainValidator, MultiSigValidator, WebAuthnValidator)
  - [x] Hooks (SpendingLimitHook, AuditHook)
  - [x] Fallbacks (TokenReceiverFallback, FlashLoanFallback)
  - [x] Executors (SessionKeyExecutor, RecurringPaymentExecutor)
- [x] Phase 3: Feature Modules
  - [x] Compliance (KYCRegistry, AuditLogger, ProofOfReserve, RegulatoryRegistry)
  - [x] Privacy (ERC5564Announcer, ERC6538Registry, PrivateBank)
  - [x] Permit2
- [x] Phase 4: DeFi & Paymasters
  - [x] UniswapV3 (UniswapV3Factory, SwapRouter, Quoter, NonfungiblePositionManager, WKRC/USDC Pool)
  - [x] DeFi (PriceOracle, LendingPool, StakingVault)
  - [x] Paymasters (VerifyingPaymaster, SponsorPaymaster, ERC20Paymaster, Permit2Paymaster)
- [ ] Phase 5: Plugins (optional)
- [ ] Phase 6: Subscription & Bridge

---

## Related Documentation

- `docs/ENTRYPOINT_DEPOSIT_STAKE.md` - EntryPoint Deposit & Stake 가이드
- `docs/KERNEL_ARCHITECTURE.md` - Kernel 아키텍처 및 EIP-7702 통합 가이드

---

## Notes

### Verification Issue (Resolved)

`foundry.toml`에서 `src/erc4337-entrypoint/*`가 skip 목록에 있으면 기본 빌드에서 아티팩트가 생성되지 않아 verification 실패.

**해결**: skip 목록에서 `src/erc4337-entrypoint/*` 제거

### Constructor Args for Verification

#### Phase 1: Smart Account

| Contract | Constructor Args |
|----------|-----------------|
| Kernel | `IEntryPoint _entrypoint` |
| KernelFactory | `address _impl` (Kernel address) |
| FactoryStaker | `address _owner` (ADMIN_ADDRESS, defaults to deployer) |

#### Phase 2: ERC-7579 Modules

| Contract | Constructor Args |
|----------|-----------------|
| ECDSAValidator | None |
| WeightedECDSAValidator | None |
| MultiChainValidator | None |
| MultiSigValidator | None |
| WebAuthnValidator | None |
| SpendingLimitHook | None |
| AuditHook | None |
| TokenReceiverFallback | None |
| FlashLoanFallback | None |
| SessionKeyExecutor | None |
| RecurringPaymentExecutor | None |

#### Phase 3: Feature Modules

| Contract | Constructor Args |
|----------|-----------------|
| KYCRegistry | `address admin` |
| AuditLogger | `address admin, uint256 retentionPeriod` |
| ProofOfReserve | `address admin, uint256 autoPauseThreshold` |
| RegulatoryRegistry | `address[] memory approvers` (3 addresses) |
| ERC5564Announcer | None |
| ERC6538Registry | None |
| PrivateBank | `address announcer, address registry` |
| Permit2 | None |

#### Phase 4: DeFi & Paymasters

| Contract | Constructor Args |
|----------|-----------------|
| UniswapV3Factory | None |
| SwapRouter | `address factory, address WETH9` |
| Quoter | `address factory, address WETH9` |
| NonfungiblePositionManager | `address factory, address WETH9, address tokenDescriptor` |
| PriceOracle | None |
| LendingPool | `address _oracle` |
| StakingVault | `address _stakingToken, address _rewardToken, VaultConfig _config` |
| VerifyingPaymaster | `IEntryPoint _entryPoint, address _owner, address _verifyingSigner` |
| SponsorPaymaster | `IEntryPoint _entryPoint, address _owner, address _signer` |
| ERC20Paymaster | `IEntryPoint _entryPoint, address _owner, IPriceOracle _oracle, uint256 _markup` |
| Permit2Paymaster | `IEntryPoint _entryPoint, address _owner, IPermit2 _permit2, IPriceOracle _oracle, uint256 _markup` |

> **Note**: WETH9 = NativeCoinAdapter (0x1000), tokenDescriptor = address(0) for initial deployment
