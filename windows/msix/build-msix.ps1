<#
.SYNOPSIS
  Builds BenchBar for Windows as an MSIX package (feasibility spike).

.DESCRIPTION
  Builds benchbar.exe (Go) and BenchBarTray.exe (.NET 10 WPF, self contained)
  the way .github/workflows/release-windows.yml does, lays both out in one flat
  package folder with AppxManifest.xml and the logos, and packs it with
  MakeAppx.exe.

  -Mode Sideload (default)  one package for this PC's CPU, signed with a self signed
                            certificate whose subject equals the manifest Publisher.
                            Prints the exact commands to trust it and install it.
  -Mode Store               unsigned .msix per CPU, a .msixbundle and a .msixupload for
                            Partner Center. Microsoft signs it after certification.
                            Use the Name, Publisher and PublisherDisplayName that Partner
                            Center shows under Product identity.

  Needs on PATH: go, dotnet (SDK 10). Needs the Windows SDK (MakeAppx.exe, and signtool.exe
  for Sideload). Nothing here changes the repository.

.EXAMPLE
  .\build-msix.ps1
  .\build-msix.ps1 -Version 0.8.2 -Arch x64
  .\build-msix.ps1 -Mode Store -Version 0.8.2 -Arch both `
      -IdentityName 'AkashMishra.BenchBar' -Publisher 'CN=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX' `
      -PublisherDisplayName 'Akash Mishra'
#>
[CmdletBinding()]
param(
  [ValidateSet('Sideload', 'Store')]
  [string]$Mode = 'Sideload',

  # Package version, A.B.C or A.B.C.0. The Store reserves the fourth part: it must be 0.
  [string]$Version = '0.0.1',

  # x64, arm64, or both (both is for Store mode: it makes the bundle).
  [ValidateSet('x64', 'arm64', 'both')]
  [string]$Arch = '',

  [string]$IdentityName = 'BenchBar.Spike',
  [string]$Publisher = 'CN=BenchBar Spike Test',
  [string]$PublisherDisplayName = 'BenchBar Spike (test)',

  # Release version stamped into benchbar.exe and BenchBarTray.exe, X.Y.Z. Empty builds
  # dev versions (the shim reports "dev" and never compares itself with the CLI).
  [string]$AppVersion = '',

  # Where everything goes. Default: windows\msix\out next to this script.
  [string]$OutDir = '',

  # Reuse the binaries from an earlier run (out\stage-<arch>) and only repack.
  [switch]$SkipBuild,

  # Framework dependent tray (smaller, but a packaged app has no way to install the .NET runtime).
  # For a size comparison only. The package will not start on a PC without the runtime.
  [switch]$FrameworkDependent,

  # Also build resources.pri with MakePri.exe so the target size logos are found.
  [switch]$MakePri
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here '..\..')).Path
if (-not $OutDir) { $OutDir = Join-Path $here 'out' }
$null = New-Item -ItemType Directory -Force -Path $OutDir
$OutDir = (Resolve-Path $OutDir).Path

function Say([string]$m) { Write-Host $m }
function Fail([string]$m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# ----------------------------------------------------------------- inputs

if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$') { Fail "Version '$Version' is not A.B.C or A.B.C.0" }
$fourth = if ($Matches[4]) { $Matches[4] } else { '0' }
if ($Mode -eq 'Store' -and $fourth -ne '0') { Fail "For the Store the fourth part of the version must be 0 (got $Version)" }
$pkgVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3]).$fourth"

if ($AppVersion -and $AppVersion -notmatch '^\d+\.\d+\.\d+$') { Fail "AppVersion '$AppVersion' is not X.Y.Z" }

$hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
if (-not $Arch) { $Arch = if ($Mode -eq 'Store') { 'both' } else { $hostArch } }
if ($Mode -eq 'Sideload' -and $Arch -eq 'both') { Fail 'Sideload mode builds one CPU. Use -Arch x64 or -Arch arm64.' }
if ($Mode -eq 'Sideload' -and $Arch -ne $hostArch) {
  Say "WARNING: this PC is $hostArch, so a $Arch package will build but will not install here."
}
if ($Mode -eq 'Store' -and ($IdentityName -eq 'BenchBar.Spike' -or $Publisher -eq 'CN=BenchBar Spike Test')) {
  Fail 'Store mode needs the Name, Publisher and PublisherDisplayName from Partner Center (Product identity). Pass -IdentityName, -Publisher and -PublisherDisplayName.'
}
$arches = if ($Arch -eq 'both') { @('x64', 'arm64') } else { @($Arch) }

