#Requires -Version 5.1
<#
    Basalt 启动器（WinUI 3 / Fluent 风格）
    ----------------------------------------------------------------------
    本地 Basalt 推理服务的图形启动器：
      - 启动 / 停止服务（复用项目自带的 start.cmd silent / stop.cmd）
      - 开机自启动开关（HKCU\...\Run\BasaltLocalAI，与 bin\autostart.cmd 同一项）
      - 打开网页、查看引擎日志、编辑 bin\config.cmd
      - 点 ✕ 收进系统托盘（服务继续跑）：托盘菜单可启停服务、收放监控面板与退出，
        偏好存 %LOCALAPPDATA%\BasaltLauncher\settings.json，托盘菜单里可关掉这个行为
      - 监控读数并入：读 /metrics 显示 tok/s / GPU% / 温度 / 显存，托盘悬停同步，
        托盘图标颜色随状态（空闲=强调色、生成=绿、加载=黄、告警=红、停=灰）；
        右下角那块面板仍由 tray\tray.py 画，但以 --no-tray 跑，不再有自己的托盘图标
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

# ---------------------------------------------------------------- 用户偏好 --
# 偏好和「请把窗口显示出来」的凭据都放 %LOCALAPPDATA%：程序装在 Program Files，
# 普通权限（没提权的启动器）写不进自己的目录。
$script:AppDataDir      = Join-Path $env:LOCALAPPDATA 'BasaltLauncher'
$script:SettingsFile    = Join-Path $script:AppDataDir 'settings.json'
$script:ShowRequestFile = Join-Path $script:AppDataDir 'show.request'
$script:CloseToTray     = $true      # 点 ✕ 收进系统托盘；false = 直接退出启动器

function Read-LauncherSettings {
    try {
        if (-not (Test-Path -LiteralPath $script:SettingsFile)) { return }
        $o = [System.IO.File]::ReadAllText($script:SettingsFile) | ConvertFrom-Json
        if ($o -and ($o.PSObject.Properties.Name -contains 'closeToTray')) {
            $script:CloseToTray = [bool]$o.closeToTray
        }
    } catch { Write-Log "settings read failed: $($_.Exception.Message)" }
}

function Save-LauncherSettings {
    try {
        if (-not (Test-Path -LiteralPath $script:AppDataDir)) {
            [void][System.IO.Directory]::CreateDirectory($script:AppDataDir)
        }
        (@{ closeToTray = [bool]$script:CloseToTray } | ConvertTo-Json -Compress) |
            Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    } catch { Write-Log "settings write failed: $($_.Exception.Message)" }
}

Read-LauncherSettings

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

# ------------------------------------------------ 监控读数（原托盘监控并入）--
# 右下角那块面板还是 tray\tray.py 画的，但「在生成什么、多少 tok/s、多热、显存多少」
# 现在这边也有一份：状态卡多一行、托盘悬停跟着变、托盘图标颜色跟着变、告警从这里弹。
$script:Metrics     = $null
$script:LiveState   = ''
$script:Alerted     = @{}
$script:MetricsNext = $null
$script:WarnActive  = $false

function To-Gib {
    param($Value)
    if ($null -eq $Value) { return $null }
    try { return ([double]$Value / 1GB) } catch { return $null }
}

function Get-MetricsSnapshot {
    # 服务没起来时拿不到是常态：不写日志、不弹东西，静默返回 $null
    try {
        $req = [System.Net.HttpWebRequest]::Create("$($script:Endpoint)/metrics")
        $req.Method = 'GET'
        $req.Timeout = 900
        $req.ReadWriteTimeout = 900
        $req.KeepAlive = $false
        $req.Proxy = $null
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $text = $sr.ReadToEnd()
        $sr.Close()
        $resp.Close()
        $m = $text | ConvertFrom-Json
    } catch {
        return $null
    }
    if (-not $m) { return $null }
    $gpu = $null
    if ($m.hardware -and $m.hardware.gpus -and (@($m.hardware.gpus).Count -gt 0)) { $gpu = @($m.hardware.gpus)[0] }
    $state = 'idle'
    if ($m.live -and $m.live.state) { $state = [string]$m.live.state }
    $hist = @()
    if ($m.history -and $m.history.tok_s) { $hist = @($m.history.tok_s) }
    $tok = $null
    if ($m.live -and ($null -ne $m.live.tok_s)) { $tok = $m.live.tok_s }
    if (($state -ne 'generating') -and $hist.Count -gt 0) { $tok = $hist[-1] }   # 空闲时给上一段的收尾速度
    $util = $null; $temp = $null; $memUsed = $null; $memTotal = $null
    if ($gpu) {
        $util = $gpu.util
        $temp = $gpu.temp
        $memUsed = To-Gib $gpu.mem_used
        $memTotal = To-Gib $gpu.mem_total
    }
    $ramUsed = $null; $ramTotal = $null
    if ($m.hardware) {
        $ramUsed = To-Gib $m.hardware.ram_used
        $ramTotal = To-Gib $m.hardware.ram_total
    }
    return [pscustomobject]@{
        State    = $state
        TokS     = $tok
        Util     = $util
        Temp     = $temp
        MemUsed  = $memUsed
        MemTotal = $memTotal
        RamUsed  = $ramUsed
        RamTotal = $ramTotal
    }
}

function Get-StateLabel {
    param([string]$State)
    switch ($State) {
        'running'  { return '运行中' }
        'loading'  { return '正在加载模型' }
        'starting' { return '正在启动' }
        'stopping' { return '正在停止' }
        'error'    { return '启动失败' }
        default    { return '已停止' }
    }
}

