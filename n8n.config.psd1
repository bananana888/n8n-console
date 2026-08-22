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
        # 必须用绝对路径指向 node 22.22.2！
        # 原因: n8n 2.35.x 要求 node >=22.22，PATH 里的 node 若版本过低会"启动即退"
        #       （Your Node.js version ... not supported）。
        # 公司机: C:\Users\SCY004730\.workbuddy\binaries\node\versions\22.22.2\node.exe
        # 家用机: C:\Users\Allen\.workbuddy\binaries\node\versions\22.22.2\node.exe
        # 若该绝对路径失效（如 workbuddy 目录被清理），脚本会回退 PATH 中的 node，
        # 安装 node >=22.22 并加入 PATH 即可，无需改配置。
        Executable  = 'C:\Users\Allen\.workbuddy\binaries\node\versions\22.22.2\node.exe'
        # 传给 Executable 的参数（n8n 可执行文件入口）
        # 公司机: D:\APP\n8n\node_modules\n8n\bin\n8n（npm 本地安装）
        # 家用机: D:\npm-global\node_modules\n8n\bin\n8n（npm 全局安装）
        # 入口路径若失效，脚本会自动探测（本地 node_modules / npm root -g / PATH），
        # 探测到真实入口后替换并写日志，无需手动改。
        Arguments   = @('D:\npm-global\node_modules\n8n\bin\n8n', 'start')
        WorkingDir  = 'D:\npm-global'
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
            # 公司机曾设 D:\APP\n8n\.n8n，真实数据落在 .n8n\.n8n 双嵌套目录。
            # 家用机数据在默认 C:\Users\Allen\.n8n，因此【不要】设此变量，
            # 否则会拼出 \.n8n\.n8n 错误路径——这是两机最关键的差异。
            # 'N8N_USER_FOLDER'     = 'C:\Users\Allen\.n8n'   # ← 不要启用！
            # N8N_LOG_FILE 若未在此指定，会自动取 Logs.Stdout 的绝对路径
            # 'N8N_LOG_FILE'      = 'D:\APP\n8n-console\logs\n8n.log'
            # 禁用 task runner / Python runner：本机无 Python，避免 n8n 启动即退
            'N8N_RUNNERS_ENABLED' = 'false'
            'N8N_PYTHON_ENABLED'  = 'false'
            # ★ 家用机关键：系统有代理(HTTP_PROXY=127.0.0.1:7897 且 NODE_USE_ENV_PROXY=1)，
            #   node 22.22 的 undici 走 EnvHttpProxyAgent，n8n 的 license 等外部请求经代理挂起，
            #   导致启动卡死(进程活着但永不监听 5678)。设 0 让 n8n 进程直连外网。
            #   2026-08-22 实测：不清代理时 n8n 卡 30s+，设此变量后 12s 内就绪。公司机无代理可注释掉。
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
                Detect = 'node 可执行且版本 >=22.22'
                Install = @{
                    Kind = 'node-portable'   # 内置类型：下载 zip + 解压到 ToolsDir\node-<版本>
                }
            },
            @{
                Name = 'n8n 本体'
                Detect = 'D:\npm-global\node_modules\n8n 存在'
                Install = @{
                    Kind    = 'npm-install'   # 内置类型：用便携 node 的 npm 安装
                    Package = 'n8n@2.35.7'    # 家用机已装的全局版本（公司机曾是本地 2.35.4）
                    Prefix  = 'D:\npm-global' # npm 全局 prefix（家用机；公司机本地安装时是 D:\APP\n8n）
                }
            },
            @{
                Name = 'n8n 数据目录'
                Detect = 'C:\Users\Allen\.n8n 存在'
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
