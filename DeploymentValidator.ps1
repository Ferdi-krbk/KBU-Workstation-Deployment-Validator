<#
.SYNOPSIS
    KBU Deployment Validator v3.0
    Answers one question: Can this workstation be deployed to the end user?

.DESCRIPTION
    Enterprise deployment validation tool for IT departments.
    Performs targeted checks across 5 modules, calculates a weighted
    deployment score (0-100), and generates a compact HTML dashboard.

    This tool does NOT inventory hardware or list every installed app.
    Use KBU PC Inventory Tool for full system inventory.

.NOTES
    Author:  Karabuk University IT Department
    Version: 3.0.0
    License: MIT
    READ-ONLY - No system modifications are made.
#>
#Requires -Version 5.1

# ============================================================================
# CONFIGURATION
# ============================================================================
$Script:AppName      = "KBU Deployment Validator"
$Script:AppVersion   = "3.0.0"
$Script:ReportId     = [Guid]::NewGuid().ToString("N").Substring(0, 8).ToUpper()
$Script:GenTime      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$Script:ComputerName = $env:COMPUTERNAME
$Script:DesktopPath  = [Environment]::GetFolderPath("Desktop")
$Script:ReportPath   = Join-Path $Script:DesktopPath "KBU_Deployment_Validation.html"
$Script:StartTime    = Get-Date

$PASS    = "PASS"
$WARN    = "WARNING"
$FAIL    = "FAIL"
$UNKNOWN = "UNKNOWN"

# ============================================================================
# SAFE QUERY HELPER
# ============================================================================
function Invoke-SafeQuery {
    param([ScriptBlock]$ScriptBlock, $Default = "Not Available")
    try {
        $result = & $ScriptBlock
        if ($null -eq $result -or $result -eq "") { return $Default }
        return $result
    } catch { return $Default }
}

# ============================================================================
# VALIDATION RESULT FACTORY
# ============================================================================
function New-Check {
    param([string]$Name, [string]$Status, [string]$Detail = "", [string]$Fix = "", [string]$Severity = "")
    return [PSCustomObject]@{
        Name     = $Name
        Status   = $Status
        Detail   = $Detail
        Fix      = $Fix
        Severity = $Severity
    }
}

# ============================================================================
# DATA COLLECTION
# ============================================================================

function Get-OSData {
    $os = Invoke-SafeQuery { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1 }
    [PSCustomObject]@{
        Edition   = Invoke-SafeQuery { $os.Caption }
        Version   = Invoke-SafeQuery { $os.Version }
        Build     = Invoke-SafeQuery { $os.BuildNumber }
        Arch      = Invoke-SafeQuery { $os.OSArchitecture }
        Activated = Invoke-SafeQuery {
            $lic = Get-CimInstance SoftwareLicensingProduct -Filter "Name like 'Windows%' AND PartialProductKey is not null" -ErrorAction SilentlyContinue | Select-Object -First 1
            $lic.LicenseStatus -eq 1
        } -Default $false
        LastBoot  = Invoke-SafeQuery {
            $boot = [Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime)
            "{0}d ago" -f [int]((Get-Date) - $boot).TotalDays
        }
    }
}

function Get-RequiredSoftware {
    $required = @(
        @{ Name = "Microsoft Office"; Patterns = @("Microsoft Office", "Microsoft 365") }
        @{ Name = "Java Runtime";     Patterns = @("Java");                   Exclude = @("Auto Updater", "Update") }
        @{ Name = "Akia";             Patterns = @("Akia") }
        @{ Name = "AnyDesk";          Patterns = @("AnyDesk") }
        @{ Name = "enVision";         Patterns = @("enVision") }
    )

    $installed = @()
    foreach ($rp in @("HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
                      "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*")) {
        $installed += @(Invoke-SafeQuery { Get-ItemProperty $rp 2>$null } -Default @() | Where-Object { $_.DisplayName })
    }
    $installed = $installed | Sort-Object DisplayName -Unique

    foreach ($req in $required) {
        $found = $null
        foreach ($pat in $req.Patterns) {
            $found = $installed | Where-Object { $_.DisplayName -like "*$pat*" } | Select-Object -First 1
            if ($found -and $req.Exclude) {
                foreach ($ex in $req.Exclude) {
                    if ($found.DisplayName -like "*$ex*") { $found = $null; break }
                }
            }
            if ($found) { break }
        }
        [PSCustomObject]@{
            Name      = $req.Name
            Installed = ($found -ne $null)
            Version   = if ($found.DisplayVersion) { $found.DisplayVersion } else { "N/A" }
        }
    }
}

