<#
.SYNOPSIS
    CLI for querying the Harness-Recon experience store.
    Per Meta-Harness paper (Appendix D): "A short CLI that lists the Pareto frontier,
    shows top-k harnesses, and diffs code and results between pairs of runs can make
    the experience store much easier to use."

.DESCRIPTION
    Commands:
      list-iterations          List all evaluated iterations with key metrics
      show-scores <N>          Show full scores.json for iteration N
      show-traces <N>          Summary of failures for iteration N
      show-contract <N>        Show hypothesis success criteria results (met/missed)
      diff-scores <A> <B>      Compare metrics between iterations A and B
      compare-source <A> <B>   Show which source files changed between iterations
      pareto-frontier          Show all Pareto-optimal iterations
      top-k <k>                Show top k iterations by overall pass rate
      show-hypothesis <N>      Show the hypothesis for iteration N
      show-outcome <N>         Show the outcome for iteration N
      summary                  One-line summary of search progress

.EXAMPLE
    pwsh Scripts/harness-cli.ps1 list-iterations
    pwsh Scripts/harness-cli.ps1 show-scores 3
    pwsh Scripts/harness-cli.ps1 show-traces 3
    pwsh Scripts/harness-cli.ps1 diff-scores 2 3
    pwsh Scripts/harness-cli.ps1 pareto-frontier
    pwsh Scripts/harness-cli.ps1 top-k 5
