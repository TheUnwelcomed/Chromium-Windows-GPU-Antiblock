# build-chromium.ps1 - build Chromium for Windows x64 with every codec Windows can decode, on this machine.
# Windows 10 or 11, Windows PowerShell 5.1. build-chromium.cmd runs it. Safe to run again: every step carries on
# from where the last run stopped.
#
#   build-chromium.cmd [VERSION] [dir=C:\chromium] [jobs=N] [official]
#     VERSION   a Chromium version (158.0.8127.88), or stable / beta / dev / canary: the version of that
#               Chrome for Testing channel (default: stable, the version update.cmd fetches)
#     dir=      where depot_tools and the checkout go: about 100 GB, no spaces in the path (default C:\chromium)
#     jobs=N    at most N compile jobs at once (default: the processors, fewer when memory is short)
#     official  an optimized build (PGO + ThinLTO): a faster browser, about twice the build time, 32 GB of RAM
#
# What it builds is the version's own source with the arguments in args.gn beside this file: H.264, AAC and MP3
# (proprietary_codecs, ffmpeg_branding="Chrome"), HEVC through the graphics card, and AC-3/E-AC-3 through Windows'
# own Dolby decoder (enable_platform_ac3_eac3_audio). The result is copied to ..\builds\custom-VERSION\chrome-win64,
# file by file as Chromium's own Windows archive is made (infra\archive_config\win-archive-rel.json), and becomes
# the build run.cmd and check.cmd use.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$Here = $PSScriptRoot
$Repo = Split-Path -Parent $Here
$Want = 'stable'
$Dir = 'C:\chromium'
$Jobs = 0
$Official = $false
foreach ($a in @($args)) {
  $s = [string]$a
  if ($s -match '^dir=(.+)$') { $Dir = $Matches[1].TrimEnd('\') }
  elseif ($s -match '^jobs=(\d+)$') { $Jobs = [int]$Matches[1] }
  elseif ($s -eq 'official') { $Official = $true }
  elseif ($s) { $Want = $s }
}
$SdkVersion = '10.0.28000.0'          # build/vs_toolchain.py SDK_VERSION at 158 and 160
$DebuggersMin = [Version]'10.0.26100.3323'   # docs/windows_build_instructions.md

function Say([string]$Verdict, [string]$Key, [string]$Text) {
  $color = 'Gray'
  if ($Verdict -eq 'ok') { $color = 'Green' } elseif ($Verdict -eq 'FAIL') { $color = 'Red' }
  Write-Host ('{0,-4} {1,-24} {2}' -f $Verdict, $Key, $Text) -ForegroundColor $color
}

function Step([string]$Text) {
  Write-Host ''
  Write-Host ('== ' + $Text + '  (' + (Get-Date).ToString('HH:mm') + ')') -ForegroundColor Cyan
}

function Run([string]$What, [string]$CommandLine, [string]$WorkDir) {
  # In cmd.exe: depot_tools' commands are .bat files, and its own guide asks for cmd.
  Write-Host "> $CommandLine" -ForegroundColor DarkGray
  Push-Location -LiteralPath $WorkDir
  try { & cmd.exe /d /s /c $CommandLine } finally { Pop-Location }
  if ($LASTEXITCODE -ne 0) {
    throw "$What failed (exit code $LASTEXITCODE). Run build-chromium.cmd again to carry on; the command above is the one that failed."
  }
}

function Get-FileVersion([string]$Path) {
  $vi = (Get-Item -LiteralPath $Path).VersionInfo
  return [Version]('{0}.{1}.{2}.{3}' -f $vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart)
}

# ------------------------------------------------------------------------------------------------ what is needed

function Test-Machine {
  Write-Host 'What this machine has:' -ForegroundColor Cyan
  $bad = 0
  $os = Get-CimInstance Win32_OperatingSystem
  if ([Environment]::Is64BitOperatingSystem) { Say 'ok' 'Windows' "$($os.Caption) $($os.Version), 64-bit" }
  else { Say 'FAIL' 'Windows' 'a 64-bit Windows is needed'; $bad++ }
  $ram = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
  $cpus = [Environment]::ProcessorCount
  if ($ram -ge 16) { Say 'ok' 'memory' "$ram GB, $cpus processors" }
  else { Say '--' 'memory' "$ram GB, $cpus processors: Chromium asks for 8 GB and more than 16 'highly recommended'; the build caps its jobs" }
  if ($Official -and $ram -lt 32) { Say 'FAIL' 'memory for official' "$ram GB: the ThinLTO link of an official build needs about 32 GB. Leave out 'official'"; $bad++ }

  if ($Dir -match '\s') { Say 'FAIL' 'folder' "'$Dir' has a space; Chromium's tools need a path without one (dir=C:\chromium)"; $bad++ }
  $drive = (Split-Path -Qualifier $Dir).TrimEnd(':')
  $free = [Math]::Round((Get-PSDrive -Name $drive).Free / 1GB)
  $need = 120
  if (Test-Path -LiteralPath (Join-Path $Dir 'src')) { $need = 30 }
  if ($free -ge $need) { Say 'ok' 'disk' "$free GB free on ${drive}: ($need GB wanted)" }
  else { Say 'FAIL' 'disk' "$free GB free on ${drive}: - $need GB wanted (choose another drive: dir=D:\chromium)"; $bad++ }
  try {
    $fs = (Get-Volume -DriveLetter $drive -ErrorAction Stop).FileSystem
    if ($fs -ne 'NTFS') { Say 'FAIL' 'file system' "${drive}: is $fs; Chromium needs NTFS (some of its files are over 4 GB)"; $bad++ }
  } catch { }

  if (Get-Command git -ErrorAction SilentlyContinue) { Say 'ok' 'git' ((& git --version) -join ' ') }
  else { Say 'FAIL' 'git' 'not installed: Git for Windows from https://git-scm.com/download/win'; $bad++ }

  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  $script:VsPath = $null
  if (Test-Path -LiteralPath $vswhere) {
    $script:VsPath = & $vswhere -products * -version '[18.0,19.0)' -requires Microsoft.VisualStudio.Workload.NativeDesktop Microsoft.VisualStudio.Component.VC.ATLMFC -property installationPath | Select-Object -First 1
    if (-not $script:VsPath) { $any = & $vswhere -products * -version '[18.0,19.0)' -property installationPath | Select-Object -First 1 }
  }
  if ($script:VsPath) { Say 'ok' 'Visual Studio 2026' $script:VsPath }
  elseif ($any) {
    Say 'FAIL' 'Visual Studio 2026' "installed at $any but without 'Desktop development with C++' and its 'C++ ATL/MFC' parts: add them in the Visual Studio Installer (Modify)"
    $bad++
  } else {
    Say 'FAIL' 'Visual Studio 2026' "not found. Chromium 158 and later need Visual Studio 2026 (18.0 or newer); Community is free. Install it with 'Desktop development with C++' and 'C++ ATL/MFC' - from a command line: VisualStudioSetup.exe --add Microsoft.VisualStudio.Workload.NativeDesktop --add Microsoft.VisualStudio.Component.VC.ATLMFC --includeRecommended"
    $bad++
  }

  $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
  if (Test-Path -LiteralPath (Join-Path $kits "Include\$SdkVersion\um\windows.h")) { Say 'ok' 'Windows SDK' $SdkVersion }
  else { Say 'FAIL' 'Windows SDK' "$SdkVersion not installed: tick 'Windows 11 SDK (10.0.28000.x)' in the Visual Studio Installer, Individual components (it installs on Windows 10)"; $bad++ }
  $dbg = Join-Path $kits 'Debuggers\x64\dbghelp.dll'
  if (Test-Path -LiteralPath $dbg) {
    $v = Get-FileVersion $dbg
    if ($v -ge $DebuggersMin) { Say 'ok' 'SDK Debugging Tools' $v }
    else { Say 'FAIL' 'SDK Debugging Tools' "$v - $DebuggersMin or newer is needed"; $bad++ }
  } else {
    Say 'FAIL' 'SDK Debugging Tools' "not installed: Control Panel > Programs and Features > Windows Software Development Kit $SdkVersion > Change > tick 'Debugging Tools for Windows'"
    $bad++
  }

  try {
    $lp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction Stop).LongPathsEnabled
    if ($lp -eq 1) { Say 'ok' 'long paths' 'on' } else { Say '--' 'long paths' 'off (git is told to use them for this build)' }
  } catch { }

  $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($admin) {
    try { Add-MpPreference -ExclusionPath $Dir -ErrorAction Stop; Say 'ok' 'Defender' "$Dir excluded from scanning (Chromium's guide: the most common cause of a slow build)" }
    catch { Say '--' 'Defender' "could not add the exclusion: $($_.Exception.Message)" }
  } else {
    Say '--' 'Defender' "scanning slows the build badly. Once, in an administrator PowerShell: Add-MpPreference -ExclusionPath $Dir"
  }
  return $bad
}

function Resolve-Version([string]$Want) {
  if ($Want -match '^\d+\.\d+\.\d+\.\d+$') { return $Want }
  $channels = @{ stable = 'Stable'; beta = 'Beta'; dev = 'Dev'; canary = 'Canary' }
  $w = $Want.ToLowerInvariant()
  if (-not $channels.ContainsKey($w)) { throw "unknown version '$Want': say 158.0.8127.88, or stable, beta, dev, canary" }
  $j = Invoke-RestMethod -UseBasicParsing -TimeoutSec 60 -Uri 'https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json'
  return [string]$j.channels.($channels[$w]).version
}

function Get-SourceVersion([string]$Src) {
  $f = Join-Path $Src 'chrome\VERSION'
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  $h = @{}
  foreach ($l in [IO.File]::ReadAllLines($f)) { if ($l -match '^(\w+)=(\d+)$') { $h[$Matches[1]] = $Matches[2] } }
  return "$($h['MAJOR']).$($h['MINOR']).$($h['BUILD']).$($h['PATCH'])"
}

# ------------------------------------------------------------------------------------------------ the build

try {
$started = Get-Date
$ver = Resolve-Version $Want
Write-Host "Chromium $ver for Windows x64, with every codec Windows can decode" -ForegroundColor Cyan
Write-Host "into $Dir$(if ($Official) { ', official (optimized) build' })"
Write-Host ''
if ((Test-Machine) -gt 0) {
  Write-Host ''
  Write-Host 'Fix the FAIL lines above, then run build-chromium.cmd again. Nothing was downloaded.' -ForegroundColor Red
  exit 1
}
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

Step 'depot_tools (Chromium''s own tools)'
$dt = Join-Path $Dir 'depot_tools'
if (-not (Test-Path -LiteralPath (Join-Path $dt 'gclient.bat'))) {
  Run 'getting depot_tools' "git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git depot_tools" $Dir
}
$env:PATH = "$dt;$env:PATH"
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'          # use the Visual Studio installed here, not Google's internal one
$env:vs2026_install = $script:VsPath
# Git settings Chromium's guide asks for, given to these commands only (not your global git config)
$env:GIT_CONFIG_COUNT = '4'
$env:GIT_CONFIG_KEY_0 = 'core.autocrlf'; $env:GIT_CONFIG_VALUE_0 = 'false'
$env:GIT_CONFIG_KEY_1 = 'core.filemode'; $env:GIT_CONFIG_VALUE_1 = 'false'
$env:GIT_CONFIG_KEY_2 = 'core.longpaths'; $env:GIT_CONFIG_VALUE_2 = 'true'
$env:GIT_CONFIG_KEY_3 = 'core.fscache'; $env:GIT_CONFIG_VALUE_3 = 'true'
Run 'setting up depot_tools' 'gclient --version' $Dir

Step "the source of Chromium $ver (the long download: tens of GB)"
$src = Join-Path $Dir 'src'
$have = Get-SourceVersion $src
if (-not (Test-Path -LiteralPath $src)) {
  Run 'getting the source' "git clone -b $ver --depth=2 https://chromium.googlesource.com/chromium/src.git src" $Dir
} elseif ($have -ne $ver) {
  Write-Host "the checkout holds $have; switching it to $ver"
  Run 'fetching the version' "git fetch --depth=2 origin refs/tags/${ver}:refs/tags/$ver" $src
  Run 'switching to it' "git checkout -f tags/$ver" $src
}
# src is "unmanaged": gclient leaves it at the version checked out and fetches what that version's DEPS name
$pgo = 'False'
if ($Official) { $pgo = 'True' }
$gclient = @"
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {"checkout_pgo_profiles": $pgo},
  },
]
target_os = ["win"]
"@
[IO.File]::WriteAllText((Join-Path $Dir '.gclient'), $gclient)
Run 'getting the dependencies' 'gclient sync --no-history --nohooks -D' $Dir
Run 'running the hooks (compilers, toolchains, generated files)' 'gclient runhooks' $Dir

