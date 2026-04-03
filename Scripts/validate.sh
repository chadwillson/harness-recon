#!/usr/bin/env bash
# validate.sh — Lightweight pre-evaluation smoke test (bash port of validate.ps1)
set -euo pipefail

RECON_ROOT="/mnt/d/DocumentReconciliation"
PAYMENT_ROOT="/mnt/d/DocumentPayment"
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=1 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
    shift
done

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; GRAY='\033[0;90m'; NC='\033[0m'
failures=()

echo ""
echo -e "${CYAN}  [Validate] Running pre-evaluation smoke test...${NC}"

# ── 1. Build check: Reconciliation ───────────────────────────────────────────
echo -e "${YELLOW}  [1/4] Build check: DocumentReconciliation...${NC}"

recon_target="$RECON_ROOT/Tideline.Reconciliation.slnx"
[[ -f "$recon_target" ]] || recon_target="$RECON_ROOT/Tideline.Reconciliation.Api/Tideline.Reconciliation.Api.csproj"

if ! build_out=$(dotnet build "$recon_target" --configuration Release --no-incremental 2>&1); then
    echo -e "${RED}  [✗] DocumentReconciliation build FAILED${NC}"
    if (( VERBOSE )); then
        echo "$build_out" | tail -20
    else
        echo "$build_out" | grep -i ' error ' | head -5 | while IFS= read -r line; do echo -e "${RED}    $line${NC}"; done
    fi
    failures+=("Reconciliation build")
else
    echo -e "${GREEN}  [✓] DocumentReconciliation build OK${NC}"
fi

# ── 2. Build check: Payment ───────────────────────────────────────────────────
echo -e "${YELLOW}  [2/4] Build check: DocumentPayment...${NC}"

payment_target="$PAYMENT_ROOT/Tideline.Payment.slnx"
[[ -f "$payment_target" ]] || payment_target="$PAYMENT_ROOT/Tideline.Payment.Api/Tideline.Payment.Api.csproj"

if ! build_out=$(dotnet build "$payment_target" --configuration Release --no-incremental 2>&1); then
    echo -e "${RED}  [✗] DocumentPayment build FAILED${NC}"
    if (( VERBOSE )); then
        echo "$build_out" | tail -20
    else
        echo "$build_out" | grep -i ' error ' | head -5 | while IFS= read -r line; do echo -e "${RED}    $line${NC}"; done
    fi
    failures+=("Payment build")
else
    echo -e "${GREEN}  [✓] DocumentPayment build OK${NC}"
fi

# ── 3. Critical Reconciliation unit tests ────────────────────────────────────
echo -e "${YELLOW}  [3/4] Critical Reconciliation unit tests...${NC}"

recon_test_proj="$RECON_ROOT/Tideline.Reconciliation.Api.Tests"
if [[ -d "$recon_test_proj" ]]; then
    filter="Category=Smoke|FullyQualifiedName~StatusEnum|FullyQualifiedName~MatchDocument|FullyQualifiedName~ReconciliationService"
    quick_out=$(dotnet test "$recon_test_proj" --no-build --filter "$filter" --verbosity quiet 2>&1) || true
    if echo "$quick_out" | grep -q "Failed!" && ! echo "$quick_out" | grep -q "No test matches"; then
        echo -e "${RED}  [✗] Critical Reconciliation unit tests FAILED${NC}"
        failures+=("Reconciliation critical tests")
        (( VERBOSE )) && echo "$quick_out" | grep -E "Failed|Error"
    else
        pass_line=$(echo "$quick_out" | grep "passed" | tail -1)
        echo -e "${GREEN}  [✓] Reconciliation critical tests OK  ($pass_line)${NC}"
    fi
else
    echo -e "${GRAY}  [─] Reconciliation test project not found — skipping${NC}"
fi

# ── 4. Critical Payment unit tests ───────────────────────────────────────────
echo -e "${YELLOW}  [4/4] Critical Payment unit tests...${NC}"

payment_test_proj="$PAYMENT_ROOT/Tideline.Payment.Api.Tests"
if [[ -d "$payment_test_proj" ]]; then
    filter="Category=Smoke|FullyQualifiedName~PaymentService|FullyQualifiedName~PaymentController"
    quick_out=$(dotnet test "$payment_test_proj" --no-build --filter "$filter" --verbosity quiet 2>&1) || true
    if echo "$quick_out" | grep -q "Failed!" && ! echo "$quick_out" | grep -q "No test matches"; then
        echo -e "${RED}  [✗] Critical Payment unit tests FAILED${NC}"
        failures+=("Payment critical tests")
        (( VERBOSE )) && echo "$quick_out" | grep -E "Failed|Error"
    else
        pass_line=$(echo "$quick_out" | grep "passed" | tail -1)
        echo -e "${GREEN}  [✓] Payment critical tests OK  ($pass_line)${NC}"
    fi
else
    echo -e "${GRAY}  [─] Payment test project not found — skipping${NC}"
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [[ ${#failures[@]} -gt 0 ]]; then
    echo -e "${RED}  [✗] Validation FAILED: $(IFS=', '; echo "${failures[*]}")${NC}"
    echo -e "${RED}  Diagnose failures before running full evaluation.${NC}"
    echo ""
    exit 1
else
    echo -e "${GREEN}  [✓] Validation PASSED — safe to run evaluate.sh${NC}"
    echo ""
    exit 0
fi
