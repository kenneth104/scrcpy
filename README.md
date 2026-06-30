# scrcpy wireless connector

这是一个 Windows 上使用的 `scrcpy` 无线连接小工具。它会自动查找 Android 设备的无线调试端口，连接 `adb`，然后启动 `scrcpy` 投屏。

项目目前主要服务于固定设备和固定局域网环境，默认设备 IP 是：

```text
192.168.1.100
```

## 功能

- 自动优先使用 WinGet 安装的 Google Platform Tools，避免误用 QtScrcpy 等软件自带的旧版 `adb`。
- 启动前检查 `adb` 和 `scrcpy` 是否可用。
- **当天智能缓存**：缓存文件记录上次成功连接的日期和端口。当天第二次及之后连接会优先尝试缓存端口（端口通常还活着，秒连）；过夜首次连接直接跳过缓存（端口已失效，省下约 2 秒无效等待）。
- **mDNS 与 TCP 扫描并行竞速**：缓存不可用时，mDNS 服务发现和 `35000-45000` 端口扫描同时后台启动，谁先给出端口就用谁；先到的端口若连不上，会继续等另一个来源。
- 模式选择对话框在后台竞速进行时同时弹出，不阻塞连接流程。
- 连接后通过 `adb devices` 再次确认设备真正在线，减少“看起来 connected 但实际不可用”的情况。
- 支持选择 Windows 版 `scrcpy` 或 WSL 里的 `scrcpy`。
- 连接断开后弹出重连/退出窗口。
- 自动写入运行日志，方便排查问题。

## 文件说明

| 文件 | 说明 |
| --- | --- |
| `scrcpy_connect.bat` | 推荐入口。双击运行它即可。 |
| `scrcpy_connect.ps1` | 主要逻辑脚本，负责检查环境、扫描端口、连接设备和启动 `scrcpy`。 |
| `scrcpy_port.cache` | 自动生成的端口缓存文件，已被 `.gitignore` 忽略。 |
| `scrcpy_connect.log` | 自动生成的运行日志，已被 `.gitignore` 忽略。 |

## 使用前准备

### 1. 安装 scrcpy

确保 Windows 命令行里可以直接运行：

```powershell
scrcpy --version
```

如果提示找不到命令，需要先安装 `scrcpy`，并把它加入系统 `PATH`。

### 2. 安装 Android Platform Tools

建议通过 WinGet 安装 Google Platform Tools：

```powershell
winget install Google.PlatformTools
```

安装后，脚本会优先使用类似下面路径里的 `adb`：

```text
%LOCALAPPDATA%\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools
```

### 3. 手机开启无线调试

在 Android 设备上开启：

```text
开发者选项 -> 无线调试
```

并确保电脑和手机在同一个局域网内。

## 使用方法

双击运行：

```text
scrcpy_connect.bat
```

启动后会出现模式选择窗口：

- `Windows (scrcpy)`：使用 Windows 中安装的 `scrcpy`。
- `WSL (wsl scrcpy)`：如果 WSL 中也安装了 `scrcpy`，可以选择它；窗口默认会在几秒后选择 WSL。

如果设备断开，脚本会弹出窗口，可以选择重新连接或退出。

## 修改设备 IP

如果手机 IP 变化，需要编辑 `scrcpy_connect.ps1` 顶部的配置：

```powershell
$DEVICE_IP = '192.168.1.100'
```

改成当前手机在局域网中的 IP。

## 常见问题

### 提示 adb not found in PATH

说明系统找不到 `adb`。建议安装 Google Platform Tools，或确认 `adb.exe` 所在目录已经加入系统 `PATH`。

### 提示 scrcpy not found in PATH

说明系统找不到 `scrcpy`。请安装 `scrcpy`，并确认可以在 PowerShell 中直接运行 `scrcpy --version`。

### 提示 IP unreachable

请检查：

- 手机和电脑是否在同一个 Wi-Fi 或局域网。
- 手机无线调试是否仍然开启。
- `scrcpy_connect.ps1` 中的 `$DEVICE_IP` 是否是手机当前 IP。

### 一直找不到设备

可以尝试：

- 在手机开发者选项里关闭再打开无线调试。
- 删除本地的 `scrcpy_port.cache` 后重新运行。
- 查看 `scrcpy_connect.log` 中最近的错误信息。
- 确认手机上是否弹出了 ADB 授权提示，并选择允许。

## GitHub 上传前建议

这个仓库适合提交脚本源码，但不建议提交个人运行状态文件。

当前 `.gitignore` 已忽略：

```gitignore
*.cache
*.log
```

也就是说，`scrcpy_port.cache` 和 `scrcpy_connect.log` 不会被提交到 GitHub。

## 注意事项

- 当前脚本针对固定设备 IP 设计，不是通用多设备管理工具。
- 无线调试端口可能会变化，所以脚本保留了自动扫描逻辑。
- 脚本会对设备执行少量 `adb shell settings` 设置，用于保持连接和优化使用体验。
- 如果要公开到 GitHub，请确认脚本里的设备 IP、日志或其他个人信息是否可以公开。
