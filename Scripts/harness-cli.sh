#!/usr/bin/env bash
# harness-cli.sh — CLI for querying the Harness-Recon experience store (bash port of harness-cli.ps1)
#
# Usage:
#   bash Scripts/harness-cli.sh list-iterations
#   bash Scripts/harness-cli.sh show-scores 3
#   bash Scripts/harness-cli.sh show-traces [N]
#   bash Scripts/harness-cli.sh diff-scores A B
#   bash Scripts/harness-cli.sh compare-source A B
#   bash Scripts/harness-cli.sh pareto-frontier
#   bash Scripts/harness-cli.sh top-k [K]
#   bash Scripts/harness-cli.sh show-hypothesis N
#   bash Scripts/harness-cli.sh show-outcome N
#   bash Scripts/harness-cli.sh summary
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"
POPULATION_ROOT="$HARNESS_ROOT/Population"
RESULTS_ROOT="$HARNESS_ROOT/Results"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; GRAY='\033[0;90m'; NC='\033[0m'

COMMAND="${1:-list-iterations}"; shift || true
ARG1="${1:-}"; ARG2="${2:-}"

fmt_rate() { python3 -c "print(f'{$1*100:.1f}%')"; }
fmt_delta() { python3 -c "d=$1; print(f'+{d*100:.2f}pp' if d>=0 else f'{d*100:.2f}pp')"; }

get_iter_dir() {
    local n; n=$(printf "%03d" "$1")
    local path="$POPULATION_ROOT/iteration-$n"
    [[ -d "$path" ]] && echo "$path" && return
    path="$POPULATION_ROOT/iteration-$1"
    echo "$path"
}

all_scores_json() {
    # Returns a JSON array of all scores sorted by iteration label
    python3 - "$POPULATION_ROOT" <<'PYEOF'
import sys, os, json
pop = sys.argv[1]
scores = []
for d in sorted(os.listdir(pop)):
    sf = os.path.join(pop, d, "scores.json")
    if os.path.isfile(sf):
        try: scores.append(json.load(open(sf)))
        except: pass
print(json.dumps(scores))
PYEOF
}

_tmpjson=$(mktemp)
trap 'rm -f "$_tmpjson"' EXIT

case "$COMMAND" in

list-iterations)
    all=$(all_scores_json)
    count=$(echo "$all" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}  No iterations found. Run initialize-baseline.sh first.${NC}"
        exit 0
    fi
    echo ""
    printf "${CYAN}  %-5s | %-6s | %-8s | %-8s | %-6s | %-6s | %s${NC}\n" \
        "Iter" "Recon%" "Handler%" "Payment%" "Cover%" "Pareto" "Hypothesis"
    echo -e "${GRAY}  ------+--------+----------+----------+--------+--------+------------------------------------------${NC}"
    echo "$all" > "$_tmpjson"
    python3 - "$_tmpjson" <<'PYEOF'
import sys, json, math
rows = json.load(open(sys.argv[1]))
GREEN = '\033[0;32m'; GRAY = '\033[0;90m'; NC = '\033[0m'
for s in rows:
    m = s.get('metrics', {})
    recon   = f"{m.get('reconUnitTests',{}).get('passRate',0)*100:.1f}%"
    handler = f"{m.get('reconHandlerTests',{}).get('passRate',0)*100:.1f}%"
    payment = f"{m.get('paymentUnitTests',{}).get('passRate',0)*100:.1f}%"
    cov     = f"{m.get('coverage',{}).get('lineRate',0)*100:.1f}%"
    pareto  = "*" if s.get('paretoStatus') == 'frontier' else " "
    hyp     = (s.get('hypothesis') or '')[:40]
    label   = s.get('iterationLabel','?').replace('iteration-','')
    color   = GREEN if s.get('paretoStatus') == 'frontier' else GRAY
    print(f"{color}  {label:<5} | {recon:<6} | {handler:<8} | {payment:<8} | {cov:<6} | {pareto:<6} | {hyp}{NC}")
PYEOF
    echo -e "${GRAY}  (* = Pareto frontier)${NC}"
    echo ""
    ;;

show-scores)
    [[ -z "$ARG1" ]] && { echo -e "${RED}Usage: harness-cli.sh show-scores <N>${NC}"; exit 1; }
    sf="$(get_iter_dir "$ARG1")/scores.json"
    [[ -f "$sf" ]] || { echo -e "${RED}  Iteration $ARG1 not found.${NC}"; exit 1; }
    jq . "$sf"
    ;;

