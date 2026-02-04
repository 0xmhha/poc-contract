# EntryPoint Deposit & Stake 가이드

> ERC-4337 EntryPoint의 Deposit과 Stake 시스템에 대한 상세 설명

## 개요

EntryPoint 컨트랙트는 두 가지 자금 관리 메커니즘을 제공합니다:

| 구분 | 목적 | 잠금 여부 |
|------|------|----------|
| **Deposit** | UserOperation 가스비 지불 | 즉시 출금 가능 |
| **Stake** | 평판(Reputation) 시스템용 담보 | 일정 기간 잠금 |

```
┌─────────────────────────────────────────────────────────────┐
│                      EntryPoint                             │
├─────────────────────────────────────────────────────────────┤
│  deposits[address] = DepositInfo {                          │
│    deposit: uint256      // 가스비 지불용 잔액              │
│    staked: bool          // 스테이킹 여부                   │
│    stake: uint112        // 스테이킹 금액                   │
│    unstakeDelaySec: uint32  // 언스테이크 대기 시간         │
│    withdrawTime: uint48  // 출금 가능 시간                  │
│  }                                                          │
└─────────────────────────────────────────────────────────────┘
```

---

## 역할별 요구사항

### 1. Account (Smart Contract Wallet)

스마트 컨트랙트 지갑은 UserOperation의 가스비를 지불해야 합니다.

| 항목 | 필요 여부 | 설명 |
|------|----------|------|
| Deposit | ✅ 필수 | Paymaster 없이 직접 가스비 지불 시 |
| Stake | ❌ 불필요 | - |

**Deposit 방법:**
```solidity
// 방법 1: depositTo 호출
entryPoint.depositTo{value: 1 ether}(accountAddress);

// 방법 2: Account가 직접 ETH 전송
(bool success,) = entryPoint.call{value: 1 ether}("");
```

**가스비 차감 로직 (EntryPoint.sol:542-550):**
```solidity
if (paymaster == address(0)) {
    uint256 bal = balanceOf(sender);
    missingAccountFunds = bal > requiredPrefund ? 0 : requiredPrefund - bal;
}
// ...
if (paymaster == address(0)) {
    if (!_tryDecrementDeposit(sender, requiredPrefund)) {
        revert FailedOp(opIndex, "AA21 didn't pay prefund");
    }
}
```

---

### 2. Paymaster

Paymaster는 다른 계정의 가스비를 대신 지불합니다.

| 항목 | 필요 여부 | 설명 |
|------|----------|------|
| Deposit | ✅ 필수 | 대납할 가스비 예치 |
| Stake | ✅ 권장 | 평판 시스템, DoS 방지 |

**Deposit 검증 (EntryPoint.sol:617-619):**
```solidity
uint256 requiredPreFund = opInfo.prefund;
if (!_tryDecrementDeposit(paymaster, requiredPreFund)) {
    revert FailedOp(opIndex, "AA31 paymaster deposit too low");
}
```

**Stake 목적:**
- 번들러가 악의적인 Paymaster를 필터링
- 오프체인 평판 시스템에서 신뢰도 지표로 사용
- `simulateValidation()`에서 StakeInfo 반환

**권장 설정:**
```bash
# Deposit: 예상 가스비 * 처리할 UserOp 수
./script/stake-entrypoint.sh --deposit=10

# Stake: 최소 unstakeDelay 1일(86400초) 이상
./script/stake-entrypoint.sh --stake=1 --unstake-delay=86400
```

---

### 3. Factory

Factory는 새로운 Account를 생성하는 컨트랙트입니다.

| 항목 | 필요 여부 | 설명 |
|------|----------|------|
| Deposit | ❌ 불필요 | - |
| Stake | ✅ 권장 | 평판 시스템, DoS 방지 |

**Stake 검증 (simulateValidation):**
```solidity
IStakeManager.StakeInfo memory factoryInfo = _getFactoryStakeInfo(userOp.initCode);
```

번들러는 Factory의 stake 정보를 확인하여 악의적인 Factory를 필터링할 수 있습니다.

---

### 4. Aggregator

Aggregator는 여러 UserOperation의 서명을 집계합니다.

| 항목 | 필요 여부 | 설명 |
|------|----------|------|
| Deposit | ❌ 불필요 | - |
| Stake | ✅ 권장 | 평판 시스템 |

**Stake 검증 (simulateValidation):**
```solidity
if (accountData.aggregator != address(0) && accountData.aggregator != address(1)) {
    aggregatorInfo = IEntryPointSimulations.AggregatorStakeInfo({
        aggregator: accountData.aggregator,
        stakeInfo: _getStakeInfo(accountData.aggregator)
    });
}
```

---

### 5. Bundler

Bundler는 UserOperation을 수집하여 `handleOps()`를 호출합니다.

| 항목 | 필요 여부 | 설명 |
|------|----------|------|
| Deposit | ❌ 불필요 | EntryPoint에 예치 불필요 |
| Stake | ❌ 불필요 | EntryPoint에서 검증하지 않음 |
| Native Balance | ✅ 필수 | 트랜잭션 가스비 선불용 |

**Bundler 제약조건 (EntryPoint.sol:80-85):**
```solidity
function _nonReentrant() internal view {
    require(
        tx.origin == msg.sender && msg.sender.code.length == 0,
        Reentrancy()
    );
}
```
→ **Bundler는 반드시 EOA**여야 합니다.