function Get-LiveLabel {
    param([string]$State)
    switch ($State) {
        'generating' { return '生成中' }
        'reading'    { return '读取中' }
        'loading'    { return '加载中' }
        'unloaded'   { return '未加载' }
        'asleep'     { return '休眠中' }
        default      { return '空闲' }
    }
}

function Format-MetricsLine {
    param($M)
    if (-not $M) { return '' }
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add((Get-LiveLabel $M.State))
    if ($null -ne $M.TokS) { [void]$parts.Add(('{0:0.0} tok/s' -f [double]$M.TokS)) }
    if ($null -ne $M.Util) { [void]$parts.Add(('GPU {0}%' -f [int]$M.Util)) }
    if ($null -ne $M.Temp) { [void]$parts.Add(('{0}°C' -f [int]$M.Temp)) }
    if ($null -ne $M.MemUsed -and $null -ne $M.MemTotal -and $M.MemTotal -gt 0) {
        [void]$parts.Add(('显存 {0:0}/{1:0}G' -f $M.MemUsed, $M.MemTotal))
    }
    return ($parts -join '   ·   ')
}

function Update-Metrics {
    # 约 3.6 秒一次（tick 是 1.2 秒）：够跟上面板的节奏，又不把自己变成第二个监控进程
    if ($script:MetricsNext -and (Get-Date) -lt $script:MetricsNext) { return }
    $script:MetricsNext = (Get-Date).AddSeconds(3.6)
    $m = Get-MetricsSnapshot
    if ($m) {
        $script:Metrics = $m
        $script:LiveState = $m.State
    } elseif ($script:State -ne 'running') {
        # 服务不在（或刚停）就清空；running 时偶发超时留着上一次的读数，免得数字乱跳
        $script:Metrics = $null
        $script:LiveState = ''
    }
    $line = Format-MetricsLine $script:Metrics
    if ($script:Ui.TxtMetrics) {
        $script:Ui.TxtMetrics.Text = $line
        if ($line) { $script:Ui.TxtMetrics.Visibility = [System.Windows.Visibility]::Visible }
        else { $script:Ui.TxtMetrics.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    Update-TrayTip
    Update-TrayIconColor
    Watch-Metrics
}

function Watch-Metrics {
    param($M)
    # 阈值和 tray.py 一致：温度 85°C / 显存 98.5% / 内存 95%，同一个键 15 分钟只弹一次
    $script:WarnActive = $false
    if (-not $M -or ($script:State -ne 'running')) { return }
    $items = @()
    if ($null -ne $M.Temp -and [double]$M.Temp -ge 85) {
        $items += , @('temp', "GPU 温度 $($M.Temp)°C，快到限频了，注意进风和散热")
    }
    if ($null -ne $M.MemUsed -and $null -ne $M.MemTotal -and $M.MemTotal -gt 0 -and
        (($M.MemUsed / $M.MemTotal) -ge 0.985)) {
        $items += , @('mem', '显存几乎占满（>98.5%），再大的上下文或并行可能顶不住')
    }
    if ($null -ne $M.RamUsed -and $null -ne $M.RamTotal -and $M.RamTotal -gt 0 -and
        (($M.RamUsed / $M.RamTotal) -ge 0.95)) {
        $items += , @('ram', '系统内存占用超过 95%，Windows 已经开始吃紧')
    }
    if ($items.Count -gt 0) { $script:WarnActive = $true }   # 有告警时托盘图标也跟着变红
    foreach ($item in $items) {
        $key = $item[0]
        $last = $null
        if ($script:Alerted.ContainsKey($key)) { $last = $script:Alerted[$key] }
        if ($last -and ((Get-Date) - $last).TotalSeconds -lt 900) { continue }
        $script:Alerted[$key] = Get-Date
        Show-Toast $item[1] 'warn'
    }
}

# -------------------------------------------------------- 监控面板（tray.py）--
# 托盘图标归这一份之后，面板自己不再挂图标；由这边负责收放它，没跑就顺手拉起来。
# 窗口类名 BasaltTrayPanel、标题「Basalt 监控」，见 tray\tray.py 的 create_panel。
$script:PanelClass = 'BasaltTrayPanel'

function Find-PanelWindow {
    # 第二参数必须是真正的 NULL：PowerShell 的 $null 会被绑成空字符串，FindWindow 就当标题等于""去匹配，永远找不到
    try {
        return [BasaltLauncherNative]::FindWindow($script:PanelClass, [NullString]::Value)
    } catch {
        Write-Log "panel lookup failed: $($_.Exception.Message)"
        return [IntPtr]::Zero
    }
}

function Get-PanelProcesses {
    try {
        return @(Get-CimInstance -ClassName Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" `
                    -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -like '*tray.py*' })
    } catch { return @() }
}

function Start-MonitorPanel {
    $py = Join-Path $script:Root 'venv\Scripts\pythonw.exe'
    $entry = Join-Path $script:Root 'tray\tray.py'
    if (-not (Test-Path -LiteralPath $entry)) {
        Show-Toast "没找到监控面板入口：$entry" 'warn'
        return $false
    }
    if (-not (Test-Path -LiteralPath $py)) { $py = 'pythonw.exe' }
    try {
        Start-Process -FilePath $py -ArgumentList "`"$entry`" --no-tray" -WindowStyle Hidden | Out-Null
        Write-Log 'monitor panel started (--no-tray)'
        return $true
    } catch {
        Show-Toast "监控面板启动失败：$($_.Exception.Message)" 'error'
        Write-Log "panel start failed: $($_.Exception.Message)"
        return $false
    }
}

function Show-MonitorPanel {
    # 只管"让面板露出来"：没跑就拉起，藏了显示，已经显示就提到最前（按 panel.pos 里的「总在最前」偏好定层级）
    $h = Find-PanelWindow
    if ($h -eq [IntPtr]::Zero) {
        # 窗口找不到，先确认是不是进程还在（还在就别再拉一份，会被它自己的互斥挡下）
        $procs = Get-PanelProcesses
        if (@($procs).Count -gt 0) {
            $pids = (@($procs | ForEach-Object { $_.ProcessId }) -join ',')
            Write-Log "panel window not found but process alive pid=$pids"
            Show-Toast "监控面板进程还在（PID $pids），但找不到它的窗口；在面板右键菜单里退出它再点这里。" 'warn'
            return $false
        }
        if (-not (Start-MonitorPanel)) { return $false }
        Start-Sleep -Milliseconds 900        # 等它把分层窗口建出来
        $h = Find-PanelWindow
        if ($h -eq [IntPtr]::Zero) { return $true }
    }
    if (-not [BasaltLauncherNative]::IsWindowVisible($h)) {
        [void][BasaltLauncherNative]::ShowWindow($h, 4)      # SW_SHOWNOACTIVATE：露出来但不抢焦点
    }
    # 「总在最前」是面板自己的偏好，存在 tray\panel.pos，照它的勾选放回层级
    $topmost = $true
    try {
        $posFile = Join-Path $script:Root 'tray\panel.pos'
        if (Test-Path -LiteralPath $posFile) {
            $pos = [System.IO.File]::ReadAllText($posFile) | ConvertFrom-Json
            if ($null -ne $pos.topmost) { $topmost = [bool]$pos.topmost }
        }
    } catch { }
    try {
        # 想让它露头必须走"先抬进置顶带、再撤掉置顶"这两步：直接给 HWND_NOTOPMOST
        # 对本来就不置顶的窗口不产生任何挪动（实测面板会被别的窗口一直压着）。
        [void][BasaltLauncherNative]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x13)   # HWND_TOPMOST
        $after = [IntPtr](-2)                                 # HWND_NOTOPMOST：落到非置顶带的最前面
        if ($topmost) { $after = [IntPtr](-1) }               # 面板勾了「总在最前」就留在置顶带
        [void][BasaltLauncherNative]::SetWindowPos($h, $after, 0, 0, 0, 0, 0x13)         # NOMOVE|NOSIZE|NOACTIVATE
    } catch { }
    return $true
}

function Toggle-MonitorPanel {
    $h = Find-PanelWindow
    if (($h -ne [IntPtr]::Zero) -and [BasaltLauncherNative]::IsWindowVisible($h)) {
        [void][BasaltLauncherNative]::ShowWindow($h, 0)      # SW_HIDE
        return
    }
    [void](Show-MonitorPanel)
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
$script:PrevState = ''      # 上一轮的状态，用来看「服务自己掉了」这种非用户发起的变化
$script:Snap      = $null
$script:Tick      = 0
$script:Toast     = $null
$script:SuppressToggle = $false
$script:SpinStory = $null
$script:Ui        = @{}

function Show-Toast {
    param([string]$Text, [string]$Kind = 'info', [int]$Seconds = 5)
    $script:Toast = @{ Text = $Text; Kind = $Kind; Until = (Get-Date).AddSeconds($Seconds) }
    # 窗口收进托盘时界面里的提示行看不见，改成托盘气泡，否则启动/停止的结果就没人知道了
    if ($script:Hidden -and ($Kind -eq 'ok' -or $Kind -eq 'error')) {
        Show-Balloon 'Basalt 启动器' $Text $Seconds
    }
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
    # 服务自己没了（不是在启动器里按的停止）得出声：以前是面板图标变红 + 气泡，现在归这一份
    if (($script:PrevState -eq 'running') -and ($state -ne 'running') -and -not $script:StopProc) {
        Show-Toast '服务不在运行了（不是在启动器里停的），看看引擎日志' 'error'
    }
    $script:PrevState = $script:State
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

    # 监控读数（内部限流到约 3.6 秒一次）：状态卡多一行 + 托盘悬停 + 图标颜色 + 告警
    Update-Metrics

    # 托盘：状态一变就同步提示文字和菜单可用性
    if ($script:Tray) { Set-TrayStatus $state }
    # 收在托盘时，别的实例（比如又双击了一次快捷方式）会留下「请显示」的凭据
    if ($script:Hidden) { Test-ShowRequest }

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
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadImage(IntPtr hInst, string name, uint type, int cx, int cy, uint fuLoad);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);
    // 这个 API 收的是 PCWSTR。默认 CharSet=Ansi 会把 ASCII 字节按 UTF-16 两两配对，
    // AUMID 就变成「楙督獥…」这种怪字（Win11 通知头部直接显示这串乱码，还没有图标）。
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);
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

# 给启动器独立的任务栏身份 + 通知身份。
# 注意：AUMID 必须先在 HKCU\Software\Classes\AppUserModelId 里注册（DisplayName / IconUri），
# 否则 Win11 通知顶部的"应用名"会渲染成乱码、连图标都不出（实测：没注册=乱码一行，注册后=「Basalt 启动器」+我们的图标）。
$script:Aumid = 'Yimuer.Basalt.Launcher'

function Register-NotificationIdentity {
    try {
        $key = "HKCU:\Software\Classes\AppUserModelId\$script:Aumid"
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -Path $key -Name DisplayName -Value 'Basalt 启动器' -ErrorAction Stop
        $png = Join-Path $script:LauncherDir 'launcher.png'
        if (Test-Path $png) { Set-ItemProperty -Path $key -Name IconUri -Value $png -ErrorAction Stop }
        return $true
    } catch {
        Write-Log "notification identity not registered: $($_.Exception.Message)"
        return $false
    }
}

[void](Register-NotificationIdentity)
try { [void][BasaltLauncherNative]::SetCurrentProcessExplicitAppUserModelID($script:Aumid) } catch {
    Write-Log "SetCurrentProcessExplicitAppUserModelID failed: $($_.Exception.Message)"
}

$script:Mutex = $null
try {
    $script:Mutex = [System.Threading.Mutex]::OpenExisting('Local\BasaltLauncher')
    # 已经有一个启动器：把它从最小化/背后叫出来
    try {
        $hwnd = [BasaltLauncherNative]::FindWindow([NullString]::Value, 'Basalt 启动器')
        if ($hwnd -ne [IntPtr]::Zero -and [BasaltLauncherNative]::IsWindowVisible($hwnd)) {
            [void][BasaltLauncherNative]::ShowWindow($hwnd, 9)   # SW_RESTORE
            [void][BasaltLauncherNative]::SetForegroundWindow($hwnd)
        } else {
            # 窗口收在托盘里（WPF 自己 Hide 的）：外部 ShowWindow 会让 WPF 的状态和
            # 实际可见性不一致、可能画成空白，所以只留一个「请显示」的凭据，
            # 由正在跑的那个实例在自己的轮询里显示回来（见 Test-ShowRequest）。
            try {
                if (-not (Test-Path -LiteralPath $script:AppDataDir)) {
                    [void][System.IO.Directory]::CreateDirectory($script:AppDataDir)
                }
                (Get-Date).ToString('o') | Set-Content -LiteralPath $script:ShowRequestFile -Encoding ASCII
                Write-Log 'second instance: asked the running one to show itself'
            } catch { Write-Log "show request failed: $($_.Exception.Message)" }
            try { (New-Object -ComObject WScript.Shell).AppActivate('Basalt 启动器') | Out-Null } catch { }
        }
    } catch { }
    return
} catch {
    $script:Mutex = [System.Threading.Mutex]::new($false, 'Local\BasaltLauncher')
    [void]$script:Mutex.WaitOne(0)
    # 上一次退出前留下的「请显示」凭据对新一轮没有意义
    try { Remove-Item -LiteralPath $script:ShowRequestFile -Force -ErrorAction SilentlyContinue } catch { }
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
              <TextBlock x:Name="TxtMetrics" Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2" Text=""
                         FontSize="12" Foreground="#79C0FF" Margin="10,4,0,0"
                         TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
              <TextBlock x:Name="TxtHint" Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="2" Text="—"
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
            <Button x:Name="BtnPanel" Style="{StaticResource LinkButton}" Margin="2,0,0,0"
                    ToolTip="显示 / 隐藏右下角的 Basalt 监控面板（没开就顺手拉起来，它不再有自己的托盘图标）">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE7E8;" Style="{StaticResource Glyph}" FontSize="13" Margin="0,0,7,0"/>
                <TextBlock Text="监控面板" FontSize="13" VerticalAlignment="Center"/>
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
            <TextBlock x:Name="TxtCloseHint" Text="关闭窗口不会停止服务" FontSize="11" Foreground="#7A7A7A"
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
                    'TxtMeta', 'TxtMetrics', 'TxtHint', 'TxtSubtitle', 'BtnStart', 'BtnStop', 'BtnOpen', 'BtnLog',
                    'BtnPanel', 'BtnCfg', 'ToggleAuto', 'TxtAutoState', 'AutoBadge', 'SettingsCard',
                    'BtnMin', 'BtnClose', 'DragArea', 'HeaderIcon', 'TxtFooter', 'TxtCloseHint')) {
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

# 图标：WPF 直接解码 ICO 会默认选 16×16，再把它居中塞进任务栏的大图标里。
# 因此 ImageSource 使用高分辨率 PNG；窗口小/大 HICON 在 Loaded 后按系统尺寸从 ICO 加载。
$script:IconPath = Join-Path $script:LauncherDir 'launcher.ico'
$script:BigIconHandle = [IntPtr]::Zero
$script:SmallIconHandle = [IntPtr]::Zero
try {
    $iconPngPath = Join-Path $script:LauncherDir 'launcher.png'
    $iconSourcePath = if (Test-Path -LiteralPath $iconPngPath) { $iconPngPath } else { $script:IconPath }
    if (Test-Path -LiteralPath $iconSourcePath) {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.DecodePixelWidth = 256
        $bmp.UriSource = New-Object System.Uri($iconSourcePath)
        $bmp.EndInit()
        $bmp.Freeze()
        $script:Window.Icon = $bmp
        $ui.HeaderIcon.Source = $bmp
    }
} catch { Write-Log "icon load failed: $($_.Exception.Message)" }

function Set-NativeWindowIcons {
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($script:Window)).Handle
        if ($hwnd -eq [IntPtr]::Zero -or -not (Test-Path -LiteralPath $script:IconPath)) { return }
        $bigSize = [BasaltLauncherNative]::GetSystemMetrics(11)       # SM_CXICON
        $smallSize = [BasaltLauncherNative]::GetSystemMetrics(49)     # SM_CXSMICON
        $script:BigIconHandle = [BasaltLauncherNative]::LoadImage(
            [IntPtr]::Zero, $script:IconPath, 1, $bigSize, $bigSize, 0x10)
        $script:SmallIconHandle = [BasaltLauncherNative]::LoadImage(
            [IntPtr]::Zero, $script:IconPath, 1, $smallSize, $smallSize, 0x10)
        if ($script:BigIconHandle -ne [IntPtr]::Zero) {
            [void][BasaltLauncherNative]::SendMessage($hwnd, 0x80, [IntPtr]1, $script:BigIconHandle)
        }
        if ($script:SmallIconHandle -ne [IntPtr]::Zero) {
            [void][BasaltLauncherNative]::SendMessage($hwnd, 0x80, [IntPtr]::Zero, $script:SmallIconHandle)
        }
    } catch { Write-Log "native icon update failed: $($_.Exception.Message)" }
}

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
    $ui.TxtFooter.Text = "Basalt $engineVersion  ·  Launcher 1.3"
} catch { }

# ------------------------------------------------------------ 系统托盘 --
# WPF 自己没有托盘图标。这里用 WinForms 的 NotifyIcon：它靠线程的消息循环收事件，
# 与 WPF 的 Dispatcher 消息泵兼容。图标对象必须由脚本自己持有、退出前 Dispose，
# 否则通知区域会留下点一下才消失的「幽灵」图标。
$script:Tray          = $null
$script:TrayMenu      = $null
$script:TrayState     = ''
$script:Hidden        = $false
$script:ExitRequested = $false
$script:SessionEnding = $false
$script:TrayHintShown = $false
$script:ShowRequestTick = ''
$script:SessionHook   = $null
$script:TrayHico      = [IntPtr]::Zero   # 自己画的彩色托盘图标句柄，换色/退出时要 DestroyIcon
$script:TrayColor     = ''
$script:TrayClickTimer = $null           # 托盘单击的去抖定时器（让双击能留给主窗口）
$script:AccentHex     = ''

function Test-TrayAvailable {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [void][System.Windows.Forms.NotifyIcon]
        [void][System.Windows.Forms.ContextMenuStrip]
        return $true
    } catch {
        Write-Log "tray unavailable: $($_.Exception.Message)"
        return $false
    }
}

function Get-TrayIcon {
    # launcher.ico 是多尺寸的；直接 new Icon(path) 拿到的是文件里第一档（256 px），
    # 缩到托盘的 16 px 会糊，所以按系统尺寸挑最接近的一档。
    try {
        if (Test-Path -LiteralPath $script:IconPath) {
            try {
                return New-Object System.Drawing.Icon($script:IconPath,
                    [System.Windows.SystemParameters]::SmallIconWidth,
                    [System.Windows.SystemParameters]::SmallIconHeight)
            } catch {
                return New-Object System.Drawing.Icon($script:IconPath)
            }
        }
    } catch { Write-Log "tray icon load failed: $($_.Exception.Message)" }
    return [System.SystemIcons]::Application
}

function Add-RoundedPath {
    param($Path, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$R)
    $d = $R * 2
    if (($d -le 0) -or ($d -ge $W) -or ($d -ge $H)) { $d = [Math]::Min($W, $H) - 1 }
    [void]$Path.AddArc($X, $Y, $d, $d, 180, 90)
    [void]$Path.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
    [void]$Path.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
    [void]$Path.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
    [void]$Path.CloseFigure()
}

function Get-TrayColorHex {
    # 颜色语义照 tray.py 那套：生成=绿、加载/读取/停止=黄、告警=红、空闲=系统强调色、没服务=灰
    if (-not $script:AccentHex) {
        try {
            $a = $script:AccentColor
            $script:AccentHex = ('#{0:X2}{1:X2}{2:X2}' -f $a.R, $a.G, $a.B)
        } catch { $script:AccentHex = '#60CDFF' }
    }
    if ($script:State -eq 'error') { return '#FF6264' }
    if (($script:State -eq 'starting') -or ($script:State -eq 'loading') -or ($script:State -eq 'stopping')) {
        return '#FFCD3D'
    }
    if ($script:State -ne 'running') { return '#6E6E6E' }
    if ($script:WarnActive) { return '#FF6264' }
    switch ($script:LiveState) {
        'generating' { return '#6CCB5F' }
        'reading'    { return '#FFCD3D' }
        'loading'    { return '#FFCD3D' }
        'unloaded'   { return '#9A9A9A' }
        default      { return $script:AccentHex }
    }
}

function New-StateTrayIcon {
    param([string]$Hex)
    # 圆角卡片 + 三根柱子，形状抄 tray.py 的 mark_icon；颜色就是状态。
    # SystemParameters 给的是 DIP，按窗口 DPI 放大后再画，不然高缩放机器上会糊。
    $scale = 1.0
    try {
        $src = [System.Windows.PresentationSource]::FromVisual($script:Window)
        if ($src) { $scale = [double]$src.CompositionTarget.TransformToDevice.M11 }
    } catch { }
    $w = [int][Math]::Round([System.Windows.SystemParameters]::SmallIconWidth * $scale)
    $h = [int][Math]::Round([System.Windows.SystemParameters]::SmallIconHeight * $scale)
    if ($w -lt 12) { $w = 16 }
    if ($h -lt 12) { $h = 16 }
    $html = [System.Drawing.ColorTranslator]::FromHtml($Hex)
    $col = [System.Drawing.Color]::FromArgb(255, $html.R, $html.G, $html.B)
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $pad = [int][Math]::Max(1, ($w / 16))
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        Add-RoundedPath $path $pad $pad ($w - 2 * $pad) ($h - 2 * $pad) ([int][Math]::Max(2, ($w / 5)))
        $bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 22, 26, 32))
        $pen = New-Object System.Drawing.Pen($col, [Math]::Max(1.5, ($w / 12)))
        $g.FillPath($bg, $path)
        $g.DrawPath($pen, $path)
        $brush = New-Object System.Drawing.SolidBrush($col)
        $barW = [Math]::Max(2.0, ($w / 9.0))
        $base = $h - 2 * $pad - 2
        $k = 0
        foreach ($frac in @(0.42, 0.72, 1.0)) {
            $x0 = $pad + 3 + ($k * ($barW + 3))
            $top = $base - [int][Math]::Round((($h - 4 * $pad - 8) * $frac))
            $g.FillRectangle($brush, [single]$x0, [single]$top, [single]$barW, [single]($base - $top))
            $k++
        }
        $path.Dispose(); $bg.Dispose(); $pen.Dispose(); $brush.Dispose()
    } finally {
        $g.Dispose()
    }
    $hicon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hicon)
    $bmp.Dispose()
    return $icon
}

function Update-TrayIconColor {
    if (-not $script:Tray) { return }
    $hex = Get-TrayColorHex
    if ($hex -eq $script:TrayColor) { return }
    $oldIcon = $script:Tray.Icon
    $oldHico = $script:TrayHico
    $icon = $null
    try {
        $icon = New-StateTrayIcon $hex
        $script:TrayColor = $hex
        $script:Tray.Icon = $icon
    } catch {
        Write-Log "tray icon color failed: $($_.Exception.Message)"
        if ($icon) { try { $icon.Dispose() } catch { } }
        return
    }
    # 换下来的图标要 Dispose + DestroyIcon，否则 GDI 句柄一点点漏光
    if ($oldIcon) { try { $oldIcon.Dispose() } catch { } }
    if ($oldHico -ne [IntPtr]::Zero) {
        try { [void][BasaltLauncherNative]::DestroyIcon($oldHico) } catch { }
    }
    try { $script:TrayHico = $icon.Handle } catch { $script:TrayHico = [IntPtr]::Zero }
}

function New-TrayMenuItem {
    param([string]$Text, $OnClick, [bool]$Checkable = $false)
    $item = New-Object System.Windows.Forms.ToolStripMenuItem
    $item.Text = $Text
    if ($Checkable) { $item.Checked = [bool]$script:CloseToTray }
    if ($OnClick) { $item.Add_Click($OnClick) }
    return $item
}

function New-TrayIcon {
    if ($script:Tray) { return $script:Tray }
    $ni = $null
    try {
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = Get-TrayIcon
        $ni.Text = 'Basalt 启动器'
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $script:MenuShow = New-TrayMenuItem '显示主窗口' { Show-FromTray }
        $script:MenuStart = New-TrayMenuItem '启动服务' { Invoke-TrayAction 'start' }
        $script:MenuStop = New-TrayMenuItem '停止服务' { Invoke-TrayAction 'stop' }
        $script:MenuOpen = New-TrayMenuItem '打开网页' { Open-Endpoint }
        $script:MenuPanel = New-TrayMenuItem '显示 / 隐藏监控面板' { Toggle-MonitorPanel }
        $script:MenuTrayPref = New-TrayMenuItem '关闭时收进托盘' `
            { Set-CloseToTray (-not $script:CloseToTray) } $true
        foreach ($item in @($script:MenuShow, (New-Object System.Windows.Forms.ToolStripSeparator),
                             $script:MenuStart, $script:MenuStop, $script:MenuOpen, $script:MenuPanel,
                             (New-Object System.Windows.Forms.ToolStripSeparator), $script:MenuTrayPref,
                             (New-Object System.Windows.Forms.ToolStripSeparator),
                             (New-TrayMenuItem '退出' { Exit-Launcher }))) {
            [void]$menu.Items.Add($item)
        }
        $ni.ContextMenuStrip = $menu
        # 单击 = 叫出监控面板（原来那个「Basalt 监控」图标的习惯）；双击 = 叫回主窗口。
        # 单击要先压 ~260ms：双击必然先来两下 Click，等得到 MouseDoubleClick 就改主意，免得两个一起弹。
        $ni.Add_MouseClick({
            param($sender, $e)
            if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
            if ($script:TrayClickTimer) { try { $script:TrayClickTimer.Stop() } catch { } }
            $timer = New-Object System.Windows.Threading.DispatcherTimer
            $timer.Interval = [TimeSpan]::FromMilliseconds(260)
            $timer.Add_Tick({
                param($s, $ev)
                $s.Stop()
                if ($script:TrayClickTimer -eq $s) { $script:TrayClickTimer = $null }
                [void](Show-MonitorPanel)
            })
            $script:TrayClickTimer = $timer
            $timer.Start()
        })
        $ni.Add_MouseDoubleClick({
            if ($script:TrayClickTimer) {
                try { $script:TrayClickTimer.Stop() } catch { }
                $script:TrayClickTimer = $null
            }
            Show-FromTray
        })
        $ni.Visible = $true
        $script:TrayMenu = $menu
        $script:Tray = $ni
        $script:TrayState = ''
        Set-TrayStatus $script:State
        Update-TrayIconColor
        Write-Log 'tray icon created'
    } catch {
        Write-Log "tray icon failed: $($_.Exception.Message)"
        try { if ($ni) { $ni.Dispose() } } catch { }
        $script:Tray = $null
    }
    return $script:Tray
}

function Remove-TrayIcon {
    if (-not $script:Tray) { return }
    try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch { }
    if ($script:TrayHico -ne [IntPtr]::Zero) {
        try { [void][BasaltLauncherNative]::DestroyIcon($script:TrayHico) } catch { }
        $script:TrayHico = [IntPtr]::Zero
    }
    $script:Tray = $null
    $script:TrayMenu = $null
    $script:TrayColor = ''
}

function Show-Balloon {
    param([string]$Title, [string]$Text, [int]$Seconds = 5)
    if (-not $script:Tray) { return }
    try {
        $kind = [System.Windows.Forms.ToolTipIcon]::Info
        if ($Text -match '失败|无法|缺失|错误') { $kind = [System.Windows.Forms.ToolTipIcon]::Warning }
        $script:Tray.ShowBalloonTip($Seconds * 1000, $Title, $Text, $kind)
    } catch { Write-Log "balloon failed: $($_.Exception.Message)" }
}

function Get-TrayTip {
    # NotifyIcon.Text 上限 63 字符；放不下就从最后面（最不重要的）开始丢
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add("Basalt 启动器 · 服务$(Get-StateLabel $script:State)")
    $m = $script:Metrics
    if ($m) {
        [void]$parts.Add((Get-LiveLabel $m.State))
        if ($null -ne $m.TokS) { [void]$parts.Add(('{0:0.0} tok/s' -f [double]$m.TokS)) }
        if ($null -ne $m.Util) { [void]$parts.Add(('GPU {0}%' -f [int]$m.Util)) }
        # 63 字上限从尾部往上丢：温度先丢，显存留下（这台机器最该盯的就是它）
        if ($null -ne $m.MemUsed -and $null -ne $m.MemTotal -and $m.MemTotal -gt 0) {
            [void]$parts.Add(('显存 {0:0}/{1:0}G' -f $m.MemUsed, $m.MemTotal))
        }
        if ($null -ne $m.Temp) { [void]$parts.Add(('{0}°C' -f [int]$m.Temp)) }
    }
    for ($n = $parts.Count; $n -ge 1; $n--) {
        $tip = ($parts[0..($n - 1)] -join ' · ')
        if ($tip.Length -le 60) { return $tip }
    }
    return 'Basalt 启动器'
}

function Update-TrayTip {
    if (-not $script:Tray) { return }
    try { $script:Tray.Text = Get-TrayTip } catch { Write-Log "tray text failed: $($_.Exception.Message)" }
}

function Set-TrayStatus {
    param([string]$State)
    if (-not $script:Tray) { return }
    if ($State -eq $script:TrayState) { return }
    $script:TrayState = $State
    Update-TrayTip
    Update-TrayIconColor
    if ($script:MenuStart) { $script:MenuStart.Enabled = (($State -eq 'stopped') -or ($State -eq 'error')) }
    if ($script:MenuStop) {
        $script:MenuStop.Enabled = (($State -eq 'running') -or ($State -eq 'loading') -or
                                    ($State -eq 'starting') -or ($State -eq 'error'))
    }
    if ($script:MenuOpen) { $script:MenuOpen.Enabled = ($State -eq 'running') }
}

function Invoke-TrayAction {
    param([string]$Which)
    try {
        if ($Which -eq 'start') { Start-BasaltService } else { Stop-BasaltService }
    } catch {
        Show-Balloon 'Basalt 启动器' $_.Exception.Message 6
        return
    }
    if ($script:Hidden) {
        if ($Which -eq 'start') { Show-Balloon 'Basalt 启动器' '已请求启动引擎，加载约 2–4 分钟；托盘提示会跟着变。' 5 }
        else { Show-Balloon 'Basalt 启动器' '已请求停止服务。' 5 }
    }
}

# 页脚那行和 ✕ 的提示语跟着开关走
function Update-CloseHint {
    if ($script:CloseToTray) {
        Set-TooltipText $script:Ui.BtnClose '收进托盘（服务继续运行）'
        if ($script:Ui.TxtCloseHint) {
            $script:Ui.TxtCloseHint.Text = '点 ✕ 收进系统托盘，服务继续运行；托盘右键「退出」才关程序'
        }
    } else {
        Set-TooltipText $script:Ui.BtnClose '退出启动器（服务不受影响）'
        if ($script:Ui.TxtCloseHint) { $script:Ui.TxtCloseHint.Text = '关闭窗口不会停止服务' }
    }
}

function Set-CloseToTray {
    param([bool]$On)
    $script:CloseToTray = [bool]$On
    Save-LauncherSettings
    if ($script:MenuTrayPref) { $script:MenuTrayPref.Checked = $script:CloseToTray }
    Update-CloseHint
    Write-Log "close to tray = $($script:CloseToTray)"
}

function Hide-ToTray {
    if ($script:Hidden) { return }
    if (-not $script:Tray) { New-TrayIcon }
    if (-not $script:Tray) { return }          # 托盘建不起来就别把窗口藏没了
    $script:Window.Hide()
    $script:Hidden = $true
    Write-Log 'launcher hidden to tray'
    if (-not $script:TrayHintShown) {
        $script:TrayHintShown = $true
        Show-Balloon 'Basalt 启动器已收进托盘' `
            ('点 ✕ 不再退出程序：服务继续跑，启动器待在右下角托盘里。' + "`n" +
             '单击托盘图标 = 叫出监控面板；双击 = 叫回这个窗口；右键 = 菜单（选「退出」才会真正关掉程序）。') 8
    }
}

