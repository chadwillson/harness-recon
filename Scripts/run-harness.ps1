<#
.SYNOPSIS
    Outer loop orchestrator for the Meta-Harness optimization of the Reconciliation suite.
    Implements Algorithm 1 from Lee et al. (2026) — Meta-Harness paper.

.DESCRIPTION
    The loop:
      (1) Validate the current candidate (fast smoke test)
      (2) Evaluate it (run full test suite, log everything to Population/)
      (3) Signal: print instructions for the proposer to inspect the filesystem
          and propose the next candidate
      (4) Repeat for N iterations

    The proposer is Claude Code operating in this workspace. It reads the
    Population/ filesystem between iterations and makes code changes to
    /mnt/d/DocumentReconciliation/ or /mnt/d/DocumentPayment/ based on what it finds.

.PARAMETER Iterations
    Number of optimization iterations to run (default: 10).

.PARAMETER Baseline
    If specified, initializes iteration-000 from the current codebase state
    without waiting for a human-proposed change. Use this on first run.

.PARAMETER SkipValidation
    Skip the validate.ps1 pre-check (useful for the baseline capture).

.PARAMETER StartFrom
    Resume from a specific iteration number.

.EXAMPLE
    # First time: capture baseline then begin optimization
    pwsh Scripts/run-harness.ps1 -Baseline

    # Continue optimization for 5 more iterations
    pwsh Scripts/run-harness.ps1 -Iterations 5

    # Run baseline without validation (first ever run)
    pwsh Scripts/run-harness.ps1 -Baseline -SkipValidation
#>
param(
    [int]$Iterations = 10,
    [switch]$Baseline,
    [switch]$SkipValidation,
    [int]$StartFrom = -1
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HarnessRoot = Split-Path -Parent $ScriptDir
$PopulationRoot = Join-Path $HarnessRoot "Population"
$SearchDir = Join-Path $HarnessRoot "Search"

function Get-NextIterationNum {
    $existing = Get-ChildItem $PopulationRoot -Directory -Filter "iteration-*" -ErrorAction SilentlyContinue
    if (-not $existing) { return 0 }
    $nums = $existing.Name | ForEach-Object { [int]($_ -replace "iteration-", "") }
    return ($nums | Measure-Object -Maximum).Maximum + 1
}

# ── Header ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Harness-Recon: Meta-Harness Optimization Loop        ║" -ForegroundColor Cyan
Write-Host "║  Based on Lee et al. (2026) — Documents/2603.28052v1  ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── Baseline mode ────────────────────────────────────────────────────────────

if ($Baseline) {
    Write-Host "  [BASELINE] Initializing iteration-000 from current codebase..." -ForegroundColor Yellow
    & pwsh "$ScriptDir/Initialize-Baseline.ps1"
    Write-Host ""
    Write-Host "  Baseline captured. Run 'pwsh Scripts/harness-cli.ps1 show-scores 0' to review." -ForegroundColor Green
    Write-Host "  Now open CLAUDE.md, study the baseline traces, and propose your first improvement." -ForegroundColor Cyan
    exit 0
}

# ── Determine starting iteration ─────────────────────────────────────────────

$startIter = if ($StartFrom -ge 0) { $StartFrom } else { Get-NextIterationNum }

Write-Host "  Starting from iteration: $startIter" -ForegroundColor White
Write-Host "  Running for: $Iterations iteration(s)" -ForegroundColor White
Write-Host ""

# ── Main loop ─────────────────────────────────────────────────────────────────

for ($i = $startIter; $i -lt ($startIter + $Iterations); $i++) {
    $iterLabel = "{0:D3}" -f $i

    Write-Host "┌─────────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
    Write-Host "│  Iteration $iterLabel" -ForegroundColor DarkCyan
    Write-Host "└─────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
    Write-Host ""

    # ── Step 1: Wait for proposer to write hypothesis ────────────────────────

    $hypothesisFile = Join-Path $SearchDir "current-hypothesis.md"

    if (-not (Test-Path $hypothesisFile)) {
        Write-Host "  [PROPOSER NEEDED]" -ForegroundColor Magenta
        Write-Host ""
        Write-Host "  Before this iteration can be evaluated, the proposer must:" -ForegroundColor White
        Write-Host ""
        Write-Host "  1. Study the experience filesystem:" -ForegroundColor Yellow
        Write-Host "     pwsh Scripts/harness-cli.ps1 list-iterations" -ForegroundColor Gray
        Write-Host "     pwsh Scripts/harness-cli.ps1 pareto-frontier" -ForegroundColor Gray
        Write-Host "     pwsh Scripts/harness-cli.ps1 show-traces" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  2. Read CLAUDE.md for guidance on what to change and how" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  3. Write a hypothesis to Search/current-hypothesis.md:" -ForegroundColor Yellow
        Write-Host "     (What you observed, root cause, proposed change, expected impact)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  4. Make the code change in /mnt/d/DocumentReconciliation/ or /mnt/d/DocumentPayment/" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  5. Re-run: pwsh Scripts/run-harness.ps1" -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }

    Write-Host "  [✓] Hypothesis found: $(Split-Path -Leaf $hypothesisFile)" -ForegroundColor Green

    # ── Step 2: Validate ─────────────────────────────────────────────────────

    if (-not $SkipValidation) {
        Write-Host ""
        & pwsh "$ScriptDir/validate.ps1"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [✗] Validation failed. Fix the issues and re-run." -ForegroundColor Red
            exit 1
        }
    }

    # ── Step 3: Full evaluation ───────────────────────────────────────────────

    & pwsh "$ScriptDir/evaluate.ps1" -HypothesisFile "Search/current-hypothesis.md" -IterationLabel $iterLabel
    $evalExit = $LASTEXITCODE

    # ── Step 4: Archive hypothesis, clear for next iteration ─────────────────

    $archiveName = "hypothesis-$iterLabel.md"
    $archivePath = Join-Path $SearchDir $archiveName
    if (Test-Path $hypothesisFile) {
        Copy-Item $hypothesisFile $archivePath -Force
        Remove-Item $hypothesisFile -Force
        Write-Host "  [✓] Hypothesis archived to Search/$archiveName" -ForegroundColor Green
    }

    # ── Step 5: Show progress and prompt for next iteration ──────────────────

    Write-Host ""
    & pwsh "$ScriptDir/harness-cli.ps1" "summary"

    if ($i -lt ($startIter + $Iterations - 1)) {
        Write-Host "  ─────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Iteration $iterLabel complete. Ready for next proposal." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Next steps for the proposer:" -ForegroundColor Yellow
        Write-Host "    1. Review outcome: pwsh Scripts/harness-cli.ps1 show-outcome $([int]$iterLabel)" -ForegroundColor Gray
        Write-Host "    2. Study traces:   pwsh Scripts/harness-cli.ps1 show-traces $([int]$iterLabel)" -ForegroundColor Gray
        Write-Host "    3. Write new hypothesis to Search/current-hypothesis.md" -ForegroundColor Gray
        Write-Host "    4. Make code change in /mnt/d/DocumentReconciliation/ or /mnt/d/DocumentPayment/" -ForegroundColor Gray
        Write-Host "    5. Re-run this script" -ForegroundColor Gray
        Write-Host ""
        break
    }
}

Write-Host ""
Write-Host "  Search complete. Final results:" -ForegroundColor Cyan
& pwsh "$ScriptDir/harness-cli.ps1" "pareto-frontier"
