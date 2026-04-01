<#
.SYNOPSIS
    WSL-compatible suite startup for the Harness-Recon optimization loop.
    Starts DocumentReconciliation (port 5200) and DocumentPayment (port 5201)
    as headless background processes.

.DESCRIPTION
    Stops existing services, then starts all components as background processes
    writing to log files (no popup windows required).

    Components started:
      Stage 5: Reconciliation API (dotnet run :5200)
      Stage 5: Reconciliation EventHub Handler (dotnet run)
      Stage 6: Payment API (dotnet run :5201)
      UI:      React app (npm start :4202)

.USAGE
    From WSL:
      "/mnt/c/Program Files/PowerShell/7/pwsh.exe" -File D:\Harness-Recon\start-suite.ps1

    From Windows PowerShell:
      pwsh -File D:\Harness-Recon\start-suite.ps1
#>

$ErrorActionPreference = "Continue"

# ── Paths ─────────────────────────────────────────────────────────────────────

$PipelineRoot = if (Test-Path "D:\DocumentReconciliation") { "D:\" }
               elseif ($env:PIPELINE_ROOT) { $env:PIPELINE_ROOT }
               else { throw "Cannot find pipeline root. Set PIPELINE_ROOT environment variable." }

$DotnetExe = "C:\Program Files\dotnet\dotnet.exe"
$NodeBin   = "C:\Program Files\nodejs"
$NpmCmd    = "$NodeBin\npm.cmd"

$LogRoot = "${PipelineRoot}DocumentReconciliation\WorkingFiles"
$PidFile = "${PipelineRoot}DocumentReconciliation\WorkingFiles\suite-pids.txt"

if (-not (Test-Path $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null }

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  Harness-Recon  |  Suite Start (Headless)                                 " -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Stop running services ─────────────────────────────────────────────

Write-Host "[1/3] Stopping existing services..." -ForegroundColor Yellow

$killNames = @(
    "Tideline.Reconciliation.EventHubHandler",
    "Tideline.Payment.Api"
)

foreach ($name in $killNames) {
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped: $name ($($procs.Count))" -ForegroundColor DarkGray
    }
}

# Stop any dotnet processes running Reconciliation or Payment
Get-Process -Name "dotnet" -ErrorAction SilentlyContinue | ForEach-Object {
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
    if ($cmd -like "*Reconciliation*" -or $cmd -like "*Payment*") {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped: dotnet (PID $($_.Id))" -ForegroundColor DarkGray
    }
}

# Stop React UI
Get-Process -Name "node" -ErrorAction SilentlyContinue | ForEach-Object {
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
    if ($cmd -like "*documentreconciliation*" -or $cmd -like "*webpack*") {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped: react-ui (node PID $($_.Id))" -ForegroundColor DarkGray
    }
}

Start-Sleep -Seconds 2
Write-Host "  Done." -ForegroundColor Green
Write-Host ""

# ── Step 2: Build handler projects ────────────────────────────────────────────

Write-Host "[2/3] Building projects (Debug)..." -ForegroundColor Yellow

$projects = @(
    "${PipelineRoot}DocumentReconciliation\Tideline.Reconciliation.Api\Tideline.Reconciliation.Api.csproj",
    "${PipelineRoot}DocumentReconciliation\Tideline.Reconciliation.EventHubHandler\Tideline.Reconciliation.EventHubHandler.csproj",
    "${PipelineRoot}DocumentPayment\Tideline.Payment.Api\Tideline.Payment.Api.csproj"
)

$buildFailed = $false
foreach ($proj in $projects) {
    if (-not (Test-Path $proj)) {
        Write-Host "  SKIPPED (not found): $proj" -ForegroundColor DarkGray
        continue
    }
    $projName = Split-Path $proj -Leaf
    Write-Host "  Building $projName..." -ForegroundColor DarkGray
    $output = & $DotnetExe build $proj --configuration Debug --no-restore 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [!] Build FAILED: $projName" -ForegroundColor Red
        $output | Select-Object -Last 5 | Write-Host
        $buildFailed = $true
    } else {
        Write-Host "  [OK] $projName" -ForegroundColor Green
    }
}

if ($buildFailed) {
    Write-Host ""
    Write-Host "  One or more builds failed. Services may run stale binaries." -ForegroundColor Yellow
}
Write-Host ""

# ── Step 3: Start services ─────────────────────────────────────────────────────

Write-Host "[3/3] Starting services (headless)..." -ForegroundColor Yellow
Write-Host ""

$pids = @{}

