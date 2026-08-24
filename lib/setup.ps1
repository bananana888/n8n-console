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
# n8n 启动脚本随安装方式/机器迁移而变化（自包含便携 tools\node-<版本>、
# 本地安装、npm 全局安装、PATH shim 等）。按顺序探测真实入口：
#   ① 便携 node 目录（自包含：Setup 把 n8n 装到 tools\node-<版本>\node_modules）
#   ② 配置 Service.Arguments[0]（绝对路径存在即用）
#   ③ {WorkingDir}\node_modules\n8n\bin\n8n（npm 本地安装）
#   ④ npm root -g 定位全局 node_modules → n8n\bin\n8n（npm 全局安装）
#   ⑤ PATH 中 n8n.cmd shim，解析其内部指向的真实 JS 入口
# 找不到返回空串，由调用方（service.ps1）报错提示配置。
function Get-N8nEntrypoint {
    $srv = $script:Config.Service
    $cands = New-Object System.Collections.ArrayList

    # ① 便携 node 目录（自包含）
    $setup = $script:Config.Setup
    if ($setup.Enabled -and -not [string]::IsNullOrWhiteSpace($setup.NodeVersion)) {
        [void]$cands.Add((Join-Path $setup.ToolsDir "node-$($setup.NodeVersion)\node_modules\n8n\bin\n8n"))
    }
    # ①b 当前文件夹 tools\ 下直接安装的 n8n（系统 node 被采用、便携未下载时的落点）
    if ($setup.Enabled -and -not [string]::IsNullOrWhiteSpace($setup.ToolsDir)) {
        [void]$cands.Add((Join-Path $setup.ToolsDir 'node_modules\n8n\bin\n8n'))
    }
    # ② 配置的入口（绝对路径）
    if ($srv.Arguments.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($srv.Arguments[0])) {
        [void]$cands.Add([string]$srv.Arguments[0])
    }
    # ③ 本地安装（工作目录下 node_modules）
    if (-not [string]::IsNullOrWhiteSpace($srv.WorkingDir)) {
        [void]$cands.Add((Join-Path $srv.WorkingDir 'node_modules\n8n\bin\n8n'))
    }
    # ④ 全局安装（npm root -g）
    $npmRoot = ''
    $npmCmd = Get-Command 'npm' -ErrorAction SilentlyContinue
    if ($npmCmd -and $npmCmd.Source) {
        try { $npmRoot = (& $npmCmd.Source root -g 2>$null | Out-String).Trim() } catch { }
    }
    if (-not $npmRoot) {
        # npm 不在 PATH：用便携 node 目录的 npm.cmd（Setup 自动安装场景）。
        # 不要用 Get-NodeExecutable 返回值推断目录——全失效时它返回字面量 'node'，
        # Split-Path 得空串会抛错（$ErrorActionPreference='Stop' 下终止，
        # 干净机器 PATH 无 node 时正好触发，会卡死自动安装检测）。
        $setup = $script:Config.Setup
        if ($setup.Enabled -and -not [string]::IsNullOrWhiteSpace($setup.NodeVersion)) {
            $nodeDir = Join-Path $setup.ToolsDir "node-$($setup.NodeVersion)"
            $npmPath = Join-Path $nodeDir 'npm.cmd'
            if (Test-Path $npmPath) {
                try { $npmRoot = (& $npmPath root -g 2>$null | Out-String).Trim() } catch { }
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($npmRoot)) {
        [void]$cands.Add((Join-Path $npmRoot 'n8n\bin\n8n'))
    }
    # ⑤ PATH 中 n8n.cmd shim，解析其内部 %~dp0\...\n8n\bin\n8n 真实 JS 入口
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

# 便携 node 是否就绪（自包含判定）。
# 与系统是否已有全局 node 无关：便携版初衷是"自带环境"，检测只认
# tools\node-<版本>\node.exe 是否存在（Install-NodePortable 成功以该文件存在为准）。
# 不调用外部命令（node --version / npm），避免主线程启动检测被进程冷启动拖慢。
function Test-PortableNodeReady {
    $setup = $script:Config.Setup
    if (-not $setup.Enabled -or [string]::IsNullOrWhiteSpace($setup.NodeVersion)) { return $false }
    return (Test-Path (Join-Path $setup.ToolsDir "node-$($setup.NodeVersion)\node.exe"))
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
            # 策略「先系统后便携」：先看系统/PATH 的 node 是否可用且版本满足
            # （Test-NodeAvailable 经 Get-NodeExecutable 探测：便携存在时测便携，
            #  便携缺失时自然回退系统 node），有则视为就绪跳过下载；否则要求便携 node 就绪
            if (Test-NodeAvailable) { return $true }
            return (Test-PortableNodeReady)
        }
        'npm-install' {
            # 已装判定用「入口可探测到」：便携/本地/全局任意一种方式装过都算已就绪。
            # 不要用本机绝对路径检测（自包含/换机器后该路径不存在，会误判触发重装）。
            return [bool](Get-N8nEntrypoint)
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
        Write-SetupProgress @{ running=$true; step=$index; stepCount=$total; stepName=$step.Name; percent=0; message="下载 node-$version-win-x64.zip ..."; mode='bar' }
        if (-not (Download-File $zipUrl $zipFile $index $total)) { return $false }
        Write-SetupProgress @{ running=$true; step=$index; stepCount=$total; stepName=$step.Name; percent=90; message="解压 → $tools\node-$version ..."; mode='marquee' }
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
                    $fname = Split-Path $outFile -Leaf
                    $msg = "$fname  $pct% ($([math]::Round($downloaded/1MB,1)) / $([math]::Round($total/1MB,1)) MB)"
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

# npm-install: 用便携 node 的 npm 安装包（Prefix 留空 = 自包含装到便携 node 目录）
# 输出经 cmd.exe 重定向到文件，主线程轮询读文件实时显示"正在下载的依赖包"。
# ⚠️ PS5.1 两个坑（2026-08-22 分发模拟实测）：
#   ① 不能用 $p.RedirectStandardOutput + BeginOutputReadLine/.NET 事件 handler——
#      异步读线程的 scriptblock 访问 $script: 变量不可靠，Add() 抛异常会
#      native crash（powershell 进程直接退出）；$p.OutputDataReceived += {} 语法也失败。
#   ② 不能调用无参 WaitForExit()——同样 native crash。文件重定向 + HasExited 轮询最稳。
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
    # Prefix 留空时的落点：便携 node 存在 → 自包含装便携 node 目录（免管理员、可整体拷贝）；
    # 便携不存在（系统 node 被采用、未下载便携）→ 装到当前文件夹 tools\ 下，
    # 避免把 n8n 写进系统 node 目录污染系统环境
    $prefix = $step.Install.Prefix
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        if (Test-PortableNodeReady) { $prefix = $nodeDir }
        else { $prefix = $setup.ToolsDir }
    }
    if (-not (Test-Path $prefix)) { New-Item -ItemType Directory -Path $prefix -Force | Out-Null }
    $pkg = $step.Install.Package

    # 预置 package.json + overrides：强制 prebuild-install 7.1.3。
    # prebuild-install 7.1.2 依赖的 napi-build-utils 1.0.1 有 N-API 字符串比较 bug：
    # node 22 的 process.versions.napi='10'（两位数），getBestNapiBuildVersion() 里
    # '3'/'6' <= '10' 按字典序为 false → 返回 undefined → prebuild 下载被跳过 →
    # 干净机无编译工具链时 node-gyp 编译必失败（sqlite3 等原生包，2026-08-22
    # 模拟实测）。7.1.3 改用 napi-build-utils ^2.0.0 已修复，所有原生包正常走
    # 预编译二进制下载，无需编译工具链。package.json 必须无 BOM（JSON.parse 遇
    # BOM 报错）；内容纯 ASCII。
    $pkgJson = Join-Path $prefix 'package.json'
    $pkgObj = $null
    if (Test-Path $pkgJson) { try { $pkgObj = Get-Content $pkgJson -Raw | ConvertFrom-Json } catch { $pkgObj = $null } }
    if (-not $pkgObj) { $pkgObj = [ordered]@{ name = 'n8n-portable'; version = '1.0.0'; private = $true } }
    if (-not $pkgObj.overrides) {
        $pkgObj | Add-Member -NotePropertyName overrides -NotePropertyValue ([ordered]@{ 'prebuild-install' = '7.1.3' }) -Force
    } else {
        $pkgObj.overrides.'prebuild-install' = '7.1.3'
    }
    [System.IO.File]::WriteAllText($pkgJson, ($pkgObj | ConvertTo-Json -Depth 5))

    $runDir = $script:Config.Paths.RunDir
    if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Path $runDir -Force | Out-Null }
    $npmOutFile = Join-Path $runDir "$($script:Config.Instance).npm-out.log"
    Remove-Item $npmOutFile -Force -ErrorAction SilentlyContinue
    $log = Join-Path $script:Config.Paths.LogDir 'setup.log'
    try {
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        # --loglevel=notice：输出精简，便于实时提取当前 fetch 的包
        # /s /c "命令 >文件 2>&1"：外层引号必须（cmd 对 /c 后引号有特殊解析）。
        # stdout/stderr 合并到同一文件——npm 的 http fetch 日志走 stderr，
        # 必须 2>&1 才能实时提取正在下载的包名（2026-08-22 模拟实测 stdout 为空）。
        $inner = "`"$npmCmd`" install $pkg --prefix `"$prefix`" --registry $($setup.NpmRegistry) --no-audit --no-fund --loglevel=notice"
        $p.StartInfo.Arguments = "/s /c `"$inner 1>`"$npmOutFile`" 2>&1`""
        $p.StartInfo.WorkingDirectory = $prefix
        $p.StartInfo.UseShellExecute = $false
        $p.StartInfo.CreateNoWindow = $true
        # 关键：npm 的子进程（oracledb 等 postinstall 脚本直接调 node）继承启动
        # 环境 PATH。干净分发机 PATH 无 node → postinstall 报 "'node' 不是内部或
        # 外部命令" → npm 整体失败（2026-08-22 模拟实测）。注入便携 node 目录。
        $p.StartInfo.EnvironmentVariables['PATH'] = "$nodeDir;" + $env:PATH
        [void]$p.Start()

        # 安装超时：受限环境不卡死，超时终止进程并报错
        $npmTimeoutMs = 600000
        if ($script:Config.Setup.InstallTimeoutSec) { $npmTimeoutMs = $script:Config.Setup.InstallTimeoutSec * 1000 }

        # 轮询 HasExited（属性，不阻塞；不能无参 WaitForExit——会 native crash），
        # 期间读输出文件尾部，把最新下载的 .tgz 包名实时写到进度文件
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastPkg = ''
        while (-not $p.HasExited) {
            if ($sw.Elapsed.TotalMilliseconds -gt $npmTimeoutMs) {
                try { $p.Kill() } catch { }
                Write-CtrlLog "npm install 超时(>$($npmTimeoutMs / 1000) s)，已终止"
                return $false
            }
            if (Test-Path $npmOutFile) {
                foreach ($line in (Get-Content $npmOutFile -Tail 20 -ErrorAction SilentlyContinue)) {
                    if ($line -match 'fetch.*?([\w@.\-]+\.tgz)') { $lastPkg = $matches[1] }
                }
            }
            # 实时统计已用时间，让提示与实际耗时不脱节（n8n 依赖 2000+，下载通常要几分钟）
            $el = $sw.Elapsed
            $timeStr = if ($el.TotalMinutes -ge 1) { "{0} 分 {1} 秒" -f [int]$el.TotalMinutes, $el.Seconds } else { "{0} 秒" -f [int]$el.TotalSeconds }
            $msg = if ($lastPkg) { "正在下载依赖包: $lastPkg（已用时 $timeStr）" } else { "正在安装 $pkg（已用时 $timeStr，通常需 5-10 分钟）..." }
            Write-SetupProgress @{ running=$true; step=$index; stepCount=$total; stepName=$step.Name; percent=50; message=$msg; mode='marquee' }
            Start-Sleep -Milliseconds 500
        }
        # 进程已退出：短等文件 flush，读完整输出写 setup.log 备查
        Start-Sleep -Milliseconds 300
        $out = if (Test-Path $npmOutFile) { Get-Content $npmOutFile -Raw -ErrorAction SilentlyContinue } else { '' }
        Add-Content -Path $log -Value "--- npm install $pkg ---" -Encoding UTF8
        if ($out) { Add-Content -Path $log -Value $out -Encoding UTF8 }
        if ($p.ExitCode -ne 0) {
            Write-CtrlLog "npm install 失败(退出码 $($p.ExitCode))，详见 setup.log"
            return $false
        }
    } catch {
        Write-CtrlLog "npm install 异常: $($_.Exception.Message)"
        return $false
    }
    $pkgName = ($pkg -split '@')[0]
    $pkgDir = Join-Path $prefix "node_modules\$pkgName"
    $installed = Test-Path $pkgDir
    Write-SetupProgress @{ running=$true; step=$index; stepCount=$total; stepName=$step.Name; percent=100; message=$(if ($installed) { "已安装 $pkgName ✓" } else { "未找到 $pkgName（安装可能失败）" }); mode='bar' }
    return $installed
}

# shell: 执行自定义命令（初始化目录/写配置）
function Invoke-ShellStep {
    param($step, [int]$index, [int]$total)
    $script = $step.Install.Script
    if ([string]::IsNullOrWhiteSpace($script)) { return $true }
    $firstLine = (($script -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    $desc = if ($firstLine) { $firstLine.Trim() } else { $step.Name }
    Write-SetupProgress @{ running=$true; step=$index; stepCount=$total; stepName=$step.Name; percent=0; message="执行: $desc ..."; mode='marquee' }
    try {
        & ([scriptblock]::Create($script))
        Write-CtrlLog "步骤完成: $($step.Name)"
        return $true
    } catch {
        Write-CtrlLog "步骤失败: $($step.Name) - $($_.Exception.Message)"
        return $false
    }
}
