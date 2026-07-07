@echo off
:: ============================================================================
:: KBU Deployment Validator - Double-Click Launcher
:: Karabuk University IT Department
:: ============================================================================
title KBU Deployment Validator
cd /d "%~dp0"
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0src\KBU_Deployment_Validator.ps1" %*
pause
