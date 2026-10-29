<#
.SYNOPSIS
  install.ps1: the one line installer for BenchBar on Windows.

.DESCRIPTION
    irm https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1 | iex

  What it does, in this order, and says so before each step:
    1. checks the CPU (amd64 or arm64)
    2. finds the release on GitHub (the latest, or -Version)
    3. downloads the zip and its checksums, checks the zip's SHA256 and
       unpacks it into a temporary folder
    4. copies it to %LOCALAPPDATA%\Programs\BenchBar (a re-run updates in
       place; it asks to close a running tray app first)
    5. runs "benchbar.exe path install" to put that folder on your user PATH
    6. unless -NoTray: checks the .NET 10 Desktop Runtime for the tray app and
       offers a Startup shortcut for it
    7. runs "benchbar.exe doctor" and prints what it says

  By hand, without a GitHub release (a test build you were sent):
    - unpack the zip, then in that folder:
        powershell -ExecutionPolicy Bypass -File .\install.ps1
      run like this, from a folder that holds benchbar.exe and SHA256SUMS, it
      installs the build in that folder instead of downloading one
    - or keep the zip and point at it:
        powershell -ExecutionPolicy Bypass -File .\install.ps1 -Zip .\benchbar-windows-X-amd64.zip
  Either way every file is checked against the SHA256SUMS inside the zip.

  It installs per user and never asks for administrator rights. It never
  writes anything inside a WSL distro and never runs "wsl --shutdown". The
  final doctor starts the distro if it is stopped. Your benches, sites and
  databases stay where they are.

  The binaries are unsigned until the code signing application is approved,
  so Windows SmartScreen may warn the first time you run them (More info,
  then Run anyway). With Smart App Control on, an unsigned program can be
  blocked outright; the README in the zip says which programs are signed.

  When piped into iex there is no way to pass parameters, so these
  environment variables work too (set them first):
    BENCHBAR_VERSION=0.8.0   the same as -Version
    BENCHBAR_NO_TRAY=1       the same as -NoTray
    BENCHBAR_YES=1           the same as -Yes
    BENCHBAR_ZIP=PATH        the same as -Zip
    BENCHBAR_SOURCE=DIR      the same as -Source (CI only)

.PARAMETER Version
  Install this release (X.Y.Z) instead of the latest.

.PARAMETER NoTray
  Install only benchbar.exe and README.txt: no tray app, no runtime check, no
  Startup shortcut.

.PARAMETER Yes
  Accept every default, ask nothing. A running tray app from the install
  folder is closed (by its exact path) and started again at the end.

.PARAMETER Zip
  Install this zip (benchbar-windows-VERSION-ARCH.zip) instead of downloading
  one. A checksums file next to it (the release's benchbar-windows-VERSION-
  SHA256SUMS.txt, or sums-ARCH.txt from a workflow artifact) is checked too.

.PARAMETER Source
  For CI and tests only: take the zip and the checksums file from this
  folder instead of GitHub.
#>

