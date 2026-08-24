# ============================================================
#  lib/gui.ps1 - WinForms 控制面板（状态卡片 / hover 按钮 / 绿灯慢闪）
#  只负责呈现，进程/日志逻辑全部调用 lib/service.ps1。
#  依赖 $script:Config 与 Show-Msg / Show-YesNo（由 n8n.ps1 提供）。
#
#  设计要点：
#  - 启动/停止在后台 runspace 执行，UI 线程不冻结（点启动后界面保持响应）。
#  - 状态圆点用独立慢闪 Timer 做"呼吸"动画。
#  - 关闭窗口 = 直接退出控制台（无托盘常驻）；n8n 若在运行则继续后台运行，
#    重新打开控制台即可管理。
#  - PS5.1 事件 handler 闭包陷阱：事件里用 $this.Tag 或 $script:_xxx，
#    禁止捕获函数局部变量（会解析为 $null）。
# ============================================================

# ---------- UI 编排（按钮/慢闪共用状态）----------
$script:_bgJob = $null          # 后台启动 job（[PowerShell] runspace 实例）
$script:_bgHandle = $null
$script:_bgPollTimer = $null    # 轮询后台 job 完成的 UI Timer
$script:_bgStartTime = $null    # 后台任务开始时间（超时兜底用）
$script:_toastTimer = $null     # 内联提示恢复 Timer（Show-Toast 惰性创建）
$script:_hintText = ""          # 底部提示默认文案（toast 临时覆盖后恢复）
$script:_setupJob = $null       # 后台安装 job（[PowerShell] runspace）
$script:_setupHandle = $null
$script:_setupTimer = $null     # 安装进度轮询 UI Timer
$script:_setupPanel = $null     # 安装进度面板（进度条 + 阶段文本）
$script:_pbSetup = $null
$script:_lblSetup = $null
$script:StateRunning = $false
$script:StatePort = $false
# 注意: StateDotColor 不能在文件顶层初始化（点源时 System.Drawing 尚未 Add-Type，会 TypeNotFound），在 Show-Gui 里初始化

# ---------- 内联提示（toast）----------
# 复用底部提示行临时显示操作结果，约 4s 后恢复默认文案；不弹 MessageBox。
function Show-Toast([string]$msg, [bool]$isError = $false) {
    if (-not $script:_lblHint) { return }
    $prefix = if ($isError) { "⚠ " } else { "✓ " }
    $line = ($msg -split "`n")[0]
    if ($line.Length -gt 46) { $line = $line.Substring(0, 46) + "…" }
    $script:_lblHint.Text = $prefix + $line
    $script:_lblHint.ForeColor = if ($isError) { [System.Drawing.Color]::FromArgb(190, 60, 50) } else { [System.Drawing.Color]::FromArgb(20, 120, 40) }
    if (-not $script:_toastTimer) {
        $script:_toastTimer = New-Object System.Windows.Forms.Timer
        $script:_toastTimer.Interval = 4000
        $script:_toastTimer.Add_Tick({
            $script:_toastTimer.Stop()
            if ($script:_lblHint) {
                $script:_lblHint.Text = $script:_hintText
                $script:_lblHint.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 140)
            }
        })
    }
    $script:_toastTimer.Start()
}

function Invoke-ManagedStart {
    # 正在后台检测/启动/安装，防重复
    if ($script:_envJob -or $script:_bgJob -or $script:_setupJob) { return }

    $s = Get-ManagedStatus
    if ($s.Running) {
        Show-Toast "$($script:Config.Service.Name) 已在运行 (PID $($s.PID))"
        # 已在运行：点「启动」的意图就是访问 web UI，直接打开
        try { Start-Process $script:Config.Service.EditorUrl } catch { }
        return
    }

    # 环境自检放后台 runspace：Test-SetupNeeded 会执行 node --version / npm root -g
    # 等外部命令，若在主线程同步跑会冻结 UI，表现为"点启动明显卡顿"。
    Start-EnvCheck
}

