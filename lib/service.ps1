# ============================================================
#  lib/service.ps1 - 后台进程控制（无 UI，可被 CLI / GUI / 自动化复用）
#  依赖 $script:Config（lib/config.ps1）与日志函数（lib/logging.ps1）。
#  约定：所有函数返回结构化结果 hashtable，由调用方决定如何呈现。
# ============================================================

# ---------- 端口探测 ----------
# ConnectAsync + 限时等待：避免在半开/防火墙拦截下 Connect 挂起拖死 UI
function Test-PortOpen([int]$port, [int]$timeoutMs = 500) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $c.ConnectAsync("127.0.0.1", $port)
        if (-not $task.Wait($timeoutMs)) { return $false }  # 超时视为未监听
        return $c.Connected
    } catch {
        return $false
    } finally {
        try { $c.Close(); $c.Dispose() } catch { }
    }
}

# 查找监听指定端口的进程 PID（未监听返回 0）。
# 用于端口被占用时区分"目标服务自身"与"其他程序"，避免误报。
function Get-PortOwnerProcess([int]$port) {
    try {
        $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop | Select-Object -First 1
        if ($conn -and $conn.OwningProcess -gt 0) { return [int]$conn.OwningProcess }
    } catch { }
    # 回退：netstat 解析（无 NetTCPIP 模块的旧系统）
    try {
        $line = netstat -ano | Select-String ":$port\s+.*LISTENING" | Select-Object -First 1
        if ($line) {
            $parts = ($line.ToString().Trim() -split '\s+')
            $last = $parts[$parts.Count - 1]
            if ($last -match '^\d+$') { return [int]$last }
        }
    } catch { }
    return 0
}

# ---------- 状态文件工具 ----------
# 读取 PID 文件并判断进程是否存活（须为配置的进程名，防 PID 被系统复用误判）
function Get-ManagedProcessId {
    $pidFile = $script:Config.Paths.PidFile
    if (Test-Path $pidFile) {
        $raw = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($raw -match "^\d+$") {
            $pidVal = [int]$raw
            $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -eq $script:Config.Service.ProcessName) { return $pidVal }
        }
        # 文件里的 PID 无效 / 进程名不符 / 进程已死 —— 自愈清理，防止残留状态文件误导
        Clear-StateFiles
    }
    return 0
}

# 清空 PID 文件（用覆盖而非 Remove-Item，避免部分环境安全策略拦截删除）
function Clear-PidFile {
    try { Set-Content -Path $script:Config.Paths.PidFile -Value "" -Encoding ASCII } catch { }
}

# 清空全部状态文件（PID + 启动时间戳）
function Clear-StateFiles {
    Clear-PidFile
    if (Test-Path $script:Config.Paths.StampFile) {
        try { Set-Content -Path $script:Config.Paths.StampFile -Value "" -Encoding ASCII } catch { }
    }
}

function Get-StartedAt {
    $stampFile = $script:Config.Paths.StampFile
    if (Test-Path $stampFile) {
        try { return [datetime]::Parse((Get-Content $stampFile -Raw).Trim()) } catch { }
    }
    return $null
}

function Get-LogTail {
    $log = $script:Config.Paths.StdoutLog
    if (Test-Path $log) {
        return (Get-Content $log -Tail 15 -ErrorAction SilentlyContinue) -join "`n"
    }
    return ""
}

# ---------- 前端缓存清理（EPERM 韧性）----------
# n8n 启动时会把前端资源解压到 {N8N_USER_FOLDER}\.cache\n8n\public，
# 若目标文件被占用/杀软锁定会报 EPERM 直接退出。启动前清掉，解压到空目录避免覆盖。
function Clear-FrontendCache {
    $userFolder = $script:Config.Service.Env['N8N_USER_FOLDER']
    if ([string]::IsNullOrWhiteSpace($userFolder)) {
        # 未显式配置 N8N_USER_FOLDER 时，n8n 数据默认在 %USERPROFILE%\.n8n（家用机场景）
        $userFolder = Join-Path $env:USERPROFILE '.n8n'
    }
    $cachePublic = Join-Path $userFolder '.cache\n8n\public'
    if (-not (Test-Path $cachePublic)) { return }

    for ($i = 0; $i -lt 3; $i++) {
        try {
            Remove-Item $cachePublic -Recurse -Force -ErrorAction Stop
            Write-CtrlLog "已清理前端缓存(规避 EPERM): $cachePublic"
            return
        } catch {
            if ($i -lt 2) { Start-Sleep -Milliseconds 500 }
        }
    }
    # 清不掉（仍被占用）不阻断启动，靠稳定性复检兜底
    Write-CtrlLog "警告: 前端缓存清理失败(可能被占用)，继续启动: $cachePublic"
}

