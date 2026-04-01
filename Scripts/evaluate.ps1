<#
.SYNOPSIS
    Full evaluation runner for the Reconciliation harness optimization loop.
    Implements step (2) of Algorithm 1 from the Meta-Harness paper:
    evaluate the proposed harness and log ALL results to the filesystem.

.DESCRIPTION
    Runs the complete Reconciliation + Payment test suites (unit, integration),
    captures TRX results and Cobertura coverage, parses metrics, and writes
    everything into Population/iteration-NNN/ for the proposer to inspect.

    Called by run-harness.ps1. Can also be called directly.

.PARAMETER HypothesisFile
    Path to Search/current-hypothesis.md written by the proposer before evaluation.

.PARAMETER IterationLabel
    Optional override for iteration number. If omitted, auto-increments from last.
#>
param(
    [string]$HypothesisFile = "Search/current-hypothesis.md",
    [string]$IterationLabel = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HarnessRoot = Split-Path -Parent $ScriptDir
$IsWSL = ($env:WSL_DISTRO_NAME -ne $null) -or ($IsLinux -and (Test-Path /mnt/d -ErrorAction SilentlyContinue))
$ReconRoot = if ($IsWSL) { "/mnt/d/DocumentReconciliation" } else { "D:\DocumentReconciliation" }
$PaymentRoot = if ($IsWSL) { "/mnt/d/DocumentPayment" } else { "D:\DocumentPayment" }
$PopulationRoot = Join-Path $HarnessRoot "Population"
$ResultsRoot = Join-Path $HarnessRoot "Results"

# ── Determine iteration number ──────────────────────────────────────────────

function Get-NextIteration {
    $existing = Get-ChildItem $PopulationRoot -Directory -Filter "iteration-*" -ErrorAction SilentlyContinue
    if (-not $existing) { return 1 }
    $nums = $existing.Name | ForEach-Object { [int]($_ -replace "iteration-", "") }
    return ($nums | Measure-Object -Maximum).Maximum + 1
}

if ($IterationLabel -eq "") {
    $iterNum = Get-NextIteration
    $IterationLabel = "{0:D3}" -f $iterNum
}

$iterDir = Join-Path $PopulationRoot "iteration-$IterationLabel"
$tracesDir = Join-Path $iterDir "traces"
New-Item -ItemType Directory -Path $iterDir -Force | Out-Null
New-Item -ItemType Directory -Path $tracesDir -Force | Out-Null

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Harness-Recon Evaluator  |  Iteration $IterationLabel" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ── Copy hypothesis ──────────────────────────────────────────────────────────

$hypothesisPath = Join-Path $HarnessRoot $HypothesisFile
if (Test-Path $hypothesisPath) {
    Copy-Item $hypothesisPath (Join-Path $iterDir "hypothesis.md") -Force
    Write-Host "  [✓] Hypothesis captured" -ForegroundColor Green
} else {
    Write-Warning "  [!] No hypothesis file found at $HypothesisFile — proceeding without it"
    "No hypothesis recorded for this iteration." | Set-Content (Join-Path $iterDir "hypothesis.md")
}

# ── Capture source snapshot ──────────────────────────────────────────────────

Write-Host "  [→] Capturing source snapshot..." -ForegroundColor Yellow

$snapshotEntries = @()

# Snapshot Reconciliation API Services
$reconFiles = Get-ChildItem "$ReconRoot/Tideline.Reconciliation.Api" -Recurse -Filter "*.cs" -ErrorAction SilentlyContinue
foreach ($file in $reconFiles) {
    $relativePath = "DocumentReconciliation/" + $file.FullName.Replace($ReconRoot, "").TrimStart("/", "\")
    $snapshotEntries += @{
        path = $relativePath
        lastModified = $file.LastWriteTimeUtc.ToString("o")
        sizeBytes = $file.Length
    }
}

# Snapshot Payment API
$paymentFiles = Get-ChildItem "$PaymentRoot/Tideline.Payment.Api" -Recurse -Filter "*.cs" -ErrorAction SilentlyContinue
foreach ($file in $paymentFiles) {
    $relativePath = "DocumentPayment/" + $file.FullName.Replace($PaymentRoot, "").TrimStart("/", "\")
    $snapshotEntries += @{
        path = $relativePath
        lastModified = $file.LastWriteTimeUtc.ToString("o")
        sizeBytes = $file.Length
    }
}

$snapshotEntries | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $iterDir "source-snapshot.json")
Write-Host "  [✓] Source snapshot: $($snapshotEntries.Count) files" -ForegroundColor Green

# ── Helper: Run dotnet test and capture output ───────────────────────────────

function Invoke-DotNetTest {
    param(
        [string]$ProjectPath,
        [string]$TrxOutputPath,
        [string]$LogPath,
        [string]$Filter = "",
        [string]$RunSettingsPath = ""
    )

    $args = @(
        "test", $ProjectPath,
        "--no-build",
        "--logger", "trx;LogFileName=$TrxOutputPath",
        "--verbosity", "normal"
    )
    if ($Filter) { $args += "--filter", $Filter }
    if ($RunSettingsPath -and (Test-Path $RunSettingsPath)) {
        $args += "--settings", $RunSettingsPath
    }

    $output = & dotnet @args 2>&1
    $output | Set-Content $LogPath
    return $LASTEXITCODE
}

# ── Build: Reconciliation solution ───────────────────────────────────────────

Write-Host "  [→] Building DocumentReconciliation solution..." -ForegroundColor Yellow

$reconBuildLog = @()
$buildFailed = $false

$reconProjects = @(
    "$ReconRoot/Tideline.Reconciliation.Api/Tideline.Reconciliation.Api.csproj",
    "$ReconRoot/Tideline.Reconciliation.Domain/Tideline.Reconciliation.Domain.csproj",
    "$ReconRoot/Tideline.Reconciliation.Api.Tests/Tideline.Reconciliation.Api.Tests.csproj"
)

# Add handler test project if it exists
$handlerTestProj = "$ReconRoot/Tideline.Reconciliation.EventHubHandler.Tests/Tideline.Reconciliation.EventHubHandler.Tests.csproj"
if (Test-Path $handlerTestProj) { $reconProjects += $handlerTestProj }

foreach ($proj in $reconProjects) {
    if (-not (Test-Path $proj)) {
        Write-Host "  [!] Project not found (skipped): $proj" -ForegroundColor DarkGray
        continue
    }
    $projName = Split-Path $proj -Leaf
    $output = & dotnet build $proj --configuration Release 2>&1
    $reconBuildLog += $output
    if ($LASTEXITCODE -ne 0) {
        $buildFailed = $true
        Write-Host "  [✗] Build FAILED on $projName" -ForegroundColor Red
        $output | Select-Object -Last 10 | Write-Host
    }
}

# ── Build: Payment solution ───────────────────────────────────────────────────

Write-Host "  [→] Building DocumentPayment solution..." -ForegroundColor Yellow

$paymentProjects = @(
    "$PaymentRoot/Tideline.Payment.Api/Tideline.Payment.Api.csproj",
    "$PaymentRoot/Tideline.Payment.Domain/Tideline.Payment.Domain.csproj",
    "$PaymentRoot/Tideline.Payment.Api.Tests/Tideline.Payment.Api.Tests.csproj"
)

foreach ($proj in $paymentProjects) {
    if (-not (Test-Path $proj)) {
        Write-Host "  [!] Project not found (skipped): $proj" -ForegroundColor DarkGray
        continue
    }
    $projName = Split-Path $proj -Leaf
    $output = & dotnet build $proj --configuration Release 2>&1
    $reconBuildLog += $output
    if ($LASTEXITCODE -ne 0) {
        $buildFailed = $true
        Write-Host "  [✗] Build FAILED on $projName" -ForegroundColor Red
        $output | Select-Object -Last 10 | Write-Host
    }
}

$reconBuildLog | Set-Content (Join-Path $tracesDir "build.log")

if ($buildFailed) {
    @{ iteration = [int]$IterationLabel; buildFailed = $true; timestamp = (Get-Date -Format "o") } |
        ConvertTo-Json | Set-Content (Join-Path $iterDir "scores.json")
    exit 1
}
Write-Host "  [✓] Build succeeded" -ForegroundColor Green

# ── Reconciliation unit tests ─────────────────────────────────────────────────

Write-Host "  [→] Running Reconciliation unit tests..." -ForegroundColor Yellow
$reconTrx = Join-Path $tracesDir "recon-unit-tests.trx"
$reconLog = Join-Path $tracesDir "recon-unit-tests.log"

$reconApiTestProj = "$ReconRoot/Tideline.Reconciliation.Api.Tests"
$reconExit = if (Test-Path $reconApiTestProj) {
    Invoke-DotNetTest `
        -ProjectPath $reconApiTestProj `
        -TrxOutputPath $reconTrx `
        -LogPath $reconLog
} else { -1 }

# Move coverage output if it exists
$coverageXml = "$ReconRoot/Tideline.Reconciliation.Api.Tests/coverage.cobertura.xml"
if (Test-Path $coverageXml) {
    Copy-Item $coverageXml (Join-Path $tracesDir "coverage.xml") -Force
}

Write-Host "  [✓] Reconciliation unit tests complete (exit: $reconExit)" -ForegroundColor $(if ($reconExit -eq 0) { "Green" } else { "Yellow" })

# ── Reconciliation handler tests (if project exists) ─────────────────────────

$handlerTrx = Join-Path $tracesDir "recon-handler-tests.trx"
$handlerLog = Join-Path $tracesDir "recon-handler-tests.log"
$handlerExit = -1

$handlerTestDir = "$ReconRoot/Tideline.Reconciliation.EventHubHandler.Tests"
if (Test-Path $handlerTestDir) {
    Write-Host "  [→] Running Reconciliation handler tests..." -ForegroundColor Yellow
    $handlerExit = Invoke-DotNetTest `
        -ProjectPath $handlerTestDir `
        -TrxOutputPath $handlerTrx `
        -LogPath $handlerLog
    Write-Host "  [✓] Handler tests complete (exit: $handlerExit)" -ForegroundColor $(if ($handlerExit -eq 0) { "Green" } else { "Yellow" })
} else {
    Write-Host "  [─] Handler test project not found — skipping" -ForegroundColor Gray
}

# ── Payment unit tests ────────────────────────────────────────────────────────

Write-Host "  [→] Running Payment unit tests..." -ForegroundColor Yellow
$paymentTrx = Join-Path $tracesDir "payment-unit-tests.trx"
$paymentLog = Join-Path $tracesDir "payment-unit-tests.log"

$paymentTestProj = "$PaymentRoot/Tideline.Payment.Api.Tests"
$paymentExit = if (Test-Path $paymentTestProj) {
    Invoke-DotNetTest `
        -ProjectPath $paymentTestProj `
        -TrxOutputPath $paymentTrx `
        -LogPath $paymentLog
} else { -1 }

Write-Host "  [✓] Payment unit tests complete (exit: $paymentExit)" -ForegroundColor $(if ($paymentExit -eq 0) { "Green" } else { "Yellow" })

# ── Parse TRX results ────────────────────────────────────────────────────────

function Parse-TrxFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return @{ passed = 0; failed = 0; total = 0; passRate = 0; failures = @() }
    }
    [xml]$trx = Get-Content $Path
    $passed = [int]($trx.TestRun.ResultSummary.Counters.passed)
    $failed = [int]($trx.TestRun.ResultSummary.Counters.failed)
    $total = $passed + $failed
    $rate = if ($total -gt 0) { [math]::Round($passed / $total, 4) } else { 0 }

    $failures = @()
    if ($trx.TestRun.Results.UnitTestResult) {
        $failedResults = @($trx.TestRun.Results.UnitTestResult) | Where-Object { $_.outcome -eq "Failed" }
        foreach ($r in $failedResults) {
            $failures += @{
                testName = $r.testName
                errorMessage = $r.Output.ErrorInfo.Message
                stackTrace = ($r.Output.ErrorInfo.StackTrace -split "`n")[0..2] -join " | "
            }
        }
    }

    return @{
        passed = $passed
        failed = $failed
        total = $total
        passRate = $rate
        failures = $failures
    }
}

