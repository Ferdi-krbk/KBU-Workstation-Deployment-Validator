# Testing Documentation — KBU Deployment Validator

## Overview

This document describes the testing strategy and methodology for the KBU Deployment Validator project.

## Test Framework

- **Pester 5.x** is used for automated testing.
- Pester is **only required for development/testing** — the validator tool itself does not require Pester to run.
- Install Pester: `Install-Module -Name Pester -Force -SkipPublisherCheck`

## Running Tests

```powershell
# Navigate to tests directory
cd tests

# Run all tests with detailed output
Invoke-Pester -Output Detailed

# Run a specific test group
Invoke-Pester -Output Detailed -Tag "Software"

# Run tests and generate NUnit XML report
Invoke-Pester -OutputFile test-results.xml -OutputFormat NUnitXml
```

## Test Categories

### Unit Tests

The test suite covers the following modules:

| Module                 | Test File      | What is Tested                                    |
|------------------------|----------------|---------------------------------------------------|
| Config                 | Config.ps1     | Valid/invalid config loading, default fallbacks   |
| Logger                 | Logger.ps1     | Log directory creation, message writing           |
| Software Validation    | SoftwareValidation.ps1 | Pattern matching, missing software detection |
| Driver Validation      | DriverValidation.ps1  | Problem device detection, error classification |
| Security Validation    | SecurityValidation.ps1 | AV detection, UNKNOWN status handling     |
| System Validation      | SystemValidation.ps1  | OS checks, disk space validation           |
| Scoring                | Scoring.ps1    | Weighted scoring, blocking issues, decisions      |
| Report Generation      | ReportRenderer.ps1   | HTML/JSON output, content verification     |

### Mocked Windows Components

To ensure tests are safe, reproducible, and do not require admin rights, the following Windows components are **mocked**:

| Component                  | Why Mocked                                        |
|----------------------------|---------------------------------------------------|
| `Get-CimInstance`          | Prevents real WMI/CIM queries on test machine     |
| `Get-ItemProperty` (Registry) | Prevents reading actual machine registry       |
| `Get-MpComputerStatus`     | Avoids Defender status dependency                 |
| `Confirm-SecureBootUEFI`   | May require UEFI firmware access                  |
| `Get-Tpm`                  | May require admin rights                          |
| `Get-BitLockerVolume`      | May require admin rights                          |
| `Get-NetFirewallProfile`   | Prevents real firewall status queries             |

### Why Hardware/Security Checks Are Mocked

1. **No Admin Rights Required** — Many security checks (TPM, BitLocker, Secure Boot) require elevated privileges. Tests must run without admin access.
2. **Cross-Machine Reproducibility** — Test results should be identical regardless of the machine they run on.
3. **No Side Effects** — Tests must not modify the system or real registry in any way.
4. **Fast Execution** — WMI/CIM queries can be slow; mocking ensures tests complete in milliseconds.

### Real System Checks That Run

These system queries run directly (they do not require admin rights and are safe):

- `Get-KBUOSInfo` — Queries `Win32_OperatingSystem` (read-only, always available)
- `Get-KBUDiskInfo` — Queries `Win32_LogicalDisk` (read-only, always available)
- `Get-KBUSystemInfo` — Wraps OS and disk queries

## Manual Validation Process

While automated tests verify the logic of each module, the following manual validation steps are recommended before deploying the tool:

1. **Run on a known-good workstation** — All checks should PASS.
2. **Run on a "broken" workstation** — Blocking issues should be detected.
3. **Run without admin rights** — Security UNKNOWN statuses should be handled gracefully.
4. **Check HTML report** — Should open in browser and display correctly.
5. **Check JSON report** — Should be valid JSON with all expected fields.
6. **Modify `config.json`** — Verify software list changes are reflected in output.

## PowerShell 5.1 Runtime Compatibility

- The validator and tests use **only PowerShell 5.1 compatible syntax**.
- Pester 5.x supports PowerShell 5.1.
- Features exclusive to PowerShell 7 (ternary operator `?:`, `ForEach-Object -Parallel`, null-coalescing `??`) are **not used**.

## Test Environment Cleanup

Tests use `$env:TEMP` for temporary directories and clean up after themselves in `AfterAll` blocks. No test artifacts should remain after execution.

## Adding New Tests

When adding new validation checks or modules:

1. Add test cases to `validator.tests.ps1` in the appropriate `Describe` block.
2. Use `Mock` for any function that queries the real system.
3. Use `New-TestCheck` helper from `TestConfig.ps1` for check objects.
4. Ensure `AfterAll` cleans up any temporary files.
5. Run the full test suite to verify no regressions.