#>
param(
    [Parameter(Position=0)] [string]$Command = "list-iterations",
    [Parameter(Position=1)] [string]$Arg1 = "",
    [Parameter(Position=2)] [string]$Arg2 = ""
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HarnessRoot = Split-Path -Parent $ScriptDir
$PopulationRoot = Join-Path $HarnessRoot "Population"
$ResultsRoot = Join-Path $HarnessRoot "Results"

function Get-AllScores {
    Get-ChildItem $PopulationRoot -Directory -Filter "iteration-*" -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object {
            $sf = Join-Path $_.FullName "scores.json"
            if (Test-Path $sf) { Get-Content $sf | ConvertFrom-Json }
        }
}

function Format-Rate { param([double]$r) "$([math]::Round($r * 100, 1))%" }
function Format-Delta { param([double]$d) if ($d -ge 0) { "+$([math]::Round($d * 100, 2))pp" } else { "$([math]::Round($d * 100, 2))pp" } }

function Get-IterDir {
    param([string]$N)
    $label = "{0:D3}" -f [int]$N
    $path = Join-Path $PopulationRoot "iteration-$label"
    if (-not (Test-Path $path)) {
        $path = Join-Path $PopulationRoot "iteration-$N"
    }
    return $path
}

# ═══════════════════════════════════════════════════════════════════════════

switch ($Command.ToLower()) {

    "list-iterations" {
        $scores = Get-AllScores
        if (-not $scores) { Write-Host "  No iterations found. Run Initialize-Baseline.ps1 first." -ForegroundColor Yellow; exit 0 }

        Write-Host ""
        Write-Host "  Iter  | Recon% | Handler% | Payment% | Cover% | Pareto | Hypothesis" -ForegroundColor Cyan
        Write-Host "  ------+--------+----------+----------+--------+--------+------------------------------------------" -ForegroundColor Gray
        foreach ($s in $scores) {
            $recon   = Format-Rate $s.metrics.reconUnitTests.passRate
            $handler = Format-Rate $s.metrics.reconHandlerTests.passRate
            $payment = Format-Rate $s.metrics.paymentUnitTests.passRate
            $cov     = Format-Rate $s.metrics.coverage.lineRate
            $pareto  = if ($s.paretoStatus -eq "frontier") { "*" } else { " " }
            $hyp     = if ($s.hypothesis) { $s.hypothesis.Substring(0, [Math]::Min(40, $s.hypothesis.Length)) } else { "" }
            $color   = if ($s.paretoStatus -eq "frontier") { "Green" } else { "Gray" }
            Write-Host ("  {0,-5} | {1,-6} | {2,-8} | {3,-8} | {4,-6} | {5,-6} | {6}" -f `
                $s.iterationLabel.Replace("iteration-",""), $recon, $handler, $payment, $cov, $pareto, $hyp) -ForegroundColor $color
        }
        Write-Host "  (* = Pareto frontier)" -ForegroundColor Gray
        Write-Host ""
    }

    "show-scores" {
        if (-not $Arg1) { Write-Host "Usage: harness-cli.ps1 show-scores <N>" -ForegroundColor Red; exit 1 }
        $dir = Get-IterDir $Arg1
        $sf = Join-Path $dir "scores.json"
        if (-not (Test-Path $sf)) { Write-Host "  Iteration $Arg1 not found." -ForegroundColor Red; exit 1 }
        Get-Content $sf | ConvertFrom-Json | ConvertTo-Json -Depth 6 | Write-Host
    }

    "show-traces" {
        if (-not $Arg1) {
            $latest = Get-ChildItem $PopulationRoot -Directory -Filter "iteration-*" -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if (-not $latest) { Write-Host "  No iterations found." -ForegroundColor Yellow; exit 0 }
            $Arg1 = $latest.Name -replace "iteration-", ""
        }

        $dir = Get-IterDir $Arg1
        $ft = Join-Path $dir "traces/failed-tests.json"

        if (-not (Test-Path $ft)) {
            Write-Host "  No test traces found for iteration $Arg1." -ForegroundColor Yellow
            exit 0
        }

        $failures = Get-Content $ft | ConvertFrom-Json

        $suites = @(
            @{ key = "reconUnit";    label = "Reconciliation Unit" }
            @{ key = "reconHandler"; label = "Reconciliation Handler" }
            @{ key = "paymentUnit";  label = "Payment Unit" }
        )

        foreach ($suite in $suites) {
            $suiteFailures = $failures.($suite.key)
            if (-not $suiteFailures -or @($suiteFailures).Count -eq 0) { continue }
            $items = @($suiteFailures)

            Write-Host ""
            Write-Host "  [$($suite.label)] $($items.Count) failure(s)" -ForegroundColor Yellow
            foreach ($f in $items) {
                Write-Host "    * $($f.testName)" -ForegroundColor White
                $msg = $f.errorMessage
                $shortMsg = if ($msg -and $msg.Length -gt 120) { $msg.Substring(0, 117) + "..." } else { $msg }
                Write-Host "      $shortMsg" -ForegroundColor Red
                Write-Host ""
            }
        }

        $total = ($suites | ForEach-Object { @($failures.($_.key)).Count } | Measure-Object -Sum).Sum
        if ($total -eq 0) { Write-Host "  No failures in iteration $Arg1! (All tests passed)" -ForegroundColor Green }
        Write-Host ""
    }

    "diff-scores" {
        if (-not $Arg1 -or -not $Arg2) { Write-Host "Usage: harness-cli.ps1 diff-scores <A> <B>" -ForegroundColor Red; exit 1 }

        function Load-Scores { param([string]$N)
            $sf = Join-Path (Get-IterDir $N) "scores.json"
            if (Test-Path $sf) { return Get-Content $sf | ConvertFrom-Json }
            return $null
        }

        $a = Load-Scores $Arg1
        $b = Load-Scores $Arg2
        if (-not $a) { Write-Host "  Iteration $Arg1 not found." -ForegroundColor Red; exit 1 }
        if (-not $b) { Write-Host "  Iteration $Arg2 not found." -ForegroundColor Red; exit 1 }

        Write-Host ""
        Write-Host "  Diff: iteration-$Arg1 → iteration-$Arg2" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Metric              | iter-$Arg1  | iter-$Arg2  | Delta" -ForegroundColor Cyan
        Write-Host "  --------------------+-----------+-----------+----------" -ForegroundColor Gray

        $metrics = @(
            @{ label = "Recon unit rate    "; a = $a.metrics.reconUnitTests.passRate;    b = $b.metrics.reconUnitTests.passRate }
            @{ label = "Handler rate       "; a = $a.metrics.reconHandlerTests.passRate; b = $b.metrics.reconHandlerTests.passRate }
            @{ label = "Payment unit rate  "; a = $a.metrics.paymentUnitTests.passRate;  b = $b.metrics.paymentUnitTests.passRate }
            @{ label = "Coverage line      "; a = $a.metrics.coverage.lineRate;          b = $b.metrics.coverage.lineRate }
            @{ label = "Overall use cases  "; a = $a.metrics.useCases.passRate;          b = $b.metrics.useCases.passRate }
        )
        foreach ($m in $metrics) {
            $delta = $m.b - $m.a
            $color = if ($delta -gt 0.001) { "Green" } elseif ($delta -lt -0.001) { "Red" } else { "Gray" }
            Write-Host ("  {0} | {1,-9} | {2,-9} | {3}" -f `
                $m.label, (Format-Rate $m.a), (Format-Rate $m.b), (Format-Delta $delta)) -ForegroundColor $color
        }
        Write-Host ""
        Write-Host "  Pareto: $($a.paretoStatus) → $($b.paretoStatus)" -ForegroundColor Gray
        Write-Host ""
    }

    "compare-source" {
        if (-not $Arg1 -or -not $Arg2) { Write-Host "Usage: harness-cli.ps1 compare-source <A> <B>" -ForegroundColor Red; exit 1 }

        function Load-Snapshot { param([string]$N)
            $sf = Join-Path (Get-IterDir $N) "source-snapshot.json"
            if (Test-Path $sf) { return Get-Content $sf | ConvertFrom-Json }
            return $null
        }

        $snapA = Load-Snapshot $Arg1
        $snapB = Load-Snapshot $Arg2
        if (-not $snapA -or -not $snapB) { Write-Host "  Snapshots not found for both iterations." -ForegroundColor Red; exit 1 }

        $dictA = @{}; foreach ($f in $snapA) { $dictA[$f.path] = $f }
        $dictB = @{}; foreach ($f in $snapB) { $dictB[$f.path] = $f }

        $changed = @()
        foreach ($path in ($dictA.Keys + $dictB.Keys | Sort-Object -Unique)) {
            $fa = $dictA[$path]; $fb = $dictB[$path]
            if ($fa -and $fb) {
                if ($fa.lastModified -ne $fb.lastModified) { $changed += @{ path = $path; status = "modified" } }
            } elseif ($fb) { $changed += @{ path = $path; status = "added" } }
            elseif ($fa) { $changed += @{ path = $path; status = "removed" } }
        }

        Write-Host ""
        Write-Host "  Source changes: iteration-$Arg1 → iteration-$Arg2" -ForegroundColor Cyan
        Write-Host "  ($($changed.Count) file(s) changed)" -ForegroundColor Gray
        Write-Host ""
        foreach ($c in $changed) {
            $color = switch ($c.status) { "added" { "Green" } "removed" { "Red" } default { "Yellow" } }
            Write-Host "  [$($c.status.PadRight(8))] $($c.path)" -ForegroundColor $color
        }
        Write-Host ""
    }

    "pareto-frontier" {
        $frontierFile = Join-Path $ResultsRoot "pareto-frontier.json"
        if (-not (Test-Path $frontierFile)) {
            $all = Get-AllScores
            $frontier = @($all | Where-Object { $_.paretoStatus -eq "frontier" })
        } else {
            $frontier = Get-Content $frontierFile | ConvertFrom-Json
            $frontier = @($frontier)
        }

        if (-not $frontier -or $frontier.Count -eq 0) {
            Write-Host "  No Pareto-frontier iterations found." -ForegroundColor Yellow; exit 0
        }

        Write-Host ""
        Write-Host "  Pareto Frontier ($($frontier.Count) iteration(s))" -ForegroundColor Cyan
        Write-Host ""
        foreach ($s in $frontier) {
            Write-Host "  iteration-$($s.iterationLabel.Replace('iteration-',''))" -ForegroundColor Green
            Write-Host "    Recon Unit:    $(Format-Rate $s.metrics.reconUnitTests.passRate)" -ForegroundColor White
            Write-Host "    Recon Handler: $(Format-Rate $s.metrics.reconHandlerTests.passRate)" -ForegroundColor White
            Write-Host "    Payment Unit:  $(Format-Rate $s.metrics.paymentUnitTests.passRate)" -ForegroundColor White
            Write-Host "    Coverage:      $(Format-Rate $s.metrics.coverage.lineRate)" -ForegroundColor White
            Write-Host "    Hypothesis:    $($s.hypothesis)" -ForegroundColor Gray
            Write-Host ""
        }
    }

    "top-k" {
        $k = if ($Arg1) { [int]$Arg1 } else { 5 }
        $all = Get-AllScores
        if (-not $all) { Write-Host "  No iterations found." -ForegroundColor Yellow; exit 0 }

        $top = @($all) | Sort-Object { $_.metrics.useCases.passRate } -Descending | Select-Object -First $k

        Write-Host ""
        Write-Host "  Top $k by Overall Pass Rate" -ForegroundColor Cyan
        Write-Host ""
        $rank = 1
        foreach ($s in $top) {
            $marker = if ($s.paretoStatus -eq "frontier") { " *" } else { "  " }
            Write-Host "  #$rank$marker iteration-$($s.iterationLabel.Replace('iteration-','')) | Overall: $(Format-Rate $s.metrics.useCases.passRate) | Cover: $(Format-Rate $s.metrics.coverage.lineRate)" -ForegroundColor $(if ($s.paretoStatus -eq "frontier") { "Green" } else { "Gray" })
            Write-Host "       $($s.hypothesis)" -ForegroundColor DarkGray
            $rank++
        }
        Write-Host ""
    }

    "show-hypothesis" {
        if (-not $Arg1) { Write-Host "Usage: harness-cli.ps1 show-hypothesis <N>" -ForegroundColor Red; exit 1 }
        $dir = Get-IterDir $Arg1
        $hf = Join-Path $dir "hypothesis.md"
        if (Test-Path $hf) { Get-Content $hf | Write-Host } else { Write-Host "  No hypothesis found for iteration $Arg1." }
    }

    "show-outcome" {
        if (-not $Arg1) { Write-Host "Usage: harness-cli.ps1 show-outcome <N>" -ForegroundColor Red; exit 1 }
        $dir = Get-IterDir $Arg1
        $of = Join-Path $dir "outcome.md"
        if (Test-Path $of) { Get-Content $of | Write-Host } else { Write-Host "  No outcome found for iteration $Arg1." }
    }

    "show-contract" {
        if (-not $Arg1) {
            $latest = Get-ChildItem $PopulationRoot -Directory -Filter "iteration-*" -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if (-not $latest) { Write-Host "  No iterations found." -ForegroundColor Yellow; exit 0 }
            $Arg1 = $latest.Name -replace "iteration-", ""
        }

        $dir = Get-IterDir $Arg1
        $sf = Join-Path $dir "scores.json"
        if (-not (Test-Path $sf)) { Write-Host "  Iteration $Arg1 not found." -ForegroundColor Red; exit 1 }

        $scores = Get-Content $sf | ConvertFrom-Json

        if (-not $scores.contractResults -or -not $scores.contractResults.criteria) {
            Write-Host ""
            Write-Host "  No success criteria defined for iteration $Arg1." -ForegroundColor Yellow
            Write-Host "  Add a ## Success Criteria section to hypothesis.md with lines like:" -ForegroundColor Gray
            Write-Host "    * | reconUnitPassRate | >= | 0.95" -ForegroundColor Gray
            Write-Host "    * | paymentUnitPassRate | >= | 0.90" -ForegroundColor Gray
            Write-Host ""
            exit 0
        }

        $cr = $scores.contractResults
        Write-Host ""
        Write-Host "  Hypothesis Contract — Iteration $Arg1" -ForegroundColor Cyan
        Write-Host "  $($cr.metCount)/$($cr.totalCriteria) criteria met" -ForegroundColor $(if ($cr.missedCount -eq 0) { "Green" } else { "Yellow" })
        Write-Host ""
        Write-Host "  Module                   | Metric          | Target      | Actual      | Status" -ForegroundColor Cyan
        Write-Host "  ─────────────────────────┼─────────────────┼─────────────┼─────────────┼───────" -ForegroundColor Gray

        foreach ($c in $cr.criteria) {
            $status = if ($c.met) { "PASS" } else { "MISS" }
            $color = if ($c.met) { "Green" } else { "Red" }
            $targetStr = "$($c.operator) $($c.target)"
            $actualStr = if ($null -ne $c.actual) { "$($c.actual)" } else { "N/A" }
            if ($c.error) { $actualStr = "ERR: $($c.error)" }
            Write-Host ("  {0,-25} | {1,-15} | {2,-11} | {3,-11} | {4}" -f `
                $c.carrier, $c.metric, $targetStr, $actualStr, $status) -ForegroundColor $color
        }
        Write-Host ""
    }

    "summary" {
        $all = Get-AllScores
        if (-not $all) { Write-Host "  No iterations yet. Run Initialize-Baseline.ps1 to begin." -ForegroundColor Yellow; exit 0 }
        $all = @($all)
        $best = @($all) | Sort-Object { $_.metrics.useCases.passRate } -Descending | Select-Object -First 1
        $frontier = @($all | Where-Object { $_.paretoStatus -eq "frontier" })

        Write-Host ""
        Write-Host "  Harness-Recon Search Summary" -ForegroundColor Cyan
        Write-Host "  Iterations evaluated: $($all.Count)" -ForegroundColor White
        Write-Host "  Pareto frontier size: $($frontier.Count)" -ForegroundColor White
        Write-Host "  Best overall pass rate: $(Format-Rate $best.metrics.useCases.passRate) (iteration-$($best.iterationLabel.Replace('iteration-','')))" -ForegroundColor Green
        Write-Host "  Best coverage: $(Format-Rate ($all | Sort-Object { $_.metrics.coverage.lineRate } -Descending | Select-Object -First 1).metrics.coverage.lineRate)" -ForegroundColor Green
        Write-Host ""
    }

    default {
        Write-Host "  Unknown command: $Command" -ForegroundColor Red
        Write-Host "  Available: list-iterations, show-scores, show-traces, show-contract, diff-scores, compare-source, pareto-frontier, top-k, show-hypothesis, show-outcome, summary"
        exit 1
    }
}
