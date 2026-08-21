# ============================================================
#  n8n 控制台配置文件（PowerShell 数据文件）
#  所有 n8n 相关 / 本机相关的配置都在这，脚本本身保持通用。
#  用 Import-PowerShellDataFile 加载；缺失的键会用脚本内置默认值兜底。
# ============================================================

@{
    Console = @{
        # 控制台自身目录。留空则用脚本所在目录（$PSScriptRoot）
        Home   = 'D:\APP\n8n-console'
        LogDir = 'logs'
        RunDir = 'run'
        Icon   = 'assets\n8n.ico'
    }

    Service = @{
        # 后台进程描述
        Name = 'n8n'
        # 必须用绝对路径指向 node 22.22.2！
        # 原因: PATH 首位现在是 TRAE 自带的 node v22.16.0，n8n 2.35.4 要求 >=22.22，
        #       用 PATH 里的 node 会"启动即退"（Your Node.js version ... not supported）。
        #       本机 22.22.2 在 workbuddy 目录（HANDOFF 记录的一致）。
        # 若该目录被清理，安装 node >=22.22 后改回 'node' 即可。
        Executable  = 'C:\Users\SCY004730\.workbuddy\binaries\node\versions\22.22.2\node.exe'
        # 传给 Executable 的参数（n8n 可执行文件入口）
        Arguments   = @('D:\APP\n8n\node_modules\n8n\bin\n8n', 'start')
        WorkingDir  = 'D:\APP\n8n'
        # 进程名（用于 PID 校验，防 PID 被系统复用误判）；留空自动从 Executable 推导
        ProcessName = 'node'

        # 服务端口与健康检查
        Port              = 5678
        HealthUrl         = 'http://localhost:5678/healthz'
        EditorUrl         = 'http://localhost:5678'
        HealthTimeoutSec  = 30
        # 健康通过后再复检的等待窗口（秒），用于抓"端口已开但随后崩溃"(如 EPERM) 的延迟崩溃
        StabilityCheckSec = 4

        # 启动前清理前端解压缓存（相对 Env.N8N_USER_FOLDER），规避文件锁 EPERM 崩溃
        CleanCacheOnStart = $true

        # 注入给子进程的环境变量
        Env = @{
            # 注意: n8n 2.x 会把 .n8n 拼到该值之后作为真实数据目录
            #   => 真实数据在 D:\APP\n8n\.n8n\.n8n\（database.sqlite / config 密钥）——这个值不能乱改
            'N8N_USER_FOLDER'     = 'D:\APP\n8n\.n8n'
            # N8N_LOG_FILE 若未在此指定，会自动取 Logs.Stdout 的绝对路径
            # 'N8N_LOG_FILE'      = 'D:\APP\n8n-console\logs\n8n.log'
            # 禁用 task runner / Python runner：本机无 Python，避免 n8n 启动即退
            'N8N_RUNNERS_ENABLED' = 'false'
            'N8N_PYTHON_ENABLED'  = 'false'
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
        # 需要的 node 版本（n8n 2.35.4 要求 >=22.22）
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
                Detect = 'D:\APP\n8n\node_modules\n8n 存在'
                Install = @{
                    Kind    = 'npm-install'   # 内置类型：用便携 node 的 npm 安装
                    Package = 'n8n@2.35.4'
                    Prefix  = 'D:\APP\n8n'
                }
            },
            @{
                Name = 'n8n 数据与配置'
                Detect = 'D:\APP\n8n\.n8n\.n8n 存在'
                Install = @{
                    Kind = 'shell'           # 内置类型：执行 PowerShell 命令
                    DetectScript = 'Test-Path "D:\APP\n8n\.n8n\.n8n"'
                    Script = @'
# n8n 数据目录与运行配置初始化（已存在则跳过）
$n8nHome = "D:\APP\n8n"
$dataDir = "$n8nHome\.n8n"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
# package.json（npm start/stop 入口）
if (-not (Test-Path "$n8nHome\package.json")) {
    @{
        name = "n8n"; version = "1.0.0"; private = $true
        scripts = @{ start = "node node_modules/n8n/bin/n8n start"; stop = "node node_modules/n8n/bin/n8n stop" }
    } | ConvertTo-Json | Set-Content "$n8nHome\package.json" -Encoding UTF8
}
# .npmrc（镜像源 + 项目内缓存，绕开系统缓存锁）
if (-not (Test-Path "$n8nHome\.npmrc")) {
    "registry=https://registry.npmmirror.com`ncache=D:\APP\n8n\.npm-cache" | Set-Content "$n8nHome\.npmrc" -Encoding UTF8
}
'@
                }
            }
        )
    }
}
