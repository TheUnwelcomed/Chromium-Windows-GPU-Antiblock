# antiblock.ps1 - Chromium for Windows that draws on the graphics card, not on the processor.
# Windows PowerShell 5.1 (Windows 10's own) or PowerShell 7. Nothing to install. The .cmd files beside it run it.
#
#   update [stable|beta|dev|canary|153|153.0.8010.52]   fetch Chrome for Testing (default: stable)
#   run [edge] [URL ...] [--switch ...]                  start it (or Microsoft Edge), with the switches of flags.txt
#   check [edge] [keep] [--switch ...]                   ask it what it does with the card and the codecs -> reports\
#   reset [edge]                                         empty the GPU caches of its profile
#   status                                               the build, the switches, what Windows sees
#   forget                                               take back the Windows graphics setting it made
#
# Chrome for Testing, not a raw Chromium snapshot: it is built with the proprietary codecs (H.264, AAC, HEVC through
# the card; build/config/features.gni), a snapshot is not. "edge" runs the Microsoft Edge already on the machine with
# the same switches and a profile of its own: the one Chromium browser on Windows that plays AC-3/E-AC-3 (Dolby), which
# Google compiles out of Chrome on Windows (media/media_options.gni).
#
# Builds, profiles and reports live in this folder (builds\, profile\, profile-edge\, reports\); nothing of an
# installed browser or its everyday profile is touched. Based on scheib/chromium-latest-linux (Apache-2.0).

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Windows PowerShell's progress bar slows a download to a crawl
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$ScriptArgs = @($args)
$Root = $PSScriptRoot
$Builds = Join-Path $Root 'builds'
$ProfileDir = Join-Path $Root 'profile'
$EdgeProfileDir = Join-Path $Root 'profile-edge'
$CheckProfile = Join-Path $Root 'profile-check'
$Reports = Join-Path $Root 'reports'
$FlagsFile = Join-Path $Root 'flags.txt'
$CurrentFile = Join-Path $Builds 'current.txt'
$CheckDir = Join-Path $Root 'check'
$GpuPrefKey = 'Software\Microsoft\DirectX\UserGpuPreferences'   # under HKEY_CURRENT_USER: Settings > Display > Graphics
$KeepBuilds = 2                                                  # the current one and one before it
$CftJson = 'https://googlechromelabs.github.io/chrome-for-testing/'
$script:Lines = New-Object System.Collections.Generic.List[string]

# ------------------------------------------------------------------------------------------------ small helpers

function Write-Line([string]$Verdict, [string]$Key, [string]$Text) {
  $line = '{0,-4} {1,-28} {2}' -f $Verdict, $Key, $Text
  $script:Lines.Add($line)
  $color = 'Gray'
  if ($Verdict -eq 'ok') { $color = 'Green' } elseif ($Verdict -eq 'FAIL') { $color = 'Red' }
  Write-Host $line -ForegroundColor $color
}

function Read-Flags {
  # One switch a line, taken whole; a line whose first character (after spaces) is # is a note.
  $out = @()
  if (Test-Path -LiteralPath $FlagsFile) {
    foreach ($raw in [IO.File]::ReadAllLines($FlagsFile)) {
      $line = $raw.Trim()
      if ($line -and -not $line.StartsWith('#')) { $out += $line }
    }
  }
  return $out
}

function ConvertTo-ArgString([string[]]$Items) {
  # Windows' own rules for one command line (CommandLineToArgvW, which Chromium uses): quote what has spaces or
  # quotes, double the backslashes in front of a quote and at the end of a quoted argument.
  $parts = foreach ($a in $Items) {
    if ($null -eq $a) { continue }
    if ($a -eq '') { '""' }
    elseif ($a -notmatch '[\s"]') { $a }
    else {
      $s = $a -replace '(\\*)"', '$1$1\"'
      $s = $s -replace '(\\+)$', '$1$1'
      '"' + $s + '"'
    }
  }
  return ($parts -join ' ')
}

