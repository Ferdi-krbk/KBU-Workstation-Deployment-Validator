<#
.SYNOPSIS
    Deployment scoring module for KBU Deployment Validator.

.DESCRIPTION
    Calculates a weighted deployment readiness score (0-100) based on
    validation check results. Determines final deployment status
    (READY / WARNING / NOT READY) and generates blocking issues,
    warnings, and recommendations.

.NOTES
    Does not call exit. Returns structured objects.
    Blocking issues always force NOT READY regardless of score.
#>

$Script:StatusPass    = "PASS"
$Script:StatusWarning = "WARNING"
$Script:StatusFail    = "FAIL"
$Script:StatusUnknown = "UNKNOWN"

$Script:DecisionReady   = "READY"
$Script:DecisionWarning = "WARNING"
$Script:DecisionNotReady = "NOT READY"

function Get-KBUScore {
    <#
    .SYNOPSIS
        Calculate the deployment readiness score from validation checks.

    .DESCRIPTION
        Applies configured weights to each check result. Failing checks
        subtract full weight, warnings subtract half weight. Blocking
        issues force NOT READY status.

    .PARAMETER AllChecks
        Array of all validation check objects (combined from all modules).

    .PARAMETER Config
        Validated configuration object with scoring rules.

    .EXAMPLE
        $score = Get-KBUScore -AllChecks $allChecks -Config $config
        $score.Score; $score.Decision; $score.BlockingIssues
    #>
    param(
        [object[]]$AllChecks,
        [PSCustomObject]$Config
    )

    $weights       = $Config.Scoring.Weights
    $blockers      = @($Config.Scoring.BlockingSoftware)
    $warnFactor    = $Config.Scoring.WarnPenaltyFactor
    $passThreshold = $Config.Scoring.PassingThreshold
    $warnThreshold = $Config.Scoring.WarningThreshold
    $maxScore      = $Config.Scoring.MaxScore

    $score        = $maxScore
    $failCount    = 0
    $warnCount    = 0
    $passCount    = 0
    $unknownCount = 0
    $blockingIssues = @()

    foreach ($check in $AllChecks) {
        $weight = 5
        if ($weights.PSObject.Properties[$check.Name]) {
            $weight = $weights.PSObject.Properties[$check.Name].Value
        }
        elseif ($check.Category -eq "Software" -and $check.Severity -eq "High") {
            $weight = $weights.RequiredSoftware
        }
        elseif ($check.Category -eq "Software") {
            $weight = $weights.OptionalSoftware
        }

        switch ($check.Status) {
            $Script:StatusFail {
                $score -= $weight
                $failCount++
                if ($check.Severity -eq "High" -or $blockers -contains $check.Name) {
                    $blockingIssues += $check.Name
                }
            }
            $Script:StatusWarning {
                $score -= [math]::Ceiling($weight * $warnFactor)
                $warnCount++
            }
            $Script:StatusPass {
                $passCount++
            }
            $Script:StatusUnknown {
                $unknownCount++
            }
            default {
                Write-KBUWarning "Unknown check status: $($check.Status) for $($check.Name)"
            }
        }
    }

    if ($score -lt 0)  { $score = 0 }
    if ($score -gt $maxScore) { $score = $maxScore }

    $totalBlockers = $blockingIssues.Count

    if ($totalBlockers -gt 0) {
        $decision = $Script:DecisionNotReady
    }
    elseif ($score -ge $passThreshold) {
        $decision = $Script:DecisionReady
    }
    elseif ($score -ge $warnThreshold) {
        $decision = $Script:DecisionWarning
    }
    else {
        $decision = $Script:DecisionNotReady
    }

    $estMinutes = ($failCount * 3) + ($warnCount * 1)
    if ($estMinutes -le 0) { $estMinutes = 0 }
    if ($estMinutes -gt 60) { $estMinutes = "60+" }

    Write-KBUInfo "Score: $score/$maxScore, Decision: $decision, Blockers: $totalBlockers"

    return [PSCustomObject]@{
        Score          = $score
        MaxScore       = $maxScore
        Decision       = $decision
        FailCount      = $failCount
        WarnCount      = $warnCount
        PassCount      = $passCount
        UnknownCount   = $unknownCount
        Total          = $AllChecks.Count
        BlockingIssues = @($blockingIssues)
        EstMinutes     = if ($estMinutes -is [int]) { "$estMinutes min" } else { "$estMinutes" }
    }
}

function Get-KBUFixes {
    <#
    .SYNOPSIS
        Extract fix actions from validation checks, grouped by severity.

    .DESCRIPTION
        Categorizes fix actions into Critical, Warnings, and Recommendations
        based on check status and severity. Deduplicates identical fixes.

    .PARAMETER AllChecks
        Array of all validation check objects.

    .EXAMPLE
        $fixes = Get-KBUFixes -AllChecks $allChecks
        $fixes.Critical | ForEach-Object { Write-Host $_.Fix }
    #>
    param(
        [object[]]$AllChecks
    )

    $critical        = @()
    $warnings        = @()
    $recommendations = @()
    $seen            = @{}

    foreach ($check in $AllChecks) {
        if (-not $check.Fix -or $seen[$check.Fix]) { continue }
        $seen[$check.Fix] = $true

        if ($check.Status -eq $Script:StatusFail -and $check.Severity -eq "High") {
            $critical += [PSCustomObject]@{ Fix = $check.Fix; Severity = $check.Severity; Name = $check.Name }
        }
        elseif ($check.Status -eq $Script:StatusFail -and $check.Severity -ne "High") {
            $warnings += [PSCustomObject]@{ Fix = $check.Fix; Severity = $check.Severity; Name = $check.Name }
        }
        elseif ($check.Status -eq $Script:StatusWarning) {
            $recommendations += [PSCustomObject]@{ Fix = $check.Fix; Severity = $check.Severity; Name = $check.Name }
        }
    }

    return [PSCustomObject]@{
        Critical        = $critical
        Warnings        = $warnings
        Recommendations = $recommendations
        Total           = $critical.Count + $warnings.Count + $recommendations.Count
    }
}

function Get-KBUModuleStatus {
    <#
    .SYNOPSIS
        Aggregate individual check results into per-module status summaries.

    .DESCRIPTION
        Groups checks by Category and computes overall PASS/WARNING/FAIL
        status for each validation module.

    .PARAMETER AllChecks
        Array of all validation check objects.

    .EXAMPLE
        $moduleStatus = Get-KBUModuleStatus -AllChecks $allChecks
        $moduleStatus | Format-Table Module, Status, TotalChecks, FailCount
    #>
    param(
        [object[]]$AllChecks
    )

    $modules = $AllChecks | Group-Object -Property Category
    $result  = @()

    foreach ($mod in $modules) {
        $fails  = @($mod.Group | Where-Object { $_.Status -eq $Script:StatusFail })
        $warns  = @($mod.Group | Where-Object { $_.Status -eq $Script:StatusWarning })
        $passes = @($mod.Group | Where-Object { $_.Status -eq $Script:StatusPass })

        if ($fails.Count -gt 0) {
            $status = $Script:StatusFail
        }
        elseif ($warns.Count -gt 0) {
            $status = $Script:StatusWarning
        }
        else {
            $status = $Script:StatusPass
        }

        $result += [PSCustomObject]@{
            Module      = $mod.Name
            Status      = $status
            TotalChecks = $mod.Count
            PassCount   = $passes.Count
            WarnCount   = $warns.Count
            FailCount   = $fails.Count
        }
    }

    return $result
}
