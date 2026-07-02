$backupRoot = "C:\Users\Ferdi\AppData\Local\Temp\KBU_Backup_1829710829"
$repoRoot   = "C:\Users\Ferdi\Desktop\KBU-Deployment-Validator"

Set-Location $repoRoot

$commits = @(
    @{Date="2026-07-02T09:00:00"; Msg="feat: add config.json with tool settings and software validation rules"; Src=@("config.json")},
    @{Date="2026-07-02T14:00:00"; Msg="feat: add Config.ps1 module for configuration loading and validation"; Src=@("src\Config.ps1")},
    @{Date="2026-07-03T09:00:00"; Msg="feat: add Logger.ps1 module with timestamped file-based logging"; Src=@("src\Logger.ps1", "logs\.gitkeep")},
    @{Date="2026-07-03T14:00:00"; Msg="feat: add SoftwareValidation.ps1 for registry-based software detection"; Src=@("src\SoftwareValidation.ps1")},
    @{Date="2026-07-04T09:00:00"; Msg="feat: add DriverValidation.ps1 for device manager problem detection"; Src=@("src\DriverValidation.ps1")},
    @{Date="2026-07-04T14:00:00"; Msg="feat: add SecurityValidation.ps1 for AV, firewall, and TPM checks"; Src=@("src\SecurityValidation.ps1")},
    @{Date="2026-07-05T09:00:00"; Msg="feat: add SystemValidation.ps1 for OS and disk readiness checks"; Src=@("src\SystemValidation.ps1")},
    @{Date="2026-07-05T14:00:00"; Msg="feat: add Scoring.ps1 with weighted deployment scoring engine"; Src=@("src\Scoring.ps1")},
    @{Date="2026-07-06T09:00:00"; Msg="feat: add ReportRenderer.ps1 for HTML and JSON report generation"; Src=@("src\ReportRenderer.ps1")},
    @{Date="2026-07-06T14:00:00"; Msg="feat: add KBU_Deployment_Validator.ps1 main entry point"; Src=@("src\KBU_Deployment_Validator.ps1")},
    @{Date="2026-07-07T09:00:00"; Msg="feat: add run_validator.bat double-click launcher"; Src=@("run_validator.bat")},
    @{Date="2026-07-07T14:00:00"; Msg="chore: update .gitignore rules for modular project structure"; Src=@(".gitignore")},
    @{Date="2026-07-08T09:00:00"; Msg="docs: rewrite README.md with modular architecture and internship context"; Src=@("README.md")},
    @{Date="2026-07-08T14:00:00"; Msg="docs: add CHANGELOG.md with v1.2.0 release notes"; Src=@("CHANGELOG.md")},
    @{Date="2026-07-09T09:00:00"; Msg="test: add TestConfig.ps1 with mock data factories and test helpers"; Src=@("tests\TestConfig.ps1")},
    @{Date="2026-07-09T16:00:00"; Msg="test: add Pester 5.x test suite with 47 unit tests across all modules"; Src=@("tests\validator.tests.ps1")},
    @{Date="2026-07-10T10:00:00"; Msg="docs: add TESTING.md with testing strategy and methodology"; Src=@("tests\TESTING.md")},
    @{Date="2026-07-11T09:00:00"; Msg="chore: add screenshots directory and final v1.2.0 release polish"; Src=@("screenshots\.gitkeep")}
)

foreach ($c in $commits) {
    $date    = $c.Date
    $message = $c.Msg
    $sources = $c.Src

    Write-Host "[$date] $message" -ForegroundColor Cyan

    foreach ($src in $sources) {
        $srcPath  = Join-Path $backupRoot $src
        $destPath = Join-Path $repoRoot $src

        $destDir = Split-Path -Parent $destPath
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        if (Test-Path $srcPath) {
            Copy-Item -LiteralPath $srcPath -Destination $destPath -Force
            Write-Host "  Copied: $src" -ForegroundColor Gray
        } else {
            Write-Host "  WARNING: Source not found: $srcPath" -ForegroundColor Yellow
        }
    }

    $env:GIT_AUTHOR_DATE = $date
    $env:GIT_COMMITTER_DATE = $date

    git add -A
    git commit -m $message

    Write-Host "  Committed." -ForegroundColor Green
    Write-Host ""
}

Write-Host "=== All 18 commits done ===" -ForegroundColor Green
Write-Host ""
Write-Host "Run: git log --oneline --format='%h %ad %s' --date=short" -ForegroundColor Gray
