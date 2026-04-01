# Harness-Recon

**Primary workspace for studying, running, updating, and improving the Tideline Reconciliation suite.**

Implements the Meta-Harness methodology from:
> Lee et al. (2026). *Meta-Harness: End-to-End Optimization of Model Harnesses.*
> arXiv:2603.28052. See `Documents/2603.28052v1.pdf`.

---

## What This Is

This workspace is an **outer-loop optimization harness** over the DocumentReconciliation and
DocumentPayment suites. It treats the reconciliation and payment logic as the "harness" being
optimized and uses Claude Code as the "proposer" that reads the experience filesystem and
proposes improvements.

```
Documents/2603.28052v1.pdf    ← Guiding paper — read this
CLAUDE.md                     ← THE proposer interface (most important file)
Scripts/
  run-harness.ps1             ← Outer loop orchestrator (Algorithm 1 from paper)
  evaluate.ps1                ← Full test runner — logs everything to Population/
  validate.ps1                ← Fast pre-check before expensive evaluation
  harness-cli.ps1             ← CLI for querying the experience store
  Initialize-Baseline.ps1     ← Captures iteration-000 from current codebase
Population/                   ← Growing filesystem of all evaluated iterations
  iteration-000/              ← Baseline
  iteration-001/              ← First proposed improvement
  ...
Search/
  current-hypothesis.md       ← Proposer writes this before each evaluation
Results/
  pareto-frontier.json        ← Best non-dominated iterations
```

---

## Quick Start

```powershell
# First time: capture the baseline
pwsh Scripts/Initialize-Baseline.ps1

# Read the skill that guides you as proposer
cat CLAUDE.md

# See what exists
pwsh Scripts/harness-cli.ps1 list-iterations

# Propose an improvement, then evaluate it
# (edit Search/current-hypothesis.md + make code change in /mnt/d/DocumentReconciliation/ or /mnt/d/DocumentPayment/)
pwsh Scripts/run-harness.ps1
```

---

## The Reconciliation Suite

| Component | Location | Role |
|-----------|----------|------|
| DocumentReconciliation | `/mnt/d/DocumentReconciliation` | Stage 5: Match OCR output to claims, manual correction |
| DocumentPayment | `/mnt/d/DocumentPayment` | Stage 6: Payment processing and audit |

**Pipeline:** ... → OCR → Validation → **Reconciliation (5200)** → **Payment (5201)** → UI (4202)

---

## Metrics Being Optimized

| Metric | Direction | Constraint |
|--------|-----------|------------|
| Unit test pass rate (Reconciliation) | Maximize | — |
| Unit test pass rate (Payment) | Maximize | — |
| Integration test pass rate | Maximize | Never regress |
| Line coverage | Maximize | Hard floor: ≥80% |
| Error rate | Minimize | Hard constraint: must stay 0 |

---

## Key Insight from the Paper

> "Access to raw execution traces is the key ingredient for enabling harness search."
> Scores-only achieves 41.3% best accuracy; full trace access achieves 56.7%.

This workspace stores full execution traces for every evaluated iteration.
The proposer (Claude Code) reads them via `harness-cli.ps1` to form causal
hypotheses about *why* tests fail, not just *that* they fail.
