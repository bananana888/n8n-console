# ============================================================
#  lib/setup.ps1 - 环境检测与自动安装（无 UI，通用壳子能力）
#  依赖 $script:Config（Setup 段）。被 n8n.ps1 点源到主 runspace；
#  安装流程在独立 runspace 执行（Invoke-Setup）。
#  进度通过进度文件 run\<instance>.setup.json 回传，GUI/CLI 轮询读取。
#
#  内置安装类型（Setup.Steps[].Install.Kind）：
#   - node-portable : 从 NodeMirror 下载 node zip 解压到 ToolsDir\node-<版本>，便携免管理员
#   - npm-install   : 用便携 node 的 npm 安装包到 Prefix
#   - shell         : 执行自定义 PowerShell 命令（初始化目录/写配置）
# ============================================================

# ---------- 进度文件 ----------
function Get-SetupProgressFile {
    return Join-Path $script:Config.Paths.RunDir "$($script:Config.Instance).setup.json"
}

function Write-SetupProgress {
    param([hashtable]$data)
    try {
        ($data | ConvertTo-Json -Compress) | Set-Content -Path (Get-SetupProgressFile) -Encoding UTF8
    } catch { }
}

# ---------- 便携 node 解析 ----------
# 解析优先级: 便携 node（Setup 装到 tools\）→ 配置 Executable（绝对路径）→ PATH 中的 node。
# 配置的绝对路径失效（换机器/目录被清理）时自动回退 PATH，不会卡死，由调用方给出明确报错。
function Get-NodeExecutable {
    $setup = $script:Config.Setup
    if ($setup.Enabled -and -not [string]::IsNullOrWhiteSpace($setup.NodeVersion)) {
        $p = Join-Path $setup.ToolsDir "node-$($setup.NodeVersion)\node.exe"
        if (Test-Path $p) { return $p }
    }
    $cfg = $script:Config.Service.Executable
    if ([IO.Path]::IsPathRooted($cfg)) {
        if (Test-Path $cfg) { return $cfg }
    } else {
        $cmd = Get-Command $cfg -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    }
    $fallback = Get-Command 'node' -ErrorAction SilentlyContinue
    if ($fallback -and $fallback.Source) { return $fallback.Source }
    return $cfg   # 全部失效时原样返回，由 service.ps1 的定位逻辑给出明确报错
}

# ---------- n8n 入口自动探测 ----------
# n8n 启动脚本随安装方式/机器迁移而变化（本地安装 D:\APP\n8n\node_modules\n8n\bin\n8n、
# 全局安装 D:\npm-global\node_modules\n8n\bin\n8n 等）。按顺序探测真实入口：
#   ① 配置 Service.Arguments[0]（绝对路径存在即用）
#   ② {WorkingDir}\node_modules\n8n\bin\n8n（npm 本地安装）
#   ③ npm root -g 定位全局 node_modules → n8n\bin\n8n（npm 全局安装）
#   ④ PATH 中 n8n.cmd shim，解析其内部指向的真实 JS 入口
# 找不到返回空串，由调用方（service.ps1）报错提示配置。
function Get-N8nEntrypoint {
    $srv = $script:Config.Service
    $cands = New-Object System.Collections.ArrayList

    # ① 配置的入口（绝对路径）
    if ($srv.Arguments.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($srv.Arguments[0])) {
        [void]$cands.Add([string]$srv.Arguments[0])
    }
    # ② 本地安装（工作目录下 node_modules）
    if (-not [string]::IsNullOrWhiteSpace($srv.WorkingDir)) {
        [void]$cands.Add((Join-Path $srv.WorkingDir 'node_modules\n8n\bin\n8n'))
    }
    # ③ 全局安装（npm root -g）
    $npmRoot = ''
    $npmCmd = Get-Command 'npm' -ErrorAction SilentlyContinue
    if ($npmCmd -and $npmCmd.Source) {
        try { $npmRoot = (& $npmCmd.Source root -g 2>$null | Out-String).Trim() } catch { }
    }
    if (-not $npmRoot) {
        # npm 不在 PATH：用便携 node 同目录的 npm.cmd（Setup 自动安装场景）
        $nodeExe = Get-NodeExecutable
        $npmPath = Join-Path (Split-Path $nodeExe -Parent) 'npm.cmd'
        if (Test-Path $npmPath) {
            try { $npmRoot = (& $npmPath root -g 2>$null | Out-String).Trim() } catch { }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($npmRoot)) {
        [void]$cands.Add((Join-Path $npmRoot 'n8n\bin\n8n'))
    }
    # ④ PATH 中 n8n.cmd shim，解析其内部 %~dp0\...\n8n\bin\n8n 真实 JS 入口
    $shim = Get-Command 'n8n.cmd' -ErrorAction SilentlyContinue
    if ($shim -and $shim.Source -and (Test-Path $shim.Source)) {
        try {
            $content = Get-Content $shim.Source -Raw -ErrorAction Stop
            if ($content -match '%~dp0([\\/][^"`\r\n]*n8n[\\/]bin[\\/]n8n[^"`\r\n]*)') {
                $dp0 = Split-Path $shim.Source -Parent
                [void]$cands.Add((Join-Path $dp0 $matches[1]))
            }
        } catch { }
    }

    foreach ($c in $cands) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path $c)) { return $c }
    }
    return ''
}

