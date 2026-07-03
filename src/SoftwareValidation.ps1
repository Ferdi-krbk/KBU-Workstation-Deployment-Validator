<#
.SYNOPSIS
    Software validation module for KBU Deployment Validator.

.DESCRIPTION
    Checks installed applications via registry uninstall paths.
    Detects missing required software, optional software presence,
    and returns structured validation results.

.NOTES
    Registry access is read-only. Does not require admin rights.
    Does not call exit. Returns structured objects.
#>

$Script:StatusPass    = "PASS"
$Script:StatusWarning = "WARNING"
$Script:StatusFail    = "FAIL"
$Script:StatusUnknown = "UNKNOWN"

function Get-KBUInstalledSoftware {
    <#
    .SYNOPSIS
        Queries registry uninstall paths and returns installed applications.

    .DESCRIPTION
        Reads HKLM uninstall registry keys (32-bit and 64-bit) and returns
        a list of installed applications with DisplayName and DisplayVersion.

    .PARAMETER RegistryPaths
        Array of registry paths to search for installed software.

    .EXAMPLE
        $installed = Get-KBUInstalledSoftware
        $installed | Where-Object { $_.DisplayName -like "*Office*" }
    #>
    param(
        [string[]]$RegistryPaths
    )

    if (-not $RegistryPaths -or $RegistryPaths.Count -eq 0) {
        $RegistryPaths = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
    }

    $installed = @()
    foreach ($rp in $RegistryPaths) {
        try {
            $items = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
            if ($items) {
                $installed += @($items | Where-Object { $_.DisplayName })
            }
        }
        catch {
            Write-KBUWarning "Failed to read registry path $rp : $($_.Exception.Message)"
        }
    }

    if ($installed.Count -gt 0) {
        $installed = $installed | Sort-Object DisplayName -Unique
    }

    Write-KBUInfo "Found $($installed.Count) installed applications in registry."
    return $installed
}

function Find-KBUSoftware {
    <#
    .SYNOPSIS
        Search for a specific software entry among installed applications.

    .DESCRIPTION
        Matches against a list of name patterns, with optional exclude patterns.
        Returns the first matching entry or $null.

    .PARAMETER InstalledSoftware
        Array of installed software objects (with DisplayName property).

    .PARAMETER SoftwareDef
        Software definition object with Name and Patterns properties.
    #>
    param(
        [object[]]$InstalledSoftware,
        [PSCustomObject]$SoftwareDef
    )

    foreach ($pattern in $SoftwareDef.Patterns) {
        $found = $InstalledSoftware | Where-Object { $_.DisplayName -like "*$pattern*" } | Select-Object -First 1
        if ($found) {
            if ($SoftwareDef.Exclude) {
                foreach ($ex in $SoftwareDef.Exclude) {
                    if ($found.DisplayName -like "*$ex*") {
                        $found = $null
                        break
                    }
                }
            }
            if ($found) { return $found }
        }
    }
    return $null
}

function Find-KBUSoftwareFile {
    <#
    .SYNOPSIS
        Search for a software executable at configured file paths.

    .DESCRIPTION
        Checks file paths defined in SoftwareDef.FilePaths for portable
        or non-registry applications. Supports environment variables in paths.

    .PARAMETER SoftwareDef
        Software definition object with optional FilePaths array.
    #>
    param(
        [PSCustomObject]$SoftwareDef
    )

    if (-not $SoftwareDef.FilePaths) { return $null }

    foreach ($fp in $SoftwareDef.FilePaths) {
        $expanded = [Environment]::ExpandEnvironmentVariables($fp)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            $version = "Portable"
            try {
                $fileInfo = Get-Item -LiteralPath $expanded -ErrorAction Stop
                if ($fileInfo.VersionInfo.FileVersion) {
                    $version = $fileInfo.VersionInfo.FileVersion
                }
            }
            catch { }

            Write-KBUInfo "Found portable software: $($SoftwareDef.Name) at $expanded"
            return [PSCustomObject]@{
                DisplayName    = $SoftwareDef.Name
                DisplayVersion = $version
                FilePath       = $expanded
            }
        }
    }
    return $null
}

function Test-KBUSoftware {
    <#
    .SYNOPSIS
        Validate required and optional software installation status.

    .DESCRIPTION
        Searches the registry for required and optional software defined
        in the configuration. Returns structured check results.

    .PARAMETER Config
        Validated configuration object from Get-KBUConfig.

    .EXAMPLE
        $swResults = Test-KBUSoftware -Config $config
        $swResults.Checks | Format-Table Name, Status, Detail
    #>
    param(
        [PSCustomObject]$Config
    )

    $checks   = @()
    $software = @{ Required = @(); Optional = @() }

    $installed = Get-KBUInstalledSoftware -RegistryPaths $Config.UninstallRegistryPaths

    if (-not $installed -or $installed.Count -eq 0) {
        Write-KBUWarning "No installed software found in registry."
    }

    foreach ($req in $Config.RequiredSoftware) {
        $found = Find-KBUSoftware -InstalledSoftware $installed -SoftwareDef $req
        if (-not $found) { $found = Find-KBUSoftwareFile -SoftwareDef $req }
        $isInstalled = ($found -ne $null)
        $version     = if ($isInstalled -and $found.DisplayVersion) { $found.DisplayVersion } else { "N/A" }
        $detail      = if ($isInstalled) { "v$version" } else { "Not Installed" }
        $fix         = if (-not $isInstalled) { "Install $($req.Name)." } else { "" }
        $status      = if ($isInstalled) { $Script:StatusPass } else { $Script:StatusFail }
        $severity    = if (-not $isInstalled -and $req.Blocking) { "High" }
                       elseif (-not $isInstalled) { "Medium" }
                       else { "" }

        $swObj = [PSCustomObject]@{
            Name      = $req.Name
            Installed = $isInstalled
            Version   = $version
        }
        $software.Required += $swObj

        $checkObj = [PSCustomObject]@{
            Name     = $req.Name
            Status   = $status
            Detail   = $detail
            Fix      = $fix
            Severity = $severity
            Category = "Software"
        }
        $checks += $checkObj

        Write-KBUInfo "Required Software Check: $($req.Name) - $status"
    }

    if ($Config.OptionalSoftware) {
        foreach ($opt in $Config.OptionalSoftware) {
            $found = Find-KBUSoftware -InstalledSoftware $installed -SoftwareDef $opt
            if (-not $found) { $found = Find-KBUSoftwareFile -SoftwareDef $opt }
            $isInstalled = ($found -ne $null)
            $version     = if ($isInstalled -and $found.DisplayVersion) { $found.DisplayVersion } else { "N/A" }
            $detail      = if ($isInstalled) { "v$version" } else { "Not Installed" }
            $status      = if ($isInstalled) { $Script:StatusPass } else { $Script:StatusWarning }

            $swObj = [PSCustomObject]@{
                Name      = $opt.Name
                Installed = $isInstalled
                Version   = $version
            }
            $software.Optional += $swObj

            $checkObj = [PSCustomObject]@{
                Name     = $opt.Name
                Status   = $status
                Detail   = $detail
                Fix      = ""
                Severity = ""
                Category = "Software"
            }
            $checks += $checkObj

            Write-KBUDebug "Optional Software Check: $($opt.Name) - $status"
        }
    }

    return [PSCustomObject]@{
        Checks        = $checks
        Required      = $software.Required
        Optional      = $software.Optional
        RequiredCount = ($software.Required | Where-Object { $_.Installed }).Count
        RequiredTotal = $software.Required.Count
    }
}