function Show-FromTray {
    if (-not $script:Hidden) {
        try {
            $script:Window.Topmost = $true
            $script:Window.Topmost = $false
            $script:Window.Activate() | Out-Null
        } catch { }
        return
    }
    try {
        $script:Window.Show()
        $script:Window.WindowState = [System.Windows.WindowState]::Normal
        $script:Window.Topmost = $true
        $script:Window.Topmost = $false
        $script:Window.Activate() | Out-Null
        $script:Hidden = $false
        Write-Log 'launcher restored from tray'
    } catch { Write-Log "restore from tray failed: $($_.Exception.Message)" }
    try { Update-Ui } catch { }
}

function Exit-Launcher {
    $script:ExitRequested = $true
    Remove-TrayIcon
    try { $script:Window.Close() } catch { }
}

# 另一个实例（比如又双击了一次快捷方式）留下的「请显示」凭据：时间戳变了就显示窗口
function Test-ShowRequest {
    try {
        if (-not (Test-Path -LiteralPath $script:ShowRequestFile)) { return }
        $stamp = [System.IO.File]::GetLastWriteTimeUtc($script:ShowRequestFile).ToString('o')
        if ($stamp -eq $script:ShowRequestTick) { return }
        $script:ShowRequestTick = $stamp
        Remove-Item -LiteralPath $script:ShowRequestFile -Force -ErrorAction SilentlyContinue
        Write-Log 'show request consumed'
        Show-FromTray
    } catch { Write-Log "show request check failed: $($_.Exception.Message)" }
}

