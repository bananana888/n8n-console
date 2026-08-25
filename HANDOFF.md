# n8n 工作交接文档（HANDOFF）

> 生成日期：2026-08-25（家用机，控制台目录 E:\ProgramFiles\n8n-console）
> 交接范围：n8n 本地安装 + 桌面控制台（启停/日志/卸载）
> 阅读对象：后续接手维护的同事

---

## 1. 项目概览

本机以 **npm 方式本地安装 n8n 2.35.4**（开源工作流自动化平台），并配套开发了一个 **Windows 桌面控制台**（PowerShell + WinForms），实现：
- 双击桌面图标弹出控制面板（状态卡片 + 三个操作按钮）
- 一键启动 / 停止 n8n（隐藏窗口、健康自检、自动开浏览器）
- 运行状态实时刷新（PID / 端口 / 运行时长）
- 系统托盘常驻（关闭窗口最小化到托盘，右键菜单操作）
- 完整日志体系（n8n 运行日志 / 操作审计 / 错误兜底）
- **GUI 卸载器（v4.2.2）**：双击「卸载 n8n 控制台.bat」弹窗卸载（勾选 5 类删除内容 + 二次确认 + 结果展示），参数模式保留供自动化
- **v4.0.0 增强**：多实例壳子（`-ConfigFile` 复用管任意命令行服务）、环境缺失自动安装（窗口内进度条）、一键打包 `setup.exe`/`setup.msi`（装用户目录+快捷方式）、日志轮转、单实例锁；作为开源项目发布（MIT），并提供 `shell-ui` skill 复用整套壳子

**两个独立目录：**
| 目录 | 内容 | 职责 |
|---|---|---|
| `D:\APP\n8n` | n8n 本体（node_modules、数据 .n8n） | 应用本体，一般不动 |
| `D:\APP\n8n-console` | 控制台全部文件（脚本/日志/图标） | 运维入口，日常操作都在这 |

> **⚠️ 环境迁移说明（2026-08-22）**：本文档基于**公司机**编写，以下旧路径均已失效，请以家用机为准：
> - 公司机：控制台 `D:\APP\n8n-console`、n8n **本地安装**于 `D:\APP\n8n`、用户 `C:\Users\SCY004730`
> - **家用机（当前环境）**：控制台 `E:\ProgramFiles\n8n-console`、n8n **全局安装**于 `D:\npm-global\node_modules\n8n`（v2.35.7）、node `C:\Users\Allen\.workbuddy\binaries\node\versions\22.22.2\node.exe`、数据目录默认 `C:\Users\Allen\.n8n`（**未设 N8N_USER_FOLDER**，公司机的双嵌套 `.n8n\.n8n` 已不存在）
> - 脚本已做兼容（换机器不用改代码）：`Console.Home` 留空自动用脚本所在目录；node 绝对路径失效会回退 PATH；n8n 入口失效会自动探测（本地 node_modules / npm root -g / PATH）。

---

## 2. 环境信息

| 项 | 值 |
|---|---|
| 操作系统 | Windows 10/11（x64） |
| Node.js | **必须 >=22.22**。2026-08-21 已把 workbuddy 的 **v22.22.2 置顶回用户 PATH**（此前被 TRAE 自带 v22.16.0 顶掉导致启动即退）；控制台配置另指向 22.22.2 绝对路径双保险。若 PATH 再被顶掉，重开终端/重做置顶即可 |
| n8n 版本 | 2.35.7（家用机全局安装 D:\npm-global） |
| npm 源 | npmmirror 镜像（`D:\APP\n8n\.npmrc` 中配置） |
| npm 缓存 | `D:\APP\n8n\.npm-cache`（项目内，不污染系统） |
| n8n 数据目录 | `D:\APP\n8n\.n8n`（SQLite 数据库、凭据密钥、前端缓存） |
| 访问地址 | http://localhost:5678 |
| 健康检查 | http://localhost:5678/healthz |

---

## 3. 目录结构