Step 'configuring (args.gn)'
$out = Join-Path $src 'out\Codecs'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$argsText = [IO.File]::ReadAllText((Join-Path $Here 'args.gn'))
if ($Official) { $argsText = $argsText -replace '(?m)^is_official_build = false', 'is_official_build = true' }
[IO.File]::WriteAllText((Join-Path $out 'args.gn'), $argsText)
Run 'gn gen' 'gn gen out\Codecs' $src

Step 'building (many hours; build-chromium.cmd again carries on after any stop)'
if ($Jobs -le 0) {
  $ram = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
  $Jobs = [Math]::Max(2, [Math]::Min([Environment]::ProcessorCount, [int][Math]::Floor($ram / 2)))
}
Write-Host "$Jobs compile jobs at once (jobs=N changes it)"
Run 'the build' "autoninja -C out\Codecs -j $Jobs chrome" $src

Step 'copying the browser out of the build'
$cfg = [IO.File]::ReadAllText((Join-Path $src 'infra\archive_config\win-archive-rel.json')) | ConvertFrom-Json
$set = @($cfg.archive_datas)[0]
$name = "custom-$ver"
$dest = Join-Path $Repo "builds\$name"
$tmp = "$dest.copying"
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
$target = Join-Path $tmp 'chrome-win64'
New-Item -ItemType Directory -Force -Path $target | Out-Null
$skip = @('interactive_ui_tests.exe', 'setup.exe')   # a test, and the installer's helper: not part of the browser
$missing = @()
foreach ($f in @($set.files)) {
  if ($skip -contains $f) { continue }
  $from = Join-Path $out $f
  if (Test-Path -LiteralPath $from) {
    $to = Join-Path $target $f
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
    Copy-Item -LiteralPath $from -Destination $to -Force
  } else { $missing += $f }
}
foreach ($g in @($set.file_globs)) {
  foreach ($file in @(Get-ChildItem -Path (Join-Path $out $g) -File -ErrorAction SilentlyContinue)) {
    $rel = $file.FullName.Substring($out.Length).TrimStart('\')
    $to = Join-Path $target $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $to -Force
  }
}
foreach ($must in @('chrome.exe', 'chrome.dll', 'chrome_elf.dll', 'resources.pak', 'icudtl.dat', 'v8_context_snapshot.bin', 'locales\en-US.pak')) {
  if (-not (Test-Path -LiteralPath (Join-Path $target $must))) { throw "the build has no $must - the copy is incomplete" }
}
if ($missing.Count) { Write-Host ('not built, left out: ' + ($missing -join ', ')) -ForegroundColor DarkGray }
if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
Move-Item -LiteralPath $tmp -Destination $dest
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'antiblock.ps1') use $name
if ($LASTEXITCODE -ne 0) { throw 'antiblock.ps1 use failed' }

$took = (Get-Date) - $started
Write-Host ''
Write-Host ("Done in {0:N1} hours: {1}" -f $took.TotalHours, (Join-Path $dest 'chrome-win64\chrome.exe')) -ForegroundColor Green
Write-Host 'run.cmd starts it; check.cmd should now say "plays" on the AC-3 and E-AC-3 lines as well.' -ForegroundColor Green
exit 0
} catch {
  Write-Host ''
  Write-Host ('FAIL ' + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
