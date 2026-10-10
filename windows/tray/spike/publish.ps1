# Publishes both shells and the harness the way the spike measures them.
#   winui-sc, wpf-sc  self contained, ReadyToRun, not trimmed (measured)
#   winui-fd, wpf-fd  framework dependent, ReadyToRun (size only: they need
#                     the .NET 10 Desktop Runtime, and WinUI also the
#                     Windows App SDK runtime, on a clean Windows 11)
#   harness           framework dependent console app
param([string]$Out = 'out')

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Publish([string]$project, [string]$dir, [string[]]$extra) {
    dotnet publish $project -c Release -r win-x64 -o (Join-Path $Out $dir) @extra
    if ($LASTEXITCODE -ne 0) { throw "publish $project to $dir failed" }
}

Publish WinUiShell/WinUiShell.csproj winui-sc @('--self-contained', 'true', '-p:PublishReadyToRun=true', '-p:WindowsAppSDKSelfContained=true')
Publish WpfShell/WpfShell.csproj wpf-sc @('--self-contained', 'true', '-p:PublishReadyToRun=true')
Publish WinUiShell/WinUiShell.csproj winui-fd @('--self-contained', 'false', '-p:PublishReadyToRun=true', '-p:WindowsAppSDKSelfContained=false')
Publish WpfShell/WpfShell.csproj wpf-fd @('--self-contained', 'false', '-p:PublishReadyToRun=true')
Publish Harness/Harness.csproj harness @('--self-contained', 'false')
