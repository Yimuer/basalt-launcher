#Requires -Version 5.1
<#
    Basalt 启动器（WinUI 3 / Fluent 风格）
    ----------------------------------------------------------------------
    本地 Basalt 推理服务的图形启动器：
      - 启动 / 停止服务（复用项目自带的 start.cmd silent / stop.cmd）
      - 开机自启动开关（HKCU\...\Run\BasaltLocalAI，与 bin\autostart.cmd 同一项）
      - 打开网页、查看引擎日志、编辑 bin\config.cmd
    界面：Windows 11 Fluent 深色风格（#202020 底、#2B2B2B 卡片、Segoe UI Variable、
    系统强调色、4/6/8 px 圆角），窗口无边框自绘标题栏。
    由 launch.vbs 以隐藏控制台方式调起；快捷方式见 install-shortcuts.ps1。

    参数：
      -Root <path>   指定项目根目录（默认：本脚本上一级目录），便于用假服务做端到端测试
      -StateOnly     只打印一次状态 JSON 后退出（调试用）
#>
param(
    [string]$Root = '',
    [switch]$StateOnly
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 基础路径 --
$script:LauncherDir = $PSScriptRoot
if ($Root) {
    $script:Root = (Resolve-Path -LiteralPath $Root).Path
} else {
    $script:Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}
# 允许用 BASALT_ROOT 环境变量兜底；找不到配置时弹窗说明，而不是静默失败
$configCandidate = Join-Path $script:Root 'bin\config.cmd'
if (-not (Test-Path -LiteralPath $configCandidate)) {
    $envRoot = [Environment]::GetEnvironmentVariable('BASALT_ROOT')
    if ($envRoot -and (Test-Path -LiteralPath (Join-Path $envRoot 'bin\config.cmd'))) {
        $script:Root = (Resolve-Path -LiteralPath $envRoot).Path
        $configCandidate = Join-Path $script:Root 'bin\config.cmd'
    }
}
if (-not (Test-Path -LiteralPath $configCandidate)) {
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show(
            "没有找到 Basalt 配置：`n$configCandidate`n`n请把 launcher 目录放进 Basalt 根目录，`n或用 -Root 参数指定根目录（也可以先设置 BASALT_ROOT 环境变量）。",
            'Basalt 启动器') | Out-Null
    } catch { }
    exit 1
}

$script:StartCmd  = Join-Path $script:Root 'start.cmd'
$script:StopCmd   = Join-Path $script:Root 'stop.cmd'
$script:ConfigCmd = Join-Path $script:Root 'bin\config.cmd'
$script:RunKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunValue  = 'BasaltLocalAI'

# ------------------------------------------------------------------ 解析配置 --
function Read-BasaltConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "找不到配置文件：$Path" }
    $enc = [System.Text.Encoding]::GetEncoding(936)   # 项目里的 .cmd 一律 GBK
    $map = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path, $enc)) {
        if ($line -match '^\s*set\s+"?([A-Za-z_][A-Za-z0-9_]*)=(.*?)"?\s*$') {
            $map[$matches[1].ToUpperInvariant()] = $matches[2]
        }
    }
    # config.cmd 里大量使用 %BASALT_ROOT%\... 这种 cmd 变量引用，这里展开成绝对路径
    $expander = {
        param($text, $vars)
        return [regex]::Replace($text, '%([A-Za-z_][A-Za-z0-9_]*)%', {
            param($m)
            $name = $m.Groups[1].Value.ToUpperInvariant()
            if ($vars.ContainsKey($name)) { return $vars[$name] }
            $envValue = [Environment]::GetEnvironmentVariable($name)
            if ($envValue) { return $envValue }
            return $m.Value
        })
    }
    for ($pass = 0; $pass -lt 4; $pass++) {
        $changed = $false
        foreach ($key in @($map.Keys)) {
            $value = [string]$map[$key]
            if ($value -match '%[A-Za-z_][A-Za-z0-9_]*%') {
                $expanded = & $expander $value $map
                if ($expanded -ne $value) { $map[$key] = $expanded; $changed = $true }
            }
        }
        if (-not $changed) { break }
    }
    if (-not $map.ContainsKey('BASALT_ROOT')) { $map['BASALT_ROOT'] = (Split-Path -Parent (Split-Path -Parent $Path)) }
    return $map
}

$script:Cfg = Read-BasaltConfig -Path $script:ConfigCmd
function Get-Cfg([string]$key, [string]$fallback = '') {
    $v = $script:Cfg[$key]
    if ($null -eq $v -or $v -eq '') { return $fallback }
    return $v
}
$script:SvcHost   = Get-Cfg 'HOST' '127.0.0.1'
$script:Port      = Get-Cfg 'PORT' '8080'
$script:Endpoint  = "http://$($script:SvcHost):$($script:Port)"
$script:PidFile   = Get-Cfg 'PIDFILE'
$script:LogFile   = Get-Cfg 'LOG'
$script:ModelName = Get-Cfg 'MODEL_NAME' 'flash-next'

