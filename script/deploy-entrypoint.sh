#!/bin/bash
# =============================================================================
# EntryPoint Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Usage:
#   ./script/deploy-entrypoint.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
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
npx ts-node script/ts/deploy-entrypoint.ts "$@"