```
E:\ProgramFiles\n8n-console\        ← 控制台（运维入口，也是开源仓库）
├── n8n.ps1                         主入口（-Action menu/start/stop/status + -Silent + -ConfigFile 多实例）
├── n8n-control.ps1                 兼容垫片 → 一行转发 n8n.ps1
├── n8n-console.exe                 编译启动器（C#，进程名 n8n-console，桌面快捷方式指向它）
├── n8n.config.psd1                 ★ 全部配置外置（路径/端口/healthz/注入 env/日志/Setup 段）
├── example.config.psd1             通用配置模板（复用壳子管其它服务时复制改）
├── uninstall.ps1                   卸载器（无参数弹 GUI 窗口；参数模式供自动化）
├── 卸载 n8n 控制台.bat             双击入口 → 调 uninstall.ps1（隐藏黑框，弹卸载窗口）
├── lib\
│   ├── config.ps1                  配置加载 + 默认值合并 + 路径解析（Get-Config -Root 必传）
│   ├── logging.ps1                 日志函数（轮转，>2MB 滚动保留 3 份）
│   ├── service.ps1                 纯进程控制（无 UI，返回结构化结果）
│   ├── setup.ps1                   环境检测 + 自动安装（进度写 run\<实例>.setup.json）
│   └── gui.ps1                     WinForms UI（状态卡片/绿灯慢闪/toast/异步启动/安装进度面板）
├── packaging\                      打包脚本（build.ps1 编译 setup.exe+setup.msi；installer.wxs/Bundle.wxs；n8n-console.cs）
│   └── tools\                      打包缓存（WiX v3 工具 + stage，可删除，build 时自动重下）
├── create_shortcut.py              重建桌面快捷方式（Python + pylnk3）
├── launcher.vbs                    vbs 无窗口启动器（备用，默认未使用）
├── assets\n8n.ico                  图标（快捷方式 + 安装包）
├── release\                        打包产物（setup.msi / n8n-console-setup.exe；gitignore 排除，可再生成）
├── logs\                           运行日志（control.log / error.log / n8n.log；运行自动重建）
└── run\                            运行时状态（n8n.pid / n8n.started；运行自动重建）

> n8n 本体：家用机为全局安装（D:\npm-global\node_modules\n8n），数据在 ~\.n8n；
> 公司机旧布局（D:\APP\n8n + D:\APP\n8n-console）已不适用，见第 1 节迁移说明。
```## 4. 日常使用

### 启动 / 停止 / 查看状态
**双击桌面「n8n 控制台」** 快捷方式（指向 `D:\APP\n8n-console\n8n-control.ps1`）→ 弹出控制面板：

| 操作 | 说明 |
|---|---|
| ▶ 启动 | **异步**拉起 n8n（UI 不冻结）→ 后台健康自检（最多 30s）→ 成功自动开浏览器 + 弹提示 |
| ■ 停止 | 弹确认框 → 进程树连坐清理（taskkill /T，含 runner 子进程）→ 验证端口关闭 |
| ⓘ 详情 | 弹窗显示 PID / 端口 / 日志路径 |
| 状态圆点 | 运行中**绿灯慢闪**（呼吸动画）；启动中金色；停止灰色 |
| 窗口 × | **直接退出控制台**（无托盘常驻）；n8n 若在运行继续后台运行，重开控制台即可管理 |

### 卸载（GUI 卸载器，v4.2.2）
**双击 `卸载 n8n 控制台.bat`** → 弹出图形卸载窗口，勾选后一键执行：
| 勾选项 | 说明 |
|---|---|
| [1] 控制台程序 | 桌面/开始菜单快捷方式、HKCU 注册、MSI 安装副本 |
| [2] 运行时缓存 | logs / run / release / 构建产物 / WiX 缓存 |
| [3] 便携 node+n8n | 当前文件夹 tools\ 下的运行时 |
| [4] 全局 n8n | npm uninstall -g（D:\npm-global） |
| [5] n8n 数据 | ~\.n8n（工作流/凭证，不可恢复） |

默认勾选 1、2；点「开始卸载」前有二次确认（勾选 5 时特别警示），删除结果逐项展示。
参数模式（供自动化，无窗口）：`.\uninstall.ps1 -Console|-Cache|-Portable|-GlobalN8n|-Data [-Force] [-WhatIf]`
### 命令行备选（主入口 n8n.ps1；旧 n8n-control.ps1 为垫片仍可调用）
```powershell
powershell -ExecutionPolicy Bypass -File D:\APP\n8n-console\n8n.ps1 -Action start
powershell -ExecutionPolicy Bypass -File D:\APP\n8n-console\n8n.ps1 -Action stop
powershell -ExecutionPolicy Bypass -File D:\APP\n8n-console\n8n.ps1 -Action status
```
追加 `-Silent` 参数 = 不弹窗、不开浏览器，结果只写 `logs\control.log`（供自动化）。

---

## 5. 关键实现说明（接手必读）

