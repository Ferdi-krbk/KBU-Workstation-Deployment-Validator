# Changelog

All notable changes to the KBU Deployment Validator project.

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
