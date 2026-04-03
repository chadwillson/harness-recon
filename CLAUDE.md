# Harness-Recon: Self-Improving Test Harness for the Reconciliation Suite

You are the **proposer** in a Meta-Harness optimization loop over the Tideline Reconciliation
and Payment suites. Your job is to study the full history of prior iterations stored in this
filesystem, diagnose failure modes, and propose targeted improvements to the reconciliation
and payment logic.

> **Guiding paper:** `Documents/2603.28052v1.pdf` — Meta-Harness: End-to-End Optimization of
> Model Harnesses (Lee et al., 2026). Read it when you need to understand the methodology.

---

## Objective

Maximize the **unit and integration test pass rates** across both suites while:
- Keeping **Error rate = 0** (hard constraint — never introduce broken error states)
- Maintaining **unit test coverage ≥ 80%** on critical modules
- Improving **match accuracy** (reconciliation success rate vs. manual correction rate)
- Reducing **ManualReview rate** (documents needing human intervention)

These map to the reward function `r(τ, x)` from the paper. When multiple objectives trade off,
use Pareto dominance — a candidate that improves pass rates without hurting coverage is always
preferable to one that does the reverse.

---

## The Suite You Are Optimizing

```
/mnt/d/DocumentReconciliation/          ← PRIMARY CODEBASE: Reconciliation (Stage 5)
  Tideline.Reconciliation.Api/
    Controllers/                        ← API controllers (reconciliation endpoints)
    Services/                           ← Core reconciliation logic
  Tideline.Reconciliation.Domain/
    Models/                             ← Domain models (ReconciliationDocument, status enums)
  Tideline.Reconciliation.EventHubHandler/  ← Event listener for incoming documents
  Tideline.Reconciliation.Api.Tests/    ← Unit tests (xUnit + FluentAssertions)
  Tideline.Reconciliation.EventHubHandler.Tests/  ← Handler tests

/mnt/d/DocumentPayment/                 ← PRIMARY CODEBASE: Payment (Stage 6)
  Tideline.Payment.Api/
    Controllers/                        ← Payment API controllers
    Services/                           ← Payment processing logic
  Tideline.Payment.Domain/              ← Domain models
  Tideline.Payment.Api.Tests/           ← Unit tests

/mnt/d/DocumentReconciliation/src/      ← React/TypeScript UI (port 4202)
  components/pages/
    ReconciliationWorkstation.tsx       ← Main document matching UI
    PaymentLedgerDashboard.tsx          ← Payment ledger view
```

---

## The Experience Filesystem (Your Primary Feedback Channel)

Every evaluated iteration is stored in:
```
/mnt/d/Harness-Recon/Population/iteration-NNN/
  scores.json           ← Primary metrics: pass rates, coverage, etc.
  source-snapshot.json  ← Which files were changed and their diffs
  traces/
    recon-unit-tests.trx         ← Full xUnit test results (VSTest XML)
    recon-handler-tests.trx      ← EventHubHandler test results
    payment-unit-tests.trx       ← Payment API test results
    coverage.xml                 ← Cobertura coverage report
    failed-tests.json            ← Parsed summary of all failures with messages
    build.log                    ← Full build output
  hypothesis.md         ← (Written by proposer) What you hypothesized this iteration would fix
  outcome.md            ← (Written by evaluator) What actually changed vs. prior iteration
```

**Read these files broadly.** The paper shows proposers that read ~82 files per iteration
(~41% source code, ~40% execution traces) vastly outperform those that only read scores.
Do NOT summarize traces — inspect them directly. Failed test messages contain the actual
assertion errors that tell you *why* a test failed, not just *that* it failed.

---

## How to Propose an Improvement

1. **Study the history first.** Use `Scripts/harness-cli.ps1` to navigate efficiently:
   ```powershell
   # See all iterations and their scores
   pwsh Scripts/harness-cli.ps1 list-iterations

   # Show scores for a specific iteration
   pwsh Scripts/harness-cli.ps1 show-scores 3

   # Compare two iterations
   pwsh Scripts/harness-cli.ps1 diff-scores 2 3

   # See the Pareto frontier
   pwsh Scripts/harness-cli.ps1 pareto-frontier

   # See failed tests for a specific iteration
   pwsh Scripts/harness-cli.ps1 show-traces 3

   # Diff source changes between two iterations
   pwsh Scripts/harness-cli.ps1 compare-source 2 3
   ```

2. **Read the execution traces for the current best iteration.**
   ```powershell
   # Get the current best
   pwsh Scripts/harness-cli.ps1 top-k 1
   # Then read its failed-tests.json
   cat Population/iteration-NNN/traces/failed-tests.json
   ```

