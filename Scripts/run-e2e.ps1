<#
.SYNOPSIS
    Run Playwright e2e tests against both ACI deployments and capture results.

.DESCRIPTION
    Executes the Playwright test suites for DocumentReconciliation and DocumentPayment
    against the live ACI URLs, parses the JSON reporter output, and writes a structured
    e2e-results.json into the specified output directory.

    Called by deploy.ps1 after containers are healthy. Can also be run standalone
    to re-run e2e against already-deployed containers.

.PARAMETER ReconUrl
    Base URL for the Reconciliation ACI container.
    Default: http://tideline-recon-poc.westus.azurecontainer.io:8080

.PARAMETER PaymentUrl
    Base URL for the Payment ACI container.
    Default: http://tideline-payment-poc.westus.azurecontainer.io:8080

.PARAMETER OutputDir
    Directory to write e2e-results.json into.
    Default: current working directory.

.PARAMETER SkipRecon
    Skip the Reconciliation e2e suite.

.PARAMETER SkipPayment
    Skip the Payment e2e suite.

.EXAMPLE
    pwsh Scripts/run-e2e.ps1
    pwsh Scripts/run-e2e.ps1 -OutputDir Population/iteration-001/traces
    pwsh Scripts/run-e2e.ps1 -ReconUrl http://localhost:4202 -PaymentUrl http://localhost:4203
#>
param(
    [string]$ReconUrl   = "http://tideline-recon-poc.westus.azurecontainer.io:8080",
    [string]$PaymentUrl = "http://tideline-payment-poc.westus.azurecontainer.io:8080",
    [string]$OutputDir  = "",
    [switch]$SkipRecon,
    [switch]$SkipPayment
)

$ErrorActionPreference = "Stop"
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$HarnessRoot = Split-Path -Parent $ScriptDir
$IsWSL = ($env:WSL_DISTRO_NAME -ne $null) -or ($IsLinux -and (Test-Path /mnt/d -ErrorAction SilentlyContinue))
$ReconRoot   = if ($IsWSL) { "/mnt/d/DocumentReconciliation" } else { "D:\DocumentReconciliation" }
$PaymentRoot = if ($IsWSL) { "/mnt/d/DocumentPayment" } else { "D:\DocumentPayment" }

if ($OutputDir -eq "") { $OutputDir = (Get-Location).Path }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Harness-Recon E2E Runner" -ForegroundColor Cyan
Write-Host "  Recon URL:   $ReconUrl" -ForegroundColor Cyan
Write-Host "  Payment URL: $PaymentUrl" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ── Helper: parse Playwright JSON reporter output ───────────────────────────

function Parse-PlaywrightResults {
    param([string]$ResultsJsonPath)

    if (-not (Test-Path $ResultsJsonPath)) {
        return @{
            passed   = 0
            failed   = 0
            skipped  = 0
            total    = 0
            passRate = 0
            failures = @()
            error    = "results.json not found at $ResultsJsonPath"
        }
    }

    $json = Get-Content $ResultsJsonPath -Raw | ConvertFrom-Json

    # Playwright JSON reporter format: stats.expected = pass, stats.unexpected = fail
    $passed  = [int]($json.stats.expected  ?? 0)
    $failed  = [int]($json.stats.unexpected ?? 0)
    $skipped = [int]($json.stats.skipped   ?? 0)
    $total   = $passed + $failed + $skipped
    $rate    = if (($passed + $failed) -gt 0) { [math]::Round($passed / ($passed + $failed), 4) } else { 0 }

    # Collect failure details from suites
    $failures = @()
    function Walk-Suite($suite) {
        foreach ($spec in ($suite.specs ?? @())) {
            foreach ($test in ($spec.tests ?? @())) {
                foreach ($result in ($test.results ?? @())) {
                    if ($result.status -in @("failed", "timedOut")) {
                        $failures += @{
                            title   = ($spec.title ?? "") + " > " + ($test.title ?? "")
                            status  = $result.status
                            error   = ($result.error.message ?? $result.error ?? "")
                            retry   = [int]($result.retry ?? 0)
                        }
                    }
                }
            }
        }
        foreach ($child in ($suite.suites ?? @())) {
            Walk-Suite $child
        }
    }

    foreach ($suite in ($json.suites ?? @())) {
        Walk-Suite $suite
    }

    return @{
        passed   = $passed
        failed   = $failed
        skipped  = $skipped
        total    = $total
        passRate = $rate
        failures = $failures
    }
}

# ── Run a Playwright suite ───────────────────────────────────────────────────

function Invoke-PlaywrightSuite {
    param(
        [string]$SuiteRoot,
        [string]$SuiteName,
        [hashtable]$EnvVars,
        [string]$LogPath
    )

    if (-not (Test-Path $SuiteRoot)) {
        Write-Warning "  [!] Suite root not found: $SuiteRoot"
        return @{ exitCode = -1; resultsPath = "" }
    }

    $resultsDir = Join-Path $SuiteRoot "e2e/test-results"
    $resultsJson = Join-Path $resultsDir "results.json"

    # Clear prior results so we know if the run produced fresh output
    if (Test-Path $resultsJson) { Remove-Item $resultsJson -Force }

    Write-Host "  [→] Running $SuiteName e2e suite..." -ForegroundColor Yellow

    $savedEnv = @{}
    foreach ($key in $EnvVars.Keys) {
        $savedEnv[$key] = [System.Environment]::GetEnvironmentVariable($key)
        [System.Environment]::SetEnvironmentVariable($key, $EnvVars[$key])
    }

    try {
        Push-Location $SuiteRoot
        $output = & npx playwright test --reporter=json,line 2>&1
        $exitCode = $LASTEXITCODE
        Pop-Location
    } finally {
        foreach ($key in $savedEnv.Keys) {
            [System.Environment]::SetEnvironmentVariable($key, $savedEnv[$key])
        }
    }

    $output | Set-Content $LogPath
    Write-Host "  [✓] $SuiteName e2e complete (exit: $exitCode)" -ForegroundColor $(if ($exitCode -eq 0) { "Green" } else { "Yellow" })

    return @{ exitCode = $exitCode; resultsPath = $resultsJson }
}

