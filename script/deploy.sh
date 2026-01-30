#!/bin/bash
# =============================================================================
# StableNet Contract Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Usage:
#   ./script/deploy.sh [--broadcast] [--verify] [--plan] [--steps=<steps>]
#
# Examples:
#   ./script/deploy.sh --plan                          # Show deployment plan
#   ./script/deploy.sh --broadcast                     # Deploy all contracts
#   ./script/deploy.sh --broadcast --steps=tokens,kernel  # Deploy specific steps
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

# Execute TypeScript deployment script
npx ts-node script/ts/deploy.ts "$@"
