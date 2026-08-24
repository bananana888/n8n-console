# ============================================================
#  uninstall.ps1 - 卸载 n8n 控制台（不依赖安装包）
#
#  与「直接删项目文件夹」的区别:
#    本脚本除清理本目录运行时产物外，还负责停止仍在运行的 n8n、
#    并删除安装包留下的系统残留（桌面/开始菜单快捷方式、HKCU
#    注册表、%LOCALAPPDATA% 下的 MSI 安装副本目录）。
#
#  n8n 本体与数据属用户资产，默认【保留】，需显式参数才删除:
#    -RemoveData       删除 n8n 数据目录 ~\.n8n（工作流/凭证，不可恢复）
#    -RemoveGlobalN8n  用 npm uninstall -g 卸载全局 n8n（D:\npm-global）
#
#  用法:
#    .\uninstall.ps1                           交互确认后清理（推荐）
#    .\uninstall.ps1 -WhatIf                   只打印将删除的清单，不实际删除
#    .\uninstall.ps1 -Force                    跳过交互确认
#    .\uninstall.ps1 -Force -RemoveData -RemoveGlobalN8n   彻底删干净
# ============================================================
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Force,           # 跳过交互确认
    [switch]$RemoveData,      # 同时删除 n8n 数据目录 ~\.n8n
    [switch]$RemoveGlobalN8n  # 同时用 npm 卸载全局 n8n
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

Write-Host ''
Write-Host '========== n8n 控制台 卸载 ==========' -ForegroundColor Cyan

# ---------- 1/2 停止运行中的 n8n ----------
Write-Host '==> 1/2 停止运行中的 n8n' -ForegroundColor Cyan
$killIds = New-Object 'System.Collections.Generic.HashSet[int]'
# 从 PID 文件读取
$pidFile = Join-Path $Root 'run\n8n.pid'
if (Test-Path $pidFile) {
    $pv = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($pv -match '^\d+$') { [void]$killIds.Add([int]$pv) }
}
# 服务端口占用进程（默认 5678，若配置了自定义端口则读取）
$ports = @(5678)
$configPath = Join-Path $Root 'n8n.config.psd1'
if (Test-Path $configPath) {
    $m = Select-String -Path $configPath -Pattern "Port\s*=\s*(\d+)" | Select-Object -First 1
    if ($m) { $ports = @([int]$m.Matches[0].Groups[1].Value) }
}
foreach ($port in $ports) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn -and $conn.OwningProcess -gt 0) { [void]$killIds.Add([int]$conn.OwningProcess) }
}
# 命令行含 n8n 的 node 进程（兜底，防止漏网的 runner/broker）
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'n8n' } |
    ForEach-Object { [void]$killIds.Add([int]$_.ProcessId) }
if (-not $WhatIfPreference) {
    foreach ($id in $killIds) {
        if (Get-Process -Id $id -ErrorAction SilentlyContinue) {
            Write-Host ("  停止 PID {0} ..." -f $id) -ForegroundColor Yellow
            & taskkill /PID $id /T /F 2>$null | Out-Null
        }
    }
}
if ($killIds.Count -eq 0) { Write-Host '  未检测到运行中的 n8n。' }
if ($WhatIfPreference) { Write-Host '  [WhatIf] 跳过进程停止。' }

# ---------- 2/2 收集并删除 ----------
Write-Host '==> 2/2 清理程序相关文件与系统残留' -ForegroundColor Cyan
$targets = New-Object System.Collections.ArrayList
function Add-Target([string]$Path, [string]$Kind) {
    if (Test-Path -LiteralPath $Path) { [void]$script:targets.Add([pscustomobject]@{ Path = $Path; Kind = $Kind }) }
}

# 本目录运行时/构建产物
Add-Target (Join-Path $Root 'logs') '运行时日志'
Add-Target (Join-Path $Root 'run') '运行时状态(PID)'
Add-Target (Join-Path $Root 'tools') '便携 node 运行时'
Add-Target (Join-Path $Root 'release') '构建产物(安装包)'
Add-Target (Join-Path $Root 'n8n-console.exe') '编译启动器'
Add-Target (Join-Path $Root 'packaging\tools') 'WiX 便携缓存'
Add-Target (Join-Path $Root 'packaging\Components.wxs') 'WiX 生成组件清单'
Get-ChildItem (Join-Path $Root 'packaging') -Filter *.wixobj -ErrorAction SilentlyContinue | ForEach-Object { Add-Target $_.FullName 'WiX 中间产物' }
Get-ChildItem (Join-Path $Root 'packaging') -Filter *.wixpdb -ErrorAction SilentlyContinue | ForEach-Object { Add-Target $_.FullName 'WiX 中间产物' }