$reconResults = Parse-TrxFile $reconTrx
$handlerResults = Parse-TrxFile $handlerTrx
$paymentResults = Parse-TrxFile $paymentTrx

# ── Parse coverage ───────────────────────────────────────────────────────────

function Parse-Coverage {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @{ lineRate = 0; branchRate = 0 } }
    [xml]$cov = Get-Content $Path
    return @{
        lineRate = [math]::Round([double]$cov.coverage.'line-rate', 4)
        branchRate = [math]::Round([double]$cov.coverage.'branch-rate', 4)
    }
}

$coverage = Parse-Coverage (Join-Path $tracesDir "coverage.xml")

# ── Write failed-tests.json ───────────────────────────────────────────────────

$allFailures = @{
    reconUnit    = $reconResults.failures
    reconHandler = $handlerResults.failures
    paymentUnit  = $paymentResults.failures
}
$allFailures | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $tracesDir "failed-tests.json")

# ── Load e2e results if already captured by deploy.ps1 ───────────────────────

function Load-E2eResults {
    param([string]$TracesDir)
    $e2ePath = Join-Path $TracesDir "e2e-results.json"
    if (-not (Test-Path $e2ePath)) {
        return @{
            recon   = @{ passed = 0; failed = 0; total = 0; passRate = 0 }
            payment = @{ passed = 0; failed = 0; total = 0; passRate = 0 }
            present = $false
        }
    }
    $raw = Get-Content $e2ePath -Raw | ConvertFrom-Json
    return @{
        recon   = @{
            passed   = [int]($raw.recon.passed   ?? 0)
            failed   = [int]($raw.recon.failed   ?? 0)
            total    = [int]($raw.recon.total    ?? 0)
            passRate = [double]($raw.recon.passRate ?? 0)
        }
        payment = @{
            passed   = [int]($raw.payment.passed   ?? 0)
            failed   = [int]($raw.payment.failed   ?? 0)
            total    = [int]($raw.payment.total    ?? 0)
            passRate = [double]($raw.payment.passRate ?? 0)
        }
        present = $true
    }
}

