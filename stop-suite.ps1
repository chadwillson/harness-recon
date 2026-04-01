<#
.SYNOPSIS
    WSL-compatible suite shutdown for the Harness-Recon optimization loop.

.USAGE
    From WSL:
      "/mnt/c/Program Files/PowerShell/7/pwsh.exe" -File D:\Harness-Recon\stop-suite.ps1

    From Windows PowerShell:
      pwsh -File D:\Harness-Recon\stop-suite.ps1
#>

$ErrorActionPreference = "Continue"

$PipelineRoot = if (Test-Path "D:\DocumentReconciliation") { "D:\" }
               elseif ($env:PIPELINE_ROOT) { $env:PIPELINE_ROOT }
               else { throw "Cannot find pipeline root." }

$PidFile = "${PipelineRoot}DocumentReconciliation\WorkingFiles\suite-pids.txt"

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  Harness-Recon  |  Suite Stop                                             " -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

$stopped = 0

# Stop by PID file first (most precise)
if (Test-Path $PidFile) {
    $pids = Get-Content $PidFile | ConvertFrom-Json
    foreach ($entry in $pids.PSObject.Properties) {
        $pid = [int]$entry.Value
        $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
            Write-Host "  Stopped: $($entry.Name) (PID $pid)" -ForegroundColor DarkGray
            $stopped++
        }
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

# Also stop by name (catches orphans not in PID file)
$killNames = @(
    "Tideline.Reconciliation.EventHubHandler",
    "Tideline.Payment.Api"
)

foreach ($name in $killNames) {
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped: $name ($($procs.Count) instance(s))" -ForegroundColor DarkGray
        $stopped += $procs.Count
    }
}

# Stop dotnet processes running Reconciliation or Payment
Get-Process -Name "dotnet" -ErrorAction SilentlyContinue | ForEach-Object {
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
    if ($cmd -like "*Reconciliation*" -or $cmd -like "*Payment*") {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped: dotnet (PID $($_.Id))" -ForegroundColor DarkGray
        $stopped++
    }
}

# Stop React UI node process
Get-Process -Name "node" -ErrorAction SilentlyContinue | ForEach-Object {
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
    if ($cmd -like "*documentreconciliation*" -or $cmd -like "*webpack*") {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped: node (PID $($_.Id)) [$($cmd.Substring(0, [Math]::Min(60,$cmd.Length)))]" -ForegroundColor DarkGray
        $stopped++
    }
}

Write-Host ""
Write-Host "  Stopped $stopped process(es)." -ForegroundColor Green
Write-Host ""
