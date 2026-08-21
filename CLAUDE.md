# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

本仓库是 **n8n 本地实例的 Windows 桌面运维控制台**（PowerShell 5.1 + WinForms），负责 n8n（开源工作流自动化平台，2.35.4）的启动/停止/状态查看/系统托盘/日志管理。已重构为"**通用后台进程启停器 + 配置外置**"：进程控制逻辑与 n8n 解耦，n8n 相关全部在 `n8n.config.psd1`。详细人工交接说明见 `HANDOFF.md`。

## 目录职责（关键架构：两个分离的目录）

| 目录 | 内容 | 职责 |
|---|---|---|
| `D:\APP\n8n` | n8n 本体（`node_modules`、数据 `.n8n`、`.npmrc`） | 应用本体，**日常不动** |
| `D:\APP\n8n-console`（本仓库） | 控制台（脚本/配置/日志/图标/运行时状态） | 运维入口，改动都在这 |

n8n 环境事实：
- 数据目录在 `D:\APP\n8n\.n8n\.n8n\`——n8n 2.x 会把 `.n8n` 拼到 `N8N_USER_FOLDER` 之后（`@n8n/config/dist/utils/utils.js` 的 `join(userHome, '.n8n')`），所以配置 `N8N_USER_FOLDER=D:\APP\n8n\.n8n` 时真数据在嵌套目录里。**这个配置值是对的，不能改。**
- 访问 http://localhost:5678，健康检查 http://localhost:5678/healthz
- **node 必须 >=22.22**（见下方踩坑第 1 条）

## 文件结构（重构后）

```
n8n-console/
├── n8n.ps1              主入口：加载配置 + 点源 lib + 分派（-Action menu/start/stop/status，-Silent 静默）
├── n8n-control.ps1      兼容垫片：仅一行转发 n8n.ps1（桌面快捷方式仍指向它，勿删）
├── n8n.config.psd1      全部配置（PS 数据文件，含中文注释；缺键由脚本内置默认兜底）
├── lib/
│   ├── config.ps1       Get-Config -Root <控制台根目录>：加载 psd1 + 默认值深度合并 + 路径解析
│   ├── logging.ps1      日志：Write-CtrlLog（审计 control.log）/ Write-FatalLog（兜底 error.log）
│   ├── service.ps1      纯进程控制（无 UI，返回结构化 hashtable 结果）
│   └── gui.ps1          WinForms UI（状态卡片/hover/托盘/1s 刷新）
├── assets\n8n.ico
├── logs\    run\
```

关键机制：
- **点源（dot-source）加载**而非 .psm1 模块：所有 lib 共享入口脚本同一作用域，WinForms 事件闭包与 `$script:` 变量行为不变。
- **配置驱动**：路径全部从 `$script:Config.Paths` 取；`Get-Config` 必须传 `-Root`（config.ps1 在 lib\ 下，其 `$PSScriptRoot` 指向 lib\，不能用它定位根目录/psd1）。
- 所有含中文文件须 **UTF-8 BOM**（PS5.1 中文必需）。

## 常用命令

```powershell
# GUI 控制面板（桌面快捷方式即此命令，经垫片转发）
powershell -ExecutionPolicy Bypass -File D:\APP\n8n-console\n8n.ps1
# 静默操作（自动化/测试，结果只写 logs\control.log，不弹窗不开浏览器）
powershell -ExecutionPolicy Bypass -File D:\APP\n8n-console\n8n.ps1 -Action start -Silent
powershell -ExecutionPolicy Bypass -File D:\APP\n8n-console\n8n.ps1 -Action stop -Silent
powershell -ExecutionPolicy Bypass -File D:\APP\n8n-console\n8n.ps1 -Action status -Silent
```

- `-Action`：`menu`(默认 GUI) / `start` / `stop` / `status`
- 无测试框架；状态验证 `-Action status -Silent`，健康验证 `curl http://localhost:5678/healthz`（应返回 `{"status":"ok"}`）
- 升级 n8n：`cd D:\APP\n8n && npm update n8n`（先停止；升级前备份 `D:\APP\n8n\.n8n\.n8n\database.sqlite`）
- 重建快捷方式：`python D:\APP\n8n-console\create_shortcut.py`（需 Python 3 + pylnk3）

## 架构要点

### lib/service.ps1 —— 纯进程控制
- `Start-ManagedService`：防重复启动（PID+进程名校验）→ 端口占用检查 → 定位 exe（**绝对路径优先，PATH 兜底**）→ **exe 预检**（`--version`，抓损坏/无法运行并给明确报错）→ 清前端缓存 → `[Diagnostics.Process]`+`CreateNoWindow` 启动并注入 config.Env → 立即写 PID → 健康轮询（`/healthz` 每 500ms，**传入 PID，进程死亡立即判失败**，避免"启动即退"白等满超时）→ **稳定性复检窗口**（`StabilityCheckSec`，默认 4s，抓"端口已开但随后崩溃"）→ 成功写时间戳 / 失败清状态文件。返回 `@{Ok;Message;PID;LogTail}`。
- `Stop-ManagedService`：`taskkill /T /F`（进程树连坐）→ 等端口释放 → 清状态文件。
- `Get-ManagedStatus`：`@{Running;PID;Port;StartedAt}`。**进程未运行时跳过端口探测**（本机 127.0.0.1 connect 有延迟，每秒 UI 刷新若每次查端口会卡顿）；PID 文件里的无效 PID **自愈清理**。
- 无任何 MessageBox；呈现由调用方负责。

