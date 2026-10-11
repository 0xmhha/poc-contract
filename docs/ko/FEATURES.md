# 지원 기능 목록

`src/` 아래 18개 모듈이 제공하는 기능을 모듈별로 정리한 문서입니다. 컨트랙트 간 의존 관계와 호출 흐름은 [아키텍처](./ARCHITECTURE.md)를 참고하세요.

> 이 문서는 각 컨트랙트의 NatSpec(`@title`/`@notice`/`@dev`)과 external/public 함수 시그니처를 근거로 작성했습니다. 함수 내부 로직과 테스트 통과 여부는 이 문서에서 검증하지 않았습니다.

## 목차

1. [개요](#1-개요)
2. [Account Abstraction 코어](#2-account-abstraction-코어)
3. [ERC-7579 모듈](#3-erc-7579-모듈)
4. [Paymaster](#4-paymaster)
5. [DeFi와 토큰](#5-defi와-토큰)
6. [Perpetual 선물 거래](#6-perpetual-선물-거래)
7. [Bridge](#7-bridge)
8. [Privacy](#8-privacy)
9. [Compliance와 구독 결제](#9-compliance와-구독-결제)
10. [배포와 운영 도구](#10-배포와-운영-도구)
11. [알려진 제약](#11-알려진-제약)
12. [테스트 현황](#12-테스트-현황)

---

## 1. 개요

StableNet PoC 컨트랙트는 다음 일곱 영역으로 나뉩니다.

| 영역 | 모듈 |
|---|---|
| Account Abstraction | `erc4337-entrypoint`, `erc7579-smartaccount`, `erc7579-validators`, `erc7579-executors`, `erc7579-hooks`, `erc7579-fallbacks`, `erc7579-plugins`, `permit2` |
| 가스 대납 | `erc4337-paymaster` |
| DeFi | `defi`, `tokens` |
| 파생상품 | `perpetual` (testnet 전용) |
| Cross-chain | `bridge` |
| Privacy | `privacy` |
| 규제·결제 | `compliance`, `subscription` |

`common/libraries/Constants.sol`은 Enterprise Stealth와 Perpetual 시스템이 공유하는 전역 상수 라이브러리입니다.

---

## 2. Account Abstraction 코어

| 모듈 | 컨트랙트 | 지원 기능 |
|---|---|---|
| `erc4337-entrypoint` | EntryPoint, NonceManager, StakeManager, SenderCreator, EntryPointSimulations | ERC-4337 EntryPoint v0.9(eth-infinitism 기반). UserOperation 검증·실행, nonce 관리, stake·deposit 관리, simulation. EIP-7702 delegate 계정 초기화 지원(`Eip7702Support`) |
| | Create2Deployer | CREATE2로 결정적 주소에 배포(`deploy`, `computeAddress`) |
| `erc7579-smartaccount` | Kernel | ERC-7579 모듈형 스마트 계정(ZeroDev Kernel 기반). root validator 변경, validator·executor·hook·fallback 설치와 교체(`installValidations`, `replaceModule`), ERC-1271 서명 검증, ERC-721/1155 수신, 업그레이드(`upgradeTo`), delegatecall whitelist, hook gas 한도 설정. 중첩된 executor 호출 뒤에도 바깥 executor context가 유지됨 |
| | KernelFactory, FactoryStaker | 계정 생성과 주소 사전 계산, factory의 EntryPoint stake 관리 |
| `permit2` | Permit2 (AllowanceTransfer, SignatureTransfer) | Uniswap Permit2 이식. 서명 기반 approve와 transfer |

**위임된 `execute` 권한.** root가 아닌 validator에 `execute` selector를 허용하면(`grantAccess` 또는 설치 시 `selectorData`) 그 validator는 계정의 관리 함수에도 닿을 수 있습니다. `execute`의 대상이 계정 자신일 수 있고 Kernel은 `onlyEntryPointOrSelfOrRoot`에서 self 호출을 허용하므로, `execute(self, changeRootValidator(...))`나 `execute(self, installModule(...))`가 성공합니다. 따라서 `execute` 허용은 root validator 교체를 포함한 계정 전체 권한을 주는 것과 같습니다. Kernel은 이를 막지 않습니다. 제한된 권한만 위임하려면 그 validator에 self 대상 실행을 거부하는 execution hook을 붙이거나(PolicyHook, SpendingLimitHook, AuditHook, HealthFactorHook이 `HookExecutionDataLib.checkExecutionTarget`으로 거부), 호출 대상을 제한하는 permission policy를 사용해야 합니다.

---

## 3. ERC-7579 모듈

### Validators (`erc7579-validators`)

| 컨트랙트 | 기능 |
|---|---|
| ECDSAValidator | 단일 EOA 소유자 서명 검증 |
| MultiSigValidator | M-of-N 멀티시그. 서명자 추가·제거·교체, threshold 변경 |
| WeightedECDSAValidator | 가중치 기반 guardian 승인. `approve`, `approveWithSig`, `veto` |
| WebAuthnValidator (+`P256` 라이브러리) | Passkey·생체 인증(secp256r1). credential 등록·폐기 |
| MultiChainValidator | Merkle proof로 여러 체인의 UserOperation을 한 번의 서명으로 승인 |

### Executors (`erc7579-executors`)

| 컨트랙트 | 기능 |
|---|---|
| SessionKeyExecutor | 세션 키 위임 실행. target·selector 권한 부여, 지출 한도, 만료 |
| RecurringPaymentExecutor | 정기 결제 스케줄 생성·일시정지·재개·취소, 금액·수령자 변경 |
| SwapExecutor | Uniswap V3 single-hop(`swapExactInputSingle`)·multi-hop(`swapExactInput`) swap. 토큰 whitelist, 일일·건당 한도, slippage 보호 |
| LendingExecutor | LendingPool supply·withdraw·borrow·repay. 자산 allowlist, 최소 health factor, 차입 한도 |
| StakingExecutor | stake·lock stake·unstake·claim·compound. 풀 allowlist, 풀당 한도, 일일 한도 |

### Hooks (`erc7579-hooks`)

| 컨트랙트 | 기능 |
|---|---|
| SpendingLimitHook | 실행 전후 잔액을 비교해 토큰별·기간별 지출 한도 적용. 한도가 걸린 토큰에 대한 0이 아닌 allowance 부여(approve, increaseAllowance, permit)를 거부하므로, approve 후 실행하는 SwapExecutor·LendingExecutor는 이 토큰에 대해 함께 쓸 수 없음. Permit2, 비표준 permit, off-chain ERC-1271 서명을 통한 allowance 부여는 감지하지 못함 |
| PolicyHook | allowlist·blocklist 모드, target·selector 제한, target별 value 한도, 기간당 트랜잭션 수 제한, 긴급 정지 |
| AuditHook | 트랜잭션 감사 로그, blocklist, 의심 트랜잭션 큐잉 |
| HealthFactorHook | lending 대상 호출 뒤 health factor가 임계값 아래로 떨어지면 revert |

`HookExecutionDataLib`는 Kernel이 hook에 넘기는 calldata에서 실행(single·batch·delegatecall)을 디코딩하는 공용 라이브러리로, PolicyHook·SpendingLimitHook·AuditHook·HealthFactorHook이 함께 사용합니다.

### Fallbacks (`erc7579-fallbacks`)

| 컨트랙트 | 기능 |
|---|---|
| FlashLoanFallback | AAVE v3(`executeOperation`), Uniswap v3(`uniswapV3FlashCallback`), Balancer(`receiveFlashLoan`), ERC-3156(`onFlashLoan`) callback 처리. fallback과 executor로 함께 설치해야 하며, strategy 호출과 상환은 account 명의로 실행. 대출마다 같은 트랜잭션 안에서 먼저 `beginFlashLoan(lender)`를 호출해야 하고, 없으면 callback이 revert. 프로토콜 whitelist, 로그 |
| TokenReceiverFallback | ERC-777 등 Kernel이 기본 지원하지 않는 토큰 수신 callback. whitelist·blacklist |

### Plugins (`erc7579-plugins`, executor 타입)

| 컨트랙트 | 기능 |
|---|---|
| AutoSwapPlugin | DCA, limit buy·sell, stop-loss, take-profit, trailing stop 주문. 조건 충족 시 실행, 일괄 실행 |
| MicroLoanPlugin | 담보 기반 소액 대출. 유동성 공급·회수, 상환, 청산, 신용 점수 |
| OnRampPlugin | 법정화폐 on-ramp. provider 등록·서명 검증, 사용자 KYC·blacklist, 주문 claim·취소·환불, 일일 한도 |

---

## 4. Paymaster

`erc4337-paymaster` 모듈은 네 가지 가스 지불 방식을 제공합니다.

| 컨트랙트 | 가스 지불 방식 |
|---|---|
| VerifyingPaymaster | off-chain signer 서명으로 가스 대납 |
| SponsorPaymaster | off-chain policy engine 판단에 따른 sponsor(Visa 4-Party 모델) |
| ERC20Paymaster | 미리 approve한 ERC-20(예: USDC)으로 가스 지불. oracle 가격과 markup 적용. validation 단계에서 최대 토큰 비용을 미리 받고 `postOp`에서 남은 금액 환불. reference price를 설정하면 20% 가격 편차 circuit breaker 동작(`updateReferencePrice`) |
| Permit2Paymaster | Permit2 서명으로 별도 approve 없이 ERC-20 가스 지불. ERC20Paymaster와 같은 미리 받기·환불 흐름과 가격 circuit breaker. oracle timestamp가 미래이면 stale로 처리 |

공통 요소:

- `BasePaymaster`: EntryPoint 참조, deposit·stake 관리, validation data 헬퍼
- `PaymasterDataLib` / `PaymasterPayload`: 네 paymaster가 공유하는 `paymasterAndData` envelope 인코딩·디코딩

공용 mempool 호환성 제약은 [11. 알려진 제약](#11-알려진-제약)을 참고하세요.

---

## 5. DeFi와 토큰

| 모듈 | 컨트랙트 | 기능 |
|---|---|---|
| `defi` | LendingPool | 다중 자산 예치·차입, 이용률 기반 변동 금리, 청산 보너스, flash loan |
| | StakingVault | 보상률 설정, lock 기간, 조기 인출 패널티, compound, 긴급 인출 |
| | PriceOracle | Chainlink feed와 Uniswap V3 TWAP 통합, staleness 검사, 금액 환산 |
| | FixedPriceAggregator | Chainlink `AggregatorV3Interface` 호환 고정 가격 feed |
| `src/MockChainlinkFeed.sol` | MockChainlinkFeed | 로컬 테스트용 Chainlink feed |
| `tokens` | USDC | 6 decimals 스테이블코인. minter 역할, blacklist, pause, mint·burn |
| `script/uniswap` | UniswapV3Factory, SwapRouter, Quoter, NonfungiblePositionManager | 로컬 체인에 DEX를 배포하기 위한 스크립트용 컨트랙트 |

---

## 6. Perpetual 선물 거래

`perpetual` 모듈은 오더북 방식의 무기한 선물 거래 시스템입니다. archive된 `stable-poc-contract` 저장소에서 가져온 testnet 참조 구현이며, 감사를 받지 않았고 production용이 아닙니다(`src/perpetual/README.md`). 동작상의 제약은 [11. 알려진 제약](#11-알려진-제약)에 정리했습니다.

| 컨트랙트 | 기능 |
|---|---|
| PerpetualEngine | 사용자 진입점. 마켓 생성·상태·설정 변경, 마진 입출금, 시장가 포지션 진입, 지정가 주문, 포지션 축소·청산, 주문 취소(전체 포함), 레버리지·마진 모드 설정, 긴급 정지와 거래 정지 |
| OrderManager | 주문 생성·취소·수정·만료, 체결(`fillOrder`), 주문 매칭(`matchOrders`), 조건 주문 트리거(`checkAndTrigger`). 주문 유형은 Market, Limit, Stop, StopLimit, TakeProfit, TakeProfitLimit. 실행 정책은 GTC, IOC, FOK, PostOnly |
| PositionManager | 포지션 열기·증가·감소·종료, 마진 추가·제거, 미실현 PnL, 마진 비율, 청산가, open interest |
| MarginManager | Isolated·Cross 마진 모드, 마진 lock·unlock, 필요 마진 계산, 실현·미실현 PnL 반영 |
| FundingRateManager | 펀딩비 계산(TWAP 포함), 누적 funding index, 주기별 정산, 펀딩 이력 스냅샷 |
| Liquidator | 전체·부분·일괄 청산, 청산 수수료와 청산자 보상 |
| InsuranceFund | 마켓별 보험 기금 배분·회수, 손실 보전(`coverLoss`), ADL 발동 임계치 |
| ADLEngine | 자동 디레버리징(ADL) 우선순위 큐, 단건·일괄·자동 ADL 실행 |
| `PerpetualMath` | 고정 소수점 연산, PnL, 마진 비율, 청산가, 펀딩비, ADL 우선순위, 수수료, 레버리지 계산 |

indexer-go의 `perp_orderbook` venue가 `PerpetualEngine`과 `OrderManager`의 이벤트와 `getOrder` 반환값을 고정된 시그니처로 디코딩합니다. 이 시그니처를 바꾸면 indexer와 호환이 깨집니다. 바꿀 때는 두 저장소를 함께 수정하고 `./script/export-venue-abi.sh`로 `abi/perpetual`을 다시 생성해야 합니다. CI가 `abi/perpetual`이 최신인지 검사합니다.

---

## 7. Bridge

`bridge` 모듈은 MPC 서명과 optimistic 검증을 겹쳐 쓰는 다층 방어 구조입니다. SecureBridge가 나머지 컨트랙트를 조합합니다.

| 컨트랙트 | 기능 |
|---|---|
| SecureBridge | 입금, `completeBridge`, 환불, 지원 체인·토큰 매핑, 수수료, TVL 조회 |
| BridgeValidator | 5-of-7 MPC 서명 검증, signer set 교체(`rotateSignerSet`), nonce 관리. nonce 소비는 `setAuthorizedBridge`로 지정한 bridge만 할 수 있음 |
| OptimisticVerifier | challenge 기간이 있는 optimistic 검증, challenge bond와 보상 |
| FraudProofVerifier | Merkle proof·state proof 기반 fraud proof 검증, state root 갱신 |
| BridgeRateLimiter | 건당·시간당·일일 USD 기준 한도, 사용량이 임계치를 넘으면 auto-pause(임계치를 넘긴 거래는 통과하고 이후 거래부터 차단). 사용량은 SecureBridge가 아니라 실제 송신자에게 귀속 |
| BridgeGuardian | 3-of-5 guardian 멀티시그로 제안 실행(unpause 포함)과 blacklist. 긴급 정지는 guardian 1명이 cooldown 없이 언제든 실행 가능 |

---

## 8. Privacy

| 컨트랙트 | 기능 |
|---|---|
| ERC5564Announcer | ERC-5564 stealth address 공지(단건·일괄·공지와 송금 동시), view tag 생성 |
| ERC6538Registry | ERC-6538 stealth meta-address 등록. EIP-712·ERC-1271 서명으로 대리 등록 |
| PrivateBank | stealth address 기반 네이티브·ERC-20 입출금, 건당·일일 입금 한도 |
| `enterprise/StealthVault` | 기업용 stealth 입금 보관, 긴급 인출 |
| `enterprise/StealthLedger` | stealth address별 잔액·거래 이력 원장 |
| `enterprise/WithdrawalManager` | 승인 threshold(기본값과 토큰별 raw 단위 override)와 cooldown이 있는 인출 요청·승인·실행. 인출 요청은 `REQUESTER_ROLE` 보유자만 가능 |
| `enterprise/RoleManager` | 만료 가능한 역할 할당을 지원하는 RBAC |

---

## 9. Compliance와 구독 결제

### Compliance (`compliance`)

| 컨트랙트 | 기능 |
|---|---|
| KYCRegistry | KYC 상태(NONE·PENDING·VERIFIED·REJECTED·EXPIRED), 위험 등급(LOW·MEDIUM·HIGH·PROHIBITED), OFAC·UN·EU 제재 목록, allow·block list, `canTransact` |
| RegulatoryRegistry | 규제기관 등록과 접근 등급, 2-of-3 승인 후 추적(trace) 요청 실행 |
| AuditLogger | 변경할 수 없는 감사 로그. actor·target·유형·기간별 조회, 보존 기간 설정 |
| ProofOfReserve | Chainlink PoR로 100% 준비금 검증, 부족 시 auto-pause, 발행 허용 여부 확인(`checkMintAllowed`) |

### 구독 결제 (`subscription`)

| 컨트랙트 | 기능 |
|---|---|
| SubscriptionManager | 상점 플랜 생성·수정, 구독·해지, 결제 처리(일괄 포함), 프로토콜 수수료 |
| MerchantRegistry | 상점 등록·검증·정지, 상점별 수수료, verifier 관리 |
| ERC7715PermissionManager | ERC-7715 권한 부여(서명 기반 포함)·조정·사용·폐기, 권한 유형 등록. 서명된 권한 부여에는 rule 목록과 `isAdjustmentAllowed`까지 포함되고, 일시정지 중에는 `usePermission`이 차단되며, 서명할 digest는 `hashPermissionGrant`로 계산 |

---

## 10. 배포와 운영 도구

| 경로 | 내용 |
|---|---|
| `script/deploy-all.sh` | 19단계로 50개 이상의 컨트랙트를 의존 순서대로 배포. `--dry-run`, `--from=<step>`, `--verify` 지원 |
| `script/deploy-contract/Deploy*.s.sol` | 모듈별 Foundry 배포 스크립트, oracle 가격 설정(`SetupOraclePrice.s.sol`) |
| `script/utils/BridgeWiring.sol` | bridge가 자금을 옮기기 전에 필요한 컨트랙트 간 권한 설정. 값이 다를 때만 쓰므로 반복 실행해도 안전 |
| `script/deploy-contract/DeployPerpetual.s.sol` | PerpetualEngine, OrderManager, PositionManager, MarginManager만 배포. `DeployAll`에는 포함되지 않음 |
| `script/export-venue-abi.sh` | indexer용 `abi/perpetual` ABI 내보내기 |
| `security/` | Slither·Mythril·Echidna 설정과 감사 스크립트(`run-audit.sh`) |

자세한 배포 절차는 [배포 가이드](./DEPLOYMENT.md)를 참고하세요.

---

## 11. 알려진 제약

### Paymaster는 private bundler 전용

네 paymaster 모두 validation 단계(`_validatePaymasterUserOp`)에서 ERC-4337 simulation 규칙을 어기는 작업을 합니다. 그래서 Pimlico, Alchemy 같은 공용 mempool bundler는 이 paymaster를 쓰는 UserOperation을 거부합니다. 근거는 `src/erc4337-paymaster/BasePaymaster.sol`의 주석입니다.

| Paymaster | 위반 내용 |
|---|---|
| VerifyingPaymaster | `senderNonce[sender]++` (내부 storage 쓰기) |
| SponsorPaymaster | `senderNonce[sender]++` (내부 storage 쓰기) |
| Permit2Paymaster | `PERMIT2.permit()`과 `PERMIT2.transferFrom()` 미리 받기 (외부 컨트랙트 상태 쓰기, 가장 심각) |
| ERC20Paymaster | `safeTransferFrom()` 미리 받기 (외부 토큰 storage 쓰기) |

토큰 paymaster가 validation 단계에서 토큰을 미리 받는 것은 의도된 설계입니다. `postOp`이 revert되어도 EntryPoint는 paymaster의 deposit에서 가스비를 가져갑니다. 그래서 `postOp`에서만 토큰을 받으면 사용자가 가스를 공짜로 쓸 수 있습니다. 토큰 전송은 validation 단계에 그대로 두어야 합니다.

공용 mempool을 지원하려면 같은 주석에 적힌 세 가지 변경이 필요합니다. `senderNonce++`를 `_postOp`으로 옮기거나 EntryPoint nonce로 대체하고, validation에서 `PERMIT2.permit()`을 호출하는 대신 Permit2 사전 approve를 요구하고, ERC20Paymaster와 Permit2Paymaster를 staked paymaster로 운영합니다.

### Perpetual은 testnet 참조 구현

`src/perpetual/README.md`에 적힌 제약입니다.

- 가격이 하드코딩된 placeholder입니다(`PerpetualEngine._getMarketPrice`, `OrderManager.executeMarketOrder`). 실제 oracle 가격으로 거래하지 않습니다.
- `Liquidator.liquidate`와 `ADLEngine`의 대부분이 placeholder입니다. 위 6장의 청산·ADL 기능은 인터페이스 수준이며 실제 동작은 완성되지 않았습니다.
- 배포 스크립트는 네 개 컨트랙트만 배포합니다. FundingRateManager, Liquidator, InsuranceFund, ADLEngine은 배포되지 않습니다.

---

## 12. 테스트 현황

`test/` 디렉터리별로 `test*`·`testFuzz*`·`invariant*` 함수 수를 정규식으로 센 근사치입니다.

| 디렉터리 | 테스트 함수 수 |
|---|---:|
| `bridge` | 236 |
| `privacy` | 201 |
| `erc7579-executors` | 165 |
| `compliance` | 157 |
| `subscription` | 147 |
| `erc7579-validators` | 129 |
| `erc7579-hooks` | 127 |
| `erc7579-plugins` | 125 |
| `defi` | 116 |
| `erc4337-paymaster` | 116 |
| `tokens` | 52 |
| `erc7579-smartaccount` | 37 |
| `erc7579-fallbacks` | 35 |
| `erc4337-entrypoint` | 16 |
| `perpetual` | 15 |
| `permit2` | 12 |
| `deploy` | 1 |

EntryPoint(16), Permit2(12), Kernel(37)는 다른 모든 모듈이 의존하는 핵심 인프라입니다. 그런데도 테스트 수는 다른 모듈보다 훨씬 적습니다. 이 세 모듈은 upstream 구현(eth-infinitism, Uniswap, ZeroDev)을 이식한 것이므로 upstream 테스트가 검증을 대신한다고 볼 수도 있습니다. 하지만 이식 과정에서 바꾼 부분이 있다면 그 부분은 이 저장소에서 따로 테스트해야 합니다.

`perpetual`의 15개 테스트는 모두 `test/perpetual/OrderManager.t.sol`에 있습니다. 이 테스트는 indexer가 의존하는 이벤트 시그니처와 `getOrder` 반환 형식을 고정하고, 주문 생성·매칭·체결·취소·수정·만료·트리거와 마켓 생성을 확인합니다. PositionManager, MarginManager, FundingRateManager, Liquidator, InsuranceFund, ADLEngine을 직접 테스트하는 파일은 없습니다.
