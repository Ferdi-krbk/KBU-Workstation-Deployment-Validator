<#
.SYNOPSIS
    Security validation module for KBU Deployment Validator.

.DESCRIPTION
    Checks antivirus status (Windows Defender and third-party), firewall
    status, BitLocker encryption, Secure Boot, and TPM readiness.

    When security data is unavailable, returns UNKNOWN status instead of
    false failures. Designed to work without admin rights.

.NOTES
    Does not call exit. Returns structured objects.
    May return UNKNOWN for checks requiring elevation.
#>

$Script:StatusPass    = "PASS"
$Script:StatusWarning = "WARNING"
$Script:StatusFail    = "FAIL"
$Script:StatusUnknown = "UNKNOWN"

function Get-KBUSecurityData {
    <#
    .SYNOPSIS
        Collect security-related data from the system.

    .DESCRIPTION
        Queries SecurityCenter2 for antivirus products, Windows Defender
        status, firewall profiles, BitLocker, Secure Boot, and TPM.
        All queries are wrapped in try/catch to handle permission errors.

    .EXAMPLE
        $secData = Get-KBUSecurityData
        $secData.HasAV
    #>

    $result = [PSCustomObject]@{
        DefenderOn              = $false
        ThirdPartyAV            = $null
        HasAV                   = $false
        Firewall                = $false
        BitLocker               = $false
        SecureBoot              = $null
        TPM                     = $null
        SecurityCenterAvailable = $false
        DefenderDataAvailable   = $false
        FirewallDataAvailable   = $false
        AVDataAvailable         = $false
    }

    $secCenterAV = $null
    try {
        $avProducts = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop
        $result.SecurityCenterAvailable = $true
        $result.AVDataAvailable = $true
        $secCenterAV = $avProducts | Where-Object {
            $_.displayName -notmatch "Windows Defender|Microsoft Defender"
        } | Select-Object -First 1
    }
    catch {
        Write-KBUWarning "SecurityCenter2 unavailable: $($_.Exception.Message)"
    }

    if ($secCenterAV) {
        $result.ThirdPartyAV = $secCenterAV.displayName
        $result.HasAV = $true
    }

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $result.DefenderDataAvailable = $true
        $result.AVDataAvailable = $true
        $result.DefenderOn = $mp.AntivirusEnabled
        if (-not $result.HasAV) {
            $result.HasAV = $result.DefenderOn
        }
    }
    catch {
        Write-KBUWarning "Windows Defender status unavailable: $($_.Exception.Message)"
    }

    try {
        $fwProfiles = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled })
        $result.FirewallDataAvailable = $true
        $result.Firewall = ($fwProfiles.Count -eq 0)
    }
    catch {
        Write-KBUWarning "Firewall status unavailable: $($_.Exception.Message)"
    }

    try {
        $blv = Get-BitLockerVolume -ErrorAction Stop | Select-Object -First 1
        if ($blv) {
            $result.BitLocker = ($blv.ProtectionStatus -eq "On")
        }
    }
    catch {
        Write-KBUDebug "BitLocker status unavailable (may require admin): $($_.Exception.Message)"
    }

    try {
        $result.SecureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
    }
    catch {
        Write-KBUDebug "Secure Boot status unavailable: $($_.Exception.Message)"
    }

    try {
        $tpm = Get-Tpm -ErrorAction Stop
        if ($tpm) {
            $result.TPM = [PSCustomObject]@{
                Present = $tpm.TpmPresent
                Ready   = $tpm.TpmReady
            }
        }
    }
    catch {
        Write-KBUDebug "TPM status unavailable (may require admin): $($_.Exception.Message)"
    }

    return $result
}

