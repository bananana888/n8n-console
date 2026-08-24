# ============================================================
#  uninstall.ps1 - 卸载 n8n 控制台（不依赖安装包，可自选删除程度）
#
#  删除类别:
#    [1] 控制台程序   快捷方式 / HKCU 注册 / MSI 安装副本
#    [2] 运行时缓存   logs / run / release / 构建产物
#    [3] 便携运行时   tools\node-<版本>（便携 node 及其中安装的 n8n）
#    [4] 全局 n8n     npm uninstall -g（D:\npm-global）
#    [5] n8n 数据     ~\.n8n（工作流/凭证，不可恢复）
#
#  交互菜单（无参数）:
#    .\uninstall.ps1                弹菜单选择删除程度（回车 = 默认 1,2）
#
#  参数模式:
#    .\uninstall.ps1 -Console       只删控制台程序(1)
#    .\uninstall.ps1 -Cache         只删运行时缓存(2)
#    .\uninstall.ps1 -Portable      删便携 node+n8n(3)
#    .\uninstall.ps1 -GlobalN8n     卸载全局 n8n(4)（旧名 -RemoveGlobalN8n）
#    .\uninstall.ps1 -Data          删 n8n 数据(5)（旧名 -RemoveData）
#    .\uninstall.ps1 -Force         跳过交互确认（无类别参数时默认 1,2）
#    .\uninstall.ps1 -WhatIf        只预览清单，不实际删除
# ============================================================
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Force,           # 跳过交互确认
    [switch]$Console,         # 类别1: 控制台程序
    [switch]$Cache,           # 类别2: 运行时缓存
    [switch]$Portable,        # 类别3: 便携运行时 node+n8n
    [Alias('RemoveGlobalN8n')][switch]$GlobalN8n,  # 类别4: 全局 n8n（旧参数名兼容）
    [Alias('RemoveData')][switch]$Data             # 类别5: n8n 数据（旧参数名兼容）
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

Write-Host ''
Write-Host '========== n8n 控制台 卸载 ==========' -ForegroundColor Cyan

# ---------- 停止运行中的 n8n ----------
Write-Host '==> 停止运行中的 n8n' -ForegroundColor Cyan
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

# ---------- 交互菜单：选择删除程度 ----------
function Select-DeleteLevel {
    while ($true) {
        Write-Host ''
        Write-Host '请选择要删除的内容（逗号分隔，如 1,2 或 3,5；回车 = 默认 1,2）:' -ForegroundColor Cyan
        Write-Host '  [1] 控制台程序（快捷方式/注册表/MSI 副本）'
        Write-Host '  [2] 运行时缓存（logs/run/release/构建产物）'
        Write-Host '  [3] 便携运行时 node+n8n（tools\，当前文件夹下）'
        Write-Host '  [4] 全局 n8n（npm uninstall -g，D:\npm-global）'
        Write-Host '  [5] n8n 数据（~\.n8n，不可恢复）'
        Write-Host '  [0] 全部删除'
        $ans = Read-Host '选择'
        if ($ans.Trim() -eq '0') { return @(1,2,3,4,5) }
        if ([string]::IsNullOrWhiteSpace($ans)) { return @(1,2) }
        $nums = @()
        $ok = $true
        foreach ($part in ($ans -split ',|，')) {
            $n = 0
            if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 5) { $nums += $n }
            else { $ok = $false; break }
        }
        if ($ok -and $nums.Count -gt 0) { return @($nums | Sort-Object -Unique) }
        Write-Host '  输入无效，请重新选择（1-5 逗号分隔，或 0 全删）。' -ForegroundColor Yellow
    }
}

# ---------- 确定删除类别 ----------
$wanted = @()
if ($Console) { $wanted += 1 }
if ($Cache) { $wanted += 2 }
if ($Portable) { $wanted += 3 }
if ($GlobalN8n) { $wanted += 4 }
if ($Data) { $wanted += 5 }
if ($wanted.Count -eq 0) {
    if ($Force) { $wanted = @(1,2) }   # -Force 无类别参数：安全默认只删控制台+缓存
    else { $wanted = Select-DeleteLevel }
}

# ---------- 按类别收集删除目标 ----------
Write-Host '==> 收集待删除内容' -ForegroundColor Cyan
$targets = New-Object System.Collections.ArrayList
function Add-Target([string]$Path, [string]$Kind) {
    if (Test-Path -LiteralPath $Path) { [void]$script:targets.Add([pscustomobject]@{ Path = $Path; Kind = $Kind }) }
}