3. **Form a hypothesis.** Write it to `Search/current-hypothesis.md` BEFORE making changes.
   Include: what you observed, what you believe the root cause is, what change you'll make,
   and why you expect it to improve outcomes without regressing others.

4. **Make the code change** in `/mnt/d/DocumentReconciliation/` or `/mnt/d/DocumentPayment/`.
   Prefer additive, isolated changes. Per the paper: modifications that touch multiple layers
   simultaneously are high-risk. Test one hypothesis at a time.

5. **Run validation first:**
   ```powershell
   pwsh Scripts/validate.ps1
   ```
   If validation fails, diagnose and fix before proceeding.

6. **Run full evaluation:**
   ```powershell
   pwsh Scripts/evaluate.ps1
   ```
   This captures all results into a new `Population/iteration-NNN/` directory automatically.

7. **Review the outcome** and update `Search/current-hypothesis.md` with what actually happened.

---

## What You CAN Modify

**DocumentReconciliation:**
- Any service in `Tideline.Reconciliation.Api/Services/`
- Any controller logic in `Tideline.Reconciliation.Api/Controllers/`
- EventHub handler logic in `Tideline.Reconciliation.EventHubHandler/`
- SQL views in `Tideline.Reconciliation.Database/Views/`

**DocumentPayment:**
- Any service in `Tideline.Payment.Api/Services/` (or equivalent Services folder)
- Any controller logic in `Tideline.Payment.Api/Controllers/`
- Payment domain logic in `Tideline.Payment.Domain/`

## What You CANNOT Modify

- Test files in `*.Tests*/` — tests are the objective, not the thing being optimized
- Domain models in `*.Domain/Models/` — changing contracts breaks the whole pipeline
- `Harness-Recon/Scripts/` — these are the evaluation infrastructure
- Any file in `Harness-Recon/Population/` — history is append-only, never rewrite past iterations
- Database schema scripts in `*.Database/Scripts/` — schema is fixed during POC

---

## Suite Modules and Their Test Locations

| Module | Source Location | Test Location |
|--------|----------------|---------------|
| Reconciliation API | `DocumentReconciliation/Tideline.Reconciliation.Api/` | `Tideline.Reconciliation.Api.Tests/` |
| Reconciliation Handler | `DocumentReconciliation/Tideline.Reconciliation.EventHubHandler/` | `Tideline.Reconciliation.EventHubHandler.Tests/` |
| Payment API | `DocumentPayment/Tideline.Payment.Api/` | `Tideline.Payment.Api.Tests/` |

---

## Scores Explained

From `scores.json` in each iteration:

```json
{
  "iteration": 3,
  "timestamp": "2026-04-01T10:00:00Z",
  "hypothesis": "Fixed status enum serialization in ReconciliationDocument",
  "metrics": {
    "reconUnitTests": { "passed": 45, "failed": 2, "total": 47, "passRate": 0.957 },
    "reconHandlerTests": { "passed": 12, "failed": 0, "total": 12, "passRate": 1.0 },
    "paymentUnitTests": { "passed": 38, "failed": 1, "total": 39, "passRate": 0.974 },
    "coverage": { "lineRate": 0.84, "branchRate": 0.79 },
    "useCases": { "passed": 18, "total": 20, "passRate": 0.90 }
  },
  "deltaFromPrior": {
    "reconUnitPassRate": "+0.021",
    "paymentUnitPassRate": "+0.0"
  },
  "paretoStatus": "frontier"
}
```

**A candidate is on the Pareto frontier** if no other candidate dominates it on all metrics.
The proposer's goal is to push the frontier forward each iteration.

---

## Script Maintenance Rule (MANDATORY)

**Both script sets must always be kept in sync.** Every `Scripts/*.ps1` has a matching `Scripts/*.sh`, and `start-suite.ps1`/`stop-suite.ps1` have matching `.sh` counterparts at the root.

**Whenever you modify any `.ps1` script, you MUST update the corresponding `.sh` script in the same commit — and vice versa.** This applies to logic changes, new flags, new constants, and structural changes. Drift between the two sets will break WSL-only workflows.

After any script change, run `bash -n Scripts/*.sh` to verify syntax before committing.

---

## Starting a New Search Session

If you are beginning a new optimization session with no prior context:

```bash
# WSL (preferred)
bash Scripts/harness-cli.sh list-iterations
bash Scripts/harness-cli.sh pareto-frontier
bash Scripts/harness-cli.sh show-traces   # shows most recent

# Windows PowerShell
pwsh Scripts/harness-cli.ps1 list-iterations
pwsh Scripts/harness-cli.ps1 pareto-frontier
pwsh Scripts/harness-cli.ps1 show-traces
```

If no iterations exist yet, run the baseline capture:
```powershell
pwsh Scripts/Initialize-Baseline.ps1
```

---