# -------------------------------------------------------------------- 日志 --
function Write-Log {
    param([string]$Message)
    try {
        $dir = Join-Path $script:Root 'logs'
        if (-not (Test-Path -LiteralPath $dir)) { $dir = [System.IO.Path]::GetTempPath() }
        Add-Content -LiteralPath (Join-Path $dir 'launcher.log') `
            -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- 画刷缓存 --
$script:BrushCache = @{}
function Get-Brush {
    param([string]$Hex)
    if (-not $script:BrushCache.ContainsKey($Hex)) {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
        $script:BrushCache[$Hex] = [System.Windows.Media.SolidColorBrush]::new($color)
    }
    return $script:BrushCache[$Hex]
}

# ---------------------------------------------------------------- 服务状态 --
function Test-Health {
    try {
        $req = [System.Net.HttpWebRequest]::Create("$($script:Endpoint)/health")
        $req.Method = 'GET'
        $req.Timeout = 500
        $req.ReadWriteTimeout = 500
        $req.KeepAlive = $false
        $req.Proxy = $null
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return ($code -eq 200)
    } catch {
        return $false
    }
}

function Get-ServiceState {
    $snap = [pscustomobject]@{
        Health    = $false
        Pid       = 0
        Alive     = $false
        StartTime = $null
    }
    if ($script:PidFile -and (Test-Path -LiteralPath $script:PidFile)) {
        try {
            $raw = ([System.IO.File]::ReadAllText($script:PidFile)).Trim()
            $n = 0
            if ([int]::TryParse($raw, [ref]$n) -and $n -gt 0) {
                $snap.Pid = $n
                $proc = Get-Process -Id $n -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -eq 'basalt') {
                    $snap.Alive = $true
                    try { $snap.StartTime = $proc.StartTime } catch { }
                }
            }
        } catch { }
    }
    $snap.Health = Test-Health
    return $snap
}

function Format-Duration {
    param($Span)
    if ($null -eq $Span) { return '' }
    if ($Span.TotalHours -ge 1) {
        return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
    }
    return ('{0:00}:{1:00}' -f $Span.Minutes, $Span.Seconds)
}

# ---------------------------------------------------------------- 开机自启 --
function Get-AutostartInfo {
    try {
        $item = Get-ItemProperty -Path $script:RunKey -Name $script:RunValue -ErrorAction Stop
        $value = [string]$item.PSObject.Properties[$script:RunValue].Value
        $target = ''
        if ($value -match '"([^"]+)"') { $target = $matches[1] }
        elseif ($value -match '(?i)(\S+\.vbs)') { $target = $matches[1] }
        return [pscustomobject]@{
            On      = $true
            Command = $value
            Target  = $target
            Missing = ($target -ne '' -and -not (Test-Path -LiteralPath $target))
        }
    } catch {
        return [pscustomobject]@{ On = $false; Command = ''; Target = ''; Missing = $false }
    }
}

function Set-Autostart {
    param([bool]$Enable)
    try {
        if ($Enable) {
            $boot = Join-Path $script:Root 'bin\boot.vbs'
            if (-not (Test-Path -LiteralPath $boot)) { throw '缺少 bin\boot.vbs，无法注册自启动' }
            $value = 'wscript.exe "' + $boot + '"'
            New-ItemProperty -Path $script:RunKey -Name $script:RunValue -Value $value `
                -PropertyType String -Force | Out-Null
            Write-Log "autostart enabled -> $value"
            Show-Toast '已开启：登录 Windows 后自动加载服务' 'ok'
        } else {
            Remove-ItemProperty -Path $script:RunKey -Name $script:RunValue -ErrorAction SilentlyContinue
            Write-Log 'autostart disabled'
            Show-Toast '已关闭开机自启动（当前服务不受影响）' 'ok'
        }
    } catch {
        Write-Log "autostart failed: $($_.Exception.Message)"
        Show-Toast ('设置失败：' + $_.Exception.Message) 'error'
    }
    Sync-AutostartUi
}

# ---------------------------------------------------------------- 界面状态 --
$script:StartProc = $null
$script:StopProc  = $null
$script:StartAt   = $null
$script:LastError = ''
$script:State     = 'stopped'
$script:Snap      = $null
$script:Tick      = 0
$script:Toast     = $null
$script:SuppressToggle = $false
$script:SpinStory = $null
$script:Ui        = @{}

function Show-Toast {
    param([string]$Text, [string]$Kind = 'info', [int]$Seconds = 5)
    $script:Toast = @{ Text = $Text; Kind = $Kind; Until = (Get-Date).AddSeconds($Seconds) }
}

function Format-StartError {
    param($Code)
    switch ([int]$Code) {
        1 { return '启动失败：引擎、模型包或 Python 环境缺失（代码 1）' }
        2 { return '启动超时：15 分钟仍未就绪（代码 2）' }
        3 { return '引擎启动失败（代码 3）' }
        default { return "启动失败（代码 $Code）" }
    }
}

function Get-ContextLabel {
    $ctx = Get-Cfg 'MAX_CONTEXT'
    if (-not $ctx) { return '' }
    $n = 0
    if ([int]::TryParse($ctx, [ref]$n) -and $n -gt 0) {
        if ($n -ge 1024 -and ($n % 1024) -eq 0) { return ('{0}K 上下文' -f ($n / 1024)) }
        return "$n 上下文"
    }
    return ''
}

