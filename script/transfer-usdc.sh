#!/bin/bash
# =============================================================================
# USDC Transfer Script
# =============================================================================
# Wrapper script that executes the TypeScript transfer code
#
# Usage:
#   ./script/transfer-usdc.sh [--amount=<amount>] [--to=<address>]
#
# Options:
#   --amount   Amount of USDC to transfer (default: 1000)
#   --to       Recipient address (default: derived from PRIVATE_KEY_TEST_NO_NATIVE)
#
# Examples:
#   ./script/transfer-usdc.sh                    # Transfer 1000 USDC to test account
#   ./script/transfer-usdc.sh --amount=5000      # Transfer 5000 USDC
#   ./script/transfer-usdc.sh --to=0x123...      # Transfer to specific address
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

# Check if USDC is deployed
CHAIN_ID="${CHAIN_ID:-8283}"
if [ ! -f "deployments/${CHAIN_ID}/addresses.json" ]; then
    echo "Error: Deployment addresses not found"
    echo "Please deploy tokens first: ./script/deploy-tokens.sh --broadcast"
    exit 1
fi

# Execute TypeScript transfer script
npx ts-node script/ts/transfer-usdc.ts "$@"