function Test-KBUSecurity {
    <#
    .SYNOPSIS
        Validate security readiness for deployment.

    .DESCRIPTION
        Runs security checks and returns structured results with
        PASS/WARNING/FAIL/UNKNOWN statuses. Uses UNKNOWN when security
        data cannot be retrieved.

    .PARAMETER Config
        Validated configuration object.

    .EXAMPLE
        $secResults = Test-KBUSecurity -Config $config
        $secResults.Checks | Format-Table Name, Status, Severity
    #>
    param(
        [PSCustomObject]$Config
    )

    $data   = Get-KBUSecurityData
    $checks = @()

    if (-not $data.AVDataAvailable) {
        $avCheck = [PSCustomObject]@{
            Name     = "Antivirus"
            WeightKey = "Antivirus"
            Status   = $Script:StatusUnknown
            Detail   = "Unable to determine"
            Fix      = "Verify antivirus protection is installed and enabled."
            Severity = ""
            Category = "Security"
        }
    }
    elseif ($data.ThirdPartyAV) {
        $avCheck = [PSCustomObject]@{
            Name     = "Antivirus"
            WeightKey = "Antivirus"
            Status   = $Script:StatusPass
            Detail   = "Third-party Antivirus Detected ($($data.ThirdPartyAV))"
            Fix      = ""
            Severity = ""
            Category = "Security"
        }
    }
    elseif ($data.DefenderOn) {
        $avCheck = [PSCustomObject]@{
            Name     = "Antivirus"
            WeightKey = "Antivirus"
            Status   = $Script:StatusPass
            Detail   = "Windows Defender Active"
            Fix      = ""
            Severity = ""
            Category = "Security"
        }
    }
    else {
        $avCheck = [PSCustomObject]@{
            Name     = "Antivirus"
            WeightKey = "Antivirus"
            Status   = $Script:StatusFail
            Detail   = "No Antivirus Detected"
            Fix      = "Install or enable antivirus protection."
            Severity = "High"
            Category = "Security"
        }
    }
    $checks += $avCheck

    if (-not $data.FirewallDataAvailable) {
        $fwCheck = [PSCustomObject]@{
            Name     = "Firewall"
            WeightKey = "Firewall"
            Status   = $Script:StatusUnknown
            Detail   = "Unable to determine"
            Fix      = "Verify Windows Firewall is enabled."
            Severity = ""
            Category = "Security"
        }
    }
    elseif ($data.Firewall) {
        $fwCheck = [PSCustomObject]@{
            Name     = "Firewall"
            WeightKey = "Firewall"
            Status   = $Script:StatusPass
            Detail   = "All Profiles On"
            Fix      = ""
            Severity = ""
            Category = "Security"
        }
    }
    else {
        $fwCheck = [PSCustomObject]@{
            Name     = "Firewall"
            WeightKey = "Firewall"
            Status   = $Script:StatusFail
            Detail   = "Disabled"
            Fix      = "Enable firewall on all network profiles."
            Severity = "High"
            Category = "Security"
        }
    }
    $checks += $fwCheck

    if ($data.BitLocker) {
        $blCheck = [PSCustomObject]@{
            Name     = "BitLocker"
            WeightKey = "BitLocker"
            Status   = $Script:StatusPass
            Detail   = "Encrypted"
            Fix      = ""
            Severity = ""
            Category = "Security"
        }
    }
    else {
        $blCheck = [PSCustomObject]@{
            Name     = "BitLocker"
            WeightKey = "BitLocker"
            Status   = $Script:StatusWarning
            Detail   = "Not Enabled"
            Fix      = "Enable BitLocker drive encryption."
            Severity = "Low"
            Category = "Security"
        }
    }
    $checks += $blCheck

    if ($null -eq $data.SecureBoot) {
        $sbCheck = [PSCustomObject]@{
            Name     = "Secure Boot"
            WeightKey = "SecureBoot"
            Status   = $Script:StatusUnknown
            Detail   = "Unable to determine"
            Fix      = "Check Secure Boot status in UEFI/BIOS."
            Severity = ""
            Category = "Security"
        }
    }
    elseif ($data.SecureBoot) {
        $sbCheck = [PSCustomObject]@{
            Name     = "Secure Boot"
            WeightKey = "SecureBoot"
            Status   = $Script:StatusPass
            Detail   = "Enabled"
            Fix      = ""
            Severity = ""
            Category = "Security"
        }
    }
    else {
        $sbCheck = [PSCustomObject]@{
            Name     = "Secure Boot"
            WeightKey = "SecureBoot"
            Status   = $Script:StatusWarning
            Detail   = "Disabled"
            Fix      = "Enable Secure Boot in UEFI/BIOS for enhanced security."
            Severity = "Low"
            Category = "Security"
        }
    }
    $checks += $sbCheck

    if ($null -eq $data.TPM) {
        $tpCheck = [PSCustomObject]@{
            Name     = "TPM"
            WeightKey = "TPM"
            Status   = $Script:StatusUnknown
            Detail   = "Unable to verify"
            Fix      = "Check TPM status in UEFI/BIOS or tpm.msc."
            Severity = ""
            Category = "Security"
        }
    }
    elseif ($data.TPM.Ready) {
        $tpCheck = [PSCustomObject]@{
            Name     = "TPM"
            WeightKey = "TPM"
            Status   = $Script:StatusPass
            Detail   = "Present and Ready"
            Fix      = ""
            Severity = ""
            Category = "Security"
        }
    }
    elseif ($data.TPM.Present) {
        $tpCheck = [PSCustomObject]@{
            Name     = "TPM"
            WeightKey = "TPM"
            Status   = $Script:StatusWarning
            Detail   = "Present, Not Ready"
            Fix      = "Initialize TPM in BIOS/UEFI."
            Severity = "Low"
            Category = "Security"
        }
    }
    else {
        $tpCheck = [PSCustomObject]@{
            Name     = "TPM"
            WeightKey = "TPM"
            Status   = $Script:StatusUnknown
            Detail   = "Not Found"
            Fix      = "TPM 2.0 is recommended for Windows 11 and security features."
            Severity = ""
            Category = "Security"
        }
    }
    $checks += $tpCheck

    Write-KBUInfo "Security validation complete. AV=$($avCheck.Status), FW=$($fwCheck.Status)"

    return [PSCustomObject]@{
        Checks     = $checks
        SecurityData = $data
    }
}
