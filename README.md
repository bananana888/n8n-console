# n8n 控制台 (n8n-console)

A lightweight Windows desktop console (PowerShell + WinForms) that starts/stops any command-line service and auto-installs its missing environment. 一个轻量 Windows 控制台：一键启停任意命令行服务，环境缺失自动安装，内置进度条。

## 这是什么

一个「通用后台进程启停器 + 环境自检自动安装」的 Windows 桌面控制台。默认管理 **n8n**（工作流自动化平台），通过配置可复用管任意命令行服务（如 PI agent、deepseek harness 等）。

## 为什么用

- **一键启停**，状态实时显示（运行中**绿灯慢闪** / 启动中黄灯 / 停止灰色）
- **环境缺失自动装**：检测到没有 node / n8n 时，确认后自动下载安装，窗口内**进度条实时展示**，装完自动继续启动
- **便携免管理员**：node 装到控制台目录 `tools\`，不污染系统 PATH
- **一套壳子多服务**：`-ConfigFile` 指定不同配置即可复用
- 日志自动轮转、单实例锁、防误操作

## 安装

1. 下载 [`n8n-console-setup.exe`](release/n8n-console-setup.exe)（或 `setup.msi`）到 Windows x64 电脑
2. 双击安装（默认装到**用户目录**，免管理员，自动创建桌面快捷方式）
3. 双击桌面「n8n 控制台」→ 点 **▶ 启动**

> 首次启动若检测到缺 node/n8n，会弹确认，自动完成安装（全程进度条）。

## 使用

| 操作 | 说明 |
|---|---|
| **▶ 启动** | 启动服务；环境缺失则自动安装后启动 |
| **■ 停止** | 确认后停止（含子进程） |
| **ⓘ 详情** | 查看 PID / 端口 / 日志路径 |

命令行备选：

```powershell
powershell -ExecutionPolicy Bypass -File n8n.ps1 -Action start -Silent   # 静默启动
powershell -ExecutionPolicy Bypass -File n8n.ps1 -Action status -Silent  # 查状态
```

## 进阶：复用为任意服务的壳子

复制 `example.config.psd1` 为「服务名.config.psd1」，按注释填写启动命令 / 端口 / 健康检查：

```powershell
powershell -ExecutionPolicy Bypass -File n8n.ps1 -ConfigFile 服务名.config.psd1
```

详见 [`example.config.psd1`](example.config.psd1)（逐字段中文注释）与 [`n8n.config.psd1`](n8n.config.psd1)（完整示例）。

## 许可

[MIT](LICENSE) · [更新日志](CHANGELOG.md)