function Get-Text([string]$Url) {
  $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60
  if ($r.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($r.Content) }
  return [string]$r.Content
}

function Get-ObjectInfo([string]$Bucket, [string]$Object) {
  # Google's own record of a file in its storage: size and MD5 (null when there is no such file)
  $u = 'https://www.googleapis.com/storage/v1/b/' + $Bucket + '/o/' + [Uri]::EscapeDataString($Object)
  try { return Invoke-RestMethod -Uri $u -UseBasicParsing -TimeoutSec 60 }
  catch {
    $resp = $_.Exception.Response
    if ($resp -and [int]$resp.StatusCode -eq 404) { return $null }
    throw
  }
}

function Save-Url([string]$Url, [string]$Path) {
  $req = [Net.HttpWebRequest]::Create($Url)
  $req.UserAgent = 'Chromium-Windows-GPU-Antiblock'
  $req.Timeout = 60000
  $req.ReadWriteTimeout = 120000
  $resp = $req.GetResponse()
  try {
    $total = $resp.ContentLength
    $in = $resp.GetResponseStream()
    $out = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
      $buf = New-Object byte[] (1MB)
      $done = [long]0
      $clock = [Diagnostics.Stopwatch]::StartNew()
      $shown = -10.0
      while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
        $out.Write($buf, 0, $n)
        $done += $n
        if ($clock.Elapsed.TotalSeconds - $shown -ge 2) {
          $shown = $clock.Elapsed.TotalSeconds
          $rate = ($done / 1MB) / [Math]::Max($shown, 0.001)
          if ($total -gt 0) { Write-Host ('  {0,6:N1} of {1:N1} MB ({2:N0} %), {3:N1} MB/s' -f ($done / 1MB), ($total / 1MB), (100 * $done / $total), $rate) }
          else { Write-Host ('  {0,6:N1} MB, {1:N1} MB/s' -f ($done / 1MB), $rate) }
        }
      }
    } finally { $out.Close() }
  } finally { $resp.Close() }
}

