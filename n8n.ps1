# ============================================================
#  n8n 控制台 - 主入口 (启动/停止/状态/菜单)
#  用法:
#    powershell -ExecutionPolicy Bypass -File n8n.ps1                 (弹出控制面板)
#    powershell -ExecutionPolicy Bypass -File n8n.ps1 -Action start
#    powershell -ExecutionPolicy Bypass -File n8n.ps1 -Action stop
#    powershell -ExecutionPolicy Bypass -File n8n.ps1 -Action status
#  -Silent 参数: 静默模式, 不弹任何窗口, 结果只写日志 (供测试/自动化)
#
#  结构: 本文件只做装配与分派; 配置在 n8n.config.psd1,
#        逻辑在 lib/{config,logging,service,gui}.ps1 (点源加载, 共享同一作用域)
# ============================================================

param(
    [ValidateSet("menu", "start", "stop", "status")]
    [string]$Action = "menu",
    [switch]$Silent,
    [string]$ConfigFile = "",
    [switch]$Version
)

$ErrorActionPreference = "Stop"
$script:AppVersion = '4.1.3'

# ---------- 加载配置（-ConfigFile 支持多实例壳子，默认 n8n.config.psd1）----------
. (Join-Path $PSScriptRoot "lib\config.ps1")
$script:Config = Get-Config -Root $PSScriptRoot -ConfigFile $ConfigFile

# ---------- 点源 lib (共享同一会话作用域, 规避模块作用域坑) ----------
. (Join-Path $PSScriptRoot "lib\logging.ps1")
. (Join-Path $PSScriptRoot "lib\service.ps1")
. (Join-Path $PSScriptRoot "lib\setup.ps1")
. (Join-Path $PSScriptRoot "lib\gui.ps1")

# ---------- 提示工具 (Silent 时只写日志) ----------
function Show-Msg([string]$msg) {
    if ($Silent) {
        Write-CtrlLog "[MSG] $msg"
    } else {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        [System.Windows.Forms.MessageBox]::Show($msg, "n8n 控制台") | Out-Null
    }
}
function Show-YesNo([string]$msg) {
    if ($Silent) { return $true }
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $r = [System.Windows.Forms.MessageBox]::Show($msg, "n8n 控制台",
         [System.Windows.Forms.MessageBoxButtons]::YesNo,
         [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

# ---------- 版本查询 ----------
if ($Version) {
    Write-Output "n8n-console v$script:AppVersion (实例: $($script:Config.Instance))"
    exit 0
}

# ---------- 入口分派 ----------
try {
    switch ($Action.ToLower()) {
        "start" {
            # 环境自检：缺依赖则自动安装（控制台"工具箱"能力）
            $missing = Test-SetupNeeded
            if ($missing.Count -gt 0) {
                $names = ($missing | ForEach-Object { $_.Name }) -join "、"
                if ($Silent) {
                    Write-FatalLog "环境缺失，需要安装: $names。请打开控制台 GUI 触发自动安装。"
                    Show-Msg "环境缺失，需要安装: $names`n`n请打开控制台 GUI，点"启动"触发自动安装。"
                    return
                }
                if (Show-YesNo "检测到缺少环境: $names`n`n需要自动安装，是否继续？") {
                    Write-CtrlLog "开始自动安装: $names"
                    try { Invoke-Setup } catch {
                        Write-FatalLog "自动安装异常: $($_.Exception.Message)"
                        Show-Msg "自动安装异常: $($_.Exception.Message)`n详见 logs\setup.log"
                        return
                    }
                    if ((Test-SetupNeeded).Count -gt 0) {
                        Show-Msg "环境安装未完成，请检查 logs\setup.log"
                        return
                    }
                    Write-CtrlLog "环境安装完成，继续启动"
                } else {
                    return
                }
            }
            $r = Start-ManagedService
            # 启动成功 / 检测到已在运行：都自动打开 web UI（Silent 不弹浏览器）
            if (($r.Ok -or $r.OpenEditor) -and -not $Silent) {
                try { Start-Process $script:Config.Service.EditorUrl } catch { }
            }
            Show-Msg $r.Message
        }
        "stop" {
            if (Show-YesNo "确认停止 $($script:Config.Service.Name) 吗？") {
                $r = Stop-ManagedService
                Show-Msg $r.Message
            }
        }
        "status" {
            $s = Get-ManagedStatus
            $svc = $script:Config.Service.Name
            if ($s.Running) {
                $port = if ($s.Port) { "已开启" } else { "未监听(可能仍在启动)" }
                Show-Msg "$svc 运行中`nPID: $($s.PID)`n端口 $($script:Config.Service.Port): $port`n`n日志: $($script:Config.Paths.StdoutLog)"
            } else {
                Show-Msg "$svc 未运行。`n`n日志目录: $($script:Config.Paths.LogDir)"
            }
        }
        default { Show-Gui }
    }
} catch {
    $err = $_.Exception.Message
    Write-FatalLog "脚本异常($Action): $err"
    if (-not $Silent) {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        [System.Windows.Forms.MessageBox]::Show("n8n 控制脚本发生异常: $err", "n8n 控制台") | Out-Null
    }
}