### 架构（2026-08-21 重构：单文件拆分为入口 + lib + 配置外置）
- **`n8n.ps1`**：主入口。加载配置 → 点源 lib（共享同一作用域，非 .psm1 模块）→ 定义 `Show-Msg`/`Show-YesNo`（-Silent 时只写日志）→ 按 `-Action` 分派（默认 menu 进 GUI）。顶层 try/catch 兜底写 `logs\error.log`。
- **`n8n.config.psd1`**：**所有 n8n 相关配置外置**（★ 唯一需要常改的运维文件）：
  - `Service.Executable`：**必须指向 node >=22.22**（详见 2. 环境信息的警告；当前指向 workbuddy 22.22.2 绝对路径）
  - `Service.Port/HealthUrl/EditorUrl`、`Service.Env`（`N8N_USER_FOLDER`、`N8N_LOG_FILE`、**`N8N_RUNNERS_ENABLED=false`**、`N8N_PYTHON_ENABLED=false`）、`Logs.*`（纯文件名，目录由 `Console.LogDir` 决定）
  - 缺键用脚本内置默认兜底（`lib/config.ps1` 的 `Get-Config`）
- **`lib/service.ps1`**：纯进程控制，无 UI，返回结构化结果 `@{Ok;Message;PID;LogTail}`：
  - **启动**：防重复启动（PID+进程名校验）→ 端口占用检查 → 定位 exe（**绝对路径优先，PATH 兜底**）→ 清前端缓存 → `[System.Diagnostics.Process]` + `CreateNoWindow=$true` 启动 node + 注入 `Service.Env` → 立即写 PID → 轮询 `/healthz`（最多 30s）→ **稳定性复检**（`StabilityCheckSec`，抓"端口已开但随后崩溃"如 EPERM）→ 成功写时间戳 / 失败清状态文件
  - **停止**：读 `run\n8n.pid` → `taskkill /T /F`（进程树）→ 等待端口释放 → 清空 PID/时间戳文件
  - **状态**：PID 文件里的**无效 PID 自愈清理**（进程已死/名不符即清空，不再残留误导）
