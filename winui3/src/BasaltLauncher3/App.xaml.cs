using System;
using System.IO;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace BasaltLauncher3;

public partial class App : Application
{
    // Replaces the mutex + show.request file signalling the PowerShell launcher used.
    private const string InstanceKey = "Yimuer.Basalt.Launcher3";

    private MainWindow? _main;

    public App() { this.InitializeComponent(); }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        AppInstance? keyInstance = null;
        try
        {
            keyInstance = AppInstance.FindOrRegisterForKey(InstanceKey);
            if (!keyInstance.IsCurrent)
            {
                // Hand this activation to the primary instance, then this process must leave.
                AppInstance.GetCurrent().GetActivatedEventArgs();
                await keyInstance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs());
                this.Exit();
                return;
            }
        }
        catch (Exception ex)
        {
            // Single-instance plumbing must never stop the launcher from opening.
            TryLog(ex);
            keyInstance = null;
        }

        _main = new MainWindow(ReadBackdropArg());
        if (keyInstance is not null)
        {
            keyInstance.Activated += OnActivated;
        }
        if (!_main.StartInTray) { _main.Activate(); }
    }

    private void OnActivated(object? sender, AppActivationArguments e)
    {
        _main?.RequestShow();
    }

    private static void TryLog(Exception ex)
    {
        try
        {
            string path = Path.Combine(Path.GetTempPath(), "basalt-launcher3-single.log");
            File.AppendAllText(path, DateTime.Now.ToString("s") + "  " + ex.GetType().Name + ": " + ex.Message + Environment.NewLine);
        }
        catch (Exception) { }
    }

    private static string? ReadBackdropArg()
    {
        string[] argv = Environment.GetCommandLineArgs();
        for (int i = 1; i < argv.Length - 1; i++)
        {
            if (string.Equals(argv[i], "--backdrop", StringComparison.OrdinalIgnoreCase))
            {
                return argv[i + 1];
            }
        }
        return null;
    }
}