# 后台环境检测（不阻塞 UI；完成后由 Test-EnvCheckDone 在 UI 线程决策）
function Start-EnvCheck {
    if ($script:_envJob) { return }

    # 立即反馈"检测中"（金色呼吸，同安装/启动中）
    $script:StateRunning = $true
    $script:StatePort = $false
    $script:_lblState.Text = "检测中..."
    $script:_lblState.ForeColor = [System.Drawing.Color]::FromArgb(180, 130, 0)
    $script:_lblDetail.Text = "正在检查运行环境..."
    $script:_lblUptime.Text = "运行时长: --"
    if ($script:_dot) { $script:_dot.Invalidate($true) }

    $homeDir = $script:Config.Paths.Home
    $ps = [System.Management.Automation.PowerShell]::Create()
    [void]$ps.AddScript(". '$homeDir\lib\config.ps1'")
    [void]$ps.AddScript("`$script:Config = Get-Config -Root '$homeDir' -ConfigFile '$($script:Config.ConfigFile)'")
    [void]$ps.AddScript(". '$homeDir\lib\logging.ps1'")
    [void]$ps.AddScript(". '$homeDir\lib\setup.ps1'")
    [void]$ps.AddScript("`$m = Test-SetupNeeded; Write-Output (`$m | ForEach-Object { `$_.Name })")
    $script:_envJob = $ps
    $script:_envHandle = $ps.BeginInvoke()

    if (-not $script:_envTimer) {
        $script:_envTimer = New-Object System.Windows.Forms.Timer
        $script:_envTimer.Interval = 300
        $script:_envTimer.Add_Tick({ Test-EnvCheckDone })
    }
    $script:_envTimer.Start()
}

# 后台环境检测完成回调（UI 线程）：环境就绪 → 直接启动；缺失 → 确认后安装
function Test-EnvCheckDone {
    if (-not $script:_envJob) { return }
    if (-not $script:_envHandle -or -not $script:_envHandle.IsCompleted) { return }

    $missing = @()
    try {
        $results = $script:_envJob.EndInvoke($script:_envHandle)
        if ($results) { $missing = @($results | ForEach-Object { [string]$_ }) }
    } catch {
        Write-FatalLog "环境检测异常: $($_.Exception.Message)"
    } finally {
        try { $script:_envJob.Dispose() } catch { }
        $script:_envJob = $null
        $script:_envHandle = $null
        if ($script:_envTimer) { $script:_envTimer.Stop() }
    }

    if ($missing.Count -eq 0) {
        # 环境就绪，直接启动
        Start-BackgroundService
        return
    }
    $names = $missing -join "、"
    if (Show-YesNo "检测到缺少环境: $names`n`n需要自动安装，是否继续？") {
        Start-SetupJob
    } else {
        Refresh-UI
    }
}

# 环境就绪后的正常启动（后台 runspace，UI 不冻结）
function Start-BackgroundService {
    if ($script:_bgJob) { return }

    # 立即反馈"启动中"
    $script:StateRunning = $true
    $script:StatePort = $false
    $script:_lblState.Text = "启动中..."
    $script:_lblState.ForeColor = [System.Drawing.Color]::FromArgb(180, 130, 0)
    $script:_lblDetail.Text = "正在启动，健康检查最多 $($script:Config.Service.HealthTimeoutSec)s..."
    $script:_lblUptime.Text = "运行时长: --"
    if ($script:_dot) { $script:_dot.Invalidate($true) }

    # 独立 runspace 执行 service.ps1 的启动逻辑（注意: 不用 $home 作变量名，只读自动变量）
    $homeDir = $script:Config.Paths.Home
    $ps = [System.Management.Automation.PowerShell]::Create()
    [void]$ps.AddScript(". '$homeDir\lib\config.ps1'")
    [void]$ps.AddScript("`$script:Config = Get-Config -Root '$homeDir' -ConfigFile '$($script:Config.ConfigFile)'")
    [void]$ps.AddScript(". '$homeDir\lib\logging.ps1'")
    [void]$ps.AddScript(". '$homeDir\lib\service.ps1'")
    [void]$ps.AddScript(". '$homeDir\lib\setup.ps1'")   # 提供 Get-NodeExecutable
    [void]$ps.AddScript("`$r = Start-ManagedService; Write-Output `$r")
    $script:_bgJob = $ps
    $script:_bgHandle = $ps.BeginInvoke()
    $script:_bgStartTime = [DateTime]::UtcNow

    # 轮询完成
    if (-not $script:_bgPollTimer) {
        $script:_bgPollTimer = New-Object System.Windows.Forms.Timer
        $script:_bgPollTimer.Interval = 500
        $script:_bgPollTimer.Add_Tick({ Test-BgJobDone })
    }
    $script:_bgPollTimer.Start()
}

