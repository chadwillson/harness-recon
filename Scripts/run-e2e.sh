#!/usr/bin/env bash
# run-e2e.sh — Run Playwright e2e suites against ACI deployments (bash port of run-e2e.ps1)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECON_ROOT="/mnt/d/DocumentReconciliation"
PAYMENT_ROOT="/mnt/d/DocumentPayment"
RECON_URL="http://tideline-recon-poc.westus.azurecontainer.io:8080"
PAYMENT_URL="http://tideline-payment-poc.westus.azurecontainer.io:8080"
OUTPUT_DIR="$(pwd)"
SKIP_RECON=0
SKIP_PAYMENT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --recon-url)    RECON_URL="$2"; shift ;;
        --payment-url)  PAYMENT_URL="$2"; shift ;;
        --output-dir)   OUTPUT_DIR="$2"; shift ;;
        --skip-recon)   SKIP_RECON=1 ;;
        --skip-payment) SKIP_PAYMENT=1 ;;
        -h|--help)
            echo "Usage: run-e2e.sh [--recon-url URL] [--payment-url URL] [--output-dir DIR]"
            echo "                   [--skip-recon] [--skip-payment]"
            exit 0 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
    shift
done

mkdir -p "$OUTPUT_DIR"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; GRAY='\033[0;90m'; NC='\033[0m'

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Harness-Recon E2E Runner${NC}"
echo -e "${CYAN}  Recon URL:   $RECON_URL${NC}"
echo -e "${CYAN}  Payment URL: $PAYMENT_URL${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""

