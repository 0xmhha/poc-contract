#!/bin/bash
# =============================================================================
# Quick Start Deployment Script
# =============================================================================
# Deploys the MINIMUM contracts for "asset transfer via ERC-4337 + ERC-7579
# smart account with ERC-20 gas payment" PoC.
#
# Contracts Deployed (12 core):
#   Phase 0: USDC (test token)
#   Phase 1: EntryPoint (ERC-4337)
#   Phase 2: Kernel, KernelFactory, FactoryStaker (ERC-7579 Smart Account)
#   Phase 3: ECDSAValidator (signature validation)
#   Phase 4: PriceOracle (token price for gas conversion)
#   Phase 5: ERC20Paymaster (pay gas with USDC)
#   Config:  FixedPriceAggregator + oracle price + paymaster setup
#
# vs deploy-all.sh:
#   - Skips: Bridge, Privacy, Compliance, Subscription, Permit2,
#            UniswapV3, Plugins, Hooks, Fallbacks, Executors
#   - 9 steps instead of 19 (50%+ faster)
#
# Usage:
#   ./script/deploy-quick-start.sh [options]
#
# Options:
#   --dry-run              Show what would be executed without running
#   --verify               Enable contract verification
#   --force                Force redeploy even if contracts exist
#   --from=<step>          Start from specific step
#   --addresses            Show deployed contract addresses only
#   --skip-config          Skip configuration, only run deployment
#
# Examples:
#   ./script/deploy-quick-start.sh                    # Full quick start
#   ./script/deploy-quick-start.sh --dry-run          # Show plan
#   ./script/deploy-quick-start.sh --from=paymasters  # Resume from paymasters
#   ./script/deploy-quick-start.sh --addresses        # Show addresses
#
# Available Steps:
#   tokens, transfer-usdc, entrypoint, smartaccount,
#   validators, defi, paymasters,
#   setup-oracle-price, setup-paymaster
# =============================================================================

set -e

# Navigate to project root
cd "$(dirname "$0")/.."

# Check if .env exists
if [ ! -f ".env" ]; then
    echo "Error: .env file not found"
    echo "Please copy .env.example to .env and configure it"
    exit 1
fi

# Execute TypeScript script
npx ts-node script/ts/deploy-quick-start.ts "$@"
