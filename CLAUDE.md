# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

本仓库是 **n8n 本地实例的 Windows 桌面运维控制台**（PowerShell 5.1 + WinForms），负责 n8n（开源工作流自动化平台，2.35.4）的启动/停止/状态查看/日志管理。已重构为"**通用后台进程启停器 + 配置外置**"：进程控制逻辑与 n8n 解耦，n8n 相关全部在 `n8n.config.psd1`，用 `-ConfigFile` 可复用管任意命令行服务（多实例）。详细人工交接说明见 `HANDOFF.md`。

## ⚠️ 当前环境注意（迁移后，改动/运行前必读）

- **本机 git 主仓库在 `E:\ProgramFiles\n8n-console`**。仓库内文档（`CLAUDE.md`/`HANDOFF.md`）与 `n8n.config.psd1` 中残留的 `D:\APP\n8n-console` / `D:\APP\n8n` / `C:\Users\SCY004730\...` 是**迁移前的路径，本机不存在**（`D:\APP` 目录不存在，本机用户是 `C:\Users\Allen`，`E:\ProgramFiles\n8n` 为空目录——n8n 本体未装）。
- `n8n.config.psd1` 当前路径配置全部指向旧环境：`Service.Executable=C:\Users\SCY004730\.workbuddy\...\22.22.2\node.exe`、`WorkingDir/Arguments/Env` 指向 `D:\APP\n8n`。**在本机运行/测试前，必须先按实际环境修正这些路径**（或另存一个 `-ConfigFile` 配置），否则启动会因找不到目录/exe 而失败。
- 本机可用的 node：`D:\Nodejs\node.exe`（v24.14.0，在 PATH）、`C:\Users\Allen\.workbuddy\binaries\node\versions\22.22.2\node.exe`（n8n 2.35.4 要求 **node >=22.22**，见踩坑 1）。
- 仓库根下 `n8n-console/` 是一个**嵌套 git 副本**（有自己的 `.git`，内容与仓库根相同，未跟踪、历史遗留）。**改动一律以仓库根为准，勿编辑子目录。**
- 打包已从 Inno Setup 改为 **WiX**（见"打包"一节）；`packaging/installer.iss` 是遗留文件，未参与当前构建。

## 目录职责（关键架构：两个分离的目录）

| 目录 | 内容 | 职责 |
|---|---|---|
| `<n8n 本体>`（迁移前为 `D:\APP\n8n`） | n8n 本体（`node_modules`、数据 `.n8n`、`.npmrc`） | 应用本体，**日常不动** |
| `E:\ProgramFiles\n8n-console`（本仓库） | 控制台（脚本/配置/日志/图标/运行时状态/打包） | 运维入口，改动都在这 |

