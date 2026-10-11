# Platform Operations Review

This review covers four topics, as of October 2026:

1. Issues found while running the full deployment and an ERC-4337 end-to-end flow on anvil, and how each was handled.
2. How to manage a growing set of modular contracts.
3. Tooling for namespaced storage in upgradeable code.
4. Recent security trends for EVM contracts.

Korean version: [docs/ko/OPERATIONS_REVIEW.md](ko/OPERATIONS_REVIEW.md).

## Contents

1. [Improvement Items](#1-improvement-items)
2. [Managing a Modular Contract Platform](#2-managing-a-modular-contract-platform)
3. [Namespaced Storage Support](#3-namespaced-storage-support)
4. [EVM Contract Security Trends (2025-2026)](#4-evm-contract-security-trends-2025-2026)
5. [Sources](#5-sources)

---

## 1. Improvement Items

Each item comes from something observed in this repository. "Done" means the item is addressed in PR #25: deployment approval, anvil E2E in CI, the storage slot check, and docs.

| # | Item | Severity | Evidence | Status |
|---|---|---|---|---|
| 1 | Local and CI Foundry versions differ | High | PR #22 passed on local forge 1.5.1 and failed on CI v1.8.3, which clears transient storage between top-level test calls. `forge fmt --check` also fails locally on two `src/permit2` files while CI passes. | Docs now pin v1.8.3 (`foundryup --install v1.8.3`; older foundryup releases use `foundryup --version v1.8.3`). Each developer still has to switch their local toolchain. On v1.8.3 an invariant contract counts as one test in the summary, so totals are lower than on older versions (1918 vs 1927) with every invariant still run. |
| 2 | Kernel has 31 bytes of EIP-170 headroom | High | The HOOK-4 fix needed manual bytecode trimming. `upgradeTo` reverts without a custom error for lack of space. | Partly done. ERC-721/1155 receiver callbacks moved into `fallback()`, which raised headroom to 347 bytes. Later changes (#29, #32) bring Kernel to 24,282 bytes (294 bytes headroom). Moving rarely used admin paths (`installValidations` 522 bytes, delegatecall whitelist setters 336, `replaceModule` 283) out of the Kernel was reviewed and declined for now: the SDK calls most of them, so it needs either an ABI change or a delegatecall extension that re-implements the admin access check. Revisit when a Kernel change needs about 200 bytes or more. |
| 3 | DeployAll left account creation broken | High | After DeployAll, `FactoryStaker.approved(factory)` was false, so initCode-based account creation reverted with `NotApprovedFactory`. | Done. DeployAll and DeployKernel approve the factory, or log the owner call when the broadcaster is not the owner. |
| 4 | No on-chain E2E in CI | High | Unit tests passed, yet real `handleOps` broadcasts failed twice on gas settings (`0xdeaddead`, `AA95 out of gas`). | Done. New `Anvil E2E` CI job runs DeployAll and `script/e2e/AnvilSmoke.s.sol`. |
| 5 | Deployment target is ambiguous | Medium | Docs describe anvil (31337) while `.env` defaults to chain 8283 at `127.0.0.1:8501`. Docs referenced a wrong DeployAll path. | Done. Paths fixed, anvil overrides documented, and the 8283 manifest described as the CI fixture. |
| 6 | Hard-coded slot constants are unguarded | Medium | Three formulas are mixed (`keccak`, `keccak - 1`, none ERC-7201). All 10 literals were correct, but nothing enforced it. | Done. `script/check-storage-slots.py` runs in CI. |
| 7 | solc pinned to 0.8.28 | Low | `layout at` (0.8.29) and `erc7201()` (0.8.35) were unavailable. | Done. Profiles on 0.8.28 moved to 0.8.35 and all tests pass. Fixing the 13 deprecation warnings 0.8.35 raises in the Kernel sources (memory-safe NatSpec comments, contract-type comparisons) costs 28 bytes, leaving Kernel at 24,257 bytes (319 bytes headroom) at the time; see item 2 for the current size. Universal Router (0.8.26) and the 0.7.6 profile are unchanged. |
| 8 | Breaking change in FlashLoanFallback | Low | The module must now be installed as an executor too, and `beginFlashLoan` must be called first (PR #22). | SDK fix in review (poc-platform#74). The Go and TypeScript helpers encoded install data the contract cannot decode, independent of PR #22; they now encode `(bool, bool)`, add `beginFlashLoan` and `addToWhitelist` encoders, and list the callback selectors. No frontend uses the module. |
| 9 | Thin Kernel test coverage | Low | `FEATURES.md` already notes 37 Kernel tests. | Partly done. `installValidations`, `uninstallValidation`, `revokeSelectors` and replayable (chain-agnostic) signatures had no test and are now covered through the real EntryPoint (`KernelValidationAdmin.t.sol`). `./script/coverage.sh` now measures coverage (an AuditHook stack-too-deep was fixed). Repository total: 56.7% lines. At that measurement the biggest gap was `ValidationManager` at 30.7% lines. Since then, permission signature checks (`KernelPermission.t.sol`) and enable mode (`KernelEnableMode.t.sol`) are covered. Coverage stays a local tool and is not run in CI. |

---

## 2. Managing a Modular Contract Platform

### 2.1 Problem

The repository has 77 contracts in 147 Solidity files, 18 deployment scripts, and 27 shell and 27 TypeScript helper scripts. The cost does not come from the number of contracts itself. It comes from three things that reinforce each other:

1. **Deployment state is tracked by hand.** `addresses.json` records addresses only. DeployAll's `[SKIP]` check asks whether an address exists, not whether the code there matches the current source.
2. **Post-deployment wiring is scattered.** Factory approval, staking, paymaster setup and bridge wiring are spread across Solidity and TypeScript scripts. Item 3 above is a direct result.
3. **Authority is per contract.** Owners and roles live in dozens of contracts. Rotating an operator or reacting to a key compromise takes dozens of transactions. Section 4 shows this is where most industry losses now originate.

Most ERC-7579 modules are singletons with per-account storage keyed by `msg.sender`. Each module is deployed once, and each account pays only an install UserOperation. The hard part is versions and state, not the count of modules.

### 2.2 Recommendation A: Manifest-driven deployment (plan/apply)

Describe each module in a manifest: name, version, constructor arguments, dependencies and post-deploy wiring. The tooling then works the way Terraform does:

- **plan**: compute each CREATE2 address and compare it with on-chain `extcodehash`. Classify each module as new, unchanged or changed.
- **apply**: deploy only what changed, then run the wiring steps.
- **verify**: run the same apply on an anvil fork with the smoke test before touching a real chain.

The repository already has a CREATE2 deployer and skip logic. What remains is the codehash comparison and a dependency graph.

Drawbacks:
- When constructor arguments embed other contracts' addresses, one change ripples into new addresses. Dependency boundaries must be chosen deliberately.
- The manifest must be the single source of truth. A manifest that drifts from the scripts makes things worse.

### 2.3 Recommendation B: Consolidate control (ERC-7484 registry and AccessManager)

- **Module registry (ERC-7484).** Attestors vouch for module addresses, and accounts install only attested modules. Revoking an attestation stops new installs of a flawed module. Rhinestone's registry is the reference implementation.
- **OpenZeppelin AccessManager.** Platform contracts (bridge, DeFi, paymasters) delegate authorization to one AccessManager. Role changes and execution delays are then managed in one place.

Drawbacks:
- Kernel has no bytecode room for a registry check, so the check must live in an installer executor or a hook.
- The registry becomes a single point of failure and an attack target.
- Moving existing contracts to AccessManager means redeploying them.

### 2.4 Further ideas

| Idea | Description | Drawback |
|---|---|---|
| Capability manifests | Each module declares the selectors, targets and call types it needs. An installer shows them to the user, and a hook rejects executions outside the declared scope (similar to Android permissions). | Declared and actual behavior must be matched by static analysis or audit. The hook adds cost to every execution. |
| Preset bundles | Ship common module sets as one initConfig, for example a payments account with ECDSA, SpendingLimit and a Subscription executor. | Bundles create a version matrix to maintain. |
| Install-state indexer | Index `ModuleInstalled` and `ModuleUninstalled` events to map which accounts run which module versions, so affected accounts can be found and notified when a flaw is found. | Off-chain infrastructure cost, and a channel to reach account owners is needed. |
| Immutable modules with a migration executor | Never upgrade a module in place. Deploy new versions at new addresses and provide an executor that copies settings from the old module. This removes upgrade authority altogether. | Users must migrate themselves, so old versions linger. |
| Risk-tiered release paths | Asset-moving executors and fallbacks go through audit, timelock and staged rollout. Low-risk hooks use a faster path. | The classification must be maintained, and a misclassified module turns the fast path into a bypass. |

---

## 3. Namespaced Storage Support

### 3.1 What exists

| Tool | What it does | Limits |
|---|---|---|
| Solidity 0.8.29 `layout at <slot>` | Sets the base slot for a contract's state variables. | Works per contract, not per variable group. Inheritance constraints were not verified for this review. |
| Solidity 0.8.35 `erc7201("id")` | A compile-time builtin for the ERC-7201 formula `keccak256(keccak256(id) - 1) & ~0xff`. Usable as `layout at erc7201("...")`. It is the first comptime builtin in the language. | Requires 0.8.35 or newer, which this repository now uses. |
| OpenZeppelin `SlotDerivation` / `StorageSlot` | ERC-7201 slot derivation, mapping and array slot derivation, and typed slot access. | Runtime computation may cost slightly more gas than a precomputed constant. |
| OpenZeppelin contracts-upgradeable v5 | Every contract uses the ERC-7201 struct pattern with `@custom:storage-location`, so storage gaps are no longer needed. | — |
| OpenZeppelin Upgrades (`validate`, Foundry `validateUpgrade`) | Checks layout compatibility between implementations from build info, including namespaced storage. | Recognizes namespaces only through `@custom:storage-location`. Slots reached through hex constants and assembly, as in this repository, are not checked. |
| ERC-8042 (Diamond Storage) | Formalizes the existing diamond-storage convention `keccak256("id")`. | Uses a different formula from ERC-7201. Mixing both gives two conventions. |
| `forge inspect <C> storageLayout`, slither-check-upgradeability | Print or compare the regular layout. | Do not see slots set through assembly. |

### 3.2 Gap and approach

This repository writes slot constants as hex literals and reads them from assembly, which places them outside the reach of most layout tools. The missing piece is a project-wide consistency check, and it does not need a new library:

1. **Now (done in PR #25).** `script/check-storage-slots.py` collects every `*_SLOT`, `*_SEED` and `*_LOCATION` constant and reads the formula comment above it. It recomputes the value, then fails on a mismatch, a missing declaration, or a reused slot or namespace id. Its weakness is that it depends on the comment format, so the format itself must be kept.
2. **For new code (the compiler is now 0.8.35).** New modules should use `erc7201()` with `@custom:storage-location`, so that OpenZeppelin `validate` covers them. Kernel keeps its existing `keccak` and `keccak - 1` slots: moving them would change where existing accounts keep their state.

---

## 4. EVM Contract Security Trends (2025-2026)

| # | Trend | Evidence | Relevance here |
|---|---|---|---|
| 1 | Losses shift from code bugs to access and operations | H1 2026: 207 incidents and USD 972M stolen. Infrastructure and operational compromises were about 15% of incidents but about 76% of losses (TRM Labs). | Owners and roles are scattered here. Consolidated authority and timelocks (2.3) are the countermeasure. |
| 2 | Single points of failure in verifiers and signers | KelpDAO (April 2026, about USD 290M) ran a 1-of-1 LayerZero DVN configuration, and the attacker compromised RPC infrastructure the DVN trusted. Drift (Solana, about USD 285M) had a 2-of-5 multisig with no timelock, abused through pre-signed transactions. Both are attributed to Lazarus. | Review bridge signer and guardian thresholds and admin timelocks. |
| 3 | OWASP Smart Contract Top 10 2026 | SC01 Access Control, SC02 Business Logic, SC03 Oracle Manipulation, SC04 Flash Loans, SC05 Input Validation, SC06 Unchecked External Calls, SC07 Rounding and Precision, SC08 Reentrancy (down from #2), SC09 Overflow, SC10 Proxy and Upgradeability (new). Based on 122 incidents in 2025 worth about USD 905M. | Matches what this repository's security review found: authorization gaps and accounting mismatches. |
| 4 | Rounding and precision attacks | Balancer v2 (November 2025, about USD 128M): inconsistent rounding between upscaling and downscaling, amplified through batchSwap. | Add rounding-direction invariant tests to the DeFi share and interest math. |
| 5 | EIP-7702 delegation phishing | Analyses report that 80 to 97% of EIP-7702 delegations point to sweeper bytecode. One signature hands over full execution control of an account. | This repository supports EIP-7702 (`Eip7702Support`). Wallets must validate and warn about delegation targets. |
| 6 | Frontend and supply-chain compromise | Polymarket frontend compromise (June 2026, about USD 3M). Bybit (2025, USD 1.5B), where a tampered Safe UI induced a delegatecall signature. | Decode and verify admin transaction calldata independently of the UI. |
| 7 | AI automates both attack and audit | In Anthropic research, agents exploited 207 of 405 historical contracts in simulation and found two zero-days, at about USD 1.22 per scan. A purpose-built audit agent reportedly detected 92% of vulnerabilities in exploited DeFi contracts. | The window between a bug and its exploitation shrinks. Run automated audits in CI and rescan deployed contracts. |
| 8 | Protocol changes break assumptions | Fusaka (3 December 2025) caps transaction gas at 2^24 (EIP-7825). Large batches and deployment transactions must be split. | Review large single-transaction steps in deployment and large batches through PolicyHook. |
| 9 | ERC-7579 standardization | Kernel v3, Biconomy Nexus and Safe's 7579 adapter adopted ERC-7579. ERC-7484 registries gate module installation. | Supports Recommendation B. |

---

## 5. Sources

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
