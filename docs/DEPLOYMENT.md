# Deployment Guide

Detailed guide for deploying StableNet PoC contracts.

> **[한국어](./ko/DEPLOYMENT.md)**

## Contract Architecture Overview

The project consists of **96 Solidity files** across **13 domains**:

| Domain | Contracts | Description |
|--------|-----------|-------------|
| Tokens | USDC, wKRC | Stablecoin (6 decimals) + Wrapped native token (18 decimals) |
| ERC-4337 EntryPoint | 10 | UserOperation singleton, nonce/stake management |
| ERC-7579 Smart Account | 32 | Modular Kernel account with proxy pattern |
| Validators | 5 | ECDSA, Weighted, MultiChain, WebAuthn, MultiSig |
| Paymasters | 5 | Verifying, ERC20, Sponsor, Permit2 |
| Executors | 2 | SessionKey, RecurringPayment |
| Hooks & Fallbacks | 4 | Audit, SpendingLimit, TokenReceiver, FlashLoan |
| Bridge | 6 | SecureBridge with MPC + Optimistic + Guardian layers |
| Privacy | 3 | Stealth addresses (ERC-5564/6538) + PrivateBank |
| DeFi | 2 | PriceOracle (Chainlink/TWAP) + DEXIntegration |
| Compliance | 4 | KYC, AuditLogger, ProofOfReserve, RegulatoryRegistry |
| Subscription | 2 | ERC-7715 PermissionManager + SubscriptionManager |
| Permit2 | 8 | Signature-based token transfers |

## Deployment Script Structure

```
script/
├── DeployAll.s.sol               # Unified deployment (all 44 contracts)
├── deploy-contract/
│   ├── DeployTokens.s.sol        # USDC, wKRC
│   ├── DeployEntryPoint.s.sol    # EntryPoint
│   ├── DeployKernel.s.sol        # Kernel + KernelFactory + FactoryStaker
│   ├── DeployPaymasters.s.sol    # All paymasters
│   ├── DeployValidators.s.sol    # All validators (5)
│   ├── DeployExecutors.s.sol     # SessionKey, RecurringPayment
│   ├── DeployHooks.s.sol         # AuditHook, SpendingLimitHook
│   ├── DeployFallbacks.s.sol     # TokenReceiver, FlashLoan
│   ├── DeployPlugins.s.sol       # AutoSwap, MicroLoan, OnRamp
│   ├── DeployBridge.s.sol        # All 6 bridge components
│   ├── DeployPrivacy.s.sol       # Stealth + PrivateBank
│   ├── DeployDeFi.s.sol          # PriceOracle, DEXIntegration
│   ├── DeployCompliance.s.sol    # KYC, Audit, PoR, Regulatory
│   ├── DeployPermit2.s.sol       # Permit2
│   └── DeploySubscription.s.sol  # ERC7715 + SubscriptionManager
└── utils/
    ├── DeploymentAddresses.sol   # Address caching & JSON management
    ├── DeployConstants.sol       # Shared constants
    └── StringUtils.sol           # String utilities
```

## Deployment Order (Dependencies)

### Layer 0 (No Dependencies)

These contracts have no on-chain dependencies and can be deployed in any order.