n8n 环境事实（本体路径以 `n8n.config.psd1` 的 `Service.WorkingDir`/`Env` 为准）：
- 数据目录是 `{WorkingDir}\.n8n\.n8n\`——n8n 2.x 会把 `.n8n` 拼到 `N8N_USER_FOLDER` 之后（`@n8n/config/dist/utils/utils.js` 的 `join(userHome, '.n8n')`），所以配置 `N8N_USER_FOLDER=D:\APP\n8n\.n8n` 时真数据在嵌套目录里。**这个配置值是对的，不能改。**
- 访问 http://localhost:5678，健康检查 http://localhost:5678/healthz
- **node 必须 >=22.22**（见踩坑 1）

## 文件结构

```
n8n-console/
├── n8n.ps1              主入口：加载配置 + 点源 lib + 分派（-Action menu/start/stop/status，-Silent，-ConfigFile 多实例，-Version）
├── n8n-control.ps1      兼容垫片：仅一行转发 n8n.ps1（本地 create_shortcut.py 仍指向它，勿删）
├── n8n-console.exe      编译启动器（C# winexe，见"打包"节；安装包快捷方式指向它）
├── n8n.config.psd1      全部配置（PS 数据文件，含中文注释；缺键由脚本内置默认兜底）
├── example.config.psd1  通用配置模板（复用壳子管其它服务时复制改）
├── lib/
│   ├── config.ps1       Get-Config -Root <控制台根目录>：加载 psd1 + 默认值深度合并 + 路径解析
│   ├── logging.ps1      日志：Write-CtrlLog（审计 control.log）/ Write-FatalLog（兜底 error.log），>2MB 滚动保留 3 份
│   ├── service.ps1      纯进程控制（无 UI，返回结构化 hashtable 结果）
│   ├── setup.ps1        环境自检 + 自动安装（Test-SetupNeeded / Invoke-Setup，进度写 run\<实例>.setup.json）
│   └── gui.ps1          WinForms UI（状态卡片/hover/1s 刷新 + 安装进度面板；无托盘）
├── packaging/           build.ps1 打包脚本（WiX v3 → release\setup.msi + setup.exe）+ *.wxs + n8n-console.cs
├── create_shortcut.py   重建本地桌面快捷方式（Python + pylnk3）
├── launcher.vbs         vbs 无窗口启动器（卡巴斯基拦截，默认未用，备用）
├── assets\n8n.ico
├── release\             打包产物（gitignore 排除）
├── logs\    run\        运行时产物（gitignore 排除）
```

关键机制：
- **点源（dot-source）加载**而非 .psm1 模块：所有 lib 共享入口脚本同一作用域，WinForms 事件闭包与 `$script:` 变量行为不变。
- **配置驱动**：路径全部从 `$script:Config.Paths` 取；`Get-Config` 必须传 `-Root`（config.ps1 在 lib\ 下，其 `$PSScriptRoot` 指向 lib\，不能用它定位根目录/psd1）。
- 所有含中文文件须 **UTF-8 BOM**（PS5.1 中文必需，.ps1/.psd1 实测均带 `efbbbf`）。

## 常用命令

```powershell
# GUI 控制面板
powershell -ExecutionPolicy Bypass -File E:\ProgramFiles\n8n-console\n8n.ps1
# 静默操作（自动化/测试，结果只写 logs\control.log，不弹窗不开浏览器）
powershell -ExecutionPolicy Bypass -File E:\ProgramFiles\n8n-console\n8n.ps1 -Action start -Silent
powershell -ExecutionPolicy Bypass -File E:\ProgramFiles\n8n-console\n8n.ps1 -Action stop -Silent
powershell -ExecutionPolicy Bypass -File E:\ProgramFiles\n8n-console\n8n.ps1 -Action status -Silent
# 版本查询
powershell -ExecutionPolicy Bypass -File E:\ProgramFiles\n8n-console\n8n.ps1 -Version
```

- `-Action`：`menu`(默认 GUI) / `start` / `stop` / `status`；`-Silent` 只写日志；`-ConfigFile <xxx.config.psd1>` 切多实例
- 无测试框架；状态验证 `-Action status -Silent`，健康验证 `curl http://localhost:5678/healthz`（应返回 `{"status":"ok"}`）
- 升级 n8n：先停止，`cd <n8n本体> && npm update n8n`；升级前备份数据 `database.sqlite`
- 重建本地快捷方式：`python E:\ProgramFiles\n8n-console\create_shortcut.py`（需 Python 3 + pylnk3）

## 架构要点

### lib/service.ps1 —— 纯进程控制
- `Start-ManagedService`：防重复启动（PID+进程名校验）→ 端口占用检查 → 定位 exe（**便携 node 优先 `tools\node-<版本>`，配置绝对路径次之，PATH 兜底**）→ **exe 预检**（`--version`，抓损坏/无法运行并给明确报错）→ 清前端缓存 → `[Diagnostics.Process]`+`CreateNoWindow` 启动并注入 config.Env → 立即写 PID → 健康轮询（`/healthz` 每 500ms，**传入 PID，进程死亡立即判失败**，避免"启动即退"白等满超时）→ **稳定性复检窗口**（`StabilityCheckSec`，默认 4s，抓"端口已开但随后崩溃"）→ 成功写时间戳 / 失败清状态文件。返回 `@{Ok;Message;PID;LogTail}`。
- `Stop-ManagedService`：`taskkill /T /F`（进程树连坐）→ 等端口释放 → 清状态文件。
- `Get-ManagedStatus`：`@{Running;PID;Port;StartedAt}`。**进程未运行时跳过端口探测**（本机 127.0.0.1 connect 有延迟，每秒 UI 刷新若每次查端口会卡顿）；PID 文件里的无效 PID **自愈清理**。
- 无任何 MessageBox；呈现由调用方负责。

