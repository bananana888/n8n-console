# ============================================================
#  build.ps1 - 构建 n8n 控制台安装包（setup.exe + setup.msi）
#
#  流程:
#   1) 收集运行文件到 packaging\tools\stage（只打包必要文件）
#   2) 下载/复用打包工具到 packaging\tools（Inno Setup + WiX v3，便携/静默）
#   3) ISCC 编译 installer.iss  -> release\setup.exe
#   4) heat + candle + light    -> release\setup.msi
#
#  用法: powershell -ExecutionPolicy Bypass -File packaging\build.ps1
#  注意: 需要联网下载工具（首次）；输出在 release\
# ============================================================
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path $PSScriptRoot -Parent
$tools = Join-Path $PSScriptRoot 'tools'
$release = Join-Path $Root 'release'
New-Item -ItemType Directory -Path $tools, $release -Force | Out-Null

Write-Host '==> 1/4 收集待打包文件到 tools\stage' -ForegroundColor Cyan
$stage = Join-Path $tools 'stage'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$files = @('n8n.ps1', 'n8n-control.ps1', 'n8n.config.psd1', 'example.config.psd1', 'LICENSE', 'README.md', 'CHANGELOG.md')
foreach ($f in $files) { Copy-Item (Join-Path $Root $f) $stage -Force }
Copy-Item (Join-Path $Root 'lib') $stage -Recurse -Force
Copy-Item (Join-Path $Root 'assets') $stage -Recurse -Force

Write-Host '==> 2/4 准备打包工具（Inno Setup + WiX v3）' -ForegroundColor Cyan
$innoDir = Join-Path $tools 'inno'
$iscc = Join-Path $innoDir 'ISCC.exe'
if (-not (Test-Path $iscc)) {
    $innoSetup = Join-Path $tools 'innosetup.exe'
    if (-not (Test-Path $innoSetup)) {
        Write-Host '  下载 Inno Setup...'
        Invoke-WebRequest 'https://jrsoftware.org/download.php/is.exe' -OutFile $innoSetup
    }
    Write-Host '  静默安装 Inno Setup 到 tools\inno...'
    $p = Start-Process $innoSetup -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=$innoDir" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Inno Setup 安装失败(退出码 $($p.ExitCode))" }
}
$wixDir = Join-Path $tools 'wix'
if (-not (Test-Path (Join-Path $wixDir 'candle.exe'))) {
    $wixZip = Join-Path $tools 'wix311.zip'
    if (-not (Test-Path $wixZip)) {
        Write-Host '  下载 WiX v3.11...'
        Invoke-WebRequest 'https://github.com/wixtoolset/wix3/releases/download/wix3112rtm/wix311-binaries.zip' -OutFile $wixZip
    }
    Expand-Archive $wixZip -DestinationPath $wixDir -Force
}

Write-Host '==> 3/4 编译 setup.exe (Inno)' -ForegroundColor Cyan
Push-Location $PSScriptRoot
try { & $iscc 'installer.iss' } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw "Inno 编译失败(退出码 $LASTEXITCODE)" }

Write-Host '==> 4/4 编译 setup.msi (WiX)' -ForegroundColor Cyan
& (Join-Path $wixDir 'heat.exe') dir $stage -cg MainComponentGroup -gg -scom -sreg -srd -sui -dr INSTALLFOLDER -var var.SourceDir -out (Join-Path $PSScriptRoot 'Components.wxs')
if ($LASTEXITCODE -ne 0) { throw "heat 失败(退出码 $LASTEXITCODE)" }
& (Join-Path $wixDir 'candle.exe') (Join-Path $PSScriptRoot 'installer.wxs') (Join-Path $PSScriptRoot 'Components.wxs') -dSourceDir="$stage"
if ($LASTEXITCODE -ne 0) { throw "candle 失败(退出码 $LASTEXITCODE)" }
& (Join-Path $wixDir 'light.exe') (Join-Path $PSScriptRoot 'installer.wixobj') (Join-Path $PSScriptRoot 'Components.wixobj') -out (Join-Path $release 'setup.msi')
if ($LASTEXITCODE -ne 0) { throw "light 失败(退出码 $LASTEXITCODE)" }

Write-Host ''
Write-Host '打包完成:' -ForegroundColor Green
Get-ChildItem $release -Filter 'setup.*' | ForEach-Object { Write-Host "  $($_.FullName) ($([math]::Round($_.Length / 1MB, 1)) MB)" }