function Start-Service {
    param(
        [string]$Label,
        [string]$Exe,
        [string]$ArgString,
        [string]$WorkDir,
        [string]$LogBase
    )

    $outLog = "$LogBase.log"
    $errLog = "$LogBase.err.log"

    if (-not (Test-Path $Exe)) {
        Write-Host "  [$Label] SKIPPED — exe not found: $Exe" -ForegroundColor Yellow
        return $null
    }

    if (-not (Test-Path $WorkDir)) {
        Write-Host "  [$Label] SKIPPED — working dir not found: $WorkDir" -ForegroundColor Yellow
        return $null
    }

    $cmdLine = if ($ArgString) { "`"$Exe`" $ArgString" } else { "`"$Exe`"" }
    $proc = Start-Process "cmd.exe" `
        -ArgumentList "/c $cmdLine" `
        -WorkingDirectory $WorkDir `
        -NoNewWindow `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError  $errLog `
        -PassThru

    Write-Host "  [$Label] PID $($proc.Id)" -ForegroundColor Green
    Write-Host "         Log: $outLog" -ForegroundColor DarkGray
    return $proc.Id
}

# Stage 5: Reconciliation API
$pids["recon-api"] = Start-Service `
    -Label     "Reconciliation API (:5200)" `
    -Exe       $DotnetExe `
    -ArgString "run --project `"${PipelineRoot}DocumentReconciliation\Tideline.Reconciliation.Api\Tideline.Reconciliation.Api.csproj`"" `
    -WorkDir   "${PipelineRoot}DocumentReconciliation" `
    -LogBase   "$LogRoot\recon-api"
Start-Sleep -Seconds 5

# Stage 5: Reconciliation EventHub Handler
$reconHandlerExe = "${PipelineRoot}DocumentReconciliation\Tideline.Reconciliation.EventHubHandler\bin\Debug\net10.0\Tideline.Reconciliation.EventHubHandler.exe"
if (Test-Path $reconHandlerExe) {
    $pids["recon-handler"] = Start-Service `
        -Label   "Reconciliation Handler" `
        -Exe     $reconHandlerExe `
        -WorkDir "${PipelineRoot}DocumentReconciliation\Tideline.Reconciliation.EventHubHandler\bin\Debug\net10.0" `
        -LogBase "$LogRoot\recon-handler"
    Start-Sleep -Seconds 3
}

# Stage 6: Payment API
$pids["payment-api"] = Start-Service `
    -Label     "Payment API (:5201)" `
    -Exe       $DotnetExe `
    -ArgString "run --project `"${PipelineRoot}DocumentPayment\Tideline.Payment.Api\Tideline.Payment.Api.csproj`"" `
    -WorkDir   "${PipelineRoot}DocumentPayment" `
    -LogBase   "$LogRoot\payment-api"
Start-Sleep -Seconds 5

# React UI (npm start — runs from DocumentReconciliation which has the shared node_modules)
$pids["react-ui"] = Start-Service `
    -Label     "React UI (:4202)" `
    -Exe       $NpmCmd `
    -ArgString "start" `
    -WorkDir   "${PipelineRoot}DocumentReconciliation" `
    -LogBase   "$LogRoot\react-ui"

# Write PID file
$pids | ConvertTo-Json | Set-Content $PidFile
Write-Host ""
Write-Host "  PIDs saved to: $PidFile" -ForegroundColor DarkGray

# ── Health check: Reconciliation API ──────────────────────────────────────────

Write-Host ""
Write-Host "  Waiting for Reconciliation API to become ready..." -ForegroundColor Yellow

$apiUrl  = "http://localhost:5200/health"
$maxWait = 60
$elapsed = 0
$ready   = $false

while ($elapsed -lt $maxWait) {
    Start-Sleep -Seconds 3
    $elapsed += 3
    try {
        $resp = Invoke-WebRequest -Uri $apiUrl -TimeoutSec 2 -ErrorAction Stop
        if ($resp.StatusCode -lt 400) { $ready = $true; break }
    } catch { }
    Write-Host "  Waiting... ($elapsed s)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
if ($ready) {
    Write-Host "  Suite is READY" -ForegroundColor Green
    Write-Host "  Reconciliation API: http://localhost:5200" -ForegroundColor White
    Write-Host "  Payment API:        http://localhost:5201" -ForegroundColor White
    Write-Host "  React UI:           http://localhost:4202  (may take ~30s for webpack)" -ForegroundColor White
} else {
    Write-Host "  API did not respond within ${maxWait}s — check logs in:" -ForegroundColor Yellow
    Write-Host "  $LogRoot" -ForegroundColor White
}
Write-Host ""
Write-Host "  To stop:  pwsh D:\Harness-Recon\stop-suite.ps1" -ForegroundColor DarkGray
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""
