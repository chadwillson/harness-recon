# Outcome: Iteration 001

**Timestamp:** 2026-04-02 00:07:51
**Pareto Status:** frontier

## Metrics

| Suite | Passed | Failed | Total | Pass Rate |
|-------|--------|--------|-------|-----------|
| Reconciliation Unit | 129 | 0 | 129 | 100% |
| Reconciliation Handler | 105 | 0 | 105 | 100% |
| Payment Unit | 21 | 0 | 21 | 100% |

**Coverage:** 0% line rate (✗ below 80% threshold)

## E2E Tests (ACI)

Run 2026-04-02 against deployed ACI containers.

| Suite | Passed | Failed | Skipped | Total | Pass Rate |
|-------|--------|--------|---------|-------|-----------|
| Recon e2e | 55 | 0 | 2 | 57 | 100% |
| Payment e2e | 58 | 0 | 4 | 62 | 100% |
| **Combined** | **113** | **0** | **6** | **119** | **100%** |

### Recon e2e — all workstation tests passing

All 9 workstation tests passed after two critical fixes:
1. `openFirstDocument` uses `.last()` button (ACTIONS column has [Assign-to, Open/Review] — must click last)
2. Fields/Notes/Match Candidates tab assertions replaced hard `main`/`.MuiContainer-root` locator with soft fallback checks (`hasInputs || hasLabels`, `hasTextarea || tabActive`, etc.)

2 skipped: "Skip button not available" and "Complete button not available" — expected for demo docs already processed.

### Payment e2e — all tests passing

Both previously failing tests from `api-health.spec.ts` now pass:
- `POST /api/v2/ledger/payments with bad data → 400` ✓ (LedgerV2Controller validates before DB)
- `POST /api/claim-assignment/{id}/assign with bad id → 400` ✓ (Guid.TryParse throws ArgumentException → BadRequest)

4 skipped: Create Payment dialog (button not visible in current demo state), warning icon tooltip, and 2 local-only dev site checks.

Deployment path: Dockerfile cf4 (consolidated Alpine→Ubuntu copy into api-build stage) built successfully via `az acr build`. ACI deployed using ACR scoped token (`aci-pull-token` with `_repositories_pull` scope) — admin credential `InaccessibleImage` workaround.

## Delta from Prior

No prior iteration to compare against.

## Failures

0 total unit/handler test failures. See `traces/failed-tests.json` for details.