function Set-StatusAppearance {
    param([string]$State)
    $icon = $script:Ui.StatusIcon
    switch ($State) {
        'running' {
            $icon.Text = [string][char]0xE930          # Completed
            $icon.Foreground = Get-Brush '#6CCB5F'
            $script:Ui.TxtState.Text = '运行中'
        }
        'loading' {
            $icon.Text = [string][char]0xE895          # Sync
            $icon.Foreground = $script:AccentBrush
            $script:Ui.TxtState.Text = '正在加载模型'
        }
        'starting' {
            $icon.Text = [string][char]0xE895
            $icon.Foreground = $script:AccentBrush
            $script:Ui.TxtState.Text = '正在启动'
        }
        'stopping' {
            $icon.Text = [string][char]0xE895
            $icon.Foreground = $script:AccentBrush
            $script:Ui.TxtState.Text = '正在停止'
        }
        'error' {
            $icon.Text = [string][char]0xE783          # Error
            $icon.Foreground = Get-Brush '#FF99A4'
            $script:Ui.TxtState.Text = '启动失败'
        }
        default {
            $icon.Text = [string][char]0xE7E8          # PowerButton
            $icon.Foreground = Get-Brush '#9A9A9A'
            $script:Ui.TxtState.Text = '已停止'
        }
    }
}

function Set-Spin {
    param([bool]$On)
    try {
        if ($On -and -not $script:SpinStory) {
            $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
            $anim.From = 0.0
            $anim.To = 360.0
            $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(1400))
            $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $sb = New-Object System.Windows.Media.Animation.Storyboard
            [System.Windows.Media.Animation.Storyboard]::SetTarget($anim, $script:Ui.StatusIcon)
            [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($anim,
                (New-Object System.Windows.PropertyPath('(UIElement.RenderTransform).(RotateTransform.Angle)')))
            $sb.Children.Add($anim)
            $script:SpinStory = $sb
            $script:SpinStory.Begin($script:Window)
        } elseif (-not $On -and $script:SpinStory) {
            $script:SpinStory.Stop($script:Window)
            $script:SpinStory = $null
            $script:Ui.StatusIconRotate.Angle = 0
        }
    } catch { }
}

function Update-Ui {
    $snap = Get-ServiceState
    $script:Snap = $snap
    $script:Tick++

    # 启动包装进程收尾
    if ($script:StartProc) {
        if ($script:StartProc.HasExited) {
            $code = 0
            try { $code = [int]$script:StartProc.ExitCode } catch { }
            if ($snap.Health -or $code -eq 0) {
                $script:StartProc = $null
            } else {
                $script:LastError = Format-StartError $code
                Write-Log "start wrapper exited code=$code"
                $script:StartProc = $null
            }
        }
    }
    # 启动包装进程还活着，但引擎已经没了：别让界面一直转圈
    if ($script:StartProc -and -not $script:StartProc.HasExited -and $script:StartAt) {
        $elapsed = ((Get-Date) - $script:StartAt).TotalSeconds
        $stalePid = ($snap.Pid -gt 0) -and (-not $snap.Alive) -and (-not $snap.Health)
        $noPid = ($snap.Pid -eq 0) -and (-not $snap.Health) -and ($elapsed -gt 120)
        if (($stalePid -and $elapsed -gt 30) -or $noPid) {
            try { & "$env:SystemRoot\System32\taskkill.exe" /PID $script:StartProc.Id /T /F | Out-Null } catch { }
            $script:StartProc = $null
            $script:LastError = '引擎进程已退出，请查看引擎日志'
            Write-Log 'start wrapper abandoned: engine process gone'
            Show-Toast $script:LastError 'error'
        }
    }
    # 停止包装进程收尾
    if ($script:StopProc) {
        if ($script:StopProc.HasExited) {
            $script:StopProc = $null
            if ($snap.Alive -or $snap.Health) {
                Show-Toast '停止未完成，请重试或查看日志' 'error'
            } else {
                Show-Toast '服务已停止，显存已释放' 'ok'
            }
        }
    }
    if ($snap.Health) { $script:LastError = '' }

    $state = 'stopped'
    if ($snap.Health) { $state = 'running' }
    elseif ($snap.Alive) { $state = 'loading' }
    elseif ($script:StopProc) { $state = 'stopping' }
    elseif ($script:StartProc) { $state = 'starting' }
    elseif ($script:LastError) { $state = 'error' }
    $script:State = $state

    Set-StatusAppearance $state

    # 右侧运行时长
    $uptime = ''
    if ($snap.StartTime -and ($state -eq 'running' -or $state -eq 'loading')) {
        $elapsed = (Get-Date) - $snap.StartTime
        $prefix = '已运行'
        if ($state -eq 'loading') { $prefix = '加载中' }
        $uptime = "$prefix $(Format-Duration $elapsed)"
    }
    $script:Ui.TxtUptime.Text = $uptime

    # 元信息
    $pieces = New-Object System.Collections.ArrayList
    [void]$pieces.Add("$($script:SvcHost):$($script:Port)")
    $ctxLabel = Get-ContextLabel
    if ($ctxLabel) { [void]$pieces.Add($ctxLabel) }
    if ($snap.Pid -gt 0) { [void]$pieces.Add("PID $($snap.Pid)") }
    $script:Ui.TxtMeta.Text = ($pieces -join '   ·   ')

    # 提示行：优先显示短暂消息
    $hint = ''
    $hintColor = '#9A9A9A'
    $toast = $script:Toast
    if ($toast -and (Get-Date) -lt $toast.Until) {
        $hint = $toast.Text
        switch ($toast.Kind) {
            'ok' { $hintColor = '#6CCB5F' }
            'error' { $hintColor = '#FF99A4' }
            'warn' { $hintColor = '#FCE100' }
            default { $hintColor = '#C8C8C8' }
        }
    } else {
        $script:Toast = $null
        switch ($state) {
            'running' { $hint = 'OpenAI 兼容接口已就绪，任意客户端可用' }
            'loading' { $hint = '正在读取模型权重，首次加载约 2–4 分钟，请稍候' }
            'starting' { $hint = '正在拉起引擎进程…' }
            'stopping' { $hint = '正在停止引擎，释放显存…' }
            'error' {
                $hint = $script:LastError
                $hintColor = '#FF99A4'
            }
            default { $hint = '点击「启动服务」加载模型；首次加载约 2–4 分钟' }
        }
    }
    $script:Ui.TxtHint.Text = $hint
    try { $script:Ui.TxtHint.Foreground = Get-Brush $hintColor } catch { }

    # 按钮可用性
    $busy = ($state -eq 'stopping')
    $script:Ui.BtnStart.IsEnabled = (($state -eq 'stopped') -or ($state -eq 'error')) -and -not $busy
    $script:Ui.BtnStop.IsEnabled = (($state -eq 'running') -or ($state -eq 'loading') -or ($state -eq 'starting') -or ($state -eq 'error')) -and -not $busy

    Set-Spin (($state -eq 'starting') -or ($state -eq 'loading') -or ($state -eq 'stopping'))

    if (($script:Tick % 3) -eq 1) { Sync-AutostartUi }
}

