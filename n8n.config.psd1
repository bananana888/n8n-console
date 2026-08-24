# ============================================================
#  n8n 控制台配置文件（PowerShell 数据文件）
#  所有 n8n 相关 / 本机相关的配置都在这，脚本本身保持通用。
#  用 Import-PowerShellDataFile 加载；缺失的键会用脚本内置默认值兜底。
# ============================================================

@{
    Console = @{
        # 控制台自身目录。留空则用脚本所在目录（$PSScriptRoot），换目录/换机器拷贝即用。
        # 历史: 公司机 D:\APP\n8n-console；家用机 E:\ProgramFiles\n8n-console —— 无需在此硬编码
        Home   = ''
        LogDir = 'logs'
        RunDir = 'run'
        Icon   = 'assets\n8n.ico'
    }

    Service = @{
        # 后台进程描述
        Name = 'n8n'
        # 运行 node 的可执行文件。'node' = 用 PATH 中的 node；脚本按
        # 「便携 node(tools\) → 本配置 → PATH」逐级回退。便携 node 由 Setup
        # 自动装到 tools\node-<版本>（免管理员），优先于 PATH。
        # n8n 2.35.x 要求 node >=22.22：版本过低会"启动即退"。无需填本机
        # 绝对路径 —— 换机器/换目录拷贝即用，旧机器的绝对路径失效会自动回退。
        Executable  = 'node'
        # 传给 Executable 的参数（n8n 可执行文件入口）。留空 = 自动探测：
        # 便携 node 目录 → 工作目录 node_modules → npm root -g → PATH 中 n8n.cmd，
        # 探测到真实入口后自动带上，无需手动填本机路径。
        Arguments   = @()
        WorkingDir  = ''            # 留空 = 控制台根目录（n8n 不依赖启动目录）
        # 进程名（用于 PID 校验，防 PID 被系统复用误判）；留空自动从 Executable 推导
        ProcessName = 'node'

        # 服务端口与健康检查
        Port              = 5678
        HealthUrl         = 'http://localhost:5678/healthz'
        EditorUrl         = 'http://localhost:5678'
        HealthTimeoutSec  = 30
        # 健康通过后再复检的等待窗口（秒），用于抓"端口已开但随后崩溃"(如 EPERM) 的延迟崩溃
        StabilityCheckSec = 4

        # 启动前清理前端解压缓存（.cache\n8n\public），规避文件锁 EPERM 崩溃。
        # 缓存目录 = 数据目录\.cache\n8n\public；未设 N8N_USER_FOLDER 时按 n8n 默认
        # （%USERPROFILE%\.n8n）清理。
        CleanCacheOnStart = $true

        # 注入给子进程的环境变量
        Env = @{
            # 注意: n8n 2.x 会把 .n8n 拼到 N8N_USER_FOLDER 之后作为真实数据目录。
            # 默认不设此变量：n8n 数据落在默认用户目录 %USERPROFILE%\.n8n（最通用）。
            # 若要自定义务必理解双嵌套行为（会拼成 N8N_USER_FOLDER\.n8n）。
            # 'N8N_USER_FOLDER'     = ''   # ← 默认留空即可
            # N8N_LOG_FILE 若未在此指定，会自动取 Logs.Stdout 的绝对路径
            # 禁用 task runner / Python runner：部分机器无 Python，避免 n8n 启动即退
            'N8N_RUNNERS_ENABLED' = 'false'
            'N8N_PYTHON_ENABLED'  = 'false'
            # 系统有代理(HTTP_PROXY 且 NODE_USE_ENV_PROXY=1)时，node 22.x 的 undici 走
            # EnvHttpProxyAgent，n8n 外部请求(license 等)经代理可能挂起导致启动卡死。
            # 设 0 让 n8n 进程直连外网（2026-08-22 实测：不清代理卡 30s+，设后 12s 就绪）。
            # 无代理的机器此变量无副作用，可保留。
            'NODE_USE_ENV_PROXY'  = '0'
        }
    }

    Logs = @{
        # 纯文件名，目录统一由 Console.LogDir 决定
        Control = 'control.log'    # 操作审计
        Fatal   = 'error.log'      # 脚本异常兜底
        Stdout  = 'n8n.log'        # n8n 运行输出 (N8N_LOG_FILE)
        Stderr  = 'n8n-error.log'  # n8n 进程 stderr
    }

    # ---------- 环境自检 + 自动安装（控制台"工具箱"能力）----------
    # 点启动时检测下列依赖，缺失则弹确认 → 后台自动安装 → 进度条展示 → 装完继续启动。
    # 检测策略「先系统后便携」：node 先看系统/PATH 是否有可用 node（版本满足即视为就绪、
    # 跳过下载），系统缺失才下载便携 node 到 ToolsDir；n8n 按入口探测（便携/本地/全局任一即可）。
    Setup = @{
        Enabled     = $true
        # 便携 node 下载镜像（npmmirror，国内快）
        NodeMirror  = 'https://npmmirror.com/mirrors/node/'
        # npm 包源
        NpmRegistry = 'https://registry.npmmirror.com'
        # 需要的 node 版本（n8n 2.35.x 要求 >=22.22）
        NodeVersion = 'v22.22.2'
        # 便携 node 解压目录（相对 Console.Home，如 n8n-console\tools\node-v22.22.2）
        ToolsDir    = 'tools'
        # 每步安装超时（秒）：受限电脑/网络超时直接报错，不卡死
        InstallTimeoutSec = 600
        # 检测/安装步骤（顺序执行；已就绪则跳过）
        Steps = @(
            @{
                Name = 'node 运行时'
                Detect = '系统 node 可用（版本满足）或便携 node 就绪'
                Install = @{
                    Kind = 'node-portable'   # 内置类型：先认系统 node（版本满足即跳过），缺失才下载 zip 解压到 ToolsDir\node-<版本>
                }
            },
            @{
                Name = 'n8n 本体'
                Detect = 'n8n 可执行入口可探测到（便携/本地/全局任意一种）'
                Install = @{
                    Kind    = 'npm-install'   # 内置类型：用 node 的 npm 安装
                    Package = 'n8n@2.35.7'    # 无 Prefix：便携 node 存在装其目录；系统 node 被采用时装 ToolsDir 下
                    # Prefix = '...'          # 可选：指定其它安装位置（如 npm 全局 prefix）
                }
            },
            @{
                Name = 'n8n 数据目录'
                Detect = 'n8n 默认数据目录 %USERPROFILE%\.n8n 存在'
                Install = @{
                    Kind = 'shell'           # 内置类型：执行 PowerShell 命令
                    DetectScript = 'Test-Path "$env:USERPROFILE\.n8n"'
                    Script = @'
# 确保 n8n 默认数据目录存在（n8n 首次启动会自动创建，这里仅兜底）
$dataDir = Join-Path $env:USERPROFILE '.n8n'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
'@
                }
            }
        )
    }
}
