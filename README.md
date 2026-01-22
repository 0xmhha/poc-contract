# StableNet PoC Contracts

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

# Fast build (development, IR disabled)
forge build --profile fast
```

### 4. Test

```bash
# Run all tests
forge test

# Run with verbose logs
forge test -vvv

# Run specific test
forge test --match-test testKernelDeployment
```

### 5. Local Deployment (Anvil)

```bash
# Terminal 1: Start Anvil (Prague hardfork)
anvil --chain-id 31337 --block-time 1 --hardfork prague

# Terminal 2: Deploy contracts (essential only)
# Use one of Anvil's default accounts (shown in Anvil output)
forge script script/deploy/DeployDevnet.s.sol:DeployDevnetScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY> \
  --broadcast

# Deploy all contracts
forge script script/DeployOrchestrator.s.sol:DeployOrchestratorScript \
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
├── privacy/                # Stealth addresses (ERC-5564/6538)
├── compliance/             # Regulatory compliance
├── tokens/                 # Token contracts
└── defi/                   # DeFi components
```

## Deployment by Category

### ERC-4337 Account Abstraction

Core Account Abstraction contracts including EntryPoint and Paymaster.

```bash
forge script script/deploy/DeployERC4337.s.sol:DeployERC4337Script \
  --rpc-url <RPC_URL> --broadcast
```

| Contract | Description |
|----------|-------------|
| EntryPoint | Core entry point for UserOperation processing |
| VerifyingPaymaster | Signature-based gas sponsorship |
| ERC20Paymaster | Pay gas fees with ERC20 tokens |

### ERC-7579 Modular Smart Account

Modular smart account and plugin modules.

```bash
forge script script/deploy/DeployERC7579.s.sol:DeployERC7579Script \
  --rpc-url <RPC_URL> --broadcast
```

| Contract | Description |
|----------|-------------|
| Kernel | Modular smart account implementation |
| KernelFactory | Kernel account creation factory |
| ECDSAValidator | ECDSA signature validation |
| WeightedECDSAValidator | Weighted multisig validation |
| SessionKeyExecutor | Session key execution module |
| SpendingLimitHook | Spending limit hook |

### Privacy (ERC-5564/6538)

Stealth address-based privacy contracts.

```bash
forge script script/deploy/DeployPrivacy.s.sol:DeployPrivacyScript \
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
forge script script/deploy/DeployCompliance.s.sol:DeployComplianceScript \
  --rpc-url <RPC_URL> --broadcast
```

| Contract | Description |
|----------|-------------|
| KYCRegistry | KYC status management |
| AuditLogger | Audit log recording |
| ProofOfReserve | Proof of reserves |

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

MIT License
