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
    [switch]$Silent
)

$ErrorActionPreference = "Stop"

# ---------- 加载配置 ----------
. (Join-Path $PSScriptRoot "lib\config.ps1")
$script:Config = Get-Config -Root $PSScriptRoot

# ---------- 点源 lib (共享同一会话作用域, 规避模块作用域坑) ----------
. (Join-Path $PSScriptRoot "lib\logging.ps1")
. (Join-Path $PSScriptRoot "lib\service.ps1")
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

# ---------- 入口分派 ----------
try {
    switch ($Action.ToLower()) {
        "start" {
            $r = Start-ManagedService
            if ($r.Ok -and -not $Silent) {
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
