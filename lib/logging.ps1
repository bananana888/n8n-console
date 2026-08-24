# ============================================================
#  lib/logging.ps1 - 日志工具（含轮转）
#  依赖 $script:Config.Paths（由 lib/config.ps1 提供）。
#  日志超过 2MB 自动滚动为 .1/.2，保留 3 份，避免无限增长。
# ============================================================

# 日志轮转：文件超过 $maxBytes 时滚动为 .1/.2/.3，保留 $keep 份
function Rotate-LogFile {
    param([string]$path, [long]$maxBytes = 2MB, [int]$keep = 3)
    if (-not (Test-Path $path)) { return }
    try {
        $size = (Get-Item $path).Length
        if ($size -lt $maxBytes) { return }
        # 从最旧到最新滚动：.3 <- .2 <- .1，再把当前文件复制为 .1 并清空
        for ($i = $keep - 1; $i -ge 1; $i--) {
            $old = "$path.$i"
            $new = "$path.$($i + 1)"
            if (Test-Path $old) { Move-Item $old $new -Force -ErrorAction SilentlyContinue }
        }
        Copy-Item $path "$path.1" -Force -ErrorAction SilentlyContinue
        Set-Content $path -Value "" -Encoding UTF8
    } catch { }
}

function Write-CtrlLog([string]$msg) {
    try {
        Rotate-LogFile $script:Config.Paths.ControlLog
        Add-Content -Path $script:Config.Paths.ControlLog -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) -Encoding UTF8
    } catch {
        # 日志写入失败（文件被锁/权限不足）不阻断主流程，静默降级
    }
}

function Write-FatalLog([string]$msg) {
    try {
        Rotate-LogFile $script:Config.Paths.FatalLog
        Add-Content -Path $script:Config.Paths.FatalLog -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) -Encoding UTF8
    } catch {
        # 日志写入失败不阻断主流程（致命错误本身已由调用方处理）
    }
}
