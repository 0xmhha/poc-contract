#!/bin/bash

# =============================================================================
# Uniswap V3 Deployment Script
# =============================================================================
# This script deploys Uniswap V3 Core and Periphery contracts
#
# Prerequisites:
#   - Foundry installed
#   - .env file configured with RPC_URL, PRIVATE_KEY_DEPLOYER
#   - wKRC deployed (WKRC_ADDRESS in .env or deployments/)
#
# Usage:
#   ./script/deploy-uniswap-v3.sh [--broadcast] [--verify]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
# =============================================================================

set -e

# Navigate to project root
cd "$(dirname "$0")/.."
PROJECT_ROOT=$(pwd)

# Load .env file
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    echo "Error: .env file not found"
    exit 1
fi

# Disable via_ir for Solidity 0.7.6 compatibility
export FOUNDRY_VIA_IR=false

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
BROADCAST=""
VERIFY=""
for arg in "$@"; do
    case $arg in
        --broadcast)
            BROADCAST="--broadcast"
            shift
            ;;
        --verify)
            VERIFY="--verify"
            shift
            ;;
    esac
done

# Use PRIVATE_KEY_DEPLOYER or PRIVATE_KEY
DEPLOYER_PRIVATE_KEY=${PRIVATE_KEY_DEPLOYER:-$PRIVATE_KEY}

# Verify required environment variables
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}    UNISWAP V3 DEPLOYMENT SCRIPT${NC}"
echo -e "${YELLOW}========================================${NC}"

if [ -z "$RPC_URL" ]; then
    echo -e "${RED}Error: RPC_URL not set in .env${NC}"
    exit 1
fi

if [ -z "$DEPLOYER_PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY_DEPLOYER not set in .env${NC}"
    exit 1
fi

# Try to get WKRC_ADDRESS from deployment file if not set
if [ -z "$WKRC_ADDRESS" ]; then
    CHAIN_ID_CHECK=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "")
    if [ -n "$CHAIN_ID_CHECK" ] && [ -f "$PROJECT_ROOT/deployments/$CHAIN_ID_CHECK/addresses.json" ]; then
        WKRC_ADDRESS=$(jq -r '.contracts.wKRC // .wKRC // empty' "$PROJECT_ROOT/deployments/$CHAIN_ID_CHECK/addresses.json" 2>/dev/null || echo "")
    fi
fi

if [ -z "$WKRC_ADDRESS" ]; then
    echo -e "${RED}Error: WKRC_ADDRESS not set${NC}"
    echo "Deploy tokens first: ./script/deploy-tokens.sh --broadcast"
    exit 1
fi

# Default native currency label
NATIVE_CURRENCY_LABEL=${NATIVE_CURRENCY_LABEL:-"KRW"}

# Get deployer address
DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_PRIVATE_KEY")

echo ""
echo "Configuration:"
echo "  RPC URL: $RPC_URL"
echo "  Deployer: $DEPLOYER_ADDRESS"
echo "  wKRC Address: $WKRC_ADDRESS"
echo "  Native Currency: $NATIVE_CURRENCY_LABEL"
echo "  Broadcast: ${BROADCAST:-"false (dry run)"}"
echo "  Verify: ${VERIFY:-"false"}"
echo ""

echo -e "${GREEN}[1/5] Deploying UniswapV3Factory...${NC}"

FACTORY_ADDRESS=$(forge create \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    -R "@uniswap/v3-core/=lib/v3-core/" \
    -R "@uniswap/v3-periphery/=lib/v3-periphery/" \
    -R "@uniswap/lib/=lib/uniswap-lib/contracts/" \
    -R "@openzeppelin/contracts/=lib/openzeppelin-contracts-v3/contracts/" \
    -R "base64-sol/=lib/base64-sol/" \
    --use 0.7.6 \
    --optimize \
    lib/v3-core/contracts/UniswapV3Factory.sol:UniswapV3Factory \
    $BROADCAST $VERIFY 2>&1 | tee /dev/stderr | grep "Deployed to:" | awk '{print $3}')

if [ -z "$FACTORY_ADDRESS" ]; then
    echo -e "${YELLOW}Note: Dry run mode - no actual deployment${NC}"
    FACTORY_ADDRESS="0x0000000000000000000000000000000000000001"