# 自动安装环境（后台 runspace；进度写进度文件，GUI 500ms 轮询）
function Start-SetupJob {
    if ($script:_setupJob) { return }

    # 显示安装面板
    if ($script:_setupPanel) { $script:_setupPanel.Visible = $true }
    if ($script:_pbSetup) { $script:_pbSetup.Style = 'Continuous'; $script:_pbSetup.Value = 0 }
    if ($script:_lblSetup) { $script:_lblSetup.Text = "正在检测环境..." }
    $script:_lblState.Text = "安装中..."
    $script:_lblState.ForeColor = [System.Drawing.Color]::FromArgb(180, 130, 0)

    # 清除旧进度
    Remove-Item (Get-SetupProgressFile) -Force -ErrorAction SilentlyContinue

    $homeDir = $script:Config.Paths.Home
    $ps = [System.Management.Automation.PowerShell]::Create()
    [void]$ps.AddScript(". '$homeDir\lib\config.ps1'")
    [void]$ps.AddScript("`$script:Config = Get-Config -Root '$homeDir' -ConfigFile '$($script:Config.ConfigFile)'")
    [void]$ps.AddScript(". '$homeDir\lib\logging.ps1'")
    [void]$ps.AddScript(". '$homeDir\lib\setup.ps1'")
    [void]$ps.AddScript("Invoke-Setup")
    $script:_setupJob = $ps
    $script:_setupHandle = $ps.BeginInvoke()

    if (-not $script:_setupTimer) {
        $script:_setupTimer = New-Object System.Windows.Forms.Timer
        $script:_setupTimer.Interval = 500
        $script:_setupTimer.Add_Tick({ Test-SetupProgress })
    }
    $script:_setupTimer.Start()
}

# 安装进度轮询：读进度文件 → 更新进度条/阶段文本 → 完成/失败收尾
function Test-SetupProgress {
    $pf = Get-SetupProgressFile
    if (-not (Test-Path $pf)) { return }
    $p = $null
    try { $p = Get-Content $pf -Raw | ConvertFrom-Json } catch { return }
    if (-not $p) { return }

    if ($p.running) {
        if ($script:_lblSetup) { $script:_lblSetup.Text = "$($p.stepName) - $($p.message)" }
        if ($p.mode -eq 'marquee') {
            # 只在模式变化时 Set Style：每 500ms 反复 Set 会不断重启 Marquee 动画，
            # 视觉上"进度条没动"（历史实测 bug）
            if ($script:_pbSetup -and $script:_pbSetup.Style -ne [System.Windows.Forms.ProgressBarStyle]::Marquee) {
                $script:_pbSetup.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
            }
        } else {
            if ($script:_pbSetup) {
                if ($script:_pbSetup.Style -ne [System.Windows.Forms.ProgressBarStyle]::Continuous) {
                    $script:_pbSetup.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
                }
                $pct = [int]$p.percent
                if ($script:_pbSetup.Value -ne $pct) { $script:_pbSetup.Value = $pct }
            }
        }
        return
    }

    # 完成或失败
    if ($script:_setupTimer) { $script:_setupTimer.Stop() }
    if ($script:_setupPanel) { $script:_setupPanel.Visible = $false }
    try { if ($script:_setupJob) { $script:_setupJob.Dispose() } } catch { }
    $script:_setupJob = $null
    $script:_setupHandle = $null

    if ($p.done) {
        Show-Toast "环境安装完成，正在启动..."
        Start-BackgroundService
    } else {
        $err = if ($p.error) { $p.error } else { "环境安装失败，详见 logs\setup.log" }
        Show-Toast $err $true
        Refresh-UI
    }
}

