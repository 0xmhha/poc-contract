#!/bin/bash
# =============================================================================
# Paymaster Post-Deployment Setup Script
# =============================================================================
# Wrapper script that executes the TypeScript setup code
#
# Runs ALL paymaster setup tasks after contract deployment:
#   1. Deposit native token to EntryPoint for all paymasters
#   2. Add USDC as supported token for ERC20Paymaster
#   3. Whitelist addresses for SponsorPaymaster
#   4. Set default budget for SponsorPaymaster
#   5. Stake bundler in EntryPoint
#   6. Stake factory in EntryPoint
#   7. Show final configuration
#
# Usage:
#   ./script/setup-paymaster.sh [options]
#
# Options:
#   --dry-run                 Show what would be executed without running
#   --info                    Show current status only (no changes)
#   --skip-deposit            Skip paymaster EntryPoint deposits
#   --skip-token              Skip ERC20Paymaster token setup
#   --skip-whitelist          Skip SponsorPaymaster whitelist
#   --skip-budget             Skip SponsorPaymaster default budget
#   --skip-bundler            Skip bundler EntryPoint staking
#   --skip-factory            Skip factory EntryPoint staking
#   --deposit=<amount>        Override deposit amount per paymaster (default: 10)
#   --from=<step>             Start from specific step
#
# Available Steps:
#   deposit, token, whitelist, budget, bundler, factory, info
#
# Examples:
#   ./script/setup-paymaster.sh                    # Full setup
#   ./script/setup-paymaster.sh --dry-run          # Show plan
#   ./script/setup-paymaster.sh --info             # Status only
#   ./script/setup-paymaster.sh --deposit=1        # Small deposit
#   ./script/setup-paymaster.sh --skip-bundler     # Skip bundler staking
#   ./script/setup-paymaster.sh --from=whitelist   # Start from whitelist step
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

# Check if deployment addresses exist
CHAIN_ID="${CHAIN_ID:-8283}"
if [ ! -f "deployments/${CHAIN_ID}/addresses.json" ]; then
    echo "Error: Deployment addresses not found at deployments/${CHAIN_ID}/addresses.json"
    echo "Please deploy contracts first: ./script/deploy-all.sh --broadcast"
    exit 1
fi

# Execute TypeScript script
npx ts-node script/ts/setup-paymaster.ts "$@"
