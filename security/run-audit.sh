#!/usr/bin/env bash
# Security Audit Script for StableNet PoC Contracts
# Runs both Slither and Mythril security analysis tools

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Output directory
OUTPUT_DIR="$SCRIPT_DIR/reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Help message
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -s, --slither       Run Slither analysis only"
    echo "  -m, --mythril       Run Mythril analysis only"
    echo "  -e, --echidna       Run Echidna fuzzing only"
    echo "  -a, --all           Run all security tools (default)"
    echo "  -p, --profile NAME  Specify foundry profile (default: all core profiles)"
    echo "  -c, --contract FILE Analyze specific contract file"
    echo "  -o, --output DIR    Output directory (default: security/reports)"
    echo "  -v, --verbose       Verbose output"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --slither                    # Run Slither only"
    echo "  $0 --mythril -c src/subscription/SubscriptionManager.sol"
    echo "  $0 --echidna                    # Run Echidna fuzzing"
    echo "  $0 --all --profile subscription # Run all on subscription profile"
    exit 0
}

# Parse arguments
RUN_SLITHER=false
RUN_MYTHRIL=false
RUN_ECHIDNA=false
PROFILE=""
CONTRACT=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--slither)
            RUN_SLITHER=true
            shift
            ;;
        -m|--mythril)
            RUN_MYTHRIL=true
            shift
            ;;
        -e|--echidna)
            RUN_ECHIDNA=true
            shift
            ;;
        -a|--all)
            RUN_SLITHER=true
            RUN_MYTHRIL=true
            RUN_ECHIDNA=true
            shift
            ;;
        -p|--profile)
            PROFILE="$2"
            shift 2
            ;;
        -c|--contract)
            CONTRACT="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Default to running all if none specified
if [[ "$RUN_SLITHER" == "false" && "$RUN_MYTHRIL" == "false" && "$RUN_ECHIDNA" == "false" ]]; then
    RUN_SLITHER=true
    RUN_MYTHRIL=true
    RUN_ECHIDNA=true
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         StableNet Security Audit Tool                      ║${NC}"
echo -e "${BLUE}╠════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║  Timestamp: ${TIMESTAMP}                             ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check dependencies
check_dependencies() {
    local missing=()

    if [[ "$RUN_SLITHER" == "true" ]] && ! command -v slither &> /dev/null; then
        missing+=("slither")
    fi

    if [[ "$RUN_MYTHRIL" == "true" ]] && ! command -v myth &> /dev/null; then
        missing+=("mythril")
    fi

    if [[ "$RUN_ECHIDNA" == "true" ]] && ! command -v echidna &> /dev/null; then
        missing+=("echidna")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Missing dependencies: ${missing[*]}${NC}"
        echo ""
        echo "Install instructions:"
        echo "  Slither: pip install slither-analyzer"
        echo "  Mythril: pip install mythril"
        echo "  Echidna: brew install echidna (macOS) or download from GitHub"
        echo ""

        # Don't exit, just warn
        return 1
    fi

    return 0
}

# Run Slither analysis
run_slither() {
    echo -e "${GREEN}▶ Running Slither Security Analysis...${NC}"
    echo "─────────────────────────────────────────────────────────────"

    local slither_output="$OUTPUT_DIR/slither-${TIMESTAMP}.json"
    local slither_md="$OUTPUT_DIR/slither-${TIMESTAMP}.md"

    cd "$PROJECT_ROOT"

    # Build contracts first
    echo "Building contracts..."
    forge build --silent 2>/dev/null || true

    # Run slither
    local slither_args=("--json" "$slither_output")

    if [[ -n "$CONTRACT" ]]; then
        slither_args+=("$CONTRACT")
    else
        slither_args+=(".")
    fi

    if [[ "$VERBOSE" == "true" ]]; then
        slither "${slither_args[@]}" --print human-summary 2>&1 | tee "$slither_md" || true
    else
        slither "${slither_args[@]}" 2>&1 > "$slither_md" || true
    fi

    # Generate summary
    if [[ -f "$slither_output" ]]; then
        echo ""
        echo -e "${GREEN}✓ Slither analysis complete${NC}"
        echo "  JSON Report: $slither_output"
        echo "  Text Report: $slither_md"

        # Parse and display summary
        if command -v jq &> /dev/null && [[ -s "$slither_output" ]]; then
            local high=$(jq '[.results.detectors[] | select(.impact == "High")] | length' "$slither_output" 2>/dev/null || echo "0")
            local medium=$(jq '[.results.detectors[] | select(.impact == "Medium")] | length' "$slither_output" 2>/dev/null || echo "0")
            local low=$(jq '[.results.detectors[] | select(.impact == "Low")] | length' "$slither_output" 2>/dev/null || echo "0")
            local info=$(jq '[.results.detectors[] | select(.impact == "Informational")] | length' "$slither_output" 2>/dev/null || echo "0")

            echo ""
            echo "  Summary:"
            echo -e "    ${RED}High:${NC}          $high"
            echo -e "    ${YELLOW}Medium:${NC}        $medium"
            echo -e "    ${BLUE}Low:${NC}           $low"
            echo -e "    Informational: $info"
        fi
    else
        echo -e "${YELLOW}⚠ Slither produced no output${NC}"
    fi

    echo ""
}

