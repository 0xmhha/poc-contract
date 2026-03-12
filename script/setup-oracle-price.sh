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

if [ -z "$DEPLOYER_KEY" ]; then
    echo "Error: PRIVATE_KEY_DEPLOYER not set in .env"
    exit 1
fi

echo "Running SetupOraclePrice script..."
echo "RPC: $RPC"
echo "Price: 1 USDC = ${USDC_KRWC_PRICE:-1500} KRWC"
echo ""

forge script \
    script/deploy-contract/SetupOraclePrice.s.sol:SetupOraclePriceScript \
    --rpc-url "$RPC" \
    --private-key "$DEPLOYER_KEY" \
    --broadcast \
    -vvv
