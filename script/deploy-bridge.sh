#!/bin/bash
# =============================================================================
# Bridge Contracts Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys Bridge contracts (Defense-in-depth bridge system):
#   - FraudProofVerifier: Dispute resolution via fraud proofs
#   - BridgeRateLimiter: Volume and rate controls
#   - BridgeValidator: MPC signing (threshold signatures)
#   - BridgeGuardian: Emergency response system
#   - OptimisticVerifier: Challenge period verification
#   - SecureBridge: Main bridge integrating all security layers
#
# Usage:
#   ./script/deploy-bridge.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
#
# Examples:
#   ./script/deploy-bridge.sh                     # Dry run
#   ./script/deploy-bridge.sh --broadcast         # Deploy
#   ./script/deploy-bridge.sh --broadcast --verify # Deploy + Verify
#   ./script/deploy-bridge.sh --verify            # Verify only
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
npx ts-node script/ts/deploy-bridge.ts "$@"
