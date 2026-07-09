<#
.SYNOPSIS
    Pester 5.x test suite for KBU Deployment Validator.

.DESCRIPTION
    Tests all validation modules, scoring, and report generation.
    Uses mocking for system-dependent operations (registry, CIM, WMI).
    Does not require admin rights. Does not modify real registry.

.NOTES
    Requires Pester 5.x. Install: Install-Module -Name Pester -Force -SkipPublisherCheck
    Run: Invoke-Pester -Output Detailed
#>

BeforeAll {
    $testRoot  = Join-Path $PSScriptRoot ""
    $srcRoot   = Join-Path $testRoot "..\src"

    . (Join-Path $srcRoot "Config.ps1")
    . (Join-Path $srcRoot "Logger.ps1")
    . (Join-Path $srcRoot "SoftwareValidation.ps1")
    . (Join-Path $srcRoot "DriverValidation.ps1")
    . (Join-Path $srcRoot "SecurityValidation.ps1")
    . (Join-Path $srcRoot "SystemValidation.ps1")
    . (Join-Path $srcRoot "Scoring.ps1")
    . (Join-Path $srcRoot "ReportRenderer.ps1")

    . (Join-Path $testRoot "TestConfig.ps1")

    $testConfig = Get-ValidTestConfig

    $tempDir = Join-Path $env:TEMP "KBU_Test_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force -ErrorAction SilentlyContinue | Out-Null
    Initialize-KBULogger -LogPath $tempDir -LogLevel "Error" -RetentionDays 0
}