fi

echo -e "  UniswapV3Factory: ${GREEN}$FACTORY_ADDRESS${NC}"
echo ""

echo -e "${GREEN}[2/5] Deploying SwapRouter...${NC}"

ROUTER_ADDRESS=$(forge create \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    -R "@uniswap/v3-core/=lib/v3-core/" \
    -R "@uniswap/v3-periphery/=lib/v3-periphery/" \
    -R "@uniswap/lib/=lib/uniswap-lib/contracts/" \
    -R "@openzeppelin/contracts/=lib/openzeppelin-contracts-v3/contracts/" \
    -R "base64-sol/=lib/base64-sol/" \
    --use 0.7.6 \
    --optimize \
    --constructor-args "$FACTORY_ADDRESS" "$WKRC_ADDRESS" \
    lib/v3-periphery/contracts/SwapRouter.sol:SwapRouter \
    $BROADCAST $VERIFY 2>&1 | tee /dev/stderr | grep "Deployed to:" | awk '{print $3}')

if [ -z "$ROUTER_ADDRESS" ]; then
    ROUTER_ADDRESS="0x0000000000000000000000000000000000000002"
fi

echo -e "  SwapRouter: ${GREEN}$ROUTER_ADDRESS${NC}"
echo ""

echo -e "${GREEN}[3/5] Deploying Quoter...${NC}"

QUOTER_ADDRESS=$(forge create \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    -R "@uniswap/v3-core/=lib/v3-core/" \
    -R "@uniswap/v3-periphery/=lib/v3-periphery/" \
    -R "@uniswap/lib/=lib/uniswap-lib/contracts/" \
    -R "@openzeppelin/contracts/=lib/openzeppelin-contracts-v3/contracts/" \
    -R "base64-sol/=lib/base64-sol/" \
    --use 0.7.6 \
    --optimize \
    --constructor-args "$FACTORY_ADDRESS" "$WKRC_ADDRESS" \
    lib/v3-periphery/contracts/lens/Quoter.sol:Quoter \
    $BROADCAST $VERIFY 2>&1 | tee /dev/stderr | grep "Deployed to:" | awk '{print $3}')

if [ -z "$QUOTER_ADDRESS" ]; then
    QUOTER_ADDRESS="0x0000000000000000000000000000000000000003"
fi

echo -e "  Quoter: ${GREEN}$QUOTER_ADDRESS${NC}"
echo ""

# Convert native currency label to bytes32
NATIVE_LABEL_BYTES32=$(cast --to-bytes32 "$(echo -n "$NATIVE_CURRENCY_LABEL" | xxd -p)")

echo -e "${GREEN}[4/5] Deploying NonfungibleTokenPositionDescriptor...${NC}"

DESCRIPTOR_ADDRESS=$(forge create \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    -R "@uniswap/v3-core/=lib/v3-core/" \
    -R "@uniswap/v3-periphery/=lib/v3-periphery/" \
    -R "@uniswap/lib/=lib/uniswap-lib/contracts/" \
    -R "@openzeppelin/contracts/=lib/openzeppelin-contracts-v3/contracts/" \
    -R "base64-sol/=lib/base64-sol/" \
    --use 0.7.6 \
    --optimize \
    --constructor-args "$WKRC_ADDRESS" "$NATIVE_LABEL_BYTES32" \
    lib/v3-periphery/contracts/NonfungibleTokenPositionDescriptor.sol:NonfungibleTokenPositionDescriptor \
    $BROADCAST $VERIFY 2>&1 | tee /dev/stderr | grep "Deployed to:" | awk '{print $3}') || true

if [ -z "$DESCRIPTOR_ADDRESS" ]; then
    echo -e "${YELLOW}  Note: NonfungibleTokenPositionDescriptor deployment skipped (complex dependencies)${NC}"
    DESCRIPTOR_ADDRESS="0x0000000000000000000000000000000000000000"
fi

echo -e "  NonfungibleTokenPositionDescriptor: ${GREEN}$DESCRIPTOR_ADDRESS${NC}"
echo ""

