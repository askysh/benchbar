<#
.SYNOPSIS
  Starts a published BenchBarTray.exe on recorded data, checks that it stays up, and asks it to quit.

.DESCRIPTION
  The tray writes a run marker (%LOCALAPPDATA%\BenchBar\running, holding its version) when it starts
  and removes it on a clean exit. This script uses that, so it needs no window and no debug hook:

    1. start BenchBarTray.exe with BENCHBAR_TRAY_FIXTURES set (recorded benches, no WSL needed)
    2. wait for the marker (the app got as far as its single instance and its first line of code)
    3. check the marker names -Version, when one is given (the version the build stamped in)
    4. check the process is still running after -StaySeconds (a missing native DLL, a bad manifest
       or a runtime that cannot start shows as an exit in the first seconds)
    5. set the Local\BenchBarTray.Quit event, the way the installer asks a running tray to close
    6. check it exits with code 0 and removes the marker

  Run it on a machine of the same CPU type as the build (arm64 build on an arm64 runner). On failure
  it prints tray.log and throws. It changes %LOCALAPPDATA%\BenchBar (a throwaway CI profile; do not
  run it on a PC where the tray is installed, it refuses when a BenchBarTray process exists).

.EXAMPLE
  pwsh windows/tray/scripts/smoke.ps1 -Dir out/tray -Fixtures windows/tray/fixtures/rest -Version 0.9.0
#>
param(
    [Parameter(Mandatory)][string]$Dir,
    [Parameter(Mandatory)][string]$Fixtures,
    [string]$Version = '',
    [int]$StaySeconds = 8,
    [int]$StartTimeoutSeconds = 30,
    [int]$QuitTimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'

$exe = Join-Path (Resolve-Path $Dir).Path 'BenchBarTray.exe'
if (-not (Test-Path $exe)) { throw "No BenchBarTray.exe in $Dir" }
$fixtures = (Resolve-Path $Fixtures).Path
if (Get-Process -Name BenchBarTray -ErrorAction SilentlyContinue) {
    throw 'A BenchBarTray process is already running. This script is for a CI runner: it does not touch a tray that is in use.'
}

$data = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'BenchBar'
$marker = Join-Path $data 'running'
$log = Join-Path $data 'tray.log'
Remove-Item $marker -Force -ErrorAction SilentlyContinue

function Show-TrayLog {
    if (Test-Path $log) { Write-Host '--- tray.log ---'; Get-Content $log -Tail 40 | ForEach-Object { Write-Host $_ }; Write-Host '--- end ---' }
    else { Write-Host '(no tray.log: the app wrote no error)' }
}

$env:BENCHBAR_TRAY_FIXTURES = $fixtures
$proc = $null
try {
    Write-Host "Starting $exe on $fixtures"
    $proc = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -PassThru

    # 2. the marker
    $deadline = [DateTime]::UtcNow.AddSeconds($StartTimeoutSeconds)
    while (-not (Test-Path $marker)) {
        if ($proc.HasExited) { throw "BenchBarTray.exe exited with code $($proc.ExitCode) before it started." }
        if ([DateTime]::UtcNow -gt $deadline) { throw "BenchBarTray.exe wrote no run marker in $StartTimeoutSeconds seconds." }
        Start-Sleep -Milliseconds 250
    }
    $stamped = (Get-Content $marker -Raw).Trim()
    Write-Host "Started: run marker says version '$stamped' (process $($proc.Id))."

    # 3. the version
    if ($Version -and $stamped -ne $Version) { throw "The tray says version '$stamped', the build was stamped '$Version'." }

    # 4. it stays up
    $until = [DateTime]::UtcNow.AddSeconds($StaySeconds)
    while ([DateTime]::UtcNow -lt $until) {
        if ($proc.HasExited) { throw "BenchBarTray.exe exited with code $($proc.ExitCode) $StaySeconds seconds or less after it started." }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "Still running after $StaySeconds seconds."

    # 5. quit the way the installer does
    $quit = [System.Threading.EventWaitHandle]::OpenExisting('Local\BenchBarTray.Quit')
    [void]$quit.Set()
    $quit.Dispose()

    # 6. a clean exit
    if (-not $proc.WaitForExit($QuitTimeoutSeconds * 1000)) { throw "BenchBarTray.exe did not exit within $QuitTimeoutSeconds seconds of the quit event." }
    if ($proc.ExitCode -ne 0) { throw "BenchBarTray.exe exited with code $($proc.ExitCode) after the quit event." }
    if (Test-Path $marker) { throw 'BenchBarTray.exe exited but left its run marker (not a clean exit).' }
    Write-Host 'Quit cleanly: exit code 0, run marker removed.'
}
catch {
    Write-Host "::error title=Tray smoke test::$($_.Exception.Message)"
    Show-TrayLog
    throw
}
finally {
    if ($proc -and -not $proc.HasExited) { $proc.Kill($true) }
    Remove-Item Env:\BENCHBAR_TRAY_FIXTURES -ErrorAction SilentlyContinue
}
