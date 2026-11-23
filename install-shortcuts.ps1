# Basalt 启动器 —— 创建桌面 / 开始菜单快捷方式（当前用户，免管理员）
# 由 launcher 目录下的 launcher.ps1 使用，可重复运行（覆盖旧快捷方式）。
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs = Join-Path $here 'launch.vbs'
$icon = Join-Path $here 'launcher.ico'
$ps1 = Join-Path $here 'launcher.ps1'

foreach ($required in @($vbs, $ps1)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "缺少文件：$required" }
}
if (-not (Test-Path -LiteralPath $icon)) { $icon = $ps1 }

$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$ws = New-Object -ComObject WScript.Shell

$dirs = @(
    [Environment]::GetFolderPath('Desktop'),
    [Environment]::GetFolderPath('Programs')
)

foreach ($dir in $dirs) {
    if (-not $dir) { continue }
    $path = Join-Path $dir 'Basalt 启动器.lnk'
    $lnk = $ws.CreateShortcut($path)
    $lnk.TargetPath = $wscript
    $lnk.Arguments = '"' + $vbs + '"'
    $lnk.WorkingDirectory = $here
    $lnk.IconLocation = $icon + ',0'
    $lnk.Description = 'Basalt 本地 AI 服务：启动 / 停止 / 开机自启动'
    $lnk.Save()

    # 读回校验
    $check = $ws.CreateShortcut($path)
    [pscustomobject]@{
        Path   = $path
        Target = $check.TargetPath
        Args   = $check.Arguments
        Icon   = $check.IconLocation
    }
}
