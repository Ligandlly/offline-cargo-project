<#
.SYNOPSIS
  在离线机器上导入 cargo vendor 离线依赖（Windows / PowerShell 版）。

.DESCRIPTION
  两种模式：
    -Target <项目目录>   把 vendor 与 .cargo\config.toml 复制到指定项目（推荐）
    -Global              安装到 $CargoHome\vendor\offline-bundle，并写入全局 config.toml

.EXAMPLE
  .\restore-offline.ps1 -Target C:\work\myproject
  .\restore-offline.ps1 -Global
#>
[CmdletBinding()]
param(
  [string]$Target = "",
  [switch]$Global,
  [switch]$NoBuild,
  [switch]$Force,
  [string]$CargoHome = ""
)

$ErrorActionPreference = "Stop"

function Write-Log  { param([string]$Message) Write-Host "[restore] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[restore] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[restore] $Message" -ForegroundColor Yellow }
function Die        { param([string]$Message) Write-Host "[restore][error] $Message" -ForegroundColor Red; exit 1 }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleDir = Split-Path -Parent $ScriptDir
$VendorSrc = Join-Path $BundleDir "vendor"

if (-not (Test-Path $VendorSrc)) {
  Die "未找到 $VendorSrc，请确认在解压后的离线包内运行本脚本"
}

if (-not $CargoHome -or $CargoHome -eq "") {
  if ($env:CARGO_HOME) { $CargoHome = $env:CARGO_HOME } else { $CargoHome = Join-Path $HOME ".cargo" }
}

$GlobalMode = [bool]$Global
if (-not $GlobalMode -and -not $Target) { $GlobalMode = $true }

function Get-ConfigBlock {
  param([string]$VendorDir)
  $dir = $VendorDir -replace '\\', '/'
  return @"
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$dir"

[net]
offline = true
"@
}

function Write-Config {
  param([string]$ConfigFile, [string]$VendorDir)
  $cargoDir = Split-Path -Parent $ConfigFile
  New-Item -ItemType Directory -Force -Path $cargoDir | Out-Null
  $utf8 = New-Object System.Text.UTF8Encoding($false)  # 无 BOM，避免 cargo 解析失败
  if (Test-Path $ConfigFile) {
    $existing = Get-Content -Raw $ConfigFile
    if ($existing -match "vendored-sources") {
      Write-Warn "已存在 vendored-sources 配置，跳过写入: $ConfigFile"
      return
    }
    $block = "`r`n# >>> cargo offline vendor (auto-generated) >>>`r`n" + (Get-ConfigBlock $VendorDir) + "# <<< cargo offline vendor (auto-generated) <<<`r`n"
    [System.IO.File]::AppendAllText($ConfigFile, $block, $utf8)
  } else {
    [System.IO.File]::WriteAllText($ConfigFile, (Get-ConfigBlock $VendorDir), $utf8)
  }
}

if ($GlobalMode) {
  $dest = Join-Path (Join-Path $CargoHome "vendor") "offline-bundle"
  Write-Log "导入模式: 全局"
  Write-Log "CARGO_HOME: $CargoHome"
  if ((Test-Path $dest) -and (-not $Force)) { Die "$dest 已存在，使用 -Force 覆盖" }
  if ($Force -and (Test-Path $dest)) { Remove-Item -Recurse -Force $dest }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
  Write-Log "复制 vendor -> $dest"
  Copy-Item -Recurse -Force $VendorSrc $dest
  Write-Config -ConfigFile (Join-Path $CargoHome "config.toml") -VendorDir $dest
  Write-Ok "全局导入完成，配置写入 $(Join-Path $CargoHome 'config.toml')"
  Write-Warn "全局 source 替换对所有项目生效"
} else {
  if (-not (Test-Path $Target)) { Die "目标目录不存在: $Target" }
  $projectDir = (Resolve-Path $Target).Path
  Write-Log "导入模式: 项目级"
  Write-Log "目标项目: $projectDir"

  $destVendor = Join-Path $projectDir "vendor"
  if ((Test-Path $destVendor) -and (-not $Force)) { Die "$destVendor 已存在，使用 -Force 覆盖" }
  if ($Force -and (Test-Path $destVendor)) { Remove-Item -Recurse -Force $destVendor }

  Write-Log "复制 vendor\ ..."
  Copy-Item -Recurse -Force $VendorSrc $destVendor
  Write-Config -ConfigFile (Join-Path $projectDir ".cargo\config.toml") -VendorDir "vendor"

  $lock = Join-Path $projectDir "Cargo.lock"
  $srcLock = Join-Path $BundleDir "Cargo.lock"
  if ((-not (Test-Path $lock)) -and (Test-Path $srcLock)) {
    Copy-Item $srcLock $lock
    Write-Log "已复制 Cargo.lock"
  }

  Write-Ok "导入完成: $projectDir"

  if (-not $NoBuild) {
    $manifest = Join-Path $projectDir "Cargo.toml"
    if (Test-Path $manifest) {
      Write-Log "离线校验: cargo build --offline"
      Push-Location $projectDir
      try {
        & cargo build --offline
        if ($LASTEXITCODE -ne 0) { Write-Warn "cargo build --offline 失败，请检查项目与依赖是否匹配" }
      } finally {
        Pop-Location
      }
    } else {
      Write-Warn "目标目录没有 Cargo.toml，跳过构建校验"
    }
  }
}