function Test-Download([string]$Path, $Info) {
  $size = (Get-Item -LiteralPath $Path).Length
  if ([string]$size -ne [string]$Info.size) { throw "the download has $size bytes; Google's record of the file says $($Info.size)" }
  if ($Info.md5Hash) {
    $want = [BitConverter]::ToString([Convert]::FromBase64String([string]$Info.md5Hash)) -replace '-', ''
    $got = (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash
    if ($got -ne $want) { throw "the download's MD5 is $got; Google's record of the file says $want" }
  }
}

function Find-Chrome([string]$Dir) {
  if (-not (Test-Path -LiteralPath $Dir)) { return $null }
  $f = Get-ChildItem -LiteralPath $Dir -Recurse -Filter 'chrome.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($f) { return $f.FullName }
  return $null
}

function Get-Current {
  # builds\current.txt names the build in use (by folder name, so the whole folder can be moved)
  if (-not (Test-Path -LiteralPath $CurrentFile)) { return $null }
  $h = @{}
  foreach ($l in [IO.File]::ReadAllLines($CurrentFile)) {
    $i = $l.IndexOf('=')
    if ($i -gt 0) { $h[$l.Substring(0, $i)] = $l.Substring($i + 1) }
  }
  if (-not $h['name']) { return $null }
  $exe = Find-Chrome (Join-Path $Builds $h['name'])
  if (-not $exe) { return $null }
  $h['exe'] = $exe
  return $h
}

function Set-Current($Build) {
  $text = "name=$($Build.Name)`r`nbuild=$($Build.Label)`r`nfetched=$((Get-Date).ToString('yyyy-MM-dd HH:mm'))`r`n"
  [IO.File]::WriteAllText($CurrentFile, $text)
}

function Set-GpuPreference([string]$Exe) {
  # What Settings > System > Display > Graphics > "High performance" writes for a program: Windows then hands this
  # chrome.exe the high-performance adapter on a machine with more than one.
  try {
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($GpuPrefKey)
    $k.SetValue($Exe, 'GpuPreference=2;', [Microsoft.Win32.RegistryValueKind]::String)
    $k.Close()
    Write-Host 'Windows graphics setting for this chrome.exe: High performance'
  } catch { Write-Host "could not set the Windows graphics setting: $($_.Exception.Message)" }
}

function Remove-GpuPreference([string]$Exe) {
  try {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($GpuPrefKey, $true)
    if ($k) { $k.DeleteValue($Exe, $false); $k.Close() }
  } catch { }
}

function Get-OwnChromes {
  # chrome.exe processes started from this folder's builds (none may run while their files are changed)
  @(Get-Process -Name chrome -ErrorAction SilentlyContinue | Where-Object {
      $p = $null; try { $p = $_.Path } catch { }
      $p -and $p.StartsWith($Builds, [StringComparison]::OrdinalIgnoreCase) })
}

function Show-Windows {
  # What Windows itself says of the session and the adapters, before Chromium is asked anything
  if ($env:SESSIONNAME -and $env:SESSIONNAME -like 'RDP-*') {
    Write-Line 'FAIL' 'session' "Remote Desktop ($env:SESSIONNAME): programs in it get no graphics card - run this at the machine itself"
  } else { Write-Line '--' 'session' ($(if ($env:SESSIONNAME) { $env:SESSIONNAME } else { 'local' })) }
  try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ("$($cs.Model) $($cs.Manufacturer)" -match 'Virtual|VMware|VirtualBox|KVM|QEMU|Xen|Parallels|Hyper-V') {
      Write-Line '--' 'machine' "a virtual machine ($($cs.Manufacturer) $($cs.Model)): its own display adapter is blocklisted by Chromium"
    }
    foreach ($vc in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
      $drv = [string]$vc.DriverVersion
      $nv = ''
      if ($vc.AdapterCompatibility -match 'NVIDIA' -and $drv -match '\.(\d+)\.(\d+)$') {
        $digits = ($Matches[1] + $Matches[2])
        if ($digits.Length -ge 5) { $d5 = $digits.Substring($digits.Length - 5); $nv = ' = NVIDIA ' + $d5.Substring(0, 3) + '.' + $d5.Substring(3) }
      }
      $code = [int]$vc.ConfigManagerErrorCode
      $state = 'working'
      if ($code -eq 43) { $state = 'STOPPED by Windows (Code 43: the driver reported a problem)' }
      elseif ($code -eq 22) { $state = 'DISABLED in Device Manager (Code 22)' }
      elseif ($code -eq 28) { $state = 'NO DRIVER (Code 28)' }
      elseif ($code -ne 0) { $state = "not working (Device Manager code $code)" }
      $v = '--'
      if ($vc.AdapterCompatibility -match 'NVIDIA') { if ($code -eq 0) { $v = 'ok' } else { $v = 'FAIL' } }
      Write-Line $v 'Windows adapter' ("{0}, driver {1}{2}, {3}" -f $vc.Name, $drv, $nv, $state)
    }
  } catch { Write-Line '--' 'Windows adapters' "not read: $($_.Exception.Message)" }
}

# ------------------------------------------------------------------------------------------------ update

