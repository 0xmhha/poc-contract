# NOTICE

This project includes code derived from or inspired by the following open-source projects.
All original copyrights and licenses are respected.

## Source Contract References (`src/`)

### ERC-4337 EntryPoint (`src/erc4337-entrypoint/`)

Based on the ERC-4337 reference implementation by the Ethereum Foundation.

- **Source**: https://github.com/eth-infinitism/account-abstraction
- **License**: GPL-3.0 (EntryPoint, StakeManager, NonceManager, SenderCreator); MIT (interfaces, helpers, UserOperationLib)
- **Copyright**: Copyright (c) 2023 Ethereum Foundation

Vendored OpenZeppelin utilities (`src/erc4337-entrypoint/vendor/openzeppelin/`) are from:

- **Source**: https://github.com/OpenZeppelin/openzeppelin-contracts (v5.x)
- **License**: MIT
- **Copyright**: Copyright (c) 2016-2025 Zeppelin Group Ltd

### ERC-4337 Paymaster (`src/erc4337-paymaster/`)

Paymaster patterns inspired by the ERC-4337 ecosystem.

- **Reference**: https://github.com/eth-infinitism/account-abstraction
- **License**: MIT
- **Copyright**: Copyright (c) 2023 Ethereum Foundation

### ERC-7579 Modular Smart Account (`src/erc7579-smartaccount/`)

Based on the Kernel smart account implementation by ZeroDev.

- **Source**: https://github.com/zerodevapp/kernel
- **License**: MIT
- **Copyright**: Copyright (c) 2023 ZeroDev

ERC-4337 interfaces within this module are licensed under GPL-3.0 per their original source.

### ERC-7579 Validators (`src/erc7579-validators/`)

Validator module patterns inspired by the Kernel ecosystem.

- **Reference**: https://github.com/zerodevapp/kernel
- **License**: MIT
- **Copyright**: Copyright (c) 2023 ZeroDev

### ERC-7579 Executors (`src/erc7579-executors/`)

Executor module patterns inspired by the ERC-7579 modular account standard.

- **Reference**: https://eips.ethereum.org/EIPS/eip-7579
- **License**: MIT

### ERC-7579 Hooks (`src/erc7579-hooks/`)

Hook module patterns following the ERC-7579 specification.

- **Reference**: https://eips.ethereum.org/EIPS/eip-7579
- **License**: MIT

### ERC-7579 Fallbacks (`src/erc7579-fallbacks/`)

Fallback handler patterns following the ERC-7579 specification.

- **Reference**: https://eips.ethereum.org/EIPS/eip-7579
- **License**: MIT

### ERC-7579 Plugins (`src/erc7579-plugins/`)

Plugin patterns for modular smart accounts.

- **Reference**: https://eips.ethereum.org/EIPS/eip-7579
- **License**: MIT

### Permit2 (`src/permit2/`)

Based on the Permit2 token approval system by Uniswap Labs.

- **Source**: https://github.com/Uniswap/permit2
- **License**: MIT
- **Copyright**: Copyright (c) 2022 Uniswap Labs

### Privacy / Stealth Addresses (`src/privacy/`)

Implements ERC-5564 (Stealth Addresses) and ERC-6538 (Stealth Meta-Address Registry).

- **Reference**: https://eips.ethereum.org/EIPS/eip-5564
- **Reference**: https://eips.ethereum.org/EIPS/eip-6538
- **License**: MIT

### DeFi Components (`src/defi/`)

DeFi integration referencing Uniswap V3 interfaces.

- **Reference**: https://github.com/Uniswap/v3-core
- **License**: BUSL-1.1 (core contracts, converting to GPL-2.0-or-later after change date)
- **Copyright**: Copyright (c) 2021 Uniswap Labs

Interface patterns also reference:

- **Reference**: https://github.com/Uniswap/v3-periphery
- **License**: GPL-2.0-or-later
- **Copyright**: Copyright (c) 2021 Uniswap Labs

