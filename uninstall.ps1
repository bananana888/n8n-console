# ============================================================
#  uninstall.ps1 - 卸载 n8n 控制台（不依赖安装包，可自选删除程度）
#
#  删除类别:
#    [1] 控制台程序   快捷方式 / HKCU 注册 / MSI 安装副本
#    [2] 运行时缓存   logs / run / release / 构建产物 / WiX 缓存
#    [3] 便携运行时   tools\node-<版本>（便携 node 及其中安装的 n8n）
#    [4] 全局 n8n     npm uninstall -g（D:\npm-global）
#    [5] n8n 数据     ~\.n8n（工作流/凭证，不可恢复）
#
#  双击用法（推荐）:
#    双击「卸载 n8n 控制台.bat」→ 弹出图形卸载窗口，勾选类别后一键执行。
#    也可右键本文件 → "使用 PowerShell 运行"（无参数时同样弹图形窗口）。
#
#  参数模式（供自动化/测试，不弹窗口）:
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

# ============================================================
#  共享函数（CLI 与 GUI 共用）
# ============================================================

# ---------- 停止运行中的 n8n（返回被停止的 PID 数组）----------
function Stop-RunningN8n {
    param([switch]$NoKill)
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
    if (-not $NoKill) {
        foreach ($id in @($killIds)) {
            if (Get-Process -Id $id -ErrorAction SilentlyContinue) {
                & taskkill /PID $id /T /F 2>$null | Out-Null
            }
        }
    }
    return ,@($killIds)
}

# ---------- 按类别收集删除目标（返回 ArrayList，元素含 Path/Kind）----------
function Get-UninstallTargets {
    param([int[]]$wanted)
    $targets = New-Object System.Collections.ArrayList
    # 类别1: 控制台程序
    if ($wanted -contains 1) {
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'n8n 控制台.lnk'
        if (Test-Path -LiteralPath $lnk) { [void]$targets.Add([pscustomobject]@{ Path = $lnk; Kind = '桌面快捷方式' }) }
        $prog = [Environment]::GetFolderPath('Programs')
        Get-ChildItem $prog -Filter '*n8n*' -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$targets.Add([pscustomobject]@{ Path = $_.FullName; Kind = '开始菜单快捷方式' })
        }
        [void]$targets.Add([pscustomobject]@{ Path = 'HKCU:\Software\n8n-console'; Kind = 'HKCU 注册残留' })
        Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -and $p.DisplayName -match 'n8n') {
                [void]$targets.Add([pscustomobject]@{ Path = $_.PSPath; Kind = 'MSI 卸载注册(' + $p.DisplayName + ')' })
            }
        }
        $msiCopy = Join-Path $env:LOCALAPPDATA 'n8n-console'
        if ($msiCopy -ne $Root -and (Test-Path -LiteralPath $msiCopy)) {
            [void]$targets.Add([pscustomobject]@{ Path = $msiCopy; Kind = 'MSI 安装副本目录' })
        }
    }
    # 类别2: 运行时缓存
    if ($wanted -contains 2) {
        foreach ($rel in @('logs', 'run', 'release')) {
            $p = Join-Path $Root $rel
            if (Test-Path -LiteralPath $p) { [void]$targets.Add([pscustomobject]@{ Path = $p; Kind = '运行时缓存(' + $rel + ')' }) }
        }
        $exe = Join-Path $Root 'n8n-console.exe'
        if (Test-Path -LiteralPath $exe) { [void]$targets.Add([pscustomobject]@{ Path = $exe; Kind = '编译启动器' }) }
        $pkTools = Join-Path $Root 'packaging\tools'
        if (Test-Path -LiteralPath $pkTools) { [void]$targets.Add([pscustomobject]@{ Path = $pkTools; Kind = 'WiX 便携缓存' }) }
        $cmp = Join-Path $Root 'packaging\Components.wxs'
        if (Test-Path -LiteralPath $cmp) { [void]$targets.Add([pscustomobject]@{ Path = $cmp; Kind = 'WiX 生成组件清单' }) }
        # WiX 编译中间产物（packaging 下）与调试符号（release 下）
        Get-ChildItem (Join-Path $Root 'packaging') -Recurse -Include '*.wixobj','*.wixpdb' -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$targets.Add([pscustomobject]@{ Path = $_.FullName; Kind = 'WiX 中间产物' })
        }
        Get-ChildItem (Join-Path $Root 'release') -Filter *.wixpdb -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$targets.Add([pscustomobject]@{ Path = $_.FullName; Kind = 'WiX 调试符号' })
        }
    }
    # 类别3: 便携运行时 node+n8n
    if ($wanted -contains 3) {
        Get-ChildItem (Join-Path $Root 'tools') -Directory -Filter 'node-*' -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$targets.Add([pscustomobject]@{ Path = $_.FullName; Kind = '便携 node 运行时' })
        }
        $nm = Join-Path $Root 'tools\node_modules'
        if (Test-Path -LiteralPath $nm) { [void]$targets.Add([pscustomobject]@{ Path = $nm; Kind = 'tools 下安装的 n8n' }) }
    }
    # 类别5: n8n 数据
    if ($wanted -contains 5) {
        $data = Join-Path $HOME '.n8n'
        if (Test-Path -LiteralPath $data) { [void]$targets.Add([pscustomobject]@{ Path = $data; Kind = 'n8n 用户数据(工作流/凭证)' }) }
    }
    return ,$targets
}