# 类别1: 控制台程序
if ($wanted -contains 1) {
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
}
# 类别2: 运行时缓存
if ($wanted -contains 2) {
    Add-Target (Join-Path $Root 'logs') '运行时日志'
    Add-Target (Join-Path $Root 'run') '运行时状态(PID)'
    Add-Target (Join-Path $Root 'release') '构建产物(安装包)'
    Add-Target (Join-Path $Root 'n8n-console.exe') '编译启动器'
    Add-Target (Join-Path $Root 'packaging\tools') 'WiX 便携缓存'
    Add-Target (Join-Path $Root 'packaging\Components.wxs') 'WiX 生成组件清单'
    Get-ChildItem (Join-Path $Root 'packaging') -Filter *.wixobj -ErrorAction SilentlyContinue | ForEach-Object { Add-Target $_.FullName 'WiX 中间产物' }
    Get-ChildItem (Join-Path $Root 'packaging') -Filter *.wixpdb -ErrorAction SilentlyContinue | ForEach-Object { Add-Target $_.FullName 'WiX 中间产物' }
}
# 类别3: 便携运行时 node+n8n
if ($wanted -contains 3) {
    Get-ChildItem (Join-Path $Root 'tools') -Directory -Filter 'node-*' -ErrorAction SilentlyContinue | ForEach-Object { Add-Target $_.FullName '便携 node 运行时' }
    # 系统 node 场景下 n8n 直接装到 tools\node_modules（无便携 node 时的落点）
    Add-Target (Join-Path $Root 'tools\node_modules') 'tools 下安装的 n8n'
}
# 类别5: n8n 数据
if ($wanted -contains 5) { Add-Target (Join-Path $HOME '.n8n') 'n8n 用户数据(工作流/凭证)' }

# ---------- 展示清单并确认 ----------
if ($targets.Count -gt 0) {
    Write-Host ('  将删除 {0} 项:' -f $targets.Count) -ForegroundColor Yellow
    foreach ($t in $targets) { Write-Host ('    - [{0}] {1}' -f $t.Kind, $t.Path) }
    Write-Host ''
}
if ($wanted -contains 4) {
    Write-Host '  将执行: npm uninstall -g n8n（卸载全局 n8n，D:\npm-global）' -ForegroundColor Yellow
    Write-Host ''
}

if ($targets.Count -eq 0 -and -not ($wanted -contains 4)) {
    Write-Host '  所选类别没有需要清理的内容。' -ForegroundColor Green
} else {
    if (-not $Force -and -not $WhatIfPreference) {
        $ans = Read-Host '确认执行以上删除？(y=确认 / n=取消)'
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
    if ($wanted -contains 4) {
        if ($PSCmdlet.ShouldProcess('npm uninstall -g n8n', '卸载全局 n8n')) {
            try { & npm uninstall -g n8n; Write-Host '  已卸载全局 n8n。' -ForegroundColor Green }
            catch { Write-Warning ('npm 卸载失败: ' + $_.Exception.Message) }
        }
    }
}

# ---------- 总结 ----------
Write-Host ''
Write-Host '========== 卸载完成 ==========' -ForegroundColor Green
$remaining = @()
if (-not ($wanted -contains 1)) { $remaining += '快捷方式 / 注册表 / MSI 副本（-Console）' }
if (-not ($wanted -contains 2)) { $remaining += '运行时缓存（-Cache）' }
if (-not ($wanted -contains 3)) { $remaining += '便携 node 与其中 n8n（-Portable）' }
if (-not ($wanted -contains 4)) { $remaining += '全局 n8n（-GlobalN8n）' }
if (-not ($wanted -contains 5)) { $remaining += 'n8n 数据 ~\.n8n（-Data）' }
Write-Host '本次未删除、仍保留的内容:'
if ($remaining.Count -eq 0) { Write-Host '  （无——已全部删除）' }
else { foreach ($r in $remaining) { Write-Host ('  - ' + $r) } }
Write-Host ('  - 本文件夹源码: ' + $Root)
Write-Host '      确认不再需要后，直接删除整个文件夹即可（含本脚本）。'
Write-Host ''
Write-Host '如需补删，可再运行（示例）:  .\uninstall.ps1 -Data -GlobalN8n' -ForegroundColor DarkGray
