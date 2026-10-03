#Requires -Version 5.1
<#
.SYNOPSIS
    Venera 项目可重建构建产物清理器（默认只预览，不删除）。

.DESCRIPTION
    清理 Flutter / HarmonyOS(OHOS) / Android / Windows Desktop 的构建缓存与中间产物。
    所有目标都是被各平台 .gitignore 覆盖、可由构建命令重新生成的目录。

    安全设计：
      1. 白名单硬编码，白名单之外的路径一律拒绝删除；
      2. 任何包含「被 Git 跟踪的文件」的目标会被自动跳过并告警，绝不误删源码；
      3. 发布包（apk/hap/exe/ipa/zip 等 >5MB）先按 SHA256 去重归档到 dist/，
         再清理 build/，避免把成品一起清掉；
      4. 默认 dry-run，必须显式加 -Execute 才真正删除。

.PARAMETER Execute
    真正执行删除。不加此开关时为 dry-run，只打印计划与体积。

.PARAMETER SkipArchive
    跳过发布包归档步骤（默认会归档到 dist/）。

.PARAMETER IncludeBackups
    额外清理根目录下的本地备份/实验目录（.git_backups/、ratelimit_task/）。

.EXAMPLE
    pwsh scripts/clean_artifacts.ps1
    预览将清理的内容。

.EXAMPLE
    pwsh scripts/clean_artifacts.ps1 -Execute
    归档发布包到 dist/ 并清理全部可重建产物。

.EXAMPLE
    pwsh scripts/clean_artifacts.ps1 -Execute -IncludeBackups
    连同本地备份/实验目录一起清理。

.NOTES
    log/ 目录（开发工作记录，被 Git 跟踪）与本脚本无关，永远不会被清理。
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$SkipArchive,
    [switch]$IncludeBackups
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $root 'venera\pubspec.yaml'))) {
    throw "无法定位项目根目录（缺少 venera\pubspec.yaml）：$root"
}

# ---------------------------------------------------------------- 白名单
$artifactPatterns = @(
    'venera/build'
    'venera/.dart_tool/flutter_build'
    'venera/windows/flutter/ephemeral'
    'venera/ohos/entry/build'
    'venera/ohos/entry/.cxx'
    'venera/ohos/entry/src/main/resources/rawfile/flutter_assets'
    'venera/ohos/oh_modules'
    'venera/ohos/.hvigor'
    'venera/ohos/venera/.idea/.deveco/cxx/.cache'
    'venera/android/.gradle'
    'venera/ohos_plugins/*/android/.cxx'
    'venera/ohos_plugins/*/ohos/build'
    'venera/ohos_plugins/*/*/ohos/build'
    'out'
    '.v2c'
)

$backupPatterns = @(
    '.git_backups'
    'ratelimit_task'
)

if ($IncludeBackups) {
    $artifactPatterns = $artifactPatterns + $backupPatterns
}

# ---------------------------------------------------------------- 工具函数
function Get-DirSizeBytes {
    param([string]$Path)
    $m = Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Sum Length
    if ($null -eq $m.Sum) { 0 } else { [int64]$m.Sum }
}

$script:GitOk = [bool](Get-Command git -ErrorAction SilentlyContinue)

function Get-TrackedCount {
    param([string]$RepoRoot, [string]$RelativePath)
    # 返回被跟踪文件数；-1 表示无法判定（git 不可用），调用方据此降级告警。
    if (-not $script:GitOk) { return -1 }
    try {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $out = & git -c "safe.directory=$RepoRoot" -C $RepoRoot ls-files -- $RelativePath 2>$null
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($code -ne 0) { return -1 }
        if ($null -eq $out) { return 0 }
        return @($out).Count
    }
    catch {
        $ErrorActionPreference = 'Stop'
        return -1
    }
}

function Expand-Targets {
    param([string]$RepoRoot, [string[]]$Patterns)
    $found = New-Object System.Collections.ArrayList
    foreach ($p in $Patterns) {
        $full = Join-Path $RepoRoot ($p -replace '/', '\')
        if ($p -match '[\*\?]') {
            # 通配符模式：返回匹配到的目录/文件本身
            foreach ($h in @(Get-ChildItem -Path $full -Force -ErrorAction SilentlyContinue)) {
                [void]$found.Add($h.FullName)
            }
        }
        elseif (Test-Path -LiteralPath $full) {
            # 字面量路径：目标就是它本身，不能展开成它的子项
            [void]$found.Add($full)
        }
    }

    # 去掉被其他目标包含的嵌套目标，避免父目录删掉后再删子目录
    $unique = @($found | Select-Object -Unique)
    $result = New-Object System.Collections.ArrayList
    foreach ($u in $unique) {
        $nested = $false
        foreach ($other in $unique) {
            if ($other -ne $u -and $u.StartsWith($other + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                $nested = $true
                break
            }
        }
        if (-not $nested) { [void]$result.Add($u) }
    }
    $result
}

# ---------------------------------------------------------------- 归档发布包
$distDir = Join-Path $root 'dist'
$archiveExts = @('.hap', '.apk', '.aab', '.ipa', '.exe', '.msi', '.deb', '.dmg', '.zip')
$archiveLog = New-Object System.Collections.ArrayList

if (-not $SkipArchive) {
    $buildDir = Join-Path $root 'venera\build'
    if (Test-Path -LiteralPath $buildDir) {
        if (-not (Test-Path -LiteralPath $distDir)) {
            if ($Execute) { New-Item -ItemType Directory -Path $distDir | Out-Null }
        }

        $known = @{}
        if (Test-Path -LiteralPath $distDir) {
            Get-ChildItem -LiteralPath $distDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                $known[(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash] = $_.Name
            }
        }

        $candidates = Get-ChildItem -LiteralPath $buildDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $archiveExts -contains $_.Extension.ToLower() -and $_.Length -ge 5MB } |
            Sort-Object Length -Descending

        foreach ($f in $candidates) {
            $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            if ($known.ContainsKey($hash)) {
                [void]$archiveLog.Add([pscustomobject]@{
                    MB     = [math]::Round($f.Length / 1MB, 1)
                    Action = '跳过(已有同样内容)'
                    Name   = "$($f.Name)  <= $($known[$hash])"
                })
                continue
            }
            [void]$archiveLog.Add([pscustomobject]@{
                MB     = [math]::Round($f.Length / 1MB, 1)
                Action = '归档'
                Name   = $f.Name
            })
            if ($Execute) {
                Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $distDir $f.Name) -Force
                $known[$hash] = $f.Name
            }
        }
    }
}

