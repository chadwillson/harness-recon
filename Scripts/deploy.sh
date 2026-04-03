#!/usr/bin/env bash
# deploy.sh — Full build → push → deploy → verify pipeline (WSL-native bash port of deploy.ps1)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"
RECON_ROOT="/mnt/d/DocumentReconciliation"
PAYMENT_ROOT="/mnt/d/DocumentPayment"
POPULATION_ROOT="$HARNESS_ROOT/Population"

ACR_REGISTRY="tidelinerecpoc.azurecr.io"
ACR_NAME="tidelinerecpoc"
RESOURCE_GROUP="tideline-recon-rg"
LOCATION="westus"
# Tags: versioned tag used for ACI (avoids 'latest' InaccessibleImage caching bug);
#       'latest' also pushed as a convenience alias.
RECON_IMAGE="$ACR_REGISTRY/tideline-recon-app:latest"
PAYMENT_IMAGE="$ACR_REGISTRY/tideline-payment:latest"
# Versioned tags are set after ITERATION_LABEL is determined (below)
RECON_ACI="tideline-recon-poc"
PAYMENT_ACI="tideline-payment-poc"
RECON_URL="http://tideline-recon-poc.westus.azurecontainer.io:8080"
PAYMENT_URL="http://tideline-payment-poc.westus.azurecontainer.io:8080"
SA_PASSWORD="Tideline@Pass123"

# ── Flags ─────────────────────────────────────────────────────────────────────
SKIP_BUILD=0
SKIP_PUSH=0
SKIP_DEPLOY=0
SKIP_E2E=0
SKIP_RECON=0
SKIP_PAYMENT=0
POLL_TIMEOUT=360
ITERATION_LABEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)    SKIP_BUILD=1 ;;
        --skip-push)     SKIP_PUSH=1 ;;
        --skip-deploy)   SKIP_DEPLOY=1 ;;
        --skip-e2e)      SKIP_E2E=1 ;;
        --skip-recon)    SKIP_RECON=1 ;;
        --skip-payment)  SKIP_PAYMENT=1 ;;
        --iteration)     ITERATION_LABEL="$2"; shift ;;
        --poll-timeout)  POLL_TIMEOUT="$2"; shift ;;
        -h|--help)
            echo "Usage: deploy.sh [--skip-build] [--skip-push] [--skip-deploy] [--skip-e2e]"
            echo "                  [--skip-recon] [--skip-payment] [--iteration NNN] [--poll-timeout N]"
            exit 0 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
    shift
done

# ── Colors ────────────────────────────────────────────────────────────────────
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; GRAY='\033[0;90m'; NC='\033[0m'
log() { echo -e "${GRAY}$*${NC}"; DEPLOY_LOG+=("$*"); }
ok()  { echo -e "${GREEN}$*${NC}"; DEPLOY_LOG+=("$*"); }
warn(){ echo -e "${YELLOW}$*${NC}"; DEPLOY_LOG+=("$*"); }
err() { echo -e "${RED}$*${NC}"; DEPLOY_LOG+=("$*"); }
DEPLOY_LOG=()

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
    latest=$(ls -d "$POPULATION_ROOT"/iteration-*/ 2>/dev/null | sort | tail -1)
    if [[ -n "$latest" ]]; then
        ITERATION_LABEL=$(basename "$latest" | sed 's/iteration-//')
    else
        ITERATION_LABEL=$(printf "%03d" "$(get_next_iteration)")
    fi
fi

ITER_DIR="$POPULATION_ROOT/iteration-$ITERATION_LABEL"
TRACES_DIR="$ITER_DIR/traces"
mkdir -p "$TRACES_DIR"