### n8n.ps1 —— 入口
加载配置 → 点源 lib → 定义 `Show-Msg`/`Show-YesNo`（Silent 时只写日志）→ switch 分派。GUI 模式进 `Show-Gui`（阻塞）。顶层 try/catch 兜底写 `logs\error.log`。

### lib/gui.ps1 —— 仅呈现（PS5.1 事件闭包陷阱见踩坑 5）
- **启动是异步的**：点启动 → 独立 runspace 执行 `Start-ManagedService`（BeginInvoke），500ms 轮询完成，UI 线程不冻结（否则健康检查+稳定性复检会锁死界面 15~38s）。⚠️ 判断 job 完成必须用 `$script:_bgHandle.IsCompleted`（IAsyncResult）；**`PowerShell` 类没有 `HasCompleted` 属性（返回 $null），用它判断会导致 job 永不"完成"→ 界面永久停在黄灯**（2026-08-21 实测 bug）。另有 90s 超时兜底强制清理。
- **状态圆点慢闪**：独立 200ms `dotFlashTimer` 做呼吸动画（运行中绿→暗绿、启动中金、停止灰），颜色存 `$script:StateDotColor`，Paint 直接读它。
- **无托盘**：关闭窗口 = 直接退出控制台（FormClosing 停所有 Timer，不做隐藏驻留）。n8n 进程独立，退出控制台不影响它，重开即可管理。
- **内联提示（toast）**：启动/停止结果不弹 MessageBox，而是复用底部提示行 `$script:_lblHint` 临时显示（`Show-Toast`，成功绿 `✓`/失败红 `⚠`，摘要取首行截断 46 字符），约 4s 后恢复默认文案。**仅"详情"（`Show-Status`）保留 MessageBox**。
- `Refresh-UI`（1s Timer）用 `Get-ManagedStatus` 刷新；后台启动中（`$script:_bgJob`）时保持"启动中"显示不覆盖。
- **窗体布局**：用 `ClientSize`（380×206，非 Size，Size 含边框会压窄内容区导致右边截断）+ `AutoScaleMode=None`（防 DPI 缩放拉伸溢出）；控件宽 352 从 x=12 起，右边留 14px 余量。

## 关键约束与踩坑（改动必读）

1. **node 版本（最容易踩）**：n8n 2.35.4 要求 **node >=22.22**，版本不够会"启动即退"（`Your Node.js version ... not supported`）。2026-08-21 已修复：把 `C:\Users\SCY004730\.workbuddy\binaries\node\versions\22.22.2` **置顶回用户 PATH**（之前被 TRAE 自带 v22.16.0 顶掉）。`n8n.config.psd1` 里 `Executable` 仍保持指向 22.22.2 绝对路径做**双保险**——即使 PATH 再被 workbuddy 更新顶掉，控制台也不受影响。若 workbuddy 目录被清理，需装 node>=22.22 并更新配置。
2. **UTF-8 BOM**：所有含中文的 .ps1/.psd1 必须 BOM；改完检查（`head -c3 | xxd -p` 应为 `efbbbf`）。
3. **`$home` 是只读自动变量**：config.ps1 里用 `$homeDir`（历史 bug：赋值 $home 报 VariableNotWritable）。
4. **Logs.\* 是纯文件名**：目录由 `Console.LogDir` 决定；别再写 `logs\xxx.log`（会双重前缀 `logs\logs`）。
5. **PS5.1 WinForms 事件闭包陷阱（重构后实测，最重要）**：.NET 事件 handler 里**引用函数局部变量会解析为 $null**（如 `$btn`/`$timer`/`$form`），导致"在此对象上找不到属性 Target"这类异常。事件 handler 必须用 **`$this`**（自动绑定 sender）或 **`$script:_xxx`** 访问状态，**禁止捕获 New-HoverButton / Show-Gui 的局部变量**。当前实现：状态容器（含 Button+Timer 引用）同时挂到 `btn.Tag` 和 `timer.Tag`（Component.Tag），handler 统一 `$st = $this.Tag` 访问；`$form`/`$notify`/刷新 timer 走 `$script:_form`/`$script:_notify`/`$script:_refreshTimer`。Paint 事件另需显式 delegate 转换 + `param($sender,$e)`（`$EventArgs` 自动变量仅 Register-ObjectEvent 可用）。
6. **Control.Tag 用 Hashtable**：PSCustomObject 跨 .NET 边界 setter 不可靠。
7. **N8N_RUNNERS_ENABLED=false**：规避无 Python 启动崩溃；Python Code 节点不可用。2.35.4 下 JS runner 仍会注册（无害）。
8. **EPERM 韧性**：n8n 启动解压前端资源到 `{N8N_USER_FOLDER}\.cache\n8n\public\`，文件被锁会 EPERM 崩溃。已做：启动前清缓存（`CleanCacheOnStart`）+ 稳定性复检兜底。

## 排障速查

| 症状 | 排查路径 |
|---|---|
| 启动即退 / 进程秒退 | 先看 `logs\error.log` 与 `logs\n8n.log` 尾部。`not supported` → node 版本 <22.22（见踩坑 1）；`EPERM ... .cache` → 前端缓存被锁（自动清缓存已兜底） |
| 健康检查通过但进程随后死 | 稳定性复检（`StabilityCheckSec`）会抓到并附日志尾 |
| 端口 5678 被占 | `netstat -ano \| findstr 5678` 找 PID，taskkill 或控制台停止 |
| 页面打不开 | `curl http://localhost:5678/healthz`；无响应先启动再查 |
| run\n8n.pid 残留死 PID | 无需手动清，`Get-ManagedProcessId` 会自愈清理 |
| 图标白块 | 桌面 F5；重建 .lnk 用 create_shortcut.py |
