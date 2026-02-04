#!/bin/bash
# =============================================================================
# Paymasters Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys ERC-4337 Paymaster contracts:
#   - VerifyingPaymaster: Off-chain signature verification for gas sponsorship
#   - SponsorPaymaster: Budget-based gas sponsorship with daily limits
#   - ERC20Paymaster: Pay gas fees with ERC20 tokens (requires PriceOracle)
#   - Permit2Paymaster: Gasless ERC20 payments via Permit2 (requires PriceOracle + Permit2)
#
# Usage:
#   ./script/deploy-paymasters.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
#
# Environment Variables:
#   OWNER_ADDRESS: Owner/admin address for paymasters (defaults to deployer)
#   VERIFYING_SIGNER: Signer address for VerifyingPaymaster/SponsorPaymaster
#   MARKUP: Price markup in basis points (default: 1000 = 10%)
#
# Dependencies (auto-loaded from addresses.json):
#   - EntryPoint: Required for all paymasters
#   - PriceOracle: Required for ERC20Paymaster and Permit2Paymaster
#   - Permit2: Required for Permit2Paymaster
#
# Examples:
#   ./script/deploy-paymasters.sh                     # Dry run
#   ./script/deploy-paymasters.sh --broadcast         # Deploy
#   ./script/deploy-paymasters.sh --broadcast --verify # Deploy + Verify
#   ./script/deploy-paymasters.sh --verify            # Verify only
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
npx ts-node script/ts/deploy-paymasters.ts "$@"