function Get-DriverProblems {
    $problems = Invoke-SafeQuery {
        Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode }
    } -Default @()

    # Classify each problem with severity
    $classify = {
        param($code)
        # Low: Virtual adapters, software devices, non-critical
        # Medium: Unknown devices without driver
        # High: System devices with errors
        if ($code -eq 22) { return "Low" }        # Disabled
        elseif ($code -in @(28)) { return "Medium" } # No driver (missing)
        elseif ($code -in @(1)) { return "High" }    # Not configured (unknown)
        elseif ($code -in @(10,18,19,31)) { return "Medium" } # Start/install errors
        else { return "Medium" }
    }

    [PSCustomObject]@{
        HasProblems = (@($problems).Count -gt 0)
        Unknown     = @($problems | Where-Object { $_.ConfigManagerErrorCode -in @(1,28) } | Select-Object Name, @{N='Code';E={$_.ConfigManagerErrorCode}}, @{N='Severity';E={& $classify $_.ConfigManagerErrorCode}})
        Disabled    = @($problems | Where-Object { $_.ConfigManagerErrorCode -eq 22 } | Select-Object Name, @{N='Code';E={$_.ConfigManagerErrorCode}}, @{N='Severity';E={& $classify $_.ConfigManagerErrorCode}})
        Other       = @($problems | Where-Object { $_.ConfigManagerErrorCode -notin @(1,22,28) } | Select-Object Name, @{N='Code';E={$_.ConfigManagerErrorCode}}, @{N='Severity';E={& $classify $_.ConfigManagerErrorCode}})
    }
}

function Get-SecurityData {
    # Query SecurityCenter2 for active antivirus products (primary method)
    $secCenterAV = Invoke-SafeQuery {
        $avProducts = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop
        $avProducts | Where-Object { $_.displayName -notmatch "Windows Defender|Microsoft Defender" } | Select-Object -First 1
    } -Default $null

    $thirdPartyAVName   = if ($secCenterAV) { $secCenterAV.displayName } else { $null }
    $hasThirdPartyAV    = ($secCenterAV -ne $null)

    $defenderState = Invoke-SafeQuery {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        [PSCustomObject]@{ Enabled = $mp.AntivirusEnabled; RTP = $mp.RealTimeProtectionEnabled }
    } -Default ([PSCustomObject]@{ Enabled = $false; RTP = $false })

    # Secure Boot — only return true/false, null means unknown
    $sbOk = Invoke-SafeQuery {
        try {
            $sb = Confirm-SecureBootUEFI -ErrorAction Stop
            if ($null -eq $sb) { $null } else { $sb }
        } catch { $null }
    } -Default $null

    # TPM — return object with present/ready/null
    $tpmResult = Invoke-SafeQuery {
        try {
            $t = Get-Tpm -ErrorAction Stop
            if ($null -eq $t) { $null }
            else { [PSCustomObject]@{ Present = $t.TpmPresent; Ready = $t.TpmReady } }
        } catch { $null }
    } -Default $null

    [PSCustomObject]@{
        DefenderOn   = $defenderState.Enabled
        ThirdPartyAV = $thirdPartyAVName
        HasAV        = ($defenderState.Enabled -or $hasThirdPartyAV)
        Firewall     = Invoke-SafeQuery { @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled }).Count -eq 0 } -Default $false
        BitLocker    = Invoke-SafeQuery { (Get-BitLockerVolume -ErrorAction Stop | Select-Object -First 1).ProtectionStatus -eq "On" } -Default $false
        SecureBoot   = $sbOk
        TPM          = $tpmResult
    }
}

function Get-DiskData {
    Invoke-SafeQuery {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | ForEach-Object {
            $pct = if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { 0 }
            [PSCustomObject]@{
                Drive   = $_.DeviceID
                Label   = if ($_.VolumeName) { $_.VolumeName } else { "Local Disk" }
                TotalGB = [math]::Round($_.Size/1GB, 1)
                FreeGB  = [math]::Round($_.FreeSpace/1GB, 1)
                PctFree = $pct
            }
        }
    } -Default @()
}

# ============================================================================
# VALIDATION ENGINE
# ============================================================================