$e2eData = Load-E2eResults -TracesDir $tracesDir

# ── Compute combined use-case pass rate ───────────────────────────────────────

$totalPassed = $reconResults.passed + $handlerResults.passed + $paymentResults.passed
$totalTests  = $reconResults.total  + $handlerResults.total  + $paymentResults.total
$overallRate = if ($totalTests -gt 0) { [math]::Round($totalPassed / $totalTests, 4) } else { 0 }

# ── Compute delta from prior iteration ───────────────────────────────────────

function Get-PriorScores {
    param([int]$CurrentNum)
    $priorNum = $CurrentNum - 1
    if ($priorNum -lt 0) { return $null }
    $priorLabel = "{0:D3}" -f $priorNum
    $priorScores = Join-Path $PopulationRoot "iteration-$priorLabel/scores.json"
    if (Test-Path $priorScores) {
        return (Get-Content $priorScores | ConvertFrom-Json)
    }
    return $null
}

$currentNum = [int]$IterationLabel
$prior = Get-PriorScores -CurrentNum $currentNum
$delta = @{}
if ($prior -and $prior.metrics) {
    $delta.reconUnitPassRate    = [math]::Round($reconResults.passRate - $prior.metrics.reconUnitTests.passRate, 4)
    $delta.paymentUnitPassRate  = [math]::Round($paymentResults.passRate - $prior.metrics.paymentUnitTests.passRate, 4)
    $delta.coverage             = [math]::Round($coverage.lineRate - $prior.metrics.coverage.lineRate, 4)
    $delta.overallPassRate      = [math]::Round($overallRate - $prior.metrics.useCases.passRate, 4)
}

