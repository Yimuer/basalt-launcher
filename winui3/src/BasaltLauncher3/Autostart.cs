using System;
using System.IO;
using Microsoft.Win32;

namespace BasaltLauncher3;

/// <summary>
/// HKCU Run entries owned by the launcher. BASALT_AUTOSTART_KEY is a test-only override that
/// redirects reads/writes to another subkey below HKCU; the normal path is the Windows Run key.
/// BasaltFetchResume is deliberately not owned here.
/// </summary>
public sealed class AutostartManager
{
    public const string EngineValue = "BasaltLocalAI";
    public const string LauncherValue = "BasaltLauncher";
    public const string PanelValue = "BasaltTrayMonitor";
    private const string DefaultRunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    private readonly BasaltPaths _paths;
    private readonly string _runKeyPath;

    public AutostartManager(BasaltPaths paths)
    {
        _paths = paths;
        _runKeyPath = Environment.GetEnvironmentVariable("BASALT_AUTOSTART_KEY") ?? DefaultRunKey;
    }

    public bool IsEnabled(string valueName)
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(_runKeyPath, writable: false);
            return key?.GetValue(valueName) is string command && !string.IsNullOrWhiteSpace(command);
        }
        catch (Exception) { return false; }
    }

    public string? Command(string valueName)
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(_runKeyPath, writable: false);
            return key?.GetValue(valueName) as string;
        }
        catch (Exception) { return null; }
    }

    public void Set(string valueName, bool enabled)
    {
        if (!enabled)
        {
            using RegistryKey? existing = Registry.CurrentUser.OpenSubKey(_runKeyPath, writable: true);
            existing?.DeleteValue(valueName, throwOnMissingValue: false);
            return;
        }

        using RegistryKey key = Registry.CurrentUser.CreateSubKey(_runKeyPath, writable: true)
            ?? throw new IOException("无法创建自启动注册表键");


        string command = BuildCommand(valueName);
        key.SetValue(valueName, command, RegistryValueKind.String);
    }

    private string BuildCommand(string valueName)
    {
        switch (valueName)
        {
            case EngineValue:
            {
                string boot = Path.Combine(_paths.Root, "bin", "boot.vbs");
                Require(boot, "缺少 bin\\boot.vbs");
                return "wscript.exe \"" + boot + "\"";
            }
            case LauncherValue:
            {
                // Keep the established entry point: launch.vbs dispatches to WinUI 3 and
                // falls back to the WPF launcher if launcher3 is absent (rollback path).
                string vbs = Path.Combine(_paths.Root, "launcher", "launch.vbs");
                Require(vbs, "缺少 launcher\\launch.vbs");
                return "wscript.exe \"" + vbs + "\" -StartInTray";
            }
            case PanelValue:
            {
                string python = Path.Combine(_paths.Root, "venv", "Scripts", "pythonw.exe");
                string panel = Path.Combine(_paths.Root, "tray", "tray.py");
                Require(python, "缺少 venv\\Scripts\\pythonw.exe");
                Require(panel, "缺少 tray\\tray.py");
                return "\"" + python + "\" \"" + panel + "\" --no-tray";
            }
            default:
                throw new ArgumentException("这个自启动项不归启动器管理：" + valueName, nameof(valueName));
        }
    }

    private static void Require(string path, string message)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) { throw new FileNotFoundException(message, path); }
    }
}