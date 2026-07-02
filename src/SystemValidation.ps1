<#
.SYNOPSIS
    System validation module for KBU Deployment Validator.

.DESCRIPTION
    Checks operating system info (edition, version, build, architecture,
    activation, uptime), disk free space, hostname, and system readiness.

.NOTES
    Does not call exit. Returns structured objects.
#>

$Script:StatusPass    = "PASS"
$Script:StatusWarning = "WARNING"
$Script:StatusFail    = "FAIL"
$Script:StatusUnknown = "UNKNOWN"

function Get-KBUOSInfo {
    <#
    .SYNOPSIS
        Collect operating system information.

    .DESCRIPTION
        Queries Win32_OperatingSystem and SoftwareLicensingProduct to
        retrieve OS edition, version, build, architecture, activation
        status, and last boot time.

    .EXAMPLE
        $osInfo = Get-KBUOSInfo
        $osInfo.Edition
    #>
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1

        if (-not $os) {
            return [PSCustomObject]@{
                Edition   = "Unknown"
                Version   = "Unknown"
                Build     = "Unknown"
                Arch      = "Unknown"
                Activated = $false
                LastBoot  = "Unknown"
                Error     = "Win32_OperatingSystem returned no data"
            }
        }

        $activated = $false
        try {
            $lic = Get-CimInstance SoftwareLicensingProduct `
                -Filter "Name like 'Windows%' AND PartialProductKey is not null" `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($lic) { $activated = ($lic.LicenseStatus -eq 1) }
        }
        catch {
            Write-KBUDebug "License check failed: $($_.Exception.Message)"
        }

        $lastBoot = "Unknown"
        try {
            $bootTime = [Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime)
            $bootDays = [int]((Get-Date) - $bootTime).TotalDays
            $lastBoot = if ($bootDays -eq 0) { "Today" }
                        elseif ($bootDays -eq 1) { "1 day ago" }
                        else { "${bootDays}d ago" }
        }
        catch {
            Write-KBUDebug "Uptime calculation failed: $($_.Exception.Message)"
        }

        $result = [PSCustomObject]@{
            Edition   = $os.Caption
            Version   = $os.Version
            Build     = $os.BuildNumber
            Arch      = $os.OSArchitecture
            Activated = $activated
            LastBoot  = $lastBoot
            BootDays  = $bootDays
        }
        return $result
    }
    catch {
        Write-KBUWarning "Failed to query OS info: $($_.Exception.Message)"
        return [PSCustomObject]@{
            Edition   = "Unknown"
            Version   = "Unknown"
            Build     = "Unknown"
            Arch      = "Unknown"
            Activated = $false
            LastBoot  = "Unknown"
            BootDays  = 999
            Error     = $_.Exception.Message
        }
    }
}

function Get-KBUDiskInfo {
    <#
    .SYNOPSIS
        Collect disk space information for all fixed drives.

    .DESCRIPTION
        Queries Win32_LogicalDisk for DriveType=3 (fixed disks) and
        returns free space, total space, and percentage free.

    .EXAMPLE
        $disks = Get-KBUDiskInfo
        $disks | Format-Table Drive, FreeGB, PctFree
    #>
    try {
        $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | ForEach-Object {
            $pct = 0
            $totalGb = 0
            $freeGb  = 0
            if ($_.Size -gt 0) {
                $totalGb = [math]::Round($_.Size / 1GB, 1)
                $freeGb  = [math]::Round($_.FreeSpace / 1GB, 1)
                $pct     = [math]::Round(($_.FreeSpace / $_.Size) * 100, 1)
            }

            [PSCustomObject]@{
                Drive   = $_.DeviceID
                Label   = if ($_.VolumeName) { $_.VolumeName } else { "Local Disk" }
                TotalGB = $totalGb
                FreeGB  = $freeGb
                PctFree = $pct
            }
        }

        if (-not $disks) {
            return @()
        }

        return @($disks)
    }
    catch {
        Write-KBUWarning "Failed to query disk info: $($_.Exception.Message)"
        return @()
    }
}

