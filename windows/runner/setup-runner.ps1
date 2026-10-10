#Requires -Version 5.1
<#
.SYNOPSIS
  Registers this Windows machine as a self hosted GitHub Actions runner for
  askysh/benchbar with the label "wsl".

.DESCRIPTION
  The runner lives in C:\actions-runner and starts from a Task Scheduler task
  at logon, not as a Windows service: it runs only while the user is logged
  on, in a hidden window, and restarts on failure. Jobs reach the bench inside
  WSL through wsl.exe. Defender gets an exclusion for C:\actions-runner\_work
  so checkouts and builds are not scanned file by file.

  Run it once from an elevated PowerShell (the Defender exclusion needs it).
  Re-running is safe: it keeps an existing registration unless -Reconfigure.

.PARAMETER Token
  A runner registration token. Without it the script asks gh for one
  (gh api -X POST repos/OWNER/REPO/actions/runners/registration-token), so
  gh must be installed and logged in on Windows with admin rights on the repo.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\setup-runner.ps1
#>
[CmdletBinding()]
param(
  [string]$Repo = 'askysh/benchbar',
  [string]$Token = '',
  [string]$RunnerName = "$env:COMPUTERNAME-wsl",
  [string]$Labels = 'wsl',
  [string]$RunnerDir = 'C:\actions-runner',
  [string]$TaskName = 'GitHub Actions runner (benchbar, wsl)',
  [switch]$Reconfigure
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
  throw 'Run this from an elevated PowerShell: the Defender exclusion needs administrator rights.'
}

# The user the task runs as: the one who started the elevated prompt.
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$workDir = Join-Path $RunnerDir '_work'

# 1. The folder and the Defender exclusion for the work folder only
New-Item -ItemType Directory -Force -Path $RunnerDir, $workDir | Out-Null
$excluded = @((Get-MpPreference).ExclusionPath) -contains $workDir
if (-not $excluded) {
  Add-MpPreference -ExclusionPath $workDir
  Write-Host "Defender: excluded $workDir"
} else {
  Write-Host "Defender: $workDir already excluded"
}

# 2. The runner itself, the latest release for this architecture
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
if (-not (Test-Path (Join-Path $RunnerDir 'config.cmd'))) {
  $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/actions/runner/releases/latest' -Headers @{ 'User-Agent' = 'benchbar-setup-runner' }
  $asset = $release.assets | Where-Object { $_.name -like "actions-runner-win-$arch-*.zip" } | Select-Object -First 1
  if (-not $asset) { throw "No actions-runner-win-$arch zip in the latest runner release." }
  $zip = Join-Path $env:TEMP $asset.name
  Write-Host "Downloading $($asset.name)"
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
  # GitHub publishes the SHA-256 in the release body; check it when present
  $expected = [regex]::Match($release.body, "$([regex]::Escape($asset.name))[^0-9a-f]*([0-9a-f]{64})").Groups[1].Value
  if ($expected) {
    $actual = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
    if ($actual -ne $expected) { Remove-Item $zip; throw "Checksum mismatch for $($asset.name)." }
  }
  Expand-Archive -Path $zip -DestinationPath $RunnerDir -Force
  Remove-Item $zip
}

# 3. Registration (kept unless -Reconfigure)
$configured = Test-Path (Join-Path $RunnerDir '.runner')
if ($configured -and $Reconfigure) {
  if (-not $Token) { $Token = (gh api -X POST "repos/$Repo/actions/runners/remove-token" --jq .token) }
  & (Join-Path $RunnerDir 'config.cmd') remove --token $Token
  $configured = $false
  $Token = ''
}
if (-not $configured) {
  if (-not $Token) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'Pass -Token, or install and log in to gh on Windows.' }
    $Token = (gh api -X POST "repos/$Repo/actions/runners/registration-token" --jq .token)
  }
  Push-Location $RunnerDir
  try {
    & .\config.cmd --unattended --url "https://github.com/$Repo" --token $Token `
      --name $RunnerName --labels $Labels --work '_work' --replace
    if ($LASTEXITCODE -ne 0) { throw "config.cmd failed with exit code $LASTEXITCODE." }
  } finally { Pop-Location }
} else {
  Write-Host 'Runner already registered (use -Reconfigure to register again).'
}

# 4. The logon task: interactive only (runs while the user is logged on),
#    hidden window through conhost --headless, restarted on failure
$run = Join-Path $RunnerDir 'run.cmd'
$action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless `"$run`"" -WorkingDirectory $RunnerDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
  -Settings $settings -Description "Runs the $Repo self hosted runner (label $Labels) while $user is logged on." -Force | Out-Null
Write-Host "Task Scheduler: '$TaskName' runs at logon for $user"

Start-ScheduledTask -TaskName $TaskName
Write-Host "Started. Check: gh api repos/$Repo/actions/runners --jq '.runners[] | [.name, .status] | @tsv'"
