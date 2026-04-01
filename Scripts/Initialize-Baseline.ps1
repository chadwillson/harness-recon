<#
.SYNOPSIS
    Captures the current state of the Reconciliation and Payment suites as iteration-000.
    Seeds the experience filesystem so the proposer has non-Markovian history
    from the first session, per the Meta-Harness paper's guidance on warm-starting.

.DESCRIPTION
    Creates Population/iteration-000/ with:
    - scores.json: combined metrics from dotnet tests
    - source-snapshot.json: all service source files from both suites
    - traces/: TRX files and build output
    - hypothesis.md: "Baseline — current codebase state"
    - outcome.md: summary of all metrics

.PARAMETER UnitOnly
    Run only dotnet tests (skip any pipeline checks).
#>
param(
    [switch]$UnitOnly
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HarnessRoot = Split-Path -Parent $ScriptDir
$IsWSL = ($env:WSL_DISTRO_NAME -ne $null) -or ($IsLinux -and (Test-Path /mnt/d -ErrorAction SilentlyContinue))
$ReconRoot   = if ($IsWSL) { "/mnt/d/DocumentReconciliation" } else { "D:\DocumentReconciliation" }
$PaymentRoot = if ($IsWSL) { "/mnt/d/DocumentPayment" } else { "D:\DocumentPayment" }
$PopulationRoot = Join-Path $HarnessRoot "Population"

$iterDir = Join-Path $PopulationRoot "iteration-000"
$tracesDir = Join-Path $iterDir "traces"

if (Test-Path $iterDir) {
    Write-Host "  iteration-000 already exists. Delete it manually if you want to re-initialize." -ForegroundColor Yellow
    exit 0
}

New-Item -ItemType Directory -Path $iterDir -Force | Out-Null
New-Item -ItemType Directory -Path $tracesDir -Force | Out-Null

Write-Host ""
Write-Host "  [Baseline] Initializing iteration-000..." -ForegroundColor Cyan
Write-Host ""

# ── Hypothesis ────────────────────────────────────────────────────────────────

@"
# Baseline: Current Codebase State

This is the starting point for the Meta-Harness optimization loop.
No changes have been made — this captures the Reconciliation and Payment suites
as they exist when Harness-Recon was first initialized.

## Starting Objectives
- Improve unit test pass rates for both DocumentReconciliation and DocumentPayment
- Reduce manual review rate (documents requiring human intervention)
- Maintain Error rate = 0
- Maintain coverage >= 80% on critical modules

## Suite Overview
- DocumentReconciliation (port 5200): Stage 5 — match OCR output to claims
- DocumentPayment (port 5201): Stage 6 — payment processing and audit
- React UI (port 4202): Combined workstation interface
"@ | Set-Content (Join-Path $iterDir "hypothesis.md")

Write-Host "  [✓] Hypothesis written" -ForegroundColor Green

# ── Source snapshot ───────────────────────────────────────────────────────────

$snapshotEntries = @()

$reconFiles = Get-ChildItem "$ReconRoot/Tideline.Reconciliation.Api" -Recurse -Filter "*.cs" -ErrorAction SilentlyContinue
foreach ($file in $reconFiles) {
    $relativePath = "DocumentReconciliation/" + $file.FullName.Replace($ReconRoot, "").TrimStart("/", "\")
    $snapshotEntries += @{
        path = $relativePath
        lastModified = $file.LastWriteTimeUtc.ToString("o")
        sizeBytes = $file.Length
        name = $file.Name
    }
}

$paymentFiles = Get-ChildItem "$PaymentRoot/Tideline.Payment.Api" -Recurse -Filter "*.cs" -ErrorAction SilentlyContinue
foreach ($file in $paymentFiles) {
    $relativePath = "DocumentPayment/" + $file.FullName.Replace($PaymentRoot, "").TrimStart("/", "\")
    $snapshotEntries += @{
        path = $relativePath
        lastModified = $file.LastWriteTimeUtc.ToString("o")
        sizeBytes = $file.Length
        name = $file.Name
    }
}

$snapshotEntries | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $iterDir "source-snapshot.json")
Write-Host "  [✓] Source snapshot: $($snapshotEntries.Count) files" -ForegroundColor Green

# ── Run dotnet tests ──────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ── Running unit tests (this may take a few minutes) ──" -ForegroundColor Cyan
Write-Host ""

function Run-Tests {
    param([string]$ProjectPath, [string]$TrxPath, [string]$LogPath)
    if (-not (Test-Path $ProjectPath)) {
        Write-Host "  [!] Project not found: $ProjectPath" -ForegroundColor DarkGray
        return @{ passed = 0; failed = 0; total = 0; passRate = 0; failures = @() }
    }

    # Build first
    & dotnet build $ProjectPath --configuration Release 2>&1 | Out-Null

    $output = & dotnet test $ProjectPath `
        --no-build `
        --logger "trx;LogFileName=$TrxPath" `
        --verbosity normal 2>&1
    $output | Set-Content $LogPath

    if (-not (Test-Path $TrxPath)) {
        return @{ passed = 0; failed = 0; total = 0; passRate = 0; failures = @() }
    }

    [xml]$trx = Get-Content $TrxPath
    $passed = [int]($trx.TestRun.ResultSummary.Counters.passed)
    $failed = [int]($trx.TestRun.ResultSummary.Counters.failed)
    $total = $passed + $failed
    $rate = if ($total -gt 0) { [math]::Round($passed / $total, 4) } else { 0 }
    $failures = @()
    if ($trx.TestRun.Results.UnitTestResult) {
        $failedResults = @($trx.TestRun.Results.UnitTestResult) | Where-Object { $_.outcome -eq "Failed" }
        foreach ($r in $failedResults) {
            $failures += @{ testName = $r.testName; errorMessage = $r.Output.ErrorInfo.Message }
        }
    }
    return @{ passed = $passed; failed = $failed; total = $total; passRate = $rate; failures = $failures }
}

Write-Host "  [→] Reconciliation API tests..." -ForegroundColor Yellow
$reconResults = Run-Tests `
    -ProjectPath "$ReconRoot/Tideline.Reconciliation.Api.Tests" `
    -TrxPath (Join-Path $tracesDir "recon-unit-tests.trx") `
    -LogPath (Join-Path $tracesDir "recon-unit-tests.log")
Write-Host "  [✓] Recon: $($reconResults.passed)/$($reconResults.total) passed" -ForegroundColor $(if ($reconResults.failed -eq 0) { "Green" } else { "Yellow" })

# Handler tests if available
$handlerResults = @{ passed = 0; failed = 0; total = 0; passRate = 0; failures = @() }
$handlerTestProj = "$ReconRoot/Tideline.Reconciliation.EventHubHandler.Tests"
if (Test-Path $handlerTestProj) {
    Write-Host "  [→] Reconciliation handler tests..." -ForegroundColor Yellow
    $handlerResults = Run-Tests `
        -ProjectPath $handlerTestProj `
        -TrxPath (Join-Path $tracesDir "recon-handler-tests.trx") `
        -LogPath (Join-Path $tracesDir "recon-handler-tests.log")
    Write-Host "  [✓] Handler: $($handlerResults.passed)/$($handlerResults.total) passed" -ForegroundColor $(if ($handlerResults.failed -eq 0) { "Green" } else { "Yellow" })
}

Write-Host "  [→] Payment API tests..." -ForegroundColor Yellow
$paymentResults = Run-Tests `
    -ProjectPath "$PaymentRoot/Tideline.Payment.Api.Tests" `
    -TrxPath (Join-Path $tracesDir "payment-unit-tests.trx") `
    -LogPath (Join-Path $tracesDir "payment-unit-tests.log")
Write-Host "  [✓] Payment: $($paymentResults.passed)/$($paymentResults.total) passed" -ForegroundColor $(if ($paymentResults.failed -eq 0) { "Green" } else { "Yellow" })

# Write failed-tests.json
@{
    reconUnit    = $reconResults.failures
    reconHandler = $handlerResults.failures
    paymentUnit  = $paymentResults.failures
} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $tracesDir "failed-tests.json")

$totalPassed = $reconResults.passed + $handlerResults.passed + $paymentResults.passed
$totalTests  = $reconResults.total  + $handlerResults.total  + $paymentResults.total
$overallRate = if ($totalTests -gt 0) { [math]::Round($totalPassed / $totalTests, 4) } else { 0 }

# ── Write scores.json ─────────────────────────────────────────────────────────

$scores = @{
    iteration      = 0
    iterationLabel = "iteration-000"
    timestamp      = (Get-Date -Format "o")
    hypothesis     = "Baseline — current codebase state"
    buildSucceeded = $true
    isBaseline     = $true
    metrics = @{
        reconUnitTests = @{
            passed   = $reconResults.passed
            failed   = $reconResults.failed
            total    = $reconResults.total
            passRate = $reconResults.passRate
        }
        reconHandlerTests = @{
            passed   = $handlerResults.passed
            failed   = $handlerResults.failed
            total    = $handlerResults.total
            passRate = $handlerResults.passRate
        }
        paymentUnitTests = @{
            passed   = $paymentResults.passed
            failed   = $paymentResults.failed
            total    = $paymentResults.total
            passRate = $paymentResults.passRate
        }
        coverage = @{
            lineRate       = 0
            branchRate     = 0
            meetsThreshold = $false
            note           = "Run evaluate.ps1 with runsettings to capture coverage"
        }
        useCases = @{
            passed   = $totalPassed
            total    = $totalTests
            passRate = $overallRate
        }
    }
    deltaFromPrior = @{}
    paretoStatus   = "frontier"
}

$scores | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $iterDir "scores.json")
Write-Host "  [✓] scores.json written" -ForegroundColor Green

# ── Outcome ────────────────────────────────────────────────────────────────────

@"
# Outcome: Iteration 000 (Baseline)

This is the baseline capture of the Reconciliation suite before any harness optimization.

## Test Results

| Suite | Passed | Failed | Total | Pass Rate |
|-------|--------|--------|-------|-----------|
| Reconciliation Unit | $($reconResults.passed) | $($reconResults.failed) | $($reconResults.total) | $([math]::Round($reconResults.passRate * 100, 1))% |
| Reconciliation Handler | $($handlerResults.passed) | $($handlerResults.failed) | $($handlerResults.total) | $([math]::Round($handlerResults.passRate * 100, 1))% |
| Payment Unit | $($paymentResults.passed) | $($paymentResults.failed) | $($paymentResults.total) | $([math]::Round($paymentResults.passRate * 100, 1))% |

## Next Steps

The proposer should:
1. Read ``traces/failed-tests.json`` to identify the root causes of failures
2. Read source files in DocumentReconciliation and DocumentPayment for context
3. Pick the highest-impact improvement and write a hypothesis to Search/current-hypothesis.md
4. Make the change, then run: ``pwsh Scripts/evaluate.ps1``
"@ | Set-Content (Join-Path $iterDir "outcome.md")
Write-Host "  [✓] outcome.md written" -ForegroundColor Green

# ── Also create Search/current-hypothesis.md template ────────────────────────

$searchHypothesis = Join-Path (Join-Path $HarnessRoot "Search") "current-hypothesis.md"
if (-not (Test-Path $searchHypothesis)) {
@"
# Hypothesis: Iteration 001

**Author:** [proposer]
**Date:** $(Get-Date -Format "yyyy-MM-dd")

## Observation

[What did you see in the traces? Which tests are failing? What patterns do you notice?]

## Root Cause Hypothesis

[What do you believe is causing the failure? Be specific — cite trace evidence.]

## Proposed Change

[What change will you make? Which file(s)? What exactly will change?]

## Expected Impact

[How many additional tests do you expect to pass? Which module? Why is this change safe?]

## Risk Assessment

[What could this change break? How are you guarding against regression?]

## Success Criteria

<!-- One row per criterion: module | metric | operator | target -->
<!-- Example: * | reconUnitPassRate | >= | 0.95 -->
"@ | Set-Content $searchHypothesis
    Write-Host "  [✓] Search/current-hypothesis.md template created" -ForegroundColor Green
}

# ── Final summary ─────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Baseline initialization complete!" -ForegroundColor Green
Write-Host "  ══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  iteration-000 created at: Population/iteration-000/" -ForegroundColor White
Write-Host "  Source files captured: $($snapshotEntries.Count)" -ForegroundColor White
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  1. Review baseline: pwsh Scripts/harness-cli.ps1 show-outcome 0" -ForegroundColor White
Write-Host "  2. Read traces:     cat Population/iteration-000/traces/failed-tests.json" -ForegroundColor White
Write-Host "  3. Read CLAUDE.md for proposer guidance" -ForegroundColor White
Write-Host "  4. Write hypothesis → make code change → pwsh Scripts/evaluate.ps1" -ForegroundColor White
Write-Host ""