# node 是否可用且版本满足（>= 22.22，n8n 2.35.4 要求）
function Test-NodeAvailable {
    $exe = Get-NodeExecutable
    if (-not (Test-Path $exe)) { return $false }
    try {
        $v = (& $exe --version 2>&1 | Out-String).Trim()
        if ($v -match 'v(\d+)\.(\d+)') {
            $major = [int]$matches[1]; $minor = [int]$matches[2]
            if ($major -gt 22) { return $true }
            if ($major -eq 22 -and $minor -ge 22) { return $true }
        }
    } catch { }
    return $false
}

# ---------- 检测 ----------
# 返回缺失步骤数组（Setup.Enabled=$false 时返回空 = 无需安装）
function Test-SetupNeeded {
    $setup = $script:Config.Setup
    if (-not $setup.Enabled) { return ,@() }
    $missing = @()
    foreach ($step in $setup.Steps) {
        if (-not (Test-SetupStep $step)) { $missing += $step }
    }
    return ,$missing
}

function Test-SetupStep {
    param($step)
    $install = $step.Install
    switch ($install.Kind) {
        'node-portable' {
            return (Test-NodeAvailable)
        }
        'npm-install' {
            $pkgName = ($install.Package -split '@')[0]
            return (Test-Path (Join-Path $install.Prefix "node_modules\$pkgName"))
        }
        'shell' {
            if ($install.DetectScript) {
                try { return [bool](& ([scriptblock]::Create($install.DetectScript))) }
                catch { return $false }
            }
            return $true
        }
        default { return $true }
    }
}

# ---------- 安装 ----------
function Invoke-Setup {
    param([bool]$Force = $false)
    $setup = $script:Config.Setup
    if (-not $setup.Enabled) { return }

    # 收集需要安装的步骤
    $steps = @()
    foreach ($step in $setup.Steps) {
        if ($Force -or -not (Test-SetupStep $step)) { $steps += $step }
    }
    if ($steps.Count -eq 0) {
        Write-SetupProgress @{ running=$false; done=$true; error=$null }
        return
    }

    $total = $steps.Count
    $i = 0
    foreach ($step in $steps) {
        $i++
        Write-CtrlLog "安装步骤 $i/$total : $($step.Name)"
        if (-not (Invoke-SetupStep $step -index $i -total $total)) {
            Write-SetupProgress @{ running=$false; done=$false; error="安装失败: $($step.Name)" }
            Write-FatalLog "环境安装失败: $($step.Name)"
            throw "环境安装失败: $($step.Name)"
        }
    }
    Write-SetupProgress @{ running=$false; done=$true; error=$null }
    Write-CtrlLog "环境安装完成"
}

