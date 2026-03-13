# StableNet PoC Contracts

[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-363636?logo=solidity)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C)](https://getfoundry.sh/)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

Smart contract PoC for StableNet — ERC-4337 Account Abstraction, ERC-7579 Modular Smart Account, DeFi, Bridge, Privacy, and Compliance.

> **[한국어 문서](./docs/ko/README.md)**

## Quick Start

### 1. Prerequisites

- [Foundry](https://getfoundry.sh/) >= 1.0.0
- Node.js >= 18 (for TypeScript deploy scripts)

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 2. Setup

```bash
git submodule update --init --recursive
npm install
cp .env.example .env
```

Edit `.env` with your configuration. Required variables for deployment:

| Variable | Description |
|----------|-------------|
| `RPC_URL` | RPC endpoint URL |
| `CHAIN_ID` | Target chain ID (default: `8283`) |
| `PRIVATE_KEY_DEPLOYER` | Deployer private key (must have native coin for gas) |

See `.env.example` for the full list of optional variables (bundler, paymaster, bridge, etc.).

### 3. Build

```bash
forge build
```

### 4. Test

```bash
forge test           # Run all tests
forge test -vvv      # Verbose output
```

## Deployment

Two deployment scripts are available depending on your needs.

### Full Deployment (`deploy-all.sh`)

Deploys **all 50+ contracts** across 19 steps in dependency order, including post-deployment configuration (USDC transfer, oracle price setup, paymaster setup).

```bash
# Full deployment
./script/deploy-all.sh

# Preview what will be deployed
./script/deploy-all.sh --dry-run

# Resume from a specific step (e.g., after partial failure)
./script/deploy-all.sh --from=paymasters

# Deploy + verify (requires indexer, see below)
./script/deploy-all.sh --verify
```

| Option | Description | When to use |
|--------|-------------|-------------|
| *(no flags)* | Full deployment | First-time setup, fresh chain |
| `--dry-run` | Show plan without executing | Review deployment order before running |
| `--from=<step>` | Start from a specific step | Recovery after partial failure |
| `--skip-deploy` | Run configuration steps only | Re-configure after contracts are already deployed |
| `--skip-config` | Run deployment steps only | Deploy without paymaster/oracle config |
| `--verify` | Verify contracts on block explorer | When indexer + frontend are running |
| `--force` | Force redeploy all contracts | Re-deploy even if contracts exist at the same address |
| `--addresses` | Print deployed addresses | Quick reference for DApp integration |

Available steps: `tokens`, `transfer-usdc`, `entrypoint`, `smartaccount`, `validators`, `hooks`, `fallbacks`, `executors`, `compliance`, `privacy`, `permit2`, `subscription`, `bridge`, `uniswap`, `defi`, `paymasters`, `plugins`, `setup-oracle-price`, `setup-paymaster`

### Selective Deployment (`deploy.sh`)

Deploys specific contract groups using `forge script` directly. Useful for deploying individual modules without the full pipeline.

```bash
# Show deployment plan
./script/deploy.sh --plan

# Deploy all contracts (no config steps)
./script/deploy.sh --broadcast

# Deploy specific steps only
./script/deploy.sh --broadcast --steps=tokens,entrypoint,kernel

# Force redeploy
./script/deploy.sh --broadcast --force
```

| Option | Description | When to use |
|--------|-------------|-------------|
| `--plan` | Show deployment plan | Preview available steps and dependencies |
| `--broadcast` | Broadcast transactions | Actually deploy (omit for dry run) |
| `--steps=<a,b,c>` | Deploy specific steps | Partial deployment of selected modules |
| `--force` | Force redeploy | Redeploy even if contracts already exist |

Available steps: `tokens`, `entrypoint`, `kernel`, `validators`, `hooks`, `fallbacks`, `executors`, `compliance`, `privacy`, `permit2`, `defi`, `paymasters`, `plugins`, `subscription`, `bridge`

### Which script to use?

| Scenario | Script |
|----------|--------|
| First time setup / fresh chain | `deploy-all.sh` |
| Need paymaster + oracle configured | `deploy-all.sh` |
| Deploying a single module for development | `deploy.sh --broadcast --steps=<step>` |
| Re-running config after contracts exist | `deploy-all.sh --skip-deploy` |
| Resuming after a failed step | `deploy-all.sh --from=<step>` |

## Contract Verification

Contract verification publishes source code to the block explorer, making contracts readable and verifiable by anyone.

**Prerequisites**: A block explorer indexer and its frontend must be running and accessible. Set the verifier endpoint in `.env`:

```bash
VERIFIER_URL=https://your-indexer-api.example.com/api
```

### Verify during deployment

```bash
./script/deploy-all.sh --verify
```

### Verify already-deployed contracts

Each module has a standalone verify mode:

```bash
# Verify all bridge contracts
npx ts-node script/ts/deploy-bridge.ts --verify

# Verify all plugin contracts
npx ts-node script/ts/deploy-plugins.ts --verify
```

This reads addresses from `deployments/<chainId>/addresses.json` and runs `forge verify-contract` for each contract with the correct constructor arguments.

## Deployed Addresses

All deployed addresses are saved to:

```
deployments/<chainId>/addresses.json
```

Quick access:

```bash
./script/deploy-all.sh --addresses
```

## Contract Structure

```
src/
├── tokens/                 # USDC stablecoin
├── erc4337-entrypoint/     # ERC-4337 EntryPoint
├── erc4337-paymaster/      # Gas sponsorship (Verifying, Sponsor, ERC20, Permit2)
├── erc7579-smartaccount/   # Kernel modular smart account
├── erc7579-validators/     # Signature validation (ECDSA, MultiSig, WebAuthn, etc.)
├── erc7579-executors/      # Execution modules (SessionKey, Swap, Lending, Staking)
├── erc7579-hooks/          # Pre/post execution hooks (Audit, SpendingLimit, Policy)
├── erc7579-fallbacks/      # Fallback handlers (TokenReceiver, FlashLoan)
├── erc7579-plugins/        # Plugins (AutoSwap, MicroLoan, OnRamp)
├── defi/                   # PriceOracle, LendingPool, StakingVault
├── bridge/                 # Cross-chain bridge (MPC + Optimistic + Guardian)
├── privacy/                # Stealth addresses (ERC-5564/6538) + Enterprise vault
├── compliance/             # KYC, AuditLogger, ProofOfReserve, RegulatoryRegistry
├── subscription/           # ERC-7715 permission management + subscriptions
└── permit2/                # Permit2 token approvals
```

## Documentation

- [Architecture](./docs/ARCHITECTURE.md) — System design and contract dependencies
- [Deployment Details](./docs/DEPLOYMENT.md) — Dependency order, post-deploy config, troubleshooting

## License

GPL-3.0