# Versioned image refs — used for ACI to avoid 'latest' tag InaccessibleImage bug
RECON_IMAGE_VERSIONED="$ACR_REGISTRY/tideline-recon-app:v${ITERATION_LABEL}"
PAYMENT_IMAGE_VERSIONED="$ACR_REGISTRY/tideline-payment:v${ITERATION_LABEL}"

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Harness-Recon Deploy Pipeline  |  Iteration $ITERATION_LABEL${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""

# ── Build locally + push ──────────────────────────────────────────────────────
# az acr build's cloud agents have a persistent layer-cache corruption bug with
# the mssql/server base image; local Docker build + push is more reliable.
build_image() {
    local context_path="$1" image_ref="$2" name="$3"
    local build_log="$TRACES_DIR/acr-build-${name,,}.log"

    if [[ ! -d "$context_path" ]]; then
        warn "  [!] Context path not found: $context_path"
        return 1
    fi
    log "  [→] Building $name image locally..."
    if sg docker -c "docker build --network=host -t '$image_ref' '$context_path'" > "$build_log" 2>&1; then
        ok "  [✓] $name image built"
    else
        err "  [✗] Docker build FAILED for $name — see $build_log"
        tail -20 "$build_log" | while IFS= read -r line; do err "      $line"; done
        return 1
    fi
}

push_image() {
    local image_ref="$1" versioned_ref="$2" name="$3"
    local push_log="$TRACES_DIR/push-${name,,}.log"

    log "  [→] Logging into ACR and pushing $name..."
    local acr_pwd; acr_pwd=$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" -o tsv 2>/dev/null)
    # Tag both :latest and :vNNN; ACI uses versioned tag to avoid 'latest' InaccessibleImage caching bug
    sg docker -c "docker tag '$image_ref' '$versioned_ref'" >> "$push_log" 2>&1
    if sg docker -c "docker login '$ACR_REGISTRY' -u '$ACR_NAME' -p '$acr_pwd'" >> "$push_log" 2>&1 && \
       sg docker -c "docker push '$image_ref'" >> "$push_log" 2>&1 && \
       sg docker -c "docker push '$versioned_ref'" >> "$push_log" 2>&1; then
        ok "  [✓] $name image pushed to ACR ($image_ref + $versioned_ref)"
    else
        err "  [✗] Push FAILED for $name — see $push_log"
        tail -10 "$push_log" | while IFS= read -r line; do err "      $line"; done
        return 1
    fi
}

if (( !SKIP_BUILD )); then
    (( !SKIP_RECON   )) && build_image "$RECON_ROOT"   "$RECON_IMAGE"   "Recon"
    (( !SKIP_PAYMENT )) && build_image "$PAYMENT_ROOT" "$PAYMENT_IMAGE" "Payment"
else
    log "  [─] Build skipped (--skip-build)"
fi

if (( !SKIP_PUSH )); then
    (( !SKIP_RECON   )) && push_image "$RECON_IMAGE"   "$RECON_IMAGE_VERSIONED"   "Recon"
    (( !SKIP_PAYMENT )) && push_image "$PAYMENT_IMAGE" "$PAYMENT_IMAGE_VERSIONED" "Payment"
else
    log "  [─] Push skipped (--skip-push)"
fi

# ── Deploy ACI containers ─────────────────────────────────────────────────────
redeploy_aci() {
    local container="$1" image="$2" dns="$3"
    local aci_log="$TRACES_DIR/aci-create-$container.log"

    log "  [→] Deleting ACI container: $container..."
    az container delete --resource-group "$RESOURCE_GROUP" --name "$container" --yes 2>&1 || true
    ok "  [✓] ACI container deleted (or did not exist): $container"

    # Use admin credentials + versioned tag (scoped token fails; 'latest' tag causes
    # InaccessibleImage due to ACR's manifest-list caching for that tag)
    local acr_pwd; acr_pwd=$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" -o tsv 2>/dev/null)
    [[ -z "$acr_pwd" ]] && { err "  [✗] Could not obtain ACR admin password"; return 1; }

    log "  [→] Creating ACI container: $container..."
    if az container create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$container" \
        --image "$image" \
        --registry-login-server "$ACR_REGISTRY" \
        --registry-username "$ACR_NAME" \
        --registry-password "$acr_pwd" \
        --dns-name-label "$dns" \
        --ports 8080 \
        --os-type Linux \
        --cpu 2 \
        --memory 4 \
        --environment-variables "MSSQL_SA_PASSWORD=$SA_PASSWORD" "SA_PASSWORD=$SA_PASSWORD" \
        --location "$LOCATION" > "$aci_log" 2>&1; then
        ok "  [✓] ACI container created: $container"
    else
        err "  [✗] ACI create FAILED for $container — see $aci_log"
        tail -15 "$aci_log" | while IFS= read -r line; do err "      $line"; done
        return 1
    fi
}

if (( !SKIP_DEPLOY )); then
    (( !SKIP_RECON   )) && redeploy_aci "$RECON_ACI"   "$RECON_IMAGE_VERSIONED"   "$RECON_ACI"
    (( !SKIP_PAYMENT )) && redeploy_aci "$PAYMENT_ACI" "$PAYMENT_IMAGE_VERSIONED" "$PAYMENT_ACI"
else
    log "  [─] ACI deploy skipped (--skip-deploy)"
fi

# ── Poll until healthy ────────────────────────────────────────────────────────
wait_container_ready() {
    local url="$1" name="$2" timeout="$3"
    log "  [→] Waiting for $name to become healthy ($url)..."
    local deadline=$(( $(date +%s) + timeout ))
    local attempt=0 interval=15

    while (( $(date +%s) < deadline )); do
        (( attempt++ ))
        local code; code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
        if [[ "$code" =~ ^[23] ]]; then
            ok "  [✓] $name is healthy (attempt $attempt, HTTP $code)"
            return 0
        fi
        log "  [~] $name not ready (attempt $attempt, HTTP $code) — retrying in ${interval}s..."
        sleep $interval
    done

    err "  [✗] $name did not become healthy within ${timeout}s"
    return 1
}

if (( !SKIP_DEPLOY || !SKIP_E2E )); then
    recon_ready=1 payment_ready=1
    if (( !SKIP_RECON )); then
        wait_container_ready "$RECON_URL/" "Recon" "$POLL_TIMEOUT" || {
            az container logs --resource-group "$RESOURCE_GROUP" --name "$RECON_ACI" \
                > "$TRACES_DIR/aci-logs-recon.log" 2>&1 || true
            recon_ready=0
        }
    fi
    if (( !SKIP_PAYMENT )); then
        wait_container_ready "$PAYMENT_URL/" "Payment" "$POLL_TIMEOUT" || {
            az container logs --resource-group "$RESOURCE_GROUP" --name "$PAYMENT_ACI" \
                > "$TRACES_DIR/aci-logs-payment.log" 2>&1 || true
            payment_ready=0
        }
    fi
    if (( recon_ready == 0 || payment_ready == 0 )); then
        err "One or more containers did not become healthy. Check traces/ for ACI logs."
        exit 1
    fi
fi

# ── Run e2e tests ─────────────────────────────────────────────────────────────
if (( !SKIP_E2E )); then
    echo ""
    log "  [→] Running Playwright e2e suites..."
    echo ""

    e2e_args=(--output-dir "$TRACES_DIR" --recon-url "$RECON_URL" --payment-url "$PAYMENT_URL")
    (( SKIP_RECON   )) && e2e_args+=(--skip-recon)
    (( SKIP_PAYMENT )) && e2e_args+=(--skip-payment)

    bash "$SCRIPT_DIR/run-e2e.sh" "${e2e_args[@]}" || true

    ok "  [✓] E2E suites complete"
else
    log "  [─] E2E skipped (--skip-e2e)"
fi

# ── Write deploy.json ─────────────────────────────────────────────────────────
recon_img_val=$(( SKIP_RECON   )) && echo '"skipped"' || echo "\"$RECON_IMAGE\""
payment_img_val=$(( SKIP_PAYMENT )) && echo '"skipped"' || echo "\"$PAYMENT_IMAGE\""

jq -n \
    --arg iter        "$ITERATION_LABEL" \
    --arg ts          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg reconUrl    "$RECON_URL" \
    --arg paymentUrl  "$PAYMENT_URL" \
    --arg reconImg    "$(( SKIP_RECON   )) && echo skipped || echo "$RECON_IMAGE"" \
    --arg paymentImg  "$(( SKIP_PAYMENT )) && echo skipped || echo "$PAYMENT_IMAGE"" \
    --argjson buildSkipped  "$SKIP_BUILD" \
    --argjson deploySkipped "$SKIP_DEPLOY" \
    --argjson e2eSkipped    "$SKIP_E2E" \
    '{iteration:$iter,timestamp:$ts,reconUrl:$reconUrl,paymentUrl:$paymentUrl,
      reconImage:$reconImg,paymentImage:$paymentImg,
      buildSkipped:($buildSkipped==1),deploySkipped:($deploySkipped==1),e2eSkipped:($e2eSkipped==1)}' \
    > "$ITER_DIR/deploy.json"

