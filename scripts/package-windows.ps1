# Copyright (c) 2026 Colin Tay
# SPDX-License-Identifier: MIT
#
# Packages the Windows app as Agentrise-windows-x64-<version>.zip (spec §5.10): Agentrise.exe, agentrise-hook.exe,
# every DLL they import transitively that isn't Windows' own, LICENSE and a README.txt.
#
# The DLL closure comes from `dumpbin /dependents` (imports and delay-load imports), searching, in order: the build
# directory, the Visual C++ runtime's redistributable folder (VC\Redist\MSVC\<version>\x64\Microsoft.VC14x.CRT of the
# newest Visual Studio with the C++ tools) and the Swift runtime directory (the directory on PATH with swiftCore.dll).
# The VC++ folder comes before Swift's, which has its own copies of vcruntime140*.dll and msvcp140.dll: the zip's copies
# are the ones Visual Studio's licence lets us redistribute. A DLL found in none of them must be Windows' own: an API
# set (api-ms-win-*, ext-ms-*), or a file in %SystemRoot%\System32 that isn't a Swift or VC++ runtime name. Anything
# else fails the packaging, naming the DLL and the file that imports it (`RuntimeFiles.isSystem` is the same rule).
# `Agentrise.exe --print-runtime-files` computes the same list with `RuntimeFiles.closure`, which the installed hook
# copies its DLLs with; the release workflow checks that the two agree.
#
# The Visual C++ runtime DLLs (vcruntime140*.dll, msvcp140*.dll) are deployed next to the exe ("application local
# folder"), unmodified, as Visual Studio's Distributable Code list allows for the files in VC\Redist ("you may copy and
# distribute with your program any of the files within the following folder and its subfolders": VC\redist); see
# README.txt below and the README's Windows section.
#
# Usage (from the repository root, after `swift build -c release`):
#   scripts/package-windows.ps1 -Version 1.0 [-BinDir <dir>] [-OutDir dist]
# Writes <OutDir>\Agentrise\ (the zip's contents), <OutDir>\Agentrise-windows-x64-<version>.zip, and, for the
# workflow's check (not in the zip), <OutDir>\runtime-files.txt, search-dirs.txt, system-dlls.txt and
# hook-closure.txt: the closure's source paths, the directories searched, the imports that are Windows' own and the
# hook's own closure in the packaged folder (what the app copies to bin\), one per line.
# The zip also carries the licence texts in third_party\licenses (the Swift runtime's and ICU's, full text).
param(
    [Parameter(Mandatory = $true)] [string] $Version,
    [string] $BinDir,
    [string] $OutDir = 'dist'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$') { throw "unusable version '$Version'" }
if (-not $BinDir) {
    $BinDir = (swift build -c release --show-bin-path | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $BinDir) { throw "swift build --show-bin-path failed ($LASTEXITCODE)" }
}
$BinDir = (Resolve-Path -LiteralPath $BinDir).Path
$root = Split-Path -Parent $PSScriptRoot

function Find-VisualStudio {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw "no vswhere.exe at $vswhere" }
    $vs = @(& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    if ($LASTEXITCODE -ne 0) { throw "vswhere failed ($LASTEXITCODE)" }
    $vs = $vs | Select-Object -First 1
    if (-not $vs) { throw 'no Visual Studio with the C++ x64 tools' }
    return $vs
}

function Get-VisualStudioLine {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $line = @(& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property catalog_productLineVersion)
    if ($LASTEXITCODE -ne 0) { throw "vswhere failed ($LASTEXITCODE)" }
    $line = $line | Select-Object -First 1
    if (-not $line) { throw 'vswhere gave no product line for Visual Studio' }
    return "$line".Trim()
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

# Windows' own DLL (see the header): RuntimeFiles.isSystem in Sources/AgentriseWin/HookSetup.swift.
function Test-SystemDll([string] $name) {
    $n = $name.ToLowerInvariant()
    if ($n.StartsWith('api-ms-win-') -or $n.StartsWith('ext-ms-')) { return $true }
    if ($n -match '^(swift|foundation|_foundation|vcruntime140|msvcp140|concrt140)' -or $n -in 'dispatch.dll', 'blocksruntime.dll') {
        return $false
    }
    return (Test-Path -LiteralPath (Join-Path ([System.Environment]::SystemDirectory) $name))
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
$vsLine = Get-VisualStudioLine
$searchDirs = @($BinDir, $vcRuntime, $swiftRuntime)
Write-Output "dumpbin: $dumpbin"
Write-Output "search: $($searchDirs -join ' | ')"

$exes = @('Agentrise.exe', 'agentrise-hook.exe') | ForEach-Object {
    $p = Join-Path $BinDir $_
    if (-not (Test-Path -LiteralPath $p)) { throw "no $p (build the release products first)" }
    $p
}
# The exes, then every DLL they import transitively that a search directory has (the first one that has it);
# imports in none of them go to System (Windows' own) or Missing ("<name> (imported by <file>)").
function Get-Closure([string] $dumpbin, [string[]] $exes, [string[]] $dirs) {
    $r = @{
        Files   = [System.Collections.Generic.List[string]]::new()
        System  = [System.Collections.Generic.List[string]]::new()
        Missing = [System.Collections.Generic.List[string]]::new()
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($e in $exes) { $r.Files.Add($e); [void]$seen.Add((Split-Path -Leaf $e)); $queue.Enqueue($e) }
    while ($queue.Count -gt 0) {
        $file = $queue.Dequeue()
        foreach ($name in (Get-Imports $dumpbin $file)) {
            if (-not $seen.Add($name)) { continue }
            $found = $dirs | ForEach-Object { Join-Path $_ $name } | Where-Object { Test-Path -LiteralPath $_ } |
                Select-Object -First 1
            if ($found) { $r.Files.Add($found); $queue.Enqueue($found) }
            elseif (Test-SystemDll $name) { $r.System.Add($name) }
            else { $r.Missing.Add("$name (imported by $(Split-Path -Leaf $file))") }
        }
    }
    return $r
}

$closure = Get-Closure $dumpbin $exes $searchDirs
$files = $closure.Files
$system = $closure.System
$missing = $closure.Missing
if ($missing.Count -gt 0) {
    throw "DLLs found in no search directory and not Windows' own: $($missing -join '; ')"
}

$licenses = @('Swift-LICENSE.txt', 'ICU-LICENSE.txt') | ForEach-Object {
    $p = Join-Path $root "third_party\licenses\$_"
    if (-not (Test-Path -LiteralPath $p)) { throw "no $p" }
    $p
}

$OutDir = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $OutDir))
$stage = Join-Path $OutDir 'Agentrise'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
foreach ($f in $files) { Copy-Item -LiteralPath $f -Destination $stage }
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $stage 'LICENSE.txt')
foreach ($l in $licenses) { Copy-Item -LiteralPath $l -Destination $stage }
$vcFiles = @($files | Where-Object { (Split-Path -Leaf $_) -match '^(vcruntime|msvcp)140' })
foreach ($f in $vcFiles) {
    if (-not $f.StartsWith($vcRuntime, [System.StringComparison]::OrdinalIgnoreCase)) { throw "$f is not from $vcRuntime" }
}
$vcFiles = @($vcFiles | ForEach-Object { Split-Path -Leaf $_ })
if ($vcFiles.Count -eq 0) { throw 'no VC++ runtime DLLs in the closure (expected vcruntime140.dll and msvcp140.dll)' }
$vcVersion = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $vcRuntime))
# vswhere's product line is "2022" for Visual Studio 2022 and "18" for Visual Studio 2026.
$vsYear = switch ($vsLine) { { $_ -in '17', '2022' } { '2022' } { $_ -in '18', '2026' } { '2026' } default { $null } }
if (-not $vsYear) { throw "unknown Visual Studio product line '$vsLine': add its Distributable Code list here" }
$redistList = "https://learn.microsoft.com/visualstudio/releases/$vsYear/redistribution"
$vsName = "Microsoft Visual Studio $vsYear"

