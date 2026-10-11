#!/usr/bin/env bash
# =============================================================================
# Code coverage
# =============================================================================
# Usage: ./script/coverage.sh [extra forge coverage args]
#   ./script/coverage.sh                          # summary for the whole repository
#   ./script/coverage.sh --report lcov            # lcov.info for editors / CI upload
#   ./script/coverage.sh --match-path "test/erc7579-smartaccount/*"
#
# forge coverage compiles without the optimizer, which hits "stack too deep" in this
# codebase, so --ir-minimum is required. Two tests assert properties of optimized bytecode
# and are excluded here (they still run in `forge test`):
#   test_KernelRuntimeFitsEip170
#       unoptimized Kernel exceeds the EIP-170 size limit
#   test_SponsorPaymaster_RecordedSpendingCoversDepositAtPostOpCap
#       SponsorPaymaster.POSTOP_GAS_OVERHEAD is measured on optimized code; unoptimized
#       postOp uses more gas than it covers
# =============================================================================
set -euo pipefail

EXCLUDED="test_KernelRuntimeFitsEip170|test_SponsorPaymaster_RecordedSpendingCoversDepositAtPostOpCap"

if [ "$#" -eq 0 ]; then
    set -- --report summary
fi

exec forge coverage --ir-minimum --no-match-test "$EXCLUDED" "$@"