# ---------- 执行删除（返回结果列表，元素含 Kind/Path/Ok/Msg）----------
function Invoke-Uninstall {
    param([int[]]$wanted, [System.Collections.ArrayList]$targets)
    $results = New-Object System.Collections.ArrayList
    foreach ($t in $targets) {
        $ok = $true; $msg = ''
        try {
            Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop
        } catch {
            $ok = $false; $msg = $_.Exception.Message
        }
        [void]$results.Add([pscustomobject]@{ Kind = $t.Kind; Path = $t.Path; Ok = $ok; Msg = $msg })
    }
    if ($wanted -contains 4) {
        $ok = $true; $msg = ''
        try { & npm uninstall -g n8n 2>$null | Out-Null } catch { $ok = $false; $msg = $_.Exception.Message }
        [void]$results.Add([pscustomobject]@{ Kind = '全局 n8n'; Path = 'npm uninstall -g n8n'; Ok = $ok; Msg = $msg })
    }
    return ,$results
}

# ---------- CLI 交互菜单（参数模式下无类别参数时使用；回车 = 默认 1,2）----------
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

# ============================================================
#  GUI 卸载器（无参数时弹出，双击「卸载 n8n 控制台.bat」触发）
# ============================================================
$script:_uniForm = $null
$script:_uniLog = $null
$script:_uniBtnGo = $null
$script:_uniBtnCancel = $null
$script:_uniChecks = @()

