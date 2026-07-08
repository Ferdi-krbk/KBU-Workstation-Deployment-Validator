<p align="center">
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=for-the-badge&logo=powershell&logoColor=white" alt="PowerShell">
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6?style=for-the-badge&logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge" alt="License">
  <img src="https://img.shields.io/badge/Version-1.2.0-blue?style=for-the-badge" alt="Version">
  <img src="https://img.shields.io/badge/Pester-5.x-5EAD4C?style=for-the-badge" alt="Pester">
</p>

<h1 align="center">KBU Deployment Validator</h1>

<p align="center">
  <strong>Windows Workstation Deployment Readiness Validation Tool</strong><br>
  <em>Answers one question: Can this workstation be deployed to the end user?</em>
</p>

---

## Overview

KBU Deployment Validator is a **read-only** PowerShell tool that validates whether a Windows workstation is ready for deployment after OS installation, software provisioning, and configuration.

It is designed for university and enterprise IT departments that deploy standardized workstations and need a fast, consistent way to verify readiness before delivery.

**This tool does NOT modify, install, delete, or configure anything on the system.**

---

## Features

### Core Validation

| Module     | What It Checks                                                  |
|------------|----------------------------------------------------------------|
| **System**     | Windows edition, version, build, architecture, activation, uptime, disk space |
| **Software**   | Required applications (Office, Java, remote tools, browsers), optional software |
| **Drivers**    | Unknown devices, disabled devices, driver errors with severity classification |
| **Security**   | Antivirus (Defender + third-party), firewall, BitLocker, Secure Boot, TPM |

### Reporting & Scoring

- **Weighted Deployment Score (0–100)** — Configurable scoring system
- **Final Decision** — `READY` / `WARNING` / `NOT READY` with blocking issue detection
- **HTML Dashboard** — Professional dark-themed report with score visualization
- **JSON Report** — Machine-readable structured output for integration
- **Required Actions** — Categorized as Critical, Warnings, Recommendations
- **Console Summary** — Immediate results with blocking issues highlighted
- **Print Support** — Built-in print button in HTML report
- **Read-Only** — Zero system modifications

---

## Architecture

```
KBU-Deployment-Validator/
│
├── src/                                 # Source code (modular)
│   ├── KBU_Deployment_Validator.ps1     # Main entry point
│   ├── Config.ps1                       # Config loader and validator
│   ├── Logger.ps1                       # File-based logging
│   ├── SoftwareValidation.ps1           # Registry software checks
│   ├── DriverValidation.ps1             # Device manager checks
│   ├── SecurityValidation.ps1           # Security status checks
│   ├── SystemValidation.ps1             # OS and disk checks
│   ├── Scoring.ps1                      # Weighted scoring engine
│   └── ReportRenderer.ps1               # HTML and JSON report generation
│
├── tests/                               # Test suite
│   ├── validator.tests.ps1              # Pester 5.x tests (35+ tests)
│   ├── TestConfig.ps1                   # Test helpers and mocks
│   └── TESTING.md                       # Testing documentation
│
├── config.json                          # Configuration file
├── run_validator.bat                    # Double-click launcher
├── CHANGELOG.md                         # Version history
├── README.md                            # Project documentation
├── LICENSE                              # MIT License
├── .gitignore                           # Git ignore rules
│
├── docs/                                # Screenshots (legacy)
├── screenshots/                         # Screenshots directory
├── reports/                             # Generated reports (gitignored)
└── logs/                                # Log files (gitignored)
```

### Workflow

```
Deployment Tool installs software/image on workstation
  → Inventory Tool collects hardware/software data
    → Validator Tool checks deployment readiness
      → Reports: READY / WARNING / NOT READY
```

---

## Requirements

| Requirement            | Details                              |
|------------------------|--------------------------------------|
| Operating System       | Windows 10 / Windows 11              |
| PowerShell             | 5.1 or later (built into Windows)    |
| Permissions            | Standard user (admin recommended*)   |
| Network                | Not required (offline-capable)       |
| Dependencies           | None — all modules are built in      |

> *Some security checks (BitLocker, TPM, Secure Boot) return more detail with elevated privileges. The tool gracefully returns `UNKNOWN` when data is unavailable.

---

## How to Run

### Double-Click

Simply double-click `run_validator.bat` in the project folder.

### Command Line

```powershell
# Navigate to the project folder and run:
powershell.exe -ExecutionPolicy Bypass -File .\src\KBU_Deployment_Validator.ps1

# With custom config path:
powershell.exe -ExecutionPolicy Bypass -File .\src\KBU_Deployment_Validator.ps1 -ConfigPath "C:\custom\config.json"

# With custom report output directory:
powershell.exe -ExecutionPolicy Bypass -File .\src\KBU_Deployment_Validator.ps1 -ReportPath "C:\Reports"
```

### Output

- **Console**: Summary with score, decision, blocking issues, and warnings
- **HTML Report**: Full dashboard in `reports/` directory, auto-opens in browser
- **JSON Report**: Structured data in `reports/` directory
- **Log File**: Detailed operation log in `logs/` directory

---

## How to Configure

Edit `config.json` to customize the validator for your environment:

```json
{
  "Tool": { "Name": "KBU Deployment Validator", "Version": "1.2.0" },
  "RequiredSoftware": [
    { "Name": "Microsoft Office", "Patterns": ["Microsoft Office", "Microsoft 365"], "Blocking": true },
    { "Name": "Java Runtime", "Patterns": ["Java"], "Exclude": ["Auto Updater"], "Blocking": true }
  ],
  "Scoring": {
    "PassingThreshold": 85,
    "WarningThreshold": 65,
    "BlockingSoftware": ["Microsoft Office", "Java Runtime", "Akia", "Antivirus"]
  },
  "Thresholds": {
    "DiskFreePercentWarning": 20,
    "DiskFreePercentCritical": 10
  }
}
```

### Key Configuration Sections

| Section              | Purpose                                          |
|----------------------|--------------------------------------------------|
| `RequiredSoftware`   | List of applications that must be installed. `Blocking: true` = deployment blocked if missing. |
| `OptionalSoftware`   | Applications that are desirable but not required. |
| `Scoring.Weights`    | Penalty weights for each failed check.           |
| `Scoring.BlockingSoftware` | Names of checks that force NOT READY status. |
| `Thresholds`         | Disk space, build number, uptime thresholds.     |
| `Reports`            | Output path, report format flags.                |
| `Logging`            | Log directory, level, and retention period.      |

---

## How to Run Tests

Pester 5.x is required for development/testing only.

```powershell
# Install Pester (one-time)
Install-Module -Name Pester -Force -SkipPublisherCheck

# Navigate to tests directory
cd tests

# Run all tests
Invoke-Pester -Output Detailed

# Run a specific test group
Invoke-Pester -Output Detailed -Tag "Software"

# Run with CI-friendly output
Invoke-Pester -Output Detailed -CI
```

See [tests/TESTING.md](tests/TESTING.md) for detailed testing documentation.

---

## Deployment Decision Criteria

| Decision | Score   | Blockers | Meaning                              |
|----------|---------|----------|--------------------------------------|
| **READY**   | ≥ 85    | 0        | No issues — deploy immediately       |
| **WARNING** | ≥ 65    | 0        | Minor issues — review recommended    |
| **NOT READY** | Any  | ≥ 1      | Critical blockers — do not deploy    |
| **NOT READY** | < 65  | Any      | Score too low — do not deploy        |

---

## Example Output

### Console
```
  KBU Deployment Validator v1.2.0
  Karabuk University IT Department
  PC: DESKTOP-ABC123  |  Date: 2026-07-02 14:00:00

  [1/4] System validation...
  [2/4] Software validation...
  [3/4] Driver validation...
  [4/4] Security validation...

  ========================================
  Score: 92/100  |  READY
  ========================================
  Pass: 18  |  Warn: 2  |  Fail: 0  |  Unknown: 1

  HTML Report: reports\KBU_Validation_20260702-140005.html
  JSON Report: reports\KBU_Validation_20260702-140005.json
  Duration: 3.2s
```

### HTML Report
The HTML dashboard shows the deployment score as a circular gauge, per-module check results, disk space visualization, and required actions grouped by severity.

### JSON Report
The JSON report contains the full validation dataset including check results, system info, software status, security status, and driver data — suitable for ingestion into asset management systems.

---

## Limitations

- **Read-Only** — The tool does not fix issues, only reports them.
- **Windows Only** — Designed exclusively for Windows 10/11.
- **Local Machine Only** — Cannot validate remote workstations.
- **Security Checks** — Some checks depend on SecurityCenter2 availability and may return UNKNOWN on certain Windows editions.
- **Software Detection** — Relies on registry uninstall entries; portable applications are not detected.
- **No Network Tests** — Does not test network connectivity or domain join status.

---

## Screenshots

See the `screenshots/` and `docs/` directories for example reports.

Standard sections in the HTML report include:
- Hero section with deployment score gauge
- Operating System validation details
- Software installation status (required + optional)
- Driver status with problem device listing
- Security status (AV, firewall, BitLocker, Secure Boot, TPM)
- Disk space visualization with progress bars
- Required actions grouped by severity
- Deployment summary with per-module pass/warn/fail counts

---

## Internship Relevance

This project was developed as part of a second-year Software Engineering internship at Karabuk University IT Department.

### Skills Demonstrated

| Skill Area             | Application in This Project                           |
|------------------------|-------------------------------------------------------|
| **Modular Design**     | 8 focused modules with clear responsibilities         |
| **Configuration Management** | JSON-driven config with validation and defaults |
| **Error Handling**     | Graceful degradation, UNKNOWN fallbacks, no crashes   |
| **Automated Testing**  | 35+ Pester 5 tests with mocking for system components |
| **Technical Writing**  | README, TESTING.md, CHANGELOG.md, comment-based help  |
| **PowerShell**         | CIM/WMI queries, registry access, structured objects  |
| **Report Generation**  | HTML/CSS dashboard, JSON export for integration       |
| **Version Control**    | Git with meaningful commits and releases              |
| **Real-World Impact**  | Tool is used in production at Karabuk University IT   |

---

## Contributing

Contributions are welcome. Please ensure:

- All changes are **read-only** — the tool must never modify system state
- PowerShell 5.1 compatibility is maintained (no PS 7+ exclusive features)
- HTML output remains self-contained (no external CDN dependencies)
- All new features include Pester tests
- Report generation stays under 5 seconds on typical hardware

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

---

<p align="center">
  <strong>Karabuk University IT Department</strong><br>
  <sub>Read-Only Tool — No system modifications are made.</sub>
</p>
