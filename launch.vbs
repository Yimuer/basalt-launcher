' Basalt launcher bootstrap: runs launcher.ps1 with no console window.
' Double-click launcher.cmd (or the "Basalt ???" shortcut) to run this file.
' If the launcher crashes on startup, run launcher-debug.cmd instead.
Option Explicit

Dim fso, sh, here, ps, script
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "launcher.ps1")
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"

sh.Run """" & ps & """ -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False