# ---------- 健康检查 ----------
# 传入 $procId 时，若进程已死立即返回 $false（避免"启动即退"白等满超时）
# $readyUrl 可选：后端(healthz)就绪后再等前端资源就绪。n8n 2.35 每次启动会把前端
# 资源重新生成到 ~\.cache\n8n（约 30-60 秒），期间访问 / 返回 404 "Cannot GET /"，
# 等它 200 再返回，避免健康检查通过后打开浏览器撞上 404 窗口。
function Wait-ManagedHealthy([string]$url, [int]$port, [int]$timeoutSec, [int]$procId = 0, [string]$readyUrl = '') {
    # 阶段1: 后端就绪（原逻辑，超时按启动失败处理）
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $backendOk = $false
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        Start-Sleep -Milliseconds 500
        if ($procId -gt 0 -and -not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
            return $false   # 进程已死：立即判定失败
        }
        if (Test-PortOpen $port) {
            try {
                $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
                if ($r.StatusCode -eq 200) { $backendOk = $true; break }
            } catch {
                # 端口开但请求失败，继续等
            }
        }
    }
    if (-not $backendOk) { return $false }

    # 阶段2: 前端就绪（可选）。120 秒仍未 200 视为异常（资源缺失/极慢环境），
    # 按失败处理并记日志；进程仍保留，可稍后手动访问确认。
    if ([string]::IsNullOrWhiteSpace($readyUrl)) { return $true }
    $fsw = [System.Diagnostics.Stopwatch]::StartNew()
    $frontTimeout = 120
    while ($fsw.Elapsed.TotalSeconds -lt $frontTimeout) {
        Start-Sleep -Milliseconds 500
        if ($procId -gt 0 -and -not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
            return $false
        }
        try {
            $r2 = Invoke-WebRequest -Uri $readyUrl -UseBasicParsing -TimeoutSec 2
            if ($r2.StatusCode -eq 200) { return $true }
        } catch {
            # 前端未就绪（缓存重建中），继续等
        }
    }
    Write-CtrlLog "警告: 前端资源 ${frontTimeout}s 内未就绪(访问 $readyUrl 仍非200)，按启动失败处理。进程仍在，可稍后手动访问确认。"
    return $false
}

