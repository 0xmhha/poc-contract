#!/bin/bash
# =============================================================================
# ERC-7579 Hooks Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys Hook modules for ERC-7579 Smart Accounts:
#   - SpendingLimitHook: Enforces spending limits per token with time-based windows
#   - AuditHook: Logs all transactions for compliance and audit purposes
#
# Usage:
#   ./script/deploy-hooks.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
#
# Examples:
#   ./script/deploy-hooks.sh                     # Dry run
#   ./script/deploy-hooks.sh --broadcast         # Deploy
#   ./script/deploy-hooks.sh --broadcast --verify # Deploy + Verify
#   ./script/deploy-hooks.sh --verify            # Verify only
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
npx ts-node script/ts/deploy-hooks.ts "$@"
