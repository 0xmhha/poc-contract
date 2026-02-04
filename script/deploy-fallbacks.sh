#!/bin/bash
# =============================================================================
# ERC-7579 Fallbacks Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys Fallback modules for ERC-7579 Smart Accounts:
#   - TokenReceiverFallback: Handles ERC-721/1155/777 token receive callbacks
#   - FlashLoanFallback: Handles flash loan callbacks (AAVE, Uniswap, Balancer, ERC-3156)
#
# Usage:
#   ./script/deploy-fallbacks.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
#
# Examples:
#   ./script/deploy-fallbacks.sh                     # Dry run
#   ./script/deploy-fallbacks.sh --broadcast         # Deploy
#   ./script/deploy-fallbacks.sh --broadcast --verify # Deploy + Verify
#   ./script/deploy-fallbacks.sh --verify            # Verify only
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
npx ts-node script/ts/deploy-fallbacks.ts "$@"
