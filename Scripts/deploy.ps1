<#
.SYNOPSIS
    Full build → push → deploy → verify pipeline for both ACI containers.

.DESCRIPTION
    Implements the complete deploy-and-verify cycle from SYSTEM-OVERVIEW.md §9:
      1. Docker login to ACR (WSL2 workaround — no az acr login)
      2. docker build both images
      3. docker push both images
      4. az container delete both ACI containers
      5. az container create both ACI containers
      6. Poll both URLs until HTTP 200 (up to 5 minutes — SQL Server startup)
      7. Run run-e2e.ps1 against both ACI URLs
      8. Capture results into Population/iteration-NNN/traces/

    ACR registry:  tidelinerecpoc.azurecr.io
    ACI group:     tideline-recon-rg  (West US)

.PARAMETER IterationLabel
    3-digit iteration number (e.g. "001"). Auto-detected from Population/ if omitted.

.PARAMETER SkipBuild
    Skip docker build steps (use existing local images).

.PARAMETER SkipPush
    Skip docker push steps (re-deploy with current registry images).

.PARAMETER SkipDeploy
    Skip ACI delete/create steps (run e2e against already-running containers).

.PARAMETER SkipE2e
    Skip Playwright e2e after deploy. Useful for testing the deploy path alone.

.PARAMETER SkipRecon
    Skip building/deploying/testing the Reconciliation container.

.PARAMETER SkipPayment
    Skip building/deploying/testing the Payment container.

.PARAMETER PollTimeoutSeconds
    How long to poll ACI containers before giving up. Default: 360 (6 minutes).
    SQL Server + .NET startup typically takes ~90–120s.

.EXAMPLE
    # Full pipeline
    pwsh Scripts/deploy.ps1

    # Re-run e2e against existing containers (no rebuild)
    pwsh Scripts/deploy.ps1 -SkipBuild -SkipPush -SkipDeploy

    # Build and push only (no ACI redeploy)
    pwsh Scripts/deploy.ps1 -SkipDeploy -SkipE2e
#>
param(
    [string]$IterationLabel      = "",
    [switch]$SkipBuild,
    [switch]$SkipPush,
    [switch]$SkipDeploy,
    [switch]$SkipE2e,
    [switch]$SkipRecon,
    [switch]$SkipPayment,
    [int]$PollTimeoutSeconds     = 360
)

$ErrorActionPreference = "Stop"
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$HarnessRoot = Split-Path -Parent $ScriptDir
$IsWSL = ($env:WSL_DISTRO_NAME -ne $null) -or ($IsLinux -and (Test-Path /mnt/d -ErrorAction SilentlyContinue))

$ReconRoot   = if ($IsWSL) { "/mnt/d/DocumentReconciliation" } else { "D:\DocumentReconciliation" }
$PaymentRoot = if ($IsWSL) { "/mnt/d/DocumentPayment" } else { "D:\DocumentPayment" }
$PopulationRoot = Join-Path $HarnessRoot "Population"

# ── ACI / ACR constants ──────────────────────────────────────────────────────

$AcrRegistry   = "tidelinerecpoc.azurecr.io"
$AcrUser       = "tidelinerecpoc"
$AcrName       = "tidelinerecpoc"
$ResourceGroup = "tideline-recon-rg"
$Location      = "westus"

$ReconImage    = "$AcrRegistry/tideline-recon-app:latest"
$PaymentImage  = "$AcrRegistry/tideline-payment:latest"
$ReconAci      = "tideline-recon-poc"
$PaymentAci    = "tideline-payment-poc"
$ReconUrl      = "http://tideline-recon-poc.westus.azurecontainer.io:8080"
$PaymentUrl    = "http://tideline-payment-poc.westus.azurecontainer.io:8080"

$SaPassword    = "Tideline@Pass123"

# ── Determine iteration directory ────────────────────────────────────────────

function Get-NextIteration {
    $existing = Get-ChildItem $PopulationRoot -Directory -Filter "iteration-*" -ErrorAction SilentlyContinue
    if (-not $existing) { return 1 }
    $nums = $existing.Name | ForEach-Object { [int]($_ -replace "iteration-", "") }
    return ($nums | Measure-Object -Maximum).Maximum + 1
}

