#!/bin/bash
# =============================================================================
# Paymaster Staking Script
# =============================================================================
# Wrapper script that executes the TypeScript staking code
#
# Deposits ETH/KRC to EntryPoint for Paymaster gas sponsorship.
# All paymasters need a deposit in EntryPoint to pay for user gas fees.
#
# Usage:
#   ./script/stake-paymaster.sh [options]
#
# Options:
#   --info                    Show current deposit balances for all paymasters
#   --deposit=<amount>        Deposit amount in ETH/KRC (e.g., --deposit=1)
#   --paymaster=<name|addr>   Target paymaster (verifying|sponsor|erc20|permit2|all|0x...)
#   --withdraw=<amount>       Withdraw amount from paymaster deposit
#
# Examples:
#   ./script/stake-paymaster.sh --info
#   ./script/stake-paymaster.sh --deposit=1 --paymaster=all
#   ./script/stake-paymaster.sh --deposit=0.5 --paymaster=verifying
#   ./script/stake-paymaster.sh --deposit=2 --paymaster=0x1234...
#   ./script/stake-paymaster.sh --withdraw=0.5 --paymaster=erc20
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
npx ts-node script/ts/stake-paymaster.ts "$@"