# The whole script runs in one script block, called at the very end with the
# command line arguments. Piped into iex it therefore defines no variable and
# no function in your session and cannot overwrite yours. (A top level param
# block would leave $Version, $Yes and the rest behind.)
& {
  param(
    [string]$Version = '',
    [switch]$NoTray,
    [switch]$Yes,
    [string]$Source = '',
    [string]$Zip = ''
  )

function Install-BenchBar {
  [CmdletBinding()]
  param(
    [string]$Version = '',
    [switch]$NoTray,
    [switch]$Yes,
    [string]$Source = '',
    [string]$Zip = ''
  )

  # scoped to this function, so piping into iex leaves your session alone
  Set-StrictMode -Version 3
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'   # Windows PowerShell 5.1 downloads crawl with the progress bar
  if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  }

  $repoApi = 'https://api.github.com/repos/askysh/benchbar'
  $startFailedMarker = 'BENCHBAR_START_FAILED: '

  # ------------------------------------------------------------ output
  function Say-Step([string]$Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
  function Say-Ok([string]$Text)   { Write-Host '  [OK] ' -ForegroundColor Green -NoNewline; Write-Host $Text }
  function Say-Warn([string]$Text) { Write-Host '  [WARN] ' -ForegroundColor Yellow -NoNewline; Write-Host $Text }
  function Say-Info([string]$Text) { Write-Host "  .. $Text" -ForegroundColor DarkGray }
  function Stop-Install([string]$Text, [string]$Fix = '') {
    $message = $Text
    if ($Fix) { $message = "$Text`n  fix: $Fix" }
    throw $message
  }

  function Test-Flag([string]$Value) {
    if ($null -eq $Value) { return $false }
    $v = $Value.Trim().ToLowerInvariant()
    return ($v -ne '' -and $v -ne '0' -and $v -ne 'false' -and $v -ne 'no')
  }

  # Confirm-Choice QUESTION DEFAULT: -Yes and a missing terminal take the default
  function Confirm-Choice([string]$Question, [bool]$Default) {
    if ($Yes) { Say-Info "auto: $Question -> $(if ($Default) { 'yes' } else { 'no' })"; return $Default }
    if ([Console]::IsInputRedirected) { Say-Info "no terminal: $Question -> $(if ($Default) { 'yes' } else { 'no' })"; return $Default }
    $hint = '[y/N]'
    if ($Default) { $hint = '[Y/n]' }
    $answer = Read-Host "  $Question $hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return ($answer.Trim() -match '^[Yy]')
  }

  # Invoke-Exe EXE ARGS...: prints the output indented, returns the exit code.
  # Windows PowerShell 5.1 turns native stderr into a terminating error under
  # 'Stop', so this runs with 'Continue'.
  function Invoke-Exe([string]$Exe, [string[]]$ExeArgs) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      & $Exe @ExeArgs 2>&1 | ForEach-Object { Write-Host "      $_" }
      return $LASTEXITCODE
    } catch {
      # the program did not start at all (not an exit code): Smart App Control
      # or an antivirus (Win32 error 4551, 0x800711C7) or something else
      $detail = ($_.Exception.Message -replace '(?s)\s*At [A-Za-z]:[\\/].*$', '').Trim()
      throw ("$startFailedMarker" + (Get-StartFailureText (Split-Path -Leaf $Exe) $detail))
    } finally {
      $ErrorActionPreference = $previous
    }
  }

  function Get-StartFailureText([string]$Name, [string]$Detail) {
    return ("$Name could not be started: $Detail`n" +
      "  This is most likely Smart App Control (Windows Security, App and browser control) or an antivirus blocking the file ('Application Control policy blocked this file', error 0x800711C7 or 4551).`n" +
      "  The BenchBar programs are unsigned until the code signing application is approved, and Smart App Control blocks unsigned programs.`n" +
      "  The files are in place, but the PATH was not changed. Allow the file in your antivirus, or turn Smart App Control off (it cannot be turned back on without reinstalling Windows), then run the installer again.")
  }

  function Get-JsonFromGitHub([string]$Url) {
    $headers = @{ 'User-Agent' = 'benchbar-install.ps1'; 'Accept' = 'application/vnd.github+json' }
    try {
      return Invoke-RestMethod -Uri $Url -Headers $headers
    } catch {
      $status = 0
      if ($_.Exception -and ($_.Exception.PSObject.Properties.Name -contains 'Response') -and $_.Exception.Response) {
        $status = [int]$_.Exception.Response.StatusCode
      }
      if ($status -eq 404) { return $null }
      if ($status -eq 403 -or $status -eq 429) {
        Stop-Install 'GitHub refused the request (rate limit?).' 'wait a few minutes and run the installer again, or download the zip from https://github.com/askysh/benchbar/releases'
      }
      Stop-Install "Could not reach GitHub: $($_.Exception.Message)" 'check your network and run the installer again'
    }
  }

  function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  }

  # Copy-IntoPlace SRC DST: a running exe cannot be overwritten but can be
  # renamed, so a locked file moves aside to NAME.old (removed on the next run)
  # Checks every file listed in the folder's SHA256SUMS (written when the zip
  # was built) and refuses a program file the list does not name.
  function Test-InnerSums([string]$Folder) {
    $list = Join-Path $Folder 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $list)) { Stop-Install "SHA256SUMS is missing from the build in $Folder; refusing to install unchecked files." }
    $root = (Resolve-Path -LiteralPath $Folder).Path.TrimEnd('\')
    $listed = @{}
    foreach ($line in Get-Content -LiteralPath $list) {
      $m = [regex]::Match($line, '^\s*([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$')
      if (-not $m.Success) { continue }
      $rel = $m.Groups[2].Value.Replace('/', '\')
      $listed[$rel.ToLowerInvariant()] = $true
      $path = Join-Path $root $rel
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-Install "$rel is missing from the build in $Folder." 'unpack the whole zip again' }
      if ((Get-FileSha256 $path) -ne $m.Groups[1].Value.ToLowerInvariant()) { Stop-Install "$rel does not match SHA256SUMS; refusing to install." 'download and unpack the zip again' }
    }
    $strangers = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll' } |
        ForEach-Object { $_.FullName.Substring($root.Length + 1) } | Where-Object { -not $listed.ContainsKey($_.ToLowerInvariant()) })
    if ($strangers.Count -gt 0) { Stop-Install "Program files that SHA256SUMS does not list: $($strangers -join ', '); refusing to install." 'unpack the zip into an empty folder' }
    Say-Ok "$($listed.Count) files match SHA256SUMS"
  }

  function Copy-IntoPlace([string]$From, [string]$To) {
    $dir = Split-Path -Parent $To
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    try {
      Copy-Item -LiteralPath $From -Destination $To -Force
    } catch {
      if (-not (Test-Path -LiteralPath $To)) { throw }
      $old = "$To.old"
      Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
      Move-Item -LiteralPath $To -Destination $old -Force
      Copy-Item -LiteralPath $From -Destination $To -Force
      Say-Info "$(Split-Path -Leaf $To) was in use: the old copy is now $(Split-Path -Leaf $old)"
    }
  }

  function Test-DotNetDesktop10 {
    # the same two places "benchbar.exe doctor" looks, so the two agree
    $roots = @($env:DOTNET_ROOT, $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'dotnet' })) | Where-Object { $_ }
    foreach ($root in $roots) {
      $shared = Join-Path $root.TrimEnd('\', '/') 'shared\Microsoft.WindowsDesktop.App'
      if ((Test-Path -LiteralPath $shared) -and (Get-ChildItem -LiteralPath $shared -Directory -Filter '10.*' -ErrorAction SilentlyContinue)) { return $true }
    }
    return $false
  }

  # ------------------------------------------------------------ settings
  if (-not $Version -and $env:BENCHBAR_VERSION) { $Version = $env:BENCHBAR_VERSION }
  if (-not $NoTray -and (Test-Flag $env:BENCHBAR_NO_TRAY)) { $NoTray = [switch]$true }
  if (-not $Yes -and (Test-Flag $env:BENCHBAR_YES)) { $Yes = [switch]$true }
  if (-not $Source -and $env:BENCHBAR_SOURCE) { $Source = $env:BENCHBAR_SOURCE }
  if (-not $Zip -and $env:BENCHBAR_ZIP) { $Zip = $env:BENCHBAR_ZIP }
  # Run as a file from an unpacked zip (benchbar.exe and SHA256SUMS beside the
  # script) and given nothing else: install the build in this folder.
  $fromFolder = ''
  if ($PSScriptRoot -and -not $Zip -and -not $Source -and -not $Version -and
      (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'benchbar.exe')) -and
      (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'SHA256SUMS'))) {
    $fromFolder = $PSScriptRoot
  }
  if ($Version) {
    $Version = $Version.Trim()
    if ($Version -notmatch '^v?\d+\.\d+\.\d+$') { Stop-Install "'$Version' is not a version." 'use X.Y.Z, for example -Version 0.8.0' }
    $Version = $Version.TrimStart('v')
  }

  # ------------------------------------------------------------ 1. architecture
  Say-Step 'Checking this PC'
  # the CPU of the machine, not of this process: x64 PowerShell running
  # emulated on Arm64 must still get the arm64 zip
  $cpu = ''
  try { $cpu = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { $cpu = '' }
  if (-not $cpu) {
    # older Windows PowerShell 5.1 without that type: the environment, then the registry
    $cpu = $env:PROCESSOR_ARCHITEW6432
    if (-not $cpu) { $cpu = $env:PROCESSOR_ARCHITECTURE }
  }
  if ($cpu -match '^(X64|AMD64)$') {
    # an emulated process can report X64 on an Arm64 PC; the machine's own value is in the registry
    try {
      $native = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name 'PROCESSOR_ARCHITECTURE' -ErrorAction Stop).PROCESSOR_ARCHITECTURE
      if ($native -match '^ARM64$') { $cpu = 'ARM64' }
    } catch { }
  }
  $arch = ''
  switch -Regex ("$cpu") {
    '^(X64|AMD64)$' { $arch = 'amd64' }
    '^ARM64$' { $arch = 'arm64' }
  }
  if (-not $arch) { Stop-Install "BenchBar for Windows needs a 64 bit Intel/AMD or ARM processor; this one reports '$cpu'." }
  Say-Ok "Windows on $arch"

  $installDir = Join-Path $env:LOCALAPPDATA 'Programs\BenchBar'
  $installExe = Join-Path $installDir 'benchbar.exe'
  $trayExe = Join-Path $installDir 'BenchBarTray.exe'

  $work = Join-Path ([IO.Path]::GetTempPath()) ('benchbar-install-' + [guid]::NewGuid().ToString('N'))
  $restartTray = $false
  $trayStarted = $false
  $installed = $false

  try {
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    # ---------------------------------------------------------- 2. release
    $zipName = ''
    $sumsName = ''
    $zipUrl = ''
    $sumsUrl = ''
    $releaseVersion = 'unknown'
    $staging = Join-Path $work 'staging'
    if ($fromFolder) {
      # run from an unpacked zip: install what is in this folder
      Say-Step "Installing the build unpacked in $fromFolder"
      if ((Resolve-Path -LiteralPath $fromFolder).Path.TrimEnd('\') -ieq $installDir.TrimEnd('\')) {
        Stop-Install 'This is the install folder itself.' 'unpack the zip somewhere else (Downloads is fine) and run its install.ps1 from there'
      }
      $readmePath = Join-Path $fromFolder 'README.txt'
      if (Test-Path -LiteralPath $readmePath) {
        $head = [regex]::Match((Get-Content -LiteralPath $readmePath -TotalCount 1), 'BenchBar for Windows (\S+) \((amd64|arm64)\)')
        if ($head.Success) {
          $releaseVersion = $head.Groups[1].Value
          if ($head.Groups[2].Value -ne $arch) { Stop-Install "This build is for $($head.Groups[2].Value), this PC is $arch." "download benchbar-windows-$releaseVersion-$arch.zip instead" }
        }
      }
      $staging = $fromFolder
      Say-Ok "build $releaseVersion"
    } elseif ($Zip) {
      # a zip downloaded by hand (a release asset, or a workflow artifact you were sent)
      Say-Step "Checking the zip $Zip"
      if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { Stop-Install "There is no file '$Zip'." }
      $zipFull = (Resolve-Path -LiteralPath $Zip).Path
      $zipName = Split-Path -Leaf $zipFull
      $found = [regex]::Match($zipName, '^benchbar-windows-(.+)-(amd64|arm64)\.zip$')
      if (-not $found.Success) { Stop-Install "'$zipName' is not a BenchBar Windows zip (benchbar-windows-VERSION-ARCH.zip)." }
      $releaseVersion = $found.Groups[1].Value
      if ($found.Groups[2].Value -ne $arch) { Stop-Install "$zipName is for $($found.Groups[2].Value), this PC is $arch." "use benchbar-windows-$releaseVersion-$arch.zip" }
      # a checksums file next to it is checked when there is one: the release's, or a workflow artifact's
      $zipDir = Split-Path -Parent $zipFull
      $sumsPath = ''
      foreach ($candidate in @("benchbar-windows-$releaseVersion-SHA256SUMS.txt", "sums-$arch.txt")) {
        $p = Join-Path $zipDir $candidate
        if (Test-Path -LiteralPath $p) { $sumsPath = $p; $sumsName = $candidate; break }
      }
      if ($sumsPath) {
        $expected = ''
        foreach ($line in Get-Content -LiteralPath $sumsPath) {
          $m = [regex]::Match($line, '^\s*([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$')
          if ($m.Success -and $m.Groups[2].Value -eq $zipName) { $expected = $m.Groups[1].Value.ToLowerInvariant(); break }
        }
        if (-not $expected) { Stop-Install "$sumsName has no line for $zipName; refusing to install an unchecked file." }
        $actual = Get-FileSha256 $zipFull
        if ($actual -ne $expected) { Stop-Install "SHA256 of $zipName does not match $sumsName (expected $expected, got $actual); refusing to install." 'download the zip again' }
        Say-Ok "SHA256 matches $sumsName ($($actual.Substring(0, 12))...)"
      } else {
        Say-Warn "No checksums file next to the zip: only the zip's own SHA256SUMS is checked, which finds a damaged download, not a swapped one. Install zips only from someone you trust."
      }
      Expand-Archive -LiteralPath $zipFull -DestinationPath $staging -Force
      if (-not (Test-Path -LiteralPath (Join-Path $staging 'benchbar.exe'))) { Stop-Install "$zipName holds no benchbar.exe." }
      Say-Ok 'Unpacked'
    } elseif ($Source) {
      Say-Step "Looking for the release files in $Source (test mode)"
      if (-not (Test-Path -LiteralPath $Source -PathType Container)) { Stop-Install "-Source folder '$Source' does not exist." }
      $zips = @(Get-ChildItem -LiteralPath $Source -File -Filter "benchbar-windows-*-$arch.zip")
      if ($zips.Count -ne 1) { Stop-Install "Expected one benchbar-windows-*-$arch.zip in $Source, found $($zips.Count)." }
      $zipName = $zips[0].Name
      $found = [regex]::Match($zipName, '^benchbar-windows-(.+)-(amd64|arm64)\.zip$')
      if (-not $found.Success) { Stop-Install "'$zipName' is not a BenchBar Windows zip." }
      $releaseVersion = $found.Groups[1].Value
      $sumsName = "benchbar-windows-$releaseVersion-SHA256SUMS.txt"
      if (-not (Test-Path -LiteralPath (Join-Path $Source $sumsName))) { Stop-Install "$sumsName is missing from $Source." }
      Say-Ok "$zipName"
    } else {
      Say-Step 'Looking for the release on GitHub'
      if ($Version) { $apiUrl = "$repoApi/releases/tags/v$Version" } else { $apiUrl = "$repoApi/releases/latest" }
      $release = Get-JsonFromGitHub $apiUrl
      if ($null -eq $release) {
        if ($Version) { Stop-Install "There is no release v$Version." 'see https://github.com/askysh/benchbar/releases' }
        Stop-Install 'There is no published release yet.' 'see https://github.com/askysh/benchbar/releases'
      }
      $tag = [string]$release.tag_name
      $releaseVersion = $tag.TrimStart('v')
      $zipName = "benchbar-windows-$releaseVersion-$arch.zip"
      $sumsName = "benchbar-windows-$releaseVersion-SHA256SUMS.txt"
      $assets = @($release.assets)
      $zipAsset = $assets | Where-Object { $_.name -eq $zipName } | Select-Object -First 1
      $sumsAsset = $assets | Where-Object { $_.name -eq $sumsName } | Select-Object -First 1
      if (-not $zipAsset -or -not $sumsAsset) {
        Stop-Install "Release $tag has no Windows build ($zipName)." 'Windows builds start with a later release. See https://benchbar.akashmishra.com/windows/'
      }
      $zipUrl = [string]$zipAsset.browser_download_url
      $sumsUrl = [string]$sumsAsset.browser_download_url
      Say-Ok "$tag, $zipName"
    }

    # ---------------------------------------------------------- 3. download, verify, unpack
    if (-not $fromFolder -and -not $Zip) {
    Say-Step 'Downloading and checking the files'
    $zipPath = Join-Path $work $zipName
    $sumsPath = Join-Path $work $sumsName
    if ($Source) {
      Copy-Item -LiteralPath (Join-Path $Source $zipName) -Destination $zipPath
      Copy-Item -LiteralPath (Join-Path $Source $sumsName) -Destination $sumsPath
    } else {
      $webHeaders = @{ 'User-Agent' = 'benchbar-install.ps1' }
      try {
        Invoke-WebRequest -Uri $sumsUrl -OutFile $sumsPath -Headers $webHeaders -UseBasicParsing
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -Headers $webHeaders -UseBasicParsing
      } catch {
        Stop-Install "Download failed: $($_.Exception.Message)" 'check your network and run the installer again'
      }
    }
    $expected = ''
    foreach ($line in Get-Content -LiteralPath $sumsPath) {
      $m = [regex]::Match($line, '^\s*([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$')
      if ($m.Success -and $m.Groups[2].Value -eq $zipName) { $expected = $m.Groups[1].Value.ToLowerInvariant(); break }
    }
    if (-not $expected) { Stop-Install "$sumsName has no line for $zipName; refusing to install an unchecked file." }
    $actual = Get-FileSha256 $zipPath
    if ($actual -ne $expected) { Stop-Install "SHA256 of $zipName does not match $sumsName (expected $expected, got $actual); refusing to install." 'run the installer again; if it repeats, report it at https://github.com/askysh/benchbar/issues' }
    Say-Ok "SHA256 matches ($($actual.Substring(0, 12))...)"

    Expand-Archive -LiteralPath $zipPath -DestinationPath $staging -Force
    if (-not (Test-Path -LiteralPath (Join-Path $staging 'benchbar.exe'))) { Stop-Install "$zipName holds no benchbar.exe." }
    Say-Ok 'Unpacked'
    }

    # every file against the SHA256SUMS inside the zip: a damaged download or a
    # half unpacked folder stops here
    Test-InnerSums $staging

    # ---------------------------------------------------------- 4. install
    Say-Step "Installing to $installDir"
    $stagingRoot = (Resolve-Path -LiteralPath $staging).Path.TrimEnd('\')
    $files = @(Get-ChildItem -LiteralPath $stagingRoot -Recurse -File | ForEach-Object { $_.FullName.Substring($stagingRoot.Length + 1) })
    if ($NoTray) { $files = @($files | Where-Object { $_ -eq 'benchbar.exe' -or $_ -eq 'README.txt' }) }

    if (-not $NoTray -and (Test-Path -LiteralPath $trayExe)) {
      # only a process running this exact file; a name match alone is not enough
      $running = @(Get-Process -Name 'BenchBarTray' -ErrorAction SilentlyContinue | Where-Object {
          $path = $null
          try { $path = $_.Path } catch { }
          $path -and ($path -ieq $trayExe)
        })
      if ($running.Count -gt 0) {
        Say-Warn 'The tray app from this folder is running.'
        if (-not (Confirm-Choice 'Close it so it can be updated? (it starts again at the end)' $true)) {
          Stop-Install 'The tray app has to be closed to update it.' 'close BenchBar Tray from the tray, then run the installer again'
        }
        foreach ($p in $running) { Stop-Process -Id $p.Id -Force }
        foreach ($p in $running) { $null = $p.WaitForExit(10000) }
        $restartTray = $true
      }
    }

    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Get-ChildItem -LiteralPath $installDir -Recurse -File -Filter '*.old' -ErrorAction SilentlyContinue |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    $manifestPath = Join-Path $installDir '.installed-files.txt'
    $previous = @()
    if (Test-Path -LiteralPath $manifestPath) { $previous = @(Get-Content -LiteralPath $manifestPath | Where-Object { $_ }) }

    foreach ($rel in $files) {
      Copy-IntoPlace (Join-Path $stagingRoot $rel) (Join-Path $installDir $rel)
    }
    Say-Ok "$($files.Count) files copied"

    # remove what the new zip no longer has: only files an earlier run of this
    # installer wrote (its manifest), only inside the install folder
    if (-not $NoTray) {
      $installRoot = [IO.Path]::GetFullPath($installDir).TrimEnd('\') + '\'
      $removed = 0
      foreach ($rel in $previous) {
        if ($files -contains $rel) { continue }
        $target = [IO.Path]::GetFullPath((Join-Path $installDir $rel))
        if (-not $target.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue; $removed++ }
      }
      if ($removed -gt 0) { Say-Ok "$removed files from the old version removed" }
    }
    if (-not $NoTray -or -not (Test-Path -LiteralPath $manifestPath)) {
      [IO.File]::WriteAllText($manifestPath, (($files | Sort-Object) -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $false))
    }
    $installed = $true

    # ---------------------------------------------------------- 5. PATH
    Say-Step 'Putting the install folder on your user PATH'
    $code = Invoke-Exe $installExe @('path', 'install')
    if ($code -eq 0) {
      Say-Ok 'Open a new terminal to use "benchbar" (open terminals keep the old PATH)'
    } else {
      Say-Warn "benchbar.exe path install exited with $code. Add $installDir to your user PATH yourself."
    }

    # ---------------------------------------------------------- 6. tray
    if ($NoTray) {
      Say-Step 'Tray app'
      Say-Info 'skipped (-NoTray)'
    } else {
      Say-Step 'Checking what the tray app needs'
      if (-not (Test-Path -LiteralPath $trayExe)) {
        Say-Warn 'This download has no tray app.'
      } else {
        if (Test-DotNetDesktop10) {
          Say-Ok '.NET 10 Desktop Runtime found'
        } else {
          Say-Warn 'The .NET 10 Desktop Runtime is missing. The tray app will not start until it is installed:'
          Write-Host '      winget install Microsoft.DotNet.DesktopRuntime.10'
        }

        $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
        $lnk = Join-Path $startup 'BenchBar Tray.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $needLink = $true
        if (Test-Path -LiteralPath $lnk) {
          $existing = $shell.CreateShortcut($lnk)
          if ($existing.TargetPath -ieq $trayExe) { $needLink = $false }
        }
        if ($needLink) {
          if (Confirm-Choice 'Start the tray app when you sign in?' $true) {
            New-Item -ItemType Directory -Force -Path $startup | Out-Null
            $link = $shell.CreateShortcut($lnk)
            $link.TargetPath = $trayExe
            $link.WorkingDirectory = $installDir
            $link.Description = 'BenchBar tray app'
            $link.Save()
            Say-Ok 'Startup shortcut created'
          } else {
            Say-Info 'no Startup shortcut'
          }
        }

        if ($restartTray) {
          Say-Info 'starting the tray app again'
          Start-Process -FilePath $trayExe -WorkingDirectory $installDir
          $trayStarted = $true
        }
      }
    }

    # ---------------------------------------------------------- 7. doctor
    Say-Step 'Running benchbar.exe doctor'
    $doctor = Invoke-Exe $installExe @('doctor')
    if ($doctor -ne 0) {
      Say-Warn 'doctor found something to fix (the lines above say what). The install itself worked.'
    } else {
      Say-Ok 'doctor passes'
    }

    Write-Host ''
    Write-Host "BenchBar $releaseVersion is installed in $installDir." -ForegroundColor Green
    if (-not $NoTray -and (Test-Path -LiteralPath $trayExe)) { Write-Host "Tray app: $trayExe" }
  } catch {
    $message = $_.Exception.Message
    # a tray app this run closed comes back, old or new, whatever failed
    if ($restartTray -and -not $trayStarted -and (Test-Path -LiteralPath $trayExe)) {
      try { Start-Process -FilePath $trayExe -WorkingDirectory $installDir; Say-Info 'started the tray app again' } catch { }
    }
    if ($message.StartsWith($startFailedMarker)) {
      Write-Host "  [FAIL] $($message.Substring($startFailedMarker.Length))" -ForegroundColor Red
      return $false
    }
    if ($installed) {
      Write-Host "  [WARN] The files are installed, but a later step failed: $message" -ForegroundColor Yellow
      return $true
    }
    Write-Host "  [FAIL] $message" -ForegroundColor Red
    return $false
  } finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
  return $true
}

# Never "exit" when piped into iex: that would close your window. Run as a
# file, a failure sets the exit code.
$benchbarOk = $false
try {
  $benchbarOk = Install-BenchBar -Version $Version -NoTray:$NoTray -Yes:$Yes -Source $Source -Zip $Zip
} catch {
  Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
}
# The last native program was doctor, whose exit code says nothing about the install; leave the
# install's own result in $LASTEXITCODE (a CI step or a calling script reads it).
if ($benchbarOk) { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 }
if ($PSCommandPath -and -not $benchbarOk) { exit 1 }

} @args
