using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace BasaltLauncher3;

public partial class MainWindow : Window
{
    private const int LogicalWidth = 496;
    private const int LogicalHeight = 600;

    private readonly IntPtr _hwnd;
    private readonly AppWindow _appWindow;
    private readonly DispatcherQueue _queue = DispatcherQueue.GetForCurrentThread();
    private readonly BasaltPaths _paths = BasaltPaths.Detect();
    private readonly EngineClient _engine;
    private readonly DispatcherTimer _timer;
    private readonly bool _dryRun;

    private bool _polling;
    private string? _actionHint;
    private DateTime _actionHintUntil;
    private LauncherTray? _tray;
    private bool _closeToTray = true;
    private bool _exitRequested;
    private readonly LauncherSettings _settings = LauncherSettings.Load();
    private bool _startInTray;
    private readonly AutostartManager _autostart;
    private bool _restoringAutostart;
    private bool _ready;
    private CancellationTokenSource? _cts;

    public MainWindow(string? initialBackdrop)
    {
        this.InitializeComponent();

        foreach (string a in Environment.GetCommandLineArgs())
        {
            if (string.Equals(a, "--dry-run", StringComparison.OrdinalIgnoreCase)) { _dryRun = true; }
            if (string.Equals(a, "--start-in-tray", StringComparison.OrdinalIgnoreCase)) { _startInTray = true; }
        }

        _engine = new EngineClient(_paths.Endpoint);
        _autostart = new AutostartManager(_paths);

        SelectByTag(ThemeBox, _settings.Theme);
        if (string.IsNullOrEmpty(initialBackdrop)) { SelectByTag(BackdropBox, _settings.Material); }
        _closeToTray = _settings.CloseToTray;
        TraySwitch.IsOn = _settings.CloseToTray;
        EngineStartSwitch.IsOn = _autostart.IsEnabled(AutostartManager.EngineValue);
        LauncherStartSwitch.IsOn = _autostart.IsEnabled(AutostartManager.LauncherValue);
        PanelStartSwitch.IsOn = _autostart.IsEnabled(AutostartManager.PanelValue);

        if (!string.IsNullOrEmpty(initialBackdrop))
        {
            SelectByTag(BackdropBox, initialBackdrop);
        }

        _hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        _appWindow = this.AppWindow;
        ConfigureWindowGeometry();
        SyncCaptionTheme();
        RootGrid.ActualThemeChanged += (_, _) => { SyncCaptionTheme(); if (this.SystemBackdrop is null) { RootGrid.Background = OpaqueBrush(); } };

        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        _timer.Tick += (_, _) => _ = PollAsync();
        _timer.Start();

        _appWindow.Closing += OnAppWindowClosing;
        TraySwitch.Toggled += (_, _) => { _closeToTray = TraySwitch.IsOn; if (_ready) { _settings.CloseToTray = TraySwitch.IsOn; _settings.Save(); } };
        _tray = new LauncherTray(RequestShow, OpenPanelCore,
            () => RunBatch(_paths.StartCmd, "silent", "启动服务"),
            () => RunBatch(_paths.StopCmd, "", "停止服务"),
            ExitApp);

        this.Activated += (_, _) => { if (_timer is not null) { _ = PollAsync(); } };

        _ready = true;
        // App.OnLaunched skips Activate for --start-in-tray, so no window frame is shown.

        _ = PollAsync();
    }

    /// <summary>Used by the tray icon and by redirected activations from a second process.</summary>
    public bool StartInTray => _startInTray;

    public void RequestShow()
    {
        _queue.TryEnqueue(() =>
        {
            _appWindow.MoveInZOrderAtTop();
            _appWindow.Show();
            this.Activate();
        });
    }

    // ---------- window plumbing ----------

    private void ConfigureWindowGeometry()
    {
        double dpi = Native.GetDpiForWindow(_hwnd);
        double scale = dpi <= 0 ? 1.0 : dpi / 96.0;

        int w = (int)Math.Round(LogicalWidth * scale);
        int h = (int)Math.Round(LogicalHeight * scale);
        _appWindow.ResizeClient(new Windows.Graphics.SizeInt32(w, h));

        DisplayArea area = DisplayArea.GetFromWindowId(_appWindow.Id, DisplayAreaFallback.Nearest);
        Windows.Graphics.RectInt32 work = area.WorkArea;
        int x = work.X + (work.Width - w) / 2;
        int y = work.Y + (work.Height - h) / 3;
        _appWindow.Move(new Windows.Graphics.PointInt32(x, y));
    }

    private void SyncCaptionTheme()
    {
        Native.SetDarkCaption(_hwnd, RootGrid.ActualTheme != ElementTheme.Light);
    }