function Resolve-Build([string]$Want) {
  if (-not $Want) { $Want = 'stable' }
  $w = $Want.ToLowerInvariant()
  if ($w -eq 'snapshot') {
    throw 'raw Chromium snapshots are built without H.264, AAC and HEVC (build/config/features.gni) - not offered here. The newest build with them: update.cmd canary'
  }
  $channels = @{ stable = 'Stable'; beta = 'Beta'; dev = 'Dev'; canary = 'Canary' }
  $entry = $null
  if ($channels.ContainsKey($w)) {
    $j = Invoke-RestMethod -Uri ($CftJson + 'last-known-good-versions-with-downloads.json') -UseBasicParsing -TimeoutSec 60
    $entry = $j.channels.($channels[$w])
  } elseif ($w -match '^\d+$') {
    $j = Invoke-RestMethod -Uri ($CftJson + 'latest-versions-per-milestone-with-downloads.json') -UseBasicParsing -TimeoutSec 60
    $entry = $j.milestones.$w
    if (-not $entry) { throw "Chrome for Testing has no milestone $w" }
  } elseif ($w -match '^\d+\.\d+\.\d+\.\d+$') {
    $entry = [pscustomobject]@{ version = $w }
  } else {
    throw "unknown build '$Want': say stable, beta, dev, canary, a milestone (153) or a version (153.0.8010.52)"
  }
  $v = [string]$entry.version
  if ($entry.downloads -and -not (@($entry.downloads.chrome) | Where-Object { $_.platform -eq 'win64' })) {
    throw "Chrome for Testing $v has no 64-bit Windows build"
  }
  $object = "$v/win64/chrome-win64.zip"
  return [pscustomobject]@{ Label = "Chrome for Testing $v ($w)"; Name = "cft-$v"; Bucket = 'chrome-for-testing-public';
    Object = $object; Url = "https://storage.googleapis.com/chrome-for-testing-public/$object"; Info = $null }
}

function Remove-OldBuilds {
  $cur = Get-Current
  $others = @(Get-ChildItem -LiteralPath $Builds -Directory | Where-Object { $_.Name -match '^cft-[0-9.]+$' -and
      -not ($cur -and $_.Name -eq $cur['name']) } | Sort-Object LastWriteTime -Descending)
  $n = 0
  foreach ($d in $others) {
    $n++
    if ($n -lt $KeepBuilds) { continue }
    $exe = Find-Chrome $d.FullName
    try {
      Remove-Item -LiteralPath $d.FullName -Recurse -Force
      if ($exe) { Remove-GpuPreference $exe }
      Write-Host "removed the older build $($d.Name)"
    } catch { Write-Host "could not remove $($d.Name) yet (is it running?): $($_.Exception.Message)" }
  }
}