# ── Pareto frontier check ─────────────────────────────────────────────────────

function Test-ParetoFrontier {
    param([hashtable]$Candidate, [array]$Population)
    foreach ($other in $Population) {
        if ($other -and $other.metrics) {
            $dominated = (
                $other.metrics.reconUnitTests.passRate -ge $Candidate.reconUnitPassRate -and
                $other.metrics.paymentUnitTests.passRate -ge $Candidate.paymentUnitPassRate -and
                $other.metrics.coverage.lineRate -ge $Candidate.coverageLineRate -and
                (
                    $other.metrics.reconUnitTests.passRate -gt $Candidate.reconUnitPassRate -or
                    $other.metrics.paymentUnitTests.passRate -gt $Candidate.paymentUnitPassRate -or
                    $other.metrics.coverage.lineRate -gt $Candidate.coverageLineRate
                )
            )
            if ($dominated) { return $false }
        }
    }
    return $true
}

$priorIterations = Get-ChildItem $PopulationRoot -Directory -Filter "iteration-*" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "iteration-$IterationLabel" } |
    ForEach-Object {
        $sf = Join-Path $_.FullName "scores.json"
        if (Test-Path $sf) { Get-Content $sf | ConvertFrom-Json }
    }

$candidateMetrics = @{
    reconUnitPassRate   = $reconResults.passRate
    paymentUnitPassRate = $paymentResults.passRate
    coverageLineRate    = $coverage.lineRate
}
$onFrontier = Test-ParetoFrontier -Candidate $candidateMetrics -Population $priorIterations