```
Layer 0 ── No Dependencies
│
├── Tokens
│   ├── wKRC                          # No constructor args
│   └── USDC                          # constructor(owner_)
│
├── ERC-4337
│   └── EntryPoint                    # No constructor args (singleton)
│
├── Permit2
│   └── Permit2                       # No constructor args
│
├── Validators
│   ├── ECDSAValidator                # No constructor args
│   ├── WeightedECDSAValidator        # No constructor args
│   ├── MultiChainValidator           # No constructor args
│   ├── MultiSigValidator             # No constructor args
│   └── WebAuthnValidator             # No constructor args
│
├── Executors
│   ├── SessionKeyExecutor
│   └── RecurringPaymentExecutor
│
├── Hooks
│   ├── AuditHook
│   └── SpendingLimitHook
│
├── Fallbacks
│   ├── TokenReceiverFallback
│   └── FlashLoanFallback
│
├── Privacy
│   ├── ERC5564Announcer              # No constructor args
│   └── ERC6538Registry               # constructor(owner_)
│
├── Bridge (partial)
│   ├── BridgeRateLimiter             # Ownable
│   └── FraudProofVerifier            # No constructor args
│
├── DeFi
│   └── PriceOracle                   # Feeds registered post-deploy
│
├── Compliance
│   ├── KYCRegistry                   # constructor(owner_)
│   ├── AuditLogger                   # constructor(owner_)
│   ├── ProofOfReserve                # constructor(owner_)
│   └── RegulatoryRegistry            # constructor(owner_)
│
└── Subscription
    └── ERC7715PermissionManager      # constructor(owner_)
```

### Layer 1 (Depends on Layer 0)

These contracts require Layer 0 addresses as constructor parameters.

```
Layer 1 ── Depends on Layer 0
│
├── ERC-7579
│   └── Kernel (implementation)       # constructor(entryPoint)
│
├── Validators
│   └── MultiChainValidator           # constructor(owner_, kernel_)
│
├── Paymasters
│   ├── VerifyingPaymaster            # constructor(entryPoint, owner_, verifyingSigner)
│   ├── SponsorPaymaster              # constructor(entryPoint, owner_)
│   └── ERC20Paymaster                # constructor(entryPoint, owner_, priceOracle, markup)
│
├── Privacy
│   └── PrivateBank                   # constructor(announcer, registry, owner_)
│
├── Bridge
│   ├── BridgeValidator               # constructor(signers_[], threshold_)
│   ├── BridgeGuardian                # constructor(guardians_[], threshold_)
│   └── OptimisticVerifier            # constructor(challengePeriod, challengeBond, reward)
│
├── DeFi
│   └── DEXIntegration                # constructor(wKRC)
│
└── Subscription
    └── SubscriptionManager           # constructor(permissionManager, owner_)
```

### Layer 2 (Depends on Layer 1)

These contracts require Layer 1 addresses.

```
Layer 2 ── Depends on Layer 1
│
├── ERC-7579
│   └── KernelFactory                 # constructor(kernelImpl) — CREATE2 proxy
│
├── Paymasters
│   └── Permit2Paymaster              # constructor(entryPoint, owner_, priceOracle, permit2, markup)
│
└── Bridge
    └── SecureBridge                   # constructor(bridgeValidator, optimisticVerifier,
                                      #             rateLimiter, guardian, feeRecipient)
```

### Post-Deployment: Cross-Contract Wiring

Bi-directional references and configuration that cannot be set at construction time.

```
Post-Deploy ── Cross-Contract Wiring
│
├── Bridge Wiring
│   ├── OptimisticVerifier.setFraudProofVerifier(FraudProofVerifier)
│   ├── OptimisticVerifier.setAuthorizedCaller(SecureBridge)
│   ├── FraudProofVerifier.setOptimisticVerifier(OptimisticVerifier)
│   └── FraudProofVerifier.setBridgeValidator(BridgeValidator)
│
├── Token Configuration
│   ├── USDC.addMinter(paymasterAddr)        # Grant minter roles
│   ├── USDC.addMinter(bridgeAddr)
│   └── SecureBridge: map supported tokens per chain
│
├── Oracle Configuration
│   ├── PriceOracle.setChainlinkFeed(token, feedAddr)
│   └── PriceOracle.setUniswapPool(token, pool, twapPeriod, quoteToken)
│
├── Paymaster Configuration
│   ├── Paymaster.deposit() via EntryPoint    # Fund gas sponsorship
│   └── ERC20Paymaster: whitelist supported tokens
│
├── Bridge Configuration
│   ├── BridgeRateLimiter: set per-token volume caps
│   ├── BridgeGuardian: register guardian addresses
│   └── SecureBridge: enable supported chains
│
└── Privacy Configuration
    └── ERC6538Registry: register stealth meta-addresses
```

