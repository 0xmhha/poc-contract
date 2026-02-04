#!/bin/bash
# =============================================================================
# FactoryStaker Staking Script
# =============================================================================
# Wrapper script that executes the TypeScript staking code
#
# Stakes FactoryStaker in EntryPoint for reputation and approves KernelFactory
#
# Usage:
#   ./script/stake-factory.sh [--stake=<amount>] [--unstake-delay=<seconds>] [--approve] [--info]
#
# Options:
#   --stake           Amount of native token to stake (default: 1)
#   --unstake-delay   Unstake delay in seconds (default: 86400)
#   --approve         Approve KernelFactory in FactoryStaker
#   --info            Show stake info only
#
# Examples:
#   ./script/stake-factory.sh --info                  # Check current stake
#   ./script/stake-factory.sh --stake=1              # Stake 1 ETH/KRC
#   ./script/stake-factory.sh --approve              # Approve KernelFactory
#   ./script/stake-factory.sh --stake=1 --approve    # Stake + Approve
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

# Check if Smart Account is deployed
CHAIN_ID="${CHAIN_ID:-8283}"
if [ ! -f "deployments/${CHAIN_ID}/addresses.json" ]; then
    echo "Error: Deployment addresses not found"
    echo "Please deploy Smart Account first: ./script/deploy-smartaccount.sh --broadcast"
    exit 1
fi

# Execute TypeScript script
npx ts-node script/ts/stake-factory.ts "$@"
