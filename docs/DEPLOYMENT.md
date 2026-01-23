# Deployment Guide

Detailed guide for deploying StableNet PoC contracts.

> **[한국어](./ko/DEPLOYMENT.md)**

## Deployment Script Structure

```
script/
├── deploy/
│   ├── DeployDevnet.s.sol      # One-click development deployment
│   ├── DeployERC4337.s.sol     # ERC-4337 Account Abstraction
│   ├── DeployERC7579.s.sol     # ERC-7579 Modular Smart Account
│   ├── DeployPrivacy.s.sol     # Privacy (ERC-5564/6538)
│   └── DeployCompliance.s.sol  # Compliance
├── utils/
│   └── DeploymentAddresses.sol # Address management utility
└── DeployOrchestrator.s.sol    # Full orchestrator
```

## Deployment Order (Dependencies)

```
Layer 0 (No dependencies)
├── EntryPoint
├── Validators (ECDSA, Weighted, MultiChain)
├── Executors (SessionKey, RecurringPayment)
├── Hooks (Audit, SpendingLimit)
├── Fallbacks (TokenReceiver, FlashLoan)
├── ERC5564Announcer, ERC6538Registry
└── KYCRegistry, AuditLogger, ProofOfReserve

Layer 1 (Depends on Layer 0)
├── Kernel → EntryPoint
├── VerifyingPaymaster → EntryPoint
├── ERC20Paymaster → EntryPoint, PriceOracle
└── PrivateBank → ERC5564Announcer, ERC6538Registry

Layer 2 (Depends on Layer 1)
├── KernelFactory → Kernel
└── SubscriptionManager → ERC7715PermissionManager
```

## Local Deployment (Anvil)

### 1. Start Anvil

```bash
# Enable Prague hardfork (EIP-7702 support)
anvil --chain-id 31337 --block-time 1 --hardfork prague

# Options explained:
# --chain-id: Chain ID (31337 = local)
# --block-time: Block creation interval (seconds)
# --hardfork: Hardfork version
```

### 2. One-Click Deployment (Essential contracts only)

Quick deployment of essential contracts for development and testing.

```bash
forge script script/deploy/DeployDevnet.s.sol:DeployDevnetScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Deployed contracts:
- EntryPoint
- Kernel + KernelFactory
- ECDSAValidator
- VerifyingPaymaster
- ERC5564Announcer + ERC6538Registry

### 3. Category-Based Deployment

#### ERC-4337 Account Abstraction

```bash
forge script script/deploy/DeployERC4337.s.sol:DeployERC4337Script \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Individual deployment:
```bash
# EntryPoint only
forge script script/deploy/DeployERC4337.s.sol:DeployEntryPointOnlyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

#### ERC-7579 Modular Smart Account

```bash
forge script script/deploy/DeployERC7579.s.sol:DeployERC7579Script \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Individual deployment:
```bash
# Kernel + Factory only
forge script script/deploy/DeployERC7579.s.sol:DeployKernelOnlyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Validators only
forge script script/deploy/DeployERC7579.s.sol:DeployValidatorsOnlyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

#### Privacy (ERC-5564/6538)

```bash
forge script script/deploy/DeployPrivacy.s.sol:DeployPrivacyScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Individual deployment:
```bash
# Stealth contracts only
forge script script/deploy/DeployPrivacy.s.sol:DeployStealthOnlyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# PrivateBank only (requires Announcer, Registry)
forge script script/deploy/DeployPrivacy.s.sol:DeployPrivateBankOnlyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

#### Compliance

```bash
forge script script/deploy/DeployCompliance.s.sol:DeployComplianceScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Individual deployment:
```bash
# KYCRegistry only
forge script script/deploy/DeployCompliance.s.sol:DeployKYCRegistryOnlyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

### 4. Full Deployment (Orchestrator)

Deploy all contracts in dependency order.

```bash
forge script script/DeployOrchestrator.s.sol:DeployOrchestratorScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Layer-by-layer deployment:
```bash
# Layer 0 only
DEPLOY_LAYER=0 forge script script/DeployOrchestrator.s.sol:DeployOrchestratorScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Layer 1 only
DEPLOY_LAYER=1 forge script script/DeployOrchestrator.s.sol:DeployOrchestratorScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Layer 2 only
DEPLOY_LAYER=2 forge script script/DeployOrchestrator.s.sol:DeployOrchestratorScript \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

## Testnet Deployment (Sepolia)

### 1. Environment Setup

```bash
# Add to .env file
RPC_URL_SEPOLIA=https://sepolia.infura.io/v3/YOUR_API_KEY
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_KEY
```

### 2. Deploy

```bash
forge script script/deploy/DeployERC4337.s.sol:DeployERC4337Script \
  --rpc-url $RPC_URL_SEPOLIA \
  --broadcast \
  --verify
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ADMIN_ADDRESS` | Admin address | Deployer |
| `VERIFYING_SIGNER` | Paymaster signer | Admin |
| `SKIP_EXISTING` | Skip existing deployments | true |
| `DEPLOY_LAYER` | Layer to deploy (0, 1, 2, all) | all |
| `AUDIT_RETENTION_PERIOD` | Audit log retention period | 365 days |
| `POR_REQUIRED_CONFIRMATIONS` | Proof of reserve confirmations | 3 |

## Deployment Results

Deployed addresses are saved as JSON files:

```
deployments/
├── 31337/
│   └── addresses.json    # Local (Anvil)
├── 11155111/
│   └── addresses.json    # Sepolia
└── 1/
    └── addresses.json    # Mainnet