function Test-BgJobDone {
    if (-not $script:_bgJob) { return }

    # 注意: 判断后台任务完成必须用 _bgHandle.IsCompleted（IAsyncResult 可靠）；
    #       PowerShell 类没有 HasCompleted 属性（返回 $null，会导致永久黄灯——历史 bug）
    if (-not $script:_bgHandle -or -not $script:_bgHandle.IsCompleted) {
        # 防御: 后台任务异常卡住时，90s 后强制清理，避免界面永久停在"启动中"
        if ($script:_bgStartTime -and (([DateTime]::UtcNow - $script:_bgStartTime).TotalSeconds -gt 90)) {
            try { $script:_bgJob.Dispose() } catch { }
            $script:_bgJob = $null
            $script:_bgHandle = $null
            $script:_bgStartTime = $null
            if ($script:_bgPollTimer) { $script:_bgPollTimer.Stop() }
            Write-FatalLog "后台启动任务超时(>90s)，已强制清理"
            Show-Toast "启动超时，请稍后查看状态" $true
            Refresh-UI
        }
        return
    }

    # job 完成，取结果
    $r = $null
    try {
        $results = $script:_bgJob.EndInvoke($script:_bgHandle)
        if ($results -and $results.Count -gt 0) { $r = $results[0] }
    } catch {
        $msg = $_.Exception
        if ($msg.InnerException) { $msg = $msg.InnerException }
        $r = @{ Ok = $false; Message = "启动异常: $($msg.Message)" }
    } finally {
        try { $script:_bgJob.Dispose() } catch { }
        $script:_bgJob = $null
        $script:_bgHandle = $null
        $script:_bgStartTime = $null
        if ($script:_bgPollTimer) { $script:_bgPollTimer.Stop() }
    }

    if ($r -and ($r.Ok -or $r.OpenEditor)) {
        # 启动成功 / 接管了已在运行的实例：都自动打开 web UI
        try { Start-Process $script:Config.Service.EditorUrl } catch { }
        Show-Toast $r.Message (-not ($r.Ok -or $r.OpenEditor))
    } else {
        $msg = if ($r) { $r.Message } else { "启动失败（无返回）" }
        Show-Toast $msg $true
    }
    Refresh-UI
}

function Invoke-ManagedStop {
    # 启动中/检测中不允许停止
    if ($script:_bgJob) {
        Show-Toast "正在启动中，请稍候..."
        return
    }
    if ($script:_envJob) {
        Show-Toast "正在检测环境，请稍候..."
        return
    }
    $s = Get-ManagedStatus
    if ($s.Running) {
        if (Show-YesNo "确认停止 $($script:Config.Service.Name) (PID $($s.PID)) 吗？") {
            $r = Stop-ManagedService
            Show-Toast $r.Message (-not $r.Ok)
        }
    } else {
        Show-Toast "$($script:Config.Service.Name) 未在运行"
    }
    Refresh-UI
}

function Show-Status {
    $s = Get-ManagedStatus
    if ($s.Running) {
        $port = if ($s.Port) { "已开启" } else { "未监听(可能仍在启动)" }
        Show-Msg "$($script:Config.Service.Name) 运行中`nPID: $($s.PID)`n端口 $($script:Config.Service.Port) : $port`n`n日志: $($script:Config.Paths.StdoutLog)"
    } else {
        Show-Msg "$($script:Config.Service.Name) 未运行。`n`n日志目录: $($script:Config.Paths.LogDir)"
    }
}

# ---------- 状态卡片绘制 ----------
function Paint-Dot {
    param($g, $color, $size = 18)
    if (-not $g) { return }  # 防御: Graphics 为 null 时直接跳过, 避免拖垮整个 Paint 事件
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $brush = New-Object System.Drawing.SolidBrush $color
    $g.FillEllipse($brush, 1, 1, $size - 2, $size - 2)
    $brush.Dispose()
}

function Format-Uptime {
    param($startedAt)
    if (-not $startedAt) { return "--" }
    $span = (Get-Date) - $startedAt
    if ($span.TotalDays -ge 1) { return "{0}天 {1}小时" -f [int]$span.TotalDays, [int]$span.Hours }
    if ($span.TotalHours -ge 1) { return "{0}小时 {1}分" -f [int]$span.TotalHours, [int]$span.Minutes }
    if ($span.TotalMinutes -ge 1) { return "{0}分 {1}秒" -f [int]$span.TotalMinutes, [int]$span.Seconds }
    return "{0}秒" -f [int]$span.TotalSeconds
}

# ---------- 颜色工具 ----------
function Get-LightColor {
    param($c, [int]$amount = 35)
    return [System.Drawing.Color]::FromArgb(
        [Math]::Min(255, $c.R + $amount),
        [Math]::Min(255, $c.G + $amount),
        [Math]::Min(255, $c.B + $amount)
    )
}
function Get-DarkColor {
    param($c, [int]$amount = 35)
    return [System.Drawing.Color]::FromArgb(
        [Math]::Max(0, $c.R - $amount),
        [Math]::Max(0, $c.G - $amount),
        [Math]::Max(0, $c.B - $amount)
    )
}
function Get-LerpColor {
    param($a, $b, [double]$t)
    return [System.Drawing.Color]::FromArgb(
        [int]($a.R + ($b.R - $a.R) * $t),
        [int]($a.G + ($b.G - $a.G) * $t),
        [int]($a.B + ($b.B - $a.B) * $t)
    )
}
function Color-Equals {
    param($a, $b)
    return ($a.R -eq $b.R -and $a.G -eq $b.G -and $a.B -eq $b.B)
}