function Invoke-SetupStep {
    param($step, [int]$index, [int]$total)
    switch ($step.Install.Kind) {
        'node-portable' { return (Install-NodePortable $step -index $index -total $total) }
        'npm-install'   { return (Install-NpmPackage $step -index $index -total $total) }
        'shell'         { return (Invoke-ShellStep $step -index $index -total $total) }
        default {
            Write-CtrlLog "未知安装类型: $($step.Install.Kind)"
            return $false
        }
    }
}

# node-portable: 下载官方 zip 解压到 ToolsDir\node-<版本>（便携，不动系统）
function Install-NodePortable {
    param($step, [int]$index, [int]$total)
    $setup = $script:Config.Setup
    $version = $setup.NodeVersion
    $tools = $setup.ToolsDir
    $nodeDir = Join-Path $tools "node-$version"
    $nodeExe = Join-Path $nodeDir 'node.exe'
    if (-not (Test-Path $nodeExe)) {
        if (-not (Test-Path $tools)) { New-Item -ItemType Directory -Path $tools -Force | Out-Null }
        $zipUrl = "$($setup.NodeMirror)$version/node-$version-win-x64.zip"
        $zipFile = Join-Path $tools "node-$version.zip"
        Write-SetupProgress @{ running=$true; step=$index; stepCount=$total; stepName=$step.Name; percent=0; message="下载 node $version ..."; mode='bar' }
        if (-not (Download-File $zipUrl $zipFile $index $total)) { return $false }
        Write-SetupProgress @{ running=$true; step=$index; stepCount=$total; stepName=$step.Name; percent=90; message="解压 node $version ..."; mode='marquee' }
        try {
            Expand-Archive -Path $zipFile -DestinationPath $tools -Force
        } catch {
            Write-CtrlLog "node 解压失败: $($_.Exception.Message)"
            return $false
        }
        Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
        # zip 内目录名是 node-<版本>-win-x64，规整为 node-<版本>
        $unpacked = Join-Path $tools "node-$version-win-x64"
        if ((Test-Path $unpacked) -and -not (Test-Path $nodeDir)) {
            try { Rename-Item $unpacked $nodeDir } catch { }
        }
    }
    return (Test-Path $nodeExe)
}