# ── Parse Playwright JSON results ─────────────────────────────────────────────
# Playwright JSON reporter: stats.expected=pass, stats.unexpected=fail, stats.skipped=skip
parse_playwright_results() {
    local json_path="$1"
    if [[ ! -f "$json_path" ]]; then
        echo '{"passed":0,"failed":0,"skipped":0,"total":0,"passRate":0,"failures":[],"error":"results.json not found"}'
        return
    fi
    jq '{
        passed:  (.stats.expected  // 0),
        failed:  (.stats.unexpected // 0),
        skipped: (.stats.skipped   // 0),
        total:   ((.stats.expected // 0) + (.stats.unexpected // 0) + (.stats.skipped // 0)),
        passRate: (
            if ((.stats.expected // 0) + (.stats.unexpected // 0)) > 0
            then ((.stats.expected // 0) / ((.stats.expected // 0) + (.stats.unexpected // 0)) * 10000 | round / 10000)
            else 0 end
        ),
        failures: [
            .. | objects |
            select(.status? == "failed" or .status? == "timedOut") |
            {title: (.title // ""), status: .status, error: (.error.message // "")}
        ]
    }' "$json_path"
}

# ── Run a Playwright suite ────────────────────────────────────────────────────
run_suite() {
    local suite_root="$1" suite_name="$2" env_key="$3" env_val="$4" log_path="$5"
    local results_dir="$suite_root/e2e/test-results"
    local results_json="$results_dir/results.json"

    if [[ ! -d "$suite_root" ]]; then
        echo -e "${YELLOW}  [!] Suite root not found: $suite_root${NC}"
        echo 1; return
    fi

    # Clear prior results
    [[ -f "$results_json" ]] && rm -f "$results_json"

    echo -e "${YELLOW}  [→] Running $suite_name e2e suite...${NC}"

    local exit_code=0
    (
        cd "$suite_root"
        export "$env_key=$env_val"
        npx playwright test --reporter=json,line 2>&1
    ) > "$log_path" || exit_code=$?

    local color; color=$([ "$exit_code" -eq 0 ] && echo "$GREEN" || echo "$YELLOW")
    echo -e "${color}  [✓] $suite_name e2e complete (exit: $exit_code)${NC}"

    echo "$exit_code"
    # results_json path is predictable — caller uses it
}

# ── Reconciliation e2e ────────────────────────────────────────────────────────
recon_passed=0 recon_failed=0 recon_skipped=0 recon_total=0 recon_rate=0 recon_exit=-1
recon_failures='[]'

if (( !SKIP_RECON )); then
    recon_log="$OUTPUT_DIR/e2e-recon.log"
    recon_results_json="$RECON_ROOT/e2e/test-results/results.json"
    [[ -f "$recon_results_json" ]] && rm -f "$recon_results_json"

    echo -e "${YELLOW}  [→] Running Reconciliation e2e suite...${NC}"
    recon_exit=0
    (
        cd "$RECON_ROOT"
        export RECON_URL="$RECON_URL"
        # Use PLAYWRIGHT_JSON_OUTPUT_NAME to write JSON to a dedicated file (not stdout)
        export PLAYWRIGHT_JSON_OUTPUT_NAME="$recon_results_json"
        npx playwright test --reporter=json,line 2>&1
    ) > "$recon_log" || recon_exit=$?

    if [[ -f "$recon_results_json" ]]; then
        recon_json=$(parse_playwright_results "$recon_results_json")
        recon_passed=$(jq -r '.passed'  <<< "$recon_json")
        recon_failed=$(jq -r '.failed'  <<< "$recon_json")
        recon_skipped=$(jq -r '.skipped' <<< "$recon_json")
        recon_total=$(jq -r '.total'   <<< "$recon_json")
        recon_rate=$(jq -r '.passRate' <<< "$recon_json")
        recon_failures=$(jq -r '.failures' <<< "$recon_json")
    fi

    # Copy playwright report
    recon_report="$RECON_ROOT/e2e/playwright-report"
    [[ -d "$recon_report" ]] && cp -r "$recon_report" "$OUTPUT_DIR/playwright-report-recon"

    color=$([ "$recon_exit" -eq 0 ] && echo "$GREEN" || echo "$YELLOW")
    echo -e "${color}  [✓] Reconciliation e2e complete (exit: $recon_exit)${NC}"
else
    echo -e "${GRAY}  [─] Reconciliation e2e skipped (--skip-recon)${NC}"
fi

# ── Payment e2e ───────────────────────────────────────────────────────────────
pay_passed=0 pay_failed=0 pay_skipped=0 pay_total=0 pay_rate=0 pay_exit=-1
pay_failures='[]'

if (( !SKIP_PAYMENT )); then
    pay_log="$OUTPUT_DIR/e2e-payment.log"
    pay_results_json="$PAYMENT_ROOT/e2e/test-results/results.json"
    [[ -f "$pay_results_json" ]] && rm -f "$pay_results_json"

    echo -e "${YELLOW}  [→] Running Payment e2e suite...${NC}"
    pay_exit=0
    (
        cd "$PAYMENT_ROOT"
        export PAYMENT_URL="$PAYMENT_URL"
        export PLAYWRIGHT_JSON_OUTPUT_NAME="$pay_results_json"
        npx playwright test --reporter=json,line 2>&1
    ) > "$pay_log" || pay_exit=$?

    if [[ -f "$pay_results_json" ]]; then
        pay_json=$(parse_playwright_results "$pay_results_json")
        pay_passed=$(jq -r '.passed'  <<< "$pay_json")
        pay_failed=$(jq -r '.failed'  <<< "$pay_json")
        pay_skipped=$(jq -r '.skipped' <<< "$pay_json")
        pay_total=$(jq -r '.total'   <<< "$pay_json")
        pay_rate=$(jq -r '.passRate' <<< "$pay_json")
        pay_failures=$(jq -r '.failures' <<< "$pay_json")
    fi

    pay_report="$PAYMENT_ROOT/e2e/playwright-report"
    [[ -d "$pay_report" ]] && cp -r "$pay_report" "$OUTPUT_DIR/playwright-report-payment"

    color=$([ "$pay_exit" -eq 0 ] && echo "$GREEN" || echo "$YELLOW")
    echo -e "${color}  [✓] Payment e2e complete (exit: $pay_exit)${NC}"
else
    echo -e "${GRAY}  [─] Payment e2e skipped (--skip-payment)${NC}"
fi

# ── Write e2e-results.json ────────────────────────────────────────────────────
combined_passed=$(( recon_passed + pay_passed ))
combined_failed=$(( recon_failed + pay_failed ))
combined_total=$(( recon_total + pay_total ))
combined_rate=0
if (( combined_passed + combined_failed > 0 )); then
    combined_rate=$(echo "scale=4; $combined_passed / ($combined_passed + $combined_failed)" | bc)
fi

e2e_results_path="$OUTPUT_DIR/e2e-results.json"

jq -n \
    --arg  ts          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg  reconUrl    "$RECON_URL" \
    --arg  paymentUrl  "$PAYMENT_URL" \
    --argjson reconPassed   "$recon_passed" \
    --argjson reconFailed   "$recon_failed" \
    --argjson reconSkipped  "$recon_skipped" \
    --argjson reconTotal    "$recon_total" \
    --argjson reconRate     "$recon_rate" \
    --argjson reconExit     "$recon_exit" \
    --argjson reconFails    "$recon_failures" \
    --argjson payPassed     "$pay_passed" \
    --argjson payFailed     "$pay_failed" \
    --argjson paySkipped    "$pay_skipped" \
    --argjson payTotal      "$pay_total" \
    --argjson payRate       "$pay_rate" \
    --argjson payExit       "$pay_exit" \
    --argjson payFails      "$pay_failures" \
    --argjson combPassed    "$combined_passed" \
    --argjson combFailed    "$combined_failed" \
    --argjson combTotal     "$combined_total" \
    --argjson combRate      "$combined_rate" \
    '{
        timestamp: $ts,
        reconUrl: $reconUrl,
        paymentUrl: $paymentUrl,
        recon: {
            passed: $reconPassed, failed: $reconFailed, skipped: $reconSkipped,
            total: $reconTotal, passRate: $reconRate, exitCode: $reconExit,
            failures: $reconFails
        },
        payment: {
            passed: $payPassed, failed: $payFailed, skipped: $paySkipped,
            total: $payTotal, passRate: $payRate, exitCode: $payExit,
            failures: $payFails
        },
        combined: {
            passed: $combPassed, failed: $combFailed,
            total: $combTotal, passRate: $combRate
        }
    }' > "$e2e_results_path"

# ── Summary ───────────────────────────────────────────────────────────────────
pct() { echo "scale=1; $1 * 100" | bc | sed 's/\.0*$//'; }

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  E2E Results${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""

if (( !SKIP_RECON )); then
    color=$([ "$recon_failed" -eq 0 ] && [ "$recon_total" -gt 0 ] && echo "$GREEN" || echo "$YELLOW")
    echo -e "${color}  Recon E2E:   $recon_passed/$recon_total passed ($(pct "$recon_rate")%)${NC}"
fi
if (( !SKIP_PAYMENT )); then
    color=$([ "$pay_failed" -eq 0 ] && [ "$pay_total" -gt 0 ] && echo "$GREEN" || echo "$YELLOW")
    echo -e "${color}  Payment E2E: $pay_passed/$pay_total passed ($(pct "$pay_rate")%)${NC}"
fi
color=$([ "$combined_failed" -eq 0 ] && [ "$combined_total" -gt 0 ] && echo "$GREEN" || echo "$YELLOW")
echo -e "${color}  Combined:    $combined_passed/$combined_total passed${NC}"
echo ""
echo -e "${CYAN}  Results written to: $e2e_results_path${NC}"
echo ""