if ($IterationLabel -eq "") {
    # Use the most recent iteration if it exists, otherwise create new
    $existing = Get-ChildItem $PopulationRoot -Directory -Filter "iteration-*" -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -Last 1
    if ($existing) {
        $IterationLabel = $existing.Name -replace "iteration-", ""
    } else {
        $IterationLabel = "{0:D3}" -f (Get-NextIteration)
    }
}

$iterDir   = Join-Path $PopulationRoot "iteration-$IterationLabel"
$tracesDir = Join-Path $iterDir "traces"
New-Item -ItemType Directory -Path $tracesDir -Force | Out-Null

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Harness-Recon Deploy Pipeline  |  Iteration $IterationLabel" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$deployLog = @()
function Log { param([string]$msg) $script:deployLog += $msg; Write-Host $msg }

# ── Steps 1–3: Build + push images via az acr build (WSL2 — no local Docker daemon) ──────────
# az acr build sends the source context to ACR and builds in the cloud.
# This avoids the local Docker daemon requirement and the Alpine→Ubuntu layer
# export bug that caused "failed to get layer sha256:...: layer does not exist"
# in the multi-stage Payment Dockerfile when using docker build + docker push.

function Build-Image {
    param([string]$ContextPath, [string]$Tag, [string]$Name)
    # Tag format: registry.azurecr.io/repo:tag → extract repo:tag for --image
    $imageRef = $Tag -replace "^$([regex]::Escape($AcrRegistry))/", ""
    if (-not (Test-Path $ContextPath)) {
        Write-Warning "  [!] Context path not found: $ContextPath"
        return $false
    }
    Log "  [→] Building $Name image via ACR cloud build (az acr build)..."
    $buildLog = Join-Path $tracesDir "acr-build-$($Name.ToLower()).log"
    $output = & az acr build `
        --registry $AcrName `
        --image "$imageRef" `
        $ContextPath 2>&1
    $output | Set-Content $buildLog
    if ($LASTEXITCODE -ne 0) {
        Log "  [✗] ACR build FAILED for $Name — see $buildLog"
        $output | Select-Object -Last 20 | ForEach-Object { Log "      $_" }
        return $false
    }
    Log "  [✓] $Name image built and pushed to ACR successfully"
    return $true
}

if (-not $SkipBuild) {
    if (-not $SkipRecon) {
        $ok = Build-Image -ContextPath $ReconRoot -Tag $ReconImage -Name "Recon"
        if (-not $ok) { Write-Error "Reconciliation image build failed." }
    }
    if (-not $SkipPayment) {
        $ok = Build-Image -ContextPath $PaymentRoot -Tag $PaymentImage -Name "Payment"
        if (-not $ok) { Write-Error "Payment image build failed." }
    }
} else {
    Log "  [─] Build skipped (-SkipBuild)"
}

# az acr build pushes automatically — no separate push step needed.
if (-not $SkipPush) {
    Log "  [─] Push step skipped — az acr build already pushes to registry"
} else {
    Log "  [─] Push skipped (-SkipPush)"
}

# ── Step 4 & 5: Delete and recreate ACI containers ──────────────────────────

function Redeploy-ACI {
    param(
        [string]$ContainerName,
        [string]$Image,
        [string]$DnsLabel
    )
    Log "  [→] Deleting ACI container: $ContainerName..."
    $out = & az container delete --resource-group $ResourceGroup --name $ContainerName --yes 2>&1
    # Ignore "not found" errors — container may not exist yet
    if ($LASTEXITCODE -ne 0 -and $out -notmatch "not found|ResourceNotFound") {
        Write-Warning "  [!] Delete returned non-zero but may be safe to ignore: $out"
    }
    Log "  [✓] ACI container deleted (or did not exist): $ContainerName"

    # Use a scoped ACR token for ACI registry auth.
    # Admin credentials cause InaccessibleImage on new container creation in West US
    # (known issue: renewed admin creds take days to propagate to ACI pull service).
    # Scoped tokens (az acr token create --scope-map _repositories_pull) work immediately.
    $acrTokenName = "aci-pull-token"
    $acrTokenPwd  = & az acr token credential generate `
        --name $acrTokenName `
        --registry $AcrName `
        --expiration-in-days 7 `
        --query "passwords[0].value" -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Fallback: create the token if it doesn't exist yet
        Log "  [!] Token not found — creating aci-pull-token..."
        $tokenInfo = & az acr token create `
            --name $acrTokenName `
            --registry $AcrName `
            --scope-map _repositories_pull `
            --query "credentials.passwords[0].value" -o tsv 2>&1
        $acrTokenPwd = $tokenInfo
    }
    if (-not $acrTokenPwd) { Write-Error "  [✗] Could not obtain ACR token for ACI create." }

    Log "  [→] Creating ACI container: $ContainerName..."
    $createArgs = @(
        "container", "create",
        "--resource-group", $ResourceGroup,
        "--name", $ContainerName,
        "--image", $Image,
        "--registry-login-server", $AcrRegistry,
        "--registry-username", $acrTokenName,
        "--registry-password", $acrTokenPwd,
        "--dns-name-label", $DnsLabel,
        "--ports", "8080",
        "--os-type", "Linux",
        "--cpu", "2",
        "--memory", "4",
        "--environment-variables",
            "MSSQL_SA_PASSWORD=$SaPassword",
            "SA_PASSWORD=$SaPassword",
        "--location", $Location
    )

    $output = & az @createArgs 2>&1
    $aciLog = Join-Path $tracesDir "aci-create-$($ContainerName).log"
    $output | Set-Content $aciLog

    if ($LASTEXITCODE -ne 0) {
        Log "  [✗] ACI create FAILED for $ContainerName — see $aciLog"
        $output | Select-Object -Last 15 | ForEach-Object { Log "      $_" }
        return $false
    }
    Log "  [✓] ACI container created: $ContainerName"
    return $true
}

if (-not $SkipDeploy) {
    if (-not $SkipRecon) {
        $ok = Redeploy-ACI -ContainerName $ReconAci -Image $ReconImage -DnsLabel $ReconAci
        if (-not $ok) { Write-Error "Reconciliation ACI deployment failed." }
    }
    if (-not $SkipPayment) {
        $ok = Redeploy-ACI -ContainerName $PaymentAci -Image $PaymentImage -DnsLabel $PaymentAci
        if (-not $ok) { Write-Error "Payment ACI deployment failed." }
    }
} else {
    Log "  [─] ACI deploy skipped (-SkipDeploy)"
}

# ── Step 6: Poll until containers are healthy ────────────────────────────────

function Wait-ContainerReady {
    param([string]$Url, [string]$Name, [int]$TimeoutSeconds)
    Log "  [→] Waiting for $Name to become healthy ($Url)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempt  = 0
    $interval = 15

    while ((Get-Date) -lt $deadline) {
        $attempt++
        try {
            $response = Invoke-WebRequest -Uri $Url -TimeoutSec 10 -UseBasicParsing -ErrorAction SilentlyContinue
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                Log "  [✓] $Name is healthy (attempt $attempt, HTTP $($response.StatusCode))"
                return $true
            }
            Log "  [~] $Name returned HTTP $($response.StatusCode) — retrying in ${interval}s..."
        } catch {
            $msg = $_.Exception.Message -replace "`n", " "
            Log "  [~] $Name not ready yet (attempt $attempt): $msg"
        }
        Start-Sleep -Seconds $interval
    }

    Log "  [✗] $Name did not become healthy within ${TimeoutSeconds}s"
    return $false
}