### Post-Deployment: Account-Level Setup

Per-user account creation and module installation.

```
Account Setup ── Per-Account
│
├── KernelFactory.createAccount()             # CREATE2 deterministic
├── Kernel.installValidator(ECDSAValidator)    # Authorization module
├── Kernel.installExecutor(SessionKeyExecutor) # Automation module
├── Kernel.installHook(SpendingLimitHook)      # Guard module
└── Kernel.installFallback(TokenReceiverFallback) # ERC721/1155 receipt
```

## Visual Dependency Flow

```
                    ┌─────────────┐
                    │  EntryPoint  │
                    └──────┬──────┘
              ┌────────────┼────────────────┐
              v            v                v
         ┌────────┐  ┌──────────────┐  ┌────────────────┐
         │ Kernel │  │ Verifying    │  │ Sponsor        │
         │        │  │ Paymaster    │  │ Paymaster      │
         └───┬────┘  └──────────────┘  └────────────────┘
             v
      ┌──────────────┐     ┌─────────────┐
      │ KernelFactory│     │ PriceOracle │
      └──────────────┘     └──────┬──────┘
                                  │
                      ┌───────────┼───────────┐
                      v           v           v
               ┌────────────┐ ┌──────────┐ ┌────────────────┐
               │ ERC20      │ │ Permit2  │ │ DEXIntegration │
               │ Paymaster  │ │ Paymaster│ │ (+ wKRC)       │
               └────────────┘ └──────────┘ └────────────────┘

  ┌──────────────────┐  ┌───────────────┐
  │ ERC5564Announcer │  │ ERC6538       │
  │                  │  │ Registry      │
  └────────┬─────────┘  └───────┬───────┘
           └────────┬───────────┘
                    v
             ┌─────────────┐
             │ PrivateBank  │
             └─────────────┘

  ┌───────────────┐ ┌──────────────────┐ ┌──────────────┐ ┌──────────────┐
  │ BridgeRate    │ │ FraudProof       │ │ Bridge       │ │ Bridge       │
  │ Limiter       │ │ Verifier         │ │ Validator    │ │ Guardian     │
  └───────┬───────┘ └────────┬─────────┘ └──────┬───────┘ └──────┬───────┘
          │                  │                   │                │
          │    ┌─────────────────────┐           │                │
          │    │ OptimisticVerifier  │───────────│────────────────│
          │    └──────────┬──────────┘           │                │
          │               │                      │                │
          └───────┬───────┴──────────────────────┴────────────────┘
                  v
           ┌──────────────┐
           │ SecureBridge  │ ── Post-Deploy: wire FraudProof <-> Optimistic
           └──────────────┘

  ┌──────────────────────┐
  │ ERC7715Permission    │
  │ Manager              │
  └──────────┬───────────┘
             v
  ┌──────────────────────┐
  │ SubscriptionManager  │
  └──────────────────────┘
```

## Local Deployment (Anvil)

### 1. Start Anvil

```bash
# Enable Prague hardfork (EIP-7702 support)
anvil --chain-id 31337 --block-time 1 --hardfork prague
```

### 2. Full Deployment (All Contracts)

Deploy all 44 contracts in dependency order using the unified deployment script.