# ----------------------------------------------------------------- tools

function Find-SdkTool([string]$name) {
  # Windows SDK layout: <Program Files (x86)>\Windows Kits\10\bin\<10.0.x.y>\<arch>\tool.exe
  $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } |
    ForEach-Object { Join-Path $_ 'Windows Kits\10\bin' } | Where-Object { Test-Path $_ }
  $found = @()
  foreach ($root in $roots) {
    foreach ($dir in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)) {
      if ($dir.Name -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
      foreach ($a in @('x64', 'arm64', 'x86')) {
        $exe = Join-Path $dir.FullName "$a\$name"
        if (Test-Path $exe) { $found += [pscustomobject]@{ Ver = [version]$dir.Name; Arch = $a; Path = $exe } }
      }
    }
  }
  if (-not $found) { return $null }
  # newest SDK first; prefer the host's own CPU, then x64 (runs on Arm64 under emulation)
  $pref = @{ 'x64' = 2; 'arm64' = 2; 'x86' = 3 }
  $pref[$hostArch] = 0
  if ($hostArch -ne 'x64') { $pref['x64'] = 1 }
  ($found | Sort-Object @{ Expression = { $_.Ver }; Descending = $true }, @{ Expression = { $pref[$_.Arch] } } | Select-Object -First 1).Path
}

$makeappx = Find-SdkTool 'makeappx.exe'
if (-not $makeappx) {
  Fail @'
MakeAppx.exe not found. Install the Windows SDK (it holds MakeAppx.exe, MakePri.exe and signtool.exe):
  Visual Studio Installer > Individual components > "Windows 11 SDK (10.0.xxxxx)"
  or: winget search Microsoft.WindowsSDK   (then install one of the 10.0.xxxxx ids)
It lives under C:\Program Files (x86)\Windows Kits\10\bin\<version>\x64\. Run this script again afterwards.
'@
}
$signtool = $null
if ($Mode -eq 'Sideload') {
  $signtool = Find-SdkTool 'signtool.exe'
  if (-not $signtool) { Fail 'signtool.exe not found. It comes with the Windows SDK (see above). Sideload mode signs the package with it.' }
}
$makepri = $null
if ($MakePri) {
  $makepri = Find-SdkTool 'makepri.exe'
  if (-not $makepri) { Fail 'makepri.exe not found. It comes with the Windows SDK (see above).' }
}
if (-not $SkipBuild) {
  if (-not (Get-Command go -ErrorAction SilentlyContinue)) { Fail 'go not found on PATH (the shim is built with Go, see windows/shim/go.mod).' }
  if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { Fail 'dotnet not found on PATH (the tray needs the .NET 10 SDK, see windows/tray/global.json).' }
}
Say "MakeAppx: $makeappx"
if ($signtool) { Say "signtool: $signtool" }

function Invoke-Native([string]$exe, [string[]]$arguments) {
  & $exe @arguments
  if ($LASTEXITCODE -ne 0) { Fail "$exe failed with exit code $LASTEXITCODE" }
}

# ----------------------------------------------------------------- build

function Get-PeMachine([string]$path) {
  $fs = [IO.File]::OpenRead($path)
  try {
    $br = New-Object IO.BinaryReader($fs)
    $fs.Position = 0x3C
    $fs.Position = $br.ReadInt32() + 4
    $br.ReadUInt16()
  } finally { $fs.Dispose() }
}
$machineOf = @{ x64 = 0x8664; arm64 = 0xAA64 }