function Set-TooltipText {
    param($Element, [string]$Text)
    if (-not $Element) { return }
    $tip = $Element.ToolTip
    if ($tip -is [System.Windows.Controls.ToolTip]) { $tip.Content = $Text }
    else { $Element.ToolTip = $Text }
}

function Sync-AutostartUi {
    $info = Get-AutostartInfo
    $script:SuppressToggle = $true
    try { $script:Ui.ToggleAuto.IsChecked = [bool]$info.On } finally { $script:SuppressToggle = $false }

    if ($info.On) {
        if ($info.Missing) {
            $script:Ui.TxtAutoState.Text = '已开启 · 目标缺失'
            $script:Ui.TxtAutoState.Foreground = Get-Brush '#FF99A4'
            $script:Ui.AutoBadge.Background = Get-Brush '#26FF99A4'
        } else {
            $script:Ui.TxtAutoState.Text = '已开启'
            $script:Ui.TxtAutoState.Foreground = Get-Brush '#6CCB5F'
            $script:Ui.AutoBadge.Background = Get-Brush '#1F6CCB5F'
        }
        Set-TooltipText $script:Ui.ToggleAuto $info.Command
    } else {
        $script:Ui.TxtAutoState.Text = '已关闭'
        $script:Ui.TxtAutoState.Foreground = Get-Brush '#9A9A9A'
        $script:Ui.AutoBadge.Background = Get-Brush '#14FFFFFF'
        Set-TooltipText $script:Ui.ToggleAuto '登录 Windows 后静默加载服务'
    }
}

# ---------------------------------------------------------------- 启动/停止 --
function Start-BasaltService {
    if ($script:StartProc) { return }
    if (-not (Test-Path -LiteralPath $script:StartCmd)) {
        Show-Toast "找不到 $($script:StartCmd)" 'error'
        return
    }
    $exe = Get-Cfg 'BASALT_EXE'
    if ($exe -and -not (Test-Path -LiteralPath $exe)) {
        Show-Toast '引擎未编译：请先运行 build.cmd' 'error'
        return
    }
    $model = Get-Cfg 'MODEL'
    if ($model -and -not (Test-Path -LiteralPath $model)) {
        Show-Toast '模型包缺失：见 bin\fetch-pack.sh 与 logs\fetch-status.txt' 'error'
        return
    }
    $py = Get-Cfg 'PYTHON'
    if ($py -and -not (Test-Path -LiteralPath $py)) {
        Show-Toast 'Python 环境缺失：请重建 venv' 'error'
        return
    }
    $script:LastError = ''
    $script:StartAt = Get-Date
    try {
        $script:StartProc = Start-Process -FilePath $script:StartCmd -ArgumentList 'silent' `
            -WorkingDirectory $script:Root -WindowStyle Hidden -PassThru
        Write-Log "start requested (wrapper pid $($script:StartProc.Id))"
    } catch {
        $script:LastError = '无法启动引擎：' + $_.Exception.Message
        Show-Toast $script:LastError 'error'
        Write-Log "start failed: $($_.Exception.Message)"
        Update-Ui
        return
    }
    Show-Toast '正在启动引擎…' 'info'
    Update-Ui
}

function Stop-BasaltService {
    if ($script:StopProc) { return }
    if (-not (Test-Path -LiteralPath $script:StopCmd)) {
        Show-Toast "找不到 $($script:StopCmd)" 'error'
        return
    }
    # 启动尚未完成时先掐掉启动包装进程（连同其子进程），避免它把服务又拉起来
    if ($script:StartProc -and -not $script:StartProc.HasExited) {
        try { & "$env:SystemRoot\System32\taskkill.exe" /PID $script:StartProc.Id /T /F | Out-Null } catch { }
        $script:StartProc = $null
    }
    try {
        $script:StopProc = Start-Process -FilePath $script:StopCmd -WorkingDirectory $script:Root `
            -WindowStyle Hidden -PassThru
        Write-Log "stop requested (wrapper pid $($script:StopProc.Id))"
        Show-Toast '正在停止服务…' 'info'
    } catch {
        Show-Toast ('停止失败：' + $_.Exception.Message) 'error'
        Write-Log "stop failed: $($_.Exception.Message)"
    }
    Update-Ui
}