function Invoke-Update([string]$Want) {
  New-Item -ItemType Directory -Force -Path $Builds | Out-Null
  $b = Resolve-Build $Want
  Write-Host "newest: $($b.Label)"
  $dir = Join-Path $Builds $b.Name
  $exe = Find-Chrome $dir
  if ($exe) {
    Write-Host "already here: $exe"
  } else {
    $info = $b.Info
    if (-not $info) { $info = Get-ObjectInfo $b.Bucket $b.Object }
    if (-not $info) { throw "Google has no file $($b.Object) - is the version right?" }
    $zip = Join-Path $Builds ($b.Name + '.zip')
    $part = $zip + '.part'
    Write-Host ('fetching {0} ({1:N1} MB)' -f $b.Url, ([long]$info.size / 1MB))
    Save-Url $b.Url $part
    Test-Download $part $info
    Move-Item -LiteralPath $part -Destination $zip -Force
    Write-Host "the file agrees with Google's record of it (size and MD5); unpacking"
    $tmp = $dir + '.unpacking'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
    Move-Item -LiteralPath $tmp -Destination $dir
    Remove-Item -LiteralPath $zip -Force
    $exe = Find-Chrome $dir
    if (-not $exe) { throw "the archive held no chrome.exe ($dir)" }
  }
  Set-Current $b
  Set-GpuPreference $exe
  Remove-OldBuilds
  Write-Host ('in use: {0} ({1})' -f $exe, (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion)
}

# ------------------------------------------------------------------------------------------------ which browser

function Find-Edge {
  $places = @()
  if (${env:ProgramFiles(x86)}) { $places += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
  if ($env:ProgramFiles) { $places += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe') }
  try {
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe')
    if ($k) { $v = [string]$k.GetValue(''); $k.Close(); if ($v) { $places += $v.Trim('"') } }
  } catch { }
  foreach ($p in $places) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
  return $null
}

function Get-Browser([string[]]$Rest) {
  # "edge" as the first word picks the installed Microsoft Edge; otherwise the Chrome for Testing in builds\.
  # Returns the browser and the words that remain.
  $words = @($Rest | Where-Object { $_ })
  if ($words.Count -and $words[0] -eq 'edge') {
    $exe = Find-Edge
    if (-not $exe) { throw 'Microsoft Edge is not installed where Windows keeps it' }
    $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    $more = @()
    if ($words.Count -gt 1) { $more = @($words[1..($words.Count - 1)]) }
    return @{ exe = $exe; build = "Microsoft Edge $version (installed)"; profile = $EdgeProfileDir; edge = $true; rest = $more }
  }
  $cur = Get-Current
  if (-not $cur) { throw 'no build here yet: run update.cmd first' }
  return @{ exe = $cur['exe']; build = $cur['build']; profile = $ProfileDir; edge = $false; rest = $words }
}

# ------------------------------------------------------------------------------------------------ run

function Invoke-Run([string[]]$Rest) {
  $b = Get-Browser $Rest
  $list = @(Read-Flags) + @("--user-data-dir=$($b.profile)", '--no-first-run', '--no-default-browser-check', '--enable-logging') + @($b.rest)
  $line = ConvertTo-ArgString $list
  Write-Host "starting $($b.build)"
  Write-Host "  $($b.exe) $line"
  Start-Process -FilePath $b.exe -ArgumentList $line | Out-Null
}

# ------------------------------------------------------------------------------------------------ check: the browser's debugging port

$script:Ws = $null
$script:NextId = 0
$WhereJs = 'location.href.split("#")[0].replace(/\/$/, "") + " " + document.readyState'   # single quotes: no $ expansion

function Connect-DevTools([int]$Port, [string]$Path) {
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $ws.Options.Proxy = $null   # 127.0.0.1 never goes through a proxy
  $ws.ConnectAsync([Uri]("ws://127.0.0.1:$Port$Path"), [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  $script:Ws = $ws
}

function Send-Text([string]$Text) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
  $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $bytes)
  $script:Ws.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
}

function Receive-Text([int]$TimeoutSec) {
  $buf = New-Object byte[] 65536
  $ms = New-Object IO.MemoryStream
  $cts = New-Object Threading.CancellationTokenSource ([TimeSpan]::FromSeconds($TimeoutSec))
  do {
    $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $buf)
    $r = $script:Ws.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
    if ($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'Chromium closed its debugging connection' }
    $ms.Write($buf, 0, $r.Count)
  } while (-not $r.EndOfMessage)
  return [Text.Encoding]::UTF8.GetString($ms.ToArray())
}

function Invoke-Cdp([string]$Method, [hashtable]$Params = @{}, [string]$Session = '', [int]$TimeoutSec = 90) {
  $script:NextId++
  $id = $script:NextId
  $msg = @{ id = $id; method = $Method; params = $Params }
  if ($Session) { $msg['sessionId'] = $Session }
  Send-Text (ConvertTo-Json $msg -Depth 10 -Compress)
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($clock.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $text = Receive-Text ([Math]::Max(5, [int]($TimeoutSec - $clock.Elapsed.TotalSeconds)))
    if ($text.IndexOf('"id":' + $id + ',') -lt 0 -and $text.IndexOf('"id":' + $id + '}') -lt 0) { continue }  # an event or another answer
    $reply = ConvertFrom-Json $text
    if ($reply.id -ne $id) { continue }
    if ($reply.error) { throw "$Method : $($reply.error.message)" }
    return $reply.result
  }
  throw "$Method : no answer in $TimeoutSec s"
}

function Invoke-Js([string]$Session, [string]$Expression, [int]$TimeoutSec = 90) {
  $r = Invoke-Cdp 'Runtime.evaluate' @{ expression = $Expression; awaitPromise = $true; returnByValue = $true; timeout = ($TimeoutSec * 1000) } $Session ($TimeoutSec + 5)
  if ($r.exceptionDetails) { throw ('the page script failed: ' + $r.exceptionDetails.text + ' ' + $r.exceptionDetails.exception.description) }
  return $r.result.value
}

function Open-Tab([string]$Url, [int]$TimeoutSec = 60) {
  # A new tab at Url; its session once the page there has loaded (a new tab starts on about:blank)
  $t = Invoke-Cdp 'Target.createTarget' @{ url = $Url }
  $s = (Invoke-Cdp 'Target.attachToTarget' @{ targetId = $t.targetId; flatten = $true }).sessionId
  $want = (($Url -split '#')[0].TrimEnd('/')) -replace '^edge://', 'chrome://'   # Edge serves chrome:// pages as edge://
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($clock.Elapsed.TotalSeconds -lt $TimeoutSec) {
    try {
      $here = [string](Invoke-Js $s $WhereJs 10)
      if ($here.EndsWith(' complete') -and ($here.Substring(0, $here.Length - 9) -replace '^edge://', 'chrome://') -eq $want) { return $s }
    } catch { }
    Start-Sleep -Milliseconds 200
  }
  throw "the tab did not reach $Url"
}

function Get-PageString([string]$Session, [string]$Name, [long]$Length) {
  # a long string the page keeps (window[Name]), in pieces of 200,000 characters
  $sb = New-Object Text.StringBuilder
  for ($at = 0; $at -lt $Length; $at += 200000) {
    [void]$sb.Append([string](Invoke-Js $Session "window['$Name'].substr($at, 200000)" 60))
  }
  return $sb.ToString()
}

function Invoke-Check([string[]]$Rest) {
  $cur = Get-Browser $Rest
  $KeepOpen = @($cur.rest | Where-Object { $_ -eq 'keep' }).Count -gt 0
  $Extra = @($cur.rest | Where-Object { $_ -ne 'keep' })
  if (Test-Path -LiteralPath $CheckProfile) {
    try { Remove-Item -LiteralPath $CheckProfile -Recurse -Force }
    catch { throw "the window of the last check (check keep) is still open: close it first ($($_.Exception.Message))" }
  }
  New-Item -ItemType Directory -Force -Path $CheckProfile | Out-Null
  New-Item -ItemType Directory -Force -Path $Reports | Out-Null
  $started = Get-Date
  Show-Windows
  # A fresh profile of its own: no setting of an everyday profile (hardware acceleration switched off, a GPU that
  # crashed in an earlier session) can change what is seen.
  $list = @(Read-Flags) + @($Extra | Where-Object { $_ }) + @("--user-data-dir=$CheckProfile", '--remote-debugging-port=0', '--no-first-run',
    '--no-default-browser-check', '--disable-search-engine-choice-screen', '--enable-logging', '--v=0', 'about:blank')
  $argLine = ConvertTo-ArgString $list
  $proc = Start-Process -FilePath $cur.exe -ArgumentList $argLine -PassThru
  $portFile = Join-Path $CheckProfile 'DevToolsActivePort'
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-Path -LiteralPath $portFile) -and $clock.Elapsed.TotalSeconds -lt 60 -and -not $proc.HasExited) { Start-Sleep -Milliseconds 200 }
  if (-not (Test-Path -LiteralPath $portFile)) {
    Write-Line 'FAIL' 'Chromium' "did not open its debugging port within 60 s (exited: $($proc.HasExited))"
    try { $proc.Kill() } catch { }
    return 2
  }
  Start-Sleep -Milliseconds 300
  $pf = [IO.File]::ReadAllLines($portFile)
  $judged = $null; $page = $null; $reportText = ''; $dataText = ''; $sysText = 'not asked'
  try {
    Connect-DevTools ([int]$pf[0]) $pf[1].Trim()
    try { $sysText = ConvertTo-Json (Invoke-Cdp 'SystemInfo.getInfo') -Depth 8 } catch { $sysText = "not answered: $($_.Exception.Message)" }
    $s1 = Open-Tab 'chrome://gpu'
    $judged = ConvertFrom-Json ([string](Invoke-Js $s1 ([IO.File]::ReadAllText((Join-Path $CheckDir 'gpu-judge.js'))) 90))
    if ($judged.error) { Write-Line 'FAIL' 'chrome://gpu' $judged.error }
    else {
      $reportText = Get-PageString $s1 '__gpuReport' ([long]$judged.reportLength)
      $dataText = Get-PageString $s1 '__gpuData' ([long]$judged.dataLength)
    }
    $s2 = Open-Tab ([Uri](Join-Path $CheckDir 'gpu-check.html')).AbsoluteUri
    $page = ConvertFrom-Json ([string](Invoke-Js $s2 'window.gpuCheck.then(r => JSON.stringify(r))' 120))
  } catch {
    Write-Line 'FAIL' 'the check itself' $_.Exception.Message
  } finally {
    if (-not $KeepOpen) {
      try { Invoke-Cdp 'Browser.close' @{} '' 10 | Out-Null } catch { }
      if (-not $proc.WaitForExit(15000)) { try { $proc.Kill() } catch { } }
    }
  }
  $log = ''
  try { $log = [IO.File]::ReadAllText((Join-Path $CheckProfile 'chrome_debug.log')) } catch { }
  if ($judged) { foreach ($l in @($judged.lines)) { Write-Line $l.verdict $l.key $l.text } }
  foreach ($l in ($log -split "`r?`n")) {
    if ($l -match "GPU process (has crashed|exited unexpectedly|isn't usable)|Exiting GPU process|GPU process launch failed") {
      $t = $l.Trim(); if ($t.Length -gt 300) { $t = $t.Substring(0, 300) }
      Write-Line '--' 'browser log' $t
    }
  }
  if ($page) { foreach ($l in @($page.lines)) { Write-Line $l.verdict $l.key $l.text } }

  $tag = ''
  if ($cur.edge) { $tag = 'edge-' }
  $report = Join-Path $Reports ('gpu-check-' + $tag + $started.ToString('yyyyMMdd-HHmmss') + '.txt')
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine('GPU check, ' + $started.ToString('yyyy-MM-dd HH:mm:ss'))
  [void]$sb.AppendLine("Browser: $($cur.exe) ($($cur.build))")
  [void]$sb.AppendLine("Switches: $argLine")
  [void]$sb.AppendLine('')
  foreach ($l in $script:Lines) { [void]$sb.AppendLine($l) }
  [void]$sb.AppendLine(''); [void]$sb.AppendLine('==== chrome://gpu, as its own report ===='); [void]$sb.AppendLine($reportText)
  [void]$sb.AppendLine(''); [void]$sb.AppendLine('==== chrome://gpu, the data (JSON) ===='); [void]$sb.AppendLine($dataText)
  [void]$sb.AppendLine(''); [void]$sb.AppendLine('==== DevTools SystemInfo.getInfo (JSON) ===='); [void]$sb.AppendLine($sysText)
  $gpuLog = @($log -split "`r?`n" | Where-Object { $_ -match 'gpu|angle|d3d|dxgi|vulkan|egl' } | Select-Object -Last 200)
  [void]$sb.AppendLine(''); [void]$sb.AppendLine('==== browser log, GPU lines (last 200) ===='); [void]$sb.AppendLine(($gpuLog -join "`r`n"))
  [IO.File]::WriteAllText($report, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))

  $failed = @($script:Lines | Where-Object { $_.StartsWith('FAIL') }).Count
  Write-Host ''
  if ($failed) { Write-Host "$failed line(s) FAIL - report: $report" -ForegroundColor Red }
  else { Write-Host "every checked line ok - report: $report" -ForegroundColor Green }
  if ($judged -and $judged.pin) {
    Write-Host ''
    Write-Host 'To draw on the NVIDIA card, add this line to flags.txt and run check.cmd again:' -ForegroundColor Yellow
    Write-Host "  $($judged.pin)" -ForegroundColor Yellow
  }
  if ($failed) { return 1 }
  return 0
}