function Test-OSValidation {
    param($OS)
    $pro      = $OS.Edition -match "Pro|Enterprise|Education"
    $isHome   = $OS.Edition -match "Home"
    $verOk    = [version]$OS.Version -ge [version]"10.0"
    $bldOk    = [int]$OS.Build -ge 19041
    $archOk   = $OS.Arch -match "64"
    $bootDays = if ($OS.LastBoot -match '(\d+)d') { [int]$Matches[1] } else { 999 }

    @(
        (New-Check "Windows Edition"  $(if($pro){$PASS}else{$WARN})  $OS.Edition                          $(if($isHome){"Pro/Enterprise recommended for enterprise environments."})  "Low"),
        (New-Check "Windows Version"  $(if($verOk){$PASS}else{$FAIL}) "$($OS.Version) (Build $($OS.Build))" $(if(!$verOk){"Upgrade to Windows 10 or 11."})       $(if(!$verOk){"High"})),
        (New-Check "Build Number"     $(if($bldOk){$PASS}else{$WARN}) $OS.Build                            $(if(!$bldOk){"Install latest Windows updates."})                        "Low"),
        (New-Check "Architecture"     $(if($archOk){$PASS}else{$FAIL}) $OS.Arch                            $(if(!$archOk){"64-bit Windows required."})                              $(if(!$archOk){"High"})),
        (New-Check "Activation"       $(if($OS.Activated){$PASS}else{$FAIL}) $(if($OS.Activated){"Licensed"}else{"Not Activated"}) $(if(!$OS.Activated){"Activate Windows with a valid license."}) $(if(!$OS.Activated){"High"})),
        (New-Check "Last Reboot"      $(if($bootDays -le 30){$PASS}else{$WARN}) $OS.LastBoot               $(if($bootDays -gt 30){"Restart to apply pending updates."})             "Low")
    )
}

function Test-SoftwareValidation {
    param($SW)
    $severityMap = @{
        "Microsoft Office" = "High"
        "Java Runtime"     = "High"
        "Akia"             = "Medium"
        "AnyDesk"          = "Medium"
        "enVision"         = "Medium"
    }
    $SW | ForEach-Object {
        $sev = if (!$_.Installed) { $severityMap[$_.Name] } else { "" }
        New-Check $_.Name $(if($_.Installed){$PASS}else{$FAIL}) `
            $(if($_.Installed){"v$($_.Version)"}else{"Not Installed"}) `
            $(if(!$_.Installed){"Install $($_.Name)."}) `
            -Severity $sev
    }
}

function Test-DriverValidation {
    param($Drv)
    @(
        (New-Check "Unknown Devices" `
            $(if(@($Drv.Unknown).Count -eq 0){$PASS}elseif((@($Drv.Unknown) | Where-Object { $_.Severity -eq "High" }).Count -gt 0){$FAIL}else{$WARN}) `
            "$(@($Drv.Unknown).Count) found" `
            $(if(@($Drv.Unknown).Count -gt 0){"Install missing drivers for unknown devices."}) `
            $(if((@($Drv.Unknown) | Where-Object { $_.Severity -eq "High" }).Count -gt 0){"High"}elseif(@($Drv.Unknown).Count -gt 0){"Medium"})),
        (New-Check "Disabled Devices" `
            $(if(@($Drv.Disabled).Count -eq 0){$PASS}else{$WARN}) `
            "$(@($Drv.Disabled).Count) found" `
            $(if(@($Drv.Disabled).Count -gt 0){"Enable disabled devices in Device Manager if needed."}) `
            "Low"),
        (New-Check "Driver Errors" `
            $(if(@($Drv.Other).Count -eq 0){$PASS}elseif((@($Drv.Other) | Where-Object { $_.Severity -eq "High" }).Count -gt 0){$FAIL}else{$WARN}) `
            "$(@($Drv.Other).Count) found" `
            $(if(@($Drv.Other).Count -gt 0){"Resolve Device Manager error codes for affected devices."}) `
            $(if((@($Drv.Other) | Where-Object { $_.Severity -eq "High" }).Count -gt 0){"High"}elseif(@($Drv.Other).Count -gt 0){"Medium"}))
    )
}

function Test-SecurityValidation {
    param($Sec)

    # Antivirus logic
    if ($Sec.ThirdPartyAV) {
        $avCheck = New-Check "Antivirus" $PASS "Third-party Antivirus Detected`nProduct Name: $($Sec.ThirdPartyAV)`nProtected" "" ""
    }
    elseif ($Sec.DefenderOn) {
        $avCheck = New-Check "Antivirus" $PASS "Windows Defender Active" "" ""
    }
    else {
        $avCheck = New-Check "Antivirus" $FAIL "No Antivirus Detected" "Install or enable antivirus protection." "High"
    }

    # Secure Boot logic
    if ($null -eq $Sec.SecureBoot) {
        $sbCheck = New-Check "Secure Boot" $UNKNOWN "Unable to determine" "Check Secure Boot status in UEFI/BIOS." ""
    }
    elseif ($Sec.SecureBoot) {
        $sbCheck = New-Check "Secure Boot" $PASS "Enabled" "" ""
    }
    else {
        $sbCheck = New-Check "Secure Boot" $WARN "Disabled" "Enable Secure Boot in UEFI/BIOS for enhanced security." "Low"
    }

    # TPM logic
    if ($null -eq $Sec.TPM) {
        $tpmCheck = New-Check "TPM" $UNKNOWN "Unable to verify" "Check TPM status in UEFI/BIOS or tpm.msc." ""
    }
    elseif ($Sec.TPM.Ready) {
        $tpmCheck = New-Check "TPM" $PASS "Present and Ready" "" ""
    }
    elseif ($Sec.TPM.Present) {
        $tpmCheck = New-Check "TPM" $WARN "Present, Not Ready" "Initialize TPM in BIOS/UEFI." "Low"
    }
    else {
        $tpmCheck = New-Check "TPM" $UNKNOWN "Not Found" "TPM 2.0 is recommended for Windows 11 and security features." ""
    }

    @(
        $avCheck,
        (New-Check "Windows Firewall" $(if($Sec.Firewall){$PASS}else{$FAIL}) $(if($Sec.Firewall){"All Profiles On"}else{"Disabled"}) $(if(!$Sec.Firewall){"Enable firewall on all network profiles."}) $(if(!$Sec.Firewall){"High"})),
        (New-Check "BitLocker"        $(if($Sec.BitLocker){$PASS}else{$WARN}) $(if($Sec.BitLocker){"Encrypted"}else{"Off"}) $(if(!$Sec.BitLocker){"Enable BitLocker drive encryption."}) "Low"),
        $sbCheck,
        $tpmCheck
    )
}

function Test-DiskValidation {
    param($Disks)
    $Disks | ForEach-Object {
        if ($_.PctFree -lt 5)       { $status = $FAIL; $sev = "High" }
        elseif ($_.PctFree -lt 10)  { $status = $WARN; $sev = "Medium" }
        elseif ($_.PctFree -lt 20)  { $status = $WARN; $sev = "Low" }
        else                        { $status = $PASS; $sev = "" }
        New-Check "$($_.Drive) ($($_.Label))" $status "$($_.FreeGB) GB free ($($_.PctFree)%)" `
            $(if($_.PctFree -lt 10){"Free up disk space on $($_.Drive)."}) $sev
    }
}

