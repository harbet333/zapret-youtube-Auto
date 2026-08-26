@echo off
chcp 65001 > nul
:: 65001 - UTF-8

cd /d "%~dp0"

:: Check target file exists
if not exist "%~dp0test current.bat" (
    echo [ERROR] "test current.bat" not found next to this script.
    pause
    exit /b 1
)

:: Elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
    exit /b
)

echo Registering autostart task for "test current.bat"...
echo.
schtasks /Create /TN "Zapret Autotest" /TR "\"%~dp0test current.bat\"" /SC ONLOGON /RL HIGHEST /F

if %errorlevel% equ 0 (
    echo.
    echo [OK] Task "Zapret Autotest" created.
    echo It runs "test current.bat" on every logon with admin rights ^(no UAC prompt^).
) else (
    echo.
    echo [ERROR] Failed to create task.
)
echo.
pause