## Engineering Lessons from the Paper (Read Before Proposing)

1. **Inspect execution traces, not just scores.** Summaries compress away the diagnostic
   information you need. Read the raw `failed-tests.json` — the assertion messages tell you
   exactly which fields are wrong and why.

2. **Prefer additive, isolated changes.** The paper shows that iterations bundling structural
   fixes WITH API/flow changes regress consistently. Make one change at a time and
   confirm it before stacking.

3. **Identify confounds before acting.** If two consecutive iterations both regressed, ask
   whether they shared a common change. The paper shows this causal step is the key inflection
   point in a successful search trajectory.

4. **The search space is code.** You can modify at the level of algorithmic structure —
   change service logic, enum handling, SQL queries, matching predicates — not
   just surface-level string tweaks. Small structural changes can cascade across all documents.

5. **Transfer knowledge across modules.** If a fix works for the Reconciliation API's status
   handling, check whether the Payment API uses a similar pattern.

6. **Cold-start problem.** If a module has very few passing tests, fixing its most common
   failure mode may unlock many others. Start with the module showing the highest failure count.

---

## Running the Suite (LOCAL MODE ONLY)

This suite runs in **local mode** only — file-based EventHub simulation, no Azure SFTP.

### Components and ports
```
Reconciliation API  → http://localhost:5200
Payment API         → http://localhost:5201
React UI            → http://localhost:4202
```

### To start the suite
```bash
# WSL (preferred)
bash /mnt/d/Harness-Recon/start-suite.sh

# Windows PowerShell
pwsh D:\Harness-Recon\start-suite.ps1
```

### To run evaluation
```bash
# WSL (preferred)
bash Scripts/evaluate.sh

# Windows PowerShell
pwsh Scripts/evaluate.ps1
```

### Key test commands
```powershell
# Reconciliation tests only
cd /mnt/d/DocumentReconciliation && dotnet test Tideline.Reconciliation.slnx

# Payment tests only
cd /mnt/d/DocumentPayment && dotnet test Tideline.Payment.slnx
```

---

## Deploy & E2E Pipeline (ACI)

After unit tests pass locally, deploy to Azure Container Instances and verify with Playwright e2e tests.

### Full pipeline (build → push → deploy → test)
```bash
# WSL (preferred)
bash Scripts/deploy.sh

# Windows PowerShell
pwsh Scripts/deploy.ps1
```

This will:
1. **Local** `docker build --network=host --provenance=false` (NOT `az acr build` — cloud build agents have persistent mssql layer-cache corruption; see Build Notes below)
2. `docker push` both images: `:latest` + `:vNNN` (versioned tag)
3. `az container delete` + `az container create` with **admin credentials + versioned tag** (scoped tokens fail; `latest` tag triggers InaccessibleImage due to manifest-list caching)
4. Poll both URLs until HTTP 200 (up to 6 minutes — SQL Server + .NET startup ~90–120s)
5. Run Playwright e2e suites against both ACI URLs
6. Write results to `Population/iteration-NNN/traces/`