# ── Run Reconciliation e2e ───────────────────────────────────────────────────

$reconResults  = @{ passed = 0; failed = 0; total = 0; passRate = 0; skipped = 0; failures = @() }
$reconExitCode = -1

if (-not $SkipRecon) {
    $reconRunResult = Invoke-PlaywrightSuite `
        -SuiteRoot $ReconRoot `
        -SuiteName "Reconciliation" `
        -EnvVars @{ RECON_URL = $ReconUrl } `
        -LogPath (Join-Path $OutputDir "e2e-recon.log")

    $reconExitCode = $reconRunResult.exitCode
    $reconResults  = Parse-PlaywrightResults $reconRunResult.resultsPath

    # Copy artifacts
    $reconReport = Join-Path $ReconRoot "e2e/playwright-report"
    if (Test-Path $reconReport) {
        Copy-Item $reconReport (Join-Path $OutputDir "playwright-report-recon") -Recurse -Force
    }
} else {
    Write-Host "  [─] Reconciliation e2e skipped (-SkipRecon)" -ForegroundColor Gray
}

# ── Run Payment e2e ──────────────────────────────────────────────────────────

$paymentResults  = @{ passed = 0; failed = 0; total = 0; passRate = 0; skipped = 0; failures = @() }
$paymentExitCode = -1

if (-not $SkipPayment) {
    $paymentRunResult = Invoke-PlaywrightSuite `
        -SuiteRoot $PaymentRoot `
        -SuiteName "Payment" `
        -EnvVars @{ PAYMENT_URL = $PaymentUrl } `
        -LogPath (Join-Path $OutputDir "e2e-payment.log")

    $paymentExitCode = $paymentRunResult.exitCode
    $paymentResults  = Parse-PlaywrightResults $paymentRunResult.resultsPath

    $paymentReport = Join-Path $PaymentRoot "e2e/playwright-report"
    if (Test-Path $paymentReport) {
        Copy-Item $paymentReport (Join-Path $OutputDir "playwright-report-payment") -Recurse -Force
    }
} else {
    Write-Host "  [─] Payment e2e skipped (-SkipPayment)" -ForegroundColor Gray
}

# ── Write e2e-results.json ───────────────────────────────────────────────────

$combinedPassed = $reconResults.passed + $paymentResults.passed
$combinedFailed = $reconResults.failed + $paymentResults.failed
$combinedTotal  = $reconResults.total  + $paymentResults.total
$combinedRate   = if (($combinedPassed + $combinedFailed) -gt 0) {
    [math]::Round($combinedPassed / ($combinedPassed + $combinedFailed), 4)
} else { 0 }

$e2eResults = @{
    timestamp  = (Get-Date -Format "o")
    reconUrl   = $ReconUrl
    paymentUrl = $PaymentUrl
    recon = @{
        passed   = $reconResults.passed
        failed   = $reconResults.failed
        skipped  = $reconResults.skipped
        total    = $reconResults.total
        passRate = $reconResults.passRate
        exitCode = $reconExitCode
        failures = $reconResults.failures
    }
    payment = @{
        passed   = $paymentResults.passed
        failed   = $paymentResults.failed
        skipped  = $paymentResults.skipped
        total    = $paymentResults.total
        passRate = $paymentResults.passRate
        exitCode = $paymentExitCode
        failures = $paymentResults.failures
    }
    combined = @{
        passed   = $combinedPassed
        failed   = $combinedFailed
        total    = $combinedTotal
        passRate = $combinedRate
    }
}

$e2eResultsPath = Join-Path $OutputDir "e2e-results.json"
$e2eResults | ConvertTo-Json -Depth 8 | Set-Content $e2eResultsPath

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  E2E Results" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Recon E2E:   $($reconResults.passed)/$($reconResults.total) passed ($([math]::Round($reconResults.passRate * 100, 1))%)" `
    -ForegroundColor $(if ($reconResults.failed -eq 0 -and $reconResults.total -gt 0) { "Green" } elseif ($reconResults.failed -gt 0) { "Yellow" } else { "Gray" })
Write-Host "  Payment E2E: $($paymentResults.passed)/$($paymentResults.total) passed ($([math]::Round($paymentResults.passRate * 100, 1))%)" `
    -ForegroundColor $(if ($paymentResults.failed -eq 0 -and $paymentResults.total -gt 0) { "Green" } elseif ($paymentResults.failed -gt 0) { "Yellow" } else { "Gray" })
Write-Host "  Combined:    $combinedPassed/$combinedTotal passed ($([math]::Round($combinedRate * 100, 1))%)" `
    -ForegroundColor $(if ($combinedFailed -eq 0 -and $combinedTotal -gt 0) { "Green" } else { "Yellow" })
Write-Host ""
Write-Host "  Results written to: $e2eResultsPath" -ForegroundColor Cyan
Write-Host ""

# Return structured object so callers (deploy.ps1) can read results
return $e2eResults
