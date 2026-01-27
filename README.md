# StableNet PoC Contracts

[![CI](https://github.com/0xmhha/poc-contract/actions/workflows/test.yml/badge.svg)](https://github.com/0xmhha/poc-contract/actions/workflows/test.yml)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-363636?logo=solidity)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C?logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTEyIDJMMiA3bDEwIDUgMTAtNS0xMC01ek0yIDE3bDEwIDUgMTAtNS0xMC01LTEwIDV6TTIgMTJsMTAgNSAxMC01LTEwLTUtMTAgNXoiIGZpbGw9IiMzMzMiLz48L3N2Zz4=)](https://getfoundry.sh/)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

Smart contract Proof of Concept (PoC) repository for StableNet.

Includes ERC-4337 Account Abstraction, ERC-7579 Modular Smart Account, Stealth Addresses (ERC-5564/6538), and Compliance contracts.

> **[한국어 문서](./docs/ko/README.md)**

## Requirements

| Tool | Version | Description |
|------|---------|-------------|
| Foundry | ≥1.0.0 | Solidity development toolkit |
| Solidity | 0.8.28 | Smart contract language |
| Anvil | ≥1.0.0 | Local Ethereum node |

### Install Foundry

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Verify installation
forge --version
anvil --version
```

## Quick Start

### 1. Install Dependencies

```bash
# Initialize and update submodules
git submodule update --init --recursive

# Or install directly with forge
forge install
```

### 2. Environment Setup

```bash
# Create .env file
cp .env.example .env

# Edit .env file with required values
```

### 3. Build

```bash
# Full build
forge build

# Tokens build (USDC, wKRC)
FOUNDRY_PROFILE=tokens forge build

# EntryPoint build
FOUNDRY_PROFILE=entrypoint forge build

# Paymaster build
FOUNDRY_PROFILE=paymaster forge build

# Smart Account build
FOUNDRY_PROFILE=smartaccount forge build

# Validator build
FOUNDRY_PROFILE=validators forge build

# Hook build
FOUNDRY_PROFILE=hooks forge build

# Fallback build
FOUNDRY_PROFILE=fallbacks forge build

# Executors build
FOUNDRY_PROFILE=executors forge build

# Plugins build
FOUNDRY_PROFILE=plugins forge build

# Compliance build
FOUNDRY_PROFILE=compliance forge build

# Privacy build
FOUNDRY_PROFILE=privacy forge build

# Permit2 build
FOUNDRY_PROFILE=permit2 forge build

# Defi build
FOUNDRY_PROFILE=defi forge build

# Subscription build
FOUNDRY_PROFILE=subscription forge build

# Bridge build
FOUNDRY_PROFILE=bridge forge build

```

### 4. Test

```bash
# Run all tests
forge test

# Run with verbose logs
forge test -vvv

# Run specific test
forge test --match-test testKernelDeployment

# Run specific folder
forge test --match-path "test/tokens/*"
```

### 5. Local Deployment (Anvil)

```bash
# Start Anvil (Prague hardfork)
anvil --chain-id 31337 --block-time 1 --hardfork prague

# Deploy contracts (essential only)
# Use one of Anvil's default accounts (shown in Anvil output)

# Token Contract
# Note: USDC owner = ADMIN_ADDRESS (env var). If not set, deployer becomes owner.
# Initial mint: 1,000,000 USDC to owner address.
FOUNDRY_PROFILE=tokens forge script script/deploy-contract/DeployTokens.s.sol:DeployTokensScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# EntryPoint Contract
FOUNDRY_PROFILE=entrypoint forge script script/deploy-contract/DeployEntryPoint.s.sol:DeployEntryPointScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# Paymaster Contract
FOUNDRY_PROFILE=paymaster forge script script/deploy-contract/DeployPaymasters.s.sol:DeployPaymastersScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# SmartAccount(Kernel + Factory) Contract
FOUNDRY_PROFILE=smartaccount forge script script/deploy-contract/DeployKernel.s.sol:DeployKernelScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# Validator Contract
FOUNDRY_PROFILE=validators forge script script/deploy-contract/DeployValidators.s.sol:DeployValidatorsScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# Hook Contract
FOUNDRY_PROFILE=hooks forge script script/deploy-contract/DeployHooks.s.sol:DeployHooksScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# Fallback Contract
FOUNDRY_PROFILE=fallbacks forge script script/deploy-contract/DeployFallbacks.s.sol:DeployFallbacksScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# Executors Contract
FOUNDRY_PROFILE=executors forge script script/deploy-contract/DeployExecutors.s.sol:DeployExecutorsScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# Plugins Contract
FOUNDRY_PROFILE=plugins forge script script/deploy-contract/DeployPlugins.s.sol:DeployPluginsScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# Compliance Contract
FOUNDRY_PROFILE=compliance forge script script/deploy-contract/DeployCompliance.s.sol:DeployComplianceScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# Privacy Contract
FOUNDRY_PROFILE=privacy forge script script/deploy-contract/DeployPrivacy.s.sol:DeployPrivacyScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# Permit2 Contract
FOUNDRY_PROFILE=permit2 forge script script/deploy-contract/DeployPermit2.s.sol:DeployPermit2Script \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# Defi Contract
FOUNDRY_PROFILE=defi forge script script/deploy-contract/DeployDeFi.s.sol:DeployDeFiScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# Subscription Contract
FOUNDRY_PROFILE=subscription forge script script/deploy-contract/DeploySubscription.s.sol:DeploySubscriptionScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# Bridge Contract
FOUNDRY_PROFILE=bridge forge script script/deploy-contract/DeployBridge.s.sol:DeployBridgeScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

```

Deployed addresses are saved to `deployments/<chainId>/addresses.json`.

## Contract Structure

```
src/
├── erc4337-entrypoint/     # ERC-4337 EntryPoint
├── erc4337-paymaster/      # Paymaster (gas sponsorship)
├── erc7579-smartaccount/   # ERC-7579 Kernel Smart Account
├── erc7579-validators/     # Signature validation modules
├── erc7579-executors/      # Execution modules
├── erc7579-hooks/          # Hook modules
├── erc7579-fallbacks/      # Fallback modules
├── erc7579-plugins/        # Plugin modules (AutoSwap, MicroLoan, OnRamp)
├── privacy/                # Stealth addresses (ERC-5564/6538)
├── compliance/             # Regulatory compliance
├── tokens/                 # Token contracts (wKRC, USDC)
├── defi/                   # DeFi components (PriceOracle, DEXIntegration)
├── permit2/                # Permit2 token approvals
├── subscription/           # Subscription management (ERC-7715)
└── bridge/                 # Cross-chain bridge
```

## Full Deployment (All Contracts)

Deploy all contracts at once using the unified deployment script:

```bash
forge script script/DeployAll.s.sol:DeployAllScript \
  --rpc-url <RPC_URL> \
  --private-key <PRIVATE_KEY> \
  --broadcast
```

This deploys all 44 contracts in dependency order across 6 phases.

## Deployment by Category

### ERC-4337 Account Abstraction

Core Account Abstraction contracts including EntryPoint and Paymaster.

```bash
# EntryPoint
FOUNDRY_PROFILE=entrypoint forge script script/deploy-contract/DeployEntryPoint.s.sol:DeployEntryPointScript \
  --rpc-url <RPC_URL> --broadcast

# Paymasters (requires EntryPoint)
FOUNDRY_PROFILE=paymaster forge script script/deploy-contract/DeployPaymasters.s.sol:DeployPaymastersScript \
  --rpc-url <RPC_URL> --broadcast
```

| Contract | Description |
|----------|-------------|
| EntryPoint | Core entry point for UserOperation processing |
| VerifyingPaymaster | Signature-based gas sponsorship |
| SponsorPaymaster | Sponsored transaction paymaster |
| ERC20Paymaster | Pay gas fees with ERC20 tokens |
| Permit2Paymaster | Permit2-based token approval paymaster |

### ERC-7579 Modular Smart Account

Modular smart account and plugin modules.

```bash
# Kernel + Factory
FOUNDRY_PROFILE=smartaccount forge script script/deploy-contract/DeployKernel.s.sol:DeployKernelScript \
  --rpc-url <RPC_URL> --broadcast

# Validators
FOUNDRY_PROFILE=validators forge script script/deploy-contract/DeployValidators.s.sol:DeployValidatorsScript \
  --rpc-url <RPC_URL> --broadcast
```

| Contract | Description |
|----------|-------------|
| Kernel | Modular smart account implementation |
| KernelFactory | Kernel account creation factory |
| ECDSAValidator | ECDSA signature validation |
| WeightedECDSAValidator | Weighted multisig validation |
| MultiChainValidator | Multi-chain signature validation |
| MultiSigValidator | Multi-signature validation |
| WebAuthnValidator | WebAuthn/Passkey validation |
| SessionKeyExecutor | Session key execution module |
| SpendingLimitHook | Spending limit hook |

### Privacy (ERC-5564/6538)

Stealth address-based privacy contracts.

```bash
FOUNDRY_PROFILE=privacy forge script script/deploy-contract/DeployPrivacy.s.sol:DeployPrivacyScript \
  --rpc-url <RPC_URL> --broadcast
```

| Contract | Description |
|----------|-------------|
| ERC5564Announcer | Stealth address announcements |
| ERC6538Registry | Stealth meta-address registry |
| PrivateBank | Private deposits and withdrawals |

### Compliance

Regulatory compliance and audit contracts.

```bash
FOUNDRY_PROFILE=compliance forge script script/deploy-contract/DeployCompliance.s.sol:DeployComplianceScript \
  --rpc-url <RPC_URL> --broadcast
```

| Contract | Description |
|----------|-------------|
| KYCRegistry | KYC status management |
| AuditLogger | Audit log recording |
| ProofOfReserve | Proof of reserves |
| RegulatoryRegistry | Regulator registration and trace approvals |

### Bridge

Cross-chain bridge with defense-in-depth security.

```bash
FOUNDRY_PROFILE=bridge forge script script/deploy-contract/DeployBridge.s.sol:DeployBridgeScript \
  --rpc-url <RPC_URL> --broadcast
```

| Contract | Description |
|----------|-------------|
| SecureBridge | Main bridge contract |
| BridgeValidator | MPC signing validation |
| OptimisticVerifier | Challenge period verification |
| FraudProofVerifier | Fraud proof resolution |
| BridgeRateLimiter | Volume and rate controls |
| BridgeGuardian | Emergency response system |

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ADMIN_ADDRESS` | Admin address | Deployer |
| `VERIFYING_SIGNER` | Paymaster signer | Admin |
| `SKIP_EXISTING` | Skip existing deployments | true |
| `RPC_URL_LOCAL` | Local RPC URL | - |
| `RPC_URL_SEPOLIA` | Sepolia RPC URL | - |

## Documentation

See the [docs/](./docs/) folder for detailed documentation:

- [Deployment Guide](./docs/DEPLOYMENT.md) - Detailed deployment instructions
- [Architecture](./docs/ARCHITECTURE.md) - Contract structure and dependencies
- [Development Guide](./docs/DEVELOPMENT.md) - Development workflow

## Project Configuration

### Key foundry.toml Settings

```toml
[profile.default]
solc = "0.8.28"
evm_version = "prague"
optimizer = true
optimizer_runs = 200
via_ir = true
```

## License

GPL-3.0 License