# ---------- 启动 ----------
# 返回: @{ Ok; Message; PID; LogTail }
function Start-ManagedService {
    $srv = $script:Config.Service

    # 已在运行
    $existing = Get-ManagedProcessId
    if ($existing -gt 0) {
        return @{ Ok = $false; Message = "$($srv.Name) 已在运行 (PID $existing)。如想重启请先停止。"; PID = 0; OpenEditor = $true }
    }

    # 端口被占用：先识别占用者。若是目标服务自身（如上次控制台退出后残留的 n8n
    # 实例，PID 文件可能已被清空导致状态脱节），不误报"被其他程序占用"，
    # 而是接管状态管理并提示用户先停止
    if (Test-PortOpen $srv.Port) {
        $ownerPid = Get-PortOwnerProcess $srv.Port
        $ownerProc = if ($ownerPid -gt 0) { Get-Process -Id $ownerPid -ErrorAction SilentlyContinue } else { $null }
        if ($ownerProc -and $ownerProc.ProcessName -eq $srv.ProcessName) {
            # 占用端口的进程名匹配目标服务（如 node）——大概率就是残留的 n8n 实例。
            # 把真实 PID 写回状态文件，让控制台接管（状态卡显示运行中，可正常停止）
            try { $ownerPid | Out-File $script:Config.Paths.PidFile -Encoding ASCII } catch { }
            Write-CtrlLog "检测到 $($srv.Name) 已在运行(PID $ownerPid)，已接管状态管理"
            return @{ Ok = $false; Message = "检测到 $($srv.Name) 已在运行 (PID $ownerPid)`n（可能由上次的控制台实例启动后仍在后台运行）。`n如需重启请先点「停止」再启动。"; PID = $ownerPid; OpenEditor = $true }
        }
        $msg = "端口 $($srv.Port) 已被其他程序占用，无法启动 $($srv.Name)。`n请先关闭占用该端口的程序。"
        Write-FatalLog "启动失败: $msg"
        return @{ Ok = $false; Message = $msg; PID = 0 }
    }

    # 定位可执行文件：Get-NodeExecutable 内部已做「便携 node → 配置绝对路径 → PATH 兜底」逐级回退，
    # 配置的绝对路径失效（换机器/目录被清理）也不会卡死，会回退到 PATH 中的 node
    $exePath = Get-NodeExecutable
    if (-not $exePath -or -not (Test-Path $exePath)) {
        $msg = "未找到可执行的 node。请确认 Service.Executable 路径正确，或 PATH 中有 node(>=22.22)。"
        Write-FatalLog "启动失败: $msg"
        return @{ Ok = $false; Message = $msg; PID = 0 }
    }

    # 预检: 确认可执行文件能正常启动（抓损坏/无法运行的场景，快速给明确报错，
    #       而不是等健康检查超时才发现进程已退）
    try {
        $verOut = (& $exePath --version 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            $msg = "可执行文件 $($srv.Executable) 校验失败(退出码 $LASTEXITCODE): $verOut`n请确认版本满足要求(如 n8n 需 node >=22.22)。"
            Write-FatalLog "启动失败: $msg"
            return @{ Ok = $false; Message = $msg; PID = 0 }
        }
    } catch {
        $msg = "可执行文件 $($srv.Executable) 无法运行: $($_.Exception.Message)"
        Write-FatalLog "启动失败: $msg"
        return @{ Ok = $false; Message = $msg; PID = 0 }
    }

    # 启动前清前端缓存，规避 EPERM（失败仅警告，不阻断）
    if ($srv.CleanCacheOnStart) { Clear-FrontendCache }

    # 清理可能的残留状态
    Clear-PidFile

    try {
        # 注入环境变量（子进程继承当前会话环境）
        foreach ($k in $srv.Env.Keys) {
            Set-Item -Path "env:$k" -Value $srv.Env[$k]
        }
        # 组装参数前：入口脚本(Arguments[0])若失效或未配置，自动探测替换。
        # 换机器/换安装方式后（自包含/本地/全局）n8n bin 路径会迁移，探测到即替换并写日志。
        $cmdArgs = @($srv.Arguments)
        $needDetect = $false
        if ($cmdArgs.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($cmdArgs[0])) {
            $entry = $cmdArgs[0]
            $entryOk = ([IO.Path]::IsPathRooted($entry) -and (Test-Path $entry)) -or
                       [bool](Get-Command $entry -ErrorAction SilentlyContinue)
            if (-not $entryOk) { $needDetect = $true }
        } elseif ($cmdArgs.Count -eq 0) {
            # 未配置入口（通用壳子默认）：探测 n8n 真实入口
            $needDetect = $true
        }
        if ($needDetect) {
            $detected = Get-N8nEntrypoint
            if ($detected) {
                Write-CtrlLog "自动探测服务入口: $detected"
                # 保留原尾随参数（如 'start'）；无尾随参数时按 n8n 语义补默认子命令
                $tail = @($cmdArgs | Select-Object -Skip 1)
                if ($tail.Count -eq 0) { $tail = @('start') }
                $cmdArgs = @($detected) + $tail
            }
        }
        # 参数拼装（逐个加引号，兼容含空格路径）
        $argString = (($cmdArgs | ForEach-Object { '"' + $_ + '"' }) -join ' ')

        # 用 [System.Diagnostics.Process] 而非 Start-Process，以便传递 CREATE_NO_WINDOW
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo.FileName = $exePath
        $proc.StartInfo.Arguments = $argString
        $proc.StartInfo.WorkingDirectory = $srv.WorkingDir
        $proc.StartInfo.UseShellExecute = $false   # 必须为 false 才能用 CreateNoWindow
        $proc.StartInfo.CreateNoWindow = $true     # CREATE_NO_WINDOW 标志
        $proc.StartInfo.WindowStyle = 'Hidden'
        $proc.Start() | Out-Null

        # 立即写 PID（防止启动期间进程快速退出导致判断错误）
        $proc.Id | Out-File $script:Config.Paths.PidFile -Encoding ASCII
        Write-CtrlLog "启动中: $($proc.ProcessName) PID $($proc.Id), $($srv.Name)"

        # 健康自检（传入进程 ID：进程若启动即退，立即失败不用等满超时）
        # 后端就绪后再等前端资源就绪（避免打开浏览器撞上 n8n 前端缓存重建的 404 窗口）
        $ok = Wait-ManagedHealthy $srv.HealthUrl $srv.Port $srv.HealthTimeoutSec $proc.Id $srv.EditorUrl
        if ($ok) {
            # 稳定性复检：等一小段窗口再确认进程仍存活且端口仍在监听，
            # 抓"端口已开但随后崩溃"(如前端资源 EPERM 锁) 的延迟崩溃
            Start-Sleep -Seconds $srv.StabilityCheckSec
            $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
            if (-not $alive) {
                $tail = Get-LogTail
                $msg = "$($srv.Name) 启动后进程退出(可能前端资源被锁 EPERM)。`n`n最近日志:`n$tail`n`n详见: $($script:Config.Paths.StdoutLog)"
                Write-FatalLog "启动失败: 稳定性复检发现进程退出, PID $($proc.Id)"
                Clear-StateFiles
                return @{ Ok = $false; Message = $msg; PID = $proc.Id; LogTail = $tail }
            }
            # 记录启动时间戳（用于显示运行时长）
            (Get-Date).ToString("o") | Out-File $script:Config.Paths.StampFile -Encoding ASCII
            Write-CtrlLog "启动成功 (PID $($proc.Id)), 健康检查+稳定性复检通过"
            return @{ Ok = $true; Message = "$($srv.Name) 已启动 (PID $($proc.Id))"; PID = $proc.Id }
        } else {
            # 区分"秒退"(进程已死) 与 "启动超时"
            $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
            $tail = Get-LogTail
            if (-not $alive) {
                $msg = "$($srv.Name) 启动失败: 进程已退出。`n`n最近日志:`n$tail`n`n详见: $($script:Config.Paths.StdoutLog)"
                Clear-StateFiles   # 进程已死：清状态文件
            } else {
                $msg = "$($srv.Name) 启动超时($($srv.HealthTimeoutSec)秒内健康检查未通过), 进程仍在运行。`n`n最近日志:`n$tail"
                # 进程仍存活：保留 PID 文件（启动时已写入），避免状态脱节——
                # 否则下次启动会因 PID 文件为空而误判"端口被其他程序占用"
            }
            Write-FatalLog "启动失败: 健康检查未通过, PID $($proc.Id), 进程存活=$([bool]$alive)"
            return @{ Ok = $false; Message = $msg; PID = $proc.Id; LogTail = $tail }
        }
    } catch {
        $err = $_.Exception.Message
        Write-FatalLog "启动异常: $err"
        Clear-StateFiles
        return @{ Ok = $false; Message = "启动 $($srv.Name) 时发生异常: $err"; PID = 0 }
    }
}

