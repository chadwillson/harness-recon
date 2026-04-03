#!/usr/bin/env bash
# start-suite.sh — Start Recon + Payment services for local development (WSL-native)
set -euo pipefail

RECON_ROOT="/mnt/d/DocumentReconciliation"
PAYMENT_ROOT="/mnt/d/DocumentPayment"
LOG_ROOT="$RECON_ROOT/WorkingFiles"
PID_FILE="$LOG_ROOT/suite-pids.json"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; GRAY='\033[0;90m'; NC='\033[0m'

mkdir -p "$LOG_ROOT"

echo ""
echo -e "${CYAN}============================================================================${NC}"
echo -e "${CYAN}  Harness-Recon  |  Suite Start (WSL)                                      ${NC}"
echo -e "${CYAN}============================================================================${NC}"
echo ""

# ── Step 1: Stop existing services ───────────────────────────────────────────
echo -e "${YELLOW}[1/3] Stopping existing services...${NC}"

if [[ -f "$PID_FILE" ]]; then
    while IFS= read -r pid; do
        [[ -z "$pid" || "$pid" == "null" ]] && continue
        kill "$pid" 2>/dev/null && echo -e "${GRAY}  Stopped PID $pid${NC}" || true
    done < <(python3 -c "import sys,json; d=json.load(open('$PID_FILE')); [print(v) for v in d.values() if v]" 2>/dev/null || true)
    rm -f "$PID_FILE"
fi

# Kill any stray dotnet processes running Reconciliation or Payment
pkill -f "Tideline.Reconciliation" 2>/dev/null || true
pkill -f "Tideline.Payment"        2>/dev/null || true

sleep 2
echo -e "${GREEN}  Done.${NC}"
echo ""

# ── Step 2: Build ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}[2/3] Building projects (Debug)...${NC}"

build_failed=0
for proj in \
    "$RECON_ROOT/Tideline.Reconciliation.Api/Tideline.Reconciliation.Api.csproj" \
    "$RECON_ROOT/Tideline.Reconciliation.EventHubHandler/Tideline.Reconciliation.EventHubHandler.csproj" \
    "$PAYMENT_ROOT/Tideline.Payment.Api/Tideline.Payment.Api.csproj"; do
    [[ -f "$proj" ]] || { echo -e "${GRAY}  SKIPPED (not found): $proj${NC}"; continue; }
    name=$(basename "$proj")
    echo -e "${GRAY}  Building $name...${NC}"
    if dotnet build "$proj" --configuration Debug --no-restore > /dev/null 2>&1; then
        echo -e "${GREEN}  [OK] $name${NC}"
    else
        echo -e "${YELLOW}  [!] Build FAILED: $name${NC}"
        build_failed=1
    fi
done

(( build_failed )) && echo -e "${YELLOW}  Warning: one or more builds failed. Services may run stale binaries.${NC}"
echo ""

# ── Step 3: Start services ────────────────────────────────────────────────────
echo -e "${YELLOW}[3/3] Starting services...${NC}"
echo ""

declare -A PIDS

start_service() {
    local label="$1" cmd="$2" workdir="$3" log_base="$4"
    [[ -d "$workdir" ]] || { echo -e "${YELLOW}  [$label] SKIPPED — dir not found: $workdir${NC}"; return; }
    local out_log="$log_base.log" err_log="$log_base.err.log"
    cd "$workdir"
    eval "$cmd" > "$out_log" 2> "$err_log" &
    local pid=$!
    cd - > /dev/null
    echo -e "${GREEN}  [$label] PID $pid${NC}"
    echo -e "${GRAY}         Log: $out_log${NC}"
    PIDS["$label"]=$pid
}

# Reconciliation API
start_service \
    "Reconciliation API (:5200)" \
    "dotnet run --project \"$RECON_ROOT/Tideline.Reconciliation.Api/Tideline.Reconciliation.Api.csproj\"" \
    "$RECON_ROOT" \
    "$LOG_ROOT/recon-api"
sleep 5

# Reconciliation EventHub Handler (run from compiled binary if present, else dotnet run)
handler_bin="$RECON_ROOT/Tideline.Reconciliation.EventHubHandler/bin/Debug/net10.0/Tideline.Reconciliation.EventHubHandler"
if [[ -f "$handler_bin" ]]; then
    start_service \
        "Reconciliation Handler" \
        "\"$handler_bin\"" \
        "$(dirname "$handler_bin")" \
        "$LOG_ROOT/recon-handler"
else
    start_service \
        "Reconciliation Handler" \
        "dotnet run --project \"$RECON_ROOT/Tideline.Reconciliation.EventHubHandler/Tideline.Reconciliation.EventHubHandler.csproj\"" \
        "$RECON_ROOT" \
        "$LOG_ROOT/recon-handler"
fi
sleep 3

# Payment API
start_service \
    "Payment API (:5201)" \
    "dotnet run --project \"$PAYMENT_ROOT/Tideline.Payment.Api/Tideline.Payment.Api.csproj\"" \
    "$PAYMENT_ROOT" \
    "$LOG_ROOT/payment-api"
sleep 5

# React UI (webpack dev server)
if [[ -f "$RECON_ROOT/package.json" ]]; then
    start_service \
        "React UI (:4202)" \
        "npm start" \
        "$RECON_ROOT" \
        "$LOG_ROOT/react-ui"
fi

# Write PID file
python3 -c "
import json
pids = {$(for k in "${!PIDS[@]}"; do echo "'$k': ${PIDS[$k]},"; done)}
with open('$PID_FILE', 'w') as f:
    json.dump(pids, f, indent=2)
print('  PIDs saved to: $PID_FILE')
"

# ── Health check: Reconciliation API ─────────────────────────────────────────
echo ""
echo -e "${YELLOW}  Waiting for Reconciliation API to become ready...${NC}"

max_wait=60
elapsed=0
ready=0
while (( elapsed < max_wait )); do
    sleep 3; (( elapsed += 3 ))
    code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 2 http://localhost:5200/health 2>/dev/null || echo "000")
    if [[ "$code" =~ ^[23] ]]; then ready=1; break; fi
    echo -e "${GRAY}  Waiting... (${elapsed}s)${NC}"
done

echo ""
echo -e "${CYAN}============================================================================${NC}"
if (( ready )); then
    echo -e "${GREEN}  Suite is READY${NC}"
    echo -e "${GREEN}  Reconciliation API: http://localhost:5200${NC}"
    echo -e "${GREEN}  Payment API:        http://localhost:5201${NC}"
    echo -e "${GREEN}  React UI:           http://localhost:4202  (webpack may take ~30s)${NC}"
else
    echo -e "${YELLOW}  API did not respond within ${max_wait}s — check logs in: $LOG_ROOT${NC}"
fi
echo ""
echo -e "${GRAY}  To stop:  bash /mnt/d/Harness-Recon/stop-suite.sh${NC}"
echo -e "${CYAN}============================================================================${NC}"
echo ""
