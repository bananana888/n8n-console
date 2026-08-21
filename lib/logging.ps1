# ============================================================
#  lib/logging.ps1 - 日志工具
#  依赖 $script:Config.Paths（由 lib/config.ps1 提供）。
# ============================================================

function Write-CtrlLog([string]$msg) {
    Add-Content -Path $script:Config.Paths.ControlLog -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) -Encoding UTF8
}

function Write-FatalLog([string]$msg) {
    Add-Content -Path $script:Config.Paths.FatalLog -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) -Encoding UTF8
}