### Subscription (`src/subscription/`)

Implements ERC-7715 Permission Manager pattern.

- **Reference**: https://eips.ethereum.org/EIPS/eip-7715
- **License**: MIT

### Tokens (`src/tokens/`)

ERC-20 token implementations referencing OpenZeppelin patterns.

- **Reference**: https://github.com/OpenZeppelin/openzeppelin-contracts
- **License**: MIT
- **Copyright**: Copyright (c) 2016-2025 Zeppelin Group Ltd

### Compliance (`src/compliance/`)

Original implementation for regulatory compliance.

- **License**: MIT

### Bridge (`src/bridge/`)

Original cross-chain bridge implementation with defense-in-depth security.

- **License**: MIT

---

## Library Dependencies (`lib/`)

### OpenZeppelin Contracts (v5.x)

- **Source**: https://github.com/OpenZeppelin/openzeppelin-contracts
- **License**: MIT
- **Copyright**: Copyright (c) 2016-2025 Zeppelin Group Ltd

### OpenZeppelin Contracts (v3.x)

- **Source**: https://github.com/OpenZeppelin/openzeppelin-contracts
- **License**: MIT
- **Copyright**: Copyright (c) 2016-2020 zOS Global Limited

### Solady

- **Source**: https://github.com/Vectorized/solady
- **License**: MIT
- **Copyright**: Copyright (c) 2022-2025 Solady

### Solmate

- **Source**: https://github.com/transmissions11/solmate
- **License**: AGPL-3.0-only (per-file SPDX identifiers apply)
- **Copyright**: Copyright (c) 2021 Transmissions11

### Forge Standard Library

- **Source**: https://github.com/foundry-rs/forge-std
- **License**: MIT OR Apache-2.0
- **Copyright**: Copyright Contributors to Forge Standard Library

### base64-sol

- **Source**: https://github.com/Brechtpd/base64
- **License**: MIT
- **Copyright**: Copyright (c) 2021 Brecht Devos

### ExcessivelySafeCall

- **Source**: https://github.com/nomad-xyz/ExcessivelySafeCall
- **License**: MIT OR Apache-2.0
- **Copyright**: Copyright (c) 2022 Nomad XYZ

### Uniswap V2 Core

- **Source**: https://github.com/Uniswap/v2-core
- **License**: GPL-3.0
- **Copyright**: Copyright (c) 2020 Uniswap Labs

### Uniswap V3 Core

- **Source**: https://github.com/Uniswap/v3-core
- **License**: BUSL-1.1 (converts to GPL-2.0-or-later after change date)
- **Copyright**: Copyright (c) 2021 Uniswap Labs

### Uniswap V3 Periphery

- **Source**: https://github.com/Uniswap/v3-periphery
- **License**: GPL-2.0-or-later
- **Copyright**: Copyright (c) 2021 Uniswap Labs

### Uniswap V4 Core

- **Source**: https://github.com/Uniswap/v4-core
- **License**: BUSL-1.1 (core contracts); MIT (interfaces, libraries)
- **Copyright**: Copyright (c) 2023 Uniswap Labs

### Uniswap V4 Periphery

- **Source**: https://github.com/Uniswap/v4-periphery
- **License**: MIT
- **Copyright**: Copyright (c) 2023 Universal Navigation Inc.

### Uniswap Lib

- **Source**: https://github.com/Uniswap/solidity-lib
- **License**: GPL-3.0
- **Copyright**: Copyright (c) 2020 Uniswap Labs

---

## License Compatibility Note

This project is licensed under **GPL-3.0** (`LICENSE`).

The inclusion of GPL-3.0 licensed components (ERC-4337 EntryPoint, Uniswap V2/V3)
and AGPL-3.0 components (Solmate) requires the overall project license to be
GPL-3.0-compatible. The BUSL-1.1 licensed Uniswap V3/V4 core contracts are used
as interface references only. All MIT and Apache-2.0 licensed components are
compatible with GPL-3.0.
