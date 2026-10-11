# 플랫폼 운영 검토

2026년 10월 기준으로 네 가지를 정리한 문서입니다.

1. anvil에서 전체 배포와 ERC-4337 end-to-end 흐름을 실행하면서 발견한 문제와 처리 결과
2. 늘어나는 모듈형 컨트랙트를 관리하는 방법
3. upgradeable 코드의 namespaced storage 지원 도구
4. EVM 컨트랙트 보안의 최신 동향

영문판: [docs/OPERATIONS_REVIEW.md](../OPERATIONS_REVIEW.md).

## 목차

1. [개선 항목](#1-개선-항목)
2. [모듈형 컨트랙트 플랫폼 관리](#2-모듈형-컨트랙트-플랫폼-관리)
3. [Namespaced Storage 지원 현황](#3-namespaced-storage-지원-현황)
4. [EVM 컨트랙트 보안 동향 (2025~2026)](#4-evm-컨트랙트-보안-동향-20252026)
5. [출처](#5-출처)

---

## 1. 개선 항목

모든 항목은 이 저장소에서 실제로 관찰한 현상에서 나왔습니다. 상태가 "완료"인 항목은 PR #25에서 처리했습니다. PR #25의 내용은 배포 시 factory 승인, CI의 anvil E2E, storage slot 검사, 문서 수정입니다.

| # | 항목 | 심각도 | 근거 | 상태 |
|---|---|---|---|---|
| 1 | local과 CI의 Foundry 버전 불일치 | 높음 | PR #22는 local forge 1.5.1에서는 통과하고 CI v1.8.3에서는 실패했습니다. v1.8.3은 테스트의 최상위 호출 사이에 transient storage를 초기화합니다. `forge fmt --check`도 local에서만 `src/permit2` 파일 2개로 실패합니다. | 문서에 v1.8.3을 명시했습니다(`foundryup --install v1.8.3`). 각 개발자가 local 툴체인을 직접 바꿔야 합니다. |
| 2 | Kernel의 EIP-170 여유가 31 bytes | 높음 | HOOK-4 수정 때 바이트코드를 손으로 줄여야 했습니다. `upgradeTo`는 공간이 없어 custom error 없이 revert합니다. | 일부 완료. ERC-721/1155 receiver callback을 `fallback()`으로 옮겨 여유를 347 bytes로 늘렸습니다. 추가 여유는 드물게 쓰는 관리 경로(`installValidations` 522 bytes, delegatecall whitelist setter 336, `replaceModule` 283)를 Kernel 바이트코드 밖으로 옮겨야 생깁니다. |
| 3 | DeployAll 후 계정 생성 불가 | 높음 | DeployAll 직후 `FactoryStaker.approved(factory)`가 false여서, initCode로 계정을 만들면 `NotApprovedFactory`로 revert했습니다. | 완료. DeployAll과 DeployKernel이 factory를 승인합니다. 브로드캐스트 계정이 owner가 아니면 owner가 할 호출을 로그로 남깁니다. |
| 4 | CI에 체인 위 E2E가 없음 | 높음 | 단위 테스트는 모두 통과했지만 실제 `handleOps` broadcast는 gas 설정 때문에 두 번 실패했습니다(`0xdeaddead`, `AA95 out of gas`). | 완료. 새 CI job `Anvil E2E`가 DeployAll과 `script/e2e/AnvilSmoke.s.sol`을 실행합니다. |
| 5 | 배포 대상이 모호함 | 중간 | 문서는 anvil(31337)을 안내하는데 `.env` 기본값은 chain 8283(`127.0.0.1:8501`)입니다. 문서의 DeployAll 경로도 틀려 있었습니다. | 완료. 경로를 고치고, anvil용 환경변수 덮어쓰기 방법과 8283 manifest가 CI fixture라는 점을 문서화했습니다. |
| 6 | 하드코딩된 slot 상수를 지키는 장치가 없음 | 중간 | 공식이 세 가지로 섞여 있습니다(`keccak`, `keccak - 1`, ERC-7201은 없음). literal 10개는 모두 맞았지만 이를 강제하는 장치가 없었습니다. | 완료. CI에서 `script/check-storage-slots.py`를 실행합니다. |
| 7 | solc 0.8.28 고정 | 낮음 | `layout at`(0.8.29)과 `erc7201()`(0.8.35)을 쓸 수 없었습니다. | 완료. 0.8.28을 쓰던 profile을 0.8.35로 올렸습니다. Kernel 크기는 그대로(24,229 bytes)이고 테스트는 모두 통과합니다. Universal Router(0.8.26)와 0.7.6 profile은 그대로입니다. |
| 8 | FlashLoanFallback의 연동 방식 변경 | 낮음 | 이제 executor로도 설치해야 하고 `beginFlashLoan`을 먼저 호출해야 합니다(PR #22). | 미해결. SDK와 프론트엔드 연동을 함께 고쳐야 합니다. |
| 9 | Kernel 테스트가 적음 | 낮음 | `FEATURES.md`에 이미 Kernel 테스트 37개로 적혀 있습니다. | 미해결. 실제 Kernel 위에서 도는 통합 테스트 형식을 늘려 갑니다. |

---

## 2. 모듈형 컨트랙트 플랫폼 관리

### 2.1 문제

저장소에는 Solidity 파일 147개에 걸쳐 컨트랙트 77개가 있습니다. 배포 스크립트가 18개, 보조 스크립트가 셸 27개와 TypeScript 27개입니다. 비용은 컨트랙트 수 자체가 아니라 서로를 키우는 세 가지에서 나옵니다.

1. **배포 상태를 사람이 추적합니다.** `addresses.json`에는 주소만 남습니다. DeployAll의 `[SKIP]` 판단은 주소가 있는지만 보고, 그 주소의 코드가 현재 소스와 같은지는 보지 않습니다.
2. **배포 후 연결 작업이 흩어져 있습니다.** factory 승인, stake, paymaster 설정, bridge 연결이 Solidity 스크립트와 TypeScript 스크립트에 나뉘어 있습니다. 위 개선 항목 3번이 그 결과입니다.
3. **권한이 컨트랙트마다 따로 있습니다.** owner와 role이 수십 개 컨트랙트에 흩어져 있습니다. 그래서 운영자를 교체하거나 키 사고에 대응하려면 수십 번의 트랜잭션이 필요합니다. 4장에서 보듯 업계 손실의 대부분이 바로 이 영역에서 나옵니다.

ERC-7579 모듈은 대부분 singleton이고, storage를 `msg.sender` 계정별로 나눠 둡니다. 모듈은 한 번만 배포하면 되고, 계정마다 드는 비용은 설치 UserOperation 하나뿐입니다. 어려운 부분은 모듈 수가 아니라 버전과 상태 관리입니다.

### 2.2 권장안 A: manifest 기반 배포 (plan/apply)

모듈마다 이름, 버전, 생성자 인자, 의존성, 배포 후 연결 작업을 manifest에 선언합니다. 배포 도구는 Terraform처럼 동작합니다.

- **plan**: 각 모듈의 CREATE2 예상 주소를 계산하고 체인 위 `extcodehash`와 비교합니다. 그 결과로 새로 배포할 것, 그대로 둘 것, 바뀐 것을 나눕니다.
- **apply**: 바뀐 것만 배포한 뒤 연결 작업을 수행합니다.
- **verify**: 실제 체인에 적용하기 전에 anvil fork에서 같은 apply와 smoke 테스트를 먼저 돌립니다.

저장소에 이미 CREATE2 deployer와 skip 로직이 있습니다. 새로 만들 부분은 codehash 비교와 의존성 그래프입니다.

단점:
- 생성자 인자에 다른 컨트랙트 주소가 들어가면, 하나가 바뀔 때 주소가 연쇄적으로 바뀝니다. 의존성 경계를 신중히 정해야 합니다.
- manifest가 유일한 기준이어야 합니다. manifest와 스크립트가 어긋나면 오히려 상황이 나빠집니다.

### 2.3 권장안 B: 제어 지점 통합 (ERC-7484 registry와 AccessManager)

- **모듈 registry(ERC-7484).** 검증 기관(attestor)이 모듈 주소를 보증하고, 계정은 보증된 모듈만 설치합니다. 결함이 발견되면 attestation을 취소해 그 모듈의 신규 설치를 막습니다. Rhinestone registry가 대표 구현입니다.
- **OpenZeppelin AccessManager.** 플랫폼 컨트랙트(bridge, DeFi, paymaster)가 권한 판단을 AccessManager 하나에 위임합니다. 역할 변경과 실행 지연을 한곳에서 관리할 수 있습니다.

단점:
- Kernel에는 registry 확인을 넣을 바이트코드 공간이 없습니다. 확인은 설치를 대행하는 executor나 hook에서 해야 합니다.
- registry 자체가 단일 실패 지점이자 공격 표적이 됩니다.
- 기존 컨트랙트를 AccessManager로 옮기려면 다시 배포해야 합니다.

### 2.4 추가 아이디어

| 아이디어 | 내용 | 단점 |
|---|---|---|
| 모듈 권한 선언(capability manifest) | 모듈이 필요한 selector, 호출 대상, 호출 유형을 선언합니다. 설치를 대행하는 executor가 이를 사용자에게 보여 주고, hook이 선언 범위 밖의 실행을 거부합니다. Android 권한 모델과 비슷합니다. | 선언과 실제 동작이 맞는지는 정적 분석이나 감사로 확인해야 합니다. hook 비용이 실행마다 듭니다. |
| 모듈 묶음(preset bundle) | 자주 함께 쓰는 모듈 묶음을 initConfig 하나로 제공합니다. 예를 들어 결제 계정이라면 ECDSA, SpendingLimit, Subscription executor입니다. | 묶음 사이의 버전 조합을 관리해야 합니다. |
| 설치 현황 색인(indexer) | `ModuleInstalled`와 `ModuleUninstalled` 이벤트를 모아, 어느 계정이 어떤 모듈의 어느 버전을 쓰는지 지도를 만듭니다. 결함이 발견되면 영향받는 계정을 찾아 알릴 수 있습니다. | 오프체인 인프라 비용이 들고, 계정 소유자에게 연락할 채널이 따로 필요합니다. |
| 교체하지 않는 모듈 + migration executor | 모듈을 그 자리에서 업그레이드하지 않습니다. 새 버전은 새 주소에 배포하고, 이전 모듈의 설정을 옮겨 주는 executor를 함께 제공합니다. upgrade 권한 자체가 사라집니다. | 사용자가 직접 옮겨야 해서 옛 버전이 오래 남습니다. |
| 위험도별 배포 경로 | 자산을 움직이는 executor와 fallback은 감사, timelock, 단계적 출시를 거칩니다. 위험이 낮은 hook은 빠른 경로로 배포합니다. | 분류를 계속 관리해야 합니다. 분류를 잘못하면 빠른 경로가 우회로가 됩니다. |

---

## 3. Namespaced Storage 지원 현황

### 3.1 이미 있는 것

| 도구 | 하는 일 | 한계 |
|---|---|---|
| Solidity 0.8.29 `layout at <slot>` | 컨트랙트 state 변수의 시작 slot을 지정합니다. | 변수 묶음 단위가 아니라 컨트랙트 단위로만 지정합니다. 상속 관련 제약은 이번 검토에서 확인하지 않았습니다. |
| Solidity 0.8.35 `erc7201("id")` | ERC-7201 공식 `keccak256(keccak256(id) - 1) & ~0xff`를 컴파일 시점에 계산하는 builtin입니다. `layout at erc7201("...")`처럼 쓸 수 있고, 언어 최초의 comptime builtin입니다. | 0.8.35 이상이 필요하며, 이 저장소는 이제 0.8.35를 씁니다. |
| OpenZeppelin `SlotDerivation` / `StorageSlot` | ERC-7201 slot 계산, mapping과 배열의 slot 유도, 타입이 붙은 slot 접근을 제공합니다. | 런타임에 계산하므로, 미리 계산해 둔 상수보다 gas가 조금 더 들 수 있습니다. |
| OpenZeppelin contracts-upgradeable v5 | 모든 컨트랙트가 ERC-7201 struct 패턴과 `@custom:storage-location`을 씁니다. 그래서 storage gap이 필요 없습니다. | — |
| OpenZeppelin Upgrades (`validate`, Foundry `validateUpgrade`) | build info로 구현 컨트랙트 사이의 layout 호환성을 검사하고, namespaced storage도 다룹니다. | namespace를 `@custom:storage-location` 주석으로만 인식합니다. 이 저장소처럼 hex 상수와 assembly로 접근하는 slot은 검사하지 못합니다. |
| ERC-8042 (Diamond Storage) | 기존 diamond storage 관행 `keccak256("id")`를 표준으로 정리했습니다. | ERC-7201과 공식이 다릅니다. 두 방식을 섞으면 규칙이 둘이 됩니다. |
| `forge inspect <C> storageLayout`, slither-check-upgradeability | 일반 layout을 출력하거나 비교합니다. | assembly로 지정한 slot은 보지 못합니다. |

### 3.2 빈 부분과 대응

이 저장소는 slot 상수를 hex literal로 적고 assembly로 읽습니다. 그래서 대부분의 layout 도구가 이 slot들을 보지 못합니다. 빠진 것은 프로젝트 전체의 일관성 검사 하나이고, 이를 위해 새 라이브러리를 만들 필요는 없습니다.

1. **지금 (PR #25에서 완료).** `script/check-storage-slots.py`가 `*_SLOT`, `*_SEED`, `*_LOCATION` 상수를 모두 모아 바로 위의 공식 주석을 읽습니다. 값을 다시 계산해, 값이 다르거나 선언이 없거나 slot이나 namespace가 겹치면 실패합니다. 약점은 주석 형식에 의존한다는 점이라, 형식 자체를 지켜야 합니다.
2. **새 코드 (컴파일러는 이제 0.8.35).** 새 모듈은 `erc7201()`과 `@custom:storage-location`을 써서 OpenZeppelin `validate`의 검사를 받게 합니다. Kernel은 기존 `keccak`, `keccak - 1` slot을 그대로 둡니다. slot을 옮기면 이미 배포된 계정의 상태 위치가 바뀌기 때문입니다.

---

## 4. EVM 컨트랙트 보안 동향 (2025~2026)

| # | 동향 | 근거 | 이 저장소와의 관련 |
|---|---|---|---|
| 1 | 손실의 중심이 코드 결함에서 권한·운영으로 이동 | 2026년 상반기 해킹 207건, 손실 9.72억 달러입니다. 인프라·운영 침해는 사건 수의 약 15%지만 손실의 약 76%를 차지했습니다(TRM Labs). | 이 저장소도 owner와 role이 흩어져 있습니다. 권한 통합과 timelock(2.3)이 대응책입니다. |
| 2 | 검증자·서명자 구성의 단일 실패 지점 | KelpDAO(2026년 4월, 약 2.9억 달러)는 LayerZero DVN을 1-of-1로 구성했고, 공격자가 DVN이 신뢰하는 RPC 인프라를 장악했습니다. Drift(Solana, 약 2.85억 달러)는 timelock 없는 2-of-5 multisig가 사전 서명 트랜잭션으로 악용됐습니다. 두 사건 모두 Lazarus 소행으로 추정됩니다. | bridge의 signer·guardian 임계값과 관리 작업 timelock을 점검합니다. |
| 3 | OWASP Smart Contract Top 10 2026 | SC01 Access Control, SC02 Business Logic, SC03 Oracle Manipulation, SC04 Flash Loan, SC05 Input Validation, SC06 Unchecked External Calls, SC07 Rounding·Precision, SC08 Reentrancy(2위에서 하락), SC09 Overflow, SC10 Proxy·Upgradeability(신규)입니다. 2025년 사건 122건, 약 9.05억 달러를 바탕으로 했습니다. | 이 저장소의 보안 리뷰에서 나온 권한 빈틈, 회계 불일치와 같은 흐름입니다. |
| 4 | 반올림·정밀도 공격 | Balancer v2(2025년 11월, 약 1.28억 달러)는 upscale과 downscale의 반올림 방향 불일치를 batchSwap으로 증폭당했습니다. | DeFi의 share와 이자 계산에 반올림 방향 불변식 테스트를 추가합니다. |
| 5 | EIP-7702 위임 피싱 | EIP-7702 위임의 80~97%가 sweeper bytecode를 가리킨다는 분석이 있습니다. 서명 한 번으로 계정 전체의 실행 권한이 넘어갑니다. | 이 저장소는 EIP-7702를 지원합니다(`Eip7702Support`). 지갑이 위임 대상을 검증하고 경고해야 합니다. |
| 6 | 프론트엔드·공급망 공격 | Polymarket 프론트엔드 침해(2026년 6월, 약 300만 달러). Bybit(2025년, 15억 달러)는 변조된 Safe UI가 delegatecall 서명을 유도했습니다. | 관리 트랜잭션의 calldata를 UI와 독립적으로 디코딩해 검증합니다. |
| 7 | AI가 공격과 감사를 모두 자동화 | Anthropic 연구에서 에이전트가 과거 컨트랙트 405개 중 207개를 시뮬레이션으로 공격했고, 미공개 취약점 2건을 찾았습니다. 1회 스캔 비용은 약 1.22달러입니다. 전용 AI 감사 에이전트가 실제 공격당한 DeFi 컨트랙트 취약점의 92%를 탐지했다는 보고도 있습니다. | 결함이 생긴 뒤 공격까지의 시간이 짧아집니다. CI에 자동 감사를 넣고, 이미 배포된 컨트랙트도 다시 점검합니다. |
| 8 | 프로토콜 변경에 따른 가정 붕괴 | Fusaka(2025년 12월 3일)의 EIP-7825가 트랜잭션 gas 상한을 2^24로 정했습니다. 큰 batch나 배포 트랜잭션은 나눠야 합니다. | 배포 과정의 큰 단일 트랜잭션과 PolicyHook의 큰 batch를 점검합니다. |
| 9 | ERC-7579 표준화 | Kernel v3, Biconomy Nexus, Safe의 7579 adapter가 ERC-7579를 채택했습니다. ERC-7484 registry가 모듈 설치를 통제합니다. | 권장안 B의 근거입니다. |

---

## 5. 출처

- [OWASP Smart Contract Top 10: 2026](https://scs.owasp.org/sctop10)
- [TRM Labs: H1 2026 crypto hacks](https://www.trmlabs.com/resources/blog/h1-2026-crypto-hacks-reach-record-high-as-losses-fall-below-usd-1-billion)
- [Nexus Mutual: KelpDAO and LayerZero incident report](https://nexusmutual.io/blog/kelpdao-layerzero-incident-report)
- [BlockSec newsletter, April 2026](https://blocksec.com/blog/newsletter-april-2026)
- [Trail of Bits: Balancer hack analysis](https://blog.trailofbits.com/2025/11/07/balancer-hack-analysis-and-guidance-for-the-defi-ecosystem/)
- [arXiv 2512.12174: EIP-7702 phishing](https://arxiv.org/abs/2512.12174v1)
- [The Block: Wintermute on EIP-7702 sweepers](https://www.theblock.co/post/356481/wintermute-warns-pectra-upgrade-leaves-ethereum-users-at-risk-of-automated-attacks)
- [The Block: Anthropic on AI agents and smart contracts](https://www.theblock.co/post/381035/ai-agent-smart-contract-anthropic)
- [Security Boulevard: purpose-built AI audit agent](https://securityboulevard.com/2026/03/purpose-built-ai-security-agent-detected-92-of-defi-contracts-vulnerabilities/)
- [Solidity 0.8.35 release announcement](https://www.soliditylang.org/blog/2026/04/29/solidity-0.8.35-release-announcement)
- [ERC-7201: Namespaced Storage Layout](https://eips.ethereum.org/EIPS/eip-7201)
- [ERC-8042: Diamond Storage](https://ercs.ethereum.org/ERCS/erc-8042)
- [OpenZeppelin Upgrades Core and CLI](https://docs.openzeppelin.com/upgrades-plugins/api-core)
- [ERC-7484: Registry Extension for ERC-7579](https://eips.ethereum.org/EIPS/eip-7484)
- [Sigma Prime: Fusaka contract security](https://sigmaprime.io/blog/fusaka-contract-security/)
- [Tatum: Ethereum's Fusaka](https://tatum.io/blog/ethereums-fusaka)
