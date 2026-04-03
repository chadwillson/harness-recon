#!/usr/bin/env bash
# evaluate.sh — Full evaluation runner for the optimization loop (bash port of evaluate.ps1)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"
RECON_ROOT="/mnt/d/DocumentReconciliation"
PAYMENT_ROOT="/mnt/d/DocumentPayment"
POPULATION_ROOT="$HARNESS_ROOT/Population"
RESULTS_ROOT="$HARNESS_ROOT/Results"
HYPOTHESIS_FILE="Search/current-hypothesis.md"
ITERATION_LABEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hypothesis) HYPOTHESIS_FILE="$2"; shift ;;
        --iteration)  ITERATION_LABEL="$2"; shift ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
    shift
done

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; GRAY='\033[0;90m'; NC='\033[0m'

# ── Determine iteration ───────────────────────────────────────────────────────
get_next_iteration() {
    local max=0
    for d in "$POPULATION_ROOT"/iteration-*/; do
        [[ -d "$d" ]] || continue
        local n; n=$(basename "$d" | sed 's/iteration-//' | sed 's/^0*//')
        [[ -z "$n" ]] && n=0
        (( n > max )) && max=$n
    done
    echo $(( max + 1 ))
}

if [[ -z "$ITERATION_LABEL" ]]; then
    ITERATION_LABEL=$(printf "%03d" "$(get_next_iteration)")
fi