# ------------------------------------------------------------------------------------------------ reset, status, forget

function Invoke-Reset([string[]]$Rest) {
  $dir = $ProfileDir
  if (@($Rest | Where-Object { $_ -eq 'edge' }).Count) {
    $dir = $EdgeProfileDir
    if (@(Get-Process -Name msedge -ErrorAction SilentlyContinue).Count) { throw 'close Microsoft Edge first (all of its windows)' }
  } elseif ((Get-OwnChromes).Count) { throw 'this Chromium is still running: close it first' }
  $names = 'GPUCache', 'ShaderCache', 'GrShaderCache', 'GraphiteDawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache'
  $n = 0
  foreach ($base in @($dir, (Join-Path $dir 'Default'))) {
    foreach ($name in $names) {
      $p = Join-Path $base $name
      if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force; Write-Host "emptied $p"; $n++ }
    }
  }
  if (-not $n) { Write-Host 'no GPU cache in the profile (nothing to empty)' }
}

function Invoke-Status {
  $cur = Get-Current
  if ($cur) { Write-Line '--' 'build' "$($cur['build']), fetched $($cur['fetched'])"; Write-Line '--' 'chrome.exe' $cur['exe'] }
  else { Write-Line 'FAIL' 'build' 'none yet: run update.cmd' }
  foreach ($f in @(Read-Flags)) { Write-Line '--' 'switch (flags.txt)' $f }
  if ($cur) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($GpuPrefKey)
    $v = $null
    if ($k) { $v = $k.GetValue($cur['exe']); $k.Close() }
    Write-Line '--' 'Windows graphics setting' ($(if ($v) { "$v (2 = High performance)" } else { 'none for this chrome.exe' }))
  }
  $edge = Find-Edge
  Write-Line '--' 'Microsoft Edge' ($(if ($edge) { "$edge ($((Get-Item -LiteralPath $edge).VersionInfo.ProductVersion)) - run.cmd edge / check.cmd edge" } else { 'not found' }))
  Show-Windows
}

