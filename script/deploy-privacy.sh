#!/bin/bash
# =============================================================================
# Privacy Contracts Deployment Script (ERC-5564/6538 Stealth Addresses)
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys Privacy modules:
#   - ERC5564Announcer: Stealth address announcement system
#   - ERC6538Registry: Stealth meta-address registry
#   - PrivateBank: Privacy-preserving deposit/withdrawal system
#
# Usage:
#   ./script/deploy-privacy.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
#
# Examples:
#   ./script/deploy-privacy.sh                     # Dry run
#   ./script/deploy-privacy.sh --broadcast         # Deploy
#   ./script/deploy-privacy.sh --broadcast --verify # Deploy + Verify
#   ./script/deploy-privacy.sh --verify            # Verify only
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
npx ts-node script/ts/deploy-privacy.ts "$@"
