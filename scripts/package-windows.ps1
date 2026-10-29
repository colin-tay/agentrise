# Copyright (c) 2026 Colin Tay
# SPDX-License-Identifier: MIT
#
# Packages the Windows app as Agentrise-windows-x64-<version>.zip (spec §5.10): Agentrise.exe, agentrise-hook.exe,
# every DLL they import transitively that isn't Windows' own, LICENSE and a README.txt.
#
# The DLL closure comes from `dumpbin /dependents` (imports and delay-load imports), searching, in order: the build
# directory, the Swift runtime directory (the directory on PATH with swiftCore.dll) and the Visual C++ runtime's
# redistributable folder (VC\Redist\MSVC\<version>\x64\Microsoft.VC14x.CRT of the newest Visual Studio with the C++
# tools). A DLL found in none of them is the system's (kernel32, the UCRT's api-ms-win-* sets, ...) and stays out.
# `Agentrise.exe --print-runtime-files` computes the same list with `RuntimeFiles.closure`, which the installed hook
# copies its DLLs with; the release workflow checks that the two agree.
#
# The Visual C++ runtime DLLs (vcruntime140*.dll, msvcp140*.dll) are deployed next to the exe ("application local
# folder"), unmodified, as the Visual Studio 2022 Distributable Code list allows for the files in VC\Redist; see
# README.txt below and the README's Windows section.
#
# Usage (from the repository root, after `swift build -c release`):
#   scripts/package-windows.ps1 -Version 1.0 [-BinDir <dir>] [-OutDir dist]
# Writes <OutDir>\Agentrise\ (the zip's contents), <OutDir>\Agentrise-windows-x64-<version>.zip and
# <OutDir>\runtime-files.txt and search-dirs.txt (the closure's source paths and the directories searched, one per
# line, for the workflow's check; not in the zip).
param(
    [Parameter(Mandatory = $true)] [string] $Version,
    [string] $BinDir,
    [string] $OutDir = 'dist'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$') { throw "unusable version '$Version'" }
if (-not $BinDir) { $BinDir = (swift build -c release --show-bin-path | Out-String).Trim() }
$BinDir = (Resolve-Path -LiteralPath $BinDir).Path
$root = Split-Path -Parent $PSScriptRoot

function Find-VisualStudio {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw "no vswhere.exe at $vswhere" }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath |
        Select-Object -First 1
    if (-not $vs) { throw 'no Visual Studio with the C++ x64 tools' }
    return $vs
}

function Find-Dumpbin([string] $vs) {
    $onPath = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $found = Get-ChildItem -Path (Join-Path $vs 'VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe') -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Parent.Parent.Parent.Name } -Descending | Select-Object -First 1
    if (-not $found) { throw "no dumpbin.exe under $vs" }
    return $found.FullName
}

function Find-SwiftRuntime {
    foreach ($dir in ($env:PATH -split ';')) {
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'swiftCore.dll'))) { return (Resolve-Path -LiteralPath $dir).Path }
    }
    throw 'no swiftCore.dll on PATH (the Swift runtime directory)'
}

# The newest x64 CRT folder of the redistributable files (not debug_nonredist, not onecore).
function Find-VCRuntime([string] $vs) {
    $versions = Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Redist\MSVC') -Directory |
        Where-Object { $_.Name -match '^\d+(\.\d+)+$' } | Sort-Object { [version]$_.Name } -Descending
    foreach ($v in $versions) {
        $crt = Get-ChildItem -Path (Join-Path $v.FullName 'x64\Microsoft.VC14*.CRT') -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($crt) { return $crt.FullName }
    }
    throw "no VC\Redist\MSVC\<version>\x64\Microsoft.VC14*.CRT under $vs"
}

function Get-Imports([string] $dumpbin, [string] $file) {
    $out = & $dumpbin /nologo /dependents $file
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed on $file" }
    # The import and delay-load sections list one DLL name per indented line.
    return @($out | ForEach-Object { if ($_ -match '^\s+(\S+\.dll)\s*$') { $Matches[1] } })
}

$vs = Find-VisualStudio
$dumpbin = Find-Dumpbin $vs
$swiftRuntime = Find-SwiftRuntime
$vcRuntime = Find-VCRuntime $vs
$searchDirs = @($BinDir, $swiftRuntime, $vcRuntime)
Write-Output "dumpbin: $dumpbin"
Write-Output "search: $($searchDirs -join ' | ')"

$exes = @('Agentrise.exe', 'agentrise-hook.exe') | ForEach-Object {
    $p = Join-Path $BinDir $_
    if (-not (Test-Path -LiteralPath $p)) { throw "no $p (build the release products first)" }
    $p
}
$files = [System.Collections.Generic.List[string]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$queue = [System.Collections.Generic.Queue[string]]::new()
foreach ($e in $exes) { $files.Add($e); [void]$seen.Add((Split-Path -Leaf $e)); $queue.Enqueue($e) }
while ($queue.Count -gt 0) {
    $file = $queue.Dequeue()
    foreach ($name in (Get-Imports $dumpbin $file)) {
        if (-not $seen.Add($name)) { continue }
        $found = $searchDirs | ForEach-Object { Join-Path $_ $name } | Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if (-not $found) { continue }   # the system's
        $files.Add($found)
        $queue.Enqueue($found)
    }
}

$OutDir = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $OutDir))
$stage = Join-Path $OutDir 'Agentrise'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
foreach ($f in $files) { Copy-Item -LiteralPath $f -Destination $stage }
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $stage 'LICENSE.txt')
$vcFiles = @($files | Where-Object { $_.StartsWith($vcRuntime, [System.StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Split-Path -Leaf $_ })
$vcVersion = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $vcRuntime))

