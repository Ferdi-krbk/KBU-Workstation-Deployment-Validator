@echo off
:: ============================================================================
:: KBU Deployment Validator - Double-Click Launcher
:: Karabuk University IT Department
:: ============================================================================
title KBU Deployment Validator
cd /d "%~dp0"
powershell.exe -ExecutionPolicy Bypass -NoProfile -File ".\DeploymentValidator.ps1"
pause
