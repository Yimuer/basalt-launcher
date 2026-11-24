# Basalt Launcher 3（WinUI 3）

Basalt 本地引擎启动器的 WinUI 3 版本。默认使用系统 **Mica** 材质，可切换 Mica Alt、Desktop Acrylic 或实色；标题栏跟随浅色/深色主题。引擎、启动器自身和监控面板的登录自启由界面管理；`BasaltFetchResume` 不归此程序管理。

## 功能

- 每 3 秒读取 `/health` 与 `/metrics`：模型、引擎版本、上下文、GPU/显存/温度/CPU、tok/s、累计请求。
- 从 `bin\config.cmd` 读取 `HOST`、`PORT`、`PIDFILE`，展开 `%BASALT_ROOT%`，显示引擎运行时长。
- 启动/停止沿用 `start.cmd silent` 与 `stop.cmd`；Web UI 和监控面板沿用现有安装。
- 单实例；第二实例会叫回主窗口。关闭可收进托盘，支持 `--start-in-tray`。单击托盘会显示并置顶已有 `BasaltTrayPanel`（隐藏窗口也能叫回，不重复启动），悬停提示每 3 秒携带状态、tok/s、GPU、显存与温度。
- 偏好写入 `%LOCALAPPDATA%\BasaltLauncher\settings.json`，沿用 `theme`、`material`、`closeToTray`，保留未知键（包括 WPF 版的 `startTrayHintShown`）。
- 自启管理 `BasaltLocalAI`、`BasaltLauncher`、`BasaltTrayMonitor` 三项；不改变当前正在运行的进程。

## 运行要求

- 推荐 Windows 11；本机实测为 Windows 11 ARM64。
- 默认 framework-dependent 包需要 **.NET 8 Desktop Runtime** 与 **Windows App SDK Runtime 2.7**。
- 目标框架 `net8.0-windows10.0.19041.0`，最低平台版本 `10.0.17763.0`。Mica 的实际呈现由 Windows 版本和系统透明效果设置决定；透明效果关闭时按实色背景显示。

## 构建与发布

```powershell
# 在源码根目录
powershell -ExecutionPolicy Bypass -File .\build.ps1
powershell -ExecutionPolicy Bypass -File .\publish.ps1
# 可选：.NET 与 Windows App SDK 都自包含
powershell -ExecutionPolicy Bypass -File .\publish.ps1 -SelfContained
```

默认发布输出：`artifacts\publish\win-arm64-framework-dependent`。发布脚本会额外带上本项目 XBF/PRI；本机实测 WAS 2.7 的 unpackaged publish 漏掉这些文件时，exe 会以 `0xC000027B` 退出。

将发布输出复制为安装包中的 `app` 文件夹，再运行 `install-launcher3.cmd`。安装器会请求管理员权限并复制到 `%ProgramFiles%\basalt\launcher3`。

## 默认入口与回滚

`launcher\launch.vbs` 是唯一调度入口：存在 `launcher3\BasaltLauncher3.exe` 时启动 WinUI 3，并把旧参数 `-StartInTray` 转为 `--start-in-tray`；不存在时回退到原 WPF `launcher.ps1`。桌面/开始菜单快捷方式与 `BasaltLauncher` 自启无需修改。

回滚：用随附的 `launch.vbs.wpf` 覆盖 `launcher\launch.vbs`，或移走 `launcher3`。WPF 的 `launcher.ps1` 保持原样。

## 调试/测试参数

- `--dry-run`：启停和打开面板只显示命令，不执行。
- `--backdrop mica|micaalt|acrylic|none`：临时覆盖本次材质，不覆盖已保存偏好。
- `--start-in-tray`：启动时不显示窗口。
- `BASALT_ROOT`：覆盖 Basalt 根目录探测。
- `BASALT_AUTOSTART_KEY`：把自启读写重定向到 HKCU 下的测试键，避免测试修改真实 Run 项。

## 已验证与边界

已实测：深浅主题和标题栏、三种系统材质/实色切换、真实引擎轮询、端口与 PIDFILE 解析、设置重启持久化、关闭到托盘、第二实例叫回、三项自启在独立注册表键上的读写、发布包独立启动、调度器 WinUI/WPF 两分支。

托盘图标的可见位置由 Windows shell 策略决定，程序不提升图标，也不写 `NotifyIconSettings`。系统透明效果的运行时切换监听未单独实测。