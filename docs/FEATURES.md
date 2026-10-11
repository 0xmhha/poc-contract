# Supported Features

This document lists the features provided by the 18 modules under `src/`, grouped by module. For contract dependencies and call flows, see [Architecture](./ARCHITECTURE.md).

> This document is derived from each contract's NatSpec (`@title`/`@notice`/`@dev`) and its external/public function signatures. It does not verify function internals or test results.

## Table of Contents

1. [Overview](#1-overview)
2. [Account Abstraction Core](#2-account-abstraction-core)
3. [ERC-7579 Modules](#3-erc-7579-modules)
4. [Paymasters](#4-paymasters)
5. [DeFi and Tokens](#5-defi-and-tokens)
6. [Perpetual Futures](#6-perpetual-futures)
7. [Bridge](#7-bridge)
8. [Privacy](#8-privacy)
9. [Compliance and Subscriptions](#9-compliance-and-subscriptions)
10. [Deployment and Tooling](#10-deployment-and-tooling)
11. [Known Limitations](#11-known-limitations)
12. [Test Coverage](#12-test-coverage)

---

## 1. Overview

The StableNet PoC contracts fall into seven areas.

| Area | Modules |
|---|---|
| Account Abstraction | `erc4337-entrypoint`, `erc7579-smartaccount`, `erc7579-validators`, `erc7579-executors`, `erc7579-hooks`, `erc7579-fallbacks`, `erc7579-plugins`, `permit2` |
| Gas sponsorship | `erc4337-paymaster` |
| DeFi | `defi`, `tokens` |
| Derivatives | `perpetual` (testnet only) |
| Cross-chain | `bridge` |
| Privacy | `privacy` |
| Regulation and payments | `compliance`, `subscription` |

`common/libraries/Constants.sol` is a library of global constants shared by the Enterprise Stealth and Perpetual systems.

---

## 2. Account Abstraction Core

| Module | Contracts | Features |
|---|---|---|
| `erc4337-entrypoint` | EntryPoint, NonceManager, StakeManager, SenderCreator, EntryPointSimulations | ERC-4337 EntryPoint v0.9 (based on eth-infinitism). UserOperation validation and execution, nonce management, stake and deposit management, simulation. EIP-7702 delegate account initialization (`Eip7702Support`) |
| | Create2Deployer | Deterministic deployment via CREATE2 (`deploy`, `computeAddress`) |
| `erc7579-smartaccount` | Kernel | ERC-7579 modular smart account (based on ZeroDev Kernel). Root validator change, install and replace validators, executors, hooks and fallbacks (`installValidations`, `replaceModule`), ERC-1271 signature validation, ERC-721/1155 receiving, upgrades (`upgradeTo`), delegatecall whitelist, hook gas limit. The outer executor context is preserved across nested executor calls |
| | KernelFactory, FactoryStaker | Account creation and counterfactual address computation, factory stake management on the EntryPoint |
| `permit2` | Permit2 (AllowanceTransfer, SignatureTransfer) | Port of Uniswap Permit2. Signature-based approvals and transfers |

**Delegated `execute` access.** A non-root validator granted the `execute` selector (`grantAccess`, or `selectorData` at install) can also reach the account's admin functions: `execute` may target the account itself, and Kernel accepts self-calls in `onlyEntryPointOrSelfOrRoot`, so `execute(self, changeRootValidator(...))` or `execute(self, installModule(...))` succeeds. Granting `execute` therefore grants full control of the account, including replacing the root validator. Kernel does not block this. To delegate limited access, give that validator an execution hook that rejects self-targeted executions (PolicyHook, SpendingLimitHook, AuditHook and HealthFactorHook do, through `HookExecutionDataLib.checkExecutionTarget`), or a permission policy that restricts call targets.

---

## 3. ERC-7579 Modules

### Validators (`erc7579-validators`)

| Contract | Features |
|---|---|
| ECDSAValidator | Single EOA owner signature validation |
| MultiSigValidator | M-of-N multisig. Add, remove and replace signers, change threshold |
| WeightedECDSAValidator | Weighted guardian approval. `approve`, `approveWithSig`, `veto` |
| WebAuthnValidator (+ `P256` library) | Passkey and biometric authentication (secp256r1). Register and revoke credentials |
| MultiChainValidator | Approve UserOperations on multiple chains with one signature via Merkle proof |

### Executors (`erc7579-executors`)

| Contract | Features |
|---|---|
| SessionKeyExecutor | Delegated execution via session keys. Target and selector permissions, spending limits, expiry |
| RecurringPaymentExecutor | Create, pause, resume and cancel recurring payment schedules; update amount and recipient |
| SwapExecutor | Uniswap V3 single-hop (`swapExactInputSingle`) and multi-hop (`swapExactInput`) swaps. Token whitelist, daily and per-swap limits, slippage protection |
| LendingExecutor | LendingPool supply, withdraw, borrow, repay. Asset allowlist, minimum health factor, borrow limit |
| StakingExecutor | Stake, locked stake, unstake, claim, compound. Pool allowlist, per-pool limit, daily limit |

### Hooks (`erc7579-hooks`)

| Contract | Features |
|---|---|
| SpendingLimitHook | Per-token, per-period spending limits by comparing balances before and after execution. Rejects nonzero allowance grants (approve, increaseAllowance, permit) on limited tokens, so approve-then-act executors such as SwapExecutor and LendingExecutor cannot run under it for those tokens. Allowance grants through Permit2, non-standard permits or off-chain ERC-1271 signatures are not detected |
| PolicyHook | Allowlist and blocklist modes, target and selector restrictions, per-target value limits, transaction count limits per period, emergency pause |
| AuditHook | Transaction audit log, blocklist, queueing of flagged transactions |
| HealthFactorHook | Reverts when a call to a lending target drops the health factor below the threshold |

`HookExecutionDataLib` is a shared library that decodes the executions (single, batch or delegatecall) behind the calldata Kernel passes to hooks. PolicyHook, SpendingLimitHook, AuditHook and HealthFactorHook use it.

### Fallbacks (`erc7579-fallbacks`)

| Contract | Features |
|---|---|
| FlashLoanFallback | Flash loan callbacks for AAVE v3 (`executeOperation`), Uniswap v3 (`uniswapV3FlashCallback`), Balancer (`receiveFlashLoan`), ERC-3156 (`onFlashLoan`). Install as both fallback and executor: strategy calls and repayment run as the account. The account calls `beginFlashLoan(lender)` in the same transaction before each loan; callbacks without it revert. Protocol whitelist, logging |
| TokenReceiverFallback | Receiver callbacks for token standards Kernel does not support natively, such as ERC-777. Whitelist and blacklist |

### Plugins (`erc7579-plugins`, executor type)

| Contract | Features |
|---|---|
| AutoSwapPlugin | DCA, limit buy and sell, stop-loss, take-profit and trailing stop orders. Execution on trigger, batch execution |
| MicroLoanPlugin | Collateralized micro-loans. Liquidity deposit and withdrawal, repayment, liquidation, credit score |
| OnRampPlugin | Fiat on-ramp. Provider registration and signature verification, user KYC and blacklist, order claim, cancel and refund, daily limit |

---

## 4. Paymasters

The `erc4337-paymaster` module provides four gas payment methods.

| Contract | Gas payment method |
|---|---|
| VerifyingPaymaster | Sponsors gas based on an off-chain signer's signature |
| SponsorPaymaster | Sponsors gas based on an off-chain policy engine decision (Visa 4-Party model) |
| ERC20Paymaster | Pays gas in pre-approved ERC-20 tokens (e.g. USDC) using an oracle price plus markup. Pre-charges the max token cost during validation and refunds the unused part in `postOp`. 20% price deviation circuit breaker once a reference price is set (`updateReferencePrice`) |
| Permit2Paymaster | Pays gas in ERC-20 tokens via a Permit2 signature, without a separate approve. Same pre-charge and refund flow and price circuit breaker as ERC20Paymaster; a future oracle timestamp is treated as stale |

Shared components:

- `BasePaymaster`: EntryPoint reference, deposit and stake management, validation data helpers
- `PaymasterDataLib` / `PaymasterPayload`: Common `paymasterAndData` envelope encoding and decoding for all four paymasters

For public mempool compatibility, see [11. Known Limitations](#11-known-limitations).

---

## 5. DeFi and Tokens

| Module | Contract | Features |
|---|---|---|
| `defi` | LendingPool | Multi-asset deposits and borrows, utilization-based variable rates, liquidation bonus, flash loans |
| | StakingVault | Configurable reward rate, lock periods, early withdrawal penalty, compounding, emergency withdrawal |
| | PriceOracle | Combines Chainlink feeds and Uniswap V3 TWAP, staleness checks, amount conversion |
| | FixedPriceAggregator | Fixed-price feed compatible with Chainlink `AggregatorV3Interface` |
| `src/MockChainlinkFeed.sol` | MockChainlinkFeed | Chainlink feed for local testing |
| `tokens` | USDC | 6-decimal stablecoin. Minter role, blacklist, pause, mint and burn |
| `script/uniswap` | UniswapV3Factory, SwapRouter, Quoter, NonfungiblePositionManager | Contracts used by scripts to deploy a DEX on a local chain |

---

## 6. Perpetual Futures

The `perpetual` module is an order-book perpetual futures system. It is a testnet reference implementation imported from the archived `stable-poc-contract` repository; it is not audited and not for production (`src/perpetual/README.md`). Behavioral limitations are listed in [11. Known Limitations](#11-known-limitations).

| Contract | Features |
|---|---|
| PerpetualEngine | User entry point. Market creation, status and config updates, margin deposit and withdrawal, market-order positions, limit orders, position reduction and close, order cancellation (including cancel-all), leverage and margin mode settings, emergency and trading pause |
| OrderManager | Order create, cancel, modify and expire; fills (`fillOrder`), matching (`matchOrders`), conditional order triggers (`checkAndTrigger`). Order types: Market, Limit, Stop, StopLimit, TakeProfit, TakeProfitLimit. Time-in-force: GTC, IOC, FOK, PostOnly |
| PositionManager | Open, increase, decrease and close positions; add and remove margin; unrealized PnL, margin ratio, liquidation price, open interest |
| MarginManager | Isolated and cross margin modes, margin lock and unlock, required margin calculation, realized and unrealized PnL accounting |
| FundingRateManager | Funding rate calculation (including TWAP), cumulative funding index, periodic settlement, funding history snapshots |
| Liquidator | Full, partial and batch liquidation, liquidation fees and liquidator rewards |
| InsuranceFund | Per-market fund allocation and reclaim, loss coverage (`coverLoss`), ADL trigger threshold |
| ADLEngine | Auto-deleveraging (ADL) priority queue; single, batch and automatic ADL execution |
| `PerpetualMath` | Fixed-point math, PnL, margin ratio, liquidation price, funding rate, ADL priority, fees, leverage |

The indexer-go `perp_orderbook` venue decodes events from `PerpetualEngine` and `OrderManager`, and the `getOrder` return layout, by hard-coded signature. Changing these signatures breaks the indexer. Update both repositories together and regenerate `abi/perpetual` with `./script/export-venue-abi.sh`; CI checks that `abi/perpetual` is current.

---

## 7. Bridge

The `bridge` module is a defense-in-depth design that layers MPC signatures and optimistic verification. SecureBridge composes the other contracts.

| Contract | Features |
|---|---|
| SecureBridge | Deposit, `completeBridge`, refund, supported chains and token mapping, fees, TVL query |
| BridgeValidator | 5-of-7 MPC signature verification, signer set rotation (`rotateSignerSet`), nonce management. Only the bridge set via `setAuthorizedBridge` may consume nonces |
| OptimisticVerifier | Optimistic verification with a challenge period, challenge bond and reward |
| FraudProofVerifier | Fraud proof verification using Merkle and state proofs, state root updates |
| BridgeRateLimiter | Per-transaction, hourly and daily USD limits; auto-pause when usage crosses the threshold (the crossing transaction goes through; later ones are blocked). Volume is attributed to the actual sender, not to SecureBridge |
| BridgeGuardian | 3-of-5 guardian multisig for proposal execution (including unpause) and blacklist. Any single guardian can emergency-pause at any time, with no cooldown |

---

## 8. Privacy

| Contract | Features |
|---|---|
| ERC5564Announcer | ERC-5564 stealth address announcements (single, batch, announce-and-transfer), view tag generation |
| ERC6538Registry | ERC-6538 stealth meta-address registry. Registration on behalf of others via EIP-712 or ERC-1271 signatures |
| PrivateBank | Native and ERC-20 deposits and withdrawals via stealth addresses, per-deposit and daily limits |
| `enterprise/StealthVault` | Enterprise custody of stealth deposits, emergency withdrawal |
| `enterprise/StealthLedger` | Balance and transaction history ledger per stealth address |
| `enterprise/WithdrawalManager` | Withdrawal requests, approvals and execution with an approval threshold (default plus optional per-token override in raw token units) and cooldown. Only `REQUESTER_ROLE` holders may request withdrawals |
| `enterprise/RoleManager` | RBAC with expiring role assignments |

---

## 9. Compliance and Subscriptions

### Compliance (`compliance`)

| Contract | Features |
|---|---|
| KYCRegistry | KYC status (NONE, PENDING, VERIFIED, REJECTED, EXPIRED), risk level (LOW, MEDIUM, HIGH, PROHIBITED), OFAC/UN/EU sanctions lists, allow and block lists, `canTransact` |
| RegulatoryRegistry | Regulator registration and access levels, trace requests executed after 2-of-3 approval |
| AuditLogger | Immutable audit log. Queries by actor, target, type and time range; retention period |
| ProofOfReserve | 100% reserve verification via Chainlink PoR, auto-pause on shortfall, mint permission check (`checkMintAllowed`) |

### Subscriptions (`subscription`)

| Contract | Features |
|---|---|
| SubscriptionManager | Merchant plan creation and updates, subscribe and cancel, payment processing (including batch), protocol fee |
| MerchantRegistry | Merchant registration, verification and suspension, per-merchant fee, verifier management |
| ERC7715PermissionManager | ERC-7715 permission grant (including signature-based), adjust, use and revoke; permission type registry. Signed grants cover the rule list and `isAdjustmentAllowed`, `usePermission` is blocked while paused, and `hashPermissionGrant` computes the digest to sign |

---

## 10. Deployment and Tooling

| Path | Contents |
|---|---|
| `script/deploy-all.sh` | Deploys 50+ contracts in 19 dependency-ordered steps. Supports `--dry-run`, `--from=<step>`, `--verify` |
| `script/deploy-contract/Deploy*.s.sol` | Per-module Foundry deployment scripts, oracle price setup (`SetupOraclePrice.s.sol`) |
| `script/utils/BridgeWiring.sol` | Cross-contract authorizations a bridge deployment needs before it can move funds. Idempotent: writes a setting only when it differs |
| `script/deploy-contract/DeployPerpetual.s.sol` | Deploys only PerpetualEngine, OrderManager, PositionManager and MarginManager. Not part of `DeployAll` |
| `script/export-venue-abi.sh` | Exports the `abi/perpetual` ABIs used by the indexer |
| `security/` | Slither, Mythril and Echidna configuration and audit script (`run-audit.sh`) |

For deployment details, see [Deployment](./DEPLOYMENT.md).

---

## 11. Known Limitations

### Paymasters require a private bundler

All four paymasters perform operations during the validation phase (`_validatePaymasterUserOp`) that violate ERC-4337 simulation rules. Public mempool bundlers such as Pimlico and Alchemy therefore reject UserOperations that use these paymasters. Source: the header comment in `src/erc4337-paymaster/BasePaymaster.sol`.

| Paymaster | Violation |
|---|---|
| VerifyingPaymaster | `senderNonce[sender]++` (internal storage write) |
| SponsorPaymaster | `senderNonce[sender]++` (internal storage write) |
| Permit2Paymaster | `PERMIT2.permit()` and `PERMIT2.transferFrom()` pre-charge (external contract state writes, most severe) |
| ERC20Paymaster | `safeTransferFrom()` pre-charge (external token storage write) |

The token paymasters pre-charge in validation on purpose. If `postOp` reverts, the EntryPoint still charges the paymaster's deposit, so collecting tokens only in `postOp` would let users get gas for free. The token transfer must therefore stay in validation.

The same comment lists three changes needed for public mempool support: move `senderNonce++` to `_postOp` or replace it with the EntryPoint nonce; require Permit2 pre-approval instead of calling `PERMIT2.permit()` in validation; and operate ERC20Paymaster and Permit2Paymaster as staked paymasters.

### Perpetual is a testnet reference implementation

From `src/perpetual/README.md`:

- Prices are hard-coded placeholders (`PerpetualEngine._getMarketPrice`, `OrderManager.executeMarketOrder`). Trades do not use real oracle prices.
- `Liquidator.liquidate` and most of `ADLEngine` are placeholders. The liquidation and ADL features in section 6 exist at the interface level; their behavior is not complete.
- The deployment script deploys only four contracts. FundingRateManager, Liquidator, InsuranceFund and ADLEngine are not deployed.

---

## 12. Test Coverage

Approximate counts of `test*`, `testFuzz*` and `invariant*` functions per `test/` directory, obtained by regex.

| Directory | Test functions |
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

EntryPoint (16), Permit2 (12) and Kernel (37) are core infrastructure that every other module depends on, yet they have far fewer tests than other modules. These modules are ports of upstream implementations (eth-infinitism, Uniswap, ZeroDev), so upstream test suites may cover much of their behavior. Any changes made during porting, however, need their own tests in this repository.

All 15 `perpetual` tests live in `test/perpetual/OrderManager.t.sol`. They pin the event signatures and `getOrder` return layout the indexer depends on, and cover order creation, matching, fills, cancellation, modification, expiry, triggers and market creation. No test file directly targets PositionManager, MarginManager, FundingRateManager, Liquidator, InsuranceFund or ADLEngine.