**가스비 흐름:**
```
1. Bundler가 handleOps() 호출 → 네이티브 토큰으로 가스비 선불
2. EntryPoint가 Account/Paymaster deposit에서 가스비 차감
3. 실행 완료 후 _compensate()로 beneficiary에게 환불
```

---

## Deposit vs Stake 비교

| 특성 | Deposit | Stake |
|------|---------|-------|
| **목적** | 가스비 지불 | 평판/담보 |
| **잠금** | 없음 (즉시 출금) | unstakeDelay 이후 출금 |
| **사용 주체** | Account, Paymaster | Paymaster, Factory, Aggregator |
| **온체인 검증** | ✅ handleOps에서 검증 | ❌ simulateValidation에서 조회만 |
| **차감** | UserOp 실행 시 자동 차감 | 차감되지 않음 |

---

## 가스비 흐름 다이어그램

```
┌──────────────┐     1. handleOps()      ┌──────────────┐
│   Bundler    │ ─────────────────────▶  │  EntryPoint  │
│    (EOA)     │   (가스비 선불)          │              │
└──────────────┘                         └──────┬───────┘
                                                │
                    ┌───────────────────────────┼───────────────────────────┐
                    │                           │                           │
                    ▼                           ▼                           ▼
           ┌───────────────┐          ┌───────────────┐          ┌───────────────┐
           │    Account    │          │   Paymaster   │          │   Paymaster   │
           │   (No PM)     │          │  (Sponsored)  │          │   (postOp)    │
           └───────┬───────┘          └───────┬───────┘          └───────┬───────┘
                   │                          │                          │
         Account.deposit에서          Paymaster.deposit에서       Paymaster.deposit에서
            가스비 차감                   가스비 차감                 가스비 차감
                   │                          │                          │
                   └──────────────────────────┼──────────────────────────┘
                                              │
                                              ▼
                                    ┌───────────────┐
                                    │  _compensate  │
                                    │  (beneficiary)│
                                    └───────────────┘
                                              │
                                              ▼
                                    ┌───────────────┐
                                    │   Bundler     │
                                    │  (가스 환불)  │
                                    └───────────────┘
```

---

## 스테이킹 관련 함수

### depositTo(address account)
계정에 deposit 추가
```solidity
entryPoint.depositTo{value: amount}(account);
```

### addStake(uint32 unstakeDelaySec)
msg.sender에 stake 추가 (잠금)
```solidity
entryPoint.addStake{value: amount}(unstakeDelaySec);
```

### unlockStake()
stake 잠금 해제 시작
```solidity
entryPoint.unlockStake();
// unstakeDelaySec 이후 withdrawStake 가능
```

### withdrawStake(address payable withdrawAddress)
잠금 해제된 stake 출금
```solidity
entryPoint.withdrawStake(withdrawAddress);
```

### withdrawTo(address payable withdrawAddress, uint256 withdrawAmount)
deposit 출금 (즉시 가능)
```solidity
entryPoint.withdrawTo(withdrawAddress, amount);
```

---

## 실용 가이드

### Paymaster 운영자
```bash
# 1. Deposit 충전 (가스 대납용)
./script/stake-entrypoint.sh --deposit=100

# 2. Stake 설정 (평판용, 최소 1일 잠금)
./script/stake-entrypoint.sh --stake=10 --unstake-delay=86400

# 3. 상태 확인
./script/stake-entrypoint.sh --info
```

### Bundler 운영자
```bash
# EntryPoint 스테이킹 불필요
# 단, 네이티브 토큰 잔액 충분히 유지

# Bundler 주소에 충분한 ETH/KRC 확보
cast balance $BUNDLER_ADDRESS --rpc-url $RPC_URL
```

### Factory 운영자

FactoryStaker를 통해 EntryPoint에 스테이킹:

```bash
# 상태 확인
./script/stake-factory.sh --info

# Stake 설정 (평판용)
./script/stake-factory.sh --stake=1 --unstake-delay=86400

# KernelFactory 승인
./script/stake-factory.sh --approve

# 한번에 Stake + Approve
./script/stake-factory.sh --stake=1 --approve
```

또는 직접 cast 명령:
```bash
# Stake만 필요 (Deposit 불필요)
cast send $FACTORY_STAKER "stake(address,uint32)" $ENTRYPOINT 86400 \
  --value 1ether \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --rpc-url $RPC_URL

# KernelFactory 승인
cast send $FACTORY_STAKER "approveFactory(address,bool)" $KERNEL_FACTORY true \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --rpc-url $RPC_URL
```

---

## 참고 사항

1. **오프체인 요구사항**: 일부 번들러 네트워크는 자체 스테이킹/평판 시스템 운영
2. **최소 unstakeDelay**: 네트워크마다 다를 수 있음 (일반적으로 1일 이상)
3. **Deposit 잔액 모니터링**: Paymaster는 deposit 잔액 부족 시 UserOp 거부됨
4. **Stake 금액**: 높을수록 번들러로부터 우선 처리될 가능성 증가

---

## 관련 코드 참조

### 컨트랙트
- `src/erc4337-entrypoint/EntryPoint.sol` - 메인 EntryPoint 컨트랙트
- `src/erc4337-entrypoint/StakeManager.sol` - Deposit/Stake 관리
- `src/erc4337-entrypoint/interfaces/IStakeManager.sol` - 인터페이스 정의
- `src/erc7579-smartaccount/factory/FactoryStaker.sol` - Factory 스테이킹 관리

### 스크립트
- `script/ts/stake-entrypoint.ts` - Bundler/Paymaster용 Deposit/Stake
- `script/ts/stake-factory.ts` - FactoryStaker용 Stake + Factory 승인
