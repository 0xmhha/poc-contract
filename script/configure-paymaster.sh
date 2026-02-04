#!/bin/bash
# =============================================================================
# Paymaster Configuration Script
# =============================================================================
# Wrapper script that executes the TypeScript configuration code
#
# Configures ERC-4337 Paymasters after deployment:
# - ERC20Paymaster: Add supported tokens for gas payment
# - SponsorPaymaster: Set whitelist, budgets, campaigns
#
# Usage:
#   ./script/configure-paymaster.sh [command] [options]
#
# Commands:
#   # ERC20Paymaster
#   add-token <token>           Add supported token to ERC20Paymaster
#   remove-token <token>        Remove supported token from ERC20Paymaster
#   set-markup <bps>            Set markup (500-5000 basis points)
#   token-info <token>          Show token configuration and price quote
#
#   # SponsorPaymaster
#   whitelist <address>         Add address to whitelist
#   unwhitelist <address>       Remove address from whitelist
#   whitelist-batch <file>      Add addresses from file (one per line)
#   set-budget <user> <limit> <period>  Set user budget
#   set-default-budget <limit> <period> Set default budget
#   create-campaign             Create a new campaign (interactive)
#   campaign-info <id>          Show campaign info
#   budget-info <user>          Show user budget info
#
#   # General
#   info                        Show all paymaster configurations
#
# Examples:
#   ./script/configure-paymaster.sh info
#   ./script/configure-paymaster.sh add-token 0x1234...
#   ./script/configure-paymaster.sh whitelist 0x5678...
#   ./script/configure-paymaster.sh set-budget 0x5678... 0.5 86400
#   ./script/configure-paymaster.sh set-markup 1500
#   ./script/configure-paymaster.sh create-campaign
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
npx ts-node script/ts/configure-paymaster.ts "$@"