if (-not $SkipDeploy -or -not $SkipE2e) {
    # Always poll if we deployed; also poll if running e2e against existing containers
    $reconReady  = $true
    $paymentReady = $true

    if (-not $SkipRecon) {
        $reconReady = Wait-ContainerReady -Url "$ReconUrl/" -Name "Recon" -TimeoutSeconds $PollTimeoutSeconds
    }
    if (-not $SkipPayment) {
        $paymentReady = Wait-ContainerReady -Url "$PaymentUrl/" -Name "Payment" -TimeoutSeconds $PollTimeoutSeconds
    }

    if (-not $reconReady -or -not $paymentReady) {
        # Capture container logs before failing
        if (-not $SkipRecon -and -not $reconReady) {
            Log "  [→] Fetching Recon container logs..."
            $logs = & az container logs --resource-group $ResourceGroup --name $ReconAci 2>&1
            $logs | Set-Content (Join-Path $tracesDir "aci-logs-recon.log")
        }
        if (-not $SkipPayment -and -not $paymentReady) {
            Log "  [→] Fetching Payment container logs..."
            $logs = & az container logs --resource-group $ResourceGroup --name $PaymentAci 2>&1
            $logs | Set-Content (Join-Path $tracesDir "aci-logs-payment.log")
        }
        Write-Error "One or more containers did not become healthy. Check traces/ for ACI logs."
    }
}