    private static void SelectByTag(ComboBox box, string tag)
    {
        foreach (object item in box.Items)
        {
            if (item is ComboBoxItem ci && string.Equals(ci.Tag as string, tag, StringComparison.OrdinalIgnoreCase))
            {
                box.SelectedItem = ci;
                return;
            }
        }
    }

    private static string? TagOf(ComboBox box)
        => (box.SelectedItem as ComboBoxItem)?.Tag as string;

    private void OnBackdropChanged(object sender, SelectionChangedEventArgs e)
    {
        if (BackdropBox is null) { return; }
        string? tag = TagOf(BackdropBox);
        bool effects = true;
        try { effects = new Windows.UI.ViewManagement.UISettings().AdvancedEffectsEnabled; }
        catch (Exception) { }
        bool useMaterial = effects && tag is "mica" or "micaalt" or "acrylic";
        SystemBackdrop? bd = null;
        if (useMaterial)
        {
            bd = tag switch
            {
                "mica" => new MicaBackdrop(),
                "micaalt" => MakeMicaAlt(),
                "acrylic" => new DesktopAcrylicBackdrop(),
                _ => null,
            };
        }
        this.SystemBackdrop = bd;
        RootGrid.Background = bd is null ? OpaqueBrush() : new SolidColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0));
        if (_ready && tag is not null)
        {
            _settings.Material = tag;
            _settings.Save();
            if (!effects && tag != "none") { Say("系统已关闭透明效果，当前按实色背景显示。"); }
        }
    }

    private Brush OpaqueBrush()
    {
        return RootGrid.Resources.TryGetValue("OpaqueWindowBrush", out object? value) && value is Brush brush
            ? brush
            : new SolidColorBrush(RootGrid.ActualTheme == ElementTheme.Light
                ? Windows.UI.Color.FromArgb(0xFF, 0xF3, 0xF3, 0xF3)
                : Windows.UI.Color.FromArgb(0xFF, 0x20, 0x20, 0x20));
    }

    private void OnAutostartToggled(object sender, RoutedEventArgs e)
    {
        if (!_ready || _restoringAutostart || sender is not ToggleSwitch sw || sw.Tag is not string valueName) { return; }
        bool desired = sw.IsOn;
        try
        {
            _autostart.Set(valueName, desired);
            string label = valueName switch
            {
                AutostartManager.EngineValue => "引擎自启",
                AutostartManager.LauncherValue => "启动器自启",
                AutostartManager.PanelValue => "监控面板自启",
                _ => valueName,
            };
            Say((desired ? "已开启" : "已关闭") + label + "；不会改变当前正在运行的进程。");
        }
        catch (Exception ex)
        {
            _restoringAutostart = true;
            sw.IsOn = !desired;
            _restoringAutostart = false;
            Say("自启动设置失败：" + ex.Message);
        }
    }

    private static MicaBackdrop MakeMicaAlt()
    {
        // MicaKind is not nameable from C# in this SDK; use the property's own enum type.
        var mb = new MicaBackdrop();
        var kind = typeof(MicaBackdrop).GetProperty("Kind");
        if (kind is not null && kind.PropertyType.IsEnum)
        {
            try { kind.SetValue(mb, Enum.Parse(kind.PropertyType, "BaseAlt")); }
            catch (Exception) { /* stay on Base */ }
        }
        return mb;
    }

    private void OnThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ThemeBox is null || this.Content is not FrameworkElement root) { return; }
        string? tag = TagOf(ThemeBox);
        root.RequestedTheme = tag switch
        {
            "light" => ElementTheme.Light,
            "dark" => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
        if (_ready && tag is not null)
        {
            _settings.Theme = tag;
            _settings.Save();
        }
    }

    // ---------- engine polling ----------

    private async Task PollAsync()
    {
        if (_polling) return;
        _polling = true;
        try
        {
            _cts?.Cancel();
            _cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            EngineSnapshot snap = await _engine.ProbeAsync(_cts.Token).ConfigureAwait(true);
            Render(snap);
        }
        catch (Exception ex)
        {
            Say("轮询异常：" + ex.Message);
        }
        finally
        {
            _polling = false;
        }
    }

    private void Render(EngineSnapshot s)
    {
        StateDot.Fill = new SolidColorBrush(ColorOf(s.Key));
        TxtState.Text = s.Text;

        var meta = new List<string>();
        if (!string.IsNullOrEmpty(s.Model)) { meta.Add("模型 " + s.Model); }
        if (!string.IsNullOrEmpty(s.Version)) { meta.Add("引擎 " + s.Version); }
        if (s.MaxContext is not null) { meta.Add("上下文 " + s.MaxContext.Value.ToString("N0", CultureInfo.InvariantCulture)); }
        meta.Add("端点 " + _paths.Endpoint);
        TxtMeta.Text = string.Join("  ·  ", meta);

        var meters = new List<string>();
        if (s.GpuUtil is not null) { meters.Add("GPU " + s.GpuUtil.Value + "%"); }
        if (s.MemUsed is not null && s.MemTotal is not null)
        {
            meters.Add("显存 " + Gib(s.MemUsed.Value) + "/" + Gib(s.MemTotal.Value) + " GiB");
        }
        if (s.Temp is not null) { meters.Add(s.Temp.Value + " °C"); }
        if (s.Cpu is not null) { meters.Add("CPU " + Math.Round(s.Cpu.Value) + "%"); }
        if (s.TokS is not null) { meters.Add(Math.Round(s.TokS.Value) + " tok/s"); }
        TxtMetrics.Text = string.Join("  ·  ", meters);

        string uptime = UptimeText(s);
        TxtUptime.Text = uptime + (s.Requests is not null
            ? (uptime.Length > 0 ? "  ·  " : "") + "累计 " + s.Requests.Value.ToString("N0", CultureInfo.InvariantCulture) + " 次请求"
            : "");
        _tray?.SetTooltip(TrayTip(s));
        bool fresh = _actionHint is not null && DateTime.Now < _actionHintUntil;
        if (fresh)
        {
            TxtHint.Text = _actionHint;
        }
        else
        {
            _actionHint = null;
            TxtHint.Text = s.Error ?? (_dryRun ? "演练模式：按钮只显示将执行的命令，不会真的执行。" : "");
        }
        TxtFooter.Text = "Basalt " + (s.Version ?? "?") + "  ·  Launcher3 0.1" + (_dryRun ? "  (dry-run)" : "");
    }

    private static string TrayTip(EngineSnapshot s)
    {
        var parts = new List<string> { "Basalt 启动器 · " + s.Text };
        if (s.TokS is not null) { parts.Add(s.TokS.Value.ToString("0.0", CultureInfo.InvariantCulture) + " tok/s"); }
        if (s.GpuUtil is not null) { parts.Add("GPU " + s.GpuUtil.Value + "%"); }
        if (s.MemUsed is not null && s.MemTotal is not null && s.MemTotal > 0)
        {
            parts.Add("显存 " + (s.MemUsed.Value / 1073741824.0).ToString("0", CultureInfo.InvariantCulture)
                + "/" + (s.MemTotal.Value / 1073741824.0).ToString("0", CultureInfo.InvariantCulture) + "G");
        }
        if (s.Temp is not null) { parts.Add(s.Temp.Value + "°C"); }
        for (int n = parts.Count; n >= 1; n--)
        {
            string tip = string.Join(" · ", parts.GetRange(0, n));
            if (tip.Length <= 60) { return tip; }
        }
        return "Basalt 启动器";
    }

    private static string Gib(long bytes) => (bytes / 1073741824.0).ToString("0.0", CultureInfo.InvariantCulture);

    private static Windows.UI.Color ColorOf(string key) => key switch
    {
        "ok" => Windows.UI.Color.FromArgb(0xFF, 0x6C, 0xCB, 0x5F),
        "busy" => Windows.UI.Color.FromArgb(0xFF, 0xFC, 0xE1, 0x00),
        "loading" => Windows.UI.Color.FromArgb(0xFF, 0x4C, 0xC2, 0xFF),
        "stopped" => Windows.UI.Color.FromArgb(0xFF, 0xFF, 0x99, 0xA4),
        "down" => Windows.UI.Color.FromArgb(0xFF, 0xFF, 0x99, 0xA4),
        _ => Windows.UI.Color.FromArgb(0xFF, 0x9A, 0x9A, 0x9A),
    };

    // ---------- actions ----------
    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_closeToTray && !_exitRequested)
        {
            args.Cancel = true;
            _appWindow.Hide();
            _tray?.Balloon("已收进托盘：双击图标叫回窗口，右键打开菜单。");
        }
    }

    private void ExitApp()
    {
        _exitRequested = true;
        _timer.Stop();
        _tray?.Dispose();
        _tray = null;
        Microsoft.UI.Xaml.Application.Current.Exit();
    }

    /// <summary>Engine uptime, mirroring the PowerShell launcher: PIDFILE plus process start time.</summary>
    private string UptimeText(EngineSnapshot s)
    {
        if (string.IsNullOrEmpty(_paths.PidFile)) { return ""; }
        if (s.Key != "ok" && s.Key != "busy" && s.Key != "loading") { return ""; }
        try
        {
            if (!File.Exists(_paths.PidFile)) { return ""; }
            string raw = File.ReadAllText(_paths.PidFile!).Trim();
            if (!int.TryParse(raw, out int pid) || pid <= 0) { return ""; }
            Process proc = Process.GetProcessById(pid);
            if (!string.Equals(proc.ProcessName, "basalt", StringComparison.OrdinalIgnoreCase)) { return ""; }
            TimeSpan span = DateTime.Now - proc.StartTime;
            string fmt = span.TotalHours >= 1
                ? ((int)Math.Floor(span.TotalHours)) + ":" + span.Minutes.ToString("00") + ":" + span.Seconds.ToString("00")
                : span.Minutes.ToString("00") + ":" + span.Seconds.ToString("00");
            return (s.Key == "loading" ? "加载中 " : "已运行 ") + fmt;
        }
        catch (Exception) { return ""; }
    }


    /// <summary>Action feedback that must survive the next 3 s poll tick.</summary>
    private void Say(string message)
    {
        _actionHint = message;
        _actionHintUntil = DateTime.Now.AddSeconds(12);
        TxtHint.Text = message;
    }

    private void OnStartService(object sender, RoutedEventArgs e) => RunBatch(_paths.StartCmd, "silent", "启动服务");

    private void OnStopService(object sender, RoutedEventArgs e) => RunBatch(_paths.StopCmd, "", "停止服务");

    private void RunBatch(string script, string args, string label)
    {
        string shown = "cmd.exe /c \"" + script + "\"" + (args.Length > 0 ? " " + args : "");
        if (_dryRun)
        {
            Say("[dry-run] " + label + " → " + shown);
            return;
        }
        if (!File.Exists(script))
        {
            Say(label + "失败：找不到 " + script);
            return;
        }
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = "/c \"" + script + "\"" + (args.Length > 0 ? " " + args : ""),
                WorkingDirectory = _paths.Root,
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            });
            Say(label + "已提交（" + Path.GetFileName(script) + "）。");
        }
        catch (Exception ex)
        {
            Say(label + "失败：" + ex.Message);
        }
    }

    private void OnOpenWeb(object sender, RoutedEventArgs e)
    {
        if (_dryRun) { Say("[dry-run] 打开 " + _paths.WebUrl); return; }
        try
        {
            Process.Start(new ProcessStartInfo { FileName = _paths.WebUrl, UseShellExecute = true });
        }
        catch (Exception ex) { Say("打不开 Web UI：" + ex.Message); }
    }

    private void OnOpenPanel(object sender, RoutedEventArgs e) => OpenPanelCore();

    private void OpenPanelCore() => _ = ShowPanelAsync();

    /// <summary>Show and raise the existing panel; only start it when no panel window exists.</summary>
    private async Task ShowPanelAsync()
    {
        string py = Path.Combine(_paths.Root, "venv", "Scripts", "pythonw.exe");
        string script = Path.Combine(_paths.Root, "tray", "tray.py");
        string shown = "\"" + py + "\" \"" + script + "\" --no-tray";
        if (_dryRun) { Say("[dry-run] 监控面板 → " + shown); return; }
        try
        {
            IntPtr h = Native.FindWindow("BasaltTrayPanel", null);
            if (h == IntPtr.Zero)
            {
                if (!File.Exists(py) || !File.Exists(script))
                {
                    Say("监控面板不可用：缺少 " + (File.Exists(py) ? script : py));
                    return;
                }
                Process.Start(new ProcessStartInfo { FileName = py, Arguments = "\"" + script + "\" --no-tray", WorkingDirectory = _paths.Root, UseShellExecute = true });
                await Task.Delay(900);
                h = Native.FindWindow("BasaltTrayPanel", null);
                if (h == IntPtr.Zero) { Say("监控面板已提交启动。"); return; }
            }

            if (!Native.IsWindowVisible(h)) { Native.ShowWindow(h, 4); } // SW_SHOWNOACTIVATE
            bool topmost = true;
            try
            {
                string posFile = Path.Combine(_paths.Root, "tray", "panel.pos");
                if (File.Exists(posFile))
                {
                    using JsonDocument pos = JsonDocument.Parse(File.ReadAllText(posFile));
                    if (pos.RootElement.TryGetProperty("topmost", out JsonElement value) &&
                        (value.ValueKind == JsonValueKind.True || value.ValueKind == JsonValueKind.False))
                    {
                        topmost = value.GetBoolean();
                    }
                }
            }
            catch (Exception) { }

            // Raising via TOPMOST then restoring the user's preferred band works even when
            // the panel was previously buried behind other windows. 0x13=NOMOVE|NOSIZE|NOACTIVATE.
            Native.SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x13);
            Native.SetWindowPos(h, new IntPtr(topmost ? -1 : -2), 0, 0, 0, 0, 0x13);
        }
        catch (Exception ex) { Say("监控面板打开失败：" + ex.Message); }
    }

    private static class Native
    {
        private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr FindWindow(string? className, string? windowName);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

        public static void SetDarkCaption(IntPtr hwnd, bool dark)
        {
            int value = dark ? 1 : 0;
            try { DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref value, sizeof(int)); }
            catch (Exception) { /* cosmetic only */ }
        }
    }
}
