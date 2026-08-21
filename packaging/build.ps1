# ============================================================
#  build.ps1 - 构建 n8n 控制台安装包（setup.exe + setup.msi）
#
#  只依赖 WiX v3（zip 便携，无需安装任何东西到系统）：
#   1) 收集运行文件到 packaging\tools\stage
#   2) 下载 WiX v3 到 packaging\tools\wix（首次）
#   3) heat + candle + light  -> release\setup.msi（MSI 安装包）
#   4) candle + light(Burn)   -> release\setup.exe（引导安装程序，链装 setup.msi）
#
#  用法: powershell -ExecutionPolicy Bypass -File packaging\build.ps1
#  注意: 首次需联网下载 WiX（~30MB）；输出在 release\
# ============================================================
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path $PSScriptRoot -Parent
$tools = Join-Path $PSScriptRoot 'tools'
$release = Join-Path $Root 'release'
New-Item -ItemType Directory -Path $tools, $release -Force | Out-Null

Write-Host '==> 1/3 收集待打包文件到 tools\stage' -ForegroundColor Cyan
$stage = Join-Path $tools 'stage'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$files = @('n8n.ps1', 'n8n-control.ps1', 'n8n.config.psd1', 'example.config.psd1', 'LICENSE', 'README.md', 'CHANGELOG.md')
foreach ($f in $files) { Copy-Item (Join-Path $Root $f) $stage -Force }
Copy-Item (Join-Path $Root 'lib') $stage -Recurse -Force
Copy-Item (Join-Path $Root 'assets') $stage -Recurse -Force

Write-Host '==> 2/3 准备 WiX v3（便携）' -ForegroundColor Cyan
$wixDir = Join-Path $tools 'wix'
if (-not (Test-Path (Join-Path $wixDir 'candle.exe'))) {
    $wixZip = Join-Path $tools 'wix311.zip'
    if (-not (Test-Path $wixZip)) {
        Write-Host '  下载 WiX v3.11...'
        Invoke-WebRequest 'https://github.com/wixtoolset/wix3/releases/download/wix3112rtm/wix311-binaries.zip' -OutFile $wixZip
    }
    Expand-Archive $wixZip -DestinationPath $wixDir -Force
}
$heat   = Join-Path $wixDir 'heat.exe'
$candle = Join-Path $wixDir 'candle.exe'
$light  = Join-Path $wixDir 'light.exe'

Write-Host '==> 3/3 编译 setup.msi + setup.exe（WiX）' -ForegroundColor Cyan

# 3.1 从 stage 生成文件组件清单（heat；-out 输出到 packaging\）
& $heat dir $stage -cg MainComponentGroup -gg -scom -sreg -srd -sui -dr INSTALLFOLDER -var var.SourceDir -out (Join-Path $PSScriptRoot 'Components.wxs')
if ($LASTEXITCODE -ne 0) { throw "heat 失败(退出码 $LASTEXITCODE)" }

# 3.2 编译 MSI（-out 让 wixobj 输出到 packaging\，与后续 light 对齐；
#      -sice 抑制 per-user 安装的 ICE 建议性检查 ICE38/ICE64/ICE91）
& $candle (Join-Path $PSScriptRoot 'installer.wxs') (Join-Path $PSScriptRoot 'Components.wxs') -dSourceDir="$stage" -out "$PSScriptRoot/"
if ($LASTEXITCODE -ne 0) { throw "candle(msi) 失败(退出码 $LASTEXITCODE)" }
& $light (Join-Path $PSScriptRoot 'installer.wixobj') (Join-Path $PSScriptRoot 'Components.wixobj') -sice:ICE38 -sice:ICE64 -sice:ICE91 -out (Join-Path $release 'setup.msi')
if ($LASTEXITCODE -ne 0) { throw "light(msi) 失败(退出码 $LASTEXITCODE)" }

# 3.3 编译 EXE（Burn 引导程序，链装 setup.msi）
$msiPath = Join-Path $release 'setup.msi'
& $candle (Join-Path $PSScriptRoot 'Bundle.wxs') -dMsiPath="$msiPath" -out "$PSScriptRoot/"
if ($LASTEXITCODE -ne 0) { throw "candle(bundle) 失败(退出码 $LASTEXITCODE)" }
& $light (Join-Path $PSScriptRoot 'Bundle.wixobj') -ext (Join-Path $wixDir 'WixBalExtension.dll') -out (Join-Path $release 'setup.exe')
if ($LASTEXITCODE -ne 0) { throw "light(bundle) 失败(退出码 $LASTEXITCODE)" }

Write-Host ''
Write-Host '打包完成:' -ForegroundColor Green
Get-ChildItem $release -Filter 'setup.*' | ForEach-Object { Write-Host "  $($_.FullName) ($([math]::Round($_.Length / 1MB, 1)) MB)" }
