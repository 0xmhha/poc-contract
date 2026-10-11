# Deployment Details

Detailed deployment order, post-deployment configuration, and troubleshooting.

For quick start and common usage, see the [README](../README.md).

> **[한국어](./ko/DEPLOYMENT.md)**

## Deployment Order

Contracts are deployed in dependency order. The `deploy-all.sh` script handles this automatically.

```
Phase 0 — Base Infrastructure
  └── Tokens (USDC), EntryPoint

Phase 1 — Smart Account
  └── Kernel, KernelFactory, FactoryStaker (depends on EntryPoint)

Phase 2 — ERC-7579 Modules
  └── Validators, Hooks, Fallbacks, Executors

Phase 3 — Feature Modules
  └── Compliance, Privacy, Permit2, Subscription, Bridge

Phase 4 — DeFi & Paymasters
  └── UniswapV3, PriceOracle, LendingPool, StakingVault, Paymasters, Plugins
      (Paymasters depend on EntryPoint + PriceOracle)
      (Plugins depend on PriceOracle + SwapRouter)

Config — Post-deployment
  └── Oracle price setup, Paymaster setup (deposit, token, bundler, factory)
```

### Key Dependencies

| Contract | Depends On |
|----------|------------|
| Kernel | EntryPoint |
| KernelFactory | Kernel |
| ERC20Paymaster | EntryPoint, PriceOracle |
| Permit2Paymaster | EntryPoint, PriceOracle, Permit2 |
| SecureBridge | BridgeValidator, OptimisticVerifier, BridgeRateLimiter, BridgeGuardian |
| SubscriptionManager | ERC7715PermissionManager |
| AutoSwapPlugin | PriceOracle, SwapRouter |
| MicroLoanPlugin | PriceOracle |
| SwapExecutor | SwapRouter, Quoter |
| LendingExecutor | LendingPool |
| HealthFactorHook | LendingPool |

## Post-Deployment Configuration

The `deploy-all.sh` script runs these automatically via `setup-oracle-price` and `setup-paymaster` steps. For manual configuration:

### Oracle Price Setup

Register a price feed so `PriceOracle.getPrice()` works:

```bash
# Automated: deploys FixedPriceAggregator and registers USDC feed
./script/setup-oracle-price.sh

# Custom price (default: 1 USDC = 1500 KRWC)
USDC_KRWC_PRICE=2000 ./script/setup-oracle-price.sh
```

### Paymaster Setup

Configure paymasters after deployment:

```bash
# Automated: deposit, add supported tokens, whitelist bundler/factory, set budgets
./script/setup-paymaster.sh
```

This handles:
- Depositing native coin to EntryPoint for gas sponsorship
- Adding USDC as a supported token on ERC20Paymaster
- Whitelisting the bundler address
- Whitelisting KernelFactory for SponsorPaymaster
- Setting daily gas budgets

### Bridge Wiring

Bridge contracts require cross-contract wiring after deployment. The `DeployBridge.s.sol` script handles this automatically:

```
OptimisticVerifier.setFraudProofVerifier(FraudProofVerifier)
OptimisticVerifier.setAuthorizedCaller(SecureBridge)
FraudProofVerifier.setOptimisticVerifier(OptimisticVerifier)
FraudProofVerifier.setBridgeValidator(BridgeValidator)
```

## Environment Variables

### Required

