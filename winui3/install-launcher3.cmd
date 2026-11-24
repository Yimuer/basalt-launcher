@echo off
setlocal EnableExtensions
set "SRC=%~dp0app"
set "DEST=%ProgramFiles%\basalt\launcher3"

if not exist "%SRC%\BasaltLauncher3.exe" (
    echo [Basalt] Missing "%SRC%\BasaltLauncher3.exe".
    echo Run publish.ps1 and place the published files in the app folder next to this script.
    pause
    exit /b 1
)
if not exist "%ProgramFiles%\basalt\start.cmd" (
    echo [Basalt] Basalt was not found under "%ProgramFiles%\basalt".
    pause
    exit /b 1
)

fltmc >nul 2>&1
if errorlevel 1 (
    echo [Basalt] Requesting administrator permission to install under Program Files...
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo [Basalt] Installing WinUI 3 launcher to "%DEST%" ...
robocopy "%SRC%" "%DEST%" /E /R:2 /W:1 /NFL /NDL /NP
if errorlevel 8 (
    echo [Basalt] Install failed.
    pause
    exit /b 1
)
if not exist "%DEST%\BasaltLauncher3.exe" (
    echo [Basalt] Install verification failed.
    pause
    exit /b 1
)

echo [Basalt] Installed. Framework-dependent package requires:
echo   - .NET 8 Desktop Runtime
echo   - Windows App SDK Runtime 2.7
echo Existing shortcuts still use launcher\launch.vbs; that dispatcher selects WinUI 3
echo when launcher3\BasaltLauncher3.exe exists and falls back to WPF when it does not.
pause
exit /b 0