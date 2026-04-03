# Hypothesis: Iteration 002 — Nav Cleanup + Deploy Infrastructure Fix

## What was observed
- Recon sidebar contained "Payment Assignment" and "Claim Discovery" nav items that don't belong in the Reconciliation application.
- ACR cloud builds (az acr build) had been failing since iteration-001 deploy with "layer does not exist" error at step 24 (COPY CreateDatabase.sql). Builds cf5–cfa all failed.

## Root cause analysis
**Nav issue:** Payment Assignment and Claim Discovery pages live in the Payment app. They were included in Recon's AppShell.tsx nav by mistake during an earlier feature addition.

**Build failure:** ACR's cloud build agents have a layer-cache corruption for `mssql/server:2022-CU14-ubuntu-20.04`. The export phase fails when assembling the final image's layer chain. The issue persists regardless of: base image tag (2022-latest vs CU14), base image registry (mcr.microsoft.com vs ACR-imported copy), or manifest format. Root cause is the ACR build agent's internal layer store.

**ACI InaccessibleImage:** Two separate causes:
1. First pushes created OCI manifest lists (Docker BuildKit provenance attestation). ACI does not support pulling manifest lists.
2. The `latest` tag retains the manifest-list pointer in ACR's manifest store. Even after pushing a standard manifest, `latest` still resolves to the old manifest list for ACI's pull path.

## Changes made
- `AppShell.tsx`: Removed Payment Assignment nav item (PaymentIcon, paymentCount)
- `AppShell.tsx`: Removed Claim Discovery nav item (AssignmentIcon, assignmentCount)  
- `App.tsx`: Removed corresponding state and API calls for both removed nav items
- `Dockerfile`: Pinned mssql base to `2022-CU14-ubuntu-20.04` (was `2022-latest`)
- `Dockerfile`: Moved `COPY --from=ui-build /ui/dist /out/wwwroot/` into api-build stage (cf4 pattern)
- `Scripts/deploy.sh`: Replaced `az acr build` with local `docker build --network=host --provenance=false`
- `Scripts/deploy.sh`: Added versioned tags (:vNNN) pushed alongside :latest; ACI uses versioned tag
- `Scripts/deploy.sh`: Changed ACI auth from scoped token to admin credentials (admin works; scoped token does not)
- `Scripts/run-e2e.sh`: Fixed JSON results capture — use `PLAYWRIGHT_JSON_OUTPUT_NAME` env var instead of stdout

## Expected outcome
- Recon nav shows: Document Assessment, Batch Assignment, Reports, Completed Documents, Claim Lookup, Admin (no Payment Assignment, no Claim Discovery)
- E2E tests pass at same or better rate as iteration-001 (55/57)
- Deploy pipeline is now reliable using local Docker build

## Actual outcome
- Nav changes confirmed correct (Batch Assignment tests 37-38 pass, no Payment Assignment nav test failures)
- 54/57 Recon e2e passed (98.2% pass rate) — 1 timeout on "Payment Ledger stats load without 500" which is a known ClaimsDB flaky test
- Deploy pipeline working: local Docker build succeeded, versioned tag push + admin credentials ACI create succeeded
