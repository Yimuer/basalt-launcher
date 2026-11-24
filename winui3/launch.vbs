' Basalt launcher bootstrap. WinUI 3 is preferred; WPF remains the rollback path.
' Existing shortcuts and HKCU Run "BasaltLauncher" continue to call this file.
Option Explicit

Dim fso, sh, here, root, ps, script, args, i, arg, winui
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
root = fso.GetParentFolderName(here)
winui = fso.BuildPath(fso.BuildPath(root, "launcher3"), "BasaltLauncher3.exe")

If fso.FileExists(winui) Then
    args = ""
    For i = 0 To WScript.Arguments.Count - 1
        arg = WScript.Arguments(i)
        If StrComp(arg, "-StartInTray", vbTextCompare) = 0 Then arg = "--start-in-tray"
        args = args & " " & QuoteArg(arg)
    Next
    sh.Run """" & winui & """" & args, 0, False
    WScript.Quit 0
End If

' WPF fallback (original launcher).
script = fso.BuildPath(here, "launcher.ps1")
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
args = ""
For i = 0 To WScript.Arguments.Count - 1
    args = args & " " & QuoteArg(WScript.Arguments(i))
Next
sh.Run """" & ps & """ -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """" & args, 0, False

Function QuoteArg(s)
    If InStr(s, " ") > 0 Or InStr(s, vbTab) > 0 Or Len(s) = 0 Then
        QuoteArg = """" & s & """"
    Else
        QuoteArg = s
    End If
End Function