### n8n.ps1 —— 入口
加载配置 → 点源 lib → 定义 `Show-Msg`/`Show-YesNo`（Silent 时只写日志）→ switch 分派（start 前先 `Test-SetupNeeded`，缺环境则确认后 `Invoke-Setup`）。GUI 模式进 `Show-Gui`（阻塞）。顶层 try/catch 兜底写 `logs\error.log`。

### lib/setup.ps1 —— 环境自检 + 自动安装（"工具箱"能力）
- 每服务在 `n8n.config.psd1` 的 `Setup` 段定义检测/安装步骤（`Steps`），内置类型：`node-portable`（下载 npmmirror node zip 解压到 `tools\node-<版本>`，便携免管理员）、`npm-install`（用便携 node 的 npm 装包）、`shell`（自定义命令）。
- `Test-SetupNeeded`：点启动时检测缺失步骤（**快**：文件存在 + `--version`）；缺则弹确认 → 后台 `Invoke-Setup` → 进度写 `run\<实例>.setup.json` → GUI 500ms 轮询更新进度条/阶段文本 → 装完自动继续启动。
- **便携 node 优先**：`Get-NodeExecutable` 返回 `tools\node-<版本>\node.exe`（若存在）否则配置 `Executable`；service.ps1 定位 exe 走它。
- CLI `-Action start`：缺环境时非 Silent 弹确认同步安装；Silent 只写日志返回失败（不静默下载）。

### lib/gui.ps1 —— 仅呈现（PS5.1 事件闭包陷阱见踩坑 5）
- **启动是异步的**：点启动 → 独立 runspace 执行 `Start-ManagedService`（BeginInvoke），500ms 轮询完成，UI 线程不冻结（否则健康检查+稳定性复检会锁死界面 15~38s）。⚠️ 判断 job 完成必须用 `$script:_bgHandle.IsCompleted`（IAsyncResult）；**`PowerShell` 类没有 `HasCompleted` 属性（返回 $null），用它判断会导致 job 永不"完成"→ 界面永久停在黄灯**（2026-08-21 实测 bug）。另有 90s 超时兜底强制清理。
- **状态圆点慢闪**：独立 200ms `dotFlashTimer` 做呼吸动画（运行中绿→暗绿、启动中金、停止灰），颜色存 `$script:StateDotColor`，Paint 直接读它。
- **无托盘**：关闭窗口 = 直接退出控制台（FormClosing 停所有 Timer，不做隐藏驻留）。n8n 进程独立，退出控制台不影响它，重开即可管理。
- **内联提示（toast）**：启动/停止结果不弹 MessageBox，而是复用底部提示行 `$script:_lblHint` 临时显示（`Show-Toast`，成功绿 `✓`/失败红 `⚠`，摘要取首行截断 46 字符），约 4s 后恢复默认文案。**仅"详情"（`Show-Status`）保留 MessageBox**。
- `Refresh-UI`（1s Timer）用 `Get-ManagedStatus` 刷新；后台启动中（`$script:_bgJob`）时保持"启动中"显示不覆盖。
- **窗体布局**：用 `ClientSize`（**380×244**，非 Size，Size 含边框会压窄内容区导致右边截断）+ `AutoScaleMode=None`（防 DPI 缩放拉伸溢出）；控件宽 352 从 x=12 起，右边留 14px 余量。`Show-Gui` 开头有**单实例锁**（Mutex `n8n-console`，重复打开直接提示退出）。

### C# 启动器 n8n-console.exe 与打包
- **`n8n-console.exe`**：由 `packaging/n8n-console.cs` 用系统 `csc.exe`（.NET Framework 自带，无需 SDK）编译，`/win32icon` 嵌图标。它是 winexe（非 console subsystem），**启动无 conhost 一闪**；进程名显示 `n8n-console` 而非 powershell；内嵌 PowerShell 引擎以 `ExecutionPolicy=Bypass` 运行同目录 `n8n.ps1` 并透传参数。**安装包（MSI）创建的桌面快捷方式指向它**。
- **打包**（`packaging/build.ps1`）：只依赖 WiX v3（zip 便携，首次联网下载到 `packaging\tools\wix`）。流程：① 编译 `n8n-console.exe`；② heat 生成文件组件清单 `Components.wxs`；③ candle+light → `release\setup.msi`（**必须 `-cultures:zh-CN`** 修 WixUI 目录选择 UI 中文编码 + `-sice:ICE38/64/91` 抑制 per-user 建议性检查）；④ candle+light(Burn) → `release\n8n-console-setup.exe`（引导安装器，链装 setup.msi）。MSI 装用户目录 `%LOCALAPPDATA%\n8n-console` + 桌面快捷方式 + 开始菜单卸载。构建产物 `*.wixobj`/`Components.wxs`/`release/` 均被 gitignore。**`installer.iss` 是 Inno 遗留，已不使用。**