$readme = @"
Agentrise $Version for Windows (experimental) / Windows 实验版

Agentrise shows your Claude Code and Codex sessions as robots in a small office tower.
https://github.com/colin-tay/agentrise

----------------------------------------------------------------------
中文
----------------------------------------------------------------------
系统要求：Windows 10 1809 或更新版本，或 Windows 11；x64。
运行：把 zip 解压到一个单独的新文件夹（这些文件都要放在一起），双击 Agentrise.exe。它常驻在系统托盘（任务栏右下角）。
首次运行：这个程序没有签名。SmartScreen 提示"Windows 已保护你的电脑"时，点"更多信息"→"仍要运行"。
开了"智能应用控制"（Smart App Control）的电脑会直接拦截未签名程序，没有"仍要运行"按钮；
查看它的状态：设置 → 隐私和安全性 → Windows 安全中心 → 应用和浏览器控制 → 智能应用控制。
接入：托盘图标右键 → 设置… → 安装 Claude Code / Codex 的 hook（先预览、再备份原文件）。
hook 程序会复制到 %LOCALAPPDATA%\Agentrise\bin\，之后移动或删除这个解压目录不影响 hook。
运行库：Visual C++ 运行库（$($vcFiles -join ', ')）已经随包附带，放在 Agentrise.exe 旁边，不需要另装。
如果启动时仍提示缺少 VCRUNTIME140.dll 或 MSVCP140.dll，请安装微软官方的
Visual C++ v14 可再发行组件包（x64）：https://aka.ms/vc14/vc_redist.x64.exe
这是实验版本：只有 x64（Windows 11 ARM 通过系统的 x64 模拟运行）。问题反馈：
https://github.com/colin-tay/agentrise/issues/new?template=windows.yml