# Save deploy log
printf '%s\n' "${DEPLOY_LOG[@]}" > "$TRACES_DIR/deploy.log"

# ── Merge e2e results into scores.json ───────────────────────────────────────
SCORES_PATH="$ITER_DIR/scores.json"
E2E_PATH="$TRACES_DIR/e2e-results.json"
if [[ -f "$SCORES_PATH" && -f "$E2E_PATH" ]]; then
    merged=$(jq -s '
        .[0].metrics.reconE2eTests   = .[1].recon   |
        .[0].metrics.paymentE2eTests = .[1].payment  |
        .[0]
    ' "$SCORES_PATH" "$E2E_PATH")
    echo "$merged" > "$SCORES_PATH"
    ok "  [✓] scores.json updated with e2e results"
fi

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Deploy Pipeline Complete: Iteration $ITERATION_LABEL${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""
(( !SKIP_RECON   )) && echo -e "${GREEN}  Recon:   $RECON_URL${NC}"
(( !SKIP_PAYMENT )) && echo -e "${GREEN}  Payment: $PAYMENT_URL${NC}"

if [[ -f "$E2E_PATH" ]]; then
    recon_p=$(jq -r '.recon.passed' "$E2E_PATH")
    recon_t=$(jq -r '.recon.total'  "$E2E_PATH")
    recon_f=$(jq -r '.recon.failed' "$E2E_PATH")
    pay_p=$(jq -r '.payment.passed' "$E2E_PATH")
    pay_t=$(jq -r '.payment.total'  "$E2E_PATH")
    pay_f=$(jq -r '.payment.failed' "$E2E_PATH")
    echo ""
    [[ "$recon_f"   == "0" ]] && echo -e "${GREEN}  Recon E2E:   $recon_p/$recon_t passed${NC}" || echo -e "${YELLOW}  Recon E2E:   $recon_p/$recon_t passed${NC}"
    [[ "$pay_f"     == "0" ]] && echo -e "${GREEN}  Payment E2E: $pay_p/$pay_t passed${NC}"   || echo -e "${YELLOW}  Payment E2E: $pay_p/$pay_t passed${NC}"
fi

echo ""
echo -e "${CYAN}  Artifacts in: Population/iteration-$ITERATION_LABEL/${NC}"
echo ""
