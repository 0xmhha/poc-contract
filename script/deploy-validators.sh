#!/bin/bash
# =============================================================================
# ERC-7579 Validators Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys Validator modules for ERC-7579 Smart Accounts:
#   - ECDSAValidator: Basic ECDSA signature validation
#   - WeightedECDSAValidator: Multi-sig with weighted signers
#   - MultiChainValidator: Cross-chain validation support
#   - MultiSigValidator: Standard multi-signature validation
#   - WebAuthnValidator: Passkey/WebAuthn validation
#
# Usage:
#   ./script/deploy-validators.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
#
# Examples:
#   ./script/deploy-validators.sh                     # Dry run
#   ./script/deploy-validators.sh --broadcast         # Deploy
#   ./script/deploy-validators.sh --broadcast --verify # Deploy + Verify
#   ./script/deploy-validators.sh --verify            # Verify only
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
npx ts-node script/ts/deploy-validators.ts "$@"
