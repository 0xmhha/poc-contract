#!/bin/bash
# =============================================================================
# DeFi Contracts Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys DeFi modules:
#   - PriceOracle: Unified price oracle supporting Chainlink feeds and Uniswap V3 TWAP
#   - LendingPool: Collateral-based lending pool with variable interest rates
#   - StakingVault: Staking vault with time-locked rewards
#
# Usage:
#   ./script/deploy-defi.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
#
# Environment Variables:
#   STAKING_TOKEN: Token to stake (defaults to WKRC/NativeCoinAdapter at 0x1000)
#   REWARD_TOKEN: Token for rewards (defaults to same as staking token)
#   REWARD_RATE: Rewards per second (default: 1e15 = 0.001 tokens/sec)
#   LOCK_PERIOD: Lock period in seconds (default: 7 days)
#   EARLY_WITHDRAW_PENALTY: Penalty in basis points (default: 1000 = 10%)
#   MIN_STAKE: Minimum stake amount (default: 1e18 = 1 token)
#   MAX_STAKE: Maximum stake amount (default: 0 = unlimited)
#
# Examples:
#   ./script/deploy-defi.sh                     # Dry run
#   ./script/deploy-defi.sh --broadcast         # Deploy
#   ./script/deploy-defi.sh --broadcast --verify # Deploy + Verify
#   ./script/deploy-defi.sh --verify            # Verify only
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
npx ts-node script/ts/deploy-defi.ts "$@"