```bash
forge script script/DeployAll.s.sol:DeployAllScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

This deploys all contracts across 6 phases:
- **Phase 0**: Base Infrastructure (wKRC, USDC, EntryPoint)
- **Phase 1**: Core Smart Account (Kernel, KernelFactory, FactoryStaker)
- **Phase 2**: ERC-7579 Modules (Validators, Hooks, Fallbacks, Executors)
- **Phase 3**: Feature Modules (Compliance, Privacy, Permit2)
- **Phase 4**: DeFi & Paymasters (PriceOracle, DEXIntegration, 4 Paymasters)
- **Phase 5**: Plugins (AutoSwap, MicroLoan, OnRamp)
- **Phase 6**: Subscription & Bridge

### 3. Domain-Specific Deployment

All domain scripts are located in `script/deploy-contract/`.

```bash
# Tokens (wKRC, USDC)
FOUNDRY_PROFILE=tokens forge script script/deploy-contract/DeployTokens.s.sol:DeployTokensScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# ERC-4337 EntryPoint
FOUNDRY_PROFILE=entrypoint forge script script/deploy-contract/DeployEntryPoint.s.sol:DeployEntryPointScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# ERC-7579 Kernel + Factory
FOUNDRY_PROFILE=smartaccount forge script script/deploy-contract/DeployKernel.s.sol:DeployKernelScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Validators (5 validators)
FOUNDRY_PROFILE=validators forge script script/deploy-contract/DeployValidators.s.sol:DeployValidatorsScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Paymasters (requires EntryPoint, PriceOracle)
FOUNDRY_PROFILE=paymaster forge script script/deploy-contract/DeployPaymasters.s.sol:DeployPaymastersScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Executors
FOUNDRY_PROFILE=executors forge script script/deploy-contract/DeployExecutors.s.sol:DeployExecutorsScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Hooks
FOUNDRY_PROFILE=hooks forge script script/deploy-contract/DeployHooks.s.sol:DeployHooksScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Fallbacks
FOUNDRY_PROFILE=fallbacks forge script script/deploy-contract/DeployFallbacks.s.sol:DeployFallbacksScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Plugins (AutoSwap, MicroLoan, OnRamp)
FOUNDRY_PROFILE=plugins forge script script/deploy-contract/DeployPlugins.s.sol:DeployPluginsScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Bridge (all 6 components)
FOUNDRY_PROFILE=bridge forge script script/deploy-contract/DeployBridge.s.sol:DeployBridgeScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Privacy (ERC-5564/6538 + PrivateBank)
FOUNDRY_PROFILE=privacy forge script script/deploy-contract/DeployPrivacy.s.sol:DeployPrivacyScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# DeFi (PriceOracle + DEXIntegration)
FOUNDRY_PROFILE=defi forge script script/deploy-contract/DeployDeFi.s.sol:DeployDeFiScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Compliance (KYC, AuditLogger, ProofOfReserve, RegulatoryRegistry)
FOUNDRY_PROFILE=compliance forge script script/deploy-contract/DeployCompliance.s.sol:DeployComplianceScript \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Permit2
FOUNDRY_PROFILE=permit2 forge script script/deploy-contract/DeployPermit2.s.sol:DeployPermit2Script \
  --rpc-url http://127.0.0.1:8545 --broadcast

# Subscription (ERC-7715 + SubscriptionManager)
FOUNDRY_PROFILE=subscription forge script script/deploy-contract/DeploySubscription.s.sol:DeploySubscriptionScript \
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
forge script script/DeployAll.s.sol:DeployAllScript \
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
  "wKRC": "0x...",
  "usdc": "0x...",
  "entryPoint": "0x...",
  "permit2": "0x...",
  "kernel": "0x...",
  "kernelFactory": "0x...",
  "ecdsaValidator": "0x...",
  "weightedEcdsaValidator": "0x...",
  "multiSigValidator": "0x...",
  "webAuthnValidator": "0x...",
  "multiChainValidator": "0x...",
  "verifyingPaymaster": "0x...",
  "sponsorPaymaster": "0x...",
  "erc20Paymaster": "0x...",
  "permit2Paymaster": "0x...",
  "sessionKeyExecutor": "0x...",
  "recurringPaymentExecutor": "0x...",
  "auditHook": "0x...",
  "spendingLimitHook": "0x...",
  "tokenReceiverFallback": "0x...",
  "flashLoanFallback": "0x...",
  "bridgeValidator": "0x...",
  "optimisticVerifier": "0x...",
  "bridgeRateLimiter": "0x...",
  "bridgeGuardian": "0x...",
  "fraudProofVerifier": "0x...",
  "secureBridge": "0x...",
  "erc5564Announcer": "0x...",
  "erc6538Registry": "0x...",
  "privateBank": "0x...",
  "priceOracle": "0x...",
  "dexIntegration": "0x...",
  "kycRegistry": "0x...",
  "auditLogger": "0x...",
  "proofOfReserve": "0x...",
  "regulatoryRegistry": "0x...",
  "erc7715PermissionManager": "0x...",
  "subscriptionManager": "0x..."
}
```

## Post-Deployment Configuration

### PriceOracle Feed Registration

> **IMPORTANT**: PriceOracle requires feed registration after deployment. Without registered feeds, price queries will revert with `NoPriceFeed` error.

#### Chainlink Feed Registration

```solidity
IPriceOracle oracle = IPriceOracle(PRICE_ORACLE_ADDRESS);