# ── Write scores.json ────────────────────────────────────────────────────────

$hypothesis = if (Test-Path (Join-Path $iterDir "hypothesis.md")) {
    (Get-Content (Join-Path $iterDir "hypothesis.md") -Raw).Trim().Split("`n")[0]
} else { "" }

$scores = @{
    iteration      = $currentNum
    iterationLabel = "iteration-$IterationLabel"
    timestamp      = (Get-Date -Format "o")
    hypothesis     = $hypothesis
    buildSucceeded = $true
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
        reconE2eTests = @{
            passed   = $e2eData.recon.passed
            failed   = $e2eData.recon.failed
            total    = $e2eData.recon.total
            passRate = $e2eData.recon.passRate
            present  = $e2eData.present
        }
        paymentE2eTests = @{
            passed   = $e2eData.payment.passed
            failed   = $e2eData.payment.failed
            total    = $e2eData.payment.total
            passRate = $e2eData.payment.passRate
            present  = $e2eData.present
        }
        coverage = @{
            lineRate       = $coverage.lineRate
            branchRate     = $coverage.branchRate
            meetsThreshold = $coverage.lineRate -ge 0.80
        }
        useCases = @{
            passed   = $totalPassed
            total    = $totalTests
            passRate = $overallRate
        }
    }
    deltaFromPrior = $delta
    paretoStatus   = if ($onFrontier) { "frontier" } else { "dominated" }
}

$scores | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $iterDir "scores.json")

# ── Update Results/pareto-frontier.json ──────────────────────────────────────

$allScores = Get-ChildItem $PopulationRoot -Directory -Filter "iteration-*" -ErrorAction SilentlyContinue |
    ForEach-Object {
        $sf = Join-Path $_.FullName "scores.json"
        if (Test-Path $sf) { Get-Content $sf | ConvertFrom-Json }
    }

$frontierItems = $allScores | Where-Object { $_.paretoStatus -eq "frontier" }
if (-not (Test-Path $ResultsRoot)) { New-Item -ItemType Directory $ResultsRoot -Force | Out-Null }
$frontierItems | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $ResultsRoot "pareto-frontier.json")

# ── Write outcome.md ─────────────────────────────────────────────────────────

$totalFailed = $reconResults.failed + $handlerResults.failed + $paymentResults.failed

$e2eSection = if ($e2eData.present) {
    @"

## E2E Tests (ACI)

| Suite | Passed | Failed | Total | Pass Rate |
|-------|--------|--------|-------|-----------|
| Reconciliation E2E | $($e2eData.recon.passed) | $($e2eData.recon.failed) | $($e2eData.recon.total) | $([math]::Round($e2eData.recon.passRate * 100, 1))% |
| Payment E2E | $($e2eData.payment.passed) | $($e2eData.payment.failed) | $($e2eData.payment.total) | $([math]::Round($e2eData.payment.passRate * 100, 1))% |

See ``traces/e2e-results.json`` for failure details. Playwright reports in ``traces/playwright-report-recon/`` and ``traces/playwright-report-payment/``.
"@
} else {
    "`n## E2E Tests (ACI)`n`nNot run for this iteration. Run ``pwsh Scripts/deploy.ps1 -SkipBuild -SkipPush -SkipDeploy`` to add e2e results.`n"
}