## 关键约束与踩坑（改动必读）

1. **node 版本（最容易踩）**：n8n 2.35.4 要求 **node >=22.22**，版本不够会"启动即退"（`Your Node.js version ... not supported`）。历史修复：把 workbuddy 的 **22.22.2 置顶回用户 PATH**（曾被 TRAE 自带 v22.16.0 顶掉）+ 配置 `Executable` 指向 22.22.2 绝对路径做**双保险**。本机 workbuddy 目录是 `C:\Users\Allen\.workbuddy\...`（配置里的 `SCY004730` 是迁移前用户，已失效）。
2. **UTF-8 BOM**：所有含中文的 .ps1/.psd1 必须 BOM；改完检查（`head -c3 | xxd -p` 应为 `efbbbf`）。
3. **`$home` 是只读自动变量**：config.ps1 里用 `$homeDir`（历史 bug：赋值 $home 报 VariableNotWritable）。
4. **Logs.\* 是纯文件名**：目录由 `Console.LogDir` 决定；别再写 `logs\xxx.log`（会双重前缀 `logs\logs`）。
5. **PS5.1 WinForms 事件闭包陷阱（重构后实测，最重要）**：.NET 事件 handler 里**引用函数局部变量会解析为 $null**（如 `$btn`/`$timer`/`$form`），导致"在此对象上找不到属性 Target"这类异常。事件 handler 必须用 **`$this`**（自动绑定 sender）或 **`$script:_xxx`** 访问状态，**禁止捕获 New-HoverButton / Show-Gui 的局部变量**。当前实现：状态容器（含 Button+Timer 引用）同时挂到 `btn.Tag` 和 `timer.Tag`（Component.Tag），handler 统一 `$st = $this.Tag` 访问；`$form`/`$notify`/刷新 timer 走 `$script:_form`/`$script:_notify`/`$script:_refreshTimer`。Paint 事件另需显式 delegate 转换 + `param($sender,$e)`（`$EventArgs` 自动变量仅 Register-ObjectEvent 可用）。
6. **Control.Tag 用 Hashtable**：PSCustomObject 跨 .NET 边界 setter 不可靠。
7. **N8N_RUNNERS_ENABLED=false**：规避无 Python 启动崩溃；Python Code 节点不可用。2.35.4 下 JS runner 仍会注册（无害）。
8. **EPERM 韧性**：n8n 启动解压前端资源到 `{N8N_USER_FOLDER}\.cache\n8n\public\`，文件被锁会 EPERM 崩溃。已做：启动前清缓存（`CleanCacheOnStart`）+ 稳定性复检兜底。
9. **打包路径注意**：`build.ps1` 收集的文件清单在脚本内 `$files` 硬编码（含 `n8n-console.exe`、`lib\`、`assets\` 等），新增根文件需同步加进清单。

## 排障速查

| 症状 | 排查路径 |
|---|---|
| 启动即退 / 进程秒退 | 先看 `logs\error.log` 与 `logs\n8n.log` 尾部。`not supported` → node 版本 <22.22（见踩坑 1）；`EPERM ... .cache` → 前端缓存被锁（自动清缓存已兜底）；报"找不到目录/路径" → **配置路径仍指向迁移前的 D:\APP / SCY004730**（见"当前环境注意"） |
| 健康检查通过但进程随后死 | 稳定性复检（`StabilityCheckSec`）会抓到并附日志尾 |
| 端口 5678 被占 | `netstat -ano \| findstr 5678` 找 PID，taskkill 或控制台停止 |
| 页面打不开 | `curl http://localhost:5678/healthz`；无响应先启动再查 |
| run\n8n.pid 残留死 PID | 无需手动清，`Get-ManagedProcessId` 会自愈清理 |
| 图标白块 | 桌面 F5；重建 .lnk 用 create_shortcut.py |