show-traces)
    if [[ -z "$ARG1" ]]; then
        ARG1=$(ls -d "$POPULATION_ROOT"/iteration-*/ 2>/dev/null | sort | tail -1 | xargs basename | sed 's/iteration-//')
    fi
    [[ -z "$ARG1" ]] && { echo -e "${YELLOW}  No iterations found.${NC}"; exit 0; }
    ft="$(get_iter_dir "$ARG1")/traces/failed-tests.json"
    [[ -f "$ft" ]] || { echo -e "${YELLOW}  No test traces found for iteration $ARG1.${NC}"; exit 0; }

    python3 - "$ft" <<'PYEOF'
import sys, json
YELLOW = '\033[1;33m'; WHITE = '\033[1;37m'; RED = '\033[0;31m'; GREEN = '\033[0;32m'; NC = '\033[0m'
data = json.load(open(sys.argv[1]))
suites = [('reconUnit','Reconciliation Unit'),('reconHandler','Reconciliation Handler'),('paymentUnit','Payment Unit')]
total = 0
for key, label in suites:
    items = data.get(key) or []
    if not items: continue
    total += len(items)
    print(f"\n{YELLOW}  [{label}] {len(items)} failure(s){NC}")
    for f in items:
        name = f.get('testName','?')
        msg  = (f.get('errorMessage') or '')[:120]
        if len(f.get('errorMessage','')) > 120: msg += '...'
        print(f"{WHITE}    * {name}{NC}")
        print(f"{RED}      {msg}{NC}\n")
if total == 0:
    print(f"\n{GREEN}  No failures! (All tests passed){NC}")
print()
PYEOF
    ;;

diff-scores)
    [[ -z "$ARG1" || -z "$ARG2" ]] && { echo -e "${RED}Usage: harness-cli.sh diff-scores <A> <B>${NC}"; exit 1; }
    sf_a="$(get_iter_dir "$ARG1")/scores.json"
    sf_b="$(get_iter_dir "$ARG2")/scores.json"
    [[ -f "$sf_a" ]] || { echo -e "${RED}  Iteration $ARG1 not found.${NC}"; exit 1; }
    [[ -f "$sf_b" ]] || { echo -e "${RED}  Iteration $ARG2 not found.${NC}"; exit 1; }

    python3 - "$sf_a" "$sf_b" "$ARG1" "$ARG2" <<'PYEOF'
import sys, json
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; GRAY='\033[0;90m'; NC='\033[0m'
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
A, B = sys.argv[3], sys.argv[4]
ma = a.get('metrics',{}); mb = b.get('metrics',{})
print(f"\n{CYAN}  Diff: iteration-{A} → iteration-{B}{NC}\n")
print(f"{CYAN}  {'Metric':<20} | {f'iter-{A}':<9} | {f'iter-{B}':<9} | Delta{NC}")
print(f"{GRAY}  {'─'*20}+{'─'*11}+{'─'*11}+{'─'*10}{NC}")
metrics = [
    ("Recon unit rate   ", ma.get('reconUnitTests',{}).get('passRate',0),    mb.get('reconUnitTests',{}).get('passRate',0)),
    ("Handler rate      ", ma.get('reconHandlerTests',{}).get('passRate',0), mb.get('reconHandlerTests',{}).get('passRate',0)),
    ("Payment unit rate ", ma.get('paymentUnitTests',{}).get('passRate',0),  mb.get('paymentUnitTests',{}).get('passRate',0)),
    ("Coverage line     ", ma.get('coverage',{}).get('lineRate',0),          mb.get('coverage',{}).get('lineRate',0)),
    ("Overall use cases ", ma.get('useCases',{}).get('passRate',0),          mb.get('useCases',{}).get('passRate',0)),
]
for label, va, vb in metrics:
    delta = vb - va
    color = GREEN if delta > 0.001 else (RED if delta < -0.001 else GRAY)
    d_str = f"+{delta*100:.2f}pp" if delta >= 0 else f"{delta*100:.2f}pp"
    print(f"{color}  {label} | {va*100:.1f}%     | {vb*100:.1f}%     | {d_str}{NC}")
print(f"\n{GRAY}  Pareto: {a.get('paretoStatus','?')} → {b.get('paretoStatus','?')}{NC}\n")
PYEOF
    ;;