```

### addresses.json Example

```json
{
  "entryPoint": "0x...",
  "kernel": "0x...",
  "kernelFactory": "0x...",
  "ecdsaValidator": "0x...",
  "verifyingPaymaster": "0x...",
  "erc5564Announcer": "0x...",
  "erc6538Registry": "0x..."
}
```

## Paymaster Funding

After deployment, Paymaster needs ETH deposited to sponsor gas.

```bash
# Use FundPaymasterScript
forge script script/deploy/DeployDevnet.s.sol:FundPaymasterScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

# Or deposit directly with cast
cast send <ENTRYPOINT_ADDRESS> "depositTo(address)" <PAYMASTER_ADDRESS> \
  --value 10ether \
  --rpc-url http://127.0.0.1:8545
```

## Post-Deployment Configuration

### PriceOracle Feed Registration

> **IMPORTANT**: PriceOracle requires feed registration after deployment. Without registered feeds, price queries will revert with `NoPriceFeed` error.

#### Chainlink Feed Registration

```solidity
// Register Chainlink price feeds (Owner only)
IPriceOracle oracle = IPriceOracle(PRICE_ORACLE_ADDRESS);

// ETH/USD feed
oracle.setChainlinkFeed(
    address(0),                           // Native token (ETH)
    0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419  // Chainlink ETH/USD (Mainnet)
);

// USDC/USD feed
oracle.setChainlinkFeed(
    USDC_ADDRESS,
    0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6  // Chainlink USDC/USD (Mainnet)
);
```

#### Uniswap V3 TWAP Registration

```solidity
// Register Uniswap V3 pool for TWAP (Owner only)
oracle.setUniswapPool(
    TOKEN_ADDRESS,           // Token to price
    UNISWAP_POOL_ADDRESS,    // Uniswap V3 pool
    1800,                    // TWAP period (30 minutes)
    address(0)               // Quote token (address(0) if USD-pegged)
);

// For non-USD pairs (e.g., TOKEN/WETH)
oracle.setUniswapPool(
    TOKEN_ADDRESS,
    TOKEN_WETH_POOL,
    1800,
    WETH_ADDRESS             // Quote token (needs Chainlink feed)
);
```

#### Chainlink Feed Addresses (Reference)

| Network | Token | Feed Address |
|---------|-------|--------------|
| Mainnet | ETH/USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| Mainnet | USDC/USD | `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` |
| Mainnet | USDT/USD | `0x3E7d1eAB13ad0104d2750B8863b489D65364e32D` |
| Sepolia | ETH/USD | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| Sepolia | USDC/USD | `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E` |

> **Note**: Always verify feed addresses from [Chainlink Data Feeds](https://docs.chain.link/data-feeds/price-feeds/addresses)

#### Verification

```solidity
// Check if feed is registered
bool hasFeed = oracle.hasPriceFeed(TOKEN_ADDRESS);

// Check if price is valid (not stale)
bool isValid = oracle.hasValidPrice(TOKEN_ADDRESS);

// Get price source
string memory source = oracle.getPriceSource(TOKEN_ADDRESS);
// Returns: "Chainlink", "UniswapV3TWAP", or "None"
```

## Troubleshooting

### 1. CreateCollision Error

A contract is already deployed at the same address.

```bash
# Solution: Restart Anvil
# Stop Anvil in terminal and restart
anvil --chain-id 31337 --hardfork prague
```

### 2. fs_permissions Error

No permission to save addresses.json.

```toml
# Add to foundry.toml
fs_permissions = [
    { access = "read-write", path = "." }
]
```

### 3. Dependency Error

Required contracts are not deployed first.

```bash
# Solution: Deploy in dependency order
# 1. DeployERC4337 (EntryPoint)
# 2. DeployERC7579 (Kernel - requires EntryPoint)
# 3. DeployPrivacy
# 4. DeployCompliance
```