ITER_DIR="$POPULATION_ROOT/iteration-$ITERATION_LABEL"
TRACES_DIR="$ITER_DIR/traces"
mkdir -p "$ITER_DIR" "$TRACES_DIR" "$RESULTS_ROOT"

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Harness-Recon Evaluator  |  Iteration $ITERATION_LABEL${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""

# ── Capture hypothesis ────────────────────────────────────────────────────────
hyp_path="$HARNESS_ROOT/$HYPOTHESIS_FILE"
if [[ -f "$hyp_path" ]]; then
    cp "$hyp_path" "$ITER_DIR/hypothesis.md"
    echo -e "${GREEN}  [✓] Hypothesis captured${NC}"
else
    echo -e "${YELLOW}  [!] No hypothesis file at $HYPOTHESIS_FILE — proceeding without it${NC}"
    echo "No hypothesis recorded for this iteration." > "$ITER_DIR/hypothesis.md"
fi

# ── Capture source snapshot ───────────────────────────────────────────────────
echo -e "${YELLOW}  [→] Capturing source snapshot...${NC}"

snapshot_json=$(python3 - "$RECON_ROOT" "$PAYMENT_ROOT" <<'PYEOF'
import sys, os, json
from datetime import timezone

entries = []
for root_path, prefix in [(sys.argv[1], "DocumentReconciliation"), (sys.argv[2], "DocumentPayment")]:
    api_dir = os.path.join(root_path, f"Tideline.{prefix.replace('Document','')}.Api")
    for dirpath, _, files in os.walk(root_path):
        for f in files:
            if not f.endswith(".cs"): continue
            full = os.path.join(dirpath, f)
            rel = prefix + "/" + full.replace(root_path, "").lstrip("/\\")
            stat = os.stat(full)
            entries.append({"path": rel, "sizeBytes": stat.st_size,
                             "lastModified": __import__('datetime').datetime.fromtimestamp(
                                 stat.st_mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
print(json.dumps(entries))
PYEOF
)
echo "$snapshot_json" > "$ITER_DIR/source-snapshot.json"
count=$(echo "$snapshot_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
echo -e "${GREEN}  [✓] Source snapshot: $count files${NC}"

# ── Build ─────────────────────────────────────────────────────────────────────
build_failed=0
build_log_file="$TRACES_DIR/build.log"
> "$build_log_file"

build_project() {
    local proj="$1"
    if [[ ! -f "$proj" && ! -d "$proj" ]]; then
        echo -e "${GRAY}  [!] Project not found (skipped): $proj${NC}"
        return 0
    fi
    local name; name=$(basename "$proj")
    local out; out=$(dotnet build "$proj" --configuration Release 2>&1)
    echo "$out" >> "$build_log_file"
    if [[ $? -ne 0 ]] || echo "$out" | grep -q "Build FAILED"; then
        echo -e "${RED}  [✗] Build FAILED: $name${NC}"
        echo "$out" | tail -10
        build_failed=1
    fi
}

echo -e "${YELLOW}  [→] Building DocumentReconciliation solution...${NC}"
for proj in \
    "$RECON_ROOT/Tideline.Reconciliation.Api/Tideline.Reconciliation.Api.csproj" \
    "$RECON_ROOT/Tideline.Reconciliation.Domain/Tideline.Reconciliation.Domain.csproj" \
    "$RECON_ROOT/Tideline.Reconciliation.Api.Tests/Tideline.Reconciliation.Api.Tests.csproj"; do
    build_project "$proj"
done
# Handler tests if present
handler_test="$RECON_ROOT/Tideline.Reconciliation.EventHubHandler.Tests/Tideline.Reconciliation.EventHubHandler.Tests.csproj"
[[ -f "$handler_test" ]] && build_project "$handler_test"

echo -e "${YELLOW}  [→] Building DocumentPayment solution...${NC}"
for proj in \
    "$PAYMENT_ROOT/Tideline.Payment.Api/Tideline.Payment.Api.csproj" \
    "$PAYMENT_ROOT/Tideline.Payment.Domain/Tideline.Payment.Domain.csproj" \
    "$PAYMENT_ROOT/Tideline.Payment.Api.Tests/Tideline.Payment.Api.Tests.csproj"; do
    build_project "$proj"
done

if (( build_failed )); then
    jq -n --argjson iter "${ITERATION_LABEL#0}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{iteration:$iter,buildFailed:true,timestamp:$ts}' > "$ITER_DIR/scores.json"
    exit 1
fi
echo -e "${GREEN}  [✓] Build succeeded${NC}"

# ── Run tests ─────────────────────────────────────────────────────────────────
run_dotnet_test() {
    local proj="$1" trx="$2" log="$3"
    if [[ ! -d "$proj" && ! -f "$proj" ]]; then echo "-1"; return; fi
    dotnet test "$proj" \
        --no-build --configuration Release \
        --logger "trx;LogFileName=$trx" \
        --verbosity normal > "$log" 2>&1 && echo 0 || echo $?
}

echo -e "${YELLOW}  [→] Running Reconciliation unit tests...${NC}"
recon_exit=$(run_dotnet_test \
    "$RECON_ROOT/Tideline.Reconciliation.Api.Tests" \
    "$TRACES_DIR/recon-unit-tests.trx" \
    "$TRACES_DIR/recon-unit-tests.log")
echo -e "$([ "$recon_exit" -eq 0 ] && echo $GREEN || echo $YELLOW)  [✓] Reconciliation unit tests complete (exit: $recon_exit)${NC}"

# Coverage
cov_src="$RECON_ROOT/Tideline.Reconciliation.Api.Tests/coverage.cobertura.xml"
[[ -f "$cov_src" ]] && cp "$cov_src" "$TRACES_DIR/coverage.xml"

handler_exit=-1
handler_test_dir="$RECON_ROOT/Tideline.Reconciliation.EventHubHandler.Tests"
if [[ -d "$handler_test_dir" ]]; then
    echo -e "${YELLOW}  [→] Running Reconciliation handler tests...${NC}"
    handler_exit=$(run_dotnet_test \
        "$handler_test_dir" \
        "$TRACES_DIR/recon-handler-tests.trx" \
        "$TRACES_DIR/recon-handler-tests.log")
    echo -e "$([ "$handler_exit" -eq 0 ] && echo $GREEN || echo $YELLOW)  [✓] Handler tests complete (exit: $handler_exit)${NC}"
else
    echo -e "${GRAY}  [─] Handler test project not found — skipping${NC}"
fi

echo -e "${YELLOW}  [→] Running Payment unit tests...${NC}"
payment_exit=$(run_dotnet_test \
    "$PAYMENT_ROOT/Tideline.Payment.Api.Tests" \
    "$TRACES_DIR/payment-unit-tests.trx" \
    "$TRACES_DIR/payment-unit-tests.log")
echo -e "$([ "$payment_exit" -eq 0 ] && echo $GREEN || echo $YELLOW)  [✓] Payment unit tests complete (exit: $payment_exit)${NC}"

# ── Parse TRX results ─────────────────────────────────────────────────────────
parse_trx() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo '{"passed":0,"failed":0,"total":0,"passRate":0,"failures":[]}'
        return
    fi
    python3 - "$path" <<'PYEOF'
import sys, json
import xml.etree.ElementTree as ET

path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
ns = {'t': 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010'}

counters = root.find('.//t:Counters', ns)
passed = int(counters.get('passed', 0)) if counters is not None else 0
failed = int(counters.get('failed', 0)) if counters is not None else 0
total  = passed + failed
rate   = round(passed / total, 4) if total > 0 else 0

failures = []
for r in root.findall('.//t:UnitTestResult', ns):
    if r.get('outcome') == 'Failed':
        msg_el = r.find('.//t:Message', ns)
        st_el  = r.find('.//t:StackTrace', ns)
        failures.append({
            'testName':     r.get('testName', ''),
            'errorMessage': msg_el.text.strip() if msg_el is not None and msg_el.text else '',
            'stackTrace':   (st_el.text or '').split('\n')[0] if st_el is not None else ''
        })

print(json.dumps({'passed':passed,'failed':failed,'total':total,'passRate':rate,'failures':failures}))
PYEOF
}

recon_data=$(parse_trx   "$TRACES_DIR/recon-unit-tests.trx")
handler_data=$(parse_trx "$TRACES_DIR/recon-handler-tests.trx")
payment_data=$(parse_trx "$TRACES_DIR/payment-unit-tests.trx")

# ── Parse coverage ────────────────────────────────────────────────────────────
parse_coverage() {
    local path="$1"
    if [[ ! -f "$path" ]]; then echo '{"lineRate":0,"branchRate":0}'; return; fi
    python3 - "$path" <<'PYEOF'
import sys, json, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
print(json.dumps({
    'lineRate':   round(float(root.get('line-rate',   '0')), 4),
    'branchRate': round(float(root.get('branch-rate', '0')), 4)
}))
PYEOF
}

coverage_data=$(parse_coverage "$TRACES_DIR/coverage.xml")

# ── Write failed-tests.json ───────────────────────────────────────────────────
jq -n \
    --argjson reconUnit    "$(jq '.failures' <<< "$recon_data")" \
    --argjson reconHandler "$(jq '.failures' <<< "$handler_data")" \
    --argjson paymentUnit  "$(jq '.failures' <<< "$payment_data")" \
    '{reconUnit:$reconUnit,reconHandler:$reconHandler,paymentUnit:$paymentUnit}' \
    > "$TRACES_DIR/failed-tests.json"

# ── Load existing e2e results ─────────────────────────────────────────────────
e2e_path="$TRACES_DIR/e2e-results.json"
if [[ -f "$e2e_path" ]]; then
    e2e_recon=$(jq '.recon'   "$e2e_path")
    e2e_pay=$(jq '.payment'   "$e2e_path")
    e2e_present=true
else
    e2e_recon='{"passed":0,"failed":0,"total":0,"passRate":0}'
    e2e_pay='{"passed":0,"failed":0,"total":0,"passRate":0}'
    e2e_present=false
fi

# ── Compute metrics ───────────────────────────────────────────────────────────
total_passed=$(jq -r '[.passed] | add' <<< "$recon_data $handler_data $payment_data" 2>/dev/null || \
    python3 -c "import json; d=[json.loads(x) for x in '''$recon_data $handler_data $payment_data'''.split()]; print(sum(x['passed'] for x in d))")
# Simpler approach:
r_p=$(jq -r '.passed' <<< "$recon_data")
r_t=$(jq -r '.total'  <<< "$recon_data")
h_p=$(jq -r '.passed' <<< "$handler_data")
h_t=$(jq -r '.total'  <<< "$handler_data")
py_p=$(jq -r '.passed' <<< "$payment_data")
py_t=$(jq -r '.total'  <<< "$payment_data")

total_passed=$(( r_p + h_p + py_p ))
total_tests=$(( r_t + h_t + py_t ))
overall_rate=0
(( total_tests > 0 )) && overall_rate=$(echo "scale=4; $total_passed / $total_tests" | bc)

# ── Compute delta from prior ──────────────────────────────────────────────────
prior_num=$(( 10#$ITERATION_LABEL - 1 ))
prior_label=$(printf "%03d" "$prior_num")
prior_scores="$POPULATION_ROOT/iteration-$prior_label/scores.json"
delta_json='{}'
if [[ -f "$prior_scores" ]]; then
    delta_json=$(jq -r \
        --argjson cur_recon    "$(jq '.passRate' <<< "$recon_data")" \
        --argjson cur_payment  "$(jq '.passRate' <<< "$payment_data")" \
        --argjson cur_cov      "$(jq '.lineRate' <<< "$coverage_data")" \
        --argjson cur_overall  "$overall_rate" \
        '{
            reconUnitPassRate:   ($cur_recon   - .metrics.reconUnitTests.passRate   | . * 10000 | round / 10000),
            paymentUnitPassRate: ($cur_payment - .metrics.paymentUnitTests.passRate | . * 10000 | round / 10000),
            coverage:            ($cur_cov     - .metrics.coverage.lineRate          | . * 10000 | round / 10000),
            overallPassRate:     ($cur_overall - .metrics.useCases.passRate          | . * 10000 | round / 10000)
        }' "$prior_scores")
fi

# ── Pareto check ──────────────────────────────────────────────────────────────
cur_recon_rate=$(jq -r '.passRate' <<< "$recon_data")
cur_pay_rate=$(jq -r '.passRate'   <<< "$payment_data")
cur_cov_rate=$(jq -r '.lineRate'   <<< "$coverage_data")

on_frontier=true
for f in "$POPULATION_ROOT"/iteration-*/scores.json; do
    [[ -f "$f" ]] || continue
    [[ "$f" == "$ITER_DIR/scores.json" ]] && continue
    dominated=$(jq -r \
        --argjson cr "$cur_recon_rate" --argjson cp "$cur_pay_rate" --argjson cc "$cur_cov_rate" \
        'if .metrics.reconUnitTests.passRate >= $cr and
            .metrics.paymentUnitTests.passRate >= $cp and
            .metrics.coverage.lineRate >= $cc and
            (.metrics.reconUnitTests.passRate > $cr or
             .metrics.paymentUnitTests.passRate > $cp or
             .metrics.coverage.lineRate > $cc)
         then "true" else "false" end' "$f")
    if [[ "$dominated" == "true" ]]; then
        on_frontier=false; break
    fi
done
pareto_status=$([ "$on_frontier" = true ] && echo "frontier" || echo "dominated")

# ── Write scores.json ─────────────────────────────────────────────────────────
hypothesis_line=$(head -1 "$ITER_DIR/hypothesis.md" 2>/dev/null || echo "")
iter_num=$(( 10#$ITERATION_LABEL ))
cov_meets=$(jq -r 'if .lineRate >= 0.80 then true else false end' <<< "$coverage_data")

jq -n \
    --argjson iter          "$iter_num" \
    --arg     iterLabel     "iteration-$ITERATION_LABEL" \
    --arg     ts            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg     hypothesis    "$hypothesis_line" \
    --argjson reconUnit     "$recon_data" \
    --argjson handlerUnit   "$handler_data" \
    --argjson paymentUnit   "$payment_data" \
    --argjson e2eRecon      "$e2e_recon" \
    --argjson e2ePayment    "$e2e_pay" \
    --argjson e2ePresent    "$e2e_present" \
    --argjson coverage      "$coverage_data" \
    --argjson covMeets      "$cov_meets" \
    --argjson totalPassed   "$total_passed" \
    --argjson totalTests    "$total_tests" \
    --argjson overallRate   "$overall_rate" \
    --argjson delta         "$delta_json" \
    --arg     pareto        "$pareto_status" \
    '{
        iteration:      $iter,
        iterationLabel: $iterLabel,
        timestamp:      $ts,
        hypothesis:     $hypothesis,
        buildSucceeded: true,
        metrics: {
            reconUnitTests:    {passed:$reconUnit.passed,   failed:$reconUnit.failed,   total:$reconUnit.total,   passRate:$reconUnit.passRate},
            reconHandlerTests: {passed:$handlerUnit.passed, failed:$handlerUnit.failed, total:$handlerUnit.total, passRate:$handlerUnit.passRate},
            paymentUnitTests:  {passed:$paymentUnit.passed, failed:$paymentUnit.failed, total:$paymentUnit.total, passRate:$paymentUnit.passRate},
            reconE2eTests:     ($e2eRecon   + {present:$e2ePresent}),
            paymentE2eTests:   ($e2ePayment + {present:$e2ePresent}),
            coverage:          {lineRate:$coverage.lineRate, branchRate:$coverage.branchRate, meetsThreshold:$covMeets},
            useCases:          {passed:$totalPassed, total:$totalTests, passRate:$overallRate}
        },
        deltaFromPrior: $delta,
        paretoStatus:   $pareto
    }' > "$ITER_DIR/scores.json"

# ── Update pareto-frontier.json ───────────────────────────────────────────────
frontier_items=()
for f in "$POPULATION_ROOT"/iteration-*/scores.json; do
    [[ -f "$f" ]] || continue
    if [[ "$(jq -r '.paretoStatus' "$f")" == "frontier" ]]; then
        frontier_items+=("$(cat "$f")")
    fi
done
printf '['; first=1
for item in "${frontier_items[@]}"; do
    (( first )) && first=0 || printf ','
    printf '%s' "$item"
done
printf ']' > "$RESULTS_ROOT/pareto-frontier.json"

# ── Write outcome.md ──────────────────────────────────────────────────────────
r_f=$(jq -r '.failed' <<< "$recon_data")
h_f=$(jq -r '.failed' <<< "$handler_data")
py_f=$(jq -r '.failed' <<< "$payment_data")
total_failed=$(( r_f + h_f + py_f ))
cov_pct=$(jq -r '.lineRate * 100 | . * 10 | round / 10' <<< "$coverage_data")
cov_status=$(jq -r 'if .lineRate >= 0.80 then "(✓ meets threshold)" else "(✗ below 80% threshold)" end' <<< "$coverage_data")
r_rate=$(jq -r '.passRate * 100 | . * 10 | round / 10' <<< "$recon_data")
h_rate=$(jq -r '.passRate * 100 | . * 10 | round / 10' <<< "$handler_data")
py_rate=$(jq -r '.passRate * 100 | . * 10 | round / 10' <<< "$payment_data")

if [[ "$e2e_present" == "true" ]]; then
    er_p=$(jq -r '.passed'  <<< "$e2e_recon")
    er_f=$(jq -r '.failed'  <<< "$e2e_recon")
    er_t=$(jq -r '.total'   <<< "$e2e_recon")
    er_r=$(jq -r '.passRate * 100 | . * 10 | round / 10' <<< "$e2e_recon")
    ep_p=$(jq -r '.passed'  <<< "$e2e_pay")
    ep_f=$(jq -r '.failed'  <<< "$e2e_pay")
    ep_t=$(jq -r '.total'   <<< "$e2e_pay")
    ep_r=$(jq -r '.passRate * 100 | . * 10 | round / 10' <<< "$e2e_pay")
    e2e_section="
## E2E Tests (ACI)

| Suite | Passed | Failed | Total | Pass Rate |
|-------|--------|--------|-------|-----------|
| Reconciliation E2E | $er_p | $er_f | $er_t | ${er_r}% |
| Payment E2E | $ep_p | $ep_f | $ep_t | ${ep_r}% |

See \`traces/e2e-results.json\` for failure details."
else
    e2e_section="
## E2E Tests (ACI)

Not run for this iteration. Run \`bash Scripts/deploy.sh --skip-build --skip-deploy\` to add e2e results."
fi

if [[ "$delta_json" != "{}" ]]; then
    dr=$(jq -r '.reconUnitPassRate   * 100 | . * 100 | round / 100' <<< "$delta_json")
    dp=$(jq -r '.paymentUnitPassRate * 100 | . * 100 | round / 100' <<< "$delta_json")
    dc=$(jq -r '.coverage            * 100 | . * 100 | round / 100' <<< "$delta_json")
    delta_section="- Reconciliation unit pass rate: $([ "${dr:0:1}" = "-" ] || echo "+")${dr}pp
- Payment unit pass rate: $([ "${dp:0:1}" = "-" ] || echo "+")${dp}pp
- Coverage: $([ "${dc:0:1}" = "-" ] || echo "+")${dc}pp"
else
    delta_section="No prior iteration to compare against."
fi

cat > "$ITER_DIR/outcome.md" <<OUTCOMEEOF
# Outcome: Iteration $ITERATION_LABEL

**Timestamp:** $(date '+%Y-%m-%d %H:%M:%S')
**Pareto Status:** $pareto_status

## Metrics

| Suite | Passed | Failed | Total | Pass Rate |
|-------|--------|--------|-------|-----------|
| Reconciliation Unit | $(jq -r '.passed' <<< "$recon_data") | $r_f | $(jq -r '.total' <<< "$recon_data") | ${r_rate}% |
| Reconciliation Handler | $(jq -r '.passed' <<< "$handler_data") | $h_f | $(jq -r '.total' <<< "$handler_data") | ${h_rate}% |
| Payment Unit | $(jq -r '.passed' <<< "$payment_data") | $py_f | $(jq -r '.total' <<< "$payment_data") | ${py_rate}% |

**Coverage:** ${cov_pct}% line rate $cov_status
$e2e_section

## Delta from Prior

$delta_section

## Failures

$total_failed total unit/handler test failures. See \`traces/failed-tests.json\` for details.
OUTCOMEEOF

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Evaluation Complete: Iteration $ITERATION_LABEL${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "$([ "$r_f" -eq 0 ] && echo $GREEN || echo $YELLOW)  Recon Unit:    $(jq -r '.passed' <<< "$recon_data")/$(jq -r '.total' <<< "$recon_data") passed (${r_rate}%)${NC}"
echo -e "$([ "$h_f" -eq 0 ] && echo $GREEN || echo $YELLOW)  Recon Handler: $(jq -r '.passed' <<< "$handler_data")/$(jq -r '.total' <<< "$handler_data") passed (${h_rate}%)${NC}"
echo -e "$([ "$py_f" -eq 0 ] && echo $GREEN || echo $YELLOW)  Payment Unit:  $(jq -r '.passed' <<< "$payment_data")/$(jq -r '.total' <<< "$payment_data") passed (${py_rate}%)${NC}"
if [[ "$e2e_present" == "true" ]]; then
    echo -e "$([ "$er_f" -eq 0 ] && echo $GREEN || echo $YELLOW)  Recon E2E:     $er_p/$er_t passed (${er_r}%)${NC}"
    echo -e "$([ "$ep_f" -eq 0 ] && echo $GREEN || echo $YELLOW)  Payment E2E:   $ep_p/$ep_t passed (${ep_r}%)${NC}"
else
    echo -e "${GRAY}  E2E:           (not run — use deploy.sh to add ACI e2e results)${NC}"
fi
cov_color=$(jq -r 'if .lineRate >= 0.80 then "green" else "red" end' <<< "$coverage_data")
[[ "$cov_color" == "green" ]] && echo -e "${GREEN}  Coverage:      ${cov_pct}%${NC}" || echo -e "${RED}  Coverage:      ${cov_pct}%${NC}"
echo -e "$([ "$pareto_status" == "frontier" ] && echo $GREEN || echo $GRAY)  Pareto:        $pareto_status${NC}"
echo ""
echo -e "${CYAN}  Results saved to: Population/iteration-$ITERATION_LABEL/${NC}"
echo ""
