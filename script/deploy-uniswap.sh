#!/bin/bash
# =============================================================================
# UniswapV3 Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys UniswapV3 contracts:
#   - UniswapV3Factory: Creates and manages liquidity pools
#   - SwapRouter: Executes token swaps
#   - Quoter: Provides swap quotes
#   - NonfungiblePositionManager: Manages LP positions as NFTs
#
# Usage:
#   ./script/deploy-uniswap.sh [--broadcast] [--create-pool] [--verify] [--force]
#
# Options:
#   --broadcast    Actually broadcast transactions (otherwise dry run)
#   --create-pool  Create WKRC/USDC pool after deployment
#   --verify       Verify contracts on block explorer
#   --force        Force redeploy even if contracts already exist
#
# Environment Variables:
#   WKRC_ADDRESS: NativeCoinAdapter address (default: 0x1000)
#   USDC_ADDRESS: USDC contract address (loaded from deployment file)
#   POOL_FEE: Pool fee tier in basis points (default: 3000 = 0.3%)
#   VERIFIER_URL: Block explorer verification URL
#
# Examples:
#   ./script/deploy-uniswap.sh                                  # Dry run
#   ./script/deploy-uniswap.sh --broadcast                      # Deploy
#   ./script/deploy-uniswap.sh --broadcast --create-pool        # Deploy + Create Pool
#   ./script/deploy-uniswap.sh --broadcast --verify             # Deploy + Verify
#   ./script/deploy-uniswap.sh --verify                         # Verify only
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

# Ensure remappings.txt is restored on any exit (success, error, or signal)
cleanup_remappings() {
    if [ -f "remappings.txt.bak" ]; then
        mv remappings.txt.bak remappings.txt
    fi
}
trap cleanup_remappings EXIT

# Build UniswapV3 contracts with isolated uniswap profile
# Temporarily hide remappings.txt to use profile-specific remappings (OZ v3 for UniswapV3)
echo "Building UniswapV3 contracts..."
if [ -f "remappings.txt" ]; then
    mv remappings.txt remappings.txt.bak
fi

FOUNDRY_PROFILE=uniswap forge build

# Execute TypeScript script
npx ts-node script/ts/deploy-uniswap.ts "$@"