| Variable | Description |
|----------|-------------|
| `RPC_URL` | RPC endpoint URL |
| `PRIVATE_KEY_DEPLOYER` | Deployer private key |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `CHAIN_ID` | `8283` | Target chain ID |
| `ADMIN_ADDRESS` | deployer | Admin for infrastructure contracts |
| `OWNER_ADDRESS` | deployer | Paymaster owner address |
| `VERIFYING_SIGNER` | admin | Off-chain signer for paymaster approval |
| `FEE_RECIPIENT` | deployer | Fee recipient for bridges and plugins |
| `PRIVATE_KEY_BUNDLER` | — | Bundler private key |
| `PRIVATE_KEY_PAYMASTER` | — | Paymaster owner private key |
| `BUNDLER_RPC_URL` | `http://127.0.0.1:4337` | Bundler RPC endpoint |
| `VERIFIER_URL` | — | Block explorer API for contract verification |
| `BRIDGE_SIGNERS` | deployer x3 | Comma-separated signer addresses |
| `BRIDGE_GUARDIANS` | deployer x3 | Comma-separated guardian addresses |
| `BRIDGE_SIGNER_THRESHOLD` | `3` | MPC signer threshold |
| `BRIDGE_GUARDIAN_THRESHOLD` | `2` | Guardian threshold |
| `FRAUD_PROOF_SOURCE_CHAINS` | unset | Comma-separated source chain ids whose tokens are authorized on FraudProofVerifier. Unset: InvalidToken fraud proofs fail closed |
| `FRAUD_PROOF_TOKENS_<chainId>` | unset | Comma-separated token addresses authorized for that source chain (add-only) |
| `SUBSCRIPTION_ENFORCE_MERCHANT_REGISTRY` | `false` | Link MerchantRegistry to SubscriptionManager. When `true`, only verified, unsuspended merchants can create plans and be paid |

See `.env.example` for the full list.

## Local Deployment and E2E (anvil)

Testing on a local node targets anvil (chain id 31337). `.env` defaults such as `CHAIN_ID=8283` and `RPC_URL` may point to a different node, so override them in the environment; forge does not let `.env` replace variables that are already set.

```bash
anvil --chain-id 31337 --hardfork prague

# anvil default account 0 (public test key)
ANVIL_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ANVIL_ADDR=$(cast wallet address $ANVIL_KEY)

CHAIN_ID=31337 ADMIN_ADDRESS=$ANVIL_ADDR VERIFYING_SIGNER=$ANVIL_ADDR \
forge script script/deploy-contract/DeployAll.s.sol:DeployAllScript \
  --rpc-url http://127.0.0.1:8545 --private-key $ANVIL_KEY --broadcast --slow

forge script script/e2e/AnvilSmoke.s.sol:AnvilSmokeScript \
  --rpc-url http://127.0.0.1:8545 --private-key $ANVIL_KEY \
  --broadcast --slow --gas-estimate-multiplier 200
```

- DeployAll approves the KernelFactory on the FactoryStaker when the broadcaster is the staker owner (`ADMIN_ADDRESS`). Otherwise it logs a `[TODO]` with the call the owner must make; until then, account creation through initCode reverts with `NotApprovedFactory`.
- The smoke script deploys an account through initCode and runs two transfers via `handleOps`. The CI job `Anvil E2E` runs the same steps.
- `--gas-estimate-multiplier` is required: `eth_estimateGas` does not cover the EntryPoint inner-call gas checks, so `handleOps` sent with the raw estimate passes simulation but fails on chain (`0xdeaddead`, `AA95 out of gas`).
- Addresses are written to `deployments/31337/addresses.json` (git-ignored). `deployments/8283/addresses.json` is the StableNet deployment manifest kept in git as the platform compatibility fixture.

## Troubleshooting

### CreateCollision Error

A contract already exists at the computed address.

```bash
# Restart the chain or use --force to redeploy
./script/deploy-all.sh --force
```

### fs_permissions Error

Forge cannot write `addresses.json`. Ensure `foundry.toml` has:

```toml
fs_permissions = [{ access = "read-write", path = "deployments" }]
```

### PriceOracle NoPriceFeed Error

Oracle has no registered price feed. Run the oracle setup:

```bash
./script/setup-oracle-price.sh
```

### Verification Fails

- Ensure `VERIFIER_URL` is set in `.env`
- Ensure the indexer and its frontend are running and accessible
- If verification fails for a specific contract, retry with the module script:
  ```bash
  npx ts-node script/ts/deploy-bridge.ts --verify
  ```

### Partial Deployment Failure

Resume from the failed step:

```bash
./script/deploy-all.sh --from=<failed-step>
```