# 向结果框追加一行（带颜色）；顺带 DoEvents 保持窗口响应
function Add-UniLog([string]$line, [string]$color = '#333333') {
    if (-not $script:_uniLog) { return }
    $rtb = $script:_uniLog
    $selStart = $rtb.TextLength
    $rtb.AppendText($line + "`r`n")
    $rtb.Select($selStart, $line.Length)
    $rtb.SelectionColor = [System.Drawing.ColorTranslator]::FromHtml($color)
    $rtb.SelectionLength = 0
    $rtb.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Show-UninstallGui {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing | Out-Null
    [void][System.Windows.Forms.Application]::EnableVisualStyles()

    # 表单（ClientSize 明确内容区；AutoScaleMode=None 避免 DPI 缩放拉伸布局）
    $form = New-Object System.Windows.Forms.Form
    $script:_uniForm = $form
    $form.Text = '卸载 n8n 控制台'
    $form.ClientSize = New-Object System.Drawing.Size(470, 522)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)
    $iconPath = Join-Path $Root 'assets\n8n.ico'
    if (Test-Path $iconPath) { try { $form.Icon = New-Object System.Drawing.Icon $iconPath } catch { } }

    # 标题 + 说明
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = '卸载 n8n 控制台'
    $lbl.Location = New-Object System.Drawing.Point(16, 14)
    $lbl.Size = New-Object System.Drawing.Size(430, 30)
    $lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $form.Controls.Add($lbl)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = '勾选要删除的内容，点击「开始卸载」。删除不可恢复，请谨慎选择。'
    $sub.Location = New-Object System.Drawing.Point(18, 48)
    $sub.Size = New-Object System.Drawing.Size(440, 20)
    $sub.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $sub.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
    $form.Controls.Add($sub)

    # 复选框面板（默认勾选 1、2）
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(14, 74)
    $panel.Size = New-Object System.Drawing.Size(440, 176)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.BorderStyle = 'FixedSingle'
    $form.Controls.Add($panel)

    $defs = @(
        @{ Key = 1; Text = '控制台程序（快捷方式 / 注册表 / MSI 副本）' },
        @{ Key = 2; Text = '运行时缓存（logs / run / 安装包 / 构建产物）' },
        @{ Key = 3; Text = '便携 node + n8n（当前文件夹 tools\ 下的运行时）' },
        @{ Key = 4; Text = '全局 n8n（执行 npm uninstall -g n8n）' },
        @{ Key = 5; Text = 'n8n 数据（~\.n8n，工作流 / 凭据，不可恢复）' }
    )
    $y = 12
    foreach ($d in $defs) {
        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Tag = $d.Key
        $chk.Text = ' [' + $d.Key + ']  ' + $d.Text
        $chk.Location = New-Object System.Drawing.Point(10, $y)
        $chk.Size = New-Object System.Drawing.Size(420, 30)
        $chk.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
        $chk.Checked = ($d.Key -le 2)
        if ($d.Key -eq 5) { $chk.ForeColor = [System.Drawing.Color]::FromArgb(190, 60, 50) }
        $panel.Controls.Add($chk)
        $script:_uniChecks += $chk
        $y += 31
    }

    # 按钮区：左 全选/清空，右 开始卸载（红）/取消
    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = '全选'
    $btnAll.Location = New-Object System.Drawing.Point(16, 256)
    $btnAll.Size = New-Object System.Drawing.Size(88, 32)
    $btnAll.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $btnAll.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($btnAll)
    $btnAll.Add_Click({ foreach ($c in $script:_uniChecks) { $c.Checked = $true } })

    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text = '清空'
    $btnNone.Location = New-Object System.Drawing.Point(110, 256)
    $btnNone.Size = New-Object System.Drawing.Size(88, 32)
    $btnNone.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $btnNone.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($btnNone)
    $btnNone.Add_Click({ foreach ($c in $script:_uniChecks) { $c.Checked = $false } })

    $btnGo = New-Object System.Windows.Forms.Button
    $btnGo.Text = '开始卸载'
    $btnGo.Location = New-Object System.Drawing.Point(276, 252)
    $btnGo.Size = New-Object System.Drawing.Size(100, 40)
    $btnGo.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $btnGo.ForeColor = [System.Drawing.Color]::White
    $btnGo.BackColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
    $btnGo.FlatStyle = 'Flat'
    $btnGo.FlatAppearance.BorderSize = 0
    $btnGo.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:_uniBtnGo = $btnGo
    $form.Controls.Add($btnGo)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(382, 256)
    $btnCancel.Size = New-Object System.Drawing.Size(72, 32)
    $btnCancel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $btnCancel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:_uniBtnCancel = $btnCancel
    $form.Controls.Add($btnCancel)
    $btnCancel.Add_Click({ $script:_uniForm.Close() })

    # 结果展示（只读、滚动）
    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Location = New-Object System.Drawing.Point(14, 302)
    $rtb.Size = New-Object System.Drawing.Size(440, 200)
    $rtb.ReadOnly = $true
    $rtb.BackColor = [System.Drawing.Color]::White
    $rtb.BorderStyle = 'FixedSingle'
    $rtb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $rtb.ScrollBars = 'Vertical'
    $script:_uniLog = $rtb
    $form.Controls.Add($rtb)

    # 开始卸载：确认 → 停止 n8n → 收集 → 逐个删除 → 结果展示
    # 注意：事件 handler 一律用 $this / $script: 访问状态，不捕获函数局部变量（PS5.1 闭包陷阱）
    $btnGo.Add_Click({
        $this.Enabled = $false
        if ($script:_uniBtnCancel) { $script:_uniBtnCancel.Enabled = $false }
        try {
            $wanted = @()
            foreach ($c in $script:_uniChecks) { if ($c.Checked) { $wanted += [int]$c.Tag } }
            $wanted = @($wanted | Sort-Object -Unique)
            if ($wanted.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('请至少勾选一项要删除的内容。', '卸载 n8n 控制台') | Out-Null
                return
            }
            # 二次确认（含类别5时特别警示）
            $names = @()
            foreach ($n in $wanted) {
                switch ($n) {
                    1 { $names += '控制台程序' }
                    2 { $names += '运行时缓存' }
                    3 { $names += '便携 node + n8n' }
                    4 { $names += '全局 n8n' }
                    5 { $names += 'n8n 数据' }
                }
            }
            $confirm = "确认卸载以下内容？`n`n· " + ($names -join "`n· ")
            if ($wanted -contains 5) {
                $confirm += "`n`n⚠ 将删除 n8n 用户数据（工作流 / 凭证），此操作不可恢复！"
            }
            $res = [System.Windows.Forms.MessageBox]::Show($confirm, '确认卸载',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($res -ne [System.Windows.Forms.DialogResult]::Yes) { return }

            # 执行
            if ($script:_uniLog) { $script:_uniLog.Clear() }
            Add-UniLog '==> 停止运行中的 n8n' '#8a6d1a'
            $killed = Stop-RunningN8n
            if ($killed.Count -eq 0) { Add-UniLog '  未检测到运行中的 n8n。' '#888888' }
            else { Add-UniLog ('  已停止 {0} 个 n8n 相关进程。' -f $killed.Count) '#1a7a3a' }
            Add-UniLog ''

            Add-UniLog '==> 收集待删除内容' '#8a6d1a'
            $targets = Get-UninstallTargets $wanted
            if ($targets.Count -eq 0 -and -not ($wanted -contains 4)) {
                Add-UniLog '  所选类别没有需要清理的内容。' '#1a7a3a'
            } else {
                Add-UniLog ('  共 {0} 项待删除，正在执行...' -f $targets.Count) '#8a6d1a'
                $results = Invoke-Uninstall $wanted $targets
                foreach ($r in $results) {
                    if ($r.Ok) {
                        Add-UniLog ('  [已删除] {0}  {1}' -f $r.Kind, $r.Path) '#1a7a3a'
                    } else {
                        Add-UniLog ('  [失败]   {0}  {1}' -f $r.Kind, $r.Path) '#b03028'
                        if ($r.Msg) { Add-UniLog ('          原因: {0}' -f $r.Msg) '#b03028' }
                    }
                }
            }
            Add-UniLog ''
            Add-UniLog '========== 卸载完成 ==========' '#333333'
            Add-UniLog '未勾选的内容仍保留。本文件夹（源码 / 脚本）确认不再需要后，' '#888888'
            Add-UniLog '请直接删除整个文件夹即可（含本脚本）。' '#888888'
        } catch {
            Add-UniLog ('发生异常: ' + $_.Exception.Message) '#b03028'
        } finally {
            $this.Enabled = $true
            if ($script:_uniBtnCancel) {
                $script:_uniBtnCancel.Enabled = $true
                $script:_uniBtnCancel.Text = '关闭'
            }
        }
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
    $script:_uniForm = $null
}

# ============================================================
#  入口分派：有参数 → CLI（自动化/测试）；无参数 → GUI（双击弹窗）
# ============================================================
$hasParams = $PSBoundParameters.Count -gt 0

try {
    if ($hasParams) {
        # ---------------- CLI 模式 ----------------
        Write-Host ''
        Write-Host '========== n8n 控制台 卸载 ==========' -ForegroundColor Cyan

        # 停止运行中的 n8n（-WhatIf 时只检测不杀）
        Write-Host '==> 停止运行中的 n8n' -ForegroundColor Cyan
        $killed = Stop-RunningN8n -NoKill:$WhatIfPreference
        if ($killed.Count -eq 0) { Write-Host '  未检测到运行中的 n8n。' }
        else { Write-Host ('  已停止 {0} 个 n8n 相关进程。' -f $killed.Count) }
        if ($WhatIfPreference) { Write-Host '  [WhatIf] 跳过进程停止。' }

        # 确定删除类别
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

        # 收集删除目标
        Write-Host '==> 收集待删除内容' -ForegroundColor Cyan
        $targets = Get-UninstallTargets $wanted

        # 展示清单
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

        # 总结
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
        exit 0
    }

    # ---------------- GUI 模式（无参数，双击 bat 触发）----------------
    Show-UninstallGui
} catch {
    $err = $_.Exception.Message
    Write-Host ''
    Write-Host ("卸载脚本异常: " + $err) -ForegroundColor Red
    if ($hasParams) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    # GUI 模式（隐藏控制台窗口）异常时弹框提示，否则用户看不到任何反馈
    if (-not $hasParams) {
        try {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            [System.Windows.Forms.MessageBox]::Show("卸载脚本发生异常: $err", 'n8n 控制台 卸载') | Out-Null
        } catch { }
    }
    exit 1
}
