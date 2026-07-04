<#
.SYNOPSIS
    Driver/device validation module for KBU Deployment Validator.

.DESCRIPTION
    Checks Device Manager for problem devices, unknown devices, and
    disabled devices. Classifies severity based on ConfigManagerErrorCode.

.NOTES
    Read-only. Uses Win32_PnPEntity CIM class. Does not require admin rights.
    Does not call exit. Returns structured objects.
#>

$Script:StatusPass    = "PASS"
$Script:StatusWarning = "WARNING"
$Script:StatusFail    = "FAIL"
$Script:StatusUnknown = "UNKNOWN"

function Get-KBUDeviceProblems {
    <#
    .SYNOPSIS
        Query Device Manager for devices with problems.

    .DESCRIPTION
        Retrieves all PnP devices with a non-zero ConfigManagerErrorCode
        and classifies them by severity and type.

    .EXAMPLE
        $problems = Get-KBUDeviceProblems
        $problems.Unknown | Format-Table Name, Code, Severity
    #>
    try {
        $allDevices = Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode }

        if (-not $allDevices) {
            Write-KBUInfo "No problem devices detected."
            return [PSCustomObject]@{
                HasProblems = $false
                Unknown     = @()
                Disabled    = @()
                Other       = @()
            }
        }

        $classify = {
            param($code)
            switch ($code) {
                0   { return "None" }
                1   { return "High" }
                10  { return "Medium" }
                18  { return "Medium" }
                19  { return "Medium" }
                22  { return "Low" }
                28  { return "Medium" }
                31  { return "Medium" }
                default { return "Medium" }
            }
        }

        $unknown  = @($allDevices | Where-Object { $_.ConfigManagerErrorCode -in @(1, 28) } |
            Select-Object Name, @{N='Code';E={$_.ConfigManagerErrorCode}},
                           @{N='Severity';E={& $classify $_.ConfigManagerErrorCode}})

        $disabled = @($allDevices | Where-Object { $_.ConfigManagerErrorCode -eq 22 } |
            Select-Object Name, @{N='Code';E={$_.ConfigManagerErrorCode}},
                           @{N='Severity';E={& $classify $_.ConfigManagerErrorCode}})

        $other    = @($allDevices | Where-Object { $_.ConfigManagerErrorCode -notin @(1, 22, 28) } |
            Select-Object Name, @{N='Code';E={$_.ConfigManagerErrorCode}},
                           @{N='Severity';E={& $classify $_.ConfigManagerErrorCode}})

        Write-KBUInfo "Device problems: $($unknown.Count) unknown, $($disabled.Count) disabled, $($other.Count) other"
    }
    catch {
        Write-KBUWarning "Failed to query device manager: $($_.Exception.Message)"
        return [PSCustomObject]@{
            HasProblems = $false
            Unknown     = @()
            Disabled    = @()
            Other       = @()
            QueryError  = $_.Exception.Message
        }
    }

    return [PSCustomObject]@{
        HasProblems = (@($unknown).Count + @($disabled).Count + @($other).Count) -gt 0
        Unknown     = $unknown
        Disabled    = $disabled
        Other       = $other
    }
}

function Test-KBUDrivers {
    <#
    .SYNOPSIS
        Validate driver/device readiness for deployment.

    .DESCRIPTION
        Analyzes device problems and returns structured check results
        with severity classification.

    .PARAMETER Config
        Validated configuration object (unused but accepted for interface consistency).

    .EXAMPLE
        $drvResults = Test-KBUDrivers
        $drvResults.Checks | Format-Table Name, Status, Severity
    #>
    param(
        [PSCustomObject]$Config
    )

    $problems = Get-KBUDeviceProblems
    $checks   = @()

    $unknownCount = @($problems.Unknown).Count
    $unknownHigh  = @($problems.Unknown | Where-Object { $_.Severity -eq "High" }).Count

    if ($unknownCount -eq 0) {
        $uStatus = $Script:StatusPass
        $uDetail = "None found"
        $uFix    = ""
        $uSev    = ""
    }
    elseif ($unknownHigh -gt 0) {
        $uStatus = $Script:StatusFail
        $uDetail = "$unknownCount found ($unknownHigh high severity)"
        $uFix    = "Install missing drivers for unknown devices."
        $uSev    = "High"
    }
    else {
        $uStatus = $Script:StatusWarning
        $uDetail = "$unknownCount found"
        $uFix    = "Install missing drivers for unknown devices."
        $uSev    = "Medium"
    }

    $checks += [PSCustomObject]@{
        Name     = "Unknown Devices"
        Status   = $uStatus
        Detail   = $uDetail
        Fix      = $uFix
        Severity = $uSev
        Category = "Drivers"
    }

    $disabledCount = @($problems.Disabled).Count
    if ($disabledCount -eq 0) {
        $dStatus = $Script:StatusPass
        $dDetail = "None found"
        $dFix    = ""
        $dSev    = ""
    }
    else {
        $dStatus = $Script:StatusWarning
        $dDetail = "$disabledCount found"
        $dFix    = "Enable disabled devices in Device Manager if needed."
        $dSev    = "Low"
    }

    $checks += [PSCustomObject]@{
        Name     = "Disabled Devices"
        Status   = $dStatus
        Detail   = $dDetail
        Fix      = $dFix
        Severity = $dSev
        Category = "Drivers"
    }

    $otherCount = @($problems.Other).Count
    $otherHigh  = @($problems.Other | Where-Object { $_.Severity -eq "High" }).Count

    if ($otherCount -eq 0) {
        $oStatus = $Script:StatusPass
        $oDetail = "None found"
        $oFix    = ""
        $oSev    = ""
    }
    elseif ($otherHigh -gt 0) {
        $oStatus = $Script:StatusFail
        $oDetail = "$otherCount found ($otherHigh high severity)"
        $oFix    = "Resolve Device Manager error codes for affected devices."
        $oSev    = "High"
    }
    else {
        $oStatus = $Script:StatusWarning
        $oDetail = "$otherCount found"
        $oFix    = "Resolve Device Manager error codes for affected devices."
        $oSev    = "Medium"
    }

    $checks += [PSCustomObject]@{
        Name     = "Driver Errors"
        Status   = $oStatus
        Detail   = $oDetail
        Fix      = $oFix
        Severity = $oSev
        Category = "Drivers"
    }

    Write-KBUInfo "Driver validation complete. Unknown: $unknownCount, Disabled: $disabledCount, Other: $otherCount"

    return [PSCustomObject]@{
        Checks      = $checks
        DeviceData  = $problems
        HasProblems = $problems.HasProblems
    }
}