$readme = @"
Agentrise $Version for Windows (experimental) / Windows 实验版

Agentrise shows your Claude Code and Codex sessions as robots in a small office tower.
https://github.com/colin-tay/agentrise

----------------------------------------------------------------------
中文
----------------------------------------------------------------------
运行：解压到任意目录，双击 Agentrise.exe。它常驻在系统托盘（任务栏右下角）。
首次运行：这个程序没有签名。SmartScreen 提示"Windows 已保护你的电脑"时，点"更多信息"→"仍要运行"。
开了"智能应用控制"（Smart App Control）的电脑会直接拦截未签名程序，没有"仍要运行"按钮；
查看它的状态：设置 → 隐私和安全性 → Windows 安全中心 → 应用和浏览器控制 → 智能应用控制。
接入：托盘图标右键 → 设置… → 安装 Claude Code / Codex 的 hook（先预览、再备份原文件）。
hook 程序会复制到 %LOCALAPPDATA%\Agentrise\bin\，之后移动或删除这个解压目录不影响 hook。
运行库：Visual C++ 运行库（$($vcFiles -join ', ')）已经随包附带，放在 Agentrise.exe 旁边，不需要另装。
如果启动时仍提示缺少 VCRUNTIME140.dll 或 MSVCP140.dll，请安装微软官方的
Visual C++ 2015-2022 x64 可再发行组件包：https://aka.ms/vs/17/release/vc_redist.x64.exe
这是实验版本：只有 x64（Windows 11 ARM 通过系统的 x64 模拟运行）。问题反馈：
https://github.com/colin-tay/agentrise/issues/new?template=windows.yml

----------------------------------------------------------------------
English
----------------------------------------------------------------------
Run: unzip anywhere and double-click Agentrise.exe. It lives in the notification area (system tray).
First run: the program is unsigned. When SmartScreen says "Windows protected your PC", choose
"More info" -> "Run anyway". With Smart App Control on, Windows blocks unsigned programs outright,
with no "Run anyway"; check its state in Settings -> Privacy & security -> Windows Security ->
App & browser control -> Smart App Control.
Hooks: right-click the tray icon -> Settings... -> install the Claude Code / Codex hooks (previewed,
the old file backed up). The hook is copied to %LOCALAPPDATA%\Agentrise\bin\, so moving or deleting
this folder later doesn't break it.
Runtime: the Visual C++ runtime ($($vcFiles -join ', ')) ships next to Agentrise.exe; nothing else to
install. If Windows still reports a missing VCRUNTIME140.dll or MSVCP140.dll, install Microsoft's
Visual C++ 2015-2022 x64 Redistributable: https://aka.ms/vs/17/release/vc_redist.x64.exe
Experimental: x64 only (runs on Windows 11 ARM through its x64 emulation). Report problems at
https://github.com/colin-tay/agentrise/issues/new?template=windows.yml

----------------------------------------------------------------------
Licences / 许可
----------------------------------------------------------------------
Agentrise: MIT, see LICENSE.txt.
Swift runtime and Foundation DLLs (swift*.dll, Foundation*.dll, _Foundation*.dll, dispatch.dll,
BlocksRuntime.dll, ...): the Swift project, Apache License 2.0 with Runtime Library Exception
(https://swift.org/LICENSE.txt); _FoundationICU.dll contains ICU, Unicode License v3
(https://github.com/unicode-org/icu/blob/main/LICENSE).
$($vcFiles -join ', '): Microsoft Visual C++ runtime $vcVersion, Copyright (c) Microsoft Corporation,
redistributed unmodified as Distributable Code under the Microsoft Visual Studio 2022 license terms
(https://aka.ms/vs/17/redistribution). They are licensed to you only for use with Agentrise, under
terms that protect them at least as much as those license terms: do not modify, reverse engineer or
redistribute them on their own. Microsoft is not affiliated with and does not endorse Agentrise.
"@
# CRLF line ends and a BOM, so Notepad on any Windows version shows the Chinese text.
[System.IO.File]::WriteAllText((Join-Path $stage 'README.txt'), ($readme -replace "`r?`n", "`r`n"),
    [System.Text.UTF8Encoding]::new($true))

$zip = Join-Path $OutDir "Agentrise-windows-x64-$Version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
[System.IO.File]::WriteAllLines((Join-Path $OutDir 'runtime-files.txt'), [string[]]$files)
[System.IO.File]::WriteAllLines((Join-Path $OutDir 'search-dirs.txt'), [string[]]$searchDirs)

Write-Output "files:"
Get-ChildItem -LiteralPath $stage | Sort-Object Name | ForEach-Object { Write-Output ("  {0,12:N0}  {1}" -f $_.Length, $_.Name) }
Write-Output ("zip: {0} ({1:N0} bytes, {2:N1} MB)" -f $zip, (Get-Item -LiteralPath $zip).Length, ((Get-Item -LiteralPath $zip).Length / 1MB))