# ── Step 7: Run e2e tests ────────────────────────────────────────────────────

$e2eResults = $null

if (-not $SkipE2e) {
    Log ""
    Log "  [→] Running Playwright e2e suites..."
    Log ""

    $runE2eScript = Join-Path $ScriptDir "run-e2e.ps1"

    $e2eArgs = @(
        "-ReconUrl",   $ReconUrl,
        "-PaymentUrl", $PaymentUrl,
        "-OutputDir",  $tracesDir
    )
    if ($SkipRecon)   { $e2eArgs += "-SkipRecon" }
    if ($SkipPayment) { $e2eArgs += "-SkipPayment" }

    $e2eResults = & pwsh $runE2eScript @e2eArgs

    Log ""
    Log "  [✓] E2E suites complete"
} else {
    Log "  [─] E2E skipped (-SkipE2e)"
}

# ── Step 8: Write deploy summary ─────────────────────────────────────────────

$deploySummary = @{
    iteration     = $IterationLabel
    timestamp     = (Get-Date -Format "o")
    reconUrl      = $ReconUrl
    paymentUrl    = $PaymentUrl
    reconImage    = if ($SkipRecon) { "skipped" } else { $ReconImage }
    paymentImage  = if ($SkipPayment) { "skipped" } else { $PaymentImage }
    buildSkipped  = $SkipBuild.IsPresent
    pushSkipped   = $SkipPush.IsPresent
    deploySkipped = $SkipDeploy.IsPresent
    e2eSkipped    = $SkipE2e.IsPresent
    e2eResults    = $e2eResults
}

$deploySummary | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $iterDir "deploy.json")
$deployLog | Set-Content (Join-Path $tracesDir "deploy.log")

# ── Merge e2e results into scores.json if it exists ─────────────────────────

$scoresPath = Join-Path $iterDir "scores.json"
if ((Test-Path $scoresPath) -and $e2eResults -ne $null) {
    $scores = Get-Content $scoresPath -Raw | ConvertFrom-Json

    # Add e2e metrics to the scores object
    $scores.metrics | Add-Member -NotePropertyName "reconE2eTests" -NotePropertyValue ([PSCustomObject]@{
        passed   = $e2eResults.recon.passed
        failed   = $e2eResults.recon.failed
        total    = $e2eResults.recon.total
        passRate = $e2eResults.recon.passRate
    }) -Force

    $scores.metrics | Add-Member -NotePropertyName "paymentE2eTests" -NotePropertyValue ([PSCustomObject]@{
        passed   = $e2eResults.payment.passed
        failed   = $e2eResults.payment.failed
        total    = $e2eResults.payment.total
        passRate = $e2eResults.payment.passRate
    }) -Force

    $scores | ConvertTo-Json -Depth 8 | Set-Content $scoresPath
    Log "  [✓] scores.json updated with e2e results"
}

# ── Final summary ─────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Deploy Pipeline Complete: Iteration $IterationLabel" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
if (-not $SkipRecon)   { Write-Host "  Recon:   $ReconUrl" -ForegroundColor Green }
if (-not $SkipPayment) { Write-Host "  Payment: $PaymentUrl" -ForegroundColor Green }
if ($e2eResults) {
    Write-Host ""
    Write-Host "  Recon E2E:   $($e2eResults.recon.passed)/$($e2eResults.recon.total) passed" `
        -ForegroundColor $(if ($e2eResults.recon.failed -eq 0) { "Green" } else { "Yellow" })
    Write-Host "  Payment E2E: $($e2eResults.payment.passed)/$($e2eResults.payment.total) passed" `
        -ForegroundColor $(if ($e2eResults.payment.failed -eq 0) { "Green" } else { "Yellow" })
}
Write-Host ""
Write-Host "  Artifacts in: Population/iteration-$IterationLabel/" -ForegroundColor Cyan
Write-Host ""
