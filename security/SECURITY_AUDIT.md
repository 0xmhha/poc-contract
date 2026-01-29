# StableNet Security Audit Guide

This document describes the security audit setup and process for the StableNet PoC contracts.

## Quick Start

```bash
# Install dependencies
pip install slither-analyzer mythril

# Run full security audit
./security/run-audit.sh --all

# Run Slither only
./security/run-audit.sh --slither

# Run Mythril on specific contract
./security/run-audit.sh --mythril -c src/subscription/SubscriptionManager.sol
```

## Tools

### 1. Slither (Static Analysis)

Slither is a Solidity static analysis framework by Trail of Bits. It detects:
- Reentrancy vulnerabilities
- Uninitialized storage variables
- Integer overflow/underflow
- Access control issues
- State variable shadowing
- Dangerous delegatecall usage

**Configuration:** `slither.config.json`

```bash
# Run Slither manually
slither . --json security/slither-report.json
```

### 2. Mythril (Symbolic Execution)

Mythril is a security analysis tool for EVM bytecode by ConsenSys. It detects:
- Integer overflow/underflow
- Reentrancy
- Unprotected selfdestruct
- Unprotected ether withdrawal
- Transaction-order dependence (TOD)

**Configuration:** `security/mythril.yaml`

```bash
# Run Mythril manually
myth analyze src/subscription/SubscriptionManager.sol -o json > mythril-report.json
```

## Contracts in Scope

### High Priority (Core Business Logic)

| Contract | Path | Risk Level |
|----------|------|------------|
| SubscriptionManager | `src/subscription/SubscriptionManager.sol` | High |
| ERC7715PermissionManager | `src/subscription/ERC7715PermissionManager.sol` | High |
| RecurringPaymentExecutor | `src/subscription/RecurringPaymentExecutor.sol` | High |

### Medium Priority (Financial Operations)

| Contract | Path | Risk Level |
|----------|------|------------|
| StealthVault | `src/privacy/enterprise/StealthVault.sol` | Medium |
| WithdrawalManager | `src/privacy/enterprise/WithdrawalManager.sol` | Medium |
| SecureBridge | `src/bridge/SecureBridge.sol` | Medium |

### Lower Priority (Support Contracts)

| Contract | Path | Risk Level |
|----------|------|------------|
| StealthLedger | `src/privacy/enterprise/StealthLedger.sol` | Low |
| RoleManager | `src/privacy/enterprise/RoleManager.sol` | Low |
| BridgeValidator | `src/bridge/BridgeValidator.sol` | Low |

## Severity Levels

| Severity | Description | Action Required |
|----------|-------------|-----------------|
| **Critical** | Direct theft of funds, contract destruction | Immediate fix before any deployment |
| **High** | Potential fund loss, access control bypass | Fix before mainnet deployment |
| **Medium** | Logic errors, DoS vulnerabilities | Fix in next development cycle |
| **Low** | Code quality, gas optimization | Document and address as time permits |
| **Informational** | Best practices, suggestions | Review for improvement |

## Common Vulnerability Patterns

### 1. Reentrancy

Check all external calls follow the checks-effects-interactions pattern:

```solidity
// Good ✅
balances[msg.sender] = 0;  // Effect first
(bool success,) = msg.sender.call{value: amount}("");  // Interaction last

// Bad ❌
(bool success,) = msg.sender.call{value: amount}("");
balances[msg.sender] = 0;  // Effect after interaction
```

### 2. Access Control

Verify all privileged functions have proper access control:

```solidity
// Good ✅
function withdraw() external onlyOwner { ... }

// Bad ❌
function withdraw() external { ... }  // Missing access control
```

### 3. Integer Overflow

Use OpenZeppelin's SafeMath or Solidity 0.8+ built-in checks:

```solidity
// Good ✅ (Solidity 0.8+)
uint256 result = a + b;  // Reverts on overflow

// Good ✅ (explicit unchecked for gas optimization)
unchecked { uint256 result = a + b; }  // Only when overflow is impossible
```

### 4. Input Validation

Always validate external inputs:

```solidity
// Good ✅
function setRecipient(address recipient) external {
    require(recipient != address(0), "Invalid address");
    _recipient = recipient;
}
```

## Output Reports

Reports are saved to `security/reports/`:

```
security/reports/
├── slither-20260128_120000.json     # Slither JSON report
├── slither-20260128_120000.md       # Slither text report
├── mythril-SubscriptionManager-20260128_120000.json
├── mythril-StealthVault-20260128_120000.json
└── security-audit-20260128_120000.md  # Combined report
```

## CI/CD Integration

Add to your GitHub Actions workflow:

```yaml
- name: Run Security Audit
  run: |
    pip install slither-analyzer
    ./security/run-audit.sh --slither
```

## Manual Audit Checklist

After automated analysis, manually verify:

- [ ] **Business Logic**: Are all business rules correctly implemented?
- [ ] **Access Control**: Are all privileged functions properly protected?
- [ ] **Token Handling**: Are all token transfers safe (CEI pattern)?
- [ ] **External Calls**: Are all external calls handled safely?
- [ ] **Upgradability**: Are proxy patterns correctly implemented?
- [ ] **Economic Attacks**: Is the contract resistant to flash loan attacks?
- [ ] **Oracle Manipulation**: Are price oracles resistant to manipulation?
- [ ] **Frontrunning**: Are there frontrunning vulnerabilities?
- [ ] **DoS**: Can the contract be permanently locked?
- [ ] **Timestamp Dependence**: Are block.timestamp uses safe?

## Resources

- [Slither Documentation](https://github.com/crytic/slither)
- [Mythril Documentation](https://mythril-classic.readthedocs.io/)
- [Smart Contract Weakness Classification (SWC)](https://swcregistry.io/)
- [ConsenSys Smart Contract Best Practices](https://consensys.github.io/smart-contract-best-practices/)
- [OpenZeppelin Security](https://www.openzeppelin.com/security-audits)