# 注销/关机时必须放行关闭窗口，否则上面 Cancel 掉关闭会把 Windows 的会话结束卡住
function Add-SessionEndHook {
    try {
        $src = [System.Windows.Interop.HwndSource]::FromVisual($script:Window)
        if (-not $src) { return }
        $script:SessionHook = [System.Windows.Interop.HwndSourceHook]{
            param($hWnd, $msg, $wParam, $lParam, [ref]$handled)
            $code = [Int64]$msg
            if (($code -eq 0x0011) -or ($code -eq 0x0016)) {   # WM_QUERYENDSESSION / WM_ENDSESSION
                if (-not $script:SessionEnding) {
                    $script:SessionEnding = $true
                    Write-Log 'session ending: letting the launcher close'
                    Remove-TrayIcon
                }
            }
            return [IntPtr]::Zero
        }
        $src.AddHook($script:SessionHook)
    } catch { Write-Log "session-end hook failed: $($_.Exception.Message)" }
}

# 事件
$ui.BtnClose.Add_Click({ $script:Window.Close() })
# ✕ / Alt+F4 / Esc 都走 Window.Close()：收进托盘还是真退出在这里定
$script:Window.Add_Closing({
    param($sender, $e)
    if ($script:ExitRequested -or $script:SessionEnding) { return }
    if ($script:CloseToTray) {
        if (-not $script:Tray) { New-TrayIcon }
        if ($script:Tray) {
            $e.Cancel = $true
            Hide-ToTray
            return
        }
        # 托盘没建起来：这次就正常退出，别把用户关在门外
        $script:ExitRequested = $true
    }
})
$ui.BtnMin.Add_Click({ $script:Window.WindowState = [System.Windows.WindowState]::Minimized })
$ui.DragArea.Add_MouseLeftButtonDown({ try { $script:Window.DragMove() } catch { } })
$ui.BtnStart.Add_Click({ try { Start-BasaltService } catch { Show-Toast $_.Exception.Message 'error' } })
$ui.BtnStop.Add_Click({ try { Stop-BasaltService } catch { Show-Toast $_.Exception.Message 'error' } })
$ui.BtnOpen.Add_Click({ try { Open-Endpoint } catch { Show-Toast $_.Exception.Message 'error' } })
$ui.BtnLog.Add_Click({ try { Open-Log } catch { Show-Toast $_.Exception.Message 'error' } })
$ui.BtnCfg.Add_Click({ try { Open-Config } catch { Show-Toast $_.Exception.Message 'error' } })
$ui.BtnPanel.Add_Click({ try { Toggle-MonitorPanel } catch { Show-Toast $_.Exception.Message 'error' } })
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
    Set-NativeWindowIcons
    # 托盘：先探一下能不能用（用不了就退回「关窗口即退出」），再把 ✕ 和页脚的文案对齐
    if ($script:CloseToTray -and -not (Test-TrayAvailable)) {
        $script:CloseToTray = $false
        Show-Toast '系统托盘不可用，窗口仍按原样关闭退出' 'warn'
    }
    Update-CloseHint
    Add-SessionEndHook
    try { Update-Ui } catch { Write-Log "initial ui failed: $($_.Exception.Message)" }
    $script:Timer.Start()
})