# ---------------------------------------------------------------- 计算清理目标
$targets = Expand-Targets -RepoRoot $root -Patterns $artifactPatterns
$plan = New-Object System.Collections.ArrayList
$skipped = New-Object System.Collections.ArrayList
$guardActive = $true

foreach ($t in $targets) {
    # 越界保护
    if (-not $t.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        [void]$skipped.Add([pscustomobject]@{ Reason = '不在项目根目录内'; Path = $t })
        continue
    }
    $rel = $t.Substring($root.Length).TrimStart('\')
    if ($t -eq $root -or [string]::IsNullOrWhiteSpace($rel)) {
        [void]$skipped.Add([pscustomobject]@{ Reason = '指向项目根目录本身'; Path = $t })
        continue
    }

    $isDir = Test-Path -LiteralPath $t -PathType Container
    if (-not $isDir) {
        [void]$skipped.Add([pscustomobject]@{ Reason = '不存在或非目录'; Path = $rel })
        continue
    }

    # 跟踪文件保护
    $tracked = Get-TrackedCount -RepoRoot $root -RelativePath ($rel -replace '\\', '/')
    if ($tracked -gt 0) {
        [void]$skipped.Add([pscustomobject]@{ Reason = "含 $tracked 个被 Git 跟踪的文件，拒绝删除"; Path = $rel })
        continue
    }
    if ($tracked -lt 0) { $guardActive = $false }

    $bytes = Get-DirSizeBytes -Path $t
    $files = @(Get-ChildItem -LiteralPath $t -Force -Recurse -File -ErrorAction SilentlyContinue).Count
    [void]$plan.Add([pscustomobject]@{
        MB     = [math]::Round($bytes / 1MB, 1)
        Files  = $files
        Path   = $rel
        Full   = $t
    })
}

# ---------------------------------------------------------------- 输出
$mode = if ($Execute) { 'EXECUTE' } else { 'DRY-RUN' }
Write-Host ""
Write-Host "Venera 构建产物清理 [$mode]   root = $root" -ForegroundColor Cyan
Write-Host ("-" * 78)

if ($archiveLog.Count -gt 0) {
    Write-Host "发布包归档 -> dist/" -ForegroundColor Yellow
    $archiveLog | Sort-Object MB -Descending |
        ForEach-Object { "{0,8:N1} MB  {1,-14} {2}" -f $_.MB, $_.Action, $_.Name } |
        Write-Host
}
else {
    Write-Host "发布包归档：无可归档文件（或已用 -SkipArchive 跳过）" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "清理目标：" -ForegroundColor Yellow
if ($plan.Count -eq 0) {
    Write-Host "  （没有需要清理的内容，已经很干净）" -ForegroundColor DarkGray
}
else {
    $plan | Sort-Object MB -Descending |
        ForEach-Object { "{0,8:N1} MB  {1,7} files  {2}" -f $_.MB, $_.Files, $_.Path } |
        Write-Host
}

if ($skipped.Count -gt 0) {
    Write-Host ""
    Write-Host "已跳过：" -ForegroundColor DarkGray
    $skipped | ForEach-Object { "  - {0}  <{1}>" -f $_.Path, $_.Reason } | Write-Host
}

if (-not $guardActive) {
    Write-Host ""
    Write-Host "警告：git 不可用，本次未启用「Git 跟踪文件保护」，执行前请自行确认目标未被跟踪。" -ForegroundColor Red
}

$totalMB = ($plan | Measure-Object -Property MB -Sum).Sum
$totalFiles = ($plan | Measure-Object -Property Files -Sum).Sum
Write-Host ("-" * 78)
Write-Host ("合计：{0:N1} MB / {1} 个文件" -f [double]$totalMB, [int]$totalFiles) -ForegroundColor Cyan

if (-not $Execute) {
    Write-Host ""
    Write-Host "这是 dry-run，未删除任何文件。确认无误后加 -Execute 执行。" -ForegroundColor Green
    return
}

# ---------------------------------------------------------------- 执行删除
$freed = 0
foreach ($item in $plan) {
    try {
        Remove-Item -LiteralPath $item.Full -Recurse -Force -ErrorAction Stop
        $freed += $item.MB
        Write-Host ("  已删除 {0,8:N1} MB  {1}" -f $item.MB, $item.Path) -ForegroundColor Green
    }
    catch {
        Write-Host ("  失败     {0}  <- {1}" -f $item.Path, $_.Exception.Message) -ForegroundColor Red
    }
}
Write-Host ""
Write-Host ("清理完成，释放约 {0:N1} MB" -f $freed) -ForegroundColor Cyan
Write-Host "下次构建前按需执行：flutter pub get / ohpm install（鸿蒙）/ flutter build <target>" -ForegroundColor DarkGray