# 安装包留下的系统残留
Add-Target (Join-Path ([Environment]::GetFolderPath('Desktop')) 'n8n 控制台.lnk') '桌面快捷方式'
$prog = [Environment]::GetFolderPath('Programs')
Get-ChildItem $prog -Filter '*n8n*' -ErrorAction SilentlyContinue | ForEach-Object { Add-Target $_.FullName '开始菜单快捷方式' }
Add-Target 'HKCU:\Software\n8n-console' 'HKCU 注册残留'
Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p.DisplayName -and $p.DisplayName -match 'n8n') { Add-Target $_.PSPath ('MSI 卸载注册(' + $p.DisplayName + ')') }
}
$msiCopy = Join-Path $env:LOCALAPPDATA 'n8n-console'
if ($msiCopy -ne $Root) { Add-Target $msiCopy 'MSI 安装副本目录' }

# 可选：n8n 数据（用户资产，需显式参数）
if ($RemoveData) { Add-Target (Join-Path $HOME '.n8n') 'n8n 用户数据(工作流/凭证)' }

# 展示清单并确认
if ($targets.Count -eq 0) {
    Write-Host '  没有检测到需要清理的程序残留。' -ForegroundColor Green
} else {
    Write-Host ('  将删除 {0} 项:' -f $targets.Count) -ForegroundColor Yellow
    foreach ($t in $targets) { Write-Host ('    - [{0}] {1}' -f $t.Kind, $t.Path) }
    Write-Host ''
    if (-not $Force -and -not $WhatIfPreference) {
        $ans = Read-Host '确认删除以上内容？(y=确认 / n=取消)'
        if ($ans -notmatch '^[yY]') { Write-Host '已取消，未删除任何内容。'; exit 0 }
    }
    Write-Host ''
    foreach ($t in $targets) {
        if ($PSCmdlet.ShouldProcess($t.Path, "删除 $($t.Kind)")) {
            Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $t.Path) {
                Write-Warning ("删除失败: {0}（可能被占用）" -f $t.Path)
            } else {
                Write-Host ("  [已删除] {0}" -f $t.Path) -ForegroundColor DarkGray
            }
        } else {
            Write-Host ("  [跳过] {0}" -f $t.Path) -ForegroundColor DarkGray
        }
    }
}

# ---------- 可选：全局 n8n ----------
if ($RemoveGlobalN8n) {
    Write-Host ''
    Write-Host '==> 卸载全局 n8n (npm)' -ForegroundColor Cyan
    $doIt = $Force -or $WhatIfPreference
    if (-not $doIt) {
        $ans = Read-Host '将执行 "npm uninstall -g n8n" 卸载全局 n8n，确认？(y/n)'
        $doIt = $ans -match '^[yY]'
    }
    if ($doIt) {
        if ($WhatIfPreference) {
            Write-Host '  [WhatIf] 跳过 npm 卸载。'
        } else {
            try { & npm uninstall -g n8n; Write-Host '  已卸载全局 n8n。' -ForegroundColor Green }
            catch { Write-Warning ('npm 卸载失败: ' + $_.Exception.Message) }
        }
    } else { Write-Host '  已跳过。' }
}

# ---------- 总结 ----------
Write-Host ''
Write-Host '========== 清理完成 ==========' -ForegroundColor Green
Write-Host '剩余内容（按需手动处理）:'
Write-Host ('  - 本文件夹源码: ' + $Root) -ForegroundColor DarkGray
Write-Host '      确认不再需要后，直接删除整个文件夹即可（含本脚本）。'
if (-not $RemoveData) {
    Write-Host ('  - n8n 数据: ' + (Join-Path $HOME '.n8n')) -ForegroundColor DarkGray
    Write-Host '      你的工作流与凭证。如需删除，请运行:  .\uninstall.ps1 -RemoveData'
}
if (-not $RemoveGlobalN8n) {
    Write-Host '  - 全局 n8n (npm): D:\npm-global' -ForegroundColor DarkGray
    Write-Host '      如需删除，请运行:  .\uninstall.ps1 -RemoveGlobalN8n'
}
