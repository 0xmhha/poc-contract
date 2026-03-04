#!/bin/bash
# =============================================================================
# Subscription Contracts Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys Subscription contracts (ERC-7715 Permission System):
#   - ERC7715PermissionManager: On-chain permission management
#   - SubscriptionManager: Recurring subscription payments
#   - MerchantRegistry: On-chain merchant registration
#
# Usage:
#   ./script/deploy-subscription.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
#
# Examples:
#   ./script/deploy-subscription.sh                     # Dry run
#   ./script/deploy-subscription.sh --broadcast         # Deploy
#   ./script/deploy-subscription.sh --broadcast --verify # Deploy + Verify
#   ./script/deploy-subscription.sh --verify            # Verify only
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
npx ts-node script/ts/deploy-subscription.ts "$@"