function Build-Programs([string]$a, [string]$stage) {
  if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
  $null = New-Item -ItemType Directory -Force -Path $stage
  $rid = if ($a -eq 'arm64') { 'win-arm64' } else { 'win-x64' }

  Say "[$a] building benchbar.exe"
  $shimVersion = if ($AppVersion) { $AppVersion } else { $null }
  $ldflags = '-s -w'
  if ($shimVersion) { $ldflags += " -X main.version=$shimVersion" }
  $old = @{ GOOS = $env:GOOS; GOARCH = $env:GOARCH; CGO_ENABLED = $env:CGO_ENABLED }
  $env:GOOS = 'windows'; $env:GOARCH = if ($a -eq 'arm64') { 'arm64' } else { 'amd64' }; $env:CGO_ENABLED = '0'
  Push-Location (Join-Path $repo 'windows\shim')
  try { Invoke-Native 'go' @('build', '-trimpath', '-ldflags', $ldflags, '-o', (Join-Path $stage 'benchbar.exe'), '.') }
  finally {
    Pop-Location
    foreach ($k in $old.Keys) { if ($null -eq $old[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } else { Set-Item "Env:$k" $old[$k] } }
  }

  Say "[$a] publishing BenchBarTray (self contained: $(-not $FrameworkDependent))"
  $sc = if ($FrameworkDependent) { 'false' } else { 'true' }
  # Directory.Build.props pins win-x64 and Platform x64; arm64 overrides all three (as release-windows.yml does)
  $extra = @()
  if ($a -eq 'arm64') { $extra = @('-p:Platform=arm64', '-p:PlatformTarget=arm64') }
  $meta = @('-p:Company=Akash Mishra', '-p:Product=BenchBar', '-p:AssemblyTitle=BenchBar tray app', '-p:Description=BenchBar tray app for Windows')
  $ver = @()
  if ($AppVersion) { $ver = @("-p:Version=$AppVersion") }
  $proj = Join-Path $repo 'windows\tray\BenchBarTray\BenchBarTray.csproj'
  Invoke-Native 'dotnet' (@('publish', $proj, '-c', 'Release', '-r', $rid, '--self-contained', $sc) + $ver + $meta + $extra + @('-o', $stage))

  foreach ($exe in @('benchbar.exe', 'BenchBarTray.exe')) {
    $p = Join-Path $stage $exe
    if (-not (Test-Path $p)) { Fail "$exe is missing from $stage" }
    if ((Get-PeMachine $p) -ne $machineOf[$a]) { Fail "$exe is not a $a program" }
  }
}

# ----------------------------------------------------------------- package folder

function Write-Manifest([string]$a, [string]$dest) {
  $text = Get-Content (Join-Path $here 'AppxManifest.xml') -Raw -Encoding UTF8
  # the header comment names the tokens; drop all comments from the packaged file
  $text = [regex]::Replace($text, '(?s)<!--.*?-->', '')
  $map = @{
    IDENTITY_NAME = $IdentityName; PUBLISHER = $Publisher; PUBLISHER_DISPLAY = $PublisherDisplayName
    VERSION = $pkgVersion; ARCH = $a
  }
  foreach ($k in $map.Keys) {
    $v = [Security.SecurityElement]::Escape($map[$k])
    $text = $text.Replace("{{$k}}", $v)
  }
  if ($text -match '\{\{[A-Z_]+\}\}') { Fail "AppxManifest.xml still has a token: $($Matches[0])" }
  $null = [xml]$text   # must be well formed
  [IO.File]::WriteAllText($dest, $text, (New-Object Text.UTF8Encoding($false)))
}

function New-PackageFolder([string]$a, [string]$stage) {
  $pkg = Join-Path $OutDir "pkg-$a"
  if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
  $null = New-Item -ItemType Directory -Force -Path $pkg
  Copy-Item (Join-Path $stage '*') $pkg -Recurse -Force
  # no debug symbols in the package
  Get-ChildItem $pkg -Recurse -Filter *.pdb | Remove-Item -Force
  Copy-Item (Join-Path $here 'Assets') (Join-Path $pkg 'Assets') -Recurse
  Write-Manifest $a (Join-Path $pkg 'AppxManifest.xml')

  if ($makepri) {
    Say "[$a] MakePri"
    $tmp = Join-Path $OutDir "pri-$a"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $tmp
    Copy-Item (Join-Path $pkg 'Assets') (Join-Path $tmp 'Assets') -Recurse
    Copy-Item (Join-Path $pkg 'AppxManifest.xml') $tmp
    $cfg = Join-Path $tmp 'priconfig.xml'
    Invoke-Native $makepri @('createconfig', '/cf', $cfg, '/dq', 'en-US', '/o')
    Invoke-Native $makepri @('new', '/pr', $tmp, '/cf', $cfg, '/mn', (Join-Path $tmp 'AppxManifest.xml'), '/of', (Join-Path $pkg 'resources.pri'), '/o')
  }
  $pkg
}

function Pack([string]$pkg, [string]$a) {
  $msix = Join-Path $OutDir ("BenchBar_{0}_{1}.msix" -f $pkgVersion, $a)
  Say "[$a] MakeAppx pack"
  Invoke-Native $makeappx @('pack', '/d', $pkg, '/p', $msix, '/o')
  $size = [math]::Round((Get-Item $msix).Length / 1MB, 1)
  Say "[$a] $msix ($size MB)"
  $msix
}

# ----------------------------------------------------------------- go

$msixFiles = @()
foreach ($a in $arches) {
  $stage = Join-Path $OutDir "stage-$a"
  if ($SkipBuild) { if (-not (Test-Path $stage)) { Fail "-SkipBuild, but $stage does not exist" } }
  else { Build-Programs $a $stage }
  $pkg = New-PackageFolder $a $stage
  $msixFiles += Pack $pkg $a
}

if ($Mode -eq 'Store') {
  $upload = $msixFiles
  if ($msixFiles.Count -gt 1) {
    $bdir = Join-Path $OutDir 'bundle-in'
    if (Test-Path $bdir) { Remove-Item $bdir -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $bdir
    $msixFiles | ForEach-Object { Copy-Item $_ $bdir }
    $bundle = Join-Path $OutDir ("BenchBar_{0}_x64_arm64.msixbundle" -f $pkgVersion)
    Say 'MakeAppx bundle'
    Invoke-Native $makeappx @('bundle', '/d', $bdir, '/bv', $pkgVersion, '/p', $bundle, '/o')
    $upload = @($bundle)
  }
  # an .msixupload is a zip of the package or bundle (and an optional .appxsym of symbols)
  $zip = Join-Path $OutDir ("BenchBar_{0}.zip" -f $pkgVersion)
  $final = [IO.Path]::ChangeExtension($zip, '.msixupload')
  foreach ($f in @($zip, $final)) { if (Test-Path $f) { Remove-Item $f -Force } }
  Compress-Archive -Path $upload -DestinationPath $zip
  Move-Item $zip $final
  Say ''
  Say 'Store submission files (unsigned on purpose: Microsoft signs after certification):'
  Say "  upload this : $final"
  Say '  Partner Center > the app > Submission > Packages: drop the .msixupload there.'
  Say '  The Identity Name, Publisher and PublisherDisplayName in the package must equal the'
  Say '  values under Product identity, or the upload is refused.'
  exit 0
}

# ----------------------------------------------------------------- sideload: certificate, sign, instructions

$msix = $msixFiles[0]
$pkgDir = Join-Path $OutDir "pkg-$($arches[0])"
$cer = Join-Path $OutDir 'BenchBar-Spike-Test.cer'

$cert = Get-ChildItem Cert:\CurrentUser\My |
  Where-Object { $_.Subject -eq $Publisher -and $_.NotAfter -gt (Get-Date).AddDays(7) } |
  Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
  Say "Creating a self signed code signing certificate with subject '$Publisher' (Cert:\CurrentUser\My)"
  $cert = New-SelfSignedCertificate -Type Custom -KeyUsage DigitalSignature `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}') `
    -Subject $Publisher -FriendlyName 'BenchBar MSIX spike (test only)' -NotAfter (Get-Date).AddYears(1)
} else {
  Say "Reusing the certificate $($cert.Thumbprint) (subject '$Publisher')"
}
$null = Export-Certificate -Cert $cert -FilePath $cer -Force
$thumb = $cert.Thumbprint

Say 'Signing'
Invoke-Native $signtool @('sign', '/fd', 'SHA256', '/sha1', $thumb, '/s', 'My', $msix)
# no signtool verify here: it fails until the certificate is trusted (step 1 below)

Say ''
Say '================ Test it on this PC ================'
Say 'The certificate is only for this test. Do not trust it on a PC you care about longer than the test.'
Say ''
Say '1. Trust the test certificate. This needs an ELEVATED PowerShell (Run as administrator):'
Say "     Import-Certificate -FilePath '$cer' -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
Say ''
Say '2. Install, in a normal (not elevated) PowerShell:'
Say "     Add-AppxPackage -Path '$msix'"
Say ''
Say '3. Check, in a NEW terminal (so it sees the alias):'
Say "     Get-AppxPackage $IdentityName | Format-List Name, Version, InstallLocation, PackageFamilyName"
Say '     where.exe benchbar'
Say '     benchbar --shim-version'
Say '     Start menu > BenchBar'
Say ''
Say 'Uninstall:'
Say "     Get-AppxPackage $IdentityName | Remove-AppxPackage"
Say 'Then, elevated, remove the test certificate:'
Say "     Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Thumbprint -eq '$thumb' | Remove-Item"
Say "     Get-ChildItem Cert:\CurrentUser\My | Where-Object Thumbprint -eq '$thumb' | Remove-Item"
Say ''
Say 'No signing, no certificate (Developer Mode must be on: Settings > System > For developers):'
Say "     Add-AppxPackage -Register '$pkgDir\AppxManifest.xml'"
Say "   The package folder must stay where it is. Remove it with the same Remove-AppxPackage line."
Say '   This is a loose layout: good for a quick look, but the signed .msix is the real test.'