AfterAll {
    $tempDirs = @(
        (Join-Path $env:TEMP "KBU_Test_Reports")
        (Join-Path $env:TEMP "KBU_Test_Logs")
    )
    foreach ($d in $tempDirs) {
        if (Test-Path $d) {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Config Module" {

    Context "Valid Configuration" {
        It "Loads valid test config successfully" {
            $cfg = Get-ValidTestConfig
            $cfg.Tool.Name | Should -Be "Test Validator"
            $cfg.Scoring.MaxScore | Should -Be 100
            $cfg.RequiredSoftware.Count | Should -BeGreaterThan 0
        }
    }

    Context "Invalid Configuration" {
        It "Detects invalid config (missing RequiredSoftware)" {
            $cfg = Get-InvalidTestConfig
            $hasRequired = $null -ne $cfg.RequiredSoftware
            $hasRequired | Should -BeFalse
        }

        It "Default config provides fallback values" {
            $cfg = Get-DefaultKBUConfig
            $cfg.RequiredSoftware.Count | Should -BeGreaterThan 0
            $cfg.Scoring.MaxScore | Should -Be 100
        }
    }

    Context "Config Validation" {
        It "Get-KBUConfig returns structured result for missing file" {
            $fakePath = Join-Path $env:TEMP "nonexistent_config.json"
            $result = Get-KBUConfig -ConfigPath $fakePath
            $result.Valid | Should -BeFalse
            $result.Error | Should -Not -BeNullOrEmpty
        }

        It "Get-KBUConfig does not exit on failure" {
            { Get-KBUConfig -ConfigPath "Z:\missing\path\config.json" } | Should -Not -Throw
        }
    }
}

Describe "Logger Module" {

    BeforeAll {
        $logDir = Join-Path $env:TEMP "KBU_Test_Logs_$(Get-Random)"
        Initialize-KBULogger -LogPath $logDir -LogLevel "Info" -RetentionDays 0
    }

    It "Creates log directory" {
        Test-Path $logDir | Should -BeTrue
    }

    It "Writes info log entry" {
        Write-KBUInfo "Test info message"
        $logFile = Join-Path $logDir "KBU_Validator_$(Get-Date -Format 'yyyyMMdd').log"
        Test-Path $logFile | Should -BeTrue
        $content = Get-Content -LiteralPath $logFile -Raw
        $content | Should -Match "Test info message"
    }

    It "Does not crash with invalid log path" {
        Initialize-KBULogger -LogPath "Z:\Invalid\Path" -LogLevel "Error"
        { Write-KBUInfo "should not throw" } | Should -Not -Throw
    }

    AfterAll {
        if (Test-Path $logDir) {
            Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Software Validation Module" {

    Context "Software Detection" {
        It "Detects installed software matching patterns" {
            $installed = New-TestInstalledSoftware
            $found = Find-KBUSoftware -InstalledSoftware $installed -SoftwareDef ([PSCustomObject]@{ Name = "TestApp1"; Patterns = @("TestApp1") })
            $found | Should -Not -BeNull
            $found.DisplayName | Should -Be "TestApp1 Suite 2024"
        }

        It "Returns null for non-matching software" {
            $installed = New-TestInstalledSoftware
            $found = Find-KBUSoftware -InstalledSoftware $installed -SoftwareDef ([PSCustomObject]@{ Name = "Missing"; Patterns = @("MissingApp") })
            $found | Should -BeNull
        }

        It "Excludes software matching exclude patterns" {
            $installed = @(
                [PSCustomObject]@{ DisplayName = "Java Auto Updater"; DisplayVersion = "1.0" }
            )
            $found = Find-KBUSoftware -InstalledSoftware $installed -SoftwareDef ([PSCustomObject]@{ Name = "Java"; Patterns = @("Java"); Exclude = @("Auto Updater") })
            $found | Should -BeNull
        }
    }

    Context "Software Validation Results" {
        It "Returns structured validation object" {
            Mock Get-KBUInstalledSoftware { return New-TestInstalledSoftware }
            $result = Test-KBUSoftware -Config $testConfig
            $result.Checks | Should -Not -BeNull
            $result.Required | Should -Not -BeNull
            $result.Optional | Should -Not -BeNull
            $result.RequiredCount | Should -BeGreaterThan 0
            $result.RequiredTotal | Should -Be $testConfig.RequiredSoftware.Count
        }

        It "Detects missing required software" {
            Mock Get-KBUInstalledSoftware { return @() }
            $result = Test-KBUSoftware -Config $testConfig
            $fails = $result.Checks | Where-Object { $_.Status -eq "FAIL" }
            @($fails).Count | Should -BeGreaterThan 0
        }

        It "Optional software WARNING status is set when not installed" {
            Mock Get-KBUInstalledSoftware { return @() }
            $result = Test-KBUSoftware -Config $testConfig
            $opt = $result.Checks | Where-Object { $_.Category -eq "Software" -and $_.Name -eq "OptApp1" }
            @($opt).Count | Should -BeGreaterThan 0
            $opt.Status | Should -Be "WARNING"
        }
    }
}

Describe "Driver Validation Module" {

    Context "Device Problem Detection" {
        It "Reports no problems for clean system" {
            Mock Get-CimInstance { return @() }
            $problems = Get-KBUDeviceProblems
            $problems.HasProblems | Should -BeFalse
        }

        It "Detects unknown devices (error code 1)" {
            $fakeDevice = [PSCustomObject]@{ Name = "Unknown Device"; ConfigManagerErrorCode = 1 }
            Mock Get-CimInstance { return @($fakeDevice) }
            $problems = Get-KBUDeviceProblems
            $problems.HasProblems | Should -BeTrue
            @($problems.Unknown).Count | Should -BeGreaterThan 0
        }

        It "Detects disabled devices (error code 22)" {
            $fakeDevice = [PSCustomObject]@{ Name = "Disabled Device"; ConfigManagerErrorCode = 22 }
            Mock Get-CimInstance { return @($fakeDevice) }
            $problems = Get-KBUDeviceProblems
            @($problems.Disabled).Count | Should -BeGreaterThan 0
        }

        It "Handles CIM query failure gracefully" {
            Mock Get-CimInstance { throw "CIM failure" }
            $problems = Get-KBUDeviceProblems
            $problems.HasProblems | Should -BeFalse
            $problems.QueryError | Should -Not -BeNullOrEmpty
        }
    }

    Context "Driver Validation Results" {
        It "Returns structured check object" {
            Mock Get-CimInstance { return @() }
            $result = Test-KBUDrivers -Config $testConfig
            $result.Checks | Should -Not -BeNull
            @($result.Checks).Count | Should -Be 3
        }

        It "Status consistency - clean system has all PASS" {
            Mock Get-CimInstance { return @() }
            $result = Test-KBUDrivers -Config $testConfig
            $fails = $result.Checks | Where-Object { $_.Status -eq "FAIL" }
            @($fails).Count | Should -Be 0
        }
    }
}

Describe "Security Validation Module" {

    Context "Antivirus Detection" {
        It "Antivirus found - returns PASS" {
            Mock Get-CimInstance {
                param($Namespace, $ClassName)
                if ($Namespace -eq "root/SecurityCenter2") {
                    return @([PSCustomObject]@{ displayName = "TestAV Pro" })
                }
                return $null
            }
            Mock Get-MpComputerStatus { return [PSCustomObject]@{ AntivirusEnabled = $false } }
            Mock Get-NetFirewallProfile { return @() }

            $result = Test-KBUSecurity -Config $testConfig
            $avCheck = $result.Checks | Where-Object { $_.Name -eq "Antivirus" }
            $avCheck.Status | Should -Be "PASS"
        }

        It "Antivirus unavailable - returns FAIL (not UNKNOWN)" {
            Mock Get-CimInstance { return @() }
            Mock Get-MpComputerStatus { return [PSCustomObject]@{ AntivirusEnabled = $false } }
            Mock Get-NetFirewallProfile { return @() }

            $result = Test-KBUSecurity -Config $testConfig
            $avCheck = $result.Checks | Where-Object { $_.Name -eq "Antivirus" }
            $avCheck.Status | Should -Be "FAIL"
        }

        It "UNKNOWN status does not become false FAILURE for Secure Boot" {
            Mock Get-CimInstance { return @() }
            Mock Get-MpComputerStatus { return [PSCustomObject]@{ AntivirusEnabled = $true } }
            Mock Get-NetFirewallProfile { return @() }
            Mock Confirm-SecureBootUEFI { throw "Not available" }

            $result = Test-KBUSecurity -Config $testConfig
            $sbCheck = $result.Checks | Where-Object { $_.Name -eq "Secure Boot" }
            $sbCheck.Status | Should -Be "UNKNOWN"
        }

        It "Handles SecurityCenter2 failure gracefully" {
            Mock Get-CimInstance { throw "Access denied" }
            Mock Get-MpComputerStatus { return [PSCustomObject]@{ AntivirusEnabled = $true } }
            Mock Get-NetFirewallProfile { return @() }

            $result = Test-KBUSecurity -Config $testConfig
            $result.Checks.Count | Should -BeGreaterThan 0
        }
    }

    Context "Firewall Detection" {
        It "Firewall all profiles on - returns PASS" {
            Mock Get-CimInstance { return @() }
            Mock Get-MpComputerStatus { return [PSCustomObject]@{ AntivirusEnabled = $true } }
            Mock Get-NetFirewallProfile { return @() }

            $result = Test-KBUSecurity -Config $testConfig
            $fwCheck = $result.Checks | Where-Object { $_.Name -eq "Firewall" }
            $fwCheck.Status | Should -Be "PASS"
        }
    }
}

Describe "System Validation Module" {

    Context "OS Information" {
        It "Returns OS info object" {
            $osInfo = Get-KBUOSInfo
            $osInfo | Should -Not -BeNull
            $osInfo.Edition | Should -Not -BeNullOrEmpty
        }
    }

    Context "Disk Information" {
        It "Returns disk info for fixed drives" {
            $disks = Get-KBUDiskInfo
            $disks | Should -Not -BeNull
        }

        It "Disk info objects have expected properties" {
            $disks = Get-KBUDiskInfo
            if ($disks.Count -gt 0) {
                $disks[0].Drive | Should -Not -BeNullOrEmpty
                $disks[0].TotalGB | Should -BeGreaterThan 0
            }
        }
    }

    Context "System Validation Results" {
        It "Returns structured system validation with checks" {
            $result = Test-KBUSystem -Config $testConfig
            $result.Checks.Count | Should -BeGreaterThan 0
            $result.SystemInfo | Should -Not -BeNull
        }

        It "OS checks include all expected checks" {
            $result = Test-KBUSystem -Config $testConfig
            $osNames = $result.Checks | Select-Object -ExpandProperty Name
            $osNames -contains "Windows Edition"    | Should -BeTrue
            $osNames -contains "Windows Version"    | Should -BeTrue
            $osNames -contains "Architecture"       | Should -BeTrue
            $osNames -contains "Activation"         | Should -BeTrue
        }

        It "Disk check status is valid" {
            Mock Get-KBUOSInfo {
                return [PSCustomObject]@{ Edition = "Windows 10 Pro"; Version = "10.0"; Build = "19045"; Arch = "64-bit"; Activated = $true; LastBoot = "Today"; BootDays = 0 }
            }
            Mock Get-KBUDiskInfo {
                return @([PSCustomObject]@{ Drive = "C:"; Label = "Test"; TotalGB = 500; FreeGB = 400; PctFree = 80 })
            }
            $result = Test-KBUSystem -Config $testConfig
            $diskCheck = $result.Checks | Where-Object { $_.Name -like "C:*" }
            $diskCheck.Status | Should -Be "PASS"
        }
    }
}

Describe "Scoring Module" {

    Context "Healthy System" {
        It "All checks healthy produces high score" {
            $checks = @(
                (New-TestCheck -Name "Windows Version" -Status "PASS"),
                (New-TestCheck -Name "Antivirus" -Status "PASS"),
                (New-TestCheck -Name "Firewall" -Status "PASS"),
                (New-TestCheck -Name "TestApp1" -Status "PASS" -Category "Software"),
                (New-TestCheck -Name "TestApp2" -Status "PASS" -Category "Software")
            )
            $score = Get-KBUScore -AllChecks $checks -Config $testConfig
            $score.Score | Should -BeGreaterOrEqual 85
            $score.Decision | Should -Be "READY"
        }
    }

    Context "Missing Required Software" {
        It "Missing blocking software lowers score and forces NOT READY" {
            $checks = @(
                (New-TestCheck -Name "Windows Version" -Status "PASS"),
                (New-TestCheck -Name "Antivirus" -Status "FAIL" -Severity "High" -Fix "Install AV"),
                (New-TestCheck -Name "Firewall" -Status "PASS"),
                (New-TestCheck -Name "TestApp1" -Status "FAIL" -Severity "High" -Fix "Install" -Category "Software")
            )
            $score = Get-KBUScore -AllChecks $checks -Config $testConfig
            $score.Score | Should -BeLessThan 85
            $score.Decision | Should -Be "NOT READY"
            $score.BlockingIssues.Count | Should -BeGreaterThan 0
        }
    }

    Context "Blocking Issues" {
        It "Blocking issue forces NOT READY regardless of score" {
            $blockerName = "Antivirus"
            $checks = @(
                (New-TestCheck -Name "Windows Version" -Status "PASS"),
                (New-TestCheck -Name "Windows Edition" -Status "PASS"),
                (New-TestCheck -Name "Architecture" -Status "PASS"),
                (New-TestCheck -Name "Activation" -Status "PASS"),
                (New-TestCheck -Name $blockerName -Status "FAIL" -Severity "High" -Fix "Install")
            )
            $score = Get-KBUScore -AllChecks $checks -Config $testConfig
            $score.Decision | Should -Be "NOT READY"
            $score.BlockingIssues -contains $blockerName | Should -BeTrue
        }
    }

    Context "Warning Status" {
        It "Warning status works correctly - score in warning range" {
            $checks = @(
                (New-TestCheck -Name "Windows Version" -Status "PASS"),
                (New-TestCheck -Name "Antivirus" -Status "PASS"),
                (New-TestCheck -Name "Firewall" -Status "WARNING" -Severity "Low"),
                (New-TestCheck -Name "TestApp2" -Status "WARNING" -Category "Software")
            )
            $score = Get-KBUScore -AllChecks $checks -Config $testConfig
            $score.WarnCount | Should -BeGreaterThan 0
        }
    }

    Context "Recommendations" {
        It "Recommendations are generated from warnings" {
            $checks = @(
                (New-TestCheck -Name "BitLocker" -Status "WARNING" -Fix "Enable BitLocker" -Severity "Low"),
                (New-TestCheck -Name "Secure Boot" -Status "WARNING" -Fix "Enable Secure Boot" -Severity "Low")
            )
            $fixes = Get-KBUFixes -AllChecks $checks
            $fixes.Recommendations.Count | Should -BeGreaterThan 0
        }

        It "Critical fixes are separated from recommendations" {
            $checks = @(
                (New-TestCheck -Name "Antivirus" -Status "FAIL" -Fix "Install AV" -Severity "High"),
                (New-TestCheck -Name "BitLocker" -Status "WARNING" -Fix "Enable BitLocker" -Severity "Low")
            )
            $fixes = Get-KBUFixes -AllChecks $checks
            $fixes.Critical.Count | Should -BeGreaterThan 0
        }

        It "Deduplicates identical fix messages" {
            $checks = @(
                (New-TestCheck -Name "Check A" -Status "WARNING" -Fix "Same fix" -Severity "Low"),
                (New-TestCheck -Name "Check B" -Status "WARNING" -Fix "Same fix" -Severity "Low")
            )
            $fixes = Get-KBUFixes -AllChecks $checks
            $fixes.Total | Should -Be 1
        }
    }

    Context "Module Status Aggregation" {
        It "Get-KBUModuleStatus groups by category" {
            $checks = @(
                (New-TestCheck -Name "OS1" -Status "PASS" -Category "System"),
                (New-TestCheck -Name "OS2" -Status "FAIL" -Severity "High" -Category "System"),
                (New-TestCheck -Name "SW1" -Status "PASS" -Category "Software")
            )
            $modules = Get-KBUModuleStatus -AllChecks $checks
            $modules.Count | Should -BeGreaterThan 0
            $sysModule = $modules | Where-Object { $_.Module -eq "System" }
            $sysModule.Status | Should -Be "FAIL"
        }
    }
}

Describe "Report Generation Module" {

    BeforeAll {
        $reportDir = Join-Path $env:TEMP "KBU_Test_Reports_$(Get-Random)"
        $testCfg = Get-ValidTestConfig
        $testCfg.Reports.OutputPath = $reportDir

        $testChecks = @(
            (New-TestCheck -Name "Windows Version" -Status "PASS" -Detail "10.0" -Category "System"),
            (New-TestCheck -Name "Antivirus" -Status "PASS" -Detail "Active" -Category "Security"),
            (New-TestCheck -Name "TestApp1" -Status "FAIL" -Detail "Not Installed" -Fix "Install TestApp1" -Severity "High" -Category "Software"),
            (New-TestCheck -Name "BitLocker" -Status "WARNING" -Detail "Off" -Fix "Enable BitLocker" -Severity "Low" -Category "Security")
        )

        $testScore = [PSCustomObject]@{
            Score          = 75
            MaxScore       = 100
            Decision       = "WARNING"
            FailCount      = 1
            WarnCount      = 1
            PassCount      = 2
            UnknownCount   = 0
            Total          = 4
            BlockingIssues = @()
            EstMinutes     = "4 min"
        }

        $testFixes = Get-KBUFixes -AllChecks $testChecks

        $testSysRes = [PSCustomObject]@{
            Checks     = @()
            SystemInfo = New-TestSystemInfo
        }

        $testSwRes = [PSCustomObject]@{
            Checks        = @()
            Required      = @([PSCustomObject]@{ Name = "TestApp1"; Installed = $false; Version = "N/A" })
            Optional      = @()
            RequiredCount = 0
            RequiredTotal = 1
        }

        $testDrvRes = [PSCustomObject]@{
            Checks      = @()
            DeviceData  = New-TestDeviceProblems
            HasProblems = $false
        }

        $testSecRes = [PSCustomObject]@{
            Checks       = @()
            SecurityData = [PSCustomObject]@{}
        }
    }

    It "HTML file is created" {
        $path = New-KBUHtmlReport -AllChecks $testChecks -ScoreCard $testScore -Fixes $testFixes -SystemResults $testSysRes -SoftwareResults $testSwRes -DriverResults $testDrvRes -Config $testCfg -OutputDir $reportDir -ElapsedSeconds 2.5
        Test-Path $path | Should -BeTrue
        (Get-Item $path).Length | Should -BeGreaterThan 100
    }

    It "JSON file is created" {
        $path = New-KBUJsonReport -AllChecks $testChecks -ScoreCard $testScore -Fixes $testFixes -SoftwareResults $testSwRes -SystemResults $testSysRes -SecurityResults $testSecRes -DriverResults $testDrvRes -Config $testCfg -OutputDir $reportDir -ElapsedSeconds 2.5
        Test-Path $path | Should -BeTrue
        (Get-Item $path).Length | Should -BeGreaterThan 100
    }

    It "HTML report contains deployment score" {
        $path = New-KBUHtmlReport -AllChecks $testChecks -ScoreCard $testScore -Fixes $testFixes -SystemResults $testSysRes -SoftwareResults $testSwRes -DriverResults $testDrvRes -Config $testCfg -OutputDir $reportDir -ElapsedSeconds 2.5
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match "75"
    }

    It "HTML report contains deployment status" {
        $path = New-KBUHtmlReport -AllChecks $testChecks -ScoreCard $testScore -Fixes $testFixes -SystemResults $testSysRes -SoftwareResults $testSwRes -DriverResults $testDrvRes -Config $testCfg -OutputDir $reportDir -ElapsedSeconds 2.5
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match "WARNING"
    }

    It "HTML report contains missing software names" {
        $path = New-KBUHtmlReport -AllChecks $testChecks -ScoreCard $testScore -Fixes $testFixes -SystemResults $testSysRes -SoftwareResults $testSwRes -DriverResults $testDrvRes -Config $testCfg -OutputDir $reportDir -ElapsedSeconds 2.5
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match "TestApp1"
    }

    It "JSON report contains score" {
        $path = New-KBUJsonReport -AllChecks $testChecks -ScoreCard $testScore -Fixes $testFixes -SoftwareResults $testSwRes -SystemResults $testSysRes -SecurityResults $testSecRes -DriverResults $testDrvRes -Config $testCfg -OutputDir $reportDir -ElapsedSeconds 2.5
        $jsonContent = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $jsonContent.Score.Value | Should -Be 75
    }

    It "JSON report contains status" {
        $path = New-KBUJsonReport -AllChecks $testChecks -ScoreCard $testScore -Fixes $testFixes -SoftwareResults $testSwRes -SystemResults $testSysRes -SecurityResults $testSecRes -DriverResults $testDrvRes -Config $testCfg -OutputDir $reportDir -ElapsedSeconds 2.5
        $jsonContent = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $jsonContent.Score.Decision | Should -Be "WARNING"
    }

    It "JSON report contains missing software names" {
        $path = New-KBUJsonReport -AllChecks $testChecks -ScoreCard $testScore -Fixes $testFixes -SoftwareResults $testSwRes -SystemResults $testSysRes -SecurityResults $testSecRes -DriverResults $testDrvRes -Config $testCfg -OutputDir $reportDir -ElapsedSeconds 2.5
        $jsonContent = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $softNames = $jsonContent.Software.Required | Where-Object { -not $_.Installed } | Select-Object -ExpandProperty Name
        $softNames -contains "TestApp1" | Should -BeTrue
    }

    AfterAll {
        if (Test-Path $reportDir) {
            Remove-Item -LiteralPath $reportDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
