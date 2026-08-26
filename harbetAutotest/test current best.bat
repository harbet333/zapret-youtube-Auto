@echo off
chcp 65001 > nul
:: 65001 - UTF-8

cd /d "%~dp0"

echo Searching for the best config (all strategies will be tested)...
echo.
start "" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test configs.ps1"