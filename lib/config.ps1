# ============================================================
#  lib/config.ps1 - 配置加载与默认值合并
#  加载 n8n.config.psd1，与内置默认值深度合并，解析绝对路径。
#  结果存到 $script:Config，供其它 lib 读取。
#  用法: $script:Config = Get-Config -Root <控制台根目录>
#  （注意: 本文件在 lib\ 下，$PSScriptRoot 指向 lib\，因此根目录必须由调用方传入）
# ============================================================

# 递归合并两个字典：override 的键优先，base 缺失的键补上
function Merge-Deep {
    param($base, $override)
    $out = @{}
    foreach ($k in $base.Keys) {
        if ($override.ContainsKey($k)) {
            $ov = $override[$k]
            if ($ov -is [System.Collections.IDictionary] -and $base[$k] -is [System.Collections.IDictionary]) {
                $out[$k] = Merge-Deep $base[$k] $ov
            } else {
                $out[$k] = $ov
            }
        } else {
            $out[$k] = $base[$k]
        }
    }
    foreach ($k in $override.Keys) {
        if (-not $out.ContainsKey($k)) { $out[$k] = $override[$k] }
    }
    return $out
}

function Get-Config {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $PSScriptRoot }

    # 内置默认配置（键缺失时兜底；配置文件的键会覆盖默认值）
    $defaults = @{
        Console = @{
            Home   = $Root
            LogDir = 'logs'
            RunDir = 'run'
            Icon   = 'assets\n8n.ico'
        }
        Service = @{
            Name              = 'n8n'
            Executable        = 'node'
            Arguments         = @()
            WorkingDir        = $Root
            ProcessName       = $null
            Port              = 5678
            HealthUrl         = 'http://localhost:5678/healthz'
            EditorUrl         = 'http://localhost:5678'
            HealthTimeoutSec  = 30
            StabilityCheckSec = 4
            CleanCacheOnStart = $true
            Env               = @{}
        }
        Logs = @{
            Control = 'control.log'
            Fatal   = 'error.log'
            Stdout  = 'n8n.log'
            Stderr  = 'n8n-error.log'
        }
    }

    # 加载用户配置文件
    $cfgFile = Join-Path $Root 'n8n.config.psd1'
    $user = @{}
    if (Test-Path $cfgFile) {
        try {
            $user = Import-PowerShellDataFile $cfgFile
        } catch {
            Write-Host "警告: 配置文件解析失败，使用内置默认值: $cfgFile ($($_.Exception.Message))" -ForegroundColor Yellow
        }
    }
    $cfg = Merge-Deep $defaults $user

    # 解析绝对路径（注意: 不用 $home 作变量名，它是 PowerShell 只读自动变量）
    $homeDir = $cfg.Console.Home
    if ([string]::IsNullOrWhiteSpace($homeDir)) { $homeDir = $Root }
    if (-not [IO.Path]::IsPathRooted($homeDir)) { $homeDir = Join-Path $Root $homeDir }
    $cfg.Console.Home = $homeDir

    $logDir = [IO.Path]::Combine($homeDir, $cfg.Console.LogDir)
    $runDir = [IO.Path]::Combine($homeDir, $cfg.Console.RunDir)
    foreach ($d in @($logDir, $runDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # 进程名：显式配置优先，否则从 Executable 推导（node.exe -> node）
    if ([string]::IsNullOrWhiteSpace($cfg.Service.ProcessName)) {
        $cfg.Service.ProcessName = [IO.Path]::GetFileNameWithoutExtension($cfg.Service.Executable)
    }

    # 统一解析后的路径表，供 logging/service/gui 使用
    $cfg.Paths = @{
        Home       = $homeDir
        LogDir     = $logDir
        RunDir     = $runDir
        Icon       = [IO.Path]::Combine($homeDir, $cfg.Console.Icon)
        ControlLog = [IO.Path]::Combine($logDir, $cfg.Logs.Control)
        FatalLog   = [IO.Path]::Combine($logDir, $cfg.Logs.Fatal)
        StdoutLog  = [IO.Path]::Combine($logDir, $cfg.Logs.Stdout)
        StderrLog  = [IO.Path]::Combine($logDir, $cfg.Logs.Stderr)
        PidFile    = [IO.Path]::Combine($runDir, 'n8n.pid')
        StampFile  = [IO.Path]::Combine($runDir, 'n8n.started')
    }

    # N8N_LOG_FILE 未显式配置时，从 Logs.Stdout 推导绝对路径
    if (-not $cfg.Service.Env.ContainsKey('N8N_LOG_FILE')) {
        $cfg.Service.Env['N8N_LOG_FILE'] = $cfg.Paths.StdoutLog
    }

    return $cfg
}