$script:Window.Add_Closed({
    $script:Timer.Stop()
    Remove-TrayIcon
    try { $script:SpinStory.Stop($script:Window) } catch { }
    if ($script:BigIconHandle -ne [IntPtr]::Zero) {
        [void][BasaltLauncherNative]::DestroyIcon($script:BigIconHandle)
    }
    if ($script:SmallIconHandle -ne [IntPtr]::Zero) {
        [void][BasaltLauncherNative]::DestroyIcon($script:SmallIconHandle)
    }
    try { $script:Mutex.ReleaseMutex() } catch { }
    # 消息泵是手动跑的（见文件末尾），窗口真关掉了才叫它停，脚本才会收尾退出
    try { $script:Window.Dispatcher.InvokeShutdown() } catch { Write-Log "dispatcher shutdown failed: $($_.Exception.Message)" }
})

try {
    # 这里不能用 ShowDialog：对话框模式下一 Hide() 就会返回、脚本走到末尾进程就退了
    # （托盘收起也就没了）。改成 Show + 自己跑消息泵，真退出时在 Closed 里停机。
    $script:Window.Show()
    [System.Windows.Threading.Dispatcher]::Run()   # 静态方法：跑本线程（UI 线程）的消息泵
} finally {
    try { $script:Mutex.ReleaseMutex() } catch { }
    try { $script:Mutex.Dispose() } catch { }
}
