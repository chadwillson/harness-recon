#!/usr/bin/env bash
# stop-suite.sh — Stop Recon + Payment local dev services (WSL-native)
set -euo pipefail

RECON_ROOT="/mnt/d/DocumentReconciliation"
PID_FILE="$RECON_ROOT/WorkingFiles/suite-pids.json"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; GRAY='\033[0;90m'; NC='\033[0m'

echo ""
echo -e "${CYAN}============================================================================${NC}"
echo -e "${CYAN}  Harness-Recon  |  Suite Stop                                             ${NC}"
echo -e "${CYAN}============================================================================${NC}"
echo ""

stopped=0

# Stop by PID file
if [[ -f "$PID_FILE" ]]; then
    while IFS=': ' read -r name pid; do
        pid=$(echo "$pid" | tr -d ' ",')
        [[ -z "$pid" || "$pid" == "null" || "$pid" == "{" || "$pid" == "}" ]] && continue
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null && echo -e "${GRAY}  Stopped: $name (PID $pid)${NC}" && (( stopped++ )) || true
        fi
    done < <(python3 -c "
import json
d = json.load(open('$PID_FILE'))
for k, v in d.items():
    if v: print(k, v)
" 2>/dev/null || true)
    rm -f "$PID_FILE"
fi

# Stop by process name (catches orphans)
for pattern in "Tideline.Reconciliation" "Tideline.Payment"; do
    count=$(pgrep -f "$pattern" 2>/dev/null | wc -l || echo 0)
    if (( count > 0 )); then
        pkill -f "$pattern" 2>/dev/null || true
        echo -e "${GRAY}  Stopped: $pattern ($count instance(s))${NC}"
        (( stopped += count ))
    fi
done

# Stop React UI (webpack/node from DocumentReconciliation)
node_count=$(pgrep -f "documentreconciliation.*webpack\|webpack.*documentreconciliation\|npm.*start" 2>/dev/null | wc -l || echo 0)
if (( node_count > 0 )); then
    pkill -f "documentreconciliation" 2>/dev/null || true
    echo -e "${GRAY}  Stopped: React UI node ($node_count process(es))${NC}"
    (( stopped += node_count ))
fi

echo ""
echo -e "${GREEN}  Stopped $stopped process(es).${NC}"
echo ""
