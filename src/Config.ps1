<#
.SYNOPSIS
    Loads and validates the KBU Deployment Validator configuration.

.DESCRIPTION
    Reads config.json from the script root directory, validates its structure,
    and returns a structured configuration object. Handles missing or invalid
    config gracefully by returning default values and error information.

.NOTES
    Does not call exit. Returns structured error objects instead.
#>

function Get-KBUConfig {
    <#
    .SYNOPSIS
        Load and validate the KBU configuration from config.json.

    .DESCRIPTION
        Searches for config.json relative to the calling script's directory.
        Validates required sections exist and returns a configuration object
        with safe defaults for any missing values.

    .PARAMETER ConfigPath
        Optional explicit path to config.json. Auto-detected if not provided.

    .EXAMPLE
        $config = Get-KBUConfig
        $config = Get-KBUConfig -ConfigPath "C:\Tools\config.json"
    #>
    param(
        [string]$ConfigPath
    )

    $result = [PSCustomObject]@{
        Valid     = $false
        Config    = $null
        Error     = $null
        ConfigPath = $null
    }

    try {
        if (-not $ConfigPath) {
            $scriptDir = Split-Path -Parent $MyInvocation.PSCommandPath
            if (-not $scriptDir) { $scriptDir = Split-Path -Parent $PSScriptRoot }
            if (-not $scriptDir) { $scriptDir = Get-Location }
            $ConfigPath = Join-Path $scriptDir "..\config.json"
        }

        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            $altPath = Join-Path (Get-Location) "config.json"
            if (Test-Path -LiteralPath $altPath) {
                $ConfigPath = $altPath
            } else {
                throw "Configuration file not found at: $ConfigPath"
            }
        }

        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop

        $requiredSections = @("Tool", "RequiredSoftware", "Scoring", "Reports")
        foreach ($section in $requiredSections) {
            if (-not $cfg.$section) {
                throw "Missing required config section: $section"
            }
        }

        if (-not $cfg.RequiredSoftware -or @($cfg.RequiredSoftware).Count -eq 0) {
            throw "RequiredSoftware list is empty"
        }

        foreach ($sw in $cfg.RequiredSoftware) {
            if (-not $sw.Name -or -not $sw.Patterns) {
                throw "Invalid software entry. Name and Patterns are required."
            }
        }

        $result.Valid = $true
        $result.Config = $cfg
        $result.ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path

        Write-Verbose "Configuration loaded successfully from: $($result.ConfigPath)"
    }
    catch {
        $result.Valid = $false
        $result.Error = $_.Exception.Message
        Write-Warning "Failed to load configuration: $($_.Exception.Message)"
    }

    return $result
}

function Get-DefaultKBUConfig {
    <#
    .SYNOPSIS
        Returns a minimal default configuration when config.json is unavailable.

    .DESCRIPTION
        Provides hardcoded fallback values so the validator can still operate
        when the config file is missing or corrupted.
    #>
    return [PSCustomObject]@{
        Tool = [PSCustomObject]@{
            Name    = "KBU Deployment Validator"
            Version = "1.2.0"
        }
        Branding = [PSCustomObject]@{
            Organization = "Karabuk University"
            Department   = "IT Department"
            LogoText     = "KBU"
        }
        RequiredSoftware = @(
            [PSCustomObject]@{ Name = "Microsoft Office"; Patterns = @("Microsoft Office", "Microsoft 365"); Blocking = $true }
            [PSCustomObject]@{ Name = "Java Runtime";     Patterns = @("Java");                   Blocking = $true;  Exclude = @("Auto Updater", "Update") }
            [PSCustomObject]@{ Name = "Akia";             Patterns = @("Akia");                   Blocking = $true }
            [PSCustomObject]@{ Name = "AnyDesk";          Patterns = @("AnyDesk");                Blocking = $false }
            [PSCustomObject]@{ Name = "enVision";         Patterns = @("enVision");                Blocking = $false }
            [PSCustomObject]@{ Name = "Web Browser";       Patterns = @("Google Chrome", "Mozilla Firefox", "Microsoft Edge"); Blocking = $true }
        )
        OptionalSoftware = @()
        Scoring = [PSCustomObject]@{
            MaxScore          = 100
            PassingThreshold  = 85
            WarningThreshold  = 65
            BlockingSoftware  = @("Microsoft Office", "Java Runtime", "Akia", "Antivirus")
            WarnPenaltyFactor = 0.5
            Weights = [PSCustomObject]@{
                WindowsEdition  = 3;  WindowsVersion = 12; BuildNumber = 3
                Architecture    = 12; Activation     = 10; LastReboot  = 2
                Antivirus       = 10; Firewall       = 8;  BitLocker   = 3
                SecureBoot      = 3;  TPM            = 5;  UnknownDevices = 5
                DisabledDevices = 2;  DriverErrors   = 5;  RequiredSoftware = 8
                OptionalSoftware = 2
            }
        }
        Thresholds = [PSCustomObject]@{
            DiskFreePercentWarning = 20; DiskFreePercentCritical = 10
            DiskFreeGBWarning      = 20; DiskFreeGBCritical      = 10
            MaxUptimeDays          = 30; MinBuildNumber          = 19041
            MinOSVersion           = "10.0"
        }
        Reports = [PSCustomObject]@{
            OutputPath    = "reports"; IncludeHtml = $true
            IncludeJson   = $true;     OpenInBrowser = $true
        }
        Logging = [PSCustomObject]@{
            LogPath       = "logs"; LogLevel = "Info"; RetentionDays = 30
        }
        ValidationModules = @("System", "Software", "Drivers", "Security")
        UninstallRegistryPaths = @(
            "HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*"
            "HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*"
        )
    }
}
