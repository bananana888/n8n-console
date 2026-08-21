# ============================================================
#  示例配置模板 —— 如何为任意命令行服务创建控制台实例
#
#  用法: 复制本文件为「你的服务名.config.psd1」，填写带 ★ 的字段即可
#        powershell -ExecutionPolicy Bypass -File n8n.ps1 -ConfigFile 你的服务名.config.psd1
#
#  一套壳子管多个服务：运行时文件（run\*.pid / *.started / 安装进度）按
#  配置文件名隔离，互不干扰。也可以复制整个目录改名用。
# ============================================================

@{
    Console = @{
        # 控制台根目录（一般不改；留空用脚本所在目录）
        Home   = 'D:\APP\n8n-console'
        LogDir = 'logs'
        RunDir = 'run'
        Icon   = 'assets\n8n.ico'        # 可换成你自己的 .ico
    }

    Service = @{
        # ★ 服务显示名（GUI 标题/提示文案用）
        Name         = 'my-service'
        # ★ 启动命令或可执行文件绝对路径（node 可用 PATH 名或绝对路径）
        Executable   = 'node'
        # ★ 传给 Executable 的参数（如 n8n 是 node_modules\n8n\bin\n8n + start）
        Arguments    = @('D:\path\to\app.js', 'start')
        # ★ 工作目录（相对路径/配置文件以它为基准）
        WorkingDir   = 'D:\path\to'
        # 进程名（PID 校验，防 PID 复用误判）；留空自动从 Executable 推导
        ProcessName  = 'node'

        # ★ 服务监听端口与健康检查
        Port             = 8080
        HealthUrl        = 'http://localhost:8080/healthz'
        EditorUrl        = 'http://localhost:8080'   # 启动成功后自动打开的地址
        HealthTimeoutSec = 30
        # 健康通过后再复检的窗口（秒），抓"端口已开但随后崩溃"的延迟崩溃
        StabilityCheckSec = 4

        # 启动前清理缓存（若服务解压资源到本地且易被文件锁，设 $true；n8n 用）
        CleanCacheOnStart = $false

        # 注入给服务进程的环境变量
        Env = @{
            # 'MY_APP_HOME' = 'D:\path'
        }
    }

    Logs = @{
        # 纯文件名，目录由 Console.LogDir 决定
        Control = 'control.log'    # 操作审计
        Fatal   = 'error.log'      # 脚本异常兜底
        Stdout  = 'stdout.log'     # 服务运行输出
        Stderr  = 'stderr.log'     # 服务 stderr
    }

    # ---------- 环境自检 + 自动安装（可选能力）----------
    # 不想要就 Enabled = $false；完整示例见 n8n.config.psd1 的 Setup 段
    Setup = @{
        Enabled     = $false
        NodeMirror  = 'https://npmmirror.com/mirrors/node/'
        NpmRegistry = 'https://registry.npmmirror.com'
        NodeVersion = 'v22.22.2'
        ToolsDir    = 'tools'      # 便携 node 解压目录（相对 Console.Home）
        Steps       = @()          # 检测/安装步骤数组
    }
}
