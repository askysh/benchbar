<#
.SYNOPSIS
  install.ps1: the one line installer for BenchBar on Windows.

.DESCRIPTION
    irm https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1 | iex

  What it does, in this order, and says so before each step:
    1. checks this PC: the CPU (amd64 or arm64), PowerShell's language mode and
       Smart App Control (it stops before it writes anything when Smart App
       Control is on, because BenchBar is not signed yet)
    2. finds the release on GitHub (the newest published one with a Windows
       zip for your CPU, or -Version)
    3. downloads the zip and its checksums, checks the zip's SHA256 and
       unpacks it into a temporary folder
    4. copies it to %LOCALAPPDATA%\Programs\BenchBar (a re-run updates in
       place; it asks to close a running tray app first) and removes the
       "downloaded from the internet" mark from the installed files
    5. runs "benchbar.exe path install" to put that folder on your user PATH
    6. unless -NoTray: checks the .NET 10 Desktop Runtime for the tray app
       (offers to install it with winget), makes a Start menu shortcut, offers
       a Startup shortcut and starts the tray app
    7. runs "benchbar.exe doctor" and prints what it says, then what to do next

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

  The Windows programs are not signed yet. With Smart App Control on, Windows blocks unsigned programs, so this
  installer stops first and says what to do.

  To remove BenchBar from this PC, run it with -Uninstall. That removes the
  tray app, the keepalive task, the shortcuts, the PATH entry and the files
  in the install folder. It never touches WSL, a distro, your benches or
  %USERPROFILE%\.wslconfig.

  When piped into iex there is no way to pass parameters, so these
  environment variables work too (set them first):
    BENCHBAR_VERSION=0.8.0   the same as -Version
    BENCHBAR_NO_TRAY=1       the same as -NoTray
    BENCHBAR_YES=1           the same as -Yes
    BENCHBAR_ZIP=PATH        the same as -Zip
    BENCHBAR_UNINSTALL=1     the same as -Uninstall
    BENCHBAR_SOURCE=DIR      the same as -Source (CI only)

.PARAMETER Version
  Install this release (X.Y.Z) instead of the latest.

.PARAMETER NoTray
  Install only benchbar.exe and README.txt: no tray app, no runtime check, no
  shortcuts, no tray start.

.PARAMETER Yes
  Accept every default, ask nothing. A running tray app from the install
  folder is closed (by its exact path), the .NET runtime is installed with
  winget when it is missing, and the tray app is started at the end.

.PARAMETER Uninstall
  Remove BenchBar from this PC instead of installing it. Asks once first
  (-Yes skips the question). With no terminal (stdin redirected) and no -Yes
  the answer is no and nothing is removed.

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
    [switch]$Uninstall,
    [string]$Source = '',
    [string]$Zip = ''
  )

