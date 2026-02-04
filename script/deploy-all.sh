#!/bin/bash
# =============================================================================
# Full Deployment Script
# =============================================================================
# Deploys all contracts and configures paymasters in the correct order.
#
# Deployment Order:
#   Phase 0: Tokens (wKRC, USDC), EntryPoint
#   Phase 1: Smart Account (Kernel, KernelFactory, FactoryStaker)
#   Phase 2: Modules (Validators, Hooks, Fallbacks, Executors)
#   Phase 3: Features (Compliance, Privacy, Permit2)
#   Phase 4: DeFi (UniswapV3, DeFi, Paymasters)
#   Config:  Paymaster staking, token support, whitelist
#
# Usage:
#   ./script/deploy-all.sh [options]
#
# Options:
#   --dry-run              Show what would be executed without running
#   --skip-deploy          Skip deployment, only run configuration
#   --skip-config          Skip configuration, only run deployment
#   --from=<step>          Start from specific step (e.g., --from=defi)
#   --verify               Enable contract verification
#   --force                Force redeploy even if contracts exist
#   --addresses            Show deployed contract addresses only (for DApp)
#
# Examples:
#   ./script/deploy-all.sh                    # Full deployment
#   ./script/deploy-all.sh --dry-run          # Show plan
#   ./script/deploy-all.sh --from=paymasters  # Start from paymasters
#   ./script/deploy-all.sh --skip-deploy      # Config only
#   ./script/deploy-all.sh --verify           # Deploy + verify
#   ./script/deploy-all.sh --addresses        # Show all deployed addresses
#
# Available Steps:
#   tokens, transfer-usdc, entrypoint, smartaccount,
#   validators, hooks, fallbacks, executors,
#   compliance, privacy, permit2,
#   uniswap, defi, paymasters,
#   stake-paymaster, add-token, whitelist, info
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
npx ts-node script/ts/deploy-all.ts "$@"
