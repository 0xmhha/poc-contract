#!/bin/bash
# =============================================================================
# Oracle Price Setup Script
# =============================================================================
# Deploys a FixedPriceAggregator and configures the PriceOracle
# to return a fixed USDC/KRWC price for PoC testing.
#
# Usage:
#   ./script/setup-oracle-price.sh                    # Default: 1 USDC = 1500 KRWC
#   USDC_KRWC_PRICE=2000 ./script/setup-oracle-price.sh  # Custom: 1 USDC = 2000 KRWC
#   ./script/setup-oracle-price.sh --verify           # Deploy + verify separately
# =============================================================================

set -e

cd "$(dirname "$0")/.."

# Load environment
if [ ! -f ".env" ]; then
    echo "Error: .env file not found"
    exit 1
fi

source .env

RPC=${RPC_URL:-http://127.0.0.1:8501}
DEPLOYER_KEY=${PRIVATE_KEY_DEPLOYER}
CHAIN_ID=${CHAIN_ID:-8283}

if [ -z "$DEPLOYER_KEY" ]; then
    echo "Error: PRIVATE_KEY_DEPLOYER not set in .env"
    exit 1
fi

VERIFY=false
for arg in "$@"; do
    case "$arg" in
        --verify) VERIFY=true ;;
    esac
done

echo "Running SetupOraclePrice script..."
echo "RPC: $RPC"
echo "Price: 1 USDC = ${USDC_KRWC_PRICE:-1500} KRWC"
echo ""

# Step 1: Deploy and configure
forge script \
    script/deploy-contract/SetupOraclePrice.s.sol:SetupOraclePriceScript \
    --rpc-url "$RPC" \
    --private-key "$DEPLOYER_KEY" \
    --broadcast \
    -vvv

# Step 2: Verify FixedPriceAggregator separately (if requested)
if [ "$VERIFY" = true ]; then
    if [ -z "$VERIFIER_URL" ]; then
        echo "Warning: --verify requested but VERIFIER_URL not set, skipping verification"
        exit 0
    fi

    echo ""
    echo "------------------------------------------------------------"
    echo "Verifying FixedPriceAggregator..."
    echo "------------------------------------------------------------"

    # Find FixedPriceAggregator address from broadcast
    BROADCAST_FILE="broadcast/SetupOraclePrice.s.sol/${CHAIN_ID}/run-latest.json"
    if [ -f "$BROADCAST_FILE" ]; then
        AGGREGATOR_ADDR=$(python3 -c "
import json, sys
with open('$BROADCAST_FILE') as f:
    data = json.load(f)
for tx in data.get('transactions', []):
    if tx.get('contractName') == 'FixedPriceAggregator' and tx.get('transactionType') in ('CREATE', 'CREATE2'):
        print(tx['contractAddress'])
        sys.exit(0)
" 2>/dev/null || true)

        if [ -n "$AGGREGATOR_ADDR" ]; then
            echo "FixedPriceAggregator at: $AGGREGATOR_ADDR"
            forge verify-contract \
                --verifier-url "$VERIFIER_URL" \
                --verifier custom \
                --chain-id "$CHAIN_ID" \
                "$AGGREGATOR_ADDR" \
                "src/defi/FixedPriceAggregator.sol:FixedPriceAggregator" || \
                echo "Verification failed (contract may already be verified)"
        else
            echo "FixedPriceAggregator address not found in broadcast file"
        fi
    else
        echo "Broadcast file not found: $BROADCAST_FILE"
    fi
fi
