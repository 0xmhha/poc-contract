# Architecture

Documentation for the structure and design of StableNet PoC contracts.

> **[한국어](./ko/ARCHITECTURE.md)**

## Overall Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     User / DApp                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    ERC-4337 Layer                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  EntryPoint │  │  Paymaster  │  │      Bundler        │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    ERC-7579 Layer                            │
│  ┌─────────────────────────────────────────────────────────┐│
│  │                    Kernel (Smart Account)                ││
│  │  ┌───────────┐ ┌───────────┐ ┌───────┐ ┌───────────┐   ││
│  │  │ Validator │ │ Executor  │ │ Hook  │ │ Fallback  │   ││
│  │  └───────────┘ └───────────┘ └───────┘ └───────────┘   ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Application Layer                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   Privacy   │  │ Compliance  │  │       DeFi          │  │
│  │  (Stealth)  │  │  (KYC/AML)  │  │  (Tokens, Oracle)   │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## ERC-4337 Account Abstraction

### EntryPoint

The entry point for UserOperations, processing all AA transactions.

```
src/erc4337-entrypoint/
├── EntryPoint.sol           # Main entry point
├── SenderCreator.sol        # Account creation helper
├── StakeManager.sol         # Staking management
└── interfaces/
    ├── IEntryPoint.sol
    ├── IAccount.sol
    └── IPaymaster.sol
```

**Key Functions:**
- `handleOps()`: Batch process UserOperations
- `simulateValidation()`: Validation simulation
- `depositTo()`: Paymaster deposit management

### Paymaster

Contracts that pay gas fees on behalf of users.

```
src/erc4337-paymaster/
├── BasePaymaster.sol        # Base Paymaster
├── VerifyingPaymaster.sol   # Signature-based verification
├── ERC20Paymaster.sol       # ERC20 token payment
└── interfaces/
    └── IPriceOracle.sol
```

**VerifyingPaymaster Flow:**
```
1. User → Request signature from Paymaster server
2. Paymaster server → Verify conditions and return signature
3. User → Include paymasterAndData in UserOperation
4. EntryPoint → Call Paymaster.validatePaymasterUserOp()
5. Paymaster → Verify signature and pay gas
```

## ERC-7579 Modular Smart Account

### Kernel

Modular smart account implementation.

```
src/erc7579-smartaccount/
├── Kernel.sol               # Main smart account
├── factory/
│   └── KernelFactory.sol    # Account creation factory
├── types/
│   └── Types.sol            # Type definitions
└── interfaces/
    ├── IKernel.sol
    └── IERC7579*.sol
```

**Module Types:**

| Type | Role | Interface |
|------|------|-----------|
| Validator | Transaction signature verification | `IValidator` |
| Executor | Transaction execution | `IExecutor` |
| Hook | Pre/post execution logic | `IHook` |
| Fallback | Fallback function handling | `IFallback` |

### Validators

Modules that verify transaction signatures.

```
src/erc7579-validators/
├── ECDSAValidator.sol           # Single ECDSA signature
├── WeightedECDSAValidator.sol   # Weighted multisig
├── MultiChainValidator.sol      # Multi-chain signatures
├── MultiSigValidator.sol        # Multi-signature validation
└── WebAuthnValidator.sol        # WebAuthn/Passkey validation
```

**ECDSAValidator:**
- Single owner ECDSA signature verification
- Most basic validation method

**WeightedECDSAValidator:**
- Assigns weights to multiple signers
- Requires threshold weight to be met

**MultiSigValidator:**
- Multi-party signature validation
- Configurable threshold (m-of-n)

**WebAuthnValidator:**
- WebAuthn/Passkey authentication support
- Requires P256 (secp256r1) curve verification

### Executors

Modules that execute transactions.

```
src/erc7579-executors/
├── SessionKeyExecutor.sol       # Session key-based execution
└── RecurringPaymentExecutor.sol # Recurring payments
```

**SessionKeyExecutor:**
- Issue session keys with limited permissions
- Time/amount/target restrictions possible

### Hooks

Modules called before/after execution.

```
src/erc7579-hooks/
├── AuditHook.sol           # Audit logging
└── SpendingLimitHook.sol   # Spending limits
```

**SpendingLimitHook:**
- Set daily/monthly spending limits
- Reject transactions exceeding limits

### Fallbacks

Modules that handle fallback functions.

```
src/erc7579-fallbacks/
├── TokenReceiverFallback.sol   # ERC721/1155 receiver
└── FlashLoanFallback.sol       # Flash loan support
```

## Privacy (ERC-5564/6538)

Stealth address-based privacy system.

```
src/privacy/
├── ERC5564Announcer.sol    # Stealth address announcements
├── ERC6538Registry.sol     # Meta address registry
└── PrivateBank.sol         # Private deposits/withdrawals
```

### Stealth Address Flow

```
┌──────────────────────────────────────────────────────────────┐
│ 1. Recipient: Register stealth meta address                   │
│    Registry.registerKeys(spendingPubKey, viewingPubKey)      │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. Sender: Generate stealth address                           │
│    stealthAddress = generateStealthAddress(metaAddress)       │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Sender: Transfer funds + announce                          │
│    transfer(stealthAddress, amount)                           │
│    Announcer.announce(ephemeralPubKey, metadata)             │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Recipient: Scan announcements and claim funds              │
│    for announcement in Announcer.getAnnouncements():          │
│        if canDecrypt(announcement): claimFunds()              │
└──────────────────────────────────────────────────────────────┘
```

## Compliance

Contracts for regulatory compliance.

```
src/compliance/
├── KYCRegistry.sol          # KYC status management
├── AuditLogger.sol          # Audit logging
├── ProofOfReserve.sol       # Proof of reserves
└── RegulatoryRegistry.sol   # Regulator registration and trace approvals
```

### KYCRegistry

```solidity
enum KYCLevel {
    NONE,        // Not verified
    BASIC,       // Basic verification
    ADVANCED,    // Advanced verification
    INSTITUTIONAL // Institutional verification
}
```

### AuditLogger

Records immutable audit logs.

```solidity
struct AuditLog {
    address account;
    bytes32 action;
    bytes data;
    uint256 timestamp;
}
```

### ProofOfReserve

On-chain proof of reserves.

```solidity
struct Reserve {
    address asset;
    uint256 amount;
    bytes32 proof;
    uint256 timestamp;
}
```

## Contract Dependency Graph

```
                    ┌─────────────┐
                    │  EntryPoint │
                    └──────┬──────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
    ┌──────────┐    ┌──────────┐    ┌──────────────┐
    │  Kernel  │    │Paymaster │    │ERC20Paymaster│
    └────┬─────┘    └──────────┘    └──────┬───────┘
         │                                  │
         ▼                                  ▼
    ┌──────────┐                      ┌──────────┐
    │  Factory │                      │  Oracle  │
    └──────────┘                      └──────────┘

    ┌──────────┐    ┌──────────┐
    │Announcer │◄───│PrivateBank│
    └──────────┘    └──────────┘
         ▲               │
         └───────────────┘
              Registry
```

## Security Considerations

### 1. Access Control
- All admin functions use `onlyOwner` or role-based access control
- Module installation/removal only by account owner

### 2. Reentrancy Protection
- Use `ReentrancyGuard`
- State changes before external calls

### 3. Signature Verification
- Use EIP-712 typed hashes
- Replay attack prevention (nonce, chainId)

### 4. Upgrades
- Kernel uses no proxy pattern (immutable)
- Functionality upgrades via module replacement
