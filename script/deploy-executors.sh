#!/bin/bash
# =============================================================================
# ERC-7579 Executors Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys Executor modules for ERC-7579 Smart Accounts:
#   - SessionKeyExecutor: Temporary session keys with time/target/function restrictions
#   - RecurringPaymentExecutor: Automated recurring payments (subscriptions, salary, etc.)
#
# Usage:
#   ./script/deploy-executors.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
#
# Examples:
#   ./script/deploy-executors.sh                     # Dry run
#   ./script/deploy-executors.sh --broadcast         # Deploy
#   ./script/deploy-executors.sh --broadcast --verify # Deploy + Verify
#   ./script/deploy-executors.sh --verify            # Verify only
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
npx ts-node script/ts/deploy-executors.ts "$@"
