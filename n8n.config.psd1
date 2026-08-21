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
}
