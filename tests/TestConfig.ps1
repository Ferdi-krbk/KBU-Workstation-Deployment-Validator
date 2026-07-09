<#
.SYNOPSIS
    Test configuration for KBU Deployment Validator Pester tests.

.DESCRIPTION
    Provides a sample valid configuration, an invalid configuration,
    and test utility functions shared across all test files.
#>

$Script:TestConfigPath = Join-Path $PSScriptRoot "test_config.json"

function Get-ValidTestConfig {
    return [PSCustomObject]@{
        Tool = [PSCustomObject]@{ Name = "Test Validator"; Version = "1.0.0" }
        Branding = [PSCustomObject]@{ Organization = "Test"; Department = "Test"; LogoText = "TST" }
        RequiredSoftware = @(
            [PSCustomObject]@{ Name = "TestApp1"; Patterns = @("TestApp1"); Blocking = $true }
            [PSCustomObject]@{ Name = "TestApp2"; Patterns = @("TestApp2"); Blocking = $false }
        )
        OptionalSoftware = @(
            [PSCustomObject]@{ Name = "OptApp1"; Patterns = @("OptApp1") }
        )
        Scoring = [PSCustomObject]@{
            MaxScore = 100
            PassingThreshold = 85
            WarningThreshold = 65
            WarnPenaltyFactor = 0.5
            BlockingSoftware = @("TestApp1", "Antivirus")
            Weights = [PSCustomObject]@{
                WindowsEdition = 3; WindowsVersion = 12; BuildNumber = 3
                Architecture = 12; Activation = 10; LastReboot = 2
                Antivirus = 10; Firewall = 8; BitLocker = 3
                SecureBoot = 3; TPM = 5; UnknownDevices = 5
                DisabledDevices = 2; DriverErrors = 5; RequiredSoftware = 8
                OptionalSoftware = 2
            }
        }
        Thresholds = [PSCustomObject]@{
            DiskFreePercentWarning = 20; DiskFreePercentCritical = 10
            DiskFreeGBWarning = 20; DiskFreeGBCritical = 10
            MaxUptimeDays = 30; MinBuildNumber = 19041; MinOSVersion = "10.0"
        }
        Reports = [PSCustomObject]@{
            OutputPath = (Join-Path $env:TEMP "KBU_Test_Reports")
            IncludeHtml = $true; IncludeJson = $true; OpenInBrowser = $false
        }
        Logging = [PSCustomObject]@{
            LogPath = (Join-Path $env:TEMP "KBU_Test_Logs")
            LogLevel = "Error"; RetentionDays = 0
        }
        ValidationModules = @("System", "Software", "Drivers", "Security")
        UninstallRegistryPaths = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
    }
}

function Get-InvalidTestConfig {
    return [PSCustomObject]@{
        Tool = [PSCustomObject]@{ Name = "Bad Config" }
    }
}

function New-TestCheck {
    param(
        [string]$Name,
        [string]$Status = "PASS",
        [string]$Detail = "",
        [string]$Fix = "",
        [string]$Severity = "",
        [string]$Category = "System"
    )
    return [PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail; Fix = $Fix; Severity = $Severity; Category = $Category }
}

function New-TestInstalledSoftware {
    return @(
        [PSCustomObject]@{
            DisplayName    = "TestApp1 Suite 2024"
            DisplayVersion = "1.0.0"
            Publisher      = "Test Corp"
        },
        [PSCustomObject]@{
            DisplayName    = "TestApp2 Enterprise"
            DisplayVersion = "2.5.0"
            Publisher      = "Test Corp"
        },
        [PSCustomObject]@{
            DisplayName    = "OptApp1 Viewer"
            DisplayVersion = "3.0.0"
            Publisher      = "Test Corp"
        },
        [PSCustomObject]@{
            DisplayName    = "Microsoft Office Professional Plus 2021"
            DisplayVersion = "16.0"
            Publisher      = "Microsoft"
        },
        [PSCustomObject]@{
            DisplayName    = "Google Chrome"
            DisplayVersion = "120.0"
            Publisher      = "Google"
        }
    )
}

function New-TestDeviceProblems {
    return [PSCustomObject]@{
        HasProblems = $false
        Unknown     = @()
        Disabled    = @()
        Other       = @()
    }
}

function New-TestSystemInfo {
    return [PSCustomObject]@{
        OS = [PSCustomObject]@{
            Edition   = "Microsoft Windows 10 Pro"
            Version   = "10.0"
            Build     = "19045"
            Arch      = "64-bit"
            Activated = $true
            LastBoot  = "Today"
            BootDays  = 0
        }
        Disks = @(
            [PSCustomObject]@{ Drive = "C:"; Label = "Local Disk"; TotalGB = 500; FreeGB = 200; PctFree = 40 }
        )
        Hostname  = $env:COMPUTERNAME
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
}
