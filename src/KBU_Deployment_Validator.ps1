<#
.SYNOPSIS
    KBU Deployment Validator — Main Entry Point

.DESCRIPTION
    Orchestrates the validation workflow:
    1. Load configuration
    2. Initialize logging
    3. Run validation modules (System, Software, Drivers, Security)
    4. Calculate deployment readiness score
    5. Generate HTML and JSON reports
    6. Display console summary

.NOTES
    Author:  Karabuk University IT Department
    Version: 1.2.0
    License: MIT
    READ-ONLY — No system modifications are made.
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$ReportPath
)

$Script:StartTime = Get-Date
$Script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Load module functions
$moduleFiles = @(
    "Config.ps1",
    "Logger.ps1",
    "SoftwareValidation.ps1",
    "DriverValidation.ps1",
    "SecurityValidation.ps1",
    "SystemValidation.ps1",
    "Scoring.ps1",
    "ReportRenderer.ps1"
)

foreach ($modFile in $moduleFiles) {
    $modPath = Join-Path $Script:ScriptDir $modFile
    if (Test-Path -LiteralPath $modPath) {
        . $modPath
        Write-KBUDebug "Loaded module: $modFile"
    }
    else {
        Write-Warning "Module not found: $modFile"
    }
}

function Write-KBUBanner {
    $cfg = $Script:CurrentConfig

    Clear-Host
    Write-Host ""
    Write-Host "  $($cfg.Tool.Name) v$($cfg.Tool.Version)" -ForegroundColor Cyan
    Write-Host "  $($cfg.Branding.Organization) $($cfg.Branding.Department)" -ForegroundColor DarkGray
    Write-Host "  PC: $($env:COMPUTERNAME)  |  Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host "  READ-ONLY -- No system changes are made." -ForegroundColor Green
    Write-Host ""
}