function Open-Endpoint {
    if (-not ($script:Snap -and $script:Snap.Health)) {
        Show-Toast '服务尚未就绪，请先启动服务' 'warn'
        Update-Ui
        return
    }
    try { Start-Process $script:Endpoint } catch { Show-Toast '无法打开浏览器' 'error' }
}

function Open-Log {
    $log = $script:LogFile
    if ($log -and (Test-Path -LiteralPath $log)) {
        try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $log) } catch { }
    } else {
        $dir = Join-Path $script:Root 'logs'
        if (Test-Path -LiteralPath $dir) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $dir) }
        else { Show-Toast '日志目录不存在' 'warn'; Update-Ui }
    }
}

function Open-Config {
    try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:ConfigCmd) }
    catch { Show-Toast '无法打开配置文件' 'error'; Update-Ui }
}

# ---------------------------------------------------------------- 单实例/DPI --
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BasaltLauncherNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@ -ErrorAction SilentlyContinue
try { [void][BasaltLauncherNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch {
    try { [void][BasaltLauncherNative]::SetProcessDPIAware() } catch { }
}

if ($StateOnly) {
    $snap = Get-ServiceState
    [pscustomobject]@{
        health    = $snap.Health
        alive     = $snap.Alive
        pid       = $snap.Pid
        autostart = (Get-AutostartInfo).On
    } | ConvertTo-Json -Compress
    return
}

$script:Mutex = $null
try {
    $script:Mutex = [System.Threading.Mutex]::OpenExisting('Local\BasaltLauncher')
    # 已经有一个启动器：把它从最小化/背后叫出来
    try {
        $hwnd = [BasaltLauncherNative]::FindWindow([NullString]::Value, 'Basalt 启动器')
        if ($hwnd -ne [IntPtr]::Zero) {
            [void][BasaltLauncherNative]::ShowWindow($hwnd, 9)   # SW_RESTORE
            [void][BasaltLauncherNative]::SetForegroundWindow($hwnd)
        } else {
            (New-Object -ComObject WScript.Shell).AppActivate('Basalt 启动器') | Out-Null
        }
    } catch { }
    return
} catch {
    $script:Mutex = [System.Threading.Mutex]::new($false, 'Local\BasaltLauncher')
    [void]$script:Mutex.WaitOne(0)
}

# ------------------------------------------------------------------- 界面 --
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Basalt 启动器" Width="496" Height="412"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        FontFamily="Segoe UI Variable Text, Microsoft YaHei UI" FontSize="14" Foreground="#FFFFFF">
  <Window.Resources>
    <!-- 强调色：加载后按系统强调色替换（DynamicResource 保证换刷子也能刷新） -->
    <SolidColorBrush x:Key="AccentBrush" Color="#0078D4"/>
    <SolidColorBrush x:Key="AccentHoverBrush" Color="#1A88DC"/>
    <SolidColorBrush x:Key="AccentPressedBrush" Color="#0069BA"/>
    <SolidColorBrush x:Key="OnAccentBrush" Color="#FFFFFF"/>

    <Style x:Key="Glyph" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="CaptionButton" TargetType="Button">
      <Setter Property="Width" Value="42"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="#C8C8C8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#14FFFFFF"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#0AFFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CaptionClose" TargetType="Button" BasedOn="{StaticResource CaptionButton}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#C42B1C"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#B02A1C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="AccentButton" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource OnAccentBrush}"/>
      <Setter Property="Background" Value="{DynamicResource AccentBrush}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentHoverBrush}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentPressedBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#0FFFFFFF"/>
                <Setter Property="Foreground" Value="#5C5C5C"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SecondaryButton" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Background" Value="#0FFFFFFF"/>
      <Setter Property="BorderBrush" Value="#14FFFFFF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="4" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#17FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#0AFFFFFF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#08FFFFFF"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#0FFFFFFF"/>
                <Setter Property="Foreground" Value="#5C5C5C"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="LinkButton" TargetType="Button">
      <Setter Property="Foreground" Value="#C8C8C8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#0FFFFFFF"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#08FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="ToggleButton">
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="20"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Grid Background="Transparent">
              <Border x:Name="Track" CornerRadius="10" Background="Transparent"
                      BorderBrush="#8A8A8A" BorderThickness="1"/>
              <Ellipse x:Name="Knob" Width="12" Height="12" Fill="#9A9A9A"
                       HorizontalAlignment="Left" Margin="4,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Track" Property="BorderBrush" Value="#C8C8C8"/>
                <Setter TargetName="Knob" Property="Fill" Value="#C8C8C8"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{DynamicResource AccentBrush}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="Transparent"/>
                <Setter TargetName="Track" Property="BorderThickness" Value="0"/>
                <Setter TargetName="Knob" Property="Fill" Value="{DynamicResource OnAccentBrush}"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,4,0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="12">
    <!-- 阴影层（不承载文字，避免 Effect 把整棵子树栅格化） -->
    <Border CornerRadius="8" Background="#000000">
      <Border.Effect>
        <DropShadowEffect BlurRadius="24" ShadowDepth="0" Opacity="0.5" Color="#000000"/>
      </Border.Effect>
    </Border>

    <Border x:Name="RootCard" CornerRadius="8" BorderThickness="1" BorderBrush="#14FFFFFF">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#212121" Offset="0"/>
          <GradientStop Color="#1E1E1E" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="40"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- 标题栏 -->
        <Grid Grid.Row="0">
          <Border x:Name="DragArea" Background="Transparent"/>
          <StackPanel Orientation="Horizontal" Margin="16,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False">
            <Image x:Name="HeaderIcon" Width="16" Height="16"/>
            <TextBlock Text="Basalt 启动器" FontSize="12" Foreground="#C8C8C8" Margin="9,0,0,0"
                       VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,5,5,0">
            <Button x:Name="BtnMin" Style="{StaticResource CaptionButton}" ToolTip="最小化">
              <TextBlock Text="&#xE921;" Style="{StaticResource Glyph}" FontSize="10"/>
            </Button>
            <Button x:Name="BtnClose" Style="{StaticResource CaptionClose}" Margin="2,0,0,0" ToolTip="关闭">
              <TextBlock Text="&#xE8BB;" Style="{StaticResource Glyph}" FontSize="10"/>
            </Button>
          </StackPanel>
        </Grid>

        <!-- 页面内容 -->
        <Grid Grid.Row="1" Margin="24,4,24,18">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <TextBlock Text="本地 AI 推理服务" FontSize="20" FontWeight="SemiBold"
                     FontFamily="Segoe UI Variable Display, Microsoft YaHei UI" Foreground="#FFFFFF"/>
          <TextBlock x:Name="TxtSubtitle" Grid.Row="1" Text="—" FontSize="12" Foreground="#9A9A9A"
                     Margin="0,2,0,0"/>

          <!-- 状态卡 -->
          <Border x:Name="StatusCard" Grid.Row="2" Background="#2B2B2B" BorderBrush="#14FFFFFF"
                  BorderThickness="1" CornerRadius="6" Padding="16,12" Margin="0,16,0,0">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="StatusIcon" Grid.Row="0" Grid.Column="0" Text="&#xE7E8;"
                         Style="{StaticResource Glyph}" FontSize="16" Foreground="#9A9A9A"
                         RenderTransformOrigin="0.5,0.5" VerticalAlignment="Center">
                <TextBlock.RenderTransform>
                  <RotateTransform x:Name="StatusIconRotate" Angle="0"/>
                </TextBlock.RenderTransform>
              </TextBlock>
              <TextBlock x:Name="TxtState" Grid.Row="0" Grid.Column="1" Text="正在检查…"
                         FontSize="14" FontWeight="SemiBold" Foreground="#FFFFFF"
                         Margin="10,0,0,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="TxtUptime" Grid.Row="0" Grid.Column="2" Text=""
                         FontSize="12" Foreground="#9A9A9A" VerticalAlignment="Center"/>
              <TextBlock x:Name="TxtMeta" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" Text="—"
                         FontSize="12" Foreground="#C8C8C8" Margin="10,4,0,0"
                         TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="TxtHint" Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2" Text="—"
                         FontSize="12" Foreground="#9A9A9A" Margin="10,2,0,0" TextWrapping="Wrap"/>
            </Grid>
          </Border>

          <!-- 主按钮 -->
          <Grid Grid.Row="3" Margin="0,16,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="8"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="BtnStart" Style="{StaticResource AccentButton}" Height="34"
                    ToolTip="启动本地服务（首次加载约 2–4 分钟）">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE768;" Style="{StaticResource Glyph}" FontSize="12" Margin="0,0,8,0"/>
                <TextBlock Text="启动服务" FontSize="14" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnStop" Grid.Column="2" Style="{StaticResource SecondaryButton}" Height="34"
                    ToolTip="停止本地服务并释放显存">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE71A;" Style="{StaticResource Glyph}" FontSize="12" Margin="0,0,8,0"/>
                <TextBlock Text="停止服务" FontSize="14" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
          </Grid>

          <!-- 设置卡：开机自启动 -->
          <Border x:Name="SettingsCard" Grid.Row="4" Background="#2B2B2B" BorderBrush="#14FFFFFF"
                  BorderThickness="1" CornerRadius="6" Padding="16,10" Margin="0,12,0,0">
            <Grid>
              <StackPanel VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE7E8;" Style="{StaticResource Glyph}" FontSize="15"
                             Foreground="#C8C8C8" Margin="0,0,10,0"/>
                  <TextBlock Text="开机自启动" FontSize="14" Foreground="#FFFFFF" VerticalAlignment="Center"/>
                  <Border x:Name="AutoBadge" Background="#14FFFFFF" CornerRadius="4" Padding="6,1,6,2"
                          Margin="8,0,0,0" VerticalAlignment="Center">
                    <TextBlock x:Name="TxtAutoState" Text="已关闭" FontSize="11" Foreground="#9A9A9A"/>
                  </Border>
                </StackPanel>
                <TextBlock Text="登录 Windows 后静默加载服务，无需手动启动" FontSize="12"
                           Foreground="#9A9A9A" Margin="25,3,0,0"/>
              </StackPanel>
              <ToggleButton x:Name="ToggleAuto" Style="{StaticResource Switch}"
                            HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
          </Border>

          <!-- 次要操作 -->
          <StackPanel Grid.Row="5" Orientation="Horizontal" Margin="-10,10,0,0">
            <Button x:Name="BtnOpen" Style="{StaticResource LinkButton}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE774;" Style="{StaticResource Glyph}" FontSize="13" Margin="0,0,7,0"/>
                <TextBlock Text="打开网页" FontSize="13" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnLog" Style="{StaticResource LinkButton}" Margin="2,0,0,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE8A5;" Style="{StaticResource Glyph}" FontSize="13" Margin="0,0,7,0"/>
                <TextBlock Text="引擎日志" FontSize="13" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnCfg" Style="{StaticResource LinkButton}" Margin="2,0,0,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE713;" Style="{StaticResource Glyph}" FontSize="13" Margin="0,0,7,0"/>
                <TextBlock Text="参数配置" FontSize="13" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
          </StackPanel>

          <!-- 页脚 -->
          <Grid Grid.Row="7" Margin="0,8,0,0">
            <TextBlock Text="关闭窗口不会停止服务" FontSize="11" Foreground="#7A7A7A"
                       VerticalAlignment="Center"/>
            <TextBlock x:Name="TxtFooter" Text="Basalt · Launcher 1.0" FontSize="11"
                       Foreground="#7A7A7A" HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
        </Grid>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$script:Window = [System.Windows.Markup.XamlReader]::Parse($xamlText)

$ui = @{}
foreach ($name in @('RootCard', 'StatusCard', 'StatusIcon', 'StatusIconRotate', 'TxtState', 'TxtUptime',
                    'TxtMeta', 'TxtHint', 'TxtSubtitle', 'BtnStart', 'BtnStop', 'BtnOpen', 'BtnLog',
                    'BtnCfg', 'ToggleAuto', 'TxtAutoState', 'AutoBadge', 'SettingsCard',
                    'BtnMin', 'BtnClose', 'DragArea', 'HeaderIcon', 'TxtFooter')) {
    $ui[$name] = $script:Window.FindName($name)
}
$script:Ui = $ui

# ------------------------------------------------------------ Fluent 强调色 --
function Get-SystemAccentColor {
    try {
        [void][Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType = WindowsRuntime]
        $uiSettings = New-Object Windows.UI.ViewManagement.UISettings
        $c = $uiSettings.GetColorValue([Windows.UI.ViewManagement.UIColorType]::Accent)
        return [System.Windows.Media.Color]::FromArgb(255, [int]$c.R, [int]$c.G, [int]$c.B)
    } catch {
        return [System.Windows.Media.Color]::FromArgb(255, 0, 120, 212)
    }
}
function Mix-Color {
    param($A, $B, [double]$T)
    return [System.Windows.Media.Color]::FromArgb(255,
        [int][Math]::Round($A.R + ($B.R - $A.R) * $T),
        [int][Math]::Round($A.G + ($B.G - $A.G) * $T),
        [int][Math]::Round($A.B + ($B.B - $A.B) * $T))
}
$script:AccentColor = Get-SystemAccentColor
$white = [System.Windows.Media.Color]::FromArgb(255, 255, 255, 255)
$black = [System.Windows.Media.Color]::FromArgb(255, 0, 0, 0)
$luminance = (0.299 * $script:AccentColor.R + 0.587 * $script:AccentColor.G + 0.114 * $script:AccentColor.B) / 255.0
$script:OnAccentColor = if ($luminance -gt 0.6) { $black } else { $white }

$res = $script:Window.Resources
$res['AccentBrush']        = [System.Windows.Media.SolidColorBrush]::new($script:AccentColor)
$res['AccentHoverBrush']   = [System.Windows.Media.SolidColorBrush]::new((Mix-Color $script:AccentColor $white 0.14))
$res['AccentPressedBrush'] = [System.Windows.Media.SolidColorBrush]::new((Mix-Color $script:AccentColor $black 0.18))
$res['OnAccentBrush']      = [System.Windows.Media.SolidColorBrush]::new($script:OnAccentColor)
$script:AccentBrush = $res['AccentBrush']
$ui.TxtSubtitle.Text = "Basalt 引擎 · 模型 $($script:ModelName) · OpenAI 兼容接口"

# 图标
try {
    $iconPath = Join-Path $script:LauncherDir 'launcher.ico'
    if (Test-Path -LiteralPath $iconPath) {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.UriSource = New-Object System.Uri($iconPath)
        $bmp.EndInit()
        $script:Window.Icon = $bmp
        $ui.HeaderIcon.Source = $bmp
    }
} catch { Write-Log "icon load failed: $($_.Exception.Message)" }

# Fluent ToolTip（弹出层不在 Window 资源树里，逐个塞样式）
function Set-ToolTipStyle {
    param($Element)
    if (-not $Element -or -not $Element.ToolTip) { return }
    $text = $Element.ToolTip
    $tip = New-Object System.Windows.Controls.ToolTip
    $tip.Content = $text
    $tip.Background = Get-Brush '#323232'
    $tip.Foreground = Get-Brush '#FFFFFF'
    $tip.BorderBrush = Get-Brush '#26FFFFFF'
    $tip.Padding = New-Object System.Windows.Thickness(9, 4, 9, 5)
    $tip.FontSize = 12
    $tip.HasDropShadow = $false
    try {
        $tpl = [System.Windows.Markup.XamlReader]::Parse(@'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                 TargetType="{x:Type ToolTip}">
  <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
          BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
    <ContentPresenter/>
  </Border>
</ControlTemplate>
'@)
        $tip.Template = $tpl
    } catch { }
    $Element.ToolTip = $tip
}
foreach ($key in @('BtnStart', 'BtnStop', 'BtnOpen', 'BtnLog', 'BtnCfg', 'BtnMin', 'BtnClose', 'ToggleAuto')) {
    Set-ToolTipStyle $ui[$key]
}

# 页脚版本号：优先读 basalt.exe 的文件版本，读不到就退回已知版本
try {
    $engineVersion = ''
    $exePath = Get-Cfg 'BASALT_EXE'
    if ($exePath -and (Test-Path -LiteralPath $exePath)) {
        $engineVersion = [string](Get-Item -LiteralPath $exePath).VersionInfo.FileVersion
    }
    if (-not $engineVersion) { $engineVersion = '0.4.1' }
    $ui.TxtFooter.Text = "Basalt $engineVersion  ·  Launcher 1.1"
} catch { }

# 事件
$ui.BtnClose.Add_Click({ $script:Window.Close() })
$ui.BtnMin.Add_Click({ $script:Window.WindowState = [System.Windows.WindowState]::Minimized })
$ui.DragArea.Add_MouseLeftButtonDown({ try { $script:Window.DragMove() } catch { } })
$ui.BtnStart.Add_Click({ try { Start-BasaltService } catch { Show-Toast $_.Exception.Message 'error' } })
$ui.BtnStop.Add_Click({ try { Stop-BasaltService } catch { Show-Toast $_.Exception.Message 'error' } })
$ui.BtnOpen.Add_Click({ try { Open-Endpoint } catch { Show-Toast $_.Exception.Message 'error' } })
$ui.BtnLog.Add_Click({ try { Open-Log } catch { Show-Toast $_.Exception.Message 'error' } })
$ui.BtnCfg.Add_Click({ try { Open-Config } catch { Show-Toast $_.Exception.Message 'error' } })
$ui.ToggleAuto.Add_Checked({
    if ($script:SuppressToggle) { return }
    Set-Autostart $true
})
$ui.ToggleAuto.Add_Unchecked({
    if ($script:SuppressToggle) { return }
    Set-Autostart $false
})
$script:Window.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $script:Window.Close() }
})

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(1200)
$script:Timer.Add_Tick({ try { Update-Ui } catch { Write-Log "ui tick failed: $($_.Exception.Message)" } })

$script:Window.Add_Loaded({
    Write-Log "launcher opened (root=$($script:Root))"
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = 0.0
    $anim.To = 1.0
    $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(160))
    $script:Window.BeginAnimation([System.Windows.Window]::OpacityProperty, $anim)
    # 隐藏控制台启动时窗口可能落在其它窗口后面：Topmost 闪一下带回前台
    try {
        $script:Window.Topmost = $true
        $script:Window.Topmost = $false
        $script:Window.Activate() | Out-Null
    } catch { }
    try { Update-Ui } catch { Write-Log "initial ui failed: $($_.Exception.Message)" }
    $script:Timer.Start()
})

$script:Window.Add_Closed({
    $script:Timer.Stop()
    try { $script:SpinStory.Stop($script:Window) } catch { }
    try { $script:Mutex.ReleaseMutex() } catch { }
})

try {
    [void]$script:Window.ShowDialog()
} finally {
    try { $script:Mutex.Dispose() } catch { }
}