# ---------- Hover 按钮工厂 ----------
# 关键: 事件 handler 通过 $this.Tag 访问状态（$this 自动绑定 sender），
#       不捕获任何函数局部变量（PS5.1 事件闭包不可靠，会解析为 $null）。
function New-HoverButton {
    param(
        [string]$Text,
        [System.Drawing.Color]$BaseColor,
        [System.Windows.Forms.FlowLayoutPanel]$Parent,
        [int]$Width = 110,
        [int]$Height = 38,
        [System.Drawing.Font]$Font,
        [scriptblock]$OnClick
    )
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Size = New-Object System.Drawing.Size($Width, $Height)
    $btn.Font = if ($Font) { $Font } else { New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold) }
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.BackColor = $BaseColor
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.TabStop = $false

    # 单一状态容器：按钮.Tag 与 timer.Tag 都指向它。
    # 用 Hashtable（不用 PSCustomObject，跨 .NET 边界 setter 不可靠）。
    $state = @{
        Button  = $btn
        Base    = $BaseColor
        Hover   = (Get-LightColor $BaseColor 35)
        Press   = (Get-DarkColor  $BaseColor 35)
        Current = $BaseColor
        Target  = $BaseColor
        Timer   = $null
    }
    $btn.Tag = $state

    # 独立 Timer (每个按钮一个, 避免共享冲突)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 15  # ~60fps
    $timer.Tag = $state   # Component.Tag，让 Tick 也能通过 $this.Tag 拿到状态
    $state.Timer = $timer

    $timer.Add_Tick({
        $st = $this.Tag
        if (Color-Equals $st.Current $st.Target) {
            $st.Timer.Stop()
            return
        }
        $st.Current = Get-LerpColor $st.Current $st.Target 0.22
        $st.Button.BackColor = $st.Current
        if (Color-Equals $st.Current $st.Target) {
            $st.Button.BackColor = $st.Target
            $st.Current = $st.Target
            $st.Timer.Stop()
        }
    })

    $btn.Add_MouseEnter({
        $st = $this.Tag
        $st.Target = $st.Hover
        $st.Timer.Start()
    })
    $btn.Add_MouseLeave({
        $st = $this.Tag
        $st.Target = $st.Base
        $st.Timer.Start()
    })
    $btn.Add_MouseDown({
        $st = $this.Tag
        $st.Timer.Stop()
        $st.Current = $st.Press
        $st.Button.BackColor = $st.Press
    })
    $btn.Add_MouseUp({
        $st = $this.Tag
        $p = $st.Button.PointToClient([System.Windows.Forms.Cursor]::Position)
        if ($p.X -ge 0 -and $p.Y -ge 0 -and $p.X -lt $st.Button.Width -and $p.Y -lt $st.Button.Height) {
            $st.Target = $st.Hover
        } else {
            $st.Target = $st.Base
        }
        $st.Timer.Start()
    })
    if ($OnClick) { $btn.Add_Click($OnClick) }
    if ($Parent) { $Parent.Controls.Add($btn) }

    # 保留 Timer 引用避免 GC (ArrayList, 用 Add 而非 +=)
    if (-not $script:_hoverTimers) { $script:_hoverTimers = New-Object System.Collections.ArrayList }
    [void]$script:_hoverTimers.Add($timer)

    return $btn
}

# 全局 hover Timer 收集器 (用于防止 GC; 双保险初始化)
if (-not $script:_hoverTimers) { $script:_hoverTimers = New-Object System.Collections.ArrayList }

# ---------- 状态圆点慢闪（呼吸动画）----------
# 慢闪 Timer 依赖 System.Windows.Forms，必须在 Show-Gui 的 Add-Type 之后创建，
# 不能在文件顶层创建（点源时 CLI 模式会 TypeNotFound）。见 Show-Gui。

