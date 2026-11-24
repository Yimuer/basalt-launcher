using System;
using System.Drawing;
using System.Windows.Forms;

namespace BasaltLauncher3;

/// <summary>
/// Shell tray icon. WinUI 3 has no tray API, so this reuses the WinForms NotifyIcon
/// (same mechanism the PowerShell/WPF launcher used) through a FrameworkReference,
/// which avoids the UseWinUI + UseWindowsForms target conflict.
/// Left click = monitor panel, double click = bring the window back, right click = menu.
/// </summary>
public sealed class LauncherTray : IDisposable
{
    private readonly NotifyIcon _icon;
    private readonly Timer _singleClickGuard = new() { Interval = 420 };
    private bool _panelPending;

    public LauncherTray(
        Action showWindow,
        Action openPanel,
        Action startService,
        Action stopService,
        Action exitApp)
    {
        Icon icon;
        try
        {
            icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? Application.ExecutablePath) ?? SystemIcons.Application;
        }
        catch (Exception)
        {
            icon = SystemIcons.Application;
        }

        ContextMenuStrip menu = new() { ShowImageMargin = false };
        menu.Items.Add(Item("显示启动器", showWindow));
        menu.Items.Add(Item("监控面板", openPanel));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item("启动服务", startService));
        menu.Items.Add(Item("停止服务", stopService));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item("退出", exitApp));

        // NotifyIcon rejects tooltips longer than 63 chars, so every write goes through SetTooltip.
        _icon = new NotifyIcon
        {
            Icon = icon,
            Text = "Basalt 启动器",
            Visible = true,
            ContextMenuStrip = menu,
            BalloonTipTitle = "Basalt 启动器",
        };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button != MouseButtons.Left) return;
            _panelPending = true;
            _singleClickGuard.Start();
        };
        _icon.MouseDoubleClick += (_, e) =>
        {
            if (e.Button != MouseButtons.Left) return;
            _singleClickGuard.Stop();
            _panelPending = false;
            Safe(showWindow);
        };

        // Delay the single-click action so a double click can cancel it, otherwise a
        // double click would open the panel *and* raise the window.
        _singleClickGuard.Tick += (_, _) =>
        {
            _singleClickGuard.Stop();
            if (_panelPending) { _panelPending = false; Safe(openPanel); }
        };
    }

    private static ToolStripMenuItem Item(string text, Action action)
    {
        ToolStripMenuItem item = new(text);
        item.Click += (_, _) => Safe(action);
        return item;
    }

    private static void Safe(Action action)
    {
        try { action(); } catch (Exception) { /* tray actions must never crash the icon */ }
    }

    public void SetTooltip(string text)
    {
        try { _icon.Text = text.Length > 63 ? text[..63] : text; } catch (Exception) { }
    }

    public void Balloon(string text)
    {
        try { _icon.ShowBalloonTip(4000, "Basalt 启动器", text, ToolTipIcon.Info); } catch (Exception) { }
    }

    public void Dispose()
    {
        try
        {
            _singleClickGuard.Dispose();
            _icon.Visible = false;
            _icon.Dispose();
        }
        catch (Exception) { }
    }
}