- **`lib/gui.ps1`**：WinForms 状态卡片（GDI 画圆点，运行中**绿灯慢闪**）+ 三个 hover 动画按钮（Timer 颜色插值）+ 1 秒定时刷新；**启动异步化**（独立 runspace 执行 Start-ManagedService，UI 不冻结）+ **无托盘**（关窗直接退出，n8n 后台进程不受影响）；只调用 service 函数并转提示框，不内联进程逻辑
- **`n8n-control.ps1`**：兼容垫片，一行转发 `n8n.ps1`
- **`lib/setup.ps1`**：环境自检 + 自动安装（`Test-SetupNeeded`/`Invoke-Setup`）。点启动检测 `Setup` 段步骤缺失 → 弹确认 → 后台安装（便携 node 到 `tools\` + npm install + 数据初始化）→ 进度写 `run\<实例>.setup.json` → GUI 轮询进度条。**每步 `InstallTimeoutSec`（默认 600s）超时直接报错不卡死**。便携 node 优先（`Get-NodeExecutable`）。
- **`n8n-console.exe`（C# 启动器）**：`packaging/n8n-console.cs` 编译，内嵌 PowerShell 引擎运行控制台（`ExecutionPolicy=Bypass`）。进程名显示 `n8n-console` 而非 powershell，窗口标题用 `Service.Name`。桌面快捷方式与安装包都指向它。用系统 `csc.exe`（.NET Framework 自带，无需 SDK）编译，`/win32icon` 嵌图标。
- **打包**（`packaging/build.ps1`）：只依赖 WiX v3（zip 便携，首次联网下载）。编译 `n8n-console.exe` → heat/candle/light 生成 `release/setup.msi` + `n8n-console-setup.exe`（Burn 引导）。MSI 装用户目录（`WixUI_InstallDir` 可选目录）+ 桌面快捷方式 + 开始菜单卸载。**注意 msi 编译须 `-cultures:zh-CN`**（WixUI 中文编码）+ `-sice:ICE38;64;91`（per-user 建议性检查）。
- **注意**：所有含中文文件为 **UTF-8 BOM** 编码（PS 5.1 中文显示必需，改文件后务必保留 BOM；`head -c3 | xxd -p` 应为 `efbbbf`）

### uninstall.ps1（GUI 卸载器）
- 无参数 → 弹 WinForms 卸载窗口（勾选类别 + 二次确认 + 停止 n8n + 逐项删除 + 结果 RichTextBox 展示）；有参数 → CLI 模式（v4.2.0 行为，含 `-WhatIf` 预览）
- 停止 n8n（PID 文件 + 端口占用 + node 命令行匹配）→ 收集目标 → 逐个删除，共享函数 `Stop-RunningN8n` / `Get-UninstallTargets` / `Invoke-Uninstall`
- PS5.1 事件 handler 沿用 `$this` / `$script:` 模式（同 gui.ps1），不捕获局部变量
- 「卸载 n8n 控制台.bat」：`powershell -WindowStyle Hidden -File`，双击隐藏黑框直接弹卸载窗口
### create_shortcut.py
- 用 **pylnk3**（纯文件格式）生成 .lnk，不依赖 COM
- **必须用 `pylnk3.for_file()` 工厂**（内部设 IsUnicode=True）；用低级 API 会因中文导致图标字段错位（历史 bug）
- 依赖 Python 3 + pylnk3（安装：`pip install pylnk3`），桌面路径从注册表 User Shell Folders 读取（兼容 OneDrive 重定向）

### launcher.vbs
- 无窗口启动方案（`WScript.Shell.Run(..., 0, False)`）
- **⚠️ 公司卡巴斯基会拦截 vbs→powershell（LOLBin 防护），当前未使用**；若 IT 放行白名单可切回（改 create_shortcut.py 的 target 为 wscript.exe 即可）

---

## 6. 日志与排障

| 症状 | 排查路径 |
|---|---|
| 启动失败（进程已退出） | 先看 `logs\error.log` 与 `logs\n8n.log` 尾部：`not supported ... version range >=22.22` → **node 版本 <22.22**（见踩坑 5）；`EPERM ... .cache` → 前端缓存被锁（启动前已自动清缓存 + 稳定性复检兜底）；`Failed to start Python task runner` → N8N_RUNNERS_ENABLED 未生效（检查 n8n.config.psd1 的 Env 段） |
| 端口 5678 被占用 | `netstat -ano | findstr 5678` 找 PID；可能是有残留 n8n 进程，用控制台停止或 taskkill |
| 图标显示白色 | 桌面按 F5 刷新；仍白则重启资源管理器；`.lnk` 重建用 create_shortcut.py |
| 控制台报 JIT 调试异常 | 查看异常文本关键字：`找不到属性 X` 通常是 PS 事件绑定问题（见 5.1 经验）；把完整异常发给维护者 |
| n8n 页面打不开 | `curl http://localhost:5678/healthz` 应返回 `{"status":"ok"}`；无响应则先启动再查 |

