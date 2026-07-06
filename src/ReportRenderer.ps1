<#
.SYNOPSIS
    Report rendering module for KBU Deployment Validator.

.DESCRIPTION
    Generates professional HTML and JSON validation reports with KBU
    branding, deployment score, status, missing software, security status,
    driver status, required actions, and a validation summary.

.NOTES
    Does not call exit. Returns file paths of generated reports.
#>

$Script:StatusPass    = "PASS"
$Script:StatusWarning = "WARNING"
$Script:StatusFail    = "FAIL"
$Script:StatusUnknown = "UNKNOWN"

function New-KBUJsonReport {
    <#
    .SYNOPSIS
        Generate a JSON validation report.

    .DESCRIPTION
        Creates a structured JSON file containing all validation results,
        score data, and system information.

    .PARAMETER AllChecks
        Array of all validation check objects.

    .PARAMETER ScoreCard
        Score result object from Get-KBUScore.

    .PARAMETER Fixes
        Fixes object from Get-KBUFixes.

    .PARAMETER SoftwareResults
        Software validation results from Test-KBUSoftware.

    .PARAMETER SystemResults
        System validation results from Test-KBUSystem.

    .PARAMETER SecurityResults
        Security validation results from Test-KBUSecurity.

    .PARAMETER DriverResults
        Driver validation results from Test-KBUDrivers.

    .PARAMETER Config
        Configuration object.

    .PARAMETER OutputDir
        Directory where the JSON file will be saved.

    .PARAMETER ElapsedSeconds
        Total validation duration in seconds.

    .EXAMPLE
        $jsonPath = New-KBUJsonReport -AllChecks $checks -ScoreCard $score `
            -Fixes $fixes -Config $config -OutputDir "reports"
    #>
    param(
        [object[]]$AllChecks,
        [PSCustomObject]$ScoreCard,
        [PSCustomObject]$Fixes,
        [PSCustomObject]$SoftwareResults,
        [PSCustomObject]$SystemResults,
        [PSCustomObject]$SecurityResults,
        [PSCustomObject]$DriverResults,
        [PSCustomObject]$Config,
        [string]$OutputDir,
        [double]$ElapsedSeconds
    )

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction Stop | Out-Null
    }

    $report = [PSCustomObject]@{
        ReportId     = (Get-Date -Format "yyyyMMdd-HHmmss")
        Tool         = $Config.Tool.Name
        Version      = $Config.Tool.Version
        Organization = $Config.Branding.Organization
        GeneratedAt  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        ComputerName = $env:COMPUTERNAME
        DurationSec  = [math]::Round($ElapsedSeconds, 1)

        Score = [PSCustomObject]@{
            Value    = $ScoreCard.Score
            Max      = $ScoreCard.MaxScore
            Decision = $ScoreCard.Decision
            Passes   = $ScoreCard.PassCount
            Warnings = $ScoreCard.WarnCount
            Failures = $ScoreCard.FailCount
            Unknown  = $ScoreCard.UnknownCount
            Total    = $ScoreCard.Total
        }

        BlockingIssues = @($ScoreCard.BlockingIssues)

        Checks = @($AllChecks | ForEach-Object {
            [PSCustomObject]@{
                Name     = $_.Name
                Status   = $_.Status
                Detail   = $_.Detail
                Fix      = $_.Fix
                Severity = $_.Severity
                Category = $_.Category
            }
        })

        Actions = [PSCustomObject]@{
            Critical        = @($Fixes.Critical | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Fix = $_.Fix } })
            Warnings        = @($Fixes.Warnings | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Fix = $_.Fix } })
            Recommendations = @($Fixes.Recommendations | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Fix = $_.Fix } })
        }

        SystemInfo = [PSCustomObject]@{
            Hostname   = $SystemResults.SystemInfo.Hostname
            OS         = $SystemResults.SystemInfo.OS.Edition
            OSVersion  = $SystemResults.SystemInfo.OS.Version
            Build      = $SystemResults.SystemInfo.OS.Build
            Arch       = $SystemResults.SystemInfo.OS.Arch
            Activated  = $SystemResults.SystemInfo.OS.Activated
            LastBoot   = $SystemResults.SystemInfo.OS.LastBoot
            Disks      = @($SystemResults.SystemInfo.Disks | ForEach-Object {
                [PSCustomObject]@{ Drive = $_.Drive; TotalGB = $_.TotalGB; FreeGB = $_.FreeGB; PctFree = $_.PctFree }
            })
        }

        Software = [PSCustomObject]@{
            Required = @($SoftwareResults.Required | ForEach-Object {
                [PSCustomObject]@{ Name = $_.Name; Installed = $_.Installed; Version = $_.Version }
            })
            Optional = @($SoftwareResults.Optional | ForEach-Object {
                [PSCustomObject]@{ Name = $_.Name; Installed = $_.Installed; Version = $_.Version }
            })
        }

        Security = [PSCustomObject]@{
            Antivirus  = ($AllChecks | Where-Object { $_.Name -eq "Antivirus" } | Select-Object -First 1).Status
            Firewall   = ($AllChecks | Where-Object { $_.Name -eq "Firewall" } | Select-Object -First 1).Status
            BitLocker  = ($AllChecks | Where-Object { $_.Name -eq "BitLocker" } | Select-Object -First 1).Status
            SecureBoot = ($AllChecks | Where-Object { $_.Name -eq "Secure Boot" } | Select-Object -First 1).Status
            TPM        = ($AllChecks | Where-Object { $_.Name -eq "TPM" } | Select-Object -First 1).Status
        }

        Drivers = [PSCustomObject]@{
            HasProblems    = $DriverResults.HasProblems
            UnknownDevices = $DriverResults.DeviceData.Unknown.Count
            DisabledDevices = $DriverResults.DeviceData.Disabled.Count
            OtherErrors    = $DriverResults.DeviceData.Other.Count
        }
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $jsonPath  = Join-Path $OutputDir "KBU_Validation_$timestamp.json"

    $report | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $jsonPath -Encoding UTF8 -Force
    Write-KBUInfo "JSON report saved: $jsonPath"

    return $jsonPath
}

function New-KBUHtmlReport {
    <#
    .SYNOPSIS
        Generate a professional HTML validation report.

    .DESCRIPTION
        Creates a dark-themed HTML dashboard with deployment score,
        all check results grouped by category, disk space bars, required
        actions, and deployment decision.

    .PARAMETER AllChecks
        Array of all validation check objects.

    .PARAMETER ScoreCard
        Score result object from Get-KBUScore.

    .PARAMETER Fixes
        Fixes object from Get-KBUFixes.

    .PARAMETER SystemResults
        System validation results from Test-KBUSystem.

    .PARAMETER SoftwareResults
        Software validation results from Test-KBUSoftware.

    .PARAMETER DriverResults
        Driver validation results from Test-KBUDrivers.

    .PARAMETER Config
        Configuration object.

    .PARAMETER OutputDir
        Directory where the HTML file will be saved.

    .PARAMETER ElapsedSeconds
        Total validation duration in seconds.

    .EXAMPLE
        $htmlPath = New-KBUHtmlReport -AllChecks $checks -ScoreCard $score `
            -Fixes $fixes -Config $config -OutputDir "reports"
    #>
    param(
        [object[]]$AllChecks,
        [PSCustomObject]$ScoreCard,
        [PSCustomObject]$Fixes,
        [PSCustomObject]$SystemResults,
        [PSCustomObject]$SoftwareResults,
        [PSCustomObject]$DriverResults,
        [PSCustomObject]$Config,
        [string]$OutputDir,
        [double]$ElapsedSeconds
    )

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction Stop | Out-Null
    }

    $score        = $ScoreCard.Score
    $swOk         = $SoftwareResults.RequiredCount
    $swTotal      = $SoftwareResults.RequiredTotal
    $elapsed      = [math]::Round($ElapsedSeconds, 1)
    $reportId     = Get-Date -Format "yyyyMMdd-HHmmss"
    $genTime      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $computerName = $env:COMPUTERNAME
    $org          = $Config.Branding.Organization
    $dept         = $Config.Branding.Department
    $logoText     = $Config.Branding.LogoText
    $appVersion   = $Config.Tool.Version
    $appName      = $Config.Tool.Name

    if ($ScoreCard.Decision -eq $Script:DecisionReady) {
        $rdColor = "#22c55e"; $rdBgColor = "#22c55e"
    }
    elseif ($ScoreCard.Decision -eq $Script:DecisionWarning) {
        $rdColor = "#f59e0b"; $rdBgColor = "#f59e0b"
    }
    else {
        $rdColor = "#ef4444"; $rdBgColor = "#ef4444"
    }

    function BuildRows($Checks) {
        $r = ""
        foreach ($c in $Checks) {
            $color = if ($c.Status -eq $Script:StatusPass) { "#22c55e" }
                     elseif ($c.Status -eq $Script:StatusWarning) { "#f59e0b" }
                     elseif ($c.Status -eq $Script:StatusUnknown) { "#94a3b8" }
                     else { "#ef4444" }
            $icon  = if ($c.Status -eq $Script:StatusPass) { "&#x2714;" }
                     elseif ($c.Status -eq $Script:StatusWarning) { "&#x26A0;" }
                     elseif ($c.Status -eq $Script:StatusUnknown) { "&#x2753;" }
                     else { "&#x2718;" }
            $r += "<div style='display:flex;align-items:center;justify-content:space-between;padding:5px 0;border-bottom:1px solid rgba(255,255,255,.04);'>"
            $r += "<span style='font-size:.82rem;color:#e2e8f0;'>$($c.Name)</span>"
            $r += "<span style='display:flex;align-items:center;gap:10px;'>"
            $r += "<span style='font-size:.72rem;color:#94a3b8;'>$($c.Detail)</span>"
            $r += "<span style='font-weight:600;font-size:.7rem;color:$color;'>$icon $($c.Status)</span>"
            $r += "</span></div>"
        }
        return $r
    }

    $osChk  = @($AllChecks | Where-Object { $_.Category -eq "System" -and $_.Name -notlike "*(*" })
    $swChk  = @($AllChecks | Where-Object { $_.Category -eq "Software" })
    $drvChk = @($AllChecks | Where-Object { $_.Category -eq "Drivers" })
    $secChk = @($AllChecks | Where-Object { $_.Category -eq "Security" })
    $dskChk = @($AllChecks | Where-Object { $_.Category -eq "System" -and $_.Name -like "*(*" })

    $drvDetail = ""
    if ($DriverResults.HasProblems) {
        $allProb = @($DriverResults.DeviceData.Unknown) + @($DriverResults.DeviceData.Disabled) + @($DriverResults.DeviceData.Other)
        if ($allProb.Count -gt 0) {
            $drvDetail += "<div style='margin-top:8px;font-size:.7rem;color:#94a3b8;max-height:150px;overflow-y:auto;'>"
            foreach ($d in $allProb | Select-Object -First 20) {
                $lbl = if ($d.Code -eq 1) { "Unknown" } elseif ($d.Code -eq 22) { "Disabled" } elseif ($d.Code -eq 28) { "No Driver" } else { "Code $($d.Code)" }
                $sevColor = if ($d.Severity -eq "High") { "#ef4444" } elseif ($d.Severity -eq "Medium") { "#f59e0b" } else { "#64748b" }
                $drvDetail += "<div style='padding:2px 0;'>$($d.Name) &mdash; <span style='color:#ef4444;'>$lbl</span> <span style='color:$sevColor;font-size:.65rem;'>[$($d.Severity)]</span></div>"
            }
            if ($allProb.Count -gt 20) {
                $drvDetail += "<div style='padding:2px 0;color:#64748b;'>... and $($allProb.Count - 20) more</div>"
            }
            $drvDetail += "</div>"
        }
    }

    $diskCards = ""
    $disks = $SystemResults.SystemInfo.Disks
    foreach ($d in $disks) {
        if ($d.PctFree -ge 20)           { $bc = "#22c55e" }
        elseif ($d.PctFree -ge 10)        { $bc = "#f59e0b" }
        else                              { $bc = "#ef4444" }
        $diskCards += "<div style='background:#1e293b;border:1px solid #334155;border-radius:8px;padding:12px 16px;'>"
        $diskCards += "<div style='display:flex;justify-content:space-between;margin-bottom:6px;'>"
        $diskCards += "<span style='font-weight:600;font-size:.82rem;color:#e2e8f0;'>$($d.Drive) &mdash; $($d.Label)</span>"
        $diskCards += "<span style='font-size:.75rem;color:#94a3b8;'>$($d.FreeGB) GB free</span></div>"
        $diskCards += "<div style='height:6px;background:#334155;border-radius:3px;'><div style='height:100%;width:$($d.PctFree)%;background:$bc;border-radius:3px;'></div></div>"
        $diskCards += "<div style='text-align:right;font-size:.68rem;color:#64748b;margin-top:4px;'>$($d.TotalGB) GB total</div></div>"
    }

    $fixHtml = ""
    if ($Fixes.Total -gt 0) {
        $fixHtml += "<div style='display:flex;flex-direction:column;gap:8px;'>"
        if ($Fixes.Critical.Count -gt 0) {
            $fixHtml += "<div style='font-size:.75rem;font-weight:600;color:#ef4444;margin-bottom:2px;'>CRITICAL ACTIONS</div>"
            foreach ($f in $Fixes.Critical) {
                $fixHtml += "<div style='padding:10px 14px;background:#1e293b;border-left:3px solid #ef4444;border-radius:0 6px 6px 0;font-size:.8rem;color:#e2e8f0;'>$($f.Fix)</div>"
            }
        }
        if ($Fixes.Warnings.Count -gt 0) {
            $fixHtml += "<div style='font-size:.75rem;font-weight:600;color:#f59e0b;margin-bottom:2px;margin-top:6px;'>WARNINGS</div>"
            foreach ($f in $Fixes.Warnings) {
                $fixHtml += "<div style='padding:10px 14px;background:#1e293b;border-left:3px solid #f59e0b;border-radius:0 6px 6px 0;font-size:.8rem;color:#e2e8f0;'>$($f.Fix)</div>"
            }
        }
        if ($Fixes.Recommendations.Count -gt 0) {
            $fixHtml += "<div style='font-size:.75rem;font-weight:600;color:#94a3b8;margin-bottom:2px;margin-top:6px;'>RECOMMENDATIONS</div>"
            foreach ($f in $Fixes.Recommendations) {
                $fixHtml += "<div style='padding:10px 14px;background:#1e293b;border-left:3px solid #64748b;border-radius:0 6px 6px 0;font-size:.8rem;color:#e2e8f0;'>$($f.Fix)</div>"
            }
        }
        $fixHtml += "</div>"
    }

    $blockingHtml = ""
    if ($ScoreCard.BlockingIssues.Count -gt 0) {
        $blockingHtml += "<div style='margin-top:6px;'>"
        $blockingHtml += "<div style='font-size:.68rem;color:#ef4444;font-weight:600;margin-bottom:4px;'>BLOCKING ISSUES</div>"
        foreach ($bi in $ScoreCard.BlockingIssues) {
            $blockingHtml += "<div style='font-size:.7rem;color:#ef4444;padding:2px 0;'>&#x2022; $bi</div>"
        }
        $blockingHtml += "</div>"
    }

    $moduleStatus = Get-KBUModuleStatus -AllChecks $AllChecks
    $depSummary = ""
    foreach ($mod in $moduleStatus) {
        $st = $mod.Status
        $sc = if ($st -eq $Script:StatusPass) { "#22c55e" } elseif ($st -eq $Script:StatusWarning) { "#f59e0b" } elseif ($st -eq $Script:StatusUnknown) { "#94a3b8" } else { "#ef4444" }
        $ic = if ($st -eq $Script:StatusPass) { "&#x2714;" } elseif ($st -eq $Script:StatusWarning) { "&#x26A0;" } elseif ($st -eq $Script:StatusUnknown) { "&#x2753;" } else { "&#x2718;" }
        $depSummary += "<div style='display:flex;align-items:center;justify-content:space-between;padding:6px 0;border-bottom:1px solid rgba(255,255,255,.04);'>"
        $depSummary += "<span style='font-size:.82rem;color:#e2e8f0;'>$($mod.Module)</span>"
        $depSummary += "<span style='font-size:.72rem;color:#94a3b8;'>$($mod.PassCount)/$($mod.TotalChecks)</span>"
        $depSummary += "<span style='font-weight:600;font-size:.75rem;color:$sc;'>$ic $st</span>"
        $depSummary += "</div>"
    }
    $depSummary += "<div style='display:flex;align-items:center;justify-content:space-between;padding:8px 0;margin-top:4px;border-top:2px solid #334155;'>"
    $depSummary += "<span style='font-size:.88rem;font-weight:700;color:#e2e8f0;'>Deployment</span>"
    $depSummary += "<span style='font-weight:700;font-size:.85rem;color:$rdBgColor;'>$($ScoreCard.Decision)</span>"
    $depSummary += "</div>"

    $validationResultHtml = ""
    if ($ScoreCard.Decision -eq $Script:DecisionNotReady) {
        $blockingReasons = @()
        foreach ($c in $AllChecks) {
            if ($c.Status -eq $Script:StatusFail -and ($c.Severity -eq "High" -or $Config.Scoring.BlockingSoftware -contains $c.Name)) {
                if ($c.Name -in @("Microsoft Office","Java Runtime","Akia","AnyDesk","enVision","Web Browser")) {
                    $blockingReasons += "$($c.Name) is not installed"
                }
                else {
                    $blockingReasons += $c.Detail
                }
            }
        }
        $validationResultHtml += "<div class='mod'>"
        $validationResultHtml += "<div class='mod-hdr'><div class='mod-icon' style='background:rgba(239,68,68,.15);'>&#x26D4;</div>Validation Result</div>"
        $validationResultHtml += "<div class='card'>"
        $validationResultHtml += "<div style='font-size:.85rem;font-weight:700;color:#ef4444;margin-bottom:10px;'>Deployment blocked because:</div>"
        foreach ($reason in ($blockingReasons | Select-Object -Unique)) {
            $validationResultHtml += "<div style='font-size:.78rem;color:#fca5a5;padding:3px 0;'>&#x2022; $reason</div>"
        }
        if ($blockingReasons.Count -eq 0) {
            $validationResultHtml += "<div style='font-size:.78rem;color:#fca5a5;padding:3px 0;'>&#x2022; Critical issues detected</div>"
        }
        $validationResultHtml += "<div style='margin-top:14px;padding-top:10px;border-top:1px solid #334155;'>"
        $validationResultHtml += "<div style='font-size:.85rem;font-weight:700;color:#e2e8f0;margin-bottom:4px;'>Estimated deployment completion:</div>"
        $validationResultHtml += "<div style='font-size:1.1rem;font-weight:700;color:#f59e0b;'>$($ScoreCard.EstMinutes)</div>"
        $validationResultHtml += "</div></div></div>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Deployment Validation &mdash; $computerName</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',-apple-system,BlinkMacSystemFont,sans-serif;background:#0f172a;color:#e2e8f0;line-height:1.5;min-height:100vh}
.hdr{background:#1e293b;border-bottom:1px solid #334155;padding:14px 24px;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:10px}
.hdr-l{display:flex;align-items:center;gap:10px}
.hdr-logo{width:38px;height:38px;border-radius:8px;background:linear-gradient(135deg,#3b82f6,#8b5cf6);display:flex;align-items:center;justify-content:center;font-weight:700;font-size:16px;color:#fff}
.hdr-title{font-size:.95rem;font-weight:600}
.hdr-sub{font-size:.68rem;color:#94a3b8}
.hdr-meta{text-align:right;font-size:.65rem;color:#64748b}
.hdr-meta strong{color:#94a3b8}
.btn{padding:6px 12px;border:1px solid #334155;border-radius:6px;background:#1e293b;color:#e2e8f0;cursor:pointer;font-size:.72rem;font-weight:500;transition:all .15s}
.btn:hover{background:#283548;border-color:#3b82f6}
.btn-p{background:#3b82f6;border-color:#3b82f6;color:#fff}.btn-p:hover{background:#2563eb}
.ctr{max-width:1050px;margin:0 auto;padding:18px 24px}
.hero{display:flex;align-items:center;gap:20px;background:linear-gradient(135deg,#1e293b,#0f172a);border:1px solid #334155;border-radius:12px;padding:20px 24px;margin-bottom:18px;flex-wrap:wrap}
.hero-circle{width:100px;height:100px;border-radius:50%;display:flex;flex-direction:column;align-items:center;justify-content:center;flex-shrink:0}
.hero-circle-val{font-size:2.5rem;font-weight:800;line-height:1}
.hero-circle-lbl{font-size:.6rem;text-transform:uppercase;letter-spacing:.08em;margin-top:2px}
.hero-info{flex:1;min-width:200px}
.hero-rdy{font-size:1.1rem;font-weight:700;margin-bottom:4px}
.hero-sub{font-size:.78rem;color:#94a3b8;margin-bottom:6px}
.hero-stats{display:flex;gap:18px;margin-top:6px;flex-wrap:wrap}
.hero-stat{text-align:center}
.hero-stat-v{font-size:1.2rem;font-weight:700}
.hero-stat-l{font-size:.6rem;color:#94a3b8;text-transform:uppercase;letter-spacing:.05em}
.mod{margin-bottom:14px}
.mod-hdr{display:flex;align-items:center;gap:8px;margin-bottom:8px;font-size:.85rem;font-weight:600;color:#cbd5e1}
.mod-icon{width:26px;height:26px;border-radius:6px;display:flex;align-items:center;justify-content:center;font-size:.8rem}
.card{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:12px 16px}
.card-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:10px}
.ftr{text-align:center;padding:14px;color:#475569;font-size:.65rem;border-top:1px solid #1e293b;margin-top:20px}
@media print{body{background:#fff;color:#000}.card,.hero{background:#fff;border:1px solid #ddd;box-shadow:none}.hdr,.btn,.ftr{display:none}}
@media(max-width:768px){.ctr{padding:10px}.hero{flex-direction:column;text-align:center}.card-grid{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="hdr">
<div class="hdr-l"><div class="hdr-logo">$logoText</div><div><div class="hdr-title">$appName</div><div class="hdr-sub">$org $dept</div></div></div>
<div class="hdr-meta"><div>Report: <strong>$reportId</strong></div><div>Generated: <strong>$genTime</strong></div><div>Workstation: <strong>$computerName</strong></div><div>Duration: <strong>${elapsed}s</strong></div></div>
<div><button class="btn btn-p" onclick="window.print()">&#x1F5A8; Print</button></div>
</div>

<div class="ctr">

<div class="hero">
<div class="hero-circle" style="background:conic-gradient($rdBgColor $($score)%,#334155 0);">
<div class="hero-circle-val" style="color:#ffffff">$score</div>
<div class="hero-circle-lbl">out of $($ScoreCard.MaxScore)</div>
</div>
<div class="hero-info">
<div class="hero-rdy" style="color:$rdBgColor">$($ScoreCard.Decision)</div>
<div class="hero-sub">$swOk of $swTotal required apps installed &middot; $($ScoreCard.Total) checks completed &middot; Est. fix: $($ScoreCard.EstMinutes)</div>
<div class="hero-stats">
<div class="hero-stat"><div class="hero-stat-v" style="color:#22c55e">$($ScoreCard.PassCount)</div><div class="hero-stat-l">Passed</div></div>
<div class="hero-stat"><div class="hero-stat-v" style="color:#f59e0b">$($ScoreCard.WarnCount)</div><div class="hero-stat-l">Warnings</div></div>
<div class="hero-stat"><div class="hero-stat-v" style="color:#ef4444">$($ScoreCard.FailCount)</div><div class="hero-stat-l">Critical</div></div>
</div>
$blockingHtml
</div>
</div>

<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(59,130,246,.15);">&#x1F4BB;</div>Operating System</div>
<div class="card">$(BuildRows $osChk)</div>
</div>

<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(139,92,246,.15);">&#x1F4E6;</div>Software ($swOk/$swTotal required, $($SoftwareResults.Optional.Count) optional)</div>
<div class="card">$(BuildRows $swChk)</div>
</div>

<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(6,182,212,.15);">&#x1F527;</div>Driver Status</div>
<div class="card">$(BuildRows $drvChk)$drvDetail</div>
</div>

<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(239,68,68,.15);">&#x1F6E1;</div>Security</div>
<div class="card">$(BuildRows $secChk)</div>
</div>

<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(249,115,22,.15);">&#x1F4BE;</div>Disk Space</div>
<div class="card-grid">$diskCards</div>
</div>

"@

    if ($fixHtml) {
        $html += @"
<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(245,158,11,.15);">&#x1F4CB;</div>Required Actions ($($Fixes.Total))</div>
<div class="card">$fixHtml</div>
</div>
"@
    }
    else {
        $html += @"
<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(34,197,94,.15);">&#x2714;</div>All Clear</div>
<div class="card" style="text-align:center;padding:20px;"><p style="color:#22c55e;font-size:.9rem;">No issues detected. Workstation is ready for deployment.</p></div>
</div>
"@
    }

    $html += @"

<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(59,130,246,.15);">&#x1F4CA;</div>Deployment Summary</div>
<div class="card">$depSummary</div>
</div>

$validationResultHtml

<div class="ftr">
$appName v$appVersion &middot; $org $dept &middot; Read-Only Tool &middot; Report: $reportId
</div>

</div>
</body>
</html>
"@

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $htmlPath  = Join-Path $OutputDir "KBU_Validation_$timestamp.html"

    $html | Out-File -LiteralPath $htmlPath -Encoding UTF8 -Force
    Write-KBUInfo "HTML report saved: $htmlPath"

    return $htmlPath
}