compare-source)
    [[ -z "$ARG1" || -z "$ARG2" ]] && { echo -e "${RED}Usage: harness-cli.sh compare-source <A> <B>${NC}"; exit 1; }
    snap_a="$(get_iter_dir "$ARG1")/source-snapshot.json"
    snap_b="$(get_iter_dir "$ARG2")/source-snapshot.json"
    [[ -f "$snap_a" && -f "$snap_b" ]] || { echo -e "${RED}  Snapshots not found for both iterations.${NC}"; exit 1; }

    python3 - "$snap_a" "$snap_b" "$ARG1" "$ARG2" <<'PYEOF'
import sys, json
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; GRAY='\033[0;90m'; NC='\033[0m'
a = {x['path']: x for x in json.load(open(sys.argv[1]))}
b = {x['path']: x for x in json.load(open(sys.argv[2]))}
A, B = sys.argv[3], sys.argv[4]
changed = []
for path in sorted(set(a) | set(b)):
    if path in a and path in b:
        if a[path]['lastModified'] != b[path]['lastModified']:
            changed.append((path, 'modified'))
    elif path in b: changed.append((path, 'added'))
    else:           changed.append((path, 'removed'))
print(f"\n{CYAN}  Source changes: iteration-{A} → iteration-{B}{NC}")
print(f"{GRAY}  ({len(changed)} file(s) changed){NC}\n")
for path, status in changed:
    color = GREEN if status == 'added' else (RED if status == 'removed' else YELLOW)
    print(f"{color}  [{status:<8}] {path}{NC}")
print()
PYEOF
    ;;

pareto-frontier)
    frontier_file="$RESULTS_ROOT/pareto-frontier.json"
    if [[ -f "$frontier_file" ]]; then
        frontier=$(cat "$frontier_file")
    else
        frontier=$(all_scores_json | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(json.dumps([x for x in d if x.get('paretoStatus')=='frontier']))")
    fi
    count=$(echo "$frontier" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}  No Pareto-frontier iterations found.${NC}"; exit 0
    fi
    echo ""
    echo -e "${CYAN}  Pareto Frontier ($count iteration(s))${NC}"
    echo ""
    echo "$frontier" > "$_tmpjson"
    python3 - "$_tmpjson" <<'PYEOF'
import sys, json
GREEN='\033[0;32m'; WHITE='\033[1;37m'; GRAY='\033[0;90m'; NC='\033[0m'
for s in json.load(open(sys.argv[1])):
    m = s.get('metrics',{})
    label = s.get('iterationLabel','?').replace('iteration-','')
    print(f"{GREEN}  iteration-{label}{NC}")
    print(f"{WHITE}    Recon Unit:    {m.get('reconUnitTests',{}).get('passRate',0)*100:.1f}%{NC}")
    print(f"{WHITE}    Recon Handler: {m.get('reconHandlerTests',{}).get('passRate',0)*100:.1f}%{NC}")
    print(f"{WHITE}    Payment Unit:  {m.get('paymentUnitTests',{}).get('passRate',0)*100:.1f}%{NC}")
    print(f"{WHITE}    Coverage:      {m.get('coverage',{}).get('lineRate',0)*100:.1f}%{NC}")
    print(f"{GRAY}    Hypothesis:    {s.get('hypothesis','')[:60]}{NC}\n")
PYEOF
    ;;

top-k)
    k="${ARG1:-5}"
    all=$(all_scores_json)
    count=$(echo "$all" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    [[ "$count" -eq 0 ]] && { echo -e "${YELLOW}  No iterations found.${NC}"; exit 0; }
    echo ""
    echo -e "${CYAN}  Top $k by Overall Pass Rate${NC}"
    echo ""
    echo "$all" > "$_tmpjson"
    python3 - "$_tmpjson" "$k" <<'PYEOF'
import sys, json
GREEN='\033[0;32m'; GRAY='\033[0;90m'; NC='\033[0m'
rows = sorted(json.load(open(sys.argv[1])), key=lambda s: s.get('metrics',{}).get('useCases',{}).get('passRate',0), reverse=True)
k = int(sys.argv[2])
for i, s in enumerate(rows[:k], 1):
    m  = s.get('metrics',{})
    ov = m.get('useCases',{}).get('passRate',0)
    cv = m.get('coverage',{}).get('lineRate',0)
    lbl = s.get('iterationLabel','?').replace('iteration-','')
    star = " *" if s.get('paretoStatus') == 'frontier' else "  "
    color = GREEN if s.get('paretoStatus') == 'frontier' else GRAY
    print(f"{color}  #{i}{star} iteration-{lbl} | Overall: {ov*100:.1f}% | Cover: {cv*100:.1f}%{NC}")
    print(f"{GRAY}       {(s.get('hypothesis') or '')[:60]}{NC}")
print()
PYEOF
    ;;

show-hypothesis)
    [[ -z "$ARG1" ]] && { echo -e "${RED}Usage: harness-cli.sh show-hypothesis <N>${NC}"; exit 1; }
    hf="$(get_iter_dir "$ARG1")/hypothesis.md"
    [[ -f "$hf" ]] && cat "$hf" || echo "  No hypothesis found for iteration $ARG1."
    ;;