# ---------- 停止 ----------
# 返回: @{ Ok; Already; Message; PID }
function Stop-ManagedService {
    $pidVal = Get-ManagedProcessId
    if ($pidVal -le 0) {
        return @{ Ok = $true; Already = $true; Message = "$($script:Config.Service.Name) 未在运行。"; PID = 0 }
    }

    Write-CtrlLog "正在停止 (PID $pidVal)..."
    $killed = $false
    try {
        # 优先 taskkill 连子进程一起清（runner/broker）
        & taskkill /PID $pidVal /T /F 2>$null | Out-Null
        $killed = $true
    } catch {
        # taskkill 不可用时回退到 Stop-Process
        try { Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue; $killed = $true } catch { }
    }

    # 等待端口释放
    $waited = 0
    while ((Test-PortOpen $script:Config.Service.Port) -and ($waited -lt 10)) {
        Start-Sleep -Seconds 1
        $waited++
    }

    Clear-StateFiles

    if (Test-PortOpen $script:Config.Service.Port) {
        $msg = "$($script:Config.Service.Name) 已停止，但端口 $($script:Config.Service.Port) 仍被占用，可能有残留进程，请手动检查。"
        Write-FatalLog "停止后端口仍占用: $msg"
        return @{ Ok = $false; Message = $msg; PID = $pidVal }
    } else {
        Write-CtrlLog "停止成功 (PID $pidVal, 耗时 $waited 秒)"
        return @{ Ok = $true; Message = "$($script:Config.Service.Name) 已停止。"; PID = $pidVal }
    }
}

# ---------- 状态 ----------
# 返回: @{ Running; PID; Port; StartedAt }
# 注意: 进程未运行时跳过端口探测（本机 127.0.0.1 connect 有延迟，
#       每秒 UI 刷新若每次都查端口会卡顿）；仅在进程运行时才探测。
function Get-ManagedStatus {
    $pidVal = Get-ManagedProcessId
    $port = $false
    if ($pidVal -gt 0) { $port = Test-PortOpen $script:Config.Service.Port }
    return @{
        Running   = $pidVal -gt 0
        PID       = $pidVal
        Port      = $port
        StartedAt = (Get-StartedAt)
    }
}