### 历史踩坑（重要经验）
1. **PS 5.1 事件参数**：WinForms 事件必须显式 delegate 类型转换（如 `[System.Windows.Forms.PaintEventHandler]{ param($sender,$e) ... }`）；自动变量 `$EventArgs` 仅 Register-ObjectEvent 可用
2. **Control.Tag 存状态**：用 Hashtable 而非 PSCustomObject（PSCustomObject 跨 .NET 边界 NoteProperty setter 不可靠）
3. **npm Windows 缓存锁**：`AppData\Local\npm-cache` 可能被 Defender 锁定导致安装"假死"；本机已用项目内缓存 `.npm-cache` 规避
4. **n8n 前端资源缓存**：n8n 启动会解压静态资源到 `.n8n\.cache\n8n\public\`，该目录被锁会 EPERM 崩溃（控制台已做：启动前清缓存 + 稳定性复检兜底）
5. **node 版本（2026-08-21 实测+修复）**：PATH 首位曾被 **TRAE 自带的 node v22.16.0** 顶掉，n8n 2.35.4 要求 **>=22.22**，启动即退（`Your Node.js version ... not supported`）。已把 workbuddy 的 **v22.22.2 置顶回用户 PATH**（注册表 HKCU\Environment\Path，`[Environment]::SetEnvironmentVariable(...,'User')` + 广播 WM_SETTINGCHANGE）。配置 `Service.Executable` 仍指向 22.22.2 绝对路径做双保险；改 node 务必 >=22.22
6. **PS5.1 事件 handler 闭包陷阱（2026-08-21 GUI 实测）**：.NET 事件 handler 里**引用函数局部变量会解析为 $null**（如 `$btn`/`$timer`/`$form`），报"在此对象上找不到属性 Target"。事件 handler 必须用 **`$this`**（=sender）或 **`$script:_xxx`** 访问状态，**不要捕获 New-HoverButton/Show-Gui 的局部变量**。gui.ps1 已全部改为此模式（状态容器同时挂 btn.Tag 与 timer.Tag）

---

## 7. 已知问题与限制

### 7.1 task runner 被禁用（重要）
- 为规避"无 Python 时 n8n 启动即退"的问题，`n8n.config.psd1` 的 `Service.Env` 设了 **`N8N_RUNNERS_ENABLED=false`**
- **影响**：Code 节点（JS）退回 n8n 1.x 模式在主进程执行（功能可用但隔离性降低）；**Python Code 节点不可用**（2.35.4 下 JS runner 仍会注册，无害）
- 若需恢复 task runner：安装 Python 3 后，去掉 `n8n.config.psd1` 里的 `N8N_RUNNERS_ENABLED=false`（保留 `N8N_PYTHON_ENABLED=false`）

### 7.2 启动时命令行窗口一闪（已解决）
- **已解决**：改用编译的 `n8n-console.exe`（C# winexe，非 console subsystem）启动，无 conhost 一闪。用系统 `csc.exe` 编译（.NET Framework 自带，无需 SDK）。
- vbs→powershell 方案仍被卡巴斯基拦截，保留备用。

### 7.3 控制台与 n8n 分离
- 控制台文件全在 `D:\APP\n8n-console`；n8n 本体在 `D:\APP\n8n`
- 备份/迁移时：控制台整体拷贝 + n8n 的 `.n8n` 数据目录拷贝即可

---

## 8. 维护操作

### 升级 n8n
```bash
cd D:\APP\n8n
npm update n8n        # 或 npm install n8n@最新版本
node node_modules/n8n/bin/n8n --version   # 确认版本
```
> 升级前先停止 n8n（控制台 → 停止）；升级后重启即可。数据目录 `.n8n` 不受影响（备份建议先拷贝 database.sqlite）。

### 重建桌面快捷方式
```bash
python D:\APP\n8n-console\create_shortcut.py
```
（需要 Python 3 + pylnk3；如环境缺失：`pip install pylnk3`）

### 打包安装包
```powershell
powershell -ExecutionPolicy Bypass -File D:\APP\n8n-console\packaging\build.ps1
```
（首次需联网下载 WiX v3 ~30MB 到 `packaging\tools\`；输出 `release\setup.msi` + `release\n8n-console-setup.exe`）

### 修改配置
- 端口/健康检查地址/node 路径/注入 env：改 **`n8n.config.psd1`**（`Service` 段）
- 日志文件名/目录：改 `n8n.config.psd1` 的 `Logs` / `Console.LogDir`
- 按钮文案/颜色：改 `lib/gui.ps1` 里 `New-HoverButton` 调用处的 `-Text` / `-BaseColor`
- psd1/ps1 改完**保持 UTF-8 BOM** 编码保存

### 备份建议
- 控制台：整个 `D:\APP\n8n-console`（约几 MB）
- n8n 数据：`D:\APP\n8n\.n8n`（含 database.sqlite、凭据密钥 config —— **机密，妥善保管**）

---

## 9. 变更历史

| 日期 | 内容 |
|---|---|
| 2026-08-25 | **v4.2.2 卸载图形化 + 项目瘦身**：uninstall.ps1 无参数弹 GUI 卸载窗口（勾选 5 类 + 二次确认 + 结果展示），新增「卸载 n8n 控制台.bat」双击入口；清理 WiX 打包缓存与中间产物 ~133MB（build 自动重下） |
| 2026-08-24 | v4.2.1 修复启动后 "Cannot GET /"（全局 n8n 前端包 n8n-editor-ui 物理缺失，补装恢复）+ 健康检查等前端就绪；v4.2.0 安装检测「先系统后便携」+ 卸载分级菜单 |
| 2026-08-24 | v4.1.x 系列：静默告警引号修复、安装包版本同步、启动器路径动态化、日志写入兜底、单实例锁加固、端口占用接管、前端等待 || 2026-08-20 | n8n 2.35.4 npm 安装完成（npmmirror 源 + 项目内缓存，绕开 Windows 缓存锁）；修复 4 个解压损坏包 + sqlite3 二进制 |
| 2026-08-20 | 桌面控制台 v1（菜单/启停/状态 + 日志三件套） |
| 2026-08-21 | 修复：图标白板（IsUnicode 编码）、启动即死（N8N_RUNNERS_ENABLED=false）、命令行窗口（CreateNoWindow） |
| 2026-08-21 | 控制台 v2：状态卡片 UI + hover 动画 + 托盘常驻 + 1s 状态刷新 |
| 2026-08-21 | 修复：Control.Tag PSCustomObject 陷阱、事件参数绑定（delegate 类型转换） |
| 2026-08-21 | 控制台独立目录 `D:\APP\n8n-console`，与 n8n 本体分离 |
| 2026-08-21 | **重构 v3**：单文件 660 行拆分为 `n8n.ps1`(入口) + `lib/`(config/logging/service/gui) + `n8n.config.psd1`(配置外置)；`n8n-control.ps1` 降级为转发垫片。修复：node 版本导致启动即退（PATH 被 TRAE v22.16.0 顶掉 → 配置指向 workbuddy v22.22.2 绝对路径，并把 22.22.2 置顶回用户 PATH）、EPERM 缓存锁（启动前清缓存 + 稳定性复检）、PID 残留自愈 |
| 2026-08-21 | GUI 体验优化：启动/停止异步化（runspace，UI 不再冻结 15~38s）；状态圆点**绿灯慢闪**；**去掉托盘**，关窗直接退出；`Get-ManagedStatus` 进程未运行时跳过端口探测（修复界面卡顿，20ms vs 500ms+） |
| 2026-08-21 | 启动提速 + 防御性：稳定性复检 8s→4s、健康轮询 800→500ms、**进程死亡立即判失败**（启动即退场景 30s→0.5s）、**exe 启动预检**（`--version` 给明确报错）；窗体改用 `ClientSize`+`AutoScaleMode=None` 修复右边截断 |
| 2026-08-21 | 修复**永久黄灯**：异步 job 完成判定误用 `PowerShell.HasCompleted`（该属性不存在返回 $null），改用 `IAsyncResult.IsCompleted` + 90s 超时兜底 |
| 2026-08-21 | 启动/停止结果改为**内联 toast**（复用底部提示行，4s 自动恢复，成功绿/失败红），不再弹 MessageBox；仅"详情"保留弹窗 |
| 2026-08-21 | **环境自检 + 自动安装**（工具箱能力）：点启动检测 node/n8n 缺失 → 弹确认 → 后台自动装（便携 node 到 tools\ + npm install n8n + 数据初始化）→ 窗口内进度条实时展示 → 装完自动继续启动。配置在 `n8n.config.psd1` 的 `Setup` 段（通用，每服务一份） |
| 2026-08-21 | **v4.0.0 复用性**：`-ConfigFile` 多实例壳子（运行文件按实例隔离）、`example.config.psd1` 模板、日志轮转、配置校验、GUI 单实例锁、`-Version` |
| 2026-08-21 | **打包发布**：`packaging/build.ps1` 生成 `release\setup.msi` + `n8n-console-setup.exe`（WiX v3 + Burn）；README/LICENSE(MIT)/CHANGELOG/.gitignore；推 GitHub `bananana888/n8n-`，tag `v4.0.0` |
| 2026-08-21 | **C# 启动器**：`n8n-console.exe`（csc 编译 + /win32icon 图标），进程名 n8n-console 而非 powershell，窗口标题=服务名 |
| 2026-08-21 | **安装包 5 修复**：exe 嵌图标、MSI 目录选择 UI（WixUI_InstallDir + -cultures:zh-CN）、安装中黄灯、开始菜单卸载、Setup 安装超时（InstallTimeoutSec） |
| 2026-08-21 | **`shell-ui` skill**（`~/.claude/skills/shell-ui/`）：整套壳子沉淀为 skill，为任意命令行服务套 UI 壳子（复制 templates + 适配配置） |

---

## 10. 联系方式 / 备注

- 控制台入口：`D:\APP\n8n-console\n8n-console.exe`（编译启动器，桌面快捷方式指向它）；脚本入口 `n8n.ps1`
- **唯一需要常改的运维文件：`D:\APP\n8n-console\n8n.config.psd1`**
- **复用壳子**：`~/.claude/skills/shell-ui/`（skill）——为任意命令行服务套 UI 壳子，Claude 说"给 X 套个壳"自动加载
- 遇到 JIT 调试弹窗/异常：**不要关闭**，把"异常文本"整段复制发维护者
- 本机安全软件：卡巴斯基 Endpoint Security（影响 vbs 启动方案，见 7.2）
