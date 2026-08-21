# n8n 工作交接文档（HANDOFF）

> 生成日期：2026-08-21
> 交接范围：n8n 本地安装 + 桌面控制台（启停/日志/托盘）
> 阅读对象：后续接手维护的同事

---

## 1. 项目概览

本机以 **npm 方式本地安装 n8n 2.35.4**（开源工作流自动化平台），并配套开发了一个 **Windows 桌面控制台**（PowerShell + WinForms），实现：
- 双击桌面图标弹出控制面板（状态卡片 + 三个操作按钮）
- 一键启动 / 停止 n8n（隐藏窗口、健康自检、自动开浏览器）
- 运行状态实时刷新（PID / 端口 / 运行时长）
- 系统托盘常驻（关闭窗口最小化到托盘，右键菜单操作）
- 完整日志体系（n8n 运行日志 / 操作审计 / 错误兜底）

**两个独立目录：**
| 目录 | 内容 | 职责 |
|---|---|---|
| `D:\APP\n8n` | n8n 本体（node_modules、数据 .n8n） | 应用本体，一般不动 |
| `D:\APP\n8n-console` | 控制台全部文件（脚本/日志/图标） | 运维入口，日常操作都在这 |

---

## 2. 环境信息

| 项 | 值 |
|---|---|
| 操作系统 | Windows 10/11（x64） |
| Node.js | **必须 >=22.22**。2026-08-21 已把 workbuddy 的 **v22.22.2 置顶回用户 PATH**（此前被 TRAE 自带 v22.16.0 顶掉导致启动即退）；控制台配置另指向 22.22.2 绝对路径双保险。若 PATH 再被顶掉，重开终端/重做置顶即可 |
| n8n 版本 | 2.35.4 |
| npm 源 | npmmirror 镜像（`D:\APP\n8n\.npmrc` 中配置） |
| npm 缓存 | `D:\APP\n8n\.npm-cache`（项目内，不污染系统） |
| n8n 数据目录 | `D:\APP\n8n\.n8n`（SQLite 数据库、凭据密钥、前端缓存） |
| 访问地址 | http://localhost:5678 |
| 健康检查 | http://localhost:5678/healthz |

---

## 3. 目录结构

```
D:\APP\
├── n8n\                            ← n8n 本体
│   ├── node_modules\               应用依赖（1100+ 包）
│   ├── .n8n\                       n8n 数据：database.sqlite / config(密钥) / .cache\
│   ├── .npm-cache\                 npm 下载缓存（.npmrc 指定）
│   ├── .npmrc                      镜像源 + 项目内缓存配置
│   ├── package.json                npm start/stop/update 脚本
│   ├── start.bat                   命令行启动备份入口（备选）
│   └── scripts\                    （空目录，已迁移至控制台）
│
└── n8n-console\                    ← 控制台（运维入口）
    ├── n8n.ps1                     主入口（-Action menu/start/stop/status + -Silent）
    ├── n8n-control.ps1             兼容垫片 → 一行转发 n8n.ps1（桌面快捷方式指向它）
    ├── n8n.config.psd1             ★ 全部配置外置（路径/端口/healthz/注入 env/日志，含注释）
    ├── lib\
    │   ├── config.ps1              配置加载 + 默认值合并 + 路径解析（Get-Config -Root 必传）
    │   ├── logging.ps1             日志函数（control.log 审计 / error.log 兜底）
    │   ├── service.ps1             纯进程控制（无 UI，返回结构化结果）
    │   └── gui.ps1                 WinForms UI（状态卡片/hover/托盘/1s 刷新）
    ├── create_shortcut.py          重建桌面快捷方式（Python + pylnk3）
    ├── launcher.vbs                vbs 无窗口启动器（备用，默认未使用）
    ├── assets\n8n.ico              图标（快捷方式 + 托盘）
    ├── logs\
    │   ├── n8n.log                 n8n 运行输出（N8N_LOG_FILE）
    │   ├── control.log             操作审计（何时启动/停止/结果）
    │   ├── error.log               脚本异常兜底
    │   └── n8n-error.log           n8n 进程 stderr
    └── run\
        ├── n8n.pid                 当前运行 PID（无效 PID 会被自愈清理）
        └── n8n.started             启动时间戳（用于显示运行时长）
```

---

## 4. 日常使用

### 启动 / 停止 / 查看状态
**双击桌面「n8n 控制台」** 快捷方式（指向 `D:\APP\n8n-console\n8n-control.ps1`）→ 弹出控制面板：

| 操作 | 说明 |
|---|---|
| ▶ 启动 | **异步**拉起 n8n（UI 不冻结）→ 后台健康自检（最多 30s）→ 成功自动开浏览器 + 弹提示 |
| ■ 停止 | 弹确认框 → 进程树连坐清理（taskkill /T，含 runner 子进程）→ 验证端口关闭 |
| ⓘ 详情 | 弹窗显示 PID / 端口 / 日志路径 |
| 状态圆点 | 运行中**绿灯慢闪**（呼吸动画）；启动中金色；停止灰色 |
| 窗口 × | **直接退出控制台**（无托盘常驻）；n8n 若在运行继续后台运行，重开控制台即可管理 |

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
- **`n8n-control.ps1`**：兼容垫片，一行转发 `n8n.ps1`（桌面快捷方式仍指向它，无需重建 .lnk）
- **注意**：所有含中文文件为 **UTF-8 BOM** 编码（PS 5.1 中文显示必需，改文件后务必保留 BOM；`head -c3 | xxd -p` 应为 `efbbbf`）

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

### 7.2 启动时命令行窗口一闪
- 公司卡巴斯基拦截 vbs→powershell 方案，只能走 powershell.exe 直接启动；Windows console subsystem 进程启动时必然瞬时创建 conhost（一闪），无法在现有约束下消除
- 彻底解决需：IT 给 launcher.vbs 加白名单，或编译 C# GUI 启动器（需 .NET SDK）

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
| 2026-08-20 | n8n 2.35.4 npm 安装完成（npmmirror 源 + 项目内缓存，绕开 Windows 缓存锁）；修复 4 个解压损坏包 + sqlite3 二进制 |
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

---

## 10. 联系方式 / 备注

- 控制台入口：`D:\APP\n8n-console\n8n.ps1`（桌面快捷方式经 `n8n-control.ps1` 垫片转发）
- **唯一需要常改的运维文件：`D:\APP\n8n-console\n8n.config.psd1`**
- 遇到 JIT 调试弹窗/异常：**不要关闭**，把"异常文本"整段复制发维护者
- 本机安全软件：卡巴斯基 Endpoint Security（影响 vbs 启动方案，见 7.2）