function Install-BenchBar {
  [CmdletBinding()]
  param(
    [string]$Version = '',
    [switch]$NoTray,
    [switch]$Yes,
    [switch]$Uninstall,
    [string]$Source = '',
    [string]$Zip = ''
  )

  # Constrained Language Mode (a company policy) blocks most of what this
  # script does. Say so before anything else.
  if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    throw ("PowerShell is in $($ExecutionContext.SessionState.LanguageMode) mode, which this installer cannot work in.`n" +
      "  fix: this usually comes from a policy on this PC (AppLocker or App Control). Ask whoever manages the PC, or unpack the zip and run benchbar.exe path install by hand. See https://benchbar.akashmishra.com/windows/#if-windows-blocks-it")
  }

  # scoped to this function, so piping into iex leaves your session alone
  Set-StrictMode -Version 3
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'   # Windows PowerShell 5.1 downloads crawl with the progress bar
  if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  }

  $repoApi = 'https://api.github.com/repos/askysh/benchbar'
  $repoWeb = 'https://github.com/askysh/benchbar'
  $docsBlocked = 'https://benchbar.akashmishra.com/windows/#if-windows-blocks-it'
  $falsePositiveUrl = 'https://www.microsoft.com/wdsi/filesubmission'
  $net = @{ RateLimited = $false }   # set by Get-JsonFromGitHub when GitHub's API says "too many requests"
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

  # Confirm-Choice QUESTION DEFAULT [NOTERMINALDEFAULT]: -Yes takes the default;
  # a missing terminal takes NOTERMINALDEFAULT (the default when not given)
  function Confirm-Choice([string]$Question, [bool]$Default, [object]$NoTerminalDefault = $null) {
    if ($Yes) { Say-Info "auto: $Question -> $(if ($Default) { 'yes' } else { 'no' })"; return $Default }
    if ([Console]::IsInputRedirected) {
      $fallback = $Default
      if ($null -ne $NoTerminalDefault) { $fallback = [bool]$NoTerminalDefault }
      Say-Info "no terminal: $Question -> $(if ($fallback) { 'yes' } else { 'no' })"
      return $fallback
    }
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
      # the program did not start at all (not an exit code): Smart App Control,
      # an antivirus (Win32 error 4551, 0x800711C7; 0x800700E1 for a file it
      # removed) or something else
      $detail = ($_.Exception.Message -replace '(?s)\s*At [A-Za-z]:[\\/].*$', '').Trim()
      $leaf = Split-Path -Leaf $Exe
      if ([IO.Path]::IsPathRooted($Exe) -and -not (Test-Path -LiteralPath $Exe)) {
        throw ("$startFailedMarker" + (Get-AntivirusText "$leaf is gone from the install folder."))
      }
      if (Test-AntivirusMessage $detail) {
        throw ("$startFailedMarker" + (Get-AntivirusText "$leaf was blocked by Windows Security or another antivirus."))
      }
      throw ("$startFailedMarker" + (Get-StartFailureText $leaf $detail))
    } finally {
      $ErrorActionPreference = $previous
    }
  }

  # The text a user sees for an error: without the internal start failed marker.
  function Get-UserMessage($ErrorRecord) {
    $text = [string]$ErrorRecord.Exception.Message
    if ($text.StartsWith($startFailedMarker)) { $text = $text.Substring($startFailedMarker.Length) }
    return $text
  }

  function Get-StartFailureText([string]$Name, [string]$Detail) {
    return ("$Name could not be started: $Detail`n" +
      "  This is most likely Smart App Control (Windows Security, App and browser control) or an antivirus blocking the file ('Application Control policy blocked this file', error 0x800711C7 or 4551).`n" +
      "  The BenchBar programs are not signed yet, and Smart App Control blocks unsigned programs.`n" +
      "  The files are in place, but the PATH was not changed. Allow the file in your antivirus, or turn Smart App Control off (on some versions of Windows you cannot turn it back on without resetting Windows), then run the installer again.`n" +
      "  More: $docsBlocked")
  }

  function Test-AntivirusMessage([string]$Text) {
    return ($Text -match '(?i)virus|potentially unwanted|800700E1')
  }

  function Get-AntivirusText([string]$What) {
    return ("$What`n" +
      "  Windows Security or another antivirus removed or blocked a BenchBar file. BenchBar is not malware, but a new program without a signature is sometimes flagged by mistake.`n" +
      "  Open Windows Security > Virus & threat protection > Protection history, find the BenchBar item, choose Actions > Allow on device, then run the installer again.`n" +
      "  To tell Microsoft it is a false positive: $falsePositiveUrl`n" +
      "  More: $docsBlocked")
  }

  # The proxy settings for a web call. Windows PowerShell 5.1 sends no
  # credentials to a system proxy by itself; this returns arguments that make
  # both 5.1 and PowerShell 7 use the system proxy with your Windows sign in.
  function Get-WebProxyArgs([string]$Url) {
    try {
      $systemProxy = [Net.WebRequest]::GetSystemWebProxy()
      $target = [Uri]$Url
      if ($systemProxy -and -not $systemProxy.IsBypassed($target)) {
        $proxyUri = $systemProxy.GetProxy($target)
        if ($proxyUri -and $proxyUri.AbsoluteUri -ne $target.AbsoluteUri) {
          return @{ Proxy = $proxyUri; ProxyUseDefaultCredentials = $true }
        }
      }
    } catch { }
    return @{}
  }

  function Get-JsonFromGitHub([string]$Url) {
    $headers = @{ 'User-Agent' = 'benchbar-install.ps1'; 'Accept' = 'application/vnd.github+json' }
    $proxyArgs = Get-WebProxyArgs $Url
    try {
      return Invoke-RestMethod -Uri $Url -Headers $headers @proxyArgs
    } catch {
      $status = 0
      if ($_.Exception -and ($_.Exception.PSObject.Properties.Name -contains 'Response') -and $_.Exception.Response) {
        $status = [int]$_.Exception.Response.StatusCode
      }
      if ($status -eq 404) { return $null }
      if ($status -eq 403 -or $status -eq 429) {
        # the caller falls back to the release page, which needs no API call
        $net.RateLimited = $true
        return $null
      }
      Stop-Install "Could not reach GitHub: $($_.Exception.Message)" 'check your network and run the installer again'
    }
  }

  # The tag the "latest release" page redirects to, without the API.
  function Get-LatestTagFromRedirect {
    $location = ''
    try {
      $request = [Net.HttpWebRequest]::Create("$repoWeb/releases/latest")
      $request.AllowAutoRedirect = $false
      $request.UserAgent = 'benchbar-install.ps1'
      $request.Timeout = 30000
      $systemProxy = [Net.WebRequest]::GetSystemWebProxy()
      $systemProxy.Credentials = [Net.CredentialCache]::DefaultCredentials
      $request.Proxy = $systemProxy
      $response = $request.GetResponse()
      try { $location = [string]$response.Headers['Location'] } finally { $response.Dispose() }
    } catch { return '' }
    $m = [regex]::Match($location, '/releases/tag/(v\d+\.\d+\.\d+)$')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
  }

  function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  }

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

  # Copy-IntoPlace SRC DST: a running exe cannot be overwritten but can be
  # renamed, so a locked file moves aside to NAME.old (removed on the next run)
  function Copy-IntoPlace([string]$From, [string]$To) {
    $dir = Split-Path -Parent $To
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    try {
      Copy-Item -LiteralPath $From -Destination $To -Force
    } catch {
      if (Test-AntivirusMessage $_.Exception.Message) {
        throw ("$startFailedMarker" + (Get-AntivirusText "Windows would not let $(Split-Path -Leaf $To) be copied."))
      }
      if (-not (Test-Path -LiteralPath $To)) { throw }
      $old = "$To.old"
      Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
      Move-Item -LiteralPath $To -Destination $old -Force
      Copy-Item -LiteralPath $From -Destination $To -Force
      Say-Info "$(Split-Path -Leaf $To) was in use: the old copy is now $(Split-Path -Leaf $old)"
    }
  }

  # After the copy: an antivirus may have removed a file, or may hold it so
  # that it cannot be read. Say so now, not at the first run.
  function Assert-CopiedFiles([string[]]$Rels) {
    foreach ($rel in $Rels) {
      $path = Join-Path $installDir $rel
      $problem = ''
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $problem = "$rel vanished right after it was copied."
      } else {
        try {
          $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
          $stream.Dispose()
        } catch {
          $problem = "$rel cannot be read right after it was copied (access denied)."
        }
      }
      if ($problem) { throw ("$startFailedMarker" + (Get-AntivirusText $problem)) }
    }
  }

  function Test-DotNetDesktop10 {
    # a test can say what the PC has (CI has no way to remove a runtime)
    if ($env:BENCHBAR_TEST_DOTNET_DESKTOP) { return (Test-Flag $env:BENCHBAR_TEST_DOTNET_DESKTOP) }
    # the places "benchbar.exe doctor" looks, so the two agree. ProgramW6432 is
    # the 64 bit Program Files even from a 32 bit PowerShell, where
    # ProgramFiles points to Program Files (x86).
    $roots = @($env:DOTNET_ROOT,
      $(if ($env:ProgramW6432) { Join-Path $env:ProgramW6432 'dotnet' }),
      $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'dotnet' })) | Where-Object { $_ }
    foreach ($root in $roots) {
      $shared = Join-Path $root.TrimEnd('\', '/') 'shared\Microsoft.WindowsDesktop.App'
      if ((Test-Path -LiteralPath $shared) -and (Get-ChildItem -LiteralPath $shared -Directory -Filter '10.*' -ErrorAction SilentlyContinue)) { return $true }
    }
    return $false
  }

  # Smart App Control: 0 off, 1 on, 2 evaluation, -1 not known (older Windows,
  # or the value is not there). BENCHBAR_TEST_SAC_STATE is for tests only.
  function Get-SmartAppControlState {
    if ($env:BENCHBAR_TEST_SAC_STATE) {
      try { return [int]$env:BENCHBAR_TEST_SAC_STATE } catch { return -1 }
    }
    try {
      $item = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction Stop
      return [int]$item.VerifiedAndReputablePolicyState
    } catch {
      return -1
    }
  }

  # The tray app of this install folder (by its exact path), if it runs.
  function Get-RunningTray {
    return @(Get-Process -Name 'BenchBarTray' -ErrorAction SilentlyContinue | Where-Object {
        $path = $null
        try { $path = $_.Path } catch { }
        $path -and ($path -ieq $trayExe)
      })
  }

  # Ask the tray to close, wait a few seconds, then end it.
  function Stop-BenchBarTray($Running) {
    foreach ($p in $Running) { try { $null = $p.CloseMainWindow() } catch { } }
    foreach ($p in $Running) { try { $null = $p.WaitForExit(5000) } catch { } }
    foreach ($p in $Running) {
      try {
        if (-not $p.HasExited) {
          Stop-Process -Id $p.Id -Force
          $null = $p.WaitForExit(10000)
          # a forced stop leaves the tray's running marker behind, and the tray
          # would report a crash at its next start
          Remove-TrayRunningMarker
        }
      } catch { }
    }
  }

  function Remove-TrayRunningMarker {
    if (-not $env:LOCALAPPDATA) { return }
    $marker = Join-Path $env:LOCALAPPDATA 'BenchBar\running'
    try { if (Test-Path -LiteralPath $marker -PathType Leaf) { Remove-Item -LiteralPath $marker -Force } } catch { }
  }

  function Get-StartMenuLink { return (Join-Path ([Environment]::GetFolderPath('Programs')) 'BenchBar.lnk') }
  function Get-StartupLink { return (Join-Path ([Environment]::GetFolderPath('Startup')) 'BenchBar Tray.lnk') }
  function Get-ResumeLink { return (Join-Path ([Environment]::GetFolderPath('Startup')) 'BenchBar Setup Resume.lnk') }

  # New-TrayShortcut PATH DESCRIPTION: a shortcut to the tray app. Returns
  # $false when one that points to it is already there.
  function New-TrayShortcut([string]$Path, [string]$Description) {
    $shell = New-Object -ComObject WScript.Shell
    if (Test-Path -LiteralPath $Path) {
      $existing = $shell.CreateShortcut($Path)
      if ($existing.TargetPath -ieq $trayExe) { return $false }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $link = $shell.CreateShortcut($Path)
    $link.TargetPath = $trayExe
    $link.WorkingDirectory = $installDir
    $link.Description = $Description
    $link.Save()
    return $true
  }

  # Remove a shortcut that points to this install's tray app. A shortcut with
  # the same name that points somewhere else is not ours and stays.
  # Only a .lnk in the Start menu Programs folder, the Startup folder or the
  # install folder, whose target is the installed tray app. Anything else,
  # including a link that cannot be read, is not ours and stays.
  function Remove-BenchBarShortcut([string]$Path) {
    $full = ''
    try { $full = [IO.Path]::GetFullPath($Path) } catch { Say-Info "$Path is not a usable path, so it is not ours: left alone"; return $false }
    if (-not $full.EndsWith('.lnk', [StringComparison]::OrdinalIgnoreCase)) { Say-Info "$full is not a shortcut file, so it is not ours: left alone"; return $false }
    $parent = ([IO.Path]::GetDirectoryName($full)).TrimEnd('\')
    $allowed = @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Startup'), $installDir) |
      Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    if (-not ($allowed | Where-Object { $_ -ieq $parent })) { Say-Info "$full is not in the Start menu, the Startup folder or the install folder, so it is not ours: left alone"; return $false }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
    $target = ''
    try { $target = [string](New-Object -ComObject WScript.Shell).CreateShortcut($full).TargetPath } catch { }
    if (-not $target) { Say-Info "$full cannot be read or has no target, so it is not ours: left alone"; return $false }
    if ($target -ine $trayExe) { Say-Info "$full points to $target, so it is not ours: left alone"; return $false }
    Remove-Item -LiteralPath $full -Force
    return $true
  }

  # Remove the install folder from the user PATH. Written through the registry
  # so a %VARIABLE% in another entry stays as it is.
  function Remove-InstallDirFromUserPath {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if ($null -eq $key) { return $false }
    try {
      $current = $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
      if ($null -eq $current) { return $false }
      $kind = $key.GetValueKind('Path')
      $want = [IO.Path]::GetFullPath($installDir).TrimEnd('\')
      $kept = @()
      $dropped = 0
      foreach ($entry in ([string]$current).Split(';')) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\')
        $same = $false
        if ($expanded) { try { $same = ([IO.Path]::GetFullPath($expanded).TrimEnd('\') -ieq $want) } catch { } }
        if ($same) { $dropped++ } else { $kept += $entry }
      }
      if ($dropped -eq 0) { return $false }
      $key.SetValue('Path', ($kept -join ';'), $kind)
    } finally {
      $key.Dispose()
    }
    # setting a user variable tells running programs the environment changed
    try { [Environment]::SetEnvironmentVariable('BENCHBAR_PATH_REFRESH', $null, 'User') } catch { }
    return $true
  }

  # -Uninstall: BenchBar only. Never WSL, a distro, a bench or .wslconfig.
  function Invoke-BenchBarUninstall {
    Say-Step 'Removing BenchBar from this PC'
    Say-Info "install folder: $installDir"
    Say-Info 'This removes the tray app, the keepalive task, the shortcuts, the PATH entry and the BenchBar files.'
    Say-Info 'It does not touch WSL, your Linux distro, your benches or %USERPROFILE%\.wslconfig.'
    if (-not (Confirm-Choice 'Remove BenchBar now?' $true $false)) {
      Say-Info 'nothing was changed. To remove without being asked, run the installer again with -Yes (or set BENCHBAR_YES=1).'
      return $true
    }

    $running = @(Get-RunningTray)
    if ($running.Count -gt 0) {
      Stop-BenchBarTray $running
      Say-Ok 'tray app closed'
    }
    Remove-TrayRunningMarker

    if (Test-Path -LiteralPath $installExe) {
      try {
        $code = Invoke-Exe $installExe @('keepalive', 'remove')
        if ($code -eq 0) { Say-Ok 'keepalive task removed' } else { Say-Warn "benchbar.exe keepalive remove exited with $code. See the lines above. You can also delete the 'BenchBar Keepalive' task in Task Scheduler." }
      } catch {
        Say-Warn "Could not run benchbar.exe to remove the keepalive task: $(Get-UserMessage $_)"
      }
    }

    # shortcuts: the ones this installer wrote down, and the usual names
    $links = @((Get-StartMenuLink), (Get-StartupLink), (Get-ResumeLink))
    $linkList = Join-Path $installDir '.installed-shortcuts.txt'
    if (Test-Path -LiteralPath $linkList) { $links += @(Get-Content -LiteralPath $linkList | Where-Object { $_ }) }
    $removedLinks = 0
    foreach ($link in ($links | Select-Object -Unique)) {
      try { if (Remove-BenchBarShortcut $link) { $removedLinks++ } } catch { Say-Warn "Could not remove ${link}: $(Get-UserMessage $_)" }
    }
    Say-Ok "$removedLinks shortcuts removed"

    try {
      if (Remove-InstallDirFromUserPath) { Say-Ok 'removed from your user PATH (open terminals keep the old PATH)' } else { Say-Info 'the install folder was not on your user PATH' }
    } catch {
      Say-Warn "Could not change your user PATH: $(Get-UserMessage $_). Remove $installDir from it in Environment Variables."
    }

    $manifestPath = Join-Path $installDir '.installed-files.txt'
    if (Test-Path -LiteralPath $installDir) {
      if (Test-Path -LiteralPath $manifestPath) {
        $installRoot = [IO.Path]::GetFullPath($installDir).TrimEnd('\') + '\'
        $removed = 0
        foreach ($rel in @(Get-Content -LiteralPath $manifestPath | Where-Object { $_ })) {
          try {
            $target = [IO.Path]::GetFullPath((Join-Path $installDir $rel))
            if (-not $target.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (Test-Path -LiteralPath $target -PathType Leaf) {
              Remove-Item -LiteralPath $target -Force
              $removed++
            }
          } catch {
            Say-Warn "Skipped the manifest line '$rel': $(Get-UserMessage $_)"
          }
        }
        Get-ChildItem -LiteralPath $installDir -Recurse -File -Filter '*.old' -ErrorAction SilentlyContinue |
          ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $manifestPath, $linkList -Force -ErrorAction SilentlyContinue
        # empty folders, deepest first, then the install folder itself
        Get-ChildItem -LiteralPath $installDir -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending |
          Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
          ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        Say-Ok "$removed files removed"
      } else {
        Say-Warn "There is no .installed-files.txt in $installDir, so no file was removed. Delete the folder by hand if it holds only BenchBar."
      }
      if (-not (Get-ChildItem -LiteralPath $installDir -Force -ErrorAction SilentlyContinue)) {
        try { Remove-Item -LiteralPath $installDir -Force; Say-Ok 'install folder removed' } catch { Say-Warn "Could not remove $installDir (is a terminal open in it?). Delete it by hand." }
      } else {
        Say-Warn "$installDir still holds files that are not BenchBar's, or files in use. It was left in place."
      }
    } else {
      Say-Info 'there is no install folder'
    }

    Write-Host ''
    Write-Host 'BenchBar is removed from this PC.' -ForegroundColor Green
    Write-Host '  Kept: WSL, your Linux distro, your benches and sites, %USERPROFILE%\.wslconfig,'
    Write-Host '  and your settings, runners and reports in %LOCALAPPDATA%\BenchBar.'
    Write-Host '  To remove the distro too (this deletes every bench and database inside it, and cannot be undone):'
    Write-Host '    wsl --list --verbose'
    Write-Host '    wsl --unregister Ubuntu-24.04'
    return $true
  }

  # ------------------------------------------------------------ settings
  if (-not $Version -and $env:BENCHBAR_VERSION) { $Version = $env:BENCHBAR_VERSION }
  if (-not $NoTray -and (Test-Flag $env:BENCHBAR_NO_TRAY)) { $NoTray = [switch]$true }
  if (-not $Yes -and (Test-Flag $env:BENCHBAR_YES)) { $Yes = [switch]$true }
  if (-not $Uninstall -and (Test-Flag $env:BENCHBAR_UNINSTALL)) { $Uninstall = [switch]$true }
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

  $installDir = Join-Path $env:LOCALAPPDATA 'Programs\BenchBar'
  $installExe = Join-Path $installDir 'benchbar.exe'
  $trayExe = Join-Path $installDir 'BenchBarTray.exe'

  if ($Uninstall) { return (Invoke-BenchBarUninstall) }

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

  # Smart App Control blocks unsigned programs, and BenchBar is not signed yet.
  # Stop before anything is downloaded or written.
  $sac = Get-SmartAppControlState
  if ($sac -eq 1) {
    Stop-Install ("Smart App Control is on, and BenchBar is not signed yet.`n" +
      "  Smart App Control blocks programs without a signature, so Windows would not let BenchBar run. Nothing was downloaded or installed.`n" +
      "  To go on, turn Smart App Control off: Windows Security > App & browser control > Smart App Control settings > Off.`n" +
      "  On some versions of Windows you cannot turn it back on without resetting Windows.`n" +
      "  Then run this installer again.") "see https://benchbar.akashmishra.com/windows/#smart-app-control"
  } elseif ($sac -eq 2) {
    Say-Warn 'Smart App Control is in evaluation mode. It may turn itself on later and then block BenchBar (it is not signed yet). See https://benchbar.akashmishra.com/windows/#smart-app-control'
  } elseif ($sac -eq 0) {
    Say-Ok 'Smart App Control is off'
  }

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
      # The Windows zips are attached to a shared Mac and Windows release, and
      # sometimes later than the release itself. So "latest" is not enough:
      # take the newest published release that has the zip for this CPU.
      $candidates = @()
      if ($Version) {
        $one = Get-JsonFromGitHub "$repoApi/releases/tags/v$Version"
        if ($null -ne $one) { $candidates = @($one) }
        elseif (-not $net.RateLimited) { Stop-Install "There is no release v$Version." "see $repoWeb/releases" }
      } else {
        $list = Get-JsonFromGitHub "$repoApi/releases?per_page=30"
        if ($null -ne $list) {
          $candidates = @(@($list) | Where-Object { -not $_.draft -and -not $_.prerelease } | Sort-Object { [datetime]$_.published_at } -Descending)
        } elseif (-not $net.RateLimited) {
          Stop-Install 'There is no published release yet.' "see $repoWeb/releases"
        }
      }
      if ($net.RateLimited) {
        # no API call needed: the release page redirects to the newest tag, and the files have fixed addresses
        Say-Warn 'GitHub refused the API request (rate limit). Using the release page instead.'
        if ($Version) { $tag = "v$Version" } else { $tag = Get-LatestTagFromRedirect }
        if (-not $tag) { Stop-Install 'GitHub refused the request (rate limit?).' "wait a few minutes and run the installer again, or download the zip from $repoWeb/releases" }
        $releaseVersion = $tag.TrimStart('v')
        $zipName = "benchbar-windows-$releaseVersion-$arch.zip"
        $sumsName = "benchbar-windows-$releaseVersion-SHA256SUMS.txt"
        $zipUrl = "$repoWeb/releases/download/$tag/$zipName"
        $sumsUrl = "$repoWeb/releases/download/$tag/$sumsName"
        Say-Ok "$tag, $zipName"
      } else {
        $tag = ''
        foreach ($release in $candidates) {
          $candidateVersion = ([string]$release.tag_name).TrimStart('v')
          $candidateZip = "benchbar-windows-$candidateVersion-$arch.zip"
          $candidateSums = "benchbar-windows-$candidateVersion-SHA256SUMS.txt"
          $assets = @($release.assets)
          $zipAsset = $assets | Where-Object { $_.name -eq $candidateZip } | Select-Object -First 1
          $sumsAsset = $assets | Where-Object { $_.name -eq $candidateSums } | Select-Object -First 1
          if ($zipAsset -and $sumsAsset) {
            $tag = [string]$release.tag_name
            $releaseVersion = $candidateVersion
            $zipName = $candidateZip
            $sumsName = $candidateSums
            $zipUrl = [string]$zipAsset.browser_download_url
            $sumsUrl = [string]$sumsAsset.browser_download_url
            break
          }
          if ($Version) { Say-Info "release v$candidateVersion has no $candidateZip yet" }
        }
        if (-not $tag) {
          if ($Version) {
            Stop-Install "Release v$Version has no Windows build for $arch (benchbar-windows-$Version-$arch.zip) yet." "the Windows zips are attached a little after a release. Try again later, or see $repoWeb/releases"
          }
          Stop-Install "No published release has a Windows build for $arch yet." "see $repoWeb/releases and https://benchbar.akashmishra.com/windows/"
        }
        Say-Ok "$tag, $zipName"
      }
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
      $proxyArgs = Get-WebProxyArgs $zipUrl
      try {
        Invoke-WebRequest -Uri $sumsUrl -OutFile $sumsPath -Headers $webHeaders -UseBasicParsing @proxyArgs
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -Headers $webHeaders -UseBasicParsing @proxyArgs
      } catch {
        $hint = 'check your network and run the installer again'
        if ($net.RateLimited) { $hint = 'the release may not have its Windows files yet; see ' + $repoWeb + '/releases, or wait a few minutes and run the installer again' }
        Stop-Install "Download failed: $($_.Exception.Message)" $hint
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
      $running = @(Get-RunningTray)
      if ($running.Count -gt 0) {
        Say-Warn 'The tray app from this folder is running.'
        if (-not (Confirm-Choice 'Close it so it can be updated? (it starts again at the end)' $true)) {
          Stop-Install 'The tray app has to be closed to update it.' 'close BenchBar Tray from the tray, then run the installer again'
        }
        Stop-BenchBarTray $running
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
    Assert-CopiedFiles $files
    Say-Ok "$($files.Count) files copied"

    # A zip saved by a browser, or unpacked by Explorer, marks its files as
    # downloaded from the internet, and the copy keeps the mark. Windows then
    # asks "The publisher could not be verified" at every first start. The
    # files were checked against SHA256SUMS above, so remove the mark.
    try {
      Get-ChildItem -LiteralPath $installDir -Recurse -File | Unblock-File
      Say-Ok 'removed the "downloaded from the internet" mark from the installed files'
    } catch {
      Say-Warn "Could not remove the internet mark from the installed files: $($_.Exception.Message). Windows may ask you to confirm the first start of each program."
    }

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
    $trayExists = (-not $NoTray) -and (Test-Path -LiteralPath $trayExe)
    $runtimeOk = $false
    if ($NoTray) {
      Say-Step 'Tray app'
      Say-Info 'skipped (-NoTray)'
    } else {
      Say-Step 'Checking what the tray app needs'
      if (-not $trayExists) {
        Say-Warn 'This download has no tray app.'
      } else {
        $runtimeOk = Test-DotNetDesktop10
        if ($runtimeOk) {
          Say-Ok '.NET 10 Desktop Runtime found'
        } else {
          Say-Warn 'The .NET 10 Desktop Runtime is missing. The tray app needs it. Without it Windows only shows "You must install .NET Desktop Runtime to run this application."'
          $dotnetPage = 'https://dotnet.microsoft.com/download/dotnet/10.0'
          if (Get-Command winget -ErrorAction SilentlyContinue) {
            if (Confirm-Choice 'Install it now with winget? Windows will ask for permission.' $true) {
              $wingetCode = 1
              try {
                $wingetCode = Invoke-Exe 'winget' @('install', '--id', 'Microsoft.DotNet.DesktopRuntime.10', '-e', '--accept-package-agreements', '--accept-source-agreements')
              } catch {
                Say-Warn 'winget could not be started.'
              }
              $runtimeOk = Test-DotNetDesktop10
              if ($runtimeOk) {
                Say-Ok '.NET 10 Desktop Runtime installed'
              } else {
                Say-Warn "winget did not install it (exit code $wingetCode). Install the .NET 10 Desktop Runtime by hand: $dotnetPage"
              }
            } else {
              Say-Info 'to install it later: winget install --id Microsoft.DotNet.DesktopRuntime.10 -e'
            }
          } else {
            Say-Info "winget is not on this PC. Download the .NET 10 Desktop Runtime (x64 or Arm64, like your PC) from $dotnetPage"
          }
        }

        # the Start menu entry is how you find BenchBar again; the Startup
        # shortcut is the open at logon choice
        $recorded = @()
        $menuLink = Get-StartMenuLink
        if (New-TrayShortcut $menuLink 'BenchBar tray app') { Say-Ok 'Start menu shortcut created (BenchBar)' } else { Say-Ok 'Start menu shortcut is in place (BenchBar)' }
        $recorded += $menuLink

        $startupLink = Get-StartupLink
        if (Test-Path -LiteralPath $startupLink) {
          $null = New-TrayShortcut $startupLink 'BenchBar tray app'
          $recorded += $startupLink
        } elseif (Confirm-Choice 'Start the tray app when you sign in?' $true) {
          $null = New-TrayShortcut $startupLink 'BenchBar tray app'
          $recorded += $startupLink
          Say-Ok 'Startup shortcut created'
        } else {
          Say-Info 'no Startup shortcut'
        }
        [IO.File]::WriteAllText((Join-Path $installDir '.installed-shortcuts.txt'), ($recorded -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $false))
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

    # ---------------------------------------------------------- 8. start the tray
    if ($trayExists) {
      if (-not $runtimeOk) {
        Say-Step 'Tray app'
        Say-Warn 'The tray app was not started, because the .NET 10 Desktop Runtime is missing. Install it, then start BenchBar from the Start menu.'
      } else {
        $startNow = $restartTray
        if (-not $startNow) {
          Say-Step 'Tray app'
          $startNow = Confirm-Choice 'Start the tray app now? It opens the setup.' $true
        }
        if ($startNow) {
          try {
            Start-Process -FilePath $trayExe -WorkingDirectory $installDir
            $trayStarted = $true
            Say-Ok 'tray app started'
          } catch {
            Say-Warn "The tray app could not be started: $(Get-UserMessage $_). Start BenchBar from the Start menu. If Windows blocks it, see $docsBlocked"
          }
        } else {
          Say-Info 'not started'
        }
      }
    }

    Write-Host ''
    Write-Host "BenchBar $releaseVersion is installed in $installDir." -ForegroundColor Green
    if ($trayExists) { Write-Host "Tray app: $trayExe" }

    Write-Host ''
    Write-Host 'Next:' -ForegroundColor Cyan
    if ($trayExists -and $runtimeOk) {
      if ($trayStarted) {
        Write-Host '  - The BenchBar tray app opens the setup. Follow it to set up WSL, Ubuntu and your first bench.'
      } else {
        Write-Host '  - Start BenchBar from the Start menu. It opens the setup.'
      }
      Write-Host '  - Later, find it in the Start menu, or as the icon near the clock. Windows may hide that icon under the ^ arrow.'
    }
    Write-Host '  - In a terminal (open a new one first), benchbar.exe setup check shows what is ready and what is not.'
    Write-Host "  - Help: https://benchbar.akashmishra.com/windows/"
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
  $benchbarOk = Install-BenchBar -Version $Version -NoTray:$NoTray -Yes:$Yes -Uninstall:$Uninstall -Source $Source -Zip $Zip
} catch {
  Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
}
# The last native program was doctor, whose exit code says nothing about the install; leave the
# install's own result in $LASTEXITCODE (a CI step or a calling script reads it).
if ($benchbarOk) { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 }
if ($PSCommandPath -and -not $benchbarOk) { exit 1 }

} @args