function Get-KBUSystemInfo {
    <#
    .SYNOPSIS
        Collect all system information in a single call.

    .DESCRIPTION
        Returns OS info, disk info, computer name, and validation timestamp.

    .EXAMPLE
        $sysInfo = Get-KBUSystemInfo
        $sysInfo.Hostname
    #>
    $os   = Get-KBUOSInfo
    $disks = Get-KBUDiskInfo

    return [PSCustomObject]@{
        OS        = $os
        Disks     = $disks
        Hostname  = $env:COMPUTERNAME
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
}

function Test-KBUSystem {
    <#
    .SYNOPSIS
        Validate system readiness for deployment.

    .DESCRIPTION
        Checks OS edition, version, build, architecture, activation,
        uptime, and disk free space against configured thresholds.

    .PARAMETER Config
        Validated configuration object.

    .EXAMPLE
        $sysResults = Test-KBUSystem -Config $config
        $sysResults.Checks | Format-Table Name, Status, Severity
    #>
    param(
        [PSCustomObject]$Config
    )

    $sysInfo = Get-KBUSystemInfo
    $os      = $sysInfo.OS
    $disks   = $sysInfo.Disks
    $checks  = @()

    $pro    = $os.Edition -match "Pro|Enterprise|Education"
    $isHome = $os.Edition -match "Home"

    $osEditionCheck = [PSCustomObject]@{
        Name     = "Windows Edition"
        WeightKey = "WindowsEdition"
        Status   = if ($pro) { $Script:StatusPass } else { $Script:StatusWarning }
        Detail   = $os.Edition
        Fix      = if ($isHome) { "Pro/Enterprise recommended for enterprise environments." } else { "" }
        Severity = "Low"
        Category = "System"
    }
    $checks += $osEditionCheck

    $verStr = $os.Version
    if ($verStr -eq "Unknown" -or -not $verStr) {
        $verOk = $false
    }
    else {
        try { $verOk = [version]$verStr -ge [version]$Config.Thresholds.MinOSVersion }
        catch { $verOk = $false }
    }

    $osVerCheck = [PSCustomObject]@{
        Name     = "Windows Version"
        WeightKey = "WindowsVersion"
        Status   = if ($verOk) { $Script:StatusPass } else { $Script:StatusFail }
        Detail   = "$($os.Version) (Build $($os.Build))"
        Fix      = if (-not $verOk) { "Upgrade to Windows 10 or 11." } else { "" }
        Severity = if (-not $verOk) { "High" } else { "" }
        Category = "System"
    }
    $checks += $osVerCheck

    if ($os.Build -match '^\d+$') {
        $buildNumber = [int]$os.Build
        $bldOk = $buildNumber -ge $Config.Thresholds.MinBuildNumber
    }
    else {
        $bldOk = $false
    }

    $osBuildCheck = [PSCustomObject]@{
        Name     = "Build Number"
        WeightKey = "BuildNumber"
        Status   = if ($bldOk) { $Script:StatusPass } else { $Script:StatusWarning }
        Detail   = $os.Build
        Fix      = if (-not $bldOk) { "Install latest Windows updates." } else { "" }
        Severity = "Low"
        Category = "System"
    }
    $checks += $osBuildCheck

    $archOk = $os.Arch -match "64"

    $osArchCheck = [PSCustomObject]@{
        Name     = "Architecture"
        WeightKey = "Architecture"
        Status   = if ($archOk) { $Script:StatusPass } else { $Script:StatusFail }
        Detail   = $os.Arch
        Fix      = if (-not $archOk) { "64-bit Windows required." } else { "" }
        Severity = if (-not $archOk) { "High" } else { "" }
        Category = "System"
    }
    $checks += $osArchCheck

    $osActCheck = [PSCustomObject]@{
        Name     = "Activation"
        WeightKey = "Activation"
        Status   = if ($os.Activated) { $Script:StatusPass } else { $Script:StatusFail }
        Detail   = if ($os.Activated) { "Licensed" } else { "Not Activated" }
        Fix      = if (-not $os.Activated) { "Activate Windows with a valid license." } else { "" }
        Severity = if (-not $os.Activated) { "High" } else { "" }
        Category = "System"
    }
    $checks += $osActCheck

    $bootDays  = if ($null -ne $os.BootDays -and $os.BootDays -ge 0) { $os.BootDays } else { 999 }
    $maxUptime = $Config.Thresholds.MaxUptimeDays

    $osBootCheck = [PSCustomObject]@{
        Name     = "Last Reboot"
        WeightKey = "LastReboot"
        Status   = if ($bootDays -le $maxUptime) { $Script:StatusPass } else { $Script:StatusWarning }
        Detail   = $os.LastBoot
        Fix      = if ($bootDays -gt $maxUptime) { "Restart to apply pending updates." } else { "" }
        Severity = "Low"
        Category = "System"
    }
    $checks += $osBootCheck

    foreach ($d in $disks) {
        if ($d.PctFree -lt $Config.Thresholds.DiskFreePercentCritical -or
            $d.FreeGB -lt $Config.Thresholds.DiskFreeGBCritical) {
            $dStatus = $Script:StatusFail
            $dSev    = "High"
        }
        elseif ($d.PctFree -lt $Config.Thresholds.DiskFreePercentWarning -or
                $d.FreeGB -lt $Config.Thresholds.DiskFreeGBWarning) {
            $dStatus = $Script:StatusWarning
            $dSev    = "Medium"
        }
        else {
            $dStatus = $Script:StatusPass
            $dSev    = ""
        }

        $diskCheck = [PSCustomObject]@{
            Name     = "$($d.Drive) ($($d.Label))"
            Status   = $dStatus
            Detail   = "$($d.FreeGB) GB free ($($d.PctFree)%)"
            Fix      = if ($dStatus -ne $Script:StatusPass) { "Free up disk space on $($d.Drive)." } else { "" }
            Severity = $dSev
            Category = "System"
        }
        $checks += $diskCheck
    }

    Write-KBUInfo "System validation complete. $($checks.Count) checks performed."

    return [PSCustomObject]@{
        Checks    = $checks
        SystemInfo = $sysInfo
    }
}