// ETH/USD feed
oracle.setChainlinkFeed(
    address(0),                                           // Native token
    0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419            // Chainlink ETH/USD
);

// USDC/USD feed
oracle.setChainlinkFeed(
    USDC_ADDRESS,
    0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6            // Chainlink USDC/USD
);
```

#### Uniswap V3 TWAP Registration

```solidity
oracle.setUniswapPool(
    TOKEN_ADDRESS,
    UNISWAP_POOL_ADDRESS,
    1800,                   // TWAP period (30 minutes)
    address(0)              // Quote token (address(0) = USD-pegged)
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

### Paymaster Funding

```bash
# Deposit ETH to fund paymaster via EntryPoint
cast send <ENTRYPOINT_ADDRESS> "depositTo(address)" <PAYMASTER_ADDRESS> \
  --value 10ether \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <PRIVATE_KEY>
```

### Bridge Configuration

```solidity
// 1. Wire fraud proof system
optimisticVerifier.setFraudProofVerifier(address(fraudProofVerifier));
optimisticVerifier.setAuthorizedCaller(address(secureBridge));
fraudProofVerifier.setOptimisticVerifier(address(optimisticVerifier));
fraudProofVerifier.setBridgeValidator(address(bridgeValidator));

// 2. Configure rate limits per token
bridgeRateLimiter.setTokenLimit(USDC_ADDRESS, 1_000_000e6, 24 hours);

// 3. Enable supported chains
secureBridge.enableChain(TARGET_CHAIN_ID);

// 4. Map tokens across chains
secureBridge.mapToken(USDC_ADDRESS, TARGET_CHAIN_ID, REMOTE_USDC_ADDRESS);
```

### USDC Minter Roles

```solidity
usdc.addMinter(address(secureBridge));
usdc.addMinter(address(erc20Paymaster));
```

## Key Deployment Parameters

| Parameter | PoC Value | Mainnet Value |
|-----------|-----------|---------------|
| Bridge Challenge Period | 6 hours | 24 hours |
| MPC Threshold | 5-of-7 | 5-of-7 |
| Guardian Threshold | 3-of-N | 3-of-N |
| ERC20Paymaster Markup | 10% (1000 bps) | 5-50% |
| Price Staleness | 1 hour | 1 hour |
| USDC Decimals | 6 | 6 |
| wKRC Decimals | 18 | 18 |

## Troubleshooting

### 1. CreateCollision Error

A contract is already deployed at the same address.

```bash
# Solution: Restart Anvil
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
# Layer 0: EntryPoint, Tokens, Validators, Compliance, Privacy (partial), Permit2
# Layer 1: Kernel, Paymasters, Bridge (partial), PrivateBank, DEXIntegration
# Layer 2: KernelFactory, Permit2Paymaster, SecureBridge
# Post-Deploy: Cross-contract wiring (setFraudProofVerifier, etc.)
```

### 4. PriceOracle NoPriceFeed Error

Oracle has no registered price feeds.

```bash
# Solution: Register feeds after deployment
# See "Post-Deployment Configuration > PriceOracle Feed Registration"
```
