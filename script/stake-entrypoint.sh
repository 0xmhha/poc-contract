#!/bin/bash
# =============================================================================
# EntryPoint Staking Script
# =============================================================================
# Wrapper script that executes the TypeScript staking code
#
# Usage:
#   ./script/stake-entrypoint.sh [--deposit=<amount>] [--stake=<amount>] [--info]
#
# Options:
#   --deposit         Amount of native token to deposit (default: 1)
#   --stake           Amount of native token to stake (default: 0)
#   --unstake-delay   Unstake delay in seconds (default: 86400)
#   --info            Show deposit info only
#
# Examples:
#   ./script/stake-entrypoint.sh --info                # Check current deposit
#   ./script/stake-entrypoint.sh --deposit=10          # Deposit 10 ETH/KRC
#   ./script/stake-entrypoint.sh --stake=1             # Stake 1 ETH/KRC
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

# Check if EntryPoint is deployed
CHAIN_ID="${CHAIN_ID:-8283}"
if [ ! -f "deployments/${CHAIN_ID}/addresses.json" ]; then
    echo "Error: Deployment addresses not found"
    echo "Please deploy EntryPoint first: ./script/deploy-entrypoint.sh --broadcast"
    exit 1
fi

# Execute TypeScript script
npx ts-node script/ts/stake-entrypoint.ts "$@"
