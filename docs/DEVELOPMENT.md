# Development Guide

Guide for developing StableNet PoC contracts.

> **[한국어](./ko/DEVELOPMENT.md)**

## Development Environment Setup

### 1. Install Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 2. Clone Project and Install Dependencies

```bash
git clone <repository-url>
cd poc-contract
git submodule update --init --recursive
```

### 3. Environment Variables Setup

```bash
cp .env.example .env
# Edit .env file
```

### 4. Verify Build

```bash
forge build
```

## Project Structure

```
poc-contract/
├── src/                    # Source code
│   ├── erc4337-*/          # ERC-4337 related
│   ├── erc7579-*/          # ERC-7579 related
│   ├── privacy/            # Privacy
│   ├── compliance/         # Regulatory compliance
│   ├── tokens/             # Tokens
│   └── defi/               # DeFi
├── test/                   # Tests
├── script/                 # Deployment scripts
│   ├── deploy/             # Category-based deployment
│   └── utils/              # Utilities
├── lib/                    # External dependencies
├── docs/                   # Documentation
├── deployments/            # Deployment results
└── foundry.toml            # Foundry configuration
```

## Coding Conventions

### Naming

```solidity
// Contract: PascalCase
contract MyContract {}

// Function: camelCase
function myFunction() public {}

// Constant: UPPER_SNAKE_CASE
uint256 public constant MAX_VALUE = 100;

// Internal function: _camelCase
function _internalFunction() internal {}

// Event: PascalCase
event MyEvent(address indexed user);

// Error: PascalCase
error MyError();
```

### File Structure

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// 1. Imports
import {Contract} from "./Contract.sol";

// 2. Interfaces
interface IMyContract {}

// 3. Libraries
library MyLibrary {}

// 4. Contracts
contract MyContract {
    // 4.1 Type declarations
    // 4.2 State variables
    // 4.3 Events
    // 4.4 Errors
    // 4.5 Modifiers
    // 4.6 Constructor
    // 4.7 External functions
    // 4.8 Public functions
    // 4.9 Internal functions
    // 4.10 Private functions
}
```

### NatSpec Documentation

```solidity
/**
 * @title MyContract
 * @notice User-facing description
 * @dev Developer-facing detailed description
 */
contract MyContract {
    /**
     * @notice Function description
     * @param value Parameter description
     * @return Return value description
     */
    function myFunction(uint256 value) public returns (uint256) {
        // ...
    }
}
```

## Writing Tests

### Test File Structure

```
test/
├── unit/                   # Unit tests
│   ├── Kernel.t.sol
│   └── Paymaster.t.sol
├── integration/            # Integration tests
│   └── UserOperation.t.sol
└── invariant/              # Invariant tests
    └── EntryPoint.invariant.t.sol
```

### Test Example

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Kernel} from "../src/erc7579-smartaccount/Kernel.sol";

contract KernelTest is Test {
    Kernel public kernel;
    address public owner;

    function setUp() public {
        owner = makeAddr("owner");
        // Initialize
    }

    function test_Initialize() public {
        // Given
        // When
        // Then
    }

    function testFuzz_Transfer(uint256 amount) public {
        vm.assume(amount > 0 && amount < 1e18);
        // Fuzz test
    }

    function testRevert_InvalidOwner() public {
        vm.expectRevert();
        // Failure case test
    }
}
```

### Running Tests

```bash
# All tests
forge test

# Verbose logs
forge test -vvv

# Specific test
forge test --match-test test_Initialize

# Specific contract
forge test --match-contract KernelTest

# Gas report
forge test --gas-report

# Coverage
forge coverage
```

## Writing Deployment Scripts

### Basic Structure

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {DeploymentHelper} from "./utils/DeploymentAddresses.sol";
import {MyContract} from "../src/MyContract.sol";

contract DeployMyContractScript is DeploymentHelper {
    function run() public {
        _initDeployment();

        vm.startBroadcast();

        MyContract myContract = new MyContract();
        _setAddress("myContract", address(myContract));
        console.log("MyContract:", address(myContract));

        vm.stopBroadcast();

        _saveAddresses();
    }
}
```

### Running Deployment

```bash
# Local deployment
forge script script/DeployMyContract.s.sol:DeployMyContractScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

# Testnet deployment (with verification)
forge script script/DeployMyContract.s.sol:DeployMyContractScript \
  --rpc-url $RPC_URL_SEPOLIA \
  --broadcast \
  --verify
```

## Debugging

### Console Logs

```solidity
import {console} from "forge-std/console.sol";

function myFunction() public {
    console.log("Value:", someValue);
    console.logAddress(msg.sender);
    console.logBytes32(keccak256("data"));
}
```

### Trace

```bash
# Transaction trace
cast run <TX_HASH> --rpc-url http://127.0.0.1:8545

# Debug mode
forge test --debug test_MyFunction
```

### Anvil Debugging

```bash
# Start Anvil with verbose logs
anvil --chain-id 31337 --hardfork prague -vvv

# Check specific block state
cast call <CONTRACT> "balanceOf(address)" <ADDRESS> \
  --rpc-url http://127.0.0.1:8545
```

## Gas Optimization

### Gas Report

```bash
forge test --gas-report
```

### Optimization Tips

1. **Storage Optimization**
   ```solidity
   // Bad
   uint256 a; // slot 0
   uint256 b; // slot 1
   uint128 c; // slot 2

   // Good
   uint256 a; // slot 0
   uint128 b; // slot 1
   uint128 c; // slot 1 (packed)
   ```

2. **Use Calldata**
   ```solidity
   // Bad
   function process(bytes memory data) external {}

   // Good
   function process(bytes calldata data) external {}
   ```

3. **Custom Errors**
   ```solidity
   // Bad
   require(x > 0, "Must be positive");

   // Good
   error MustBePositive();
   if (x == 0) revert MustBePositive();
   ```

## Foundry Profiles

### fast Profile (Development)

```bash
forge build --profile fast
forge test --profile fast
```

Fast builds with IR disabled and reduced optimizer runs.

### default Profile (Production)

```bash
forge build
```

Generates optimized bytecode.

## CI/CD

### GitHub Actions Example

```yaml
name: CI

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1

      - name: Build
        run: forge build

      - name: Test
        run: forge test -vvv

      - name: Gas Report
        run: forge test --gas-report
```

## Useful Commands

```bash
# Check contract sizes
forge build --sizes

# Generate ABI
forge inspect MyContract abi

# Storage layout
forge inspect MyContract storage

# Generate bytecode
forge inspect MyContract bytecode

# Formatting
forge fmt

# Lint
forge lint

# Generate docs
forge doc
```

## References

- [Foundry Book](https://book.getfoundry.sh/)
- [ERC-4337 Spec](https://eips.ethereum.org/EIPS/eip-4337)
- [ERC-7579 Spec](https://eips.ethereum.org/EIPS/eip-7579)
- [ERC-5564 Spec](https://eips.ethereum.org/EIPS/eip-5564)
- [ERC-6538 Spec](https://eips.ethereum.org/EIPS/eip-6538)