# Run Mythril analysis
run_mythril() {
    echo -e "${GREEN}▶ Running Mythril Security Analysis...${NC}"
    echo "─────────────────────────────────────────────────────────────"

    local mythril_output="$OUTPUT_DIR/mythril-${TIMESTAMP}.json"

    cd "$PROJECT_ROOT"

    # Define contracts to analyze
    local contracts=()

    if [[ -n "$CONTRACT" ]]; then
        contracts+=("$CONTRACT")
    else
        # Core contracts for analysis
        contracts=(
            "src/subscription/SubscriptionManager.sol"
            "src/subscription/ERC7715PermissionManager.sol"
            "src/privacy/enterprise/StealthVault.sol"
        )
    fi

    local results=()

    for contract in "${contracts[@]}"; do
        if [[ -f "$contract" ]]; then
            echo "Analyzing: $contract"

            local contract_name=$(basename "$contract" .sol)
            local contract_output="$OUTPUT_DIR/mythril-${contract_name}-${TIMESTAMP}.json"

            # Run mythril with timeout
            if timeout 300 myth analyze "$contract" \
                --solc-json \
                --execution-timeout 120 \
                --max-depth 64 \
                -o json > "$contract_output" 2>&1; then

                results+=("$contract_output")
                echo -e "  ${GREEN}✓${NC} $contract_name"
            else
                echo -e "  ${YELLOW}⚠${NC} $contract_name (timeout or error)"
            fi
        else
            echo -e "  ${RED}✗${NC} File not found: $contract"
        fi
    done

    # Combine results
    if [[ ${#results[@]} -gt 0 ]]; then
        echo ""
        echo -e "${GREEN}✓ Mythril analysis complete${NC}"
        echo "  Reports saved to: $OUTPUT_DIR/mythril-*-${TIMESTAMP}.json"
    fi

    echo ""
}

# Run Echidna fuzzing
run_echidna() {
    echo -e "${GREEN}▶ Running Echidna Fuzzing...${NC}"
    echo "─────────────────────────────────────────────────────────────"

    cd "$PROJECT_ROOT"

    # Define fuzzing contracts
    local fuzz_contracts=(
        "test/echidna/EchidnaKernel.sol:EchidnaKernel"
        "test/echidna/EchidnaSubscription.sol:EchidnaSubscription"
        "test/echidna/EchidnaSpendingLimit.sol:EchidnaSpendingLimit"
    )

    # Create corpus directory
    mkdir -p "security/echidna-corpus"

    for fuzz_target in "${fuzz_contracts[@]}"; do
        local contract_file="${fuzz_target%%:*}"
        local contract_name="${fuzz_target##*:}"

        if [[ -f "$contract_file" ]]; then
            echo "Fuzzing: $contract_name"

            local echidna_output="$OUTPUT_DIR/echidna-${contract_name}-${TIMESTAMP}.txt"

            # Run Echidna with timeout
            if timeout 600 echidna "$contract_file" \
                --contract "$contract_name" \
                --config "security/echidna.yaml" \
                --format text > "$echidna_output" 2>&1; then

                echo -e "  ${GREEN}✓${NC} $contract_name passed"
            else
                local exit_code=$?
                if [[ $exit_code -eq 124 ]]; then
                    echo -e "  ${YELLOW}⚠${NC} $contract_name (timeout)"
                else
                    echo -e "  ${RED}✗${NC} $contract_name (property failed)"
                fi
            fi

            # Show summary if verbose
            if [[ "$VERBOSE" == "true" && -f "$echidna_output" ]]; then
                tail -20 "$echidna_output"
            fi
        else
            echo -e "  ${YELLOW}⚠${NC} File not found: $contract_file"
        fi
    done

    echo ""
    echo -e "${GREEN}✓ Echidna fuzzing complete${NC}"
    echo "  Reports saved to: $OUTPUT_DIR/echidna-*-${TIMESTAMP}.txt"
    echo ""
}

# Generate combined report
generate_report() {
    echo -e "${GREEN}▶ Generating Combined Security Report...${NC}"
    echo "─────────────────────────────────────────────────────────────"

    local report_file="$OUTPUT_DIR/security-audit-${TIMESTAMP}.md"

    cat > "$report_file" << EOF
# StableNet Security Audit Report

**Generated:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
**Project:** StableNet PoC Contracts

## Executive Summary

This report contains the results of automated security analysis using:
- **Slither**: Static analysis tool by Trail of Bits
- **Mythril**: Symbolic execution tool by ConsenSys

## Audit Scope

### Contracts Analyzed

| Category | Contracts |
|----------|-----------|
| Subscription | SubscriptionManager, ERC7715PermissionManager, RecurringPaymentExecutor |
| Privacy | StealthVault, StealthLedger, WithdrawalManager, RoleManager |
| Bridge | SecureBridge, BridgeValidator, BridgeGuardian |

## Analysis Results

### Slither Findings

See: \`slither-${TIMESTAMP}.json\` for detailed findings.

### Mythril Findings

See: \`mythril-*-${TIMESTAMP}.json\` for detailed findings.

## Recommendations

1. **High Priority**: Address all High severity findings before deployment
2. **Medium Priority**: Review Medium findings and document accepted risks
3. **Low Priority**: Address Low findings in next development cycle
4. **Informational**: Review for code quality improvements

## Manual Review Required

Automated tools cannot detect all vulnerabilities. A manual security audit by experienced auditors is recommended for:
- Business logic vulnerabilities
- Access control issues
- Economic attacks (flash loans, sandwich attacks)
- Cross-contract interaction bugs

## Tool Versions

- Slither: $(slither --version 2>/dev/null || echo "Not installed")
- Mythril: $(myth version 2>/dev/null || echo "Not installed")
- Foundry: $(forge --version 2>/dev/null || echo "Not installed")

---
*This report was automatically generated. Manual verification of findings is required.*
EOF

    echo -e "${GREEN}✓ Combined report generated: $report_file${NC}"
    echo ""
}

# Main execution
main() {
    # Check dependencies (warn but continue)
    check_dependencies || true

    if [[ "$RUN_SLITHER" == "true" ]]; then
        if command -v slither &> /dev/null; then
            run_slither
        else
            echo -e "${YELLOW}Skipping Slither (not installed)${NC}"
            echo "  Install: pip install slither-analyzer"
            echo ""
        fi
    fi

    if [[ "$RUN_MYTHRIL" == "true" ]]; then
        if command -v myth &> /dev/null; then
            run_mythril
        else
            echo -e "${YELLOW}Skipping Mythril (not installed)${NC}"
            echo "  Install: pip install mythril"
            echo ""
        fi
    fi

    if [[ "$RUN_ECHIDNA" == "true" ]]; then
        if command -v echidna &> /dev/null; then
            run_echidna
        else
            echo -e "${YELLOW}Skipping Echidna (not installed)${NC}"
            echo "  Install: brew install echidna (macOS)"
            echo "  Or download from: https://github.com/crytic/echidna/releases"
            echo ""
        fi
    fi

    generate_report

    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    Audit Complete                          ║${NC}"
    echo -e "${BLUE}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  Reports saved to: security/reports/                       ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
}

main
