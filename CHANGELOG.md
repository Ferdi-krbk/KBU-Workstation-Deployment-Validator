# Changelog

All notable changes to the KBU Deployment Validator project.

## v1.2.1 — 2026-07-02

### Fixed
- **Module loading order** — Logger.ps1 now loads before all other modules, preventing undefined function calls
- **Scoring weight key mismatch** — Added `WeightKey` property to all check objects; `Get-KBUScore` now resolves weights via normalized key lookup so configured weights in `config.json` apply correctly
- **Security UNKNOWN logic** — Added `AVDataAvailable`, `FirewallDataAvailable`, `DefenderDataAvailable` flags to `Get-KBUSecurityData`; antivirus and firewall return `UNKNOWN` instead of `FAIL` when data is truly unavailable
- **Uptime BootDays bug** — Fixed `if ($os.BootDays -and $os.BootDays -ge 0)` which treated `BootDays = 0` as falsy, causing 999-day fallback. Changed to `$null -ne` guard
- **Safe OS version/build parsing** — Gracefully handles `"Unknown"` version strings with `try/catch` fallback

### Changed
- **Archived legacy files** — Moved `DeploymentValidator.ps1` and `Run_KBU_Validation.bat` to `legacy/` directory
- **README production claim** — Replaced unverified production claim with "Designed and tested for" wording
- **Test count updated** — Corrected from "35+" to "45+" across README and docs

### Added
- **Stronger scoring tests** — Added Pester tests proving blocking issues force NOT READY, UNKNOWN checks do not create blockers, and warning checks reduce score without forcing NOT READY
- **WeightKey test coverage** — Tests verifying `"Windows Version"`, `"Secure Boot"`, and `"Unknown Devices"` resolve to correct configured weights

## v1.2.0 — 2026-07-02

### Added
- **Modular validation architecture** — Split monolithic script into 8 focused modules under `src/`
- **Configuration-based software checks** — `config.json` drives required/optional software lists, scoring weights, and thresholds
- **Driver validation** — Device Manager problem detection with severity classification
- **Security validation** — Antivirus, firewall, BitLocker, Secure Boot, and TPM checks with UNKNOWN fallback
- **System readiness validation** — OS edition, version, build, architecture, activation, uptime, and disk space checks
- **Weighted deployment scoring** — Configurable weights and blocking issue detection
- **HTML report generation** — Professional dark-themed dashboard with score, charts, and action items
- **JSON report generation** — Machine-readable structured output for integration with other tools
- **Logger module** — Timestamped file-based logging with log retention
- **Pester 5 automated test suite** — 35+ tests covering all modules with proper mocking
- **Testing documentation** — TESTING.md with testing strategy and methodology
- **Default configuration fallback** — Tool runs with sensible defaults when config.json is missing

### Changed
- Project restructured into `src/`, `tests/`, `screenshots/`, `reports/`, `logs/` directories
- Main entry point moved to `src/KBU_Deployment_Validator.ps1`
- Launcher renamed to `run_validator.bat`
- Software checks now accept exclude patterns (e.g., exclude "Java Auto Updater" when looking for "Java")
- Reporting now includes optional software checks
- Disk validation uses configurable thresholds from config.json

### Fixed
- No longer calls `exit` in module functions — all errors return structured objects
- Logger never crashes the main tool even when log directory is unwritable
- Security checks return UNKNOWN instead of false FAIL when data is unavailable

## v3.0.0 — Previous Release

- Original monolithic deployment validation script
- HTML dashboard report generation
- Basic scoring and decision logic

## v2.0.0 — Earlier Release

- Initial deployment validation concept
- Basic software and OS checks

## v1.0.0 — Initial Release

- First working version