# ============================================================================
# WEIGHTED SCORING — designed so healthy systems score 90-100
# ============================================================================
function Get-DeploymentScore {
    param($AllChecks)

    # Weight map: penalty when FAIL. WARN gets half penalty.
    $weights = @{
        "Windows Edition"   = 3      # Home is a recommendation, not critical
        "Windows Version"   = 12
        "Build Number"      = 3
        "Architecture"      = 12
        "Activation"        = 10
        "Last Reboot"       = 2
        "Microsoft Office"  = 10
        "Java Runtime"      = 8
        "Akia"              = 5
        "AnyDesk"           = 5
        "enVision"          = 5
        "Antivirus"         = 10
        "Windows Firewall"  = 8
        "BitLocker"         = 3
        "Secure Boot"       = 3
        "TPM"               = 5
        "Unknown Devices"   = 5
        "Disabled Devices"  = 2
        "Driver Errors"     = 5
    }

    $score = 100
    $failCount = 0
    $warnCount = 0
    $passCount = 0
    $unknownCount = 0
    $blockingIssues = @()

    foreach ($c in $AllChecks) {
        $w = if ($weights[$c.Name]) { $weights[$c.Name] } else { 5 }

        $softwareBlockers = @("Akia", "AnyDesk", "enVision", "Antivirus")
        switch ($c.Status) {
            $FAIL    {
                $score -= $w
                $failCount++
                if ($c.Severity -eq "High" -or $softwareBlockers -contains $c.Name) {
                    $blockingIssues += $c.Name
                }
            }
            $WARN    {
                $score -= [math]::Ceiling($w / 2)
                $warnCount++
            }
            $PASS    { $passCount++ }
            $UNKNOWN { $unknownCount++ }
        }
    }

    if ($score -lt 0) { $score = 0 }
    if ($score -gt 100) { $score = 100 }

    # Deployment decision
    $criticalFails = ($AllChecks | Where-Object { $_.Status -eq $FAIL -and $_.Severity -eq "High" }).Count
    $totalBlockers = $blockingIssues.Count

    if ($score -ge 85 -and $totalBlockers -eq 0) {
        $decision = "READY FOR DEPLOYMENT"
    }
    elseif ($score -ge 65 -and $totalBlockers -le 2) {
        $decision = "NEEDS ATTENTION"
    }
    else {
        $decision = "NOT READY"
    }

    # Estimated fix time (rough heuristic)
    $estMinutes = ($failCount * 3) + ($warnCount * 1)
    if ($estMinutes -le 0) { $estMinutes = 0 }
    if ($estMinutes -gt 60) { $estMinutes = "60+" }

    [PSCustomObject]@{
        Score          = $score
        Decision       = $decision
        FailCount      = $failCount
        WarnCount      = $warnCount
        PassCount      = $passCount
        UnknownCount   = $unknownCount
        Total          = $AllChecks.Count
        BlockingIssues = $blockingIssues
        EstMinutes     = "$estMinutes min"
    }
}