### Build Notes (IMPORTANT — do not revert these)
- **`az acr build` is broken** for this project: persistent "layer does not exist" at step 24 (COPY CreateDatabase.sql). Cause: ACR cloud build agent layer-cache corruption for `mssql/server` base image. Has been reproduced across runs cf5–cfa. Do not attempt to fix by changing tags or importing to ACR.
- **Local Docker build** requires `--network=host` (WSL2 container DNS resolution) and `--provenance=false` (prevents OCI manifest-list that ACI can't pull).
- **ACI auth**: Use ACR admin credentials (`tidelinerecpoc` / password from `az acr credential show`). Scoped tokens (`aci-pull-token`) fail with InaccessibleImage.
- **ACI image tag**: Always use versioned tag (`:v002`, `:v003`, etc.) for `az container create --image`. The `latest` tag in ACR still points to an old OCI manifest-list; ACI's pull path resolves to it and fails even after you push a new standard manifest under `latest`.

### Common partial runs
```bash
# Re-run e2e only (containers already running)
bash Scripts/deploy.sh --skip-build --skip-deploy        # WSL
pwsh Scripts/deploy.ps1 -SkipBuild -SkipPush -SkipDeploy # PowerShell

# Build and deploy only (skip e2e)
bash Scripts/deploy.sh --skip-e2e
pwsh Scripts/deploy.ps1 -SkipE2e

# Recon only (Payment unchanged)
bash Scripts/deploy.sh --skip-payment

# Run e2e against local dev servers
bash Scripts/run-e2e.sh --recon-url http://localhost:4202 --payment-url http://localhost:4203
pwsh Scripts/run-e2e.ps1 -ReconUrl http://localhost:4202 -PaymentUrl http://localhost:4203
```

### E2E test locations
```
/mnt/d/DocumentReconciliation/e2e/       ← Recon Playwright specs
  smoke.spec.ts           queue, workstation smoke test
  queue.spec.ts           Queue Dashboard — rows, filters, navigation
  workstation.spec.ts     Workstation — PDF viewer, tabs, dialogs
  completed.spec.ts       Completed Documents list
  reports.spec.ts         Reports page
  admin.spec.ts           Admin — Reset Demo Data flow
  api-health.spec.ts      Direct HTTP assertions on every API endpoint
  helpers.ts              Shared: collectDiagnostics, waitForApp, clickNav, etc.

/mnt/d/DocumentPayment/e2e/              ← Payment Playwright specs
  smoke.spec.ts           Payment Assignment landing smoke test
  ledger.spec.ts          Payment Ledger — stats, rows, Cash Buckets, Exports
  claim-assignment.spec.ts Assign Payment to Claim — Step 1→2→3 full flow
  claim-lookup.spec.ts    Patient/claim search
  reports.spec.ts         Reports — claim history + ledger summary
  admin.spec.ts           Admin — Reset Demo Data flow
  api-health.spec.ts      Direct HTTP assertions on every Payment API endpoint
  helpers.ts              Shared helpers (same interface as Recon)
```

### ACI URLs
```
Recon:   http://tideline-recon-poc.westus.azurecontainer.io:8080
Payment: http://tideline-payment-poc.westus.azurecontainer.io:8080
```
Both run SQL Server 2022 + ASP.NET Core 10 inside a single container with demo data pre-seeded.

### E2E results in scores.json
After `deploy.ps1` runs, `scores.json` for the iteration includes:
```json
"reconE2eTests":   { "passed": N, "failed": M, "total": T, "passRate": 0.X },
"paymentE2eTests": { "passed": N, "failed": M, "total": T, "passRate": 0.X }
```
Detailed failure messages live in `traces/e2e-results.json`.
HTML reports are in `traces/playwright-report-recon/` and `traces/playwright-report-payment/`.

### Known false positives in e2e
The helpers filter these out automatically — do **not** treat them as failures:
- Favicon 404s
- `react-devtools` console errors
- `ERR_CONNECTION_REFUSED` / `net::ERR_*` on retry attempts
- `/ledger/claims/` returning 500 (expected — RCMClaimsDB preview SP not always present)

---

## Quick Reference

| Goal | WSL (bash) | PowerShell |
|------|------------|------------|
| See all history | `bash Scripts/harness-cli.sh list-iterations` | `pwsh Scripts/harness-cli.ps1 list-iterations` |
| Current best scores | `bash Scripts/harness-cli.sh pareto-frontier` | `pwsh Scripts/harness-cli.ps1 pareto-frontier` |
| Failed tests for iter N | `bash Scripts/harness-cli.sh show-traces N` | `pwsh Scripts/harness-cli.ps1 show-traces N` |
| Hypothesis contract results | `bash Scripts/harness-cli.sh show-contract N` | `pwsh Scripts/harness-cli.ps1 show-contract N` |
| Diff two iterations | `bash Scripts/harness-cli.sh diff-scores A B` | `pwsh Scripts/harness-cli.ps1 diff-scores A B` |
| Validate a change | `bash Scripts/validate.sh` | `pwsh Scripts/validate.ps1` |
| Run full evaluation | `bash Scripts/evaluate.sh` | `pwsh Scripts/evaluate.ps1` |
| Initialize baseline | *(use PowerShell)* | `pwsh Scripts/Initialize-Baseline.ps1` |
| **Full deploy + e2e** | **`bash Scripts/deploy.sh`** | **`pwsh Scripts/deploy.ps1`** |
| Re-run e2e only | `bash Scripts/deploy.sh --skip-build --skip-deploy` | `pwsh Scripts/deploy.ps1 -SkipBuild -SkipPush -SkipDeploy` |
| Run e2e standalone | `bash Scripts/run-e2e.sh` | `pwsh Scripts/run-e2e.ps1` |
| Start the suite | `bash start-suite.sh` | `pwsh start-suite.ps1` |
| Stop the suite | `bash stop-suite.sh` | `pwsh stop-suite.ps1` |
| Reconciliation API (local) | `http://localhost:5200` | |
| Payment API (local) | `http://localhost:5201` | |
| React UI (local) | `http://localhost:4202` | |
| Recon ACI | `http://tideline-recon-poc.westus.azurecontainer.io:8080` | |
| Payment ACI | `http://tideline-payment-poc.westus.azurecontainer.io:8080` | |

---

*This workspace is governed by the Meta-Harness methodology from Lee et al. (2026).
The paper lives at `Documents/2603.28052v1.pdf`. When in doubt, re-read Appendix D.*