show-outcome)
    [[ -z "$ARG1" ]] && { echo -e "${RED}Usage: harness-cli.sh show-outcome <N>${NC}"; exit 1; }
    of="$(get_iter_dir "$ARG1")/outcome.md"
    [[ -f "$of" ]] && cat "$of" || echo "  No outcome found for iteration $ARG1."
    ;;

show-contract)
    if [[ -z "$ARG1" ]]; then
        ARG1=$(ls -d "$POPULATION_ROOT"/iteration-*/ 2>/dev/null | sort | tail -1 | xargs basename | sed 's/iteration-//')
    fi
    [[ -z "$ARG1" ]] && { echo -e "${YELLOW}  No iterations found.${NC}"; exit 0; }
    sf="$(get_iter_dir "$ARG1")/scores.json"
    [[ -f "$sf" ]] || { echo -e "${RED}  Iteration $ARG1 not found.${NC}"; exit 1; }
    cr=$(jq -r '.contractResults // empty' "$sf")
    if [[ -z "$cr" ]]; then
        echo -e "\n${YELLOW}  No success criteria defined for iteration $ARG1.${NC}"
        echo -e "${GRAY}  Add a ## Success Criteria section to hypothesis.md${NC}\n"
        exit 0
    fi
    echo "$cr" > "$_tmpjson"
    python3 - "$_tmpjson" "$ARG1" <<'PYEOF'
import sys, json
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; GRAY='\033[0;90m'; NC='\033[0m'
cr = json.load(open(sys.argv[1])); A = sys.argv[2]
color = GREEN if cr.get('missedCount',0) == 0 else '\033[1;33m'
print(f"\n{CYAN}  Hypothesis Contract — Iteration {A}{NC}")
print(f"{color}  {cr.get('metCount',0)}/{cr.get('totalCriteria',0)} criteria met{NC}\n")
for c in cr.get('criteria', []):
    status = "PASS" if c.get('met') else "MISS"
    color  = GREEN if c.get('met') else RED
    actual = str(c.get('actual','N/A'))
    if c.get('error'): actual = f"ERR: {c['error']}"
    print(f"{color}  {c.get('carrier',''):<25} | {c.get('metric',''):<15} | {c.get('operator','')} {c.get('target','')} | {actual:<11} | {status}{NC}")
print()
PYEOF
    ;;

summary)
    all=$(all_scores_json)
    count=$(echo "$all" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    [[ "$count" -eq 0 ]] && { echo -e "${YELLOW}  No iterations yet. Run initialize-baseline.sh to begin.${NC}"; exit 0; }
    echo "$all" > "$_tmpjson"
    python3 - "$_tmpjson" <<'PYEOF'
import sys, json
CYAN='\033[0;36m'; GREEN='\033[0;32m'; WHITE='\033[1;37m'; NC='\033[0m'
rows = json.load(open(sys.argv[1]))
frontier = [s for s in rows if s.get('paretoStatus') == 'frontier']
best = max(rows, key=lambda s: s.get('metrics',{}).get('useCases',{}).get('passRate',0))
best_cov = max(rows, key=lambda s: s.get('metrics',{}).get('coverage',{}).get('lineRate',0))
bm = best.get('metrics',{})
print(f"\n{CYAN}  Harness-Recon Search Summary{NC}")
print(f"{WHITE}  Iterations evaluated: {len(rows)}{NC}")
print(f"{WHITE}  Pareto frontier size: {len(frontier)}{NC}")
print(f"{GREEN}  Best overall pass rate: {bm.get('useCases',{}).get('passRate',0)*100:.1f}% (iteration-{best.get('iterationLabel','?').replace('iteration-','')}){NC}")
print(f"{GREEN}  Best coverage: {best_cov.get('metrics',{}).get('coverage',{}).get('lineRate',0)*100:.1f}%{NC}\n")
PYEOF
    ;;

*)
    echo -e "${RED}  Unknown command: $COMMAND${NC}"
    echo "  Available: list-iterations, show-scores, show-traces, show-contract, diff-scores,"
    echo "             compare-source, pareto-frontier, top-k, show-hypothesis, show-outcome, summary"
    exit 1
    ;;
esac
