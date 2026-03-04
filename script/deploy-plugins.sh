#!/bin/bash
# =============================================================================
# ERC-7579 Plugins Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys Plugin modules for ERC-7579 Smart Accounts:
#   - AutoSwapPlugin: Automated trading (DCA, limit orders, stop loss)
#   - MicroLoanPlugin: Collateralized micro-loans with credit scoring
#   - OnRampPlugin: Fiat on-ramp integration with KYC tracking
#
# Usage:
#   ./script/deploy-plugins.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
#
# Examples:
#   ./script/deploy-plugins.sh                     # Dry run
#   ./script/deploy-plugins.sh --broadcast         # Deploy
#   ./script/deploy-plugins.sh --broadcast --verify # Deploy + Verify
#   ./script/deploy-plugins.sh --verify            # Verify only
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
npx ts-node script/ts/deploy-plugins.ts "$@"