# ============================================================================
# FIXES: Split into Critical / Warning / Recommendation
# ============================================================================
function Get-Fixes {
    param($AllChecks)

    $critical = @()
    $warnings = @()
    $recommendations = @()
    $seen = @{}

    foreach ($c in $AllChecks) {
        if (-not $c.Fix -or $seen[$c.Fix]) { continue }
        $seen[$c.Fix] = $true

        if ($c.Status -eq $FAIL -and $c.Severity -eq "High") {
            $critical += [PSCustomObject]@{ Fix = $c.Fix; Severity = $c.Severity }
        }
        elseif ($c.Status -eq $FAIL -and $c.Severity -ne "High") {
            $warnings += [PSCustomObject]@{ Fix = $c.Fix; Severity = $c.Severity }
        }
        elseif ($c.Status -eq $WARN) {
            $recommendations += [PSCustomObject]@{ Fix = $c.Fix; Severity = $c.Severity }
        }
    }

    [PSCustomObject]@{
        Critical        = $critical
        Warnings        = $warnings
        Recommendations = $recommendations
        Total           = $critical.Count + $warnings.Count + $recommendations.Count
    }
}

# ============================================================================
# HTML REPORT (Compact, Windows Admin Center style)
# ============================================================================
function Build-HtmlReport {
    param($AllChecks, $ScoreCard, $Fixes, $Drivers, $Disks, $Software)

    $score   = $ScoreCard.Score
    $swOk    = ($Software | Where-Object { $_.Installed }).Count
    $swTotal = @($Software).Count
    $elapsed = [math]::Round(((Get-Date) - $Script:StartTime).TotalSeconds, 1)

    # Color logic
    if ($ScoreCard.Decision -eq "READY FOR DEPLOYMENT") {
        $rdColor   = "#22c55e"
        $rdBgColor = "#22c55e"
    }
    elseif ($ScoreCard.Decision -eq "NEEDS ATTENTION") {
        $rdColor   = "#f59e0b"
        $rdBgColor = "#f59e0b"
    }
    else {
        $rdColor   = "#ef4444"
        $rdBgColor = "#ef4444"
    }

    # Build check rows
    function BuildRows($Checks) {
        $r = ""
        foreach ($c in $Checks) {
            $color = if ($c.Status -eq $PASS) { "#22c55e" }
                     elseif ($c.Status -eq $WARN) { "#f59e0b" }
                     elseif ($c.Status -eq $UNKNOWN) { "#94a3b8" }
                     else { "#ef4444" }
            $icon  = if ($c.Status -eq $PASS) { "&#x2714;" }
                     elseif ($c.Status -eq $WARN) { "&#x26A0;" }
                     elseif ($c.Status -eq $UNKNOWN) { "&#x2753;" }
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

    # Driver problem detail with severity
    $drvDetail = ""
    $allProb = @($Drivers.Unknown) + @($Drivers.Disabled) + @($Drivers.Other)
    if ($allProb.Count -gt 0) {
        $drvDetail += "<div style='margin-top:8px;font-size:.7rem;color:#94a3b8;max-height:150px;overflow-y:auto;'>"
        foreach ($d in $allProb) {
            $lbl = if ($d.Code -eq 1) { "Unknown" } elseif ($d.Code -eq 22) { "Disabled" } elseif ($d.Code -eq 28) { "No Driver" } else { "Code $($d.Code)" }
            $sevColor = if ($d.Severity -eq "High") { "#ef4444" } elseif ($d.Severity -eq "Medium") { "#f59e0b" } else { "#64748b" }
            $drvDetail += "<div style='padding:2px 0;'>$($d.Name) &mdash; <span style='color:#ef4444;'>$lbl</span> <span style='color:$sevColor;font-size:.65rem;'>[$($d.Severity)]</span></div>"
        }
        $drvDetail += "</div>"
    }

    # Disk cards
    $diskCards = ""
    foreach ($d in $Disks) {
        if ($d.PctFree -ge 20)       { $bc = "#22c55e" }
        elseif ($d.PctFree -ge 10)   { $bc = "#f59e0b" }
        else                         { $bc = "#ef4444" }
        $diskCards += "<div style='background:#1e293b;border:1px solid #334155;border-radius:8px;padding:12px 16px;'>"
        $diskCards += "<div style='display:flex;justify-content:space-between;margin-bottom:6px;'>"
        $diskCards += "<span style='font-weight:600;font-size:.82rem;color:#e2e8f0;'>$($d.Drive) &mdash; $($d.Label)</span>"
        $diskCards += "<span style='font-size:.75rem;color:#94a3b8;'>$($d.FreeGB) GB free</span></div>"
        $diskCards += "<div style='height:6px;background:#334155;border-radius:3px;'><div style='height:100%;width:$($d.PctFree)%;background:$bc;border-radius:3px;'></div></div>"
        $diskCards += "<div style='text-align:right;font-size:.68rem;color:#64748b;margin-top:4px;'>$($d.TotalGB) GB total</div></div>"
    }

    # Fixes list — split into sections
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

    # Group checks
    $osChk  = $AllChecks | Where-Object { $_.Name -in @("Windows Edition","Windows Version","Build Number","Architecture","Activation","Last Reboot") }
    $swChk  = $AllChecks | Where-Object { $_.Name -in @("Microsoft Office","Java Runtime","Akia","AnyDesk","enVision") }
    $drvChk = $AllChecks | Where-Object { $_.Name -in @("Unknown Devices","Disabled Devices","Driver Errors") }
    $secChk = $AllChecks | Where-Object { $_.Name -in @("Antivirus","Windows Firewall","BitLocker","Secure Boot","TPM") }
    $dskChk = $AllChecks | Where-Object { $_.Name -notin @("Windows Edition","Windows Version","Build Number","Architecture","Activation","Last Reboot","Microsoft Office","Java Runtime","Akia","AnyDesk","enVision","Unknown Devices","Disabled Devices","Driver Errors","Antivirus","Windows Firewall","BitLocker","Secure Boot","TPM") }

    # Deployment summary table
    $depSummary = ""
    $moduleStatus = @{
        "Operating System" = if (($osChk | Where-Object { $_.Status -eq $FAIL }).Count -gt 0) { $FAIL } elseif (($osChk | Where-Object { $_.Status -eq $WARN }).Count -gt 0) { $WARN } else { $PASS }
        "Required Software" = if (($swChk | Where-Object { $_.Status -eq $FAIL }).Count -gt 0) { $FAIL } elseif (($swChk | Where-Object { $_.Status -eq $WARN }).Count -gt 0) { $WARN } else { $PASS }
        "Drivers"          = if (($drvChk | Where-Object { $_.Status -eq $FAIL }).Count -gt 0) { $FAIL } elseif (($drvChk | Where-Object { $_.Status -eq $WARN }).Count -gt 0) { $WARN } else { $PASS }
        "Security"         = if (($secChk | Where-Object { $_.Status -eq $FAIL }).Count -gt 0) { $FAIL } elseif (($secChk | Where-Object { $_.Status -eq $WARN }).Count -gt 0) { $WARN } else { $PASS }
        "Disk Space"       = if (($dskChk | Where-Object { $_.Status -eq $FAIL }).Count -gt 0) { $FAIL } elseif (($dskChk | Where-Object { $_.Status -eq $WARN }).Count -gt 0) { $WARN } else { $PASS }
    }

    foreach ($mod in $moduleStatus.Keys) {
        $st = $moduleStatus[$mod]
        $sc = if ($st -eq $PASS) { "#22c55e" } elseif ($st -eq $WARN) { "#f59e0b" } elseif ($st -eq $UNKNOWN) { "#94a3b8" } else { "#ef4444" }
        $ic = if ($st -eq $PASS) { "&#x2714;" } elseif ($st -eq $WARN) { "&#x26A0;" } elseif ($st -eq $UNKNOWN) { "&#x2753;" } else { "&#x2718;" }
        $depSummary += "<div style='display:flex;align-items:center;justify-content:space-between;padding:6px 0;border-bottom:1px solid rgba(255,255,255,.04);'>"
        $depSummary += "<span style='font-size:.82rem;color:#e2e8f0;'>$mod</span>"
        $depSummary += "<span style='font-weight:600;font-size:.75rem;color:$sc;'>$ic $st</span>"
        $depSummary += "</div>"
    }
    # Final decision row
    $depSummary += "<div style='display:flex;align-items:center;justify-content:space-between;padding:8px 0;margin-top:4px;border-top:2px solid #334155;'>"
    $depSummary += "<span style='font-size:.88rem;font-weight:700;color:#e2e8f0;'>Deployment</span>"
    $depSummary += "<span style='font-weight:700;font-size:.85rem;color:$rdBgColor;'>$($ScoreCard.Decision)</span>"
    $depSummary += "</div>"

    # Validation Result section - shown when deployment is blocked
    $validationResultHtml = ""
    if ($ScoreCard.Decision -eq "NOT READY") {
        $softwareNames = @("Microsoft Office", "Java Runtime", "Akia", "AnyDesk", "enVision")
        $blockingReasons = @()
        foreach ($c in $AllChecks) {
            if ($c.Status -eq $FAIL -and ($c.Severity -eq "High" -or $c.Name -in @("Akia","AnyDesk","enVision","Antivirus"))) {
                if ($c.Name -in $softwareNames) {
                    $blockingReasons += "$($c.Name) is not installed"
                } else {
                    $blockingReasons += $c.Detail
                }
            }
        }
        $validationResultHtml += "<div class='mod'>"
        $validationResultHtml += "<div class='mod-hdr'><div class='mod-icon' style='background:rgba(239,68,68,.15);'>&#x26D4;</div>Validation Result</div>"
        $validationResultHtml += "<div class='card'>"
        $validationResultHtml += "<div style='font-size:.85rem;font-weight:700;color:#ef4444;margin-bottom:10px;'>Deployment blocked because:</div>"
        foreach ($reason in $blockingReasons) {
            $validationResultHtml += "<div style='font-size:.78rem;color:#fca5a5;padding:3px 0;'>&#x2022; $reason</div>"
        }
        if ($blockingReasons.Count -eq 0) {
            $validationResultHtml += "<div style='font-size:.78rem;color:#fca5a5;padding:3px 0;'>&#x2022; Critical issues detected</div>"
        }
        $validationResultHtml += "<div style='margin-top:14px;padding-top:10px;border-top:1px solid #334155;'>"
        $validationResultHtml += "<div style='font-size:.85rem;font-weight:700;color:#e2e8f0;margin-bottom:4px;'>Estimated deployment completion:</div>"
        $validationResultHtml += "<div style='font-size:1.1rem;font-weight:700;color:#f59e0b;'>20 minutes</div>"
        $validationResultHtml += "</div></div></div>"
    }

    # Blocking issues for decision section
    $blockingHtml = ""
    if ($ScoreCard.BlockingIssues.Count -gt 0) {
        $blockingHtml += "<div style='margin-top:6px;'>"
        $blockingHtml += "<div style='font-size:.68rem;color:#ef4444;font-weight:600;margin-bottom:4px;'>BLOCKING ISSUES</div>"
        foreach ($bi in $ScoreCard.BlockingIssues) {
            $blockingHtml += "<div style='font-size:.7rem;color:#ef4444;padding:2px 0;'>&#x2022; $bi</div>"
        }
        $blockingHtml += "</div>"
    }

    $rid = $Script:ReportId
    $gt  = $Script:GenTime
    $cn  = $Script:ComputerName
    $ver = $Script:AppVersion

@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Deployment Validation &mdash; $cn</title>
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
/* Hero */
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
/* Modules */
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
<div class="hdr-l"><div class="hdr-logo">KBU</div><div><div class="hdr-title">Deployment Validator</div><div class="hdr-sub">Karabuk University IT</div></div></div>
<div class="hdr-meta"><div>Report: <strong>$rid</strong></div><div>Generated: <strong>$gt</strong></div><div>Workstation: <strong>$cn</strong></div><div>Duration: <strong>${elapsed}s</strong></div></div>
<div><button class="btn btn-p" onclick="window.print()">&#x1F5A8; Print</button></div>
</div>

<div class="ctr">

<!-- HERO -->
<div class="hero">
<div class="hero-circle" style="background:conic-gradient($rdBgColor $($score)%,#334155 0);">
<div class="hero-circle-val" style="color:#ffffff">$score</div>
<div class="hero-circle-lbl">out of 100</div>
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

<!-- OS -->
<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(59,130,246,.15);">&#x1F4BB;</div>Operating System</div>
<div class="card">$(BuildRows $osChk)</div>
</div>

<!-- REQUIRED SOFTWARE -->
<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(139,92,246,.15);">&#x1F4E6;</div>Required Software ($swOk/$swTotal)</div>
<div class="card">$(BuildRows $swChk)</div>
</div>

<!-- DRIVERS -->
<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(6,182,212,.15);">&#x1F527;</div>Driver Status</div>
<div class="card">$(BuildRows $drvChk)$drvDetail</div>
</div>

<!-- SECURITY -->
<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(239,68,68,.15);">&#x1F6E1;</div>Security</div>
<div class="card">$(BuildRows $secChk)</div>
</div>

<!-- DISK SPACE -->
<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(249,115,22,.15);">&#x1F4BE;</div>Disk Space</div>
<div class="card-grid">$diskCards</div>
</div>

<!-- REQUIRED ACTIONS -->
$(if ($fixHtml) {
"<div class='mod'>
<div class='mod-hdr'><div class='mod-icon' style='background:rgba(245,158,11,.15);'>&#x1F4CB;</div>Required Actions ($($Fixes.Total))</div>
<div class='card'>$fixHtml</div>
</div>"
} else {
"<div class='mod'>
<div class='mod-hdr'><div class='mod-icon' style='background:rgba(34,197,94,.15);'>&#x2714;</div>All Clear</div>
<div class='card' style='text-align:center;padding:20px;'><p style='color:#22c55e;font-size:.9rem;'>No issues detected. Workstation is ready for deployment.</p></div>
</div>"
})

<!-- DEPLOYMENT SUMMARY -->
<div class="mod">
<div class="mod-hdr"><div class="mod-icon" style="background:rgba(59,130,246,.15);">&#x1F4CA;</div>Deployment Summary</div>
<div class="card">$depSummary</div>
</div>

$validationResultHtml

<div class="ftr">
KBU Deployment Validator v$ver &middot; Karabuk University IT &middot; Read-Only Tool &middot; Report: $rid
</div>

</div>
</body>
</html>
"@
}

# ============================================================================
# MAIN
# ============================================================================
function Main {
    Clear-Host

    Write-Host ""
    Write-Host "  KBU Deployment Validator v$($Script:AppVersion)" -ForegroundColor Cyan
    Write-Host "  Karabuk University IT" -ForegroundColor DarkGray
    Write-Host "  ID: $($Script:ReportId)  |  PC: $($Script:ComputerName)" -ForegroundColor DarkGray
    Write-Host "  READ-ONLY -- No system changes are made." -ForegroundColor Green
    Write-Host ""

    Write-Host "  [1/3] Collecting data..." -ForegroundColor Cyan
    $os   = Get-OSData
    $sw   = Get-RequiredSoftware
    $drv  = Get-DriverProblems
    $sec  = Get-SecurityData
    $dsk  = Get-DiskData

    Write-Host "  [2/3] Running validation..." -ForegroundColor Cyan
    $all = @()
    $all += Test-OSValidation -OS $os
    $all += Test-SoftwareValidation -SW $sw
    $all += Test-DriverValidation -Drv $drv
    $all += Test-SecurityValidation -Sec $sec
    $all += Test-DiskValidation -Disks $dsk

    $scoreCard = Get-DeploymentScore -AllChecks $all
    $fixes     = Get-Fixes -AllChecks $all

    $scoreColor = if ($scoreCard.Score -ge 85) { "Green" } elseif ($scoreCard.Score -ge 65) { "Yellow" } else { "Red" }
    Write-Host ""
    Write-Host "  Score: $($scoreCard.Score)/100  |  $($scoreCard.Decision)" -ForegroundColor $scoreColor
    Write-Host "  Pass: $($scoreCard.PassCount)  |  Warn: $($scoreCard.WarnCount)  |  Fail: $($scoreCard.FailCount)  |  Unknown: $($scoreCard.UnknownCount)" -ForegroundColor Gray
    Write-Host "  Est. Fix Time: $($scoreCard.EstMinutes)" -ForegroundColor DarkGray

    Write-Host "  [3/3] Generating report..." -ForegroundColor Cyan
    $html = Build-HtmlReport -AllChecks $all -ScoreCard $scoreCard -Fixes $fixes -Drivers $drv -Disks $dsk -Software $sw
    $html | Out-File -FilePath $Script:ReportPath -Encoding UTF8 -Force

    if ($scoreCard.FailCount -gt 0) {
        Write-Host ""
        Write-Host "  Blocking Issues:" -ForegroundColor Red
        $all | Where-Object { $_.Status -eq $FAIL -and $_.Severity -eq "High" } | ForEach-Object {
            Write-Host "    X  $($_.Name) -- $($_.Detail)" -ForegroundColor Red
        }
        if (($all | Where-Object { $_.Status -eq $FAIL -and $_.Severity -ne "High" }).Count -gt 0) {
            Write-Host "  Other Issues:" -ForegroundColor Yellow
            $all | Where-Object { $_.Status -eq $FAIL -and $_.Severity -ne "High" } | ForEach-Object {
                Write-Host "    !  $($_.Name) -- $($_.Detail)" -ForegroundColor Yellow
            }
        }
    }

    if (($all | Where-Object { $_.Status -eq $WARN }).Count -gt 0) {
        Write-Host ""
        Write-Host "  Warnings:" -ForegroundColor Yellow
        $all | Where-Object { $_.Status -eq $WARN } | ForEach-Object {
            Write-Host "    ~  $($_.Name) -- $($_.Detail)" -ForegroundColor Yellow
        }
    }

    $elapsed = [math]::Round(((Get-Date) - $Script:StartTime).TotalSeconds, 1)
    Write-Host ""
    Write-Host "  Report: $($Script:ReportPath)" -ForegroundColor Green
    Write-Host "  Duration: ${elapsed}s" -ForegroundColor Gray
    Start-Process -FilePath $Script:ReportPath
    Write-Host "  Opening in browser..." -ForegroundColor Gray
    Write-Host ""

    if ($scoreCard.FailCount -gt 0) {
        Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

# ============================================================================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Main