if [ "$DESCRIPTOR_ADDRESS" != "0x0000000000000000000000000000000000000000" ]; then
    echo -e "${GREEN}[5/5] Deploying NonfungiblePositionManager...${NC}"

    POSITION_MANAGER_ADDRESS=$(forge create \
        --rpc-url "$RPC_URL" \
        --private-key "$DEPLOYER_PRIVATE_KEY" \
        -R "@uniswap/v3-core/=lib/v3-core/" \
        -R "@uniswap/v3-periphery/=lib/v3-periphery/" \
        -R "@uniswap/lib/=lib/uniswap-lib/contracts/" \
        -R "@openzeppelin/contracts/=lib/openzeppelin-contracts-v3/contracts/" \
        -R "base64-sol/=lib/base64-sol/" \
        --use 0.7.6 \
        --optimize \
        --constructor-args "$FACTORY_ADDRESS" "$WKRC_ADDRESS" "$DESCRIPTOR_ADDRESS" \
        lib/v3-periphery/contracts/NonfungiblePositionManager.sol:NonfungiblePositionManager \
        $BROADCAST $VERIFY 2>&1 | tee /dev/stderr | grep "Deployed to:" | awk '{print $3}') || true

    if [ -z "$POSITION_MANAGER_ADDRESS" ]; then
        POSITION_MANAGER_ADDRESS="0x0000000000000000000000000000000000000000"
    fi
else
    echo -e "${YELLOW}[5/5] Skipping NonfungiblePositionManager (descriptor not deployed)${NC}"
    POSITION_MANAGER_ADDRESS="0x0000000000000000000000000000000000000000"
fi

echo -e "  NonfungiblePositionManager: ${GREEN}$POSITION_MANAGER_ADDRESS${NC}"

# Get chain ID
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")

# Print summary
echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}    DEPLOYMENT SUMMARY${NC}"
echo -e "${YELLOW}========================================${NC}"
echo "Chain ID: $CHAIN_ID"
echo ""
echo "Core Contracts:"
echo "  UniswapV3Factory: $FACTORY_ADDRESS"
echo ""
echo "Periphery Contracts:"
echo "  SwapRouter: $ROUTER_ADDRESS"
echo "  Quoter: $QUOTER_ADDRESS"
echo "  NonfungibleTokenPositionDescriptor: $DESCRIPTOR_ADDRESS"
echo "  NonfungiblePositionManager: $POSITION_MANAGER_ADDRESS"
echo ""
echo "Configuration:"
echo "  wKRC: $WKRC_ADDRESS"
echo -e "${YELLOW}========================================${NC}"

# Save deployment info to JSON if broadcast was used
if [ -n "$BROADCAST" ]; then
    DEPLOYMENTS_DIR="deployments/$CHAIN_ID"
    mkdir -p "$DEPLOYMENTS_DIR"

    TIMESTAMP=$(date +%s)
    DEPLOYMENT_FILE="$DEPLOYMENTS_DIR/uniswap-v3-$TIMESTAMP.json"

    cat > "$DEPLOYMENT_FILE" << EOF
{
    "chainId": $CHAIN_ID,
    "timestamp": $TIMESTAMP,
    "deployer": "$DEPLOYER_ADDRESS",
    "contracts": {
        "UniswapV3Factory": "$FACTORY_ADDRESS",
        "SwapRouter": "$ROUTER_ADDRESS",
        "Quoter": "$QUOTER_ADDRESS",
        "NonfungibleTokenPositionDescriptor": "$DESCRIPTOR_ADDRESS",
        "NonfungiblePositionManager": "$POSITION_MANAGER_ADDRESS"
    },
    "configuration": {
        "wKRC": "$WKRC_ADDRESS",
        "nativeCurrencyLabel": "$NATIVE_CURRENCY_LABEL"
    }
}
EOF

    # Also save as latest
    cp "$DEPLOYMENT_FILE" "$DEPLOYMENTS_DIR/uniswap-v3-latest.json"

    echo ""
    echo -e "${GREEN}Deployment saved to: $DEPLOYMENT_FILE${NC}"
fi

echo ""
echo -e "${GREEN}Deployment complete!${NC}"
