@echo off
chcp 65001 > nul
:: 65001 - UTF-8

cd /d "%~dp0"

:: Elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
    exit /b
)

echo Removing autostart task "Zapret Autotest"...
echo.
schtasks /Delete /TN "Zapret Autotest" /F

if %errorlevel% equ 0 (
    echo.
    echo [OK] Task "Zapret Autotest" successfully removed from autostart.
) else (
    echo.
    echo [ERROR] Failed to remove task "Zapret Autotest" or task does not exist.
)
echo.
pause