function Main {
    $ErrorActionPreference = "Continue"
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    Write-Host "  Loading configuration..." -ForegroundColor Cyan

    $configResult = Get-KBUConfig -ConfigPath $ConfigPath
    if (-not $configResult.Valid) {
        Write-Host "  WARNING: $($configResult.Error)" -ForegroundColor Yellow
        Write-Host "  Using default configuration." -ForegroundColor Yellow
        $Script:CurrentConfig = Get-DefaultKBUConfig
    }
    else {
        $Script:CurrentConfig = $configResult.Config
    }

    $cfg = $Script:CurrentConfig

    Initialize-KBULogger -LogPath $cfg.Logging.LogPath `
                         -LogLevel $cfg.Logging.LogLevel `
                         -RetentionDays $cfg.Logging.RetentionDays

    Write-KBUInfo "=== $($cfg.Tool.Name) v$($cfg.Tool.Version) started ==="
    Write-KBUInfo "Computer: $env:COMPUTERNAME, User: $env:USERNAME"

    Write-Host "  Running validation checks..." -ForegroundColor Cyan

    $allChecks  = @()
    $systemRes  = @{}
    $swRes      = @{}
    $drvRes     = @{}
    $secRes     = @{}

    Write-KBUBanner

    Write-Host "  [1/4] System validation..." -ForegroundColor Cyan
    try {
        $systemRes = Test-KBUSystem -Config $cfg
        $allChecks += $systemRes.Checks
    }
    catch {
        Write-KBUError "System validation failed: $($_.Exception.Message)"
    }

    Write-Host "  [2/4] Software validation..." -ForegroundColor Cyan
    try {
        $swRes = Test-KBUSoftware -Config $cfg
        $allChecks += $swRes.Checks
    }
    catch {
        Write-KBUError "Software validation failed: $($_.Exception.Message)"
    }

    Write-Host "  [3/4] Driver validation..." -ForegroundColor Cyan
    try {
        $drvRes = Test-KBUDrivers -Config $cfg
        $allChecks += $drvRes.Checks
    }
    catch {
        Write-KBUError "Driver validation failed: $($_.Exception.Message)"
    }

    Write-Host "  [4/4] Security validation..." -ForegroundColor Cyan
    try {
        $secRes = Test-KBUSecurity -Config $cfg
        $allChecks += $secRes.Checks
    }
    catch {
        Write-KBUError "Security validation failed: $($_.Exception.Message)"
    }

    Write-Host "  Calculating deployment score..." -ForegroundColor Cyan
    $scoreCard = Get-KBUScore -AllChecks $allChecks -Config $cfg
    $fixes     = Get-KBUFixes -AllChecks $allChecks

    $elapsed = [math]::Round(((Get-Date) - $Script:StartTime).TotalSeconds, 1)

    $outputDir = $cfg.Reports.OutputPath
    if ($ReportPath) {
        $outputDir = $ReportPath
    }

    Write-Host "  Generating reports..." -ForegroundColor Cyan
    $htmlPath = $null
    $jsonPath = $null

    try {
        if ($cfg.Reports.IncludeHtml) {
            $htmlPath = New-KBUHtmlReport -AllChecks $allChecks -ScoreCard $scoreCard `
                -Fixes $fixes -SystemResults $systemRes -SoftwareResults $swRes `
                -DriverResults $drvRes -Config $cfg -OutputDir $outputDir `
                -ElapsedSeconds $elapsed
        }
        if ($cfg.Reports.IncludeJson) {
            $jsonPath = New-KBUJsonReport -AllChecks $allChecks -ScoreCard $scoreCard `
                -Fixes $fixes -SoftwareResults $swRes -SystemResults $systemRes `
                -SecurityResults $secRes -DriverResults $drvRes -Config $cfg `
                -OutputDir $outputDir -ElapsedSeconds $elapsed
        }
    }
    catch {
        Write-KBUError "Report generation failed: $($_.Exception.Message)"
    }

    $scoreColor = if ($scoreCard.Decision -eq $Script:DecisionReady) { "Green" }
                  elseif ($scoreCard.Decision -eq $Script:DecisionWarning) { "Yellow" }
                  else { "Red" }

    Write-Host ""
    Write-Host "  ========================================" -ForegroundColor DarkGray
    Write-Host "  Score: $($scoreCard.Score)/$($scoreCard.MaxScore)  |  $($scoreCard.Decision)" -ForegroundColor $scoreColor
    Write-Host "  ========================================" -ForegroundColor DarkGray
    Write-Host "  Pass: $($scoreCard.PassCount)  |  Warn: $($scoreCard.WarnCount)  |  Fail: $($scoreCard.FailCount)  |  Unknown: $($scoreCard.UnknownCount)" -ForegroundColor Gray
    Write-Host "  Est. Fix Time: $($scoreCard.EstMinutes)" -ForegroundColor DarkGray
    Write-Host ""

    if ($scoreCard.FailCount -gt 0) {
        Write-Host "  Blocking Issues:" -ForegroundColor Red
        $blockingChecks = $allChecks | Where-Object { $_.Status -eq $Script:StatusFail -and $_.Severity -eq "High" }
        if ($blockingChecks) {
            $blockingChecks | ForEach-Object {
                Write-Host "    X  $($_.Name) -- $($_.Detail)" -ForegroundColor Red
            }
        }
        $otherFails = $allChecks | Where-Object { $_.Status -eq $Script:StatusFail -and $_.Severity -ne "High" }
        if ($otherFails) {
            Write-Host ""
            Write-Host "  Other Issues:" -ForegroundColor Yellow
            $otherFails | ForEach-Object {
                Write-Host "    !  $($_.Name) -- $($_.Detail)" -ForegroundColor Yellow
            }
        }
    }

    $warnings = $allChecks | Where-Object { $_.Status -eq $Script:StatusWarning }
    if ($warnings) {
        Write-Host ""
        Write-Host "  Warnings:" -ForegroundColor Yellow
        $warnings | ForEach-Object {
            Write-Host "    ~  $($_.Name) -- $($_.Detail)" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    if ($htmlPath) {
        Write-Host "  HTML Report: $htmlPath" -ForegroundColor Green
    }
    if ($jsonPath) {
        Write-Host "  JSON Report: $jsonPath" -ForegroundColor Green
    }
    Write-Host "  Duration: ${elapsed}s" -ForegroundColor Gray

    if ($cfg.Reports.OpenInBrowser -and $htmlPath) {
        Start-Process -FilePath $htmlPath -ErrorAction SilentlyContinue
        Write-Host "  Opening in browser..." -ForegroundColor Gray
    }

    Write-Host ""
    Write-KBUInfo "=== Validation completed in ${elapsed}s, Decision: $($scoreCard.Decision) ==="

    if ($scoreCard.FailCount -gt 0) {
        Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

Main
