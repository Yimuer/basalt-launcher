@echo off
rem ============================================================
rem  Basalt 启动器：双击即可打开图形界面（不弹控制台）
rem  调试用 launcher-debug.cmd；快捷方式由 install-shortcuts.ps1 生成
rem ============================================================
start "" wscript.exe "%~dp0launch.vbs"