# ---------- UI 刷新（1s Timer 驱动）----------
function Refresh-UI {
    if ($script:_bgJob) {
        # 正在后台启动：保持"启动中"展示，不覆盖
        $script:StateRunning = $true
        $script:StatePort = $false
        return
    }
    if ($script:_envJob) {
        # 正在后台检测环境：显示"检测中"（金色呼吸），不覆盖
        $script:StateRunning = $true
        $script:StatePort = $false
        $script:_lblState.Text = "检测中..."
        $script:_lblState.ForeColor = [System.Drawing.Color]::FromArgb(180, 130, 0)
        $script:_lblDetail.Text = "正在检查运行环境..."
        $script:_lblUptime.Text = "运行时长: --"
        if ($script:_dot) { $script:_dot.Invalidate($true) }
        return
    }
    if ($script:_setupJob) {
        # 正在后台安装环境：状态卡显示"安装中"（黄灯，同启动中）
        $script:StateRunning = $true
        $script:StatePort = $false
        $script:_lblState.Text = "安装中..."
        $script:_lblState.ForeColor = [System.Drawing.Color]::FromArgb(180, 130, 0)
        $script:_lblDetail.Text = "正在自动安装所需环境..."
        $script:_lblUptime.Text = "运行时长: --"
        if ($script:_dot) { $script:_dot.Invalidate($true) }
        return
    }
    $sd = Get-ManagedStatus
    # 供 Paint / 慢闪读取
    $script:StateRunning = $sd.Running
    $script:StatePort = $sd.Port
    $port = $script:Config.Service.Port
    if ($sd.Running -and $sd.Port) {
        $script:_lblState.Text = "运行中"
        $script:_lblState.ForeColor = [System.Drawing.Color]::FromArgb(20, 120, 40)
        $script:_lblDetail.Text = "PID: $($sd.PID)   端口: $port 已监听"
        $script:_lblUptime.Text = "运行时长: $(Format-Uptime $sd.StartedAt)"
    } elseif ($sd.Running) {
        $script:_lblState.Text = "启动中..."
        $script:_lblState.ForeColor = [System.Drawing.Color]::FromArgb(180, 130, 0)
        $script:_lblDetail.Text = "PID: $($sd.PID)   端口: $port 等待监听"
        $script:_lblUptime.Text = "运行时长: $(Format-Uptime $sd.StartedAt)"
    } else {
        $script:_lblState.Text = "未运行"
        $script:_lblState.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
        $script:_lblDetail.Text = "PID: --   端口: --"
        $script:_lblUptime.Text = "运行时长: --"
    }
    if ($script:_dot) { $script:_dot.Invalidate($true) }
}