$outcomeContent = @"
# Outcome: Iteration $IterationLabel

**Timestamp:** $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
**Pareto Status:** $($scores.paretoStatus)

## Metrics

| Suite | Passed | Failed | Total | Pass Rate |
|-------|--------|--------|-------|-----------|
| Reconciliation Unit | $($reconResults.passed) | $($reconResults.failed) | $($reconResults.total) | $([math]::Round($reconResults.passRate * 100, 1))% |
| Reconciliation Handler | $($handlerResults.passed) | $($handlerResults.failed) | $($handlerResults.total) | $([math]::Round($handlerResults.passRate * 100, 1))% |
| Payment Unit | $($paymentResults.passed) | $($paymentResults.failed) | $($paymentResults.total) | $([math]::Round($paymentResults.passRate * 100, 1))% |

**Coverage:** $([math]::Round($coverage.lineRate * 100, 1))% line rate $(if ($coverage.lineRate -ge 0.80) { "(✓ meets threshold)" } else { "(✗ below 80% threshold)" })
$e2eSection
## Delta from Prior

$(if ($delta.Count -gt 0) {
    "- Reconciliation unit pass rate: $(if ($delta.reconUnitPassRate -ge 0) { '+' })$($delta.reconUnitPassRate * 100 | % { [math]::Round($_, 2) })pp"
    "- Payment unit pass rate: $(if ($delta.paymentUnitPassRate -ge 0) { '+' })$($delta.paymentUnitPassRate * 100 | % { [math]::Round($_, 2) })pp"
    "- Coverage: $(if ($delta.coverage -ge 0) { '+' })$($delta.coverage * 100 | % { [math]::Round($_, 2) })pp"
} else { "No prior iteration to compare against." })

## Failures

$totalFailed total unit/handler test failures. See ``traces/failed-tests.json`` for details.
"@

$outcomeContent | Set-Content (Join-Path $iterDir "outcome.md")

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Evaluation Complete: Iteration $IterationLabel" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Recon Unit:    $($reconResults.passed)/$($reconResults.total) passed ($([math]::Round($reconResults.passRate * 100, 1))%)" -ForegroundColor $(if ($reconResults.failed -eq 0) { "Green" } else { "Yellow" })
Write-Host "  Recon Handler: $($handlerResults.passed)/$($handlerResults.total) passed ($([math]::Round($handlerResults.passRate * 100, 1))%)" -ForegroundColor $(if ($handlerResults.failed -eq 0) { "Green" } else { "Yellow" })
Write-Host "  Payment Unit:  $($paymentResults.passed)/$($paymentResults.total) passed ($([math]::Round($paymentResults.passRate * 100, 1))%)" -ForegroundColor $(if ($paymentResults.failed -eq 0) { "Green" } else { "Yellow" })
if ($e2eData.present) {
    Write-Host "  Recon E2E:     $($e2eData.recon.passed)/$($e2eData.recon.total) passed ($([math]::Round($e2eData.recon.passRate * 100, 1))%)" -ForegroundColor $(if ($e2eData.recon.failed -eq 0) { "Green" } else { "Yellow" })
    Write-Host "  Payment E2E:   $($e2eData.payment.passed)/$($e2eData.payment.total) passed ($([math]::Round($e2eData.payment.passRate * 100, 1))%)" -ForegroundColor $(if ($e2eData.payment.failed -eq 0) { "Green" } else { "Yellow" })
} else {
    Write-Host "  E2E:           (not run — use deploy.ps1 to add ACI e2e results)" -ForegroundColor Gray
}
Write-Host "  Coverage:      $([math]::Round($coverage.lineRate * 100, 1))%" -ForegroundColor $(if ($coverage.lineRate -ge 0.80) { "Green" } else { "Red" })
Write-Host "  Pareto:        $($scores.paretoStatus)" -ForegroundColor $(if ($onFrontier) { "Green" } else { "Gray" })
Write-Host ""
Write-Host "  Results saved to: Population/iteration-$IterationLabel/" -ForegroundColor Cyan
Write-Host ""
