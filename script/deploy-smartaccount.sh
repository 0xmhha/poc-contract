#!/bin/bash
# =============================================================================
# Smart Account (Kernel) Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys:
#   - Kernel (ERC-7579 Smart Account implementation)
#   - KernelFactory (creates Kernel instances)
#   - FactoryStaker (manages factory staking in EntryPoint)
#
# Prerequisites:
#   - EntryPoint must be deployed first (Phase 0)
#
# Usage:
#   ./script/deploy-smartaccount.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
#
# Examples:
#   ./script/deploy-smartaccount.sh                    # Dry run
#   ./script/deploy-smartaccount.sh --broadcast        # Deploy
#   ./script/deploy-smartaccount.sh --verify           # Verify only
#   ./script/deploy-smartaccount.sh --broadcast --verify  # Deploy + Verify
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

# Check if EntryPoint is deployed
CHAIN_ID="${CHAIN_ID:-8283}"
if [ ! -f "deployments/${CHAIN_ID}/addresses.json" ]; then
    echo "Error: Deployment addresses not found"
    echo "Please deploy EntryPoint first: ./script/deploy-entrypoint.sh --broadcast"
    exit 1
fi

# Check if EntryPoint address exists in addresses.json
ENTRYPOINT=$(grep -o '"entryPoint"[[:space:]]*:[[:space:]]*"[^"]*"' "deployments/${CHAIN_ID}/addresses.json" | cut -d'"' -f4)
if [ -z "$ENTRYPOINT" ]; then
    echo "Error: EntryPoint address not found in deployments/${CHAIN_ID}/addresses.json"
    echo "Please deploy EntryPoint first: ./script/deploy-entrypoint.sh --broadcast"
    exit 1
fi

echo "Using EntryPoint: $ENTRYPOINT"

# Execute TypeScript deployment script
npx ts-node script/ts/deploy-smartaccount.ts "$@"