# 带进度的文件下载（HttpWebRequest 手动流式读取，循环内算进度写进度文件。
# 不用 WebClient.DownloadFile：其进度事件只在异步方法触发，同步调用无进度）
function Download-File {
    param([string]$url, [string]$outFile, [int]$stepIndex, [int]$stepTotal)
    $script:_lastPct = -1
    $resp = $null; $in = $null; $out = $null
    try {
        # PS5.1 默认 TLS 可能不含 1.2，显式启用（npmmirror https 需要）
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Timeout = 60000
        $resp = $req.GetResponse()
        $total = [long]$resp.ContentLength
        $in = $resp.GetResponseStream()
        $out = [System.IO.File]::Create($outFile)
        $buf = New-Object byte[] 81920
        $downloaded = [long]0
        # 读流总超时：受限网络/电脑不卡死，超时直接失败
        $dlTimeoutSec = if ($script:Config.Setup.InstallTimeoutSec) { $script:Config.Setup.InstallTimeoutSec } else { 600 }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (($read = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            if ($sw.Elapsed.TotalSeconds -gt $dlTimeoutSec) {
                Write-CtrlLog "下载超时(>$dlTimeoutSec s)，已中止"
                return $false
            }
            $out.Write($buf, 0, $read)
            $downloaded += $read
            if ($total -gt 0) {
                $pct = [int]($downloaded * 100 / $total)
                if ($pct -ge ($script:_lastPct + 2) -or $pct -le 0) {
                    $script:_lastPct = $pct
                    $msg = "$pct% ($([math]::Round($downloaded/1MB,1)) / $([math]::Round($total/1MB,1)) MB)"
                    Write-SetupProgress @{ running=$true; step=$stepIndex; stepCount=$stepTotal; stepName='下载 node'; percent=$pct; message=$msg; mode='bar' }
                }
            }
        }
        return $true
    } catch {
        Write-CtrlLog "下载失败: $($_.Exception.Message)"
        return $false
    } finally {
        try { if ($in) { $in.Dispose() } } catch { }
        try { if ($out) { $out.Dispose() } } catch { }
        try { if ($resp) { $resp.Dispose() } } catch { }
    }
}

# npm-install: 用便携 node 的 npm 安装包到 Prefix
function Install-NpmPackage {
    param($step, [int]$index, [int]$total)
    $setup = $script:Config.Setup
    $nodeExe = Get-NodeExecutable
    $nodeDir = Split-Path $nodeExe -Parent
    $npmCmd = Join-Path $nodeDir 'npm.cmd'
    if (-not (Test-Path $npmCmd)) {
        Write-CtrlLog "npm 不存在: $npmCmd"
        return $false
    }
    $prefix = $step.Install.Prefix
    if (-not (Test-Path $prefix)) { New-Item -ItemType Directory -Path $prefix -Force | Out-Null }
    $pkg = $step.Install.Package
    Write-SetupProgress @{ running=$true; step=$index; stepCount=$total; stepName=$step.Name; percent=0; message="npm install $pkg (可能需要几分钟)..."; mode='marquee' }

    $log = Join-Path $script:Config.Paths.LogDir 'setup.log'
    try {
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo.FileName = $npmCmd
        $p.StartInfo.Arguments = "install $pkg --prefix `"$prefix`" --registry $($setup.NpmRegistry) --no-audit --no-fund"
        $p.StartInfo.WorkingDirectory = $prefix
        $p.StartInfo.UseShellExecute = $false
        $p.StartInfo.CreateNoWindow = $true
        $p.StartInfo.RedirectStandardOutput = $true
        $p.StartInfo.RedirectStandardError = $true
        [void]$p.Start()
        # 安装超时：受限环境不卡死，超时终止进程并报错
        $npmTimeoutMs = 600000
        if ($script:Config.Setup.InstallTimeoutSec) { $npmTimeoutMs = $script:Config.Setup.InstallTimeoutSec * 1000 }
        if (-not $p.WaitForExit($npmTimeoutMs)) {
            try { $p.Kill() } catch { }
            Write-CtrlLog "npm install 超时(>$($npmTimeoutMs / 1000) s)，已终止"
            return $false
        }
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        Add-Content -Path $log -Value "--- npm install $pkg ---" -Encoding UTF8
        if ($out) { Add-Content -Path $log -Value $out -Encoding UTF8 }
        if ($err) { Add-Content -Path $log -Value $err -Encoding UTF8 }
        if ($p.ExitCode -ne 0) {
            Write-CtrlLog "npm install 失败(退出码 $($p.ExitCode))，详见 setup.log"
            return $false
        }
    } catch {
        Write-CtrlLog "npm install 异常: $($_.Exception.Message)"
        return $false
    }
    $pkgName = ($pkg -split '@')[0]
    return (Test-Path (Join-Path $prefix "node_modules\$pkgName"))
}

# shell: 执行自定义命令（初始化目录/写配置）
function Invoke-ShellStep {
    param($step, [int]$index, [int]$total)
    $script = $step.Install.Script
    if ([string]::IsNullOrWhiteSpace($script)) { return $true }
    Write-SetupProgress @{ running=$true; step=$index; stepCount=$total; stepName=$step.Name; percent=0; message="初始化 $($step.Name) ..."; mode='marquee' }
    try {
        & ([scriptblock]::Create($script))
        Write-CtrlLog "步骤完成: $($step.Name)"
        return $true
    } catch {
        Write-CtrlLog "步骤失败: $($step.Name) - $($_.Exception.Message)"
        return $false
    }
}
