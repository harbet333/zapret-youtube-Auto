@echo off
chcp 65001 > nul
:: 65001 - UTF-8

cd /d "%~dp0"

echo Starting test of current system state (no strategy applied)...
echo.
start "" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test current.ps1" %*