----------------------------------------------------------------------
English
----------------------------------------------------------------------
Requires: Windows 10 version 1809 or later, or Windows 11; x64.
Run: unzip into a folder of its own (the files must stay together) and double-click Agentrise.exe.
It lives in the notification area (system tray).
First run: the program is unsigned. When SmartScreen says "Windows protected your PC", choose
"More info" -> "Run anyway". With Smart App Control on, Windows blocks unsigned programs outright,
with no "Run anyway"; check its state in Settings -> Privacy & security -> Windows Security ->
App & browser control -> Smart App Control.
Hooks: right-click the tray icon -> Settings... -> install the Claude Code / Codex hooks (previewed,
the old file backed up). The hook is copied to %LOCALAPPDATA%\Agentrise\bin\, so moving or deleting
this folder later doesn't break it.
Runtime: the Visual C++ runtime ($($vcFiles -join ', ')) ships next to Agentrise.exe;
nothing else to install. If Windows still reports a missing VCRUNTIME140.dll or MSVCP140.dll, install Microsoft's
Visual C++ v14 Redistributable (x64): https://aka.ms/vc14/vc_redist.x64.exe
Experimental: x64 only (runs on Windows 11 ARM through its x64 emulation). Report problems at
https://github.com/colin-tay/agentrise/issues/new?template=windows.yml

----------------------------------------------------------------------
Licences / 许可
----------------------------------------------------------------------
Agentrise: MIT, see LICENSE.txt.
Swift runtime and Foundation DLLs (swift*.dll, Foundation*.dll, _Foundation*.dll, dispatch.dll,
BlocksRuntime.dll): Swift 6.1.2, Apache License 2.0 with the Runtime Library Exception; full text in
Swift-LICENSE.txt.
_FoundationICU.dll contains ICU 74.1: Unicode License V3 and ICU's third-party licences; full text in
ICU-LICENSE.txt.
$($vcFiles -join ', '): Microsoft Visual C++ runtime $vcVersion,
Copyright (c) Microsoft Corporation, redistributed unmodified as Distributable Code under the
$vsName license terms (https://visualstudio.microsoft.com/license-terms/;
Distributable Code list: $redistList).
They are licensed to you only for use with Agentrise, under
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
[System.IO.File]::WriteAllLines((Join-Path $OutDir 'system-dlls.txt'), [string[]]$system)
# What the app copies to %LOCALAPPDATA%\Agentrise\bin with the hook: its closure in the packaged folder alone.
$hookClosure = Get-Closure $dumpbin @((Join-Path $stage 'agentrise-hook.exe')) @($stage)
if ($hookClosure.Missing.Count -gt 0) { throw "the packaged hook misses: $($hookClosure.Missing -join '; ')" }
[System.IO.File]::WriteAllLines((Join-Path $OutDir 'hook-closure.txt'), [string[]]@($hookClosure.Files | ForEach-Object { Split-Path -Leaf $_ }))

Write-Output "files:"
Get-ChildItem -LiteralPath $stage | Sort-Object Name | ForEach-Object { Write-Output ("  {0,12:N0}  {1}" -f $_.Length, $_.Name) }
Write-Output ("zip: {0} ({1:N0} bytes, {2:N1} MB)" -f $zip, (Get-Item -LiteralPath $zip).Length, ((Get-Item -LiteralPath $zip).Length / 1MB))
