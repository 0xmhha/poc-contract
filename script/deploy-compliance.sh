#!/bin/bash
# =============================================================================
# Compliance Contracts Deployment Script
# =============================================================================
# Wrapper script that executes the TypeScript deployment code
#
# Deploys Compliance modules:
#   - KYCRegistry: KYC status management with multi-jurisdiction support
#   - AuditLogger: Immutable audit logging for regulatory compliance
#   - ProofOfReserve: 100% reserve verification using Chainlink PoR
#   - RegulatoryRegistry: Regulator management with 2-of-3 multi-sig trace approval
#
# Usage:
#   ./script/deploy-compliance.sh [--broadcast] [--verify] [--force]
#
# Options:
#   --broadcast  Actually broadcast transactions (otherwise dry run)
#   --verify     Verify contracts on block explorer
#   --force      Force redeploy even if contracts already exist
#
# Environment Variables:
#   ADMIN_ADDRESS: Admin address for contracts (defaults to deployer)
#   RETENTION_PERIOD: AuditLogger retention period in seconds (default: 7 years)
#   AUTO_PAUSE_THRESHOLD: ProofOfReserve auto-pause threshold (default: 3)
#   APPROVER_1, APPROVER_2, APPROVER_3: RegulatoryRegistry approvers
#
# Examples:
#   ./script/deploy-compliance.sh                     # Dry run
#   ./script/deploy-compliance.sh --broadcast         # Deploy
#   ./script/deploy-compliance.sh --broadcast --verify # Deploy + Verify
#   ./script/deploy-compliance.sh --verify            # Verify only
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
npx ts-node script/ts/deploy-compliance.ts "$@"