# ---------- 主界面 ----------
function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing | Out-Null

    # 单实例锁：防止重复打开控制台（已有实例则提示并退出）
    $script:appMutex = New-Object System.Threading.Mutex($false, 'n8n-console')
    if (-not $script:appMutex.WaitOne(0)) {
        try {
            [System.Windows.Forms.MessageBox]::Show("控制台已有一个实例在运行，请切换到已打开的窗口。", "n8n 控制台") | Out-Null
        } catch { }
        return
    }

    $script:StateDotColor = [System.Drawing.Color]::LightGray

    # 状态圆点慢闪 Timer（运行中绿→暗绿呼吸；启动中金；停止灰），约 4.8s 周期
    $script:dotFlashTimer = New-Object System.Windows.Forms.Timer
    $script:dotFlashTimer.Interval = 200
    $script:dotFlashTimer.Add_Tick({
        if ($script:StateRunning -and $script:StatePort) {
            $phase = ([Environment]::TickCount / 200) % 24
            $t = $phase / 24.0
            if ($t -gt 0.5) { $t = 1 - $t }
            $t = $t * 2
            $r = [int](50 + (20 - 50) * $t)
            $g = [int](205 + (110 - 205) * $t)
            $b = [int](50 + (30 - 50) * $t)
            $script:StateDotColor = [System.Drawing.Color]::FromArgb($r, $g, $b)
        } elseif ($script:StateRunning) {
            # 检测中/安装中/启动中：金色呼吸（金↔深金），比固定金色更醒目
            $phase = ([Environment]::TickCount / 200) % 24
            $t = $phase / 24.0
            if ($t -gt 0.5) { $t = 1 - $t }
            $t = $t * 2
            $r = [int](235 + (180 - 235) * $t)
            $g = [int](185 + (115 - 185) * $t)
            $b = [int](35 + (0 - 35) * $t)
            $script:StateDotColor = [System.Drawing.Color]::FromArgb($r, $g, $b)
        } else {
            $script:StateDotColor = [System.Drawing.Color]::LightGray
        }
        if ($script:_dot) { $script:_dot.Invalidate($true) }
    })
    $script:dotFlashTimer.Start()

    $script:_dot = $null
    $script:_lblState = $null
    $script:_lblDetail = $null
    $script:_lblUptime = $null
    $script:_lblHint = $null
    $script:_form = $null

    # 加载图标：首选 assets\n8n.ico，失败则从同目录 n8n-console.exe 提取兜底
    # （Win11 标题栏不显示窗口图标属系统行为；任务栏/Alt-Tab 图标来自 $form.Icon）
    $iconPath = $script:Config.Paths.Icon
    $formIcon = $null
    if (Test-Path $iconPath) {
        try { $formIcon = New-Object System.Drawing.Icon $iconPath } catch {
            Write-CtrlLog "加载窗口图标失败: $iconPath ($($_.Exception.Message))"
        }
    }
    if (-not $formIcon) {
        # 兜底：从启动器 exe 提取关联图标（拷贝/精简场景 assets 缺失时仍能显示）
        $exePath = Join-Path $script:Config.Paths.Home 'n8n-console.exe'
        if (Test-Path $exePath) {
            try { $formIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath) } catch {
                Write-CtrlLog "从 exe 提取图标失败: $exePath ($($_.Exception.Message))"
            }
        }
    }

    # 表单
    # 用 ClientSize 明确内容区（Size 含边框，内容区会被压缩导致右边截断）；
    # AutoScaleMode=None 避免 DPI 自动缩放拉伸控件导致布局溢出。
    $form = New-Object System.Windows.Forms.Form
    $script:_form = $form
    $form.Text = "$($script:Config.Service.Name) 控制台"
    $form.ClientSize = New-Object System.Drawing.Size(380, 244)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $true
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)
    if ($formIcon) { $form.Icon = $formIcon }

    # 状态卡片 Panel
    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point(12, 12)
    $card.Size = New-Object System.Drawing.Size(352, 100)
    $card.BackColor = [System.Drawing.Color]::White
    $card.BorderStyle = 'FixedSingle'

    # 状态圆点 (Paint 直接读 $script:StateDotColor，由慢闪 Timer 更新)
    $dot = New-Object System.Windows.Forms.Panel
    $dot.Location = New-Object System.Drawing.Point(15, 18)
    $dot.Size = New-Object System.Drawing.Size(20, 20)
    $dot.BackColor = [System.Drawing.Color]::White
    $script:_dot = $dot
    $dot.Add_Paint([System.Windows.Forms.PaintEventHandler]{
        param($sender, $e)
        $g = $e.Graphics
        Paint-Dot $g $script:StateDotColor 20
    })
    $card.Controls.Add($dot)

    # 状态文字（主标题）
    $lblState = New-Object System.Windows.Forms.Label
    $lblState.Location = New-Object System.Drawing.Point(45, 15)
    $lblState.Size = New-Object System.Drawing.Size(300, 30)
    $lblState.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 14, [System.Drawing.FontStyle]::Bold)
    $lblState.Text = "未运行"
    $lblState.ForeColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $script:_lblState = $lblState
    $card.Controls.Add($lblState)

    # 详情
    $lblDetail = New-Object System.Windows.Forms.Label
    $lblDetail.Location = New-Object System.Drawing.Point(45, 48)
    $lblDetail.Size = New-Object System.Drawing.Size(300, 20)
    $lblDetail.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $lblDetail.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $lblDetail.Text = "PID: --   端口: --"
    $script:_lblDetail = $lblDetail
    $card.Controls.Add($lblDetail)

    # 时长
    $lblUptime = New-Object System.Windows.Forms.Label
    $lblUptime.Location = New-Object System.Drawing.Point(45, 70)
    $lblUptime.Size = New-Object System.Drawing.Size(300, 20)
    $lblUptime.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $lblUptime.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
    $lblUptime.Text = "运行时长: --"
    $script:_lblUptime = $lblUptime
    $card.Controls.Add($lblUptime)

    $form.Controls.Add($card)

    # 安装进度面板（默认隐藏；环境缺失时显示：阶段文本 + 细进度条）
    $setupPanel = New-Object System.Windows.Forms.Panel
    $setupPanel.Location = New-Object System.Drawing.Point(12, 116)
    $setupPanel.Size = New-Object System.Drawing.Size(352, 34)
    $setupPanel.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)
    $setupPanel.Visible = $false
    $script:_setupPanel = $setupPanel

    $lblSetup = New-Object System.Windows.Forms.Label
    $lblSetup.Location = New-Object System.Drawing.Point(0, 0)
    $lblSetup.Size = New-Object System.Drawing.Size(352, 16)
    $lblSetup.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
    $lblSetup.ForeColor = [System.Drawing.Color]::FromArgb(180, 130, 0)
    $lblSetup.Text = "正在检测环境..."
    $script:_lblSetup = $lblSetup
    $setupPanel.Controls.Add($lblSetup)

    $pbSetup = New-Object System.Windows.Forms.ProgressBar
    $pbSetup.Location = New-Object System.Drawing.Point(0, 18)
    $pbSetup.Size = New-Object System.Drawing.Size(352, 14)
    $pbSetup.Minimum = 0
    $pbSetup.Maximum = 100
    $pbSetup.Value = 0
    $script:_pbSetup = $pbSetup
    $setupPanel.Controls.Add($pbSetup)

    $form.Controls.Add($setupPanel)

    # 操作按钮区域
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Location = New-Object System.Drawing.Point(12, 152)
    $flow.Size = New-Object System.Drawing.Size(352, 45)
    $flow.FlowDirection = 'LeftToRight'
    $flow.BackColor = [System.Drawing.Color]::Transparent
    $form.Controls.Add($flow)

    $btnStart = New-HoverButton -Text "▶ 启动" `
        -BaseColor ([System.Drawing.Color]::FromArgb(34, 139, 34)) `
        -Parent $flow `
        -OnClick { Invoke-ManagedStart }
    $btnStop = New-HoverButton -Text "■ 停止" `
        -BaseColor ([System.Drawing.Color]::FromArgb(200, 60, 60)) `
        -Parent $flow `
        -OnClick { Invoke-ManagedStop }
    $btnStatus = New-HoverButton -Text "ⓘ 详情" `
        -BaseColor ([System.Drawing.Color]::FromArgb(90, 130, 180)) `
        -Parent $flow `
        -OnClick { Show-Status }

    # 底部提示（同时用作 toast：操作结果临时覆盖此处，4s 后恢复）
    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "关闭窗口即退出控制台; n8n 若在运行会继续后台运行"
    $script:_hintText = $lblHint.Text
    $lblHint.Location = New-Object System.Drawing.Point(12, 212)
    $lblHint.Size = New-Object System.Drawing.Size(352, 16)
    $lblHint.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
    $lblHint.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 140)
    $script:_lblHint = $lblHint   # 供 Show-Toast 复用
    $form.Controls.Add($lblHint)

    # 窗口关闭 → 直接退出（无托盘常驻）。n8n 进程独立，不受影响。
    $form.Add_FormClosing([System.Windows.Forms.FormClosingEventHandler]{
        param($sender, $e)
        # 停止所有 Timer
        foreach ($t in $script:_hoverTimers) { try { $t.Stop() } catch { } }
        try { $script:_refreshTimer.Stop() } catch { }
        try { $script:dotFlashTimer.Stop() } catch { }
        if ($script:_bgPollTimer) { try { $script:_bgPollTimer.Stop() } catch { } }
        if ($script:_toastTimer) { try { $script:_toastTimer.Stop() } catch { } }
        if ($script:_setupTimer) { try { $script:_setupTimer.Stop() } catch { } }
        if ($script:_envTimer) { try { $script:_envTimer.Stop() } catch { } }
        # 后台任务仍在跑则放弃（n8n 进程本身已由独立 runspace 拉起，继续后台运行）
        if ($script:_bgJob) {
            try { $script:_bgJob.Dispose() } catch { }
            $script:_bgJob = $null
        }
        if ($script:_envJob) {
            try { $script:_envJob.Dispose() } catch { }
            $script:_envJob = $null
        }
        if ($script:_setupJob) {
            try { $script:_setupJob.Dispose() } catch { }
            $script:_setupJob = $null
        }
    })

    # 1 秒定时刷新状态
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({ Refresh-UI })
    $timer.Start()
    $script:_refreshTimer = $timer

    # 首次刷新
    Refresh-UI
    $form.ShowDialog() | Out-Null
    $timer.Stop()
    $form.Dispose()
    # 释放单实例锁
    try { $script:appMutex.ReleaseMutex() } catch { }
    try { $script:appMutex.Dispose() } catch { }
}
