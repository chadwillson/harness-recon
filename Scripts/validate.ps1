<#
.SYNOPSIS
    Lightweight pre-validation for Reconciliation harness candidates.
    Per Meta-Harness paper (Appendix D): "Write a small validation test that imports
    the module, instantiates the class, and calls both methods on a tiny set of examples.
    A simple test script can catch most malformed or nonfunctional candidates in seconds."

.DESCRIPTION
    Runs a fast smoke test before committing to the expensive full evaluation:
    1. Verifies both solutions build successfully
    2. Runs a small subset of critical unit tests (< 30 seconds)
    3. Checks that domain model contracts are not broken

    Exit code 0 = pass, proceed to full evaluation
    Exit code 1 = fail, do not evaluate (diagnose and fix first)
#>
param(
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$IsWSL = ($env:WSL_DISTRO_NAME -ne $null) -or ($IsLinux -and (Test-Path /mnt/d -ErrorAction SilentlyContinue))
$ReconRoot   = if ($IsWSL) { "/mnt/d/DocumentReconciliation" } else { "D:\DocumentReconciliation" }
$PaymentRoot = if ($IsWSL) { "/mnt/d/DocumentPayment" } else { "D:\DocumentPayment" }

Write-Host ""
Write-Host "  [Validate] Running pre-evaluation smoke test..." -ForegroundColor Cyan

$failures = @()

# ── 1. Build check: Reconciliation ───────────────────────────────────────────

Write-Host "  [1/4] Build check: DocumentReconciliation..." -ForegroundColor Yellow

$reconSlnx = "$ReconRoot/Tideline.Reconciliation.slnx"
$reconBuildTarget = if (Test-Path $reconSlnx) { $reconSlnx } else { "$ReconRoot/Tideline.Reconciliation.Api/Tideline.Reconciliation.Api.csproj" }

$buildOutput = & dotnet build $reconBuildTarget --configuration Release --no-incremental 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [✗] DocumentReconciliation build FAILED" -ForegroundColor Red
    if ($Verbose) { $buildOutput | Select-Object -Last 20 | Write-Host }
    else {
        $buildOutput | Where-Object { $_ -match "\serror\s" } | Select-Object -First 5 | Write-Host -ForegroundColor Red
    }
    $failures += "Reconciliation build"
} else {
    Write-Host "  [✓] DocumentReconciliation build OK" -ForegroundColor Green
}

# ── 2. Build check: Payment ───────────────────────────────────────────────────

Write-Host "  [2/4] Build check: DocumentPayment..." -ForegroundColor Yellow

$paymentSlnx = "$PaymentRoot/Tideline.Payment.slnx"
$paymentBuildTarget = if (Test-Path $paymentSlnx) { $paymentSlnx } else { "$PaymentRoot/Tideline.Payment.Api/Tideline.Payment.Api.csproj" }

$buildOutput = & dotnet build $paymentBuildTarget --configuration Release --no-incremental 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [✗] DocumentPayment build FAILED" -ForegroundColor Red
    if ($Verbose) { $buildOutput | Select-Object -Last 20 | Write-Host }
    else {
        $buildOutput | Where-Object { $_ -match "\serror\s" } | Select-Object -First 5 | Write-Host -ForegroundColor Red
    }
    $failures += "Payment build"
} else {
    Write-Host "  [✓] DocumentPayment build OK" -ForegroundColor Green
}

# ── 3. Critical unit tests: Reconciliation ───────────────────────────────────

Write-Host "  [3/4] Critical Reconciliation unit tests..." -ForegroundColor Yellow

$reconTestProj = "$ReconRoot/Tideline.Reconciliation.Api.Tests"
if (Test-Path $reconTestProj) {
    # Run a quick subset — category smoke or any tests with "Status" or "Match" in name
    $criticalFilter = "Category=Smoke|FullyQualifiedName~StatusEnum|FullyQualifiedName~MatchDocument|FullyQualifiedName~ReconciliationService"
    $quickOutput = & dotnet test $reconTestProj `
        --no-build `
        --filter $criticalFilter `
        --verbosity quiet 2>&1

    if ($LASTEXITCODE -ne 0 -and ($quickOutput -notmatch "No test matches")) {
        Write-Host "  [✗] Critical Reconciliation unit tests FAILED" -ForegroundColor Red
        $failures += "Reconciliation critical tests"
        if ($Verbose) {
            $quickOutput | Where-Object { $_ -match "Failed|Error" } | Write-Host -ForegroundColor Red
        }
    } else {
        $passLine = $quickOutput | Where-Object { $_ -match "passed" } | Select-Object -Last 1
        Write-Host "  [✓] Reconciliation critical tests OK  ($passLine)" -ForegroundColor Green
    }
} else {
    Write-Host "  [─] Reconciliation test project not found — skipping" -ForegroundColor DarkGray
}

# ── 4. Critical unit tests: Payment ──────────────────────────────────────────

Write-Host "  [4/4] Critical Payment unit tests..." -ForegroundColor Yellow

$paymentTestProj = "$PaymentRoot/Tideline.Payment.Api.Tests"
if (Test-Path $paymentTestProj) {
    $criticalFilter = "Category=Smoke|FullyQualifiedName~PaymentService|FullyQualifiedName~PaymentController"
    $quickOutput = & dotnet test $paymentTestProj `
        --no-build `
        --filter $criticalFilter `
        --verbosity quiet 2>&1

    if ($LASTEXITCODE -ne 0 -and ($quickOutput -notmatch "No test matches")) {
        Write-Host "  [✗] Critical Payment unit tests FAILED" -ForegroundColor Red
        $failures += "Payment critical tests"
        if ($Verbose) {
            $quickOutput | Where-Object { $_ -match "Failed|Error" } | Write-Host -ForegroundColor Red
        }
    } else {
        $passLine = $quickOutput | Where-Object { $_ -match "passed" } | Select-Object -Last 1
        Write-Host "  [✓] Payment critical tests OK  ($passLine)" -ForegroundColor Green
    }
} else {
    Write-Host "  [─] Payment test project not found — skipping" -ForegroundColor DarkGray
}

# ── Result ───────────────────────────────────────────────────────────────────

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "  [✗] Validation FAILED: $($failures -join ', ')" -ForegroundColor Red
    Write-Host "  Diagnose failures before running full evaluation." -ForegroundColor Red
    Write-Host ""
    exit 1
} else {
    Write-Host "  [✓] Validation PASSED — safe to run evaluate.ps1" -ForegroundColor Green
    Write-Host ""
    exit 0
}
