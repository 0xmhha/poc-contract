#!/bin/bash
# =============================================================================
# Permit2 Contract Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys Uniswap's Permit2 for signature-based token transfers:
#   - SignatureTransfer: One-time permit signatures for token transfers
#   - AllowanceTransfer: Persistent allowances with expiration
#   - EIP-712: Cross-chain replay protection
#
# Usage:
#   ./script/deploy-permit2.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
#
# Examples:
#   ./script/deploy-permit2.sh                     # Dry run
#   ./script/deploy-permit2.sh --broadcast         # Deploy
#   ./script/deploy-permit2.sh --broadcast --verify # Deploy + Verify
#   ./script/deploy-permit2.sh --verify            # Verify only
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
npx ts-node script/ts/deploy-permit2.ts "$@"