function Invoke-Forget {
  $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($GpuPrefKey, $true)
  if (-not $k) { Write-Host 'no Windows graphics settings at all'; return }
  $n = 0
  foreach ($name in $k.GetValueNames()) {
    if ($name.StartsWith($Builds, [StringComparison]::OrdinalIgnoreCase)) { $k.DeleteValue($name); Write-Host "forgot $name"; $n++ }
  }
  $k.Close()
  if (-not $n) { Write-Host 'none was made from this folder' }
}

# ------------------------------------------------------------------------------------------------ the command

$command = 'help'
if ($ScriptArgs.Count) { $command = ([string]$ScriptArgs[0]).ToLowerInvariant() }
$rest = @()
if ($ScriptArgs.Count -gt 1) { $rest = @($ScriptArgs[1..($ScriptArgs.Count - 1)] | ForEach-Object { [string]$_ }) }
$code = 0
try {
  switch ($command) {
    'update' { Invoke-Update ($rest | Select-Object -First 1) }
    'run' { Invoke-Run $rest }
    'check' { $code = Invoke-Check $rest }
    'reset' { Invoke-Reset $rest }
    'status' { Invoke-Status }
    'forget' { Invoke-Forget }
    default {
      Write-Host 'antiblock.ps1 update [stable|beta|dev|canary|MILESTONE|VERSION] | run [edge] [URL] [--switch] | check [edge] [keep] [--switch] | reset [edge] | status | forget'
      Write-Host 'The .cmd files beside it do the same with a double-click. README.md says what each part does.'
    }
  }
} catch {
  Write-Host ('FAIL ' + $_.Exception.Message) -ForegroundColor Red
  $code = 2
}
exit $code
