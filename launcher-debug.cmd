@echo off
rem 带控制台启动，排错用；窗口会一直留到启动器关闭
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0launcher.ps1"
if errorlevel 1 pause