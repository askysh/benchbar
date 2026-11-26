---
title: "Windows"
description: "BenchBar for Windows (beta): benches run in WSL, benchbar.exe runs the CLI from PowerShell, and the tray app shows them in the notification area."
---

On Windows, benches run inside WSL 2, never on Windows itself. Two small
programs bring them to the Windows side:

- `benchbar.exe`, the shim: every command forwards to `benchbar` inside
  the distro, so `benchbar.exe status`, `up`, `down` and `doctor` work
  from PowerShell.
- BenchBar Tray, a notification area app: the runner shows the state of
  your benches, and a click opens them.

BenchBar for Windows is in beta. It works, and you may find rough edges.
The tray and the window say so: a **Beta** pill, the window title
"BenchBar (Beta)" and a banner that you can dismiss. Both programs are
not signed, and 0.9.0 has no signed or Microsoft Store route. On our
Windows 11 test PC (Smart App Control off) the one line installer needed
no click through a warning. Smart App Control, when it is on, blocks the
tray and `benchbar.exe`: see [Smart App Control](#smart-app-control) for
what you can do, and [Signing and verification](#signing-and-verification).

## What you need

- Windows 11, or Windows 10 version 22H2 (build 19045) or later, with
  virtualization on in the firmware.
- Smart App Control off (see [Smart App Control](#smart-app-control)).
- For the tray: the .NET 10 Desktop Runtime. The installer offers to
  install it with `winget`
  (`winget install --id Microsoft.DotNet.DesktopRuntime.10 -e`).

Everything else the first run wizard sets up for you (see
[First run](#first-run)): WSL 2, Ubuntu 24.04 with systemd, your Linux
user, `benchbar` inside the distro, linger, the keepalive task and
`benchbar.exe` on your PATH. To do it by hand instead, see
[Set up from PowerShell](#set-up-from-powershell).

## Before you install

What Windows may show depends on how the files reach your PC. The one
line installer is the quiet route. A zip you download yourself is
marked by Windows as "from the internet", and that mark brings dialogs.

| Route | What Windows may show | What to do |
| --- | --- | --- |
| One line installer (`irm ... \| iex`) | On our Windows 11 test PC (one PC, Smart App Control off): nothing. No SmartScreen dialog, no Defender block and no administrator prompt. The files it writes carry no internet mark when it could verify the build provenance (`gh` signed in), and starting them shows no dialog then. | Nothing. |
| Zip, started with `.\install.ps1` | With the default execution policy: "cannot be loaded because running scripts is disabled on this system". `Unblock-File` does not change that. | Start it with `powershell -ExecutionPolicy Bypass -File .\install.ps1`. |
| Zip saved by a browser | Edge saves it without a warning, but marks it as downloaded (`Zone.Identifier`, ZoneId 3). Extract All in Explorer marks every file in it. `Expand-Archive` marks none. | Nothing, if you run the installer from the zip. It removes the mark from the files it installs. |
| Starting a marked program yourself | "Open File - Security Warning: The publisher could not be verified. Are you sure you want to run this software?" with **Run** and **Cancel**. The dialog can open behind other windows. | Click **Run**. If nothing seems to happen, look for a flashing icon in the taskbar. |
| The tray without the .NET runtime | Microsoft's dialog "You must install .NET Desktop Runtime to run this application." | Install the runtime: see [If Windows blocks it](#if-windows-blocks-it). |

The installer checks every file against `SHA256SUMS` first. It removes
the internet mark from the files it installs only when the zip's build
provenance verified, which needs the [GitHub CLI](https://cli.github.com)
(`gh`) signed in. The checksums come from the same release as the zip,
so they find a damaged download, not a swapped one, and they are no reason
to drop a mark that Windows put there. Without `gh`, or when the check
fails, the installer keeps the mark and says so, and Windows shows the
Open File dialog once for each program: click **Run**. A zip you run
`install.ps1` from after unpacking it has no zip left to verify, so the
mark stays there too.

### Smart App Control

Smart App Control is a Windows 11 feature. When it is on, it blocks
programs that are not signed and have no known reputation, and it has no
exception for one program. BenchBar 0.9.0 is not signed and has no
Microsoft Store package, so with Smart App Control on, Windows blocks
`benchbar.exe` and BenchBar Tray. There is no signed route in this
release.

To check: open Windows Security, then **App & browser control**, then
**Smart App Control**. It says **On**, **Evaluation** or **Off**.

What the installer does:

- **On**: it stops before it downloads or writes anything, says what
  Smart App Control is and that BenchBar is not signed, and links here.
- **Evaluation**: it warns and goes on. Windows may turn Smart App
  Control on later and block BenchBar then.
- **Off**, or a Windows without it: it goes on.

What you can do when it is on:

- **Use the command line inside WSL.** `benchbar` runs inside your Ubuntu
  24.04 distro, where Smart App Control does not apply, and it does all
  the work: install it there with the line in
  [The installer on Linux](install.md#the-installer-on-linux), then run
  `benchbar install`. You lose only the Windows parts: `benchbar.exe` in
  PowerShell and the tray. Run `wsl.exe -d Ubuntu-24.04 -- benchbar
  status` from PowerShell instead.
- **Turn Smart App Control off** in Windows Security > App & browser
  control > Smart App Control settings, then run the one line installer
  again. On some versions of Windows you cannot turn it back on without
  resetting Windows. Think about that first.
- **Wait for a signed build.** There is none in 0.9.0 and no date. See the
  [roadmap](https://github.com/askysh/benchbar/blob/main/ROADMAP.md).

With Smart App Control off, or in evaluation mode, the one line installer
is the route to use.

The installer also stops early when PowerShell runs in Constrained
Language Mode, which a company policy can set. Ask whoever manages the PC.

## First run

When BenchBar Tray starts and finds no bench, it opens the BenchBar
window at Welcome: **Set Up a New Bench**, **I Already Have a Bench** or
**Just the Command Line Tool**. **+** > New Bench opens it again later.
The command line tool step runs the
[Linux installer](install.md#the-installer-on-linux) of the same release
as `benchbar.exe` inside the distro (`install.sh` from the `v<version>`
tag, with `--version v<version>`); a development build uses `main`. To
do it by hand, run in Ubuntu:
`curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash`.

![The first run wizard at Welcome](images/windows-wizard-welcome.png)

1. **Check Your PC** lists every step with its state and a button to fix
   it: Windows version, virtualization, WSL, a pending restart, WSL
   version, the distro, the Linux user, systemd, the command line tool,
   linger, keepalive, the WSL idle settings and PATH. **Set Up
   Everything** runs the missing steps in order.
2. Turning on WSL is the only step that needs administrator rights. It
   has a shield on its button, and Windows asks for permission once. If
   you say no, nothing changes and you can try again.
3. When Windows needs a restart, **Restart Now** asks first, restarts in
   15 seconds (`shutdown /a` cancels it) and opens the wizard where it
   was when you sign in again.
4. **Linux User**: the name and password of your user in Ubuntu. The
   password is used to create the user and later for the `sudo` steps of
   the install, and is never stored.
5. **New Bench**: the folder (default `~/frappe-bench`), the site and the
   Administrator password; **Review** shows the plan of
   `benchbar install --dry-run`, with the steps that use sudo marked.
6. **Install** streams every step. Stop, Retry and Open Log are there;
   when MariaDB already has a root password BenchBar does not know, a
   field asks for it.
7. **Done**: Open Site, notifications, Open BenchBar at logon, and the
   `claude mcp add benchbar -- benchbar.exe mcp` line to copy.

Some rows in Check Your PC are advice: linger, keepalive, the WSL idle
settings and PATH. They never block **Continue**. The other rows must be
ok first.

![Check Your PC with every step ok](images/windows-wizard-check.png)

For a distro whose user the wizard did not create, BenchBar asks for
your Linux password right before the steps that use sudo.

![The New Bench page](images/windows-wizard-bench.png)

The **Profile** list on the New Bench page holds the built in profiles
(`v15-lts`, `v16-lts`) and the valid team profiles from
`benchbar.exe profile list`. It starts on `v15-lts`; the choice goes to
the install as `--profile NAME`. BenchBar asks the CLI about each
profile with a dry run (`install --dry-run --json --offline --profile
NAME`), so a profile that this Ubuntu cannot install shows off, with the
CLI's own reason under the list. If the list cannot be read, `v15-lts` is
the only choice and **Try Again** reads it again.

![Review, the plan before Install](images/windows-wizard-review.png)

Every wizard page has a **Report a Bug** button in its footer, and a
failed step has **Report This Problem** next to it. See
[Report a bug](#report-a-bug).

## Set up from PowerShell

The wizard runs these, and you can too:

```powershell
benchbar.exe setup check --json            # every step, read only
benchbar.exe setup check --json --probe    # also starts a stopped distro to check inside it
benchbar.exe setup run distro_install --jsonl
```

`setup run` takes one action at a time: `wsl_enable` (asks Windows for
permission), `wsl_update`, `distro_install`, `distro_wsl2` (converts a
distro that runs as WSL 1 to WSL 2; it stops that distro), `distro_user`
(the password in `BENCHBAR_SETUP_PASSWORD`), `systemd`, `cli_install`
(installs the command line tool in the distro, or updates an older one), `linger`,
`keepalive`, `wslconfig` and `path`. With `--jsonl` it prints only JSON
lines, and ends with one `done` line (`exit`, `changed`, `reboot_required`,
`cancelled`, `warnings`, `next_actions`). `setup` never runs `wsl --shutdown` or
`--unregister`; `systemd`, `distro_user` and `distro_wsl2` stop only that one distro.

The older commands still work: `benchbar.exe path install`,
`benchbar.exe adopt-distro`, `benchbar.exe keepalive install` and
`benchbar.exe wslconfig --apply --yes`.

## Install

In PowerShell, as yourself (no administrator rights):

```powershell
irm https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1 | iex
```

The installer checks this PC first (the CPU, PowerShell's language mode
and [Smart App Control](#smart-app-control)), then looks at the GitHub
releases for the newest published one that has a Windows zip for your CPU
(x64 or Arm64). It checks the zip against the release's
`benchbar-windows-<version>-SHA256SUMS.txt` and installs it to
`%LOCALAPPDATA%\Programs\BenchBar`. Then it:

1. removes the internet mark from the installed files when the zip's build
   provenance verified (`gh attestation verify`), and keeps it otherwise;
2. puts that folder on your user PATH (`benchbar.exe path install`);
3. checks the .NET 10 Desktop Runtime and, when `winget` is there, offers
   to install it (Windows asks for permission);
4. makes a Start menu shortcut named BenchBar, and offers a Startup
   shortcut so the tray opens at logon;
5. runs `benchbar.exe doctor`;
6. starts the tray, which opens the setup, and prints what to do next.

The tray is not started when the .NET runtime is still missing, and the
installer says why. It writes nothing inside a WSL distro; the final
doctor starts the distro if it is stopped. It uses your Windows proxy
settings, with your Windows sign in, for its downloads. When GitHub's API
says too many requests, it falls back to the release page, which needs no
API call.

After it finishes, find BenchBar in the Start menu, or as the tray icon
near the clock. Windows may hide that icon under the ^ arrow. In a
terminal, `benchbar.exe setup check` shows what is ready.

Run as a file it takes `-Version X.Y.Z` (a given release), `-NoTray`
(only `benchbar.exe`: no runtime check, no shortcuts, no tray), `-Yes` (no
questions), `-Zip PATH` (a zip you downloaded) and `-Uninstall`. To pass
them without saving a file, run the script as a script block, which sets
nothing in your session:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1))) -Version X.Y.Z
```

Piped into `iex`, set `BENCHBAR_VERSION`, `BENCHBAR_NO_TRAY=1`,
`BENCHBAR_YES=1`, `BENCHBAR_ZIP=PATH` or `BENCHBAR_UNINSTALL=1` first.
These variables stay set in that PowerShell window, so remove them
afterwards (for example `Remove-Item Env:BENCHBAR_VERSION`).

To run it as a file, download `install.ps1` and start it with
`powershell -ExecutionPolicy Bypass -File .\install.ps1 ...`. The default
execution policy refuses a script file, and `Unblock-File` does not
change that.

Without the script: download `benchbar-windows-<version>-amd64.zip` (or
`-arm64.zip`) from the [releases](https://github.com/askysh/benchbar/releases),
check it (see [Verify a download](#verify-a-download)), unpack it into a
folder of your choice and run `benchbar.exe path install` from there.

### A test build you were sent

Every zip carries `install.ps1`, so a build that is not on a release
installs the same way, from its own folder:

1. Unpack the whole zip (right click, Extract All) into a new folder, for
   example in Downloads. `benchbar-windows-<version>-amd64.zip` is for
   Intel and AMD PCs, `-arm64.zip` for Arm PCs.
2. Open PowerShell in that folder and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

It checks every file against the `SHA256SUMS` in the zip, installs to
`%LOCALAPPDATA%\Programs\BenchBar` as above, and ends with
`benchbar.exe doctor`. To keep the zip unpacked, pass it instead:
`.\install.ps1 -Zip .\benchbar-windows-<version>-amd64.zip`. A checksums
file next to the zip is checked too when there is one.

Extract All in Explorer marks every file as downloaded. The installer
removes that mark from the copies it installs, so the programs start
without a dialog. Start a program from the unpacked folder yourself, and
Windows shows the Open File dialog (see [Before you install](#before-you-install)).

### Verify a download

Each release has `benchbar-windows-<version>-SHA256SUMS.txt`. Compare it
with the zip:

```powershell
(Get-FileHash .\benchbar-windows-<version>-amd64.zip -Algorithm SHA256).Hash
```

The installer does this for you. Releases after 0.8.2 also carry a build
provenance attestation, made by the release workflow. It proves that the
zip was built from this repository by GitHub Actions. The installer
checks it when `gh` is installed and signed in, and says so when it
cannot. The checksums file is attested too. With the
[GitHub CLI](https://cli.github.com):

```powershell
gh attestation verify benchbar-windows-<version>-amd64.zip -R askysh/benchbar `
  --signer-workflow askysh/benchbar/.github/workflows/release-windows.yml
```

## If Windows blocks it

**Smart App Control** says BenchBar is blocked, or the installer stops
with "Smart App Control is on". See [Smart App Control](#smart-app-control).

**"Open File - Security Warning: The publisher could not be verified."**
The file carries an internet mark, for example because you started a
program from an unpacked zip. Click **Run**. The dialog can open behind
other windows. The installer removes the mark from what it installs when it verified
the zip's build provenance (`gh` signed in). Without that, you see this
once for each program. To remove the mark yourself, once you have checked
the zip, run
`Get-ChildItem "$env:LOCALAPPDATA\Programs\BenchBar" -Recurse | Unblock-File`.

**Microsoft Defender or another antivirus removes a file**, or the
installer says a file "contains a virus or potentially unwanted software"
(error 0x800700E1). BenchBar is not malware, but a new program without a
signature is sometimes flagged by mistake. On our Windows 11 test PC,
Defender scans of the zip and the install folder were clean, and Defender
sent `benchbar.exe` to Microsoft for cloud analysis once.

1. Open Windows Security > Virus & threat protection > **Protection
   history**.
2. Find the BenchBar item, choose **Actions**, then **Allow on device**.
3. Run the installer again.

To tell Microsoft it is a false positive, send the file at
<https://www.microsoft.com/wdsi/filesubmission>.

**"You must install .NET Desktop Runtime to run this application."**
BenchBar Tray needs the .NET 10 Desktop Runtime, and this dialog is
Microsoft's. Install it, then start BenchBar again:

```powershell
winget install --id Microsoft.DotNet.DesktopRuntime.10 -e
```

Without `winget`, download the **.NET 10 Desktop Runtime** (x64 or Arm64,
like your PC) from <https://dotnet.microsoft.com/download/dotnet/10.0>.
The installer offers to run the `winget` line and does not start the
tray while the runtime is missing.

## Signing and verification

The Windows programs (`benchbar.exe`, `BenchBarTray.exe` and the tray's
own DLLs) are not signed, and 0.9.0 has no signed or Microsoft Store
route: SignPath Foundation declined the project on 2026-11-13, and a
Store package is not part of this release. In practice that means: Smart
App Control blocks them (see [Smart App Control](#smart-app-control)),
and a program you start from an unpacked zip shows the "Open File -
Security Warning" dialog. See [Before you install](#before-you-install)
for what to expect on each route.

You can still check what you download:

- Every release has `benchbar-windows-<version>-SHA256SUMS.txt`, and every
  zip holds a `SHA256SUMS` file. The installer checks them.
- From the next release on, each zip also has a build provenance
  attestation that you can verify. See [Verify a download](#verify-a-download).
- Check a signature in PowerShell:
  `Get-AuthenticodeSignature "$env:LOCALAPPDATA\Programs\BenchBar\benchbar.exe"`
  shows `NotSigned` today.

Privacy: neither program sends data anywhere except to GitHub's release
list, for the update check described under [Settings](windows-tray.md#settings). Report
a Bug writes its zip on your PC, and sends nothing until you post the
issue yourself.

## The tray

The tray has its own page: [The BenchBar tray](windows-tray.md). It covers the
flyout, the BenchBar window, the settings, `benchbar://` links and what the
tray costs.

## Report a bug

Report a Bug is in the tray menu, in About, in the beta banner, in the
footer of every wizard page, and next to each failed step (Report This
Problem). All of them do the same thing:

1. They run `benchbar.exe report-windows --json`. It writes a redacted
   zip to `%LOCALAPPDATA%\BenchBar\reports` and keeps the newest 10.
2. A small window says that the report is ready. It selects the zip in
   Explorer and opens a GitHub issue with the Windows bug form filled in
   (versions, Windows edition, distro and what you did). Show Zip and
   Open Issue do this again, and Copy Path copies the zip path.
3. Drag the zip from Explorer into the last box of the form, say what
   happened, and submit.

The zip holds the versions, the Windows edition and build, the WSL status
and distro list, the setup check (run without starting a distro) and,
when the distro runs, the CLI's own report. User names and home paths
become `<user>`, and it holds no passwords. The full list is in
[windows/shim/README.md](https://github.com/askysh/benchbar/blob/main/windows/shim/README.md#bug-report-zip).

Report a Bug works with no WSL, with a stopped distro (it never starts
one) and with no CLI installed. If `benchbar.exe` cannot start, the tray
writes a smaller zip with its own log only.

For a security problem, do not use the form. See
[SECURITY.md](https://github.com/askysh/benchbar/blob/main/SECURITY.md).

## Update

In the app: when a newer release is out, the BenchBar window, the tray
menu and About show **Update Now**. It runs the update in its own window,
closes BenchBar, and starts it again when the update is done.

In a terminal:

```powershell
benchbar.exe self-update
```

It shows the version you have and the newest release, asks once, then
updates all of BenchBar for Windows to that release: `benchbar.exe`, the
tray app and the BenchBar CLI inside WSL. It runs the installer of that
release for you: `install.ps1` of the release's tag, downloaded and
compared with the release's SHA256 sums before it runs, not whatever is on
`main`. The installer checks the new files against the same sums, and
Windows shows no SmartScreen dialog for them when the zip's build
provenance verified (see [Verify a download](#verify-a-download)). The tray app closes and starts
again. It ends with one line for each part. Your settings, benches and sites
stay as they are.

- `benchbar.exe self-update --check` only looks: the version you have, the
  newest release and the CLI in WSL. `--json` gives the same as JSON.
- `--yes` does not ask. `--version X.Y.Z` installs that release, also an
  older one, or a release candidate (`0.9.0-rc.1`), which the check and a
  plain `self-update` never offer.
- With no distro set up yet, the CLI part is skipped: the setup installs it.
- BenchBar is not in the Microsoft Store. A copy that runs from an MSIX
  package, which no release ships yet, is updated by its package, and
  `self-update` changes nothing there.

Running the one line installer again does the same for `benchbar.exe` and
the tray. It finds the newest release that has a Windows zip, closes the
tray (it asks the tray to close first), replaces the files, removes files
the new version no longer has, and starts the tray again when it was
running. An update keeps your choices: it adds no Startup shortcut and does
not open the setup again. It ends with the version it updated from and to.
It does not change anything inside the distro: run `benchbar.exe
self-update` afterwards, or `benchbar.exe setup run cli_install`, to bring
the CLI in WSL to the same release. `benchbar.exe setup check` and
`benchbar.exe doctor` say when the two differ.

## Uninstall

Uninstalling BenchBar for Windows removes the two programs and what
belongs to them. It keeps WSL, the distro and your benches.

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

Run it from a copy of `install.ps1` (a zip carries one, and so does the
install folder of a full install), or through the one line installer with
`$env:BENCHBAR_UNINSTALL = '1'` set first. It asks once, and `-Yes` skips
the question. With no terminal to answer on (input is redirected) and no
`-Yes`, the answer is no and nothing is removed: add `-Yes` (or set
`BENCHBAR_YES=1`) to confirm. Then it:

1. closes the tray;
2. removes the keepalive task (`benchbar.exe keepalive remove`);
3. removes the Start menu shortcut, the Startup shortcut and the setup
   resume shortcut. It removes only a `.lnk` file in the Start menu, the
   Startup folder or the install folder that points to the installed tray
   app; any other shortcut stays;
4. removes the `benchbar://` registration, when it points to the installed
   tray app;
5. removes the install folder from your user PATH;
6. removes the files it installed (the list is `.installed-files.txt` in
   the install folder) and the folder, when it is empty.

It never touches WSL, your distro, your benches or
`%USERPROFILE%\.wslconfig`. Your settings, runners and reports stay in
`%LOCALAPPDATA%\BenchBar`. Delete that folder too when you no longer want
them.

To do it by hand instead:

1. Run `benchbar.exe keepalive remove` while `benchbar.exe` is still
   there. It removes the keepalive task.
2. Quit the tray from its right click menu.
3. Delete the **BenchBar Tray** shortcut in your Startup folder (open it
   with Run, `shell:startup`), the **BenchBar Setup Resume** shortcut if
   there is one, and the **BenchBar** shortcut in the Start menu (Run,
   `shell:programs`).
4. Delete the registry key `HKEY_CURRENT_USER\Software\Classes\benchbar`
   (Registry Editor), when its command points to `BenchBarTray.exe`.
5. Remove `%LOCALAPPDATA%\Programs\BenchBar` from your user PATH: run
   `benchbar.exe path remove` while `benchbar.exe` is still there, or open
   Environment Variables (search for it in Start), edit the user `Path`
   and delete the entry for that folder.
6. Delete the folder `%LOCALAPPDATA%\Programs\BenchBar`.

### Removing the distro

To remove the Linux distro as well, run this in PowerShell:

```powershell
wsl --unregister Ubuntu-24.04
```

Warning: this deletes everything inside the distro, including every bench,
site and database in it, and it cannot be undone. Copy what you need out
of the distro first. `wsl --list --verbose` shows the distro names.

## `*.localhost` names

A site on a `*.localhost` name (for example `mysite.localhost:8000`)
opens in Edge, Chrome and `curl.exe` on Windows, because WSL forwards
`localhost` to the distro. PowerShell's `Invoke-WebRequest`, `ping` and the
Windows resolver do not resolve such a name. In PowerShell, use
`curl.exe`, with the `.exe`, because `curl` is an alias of
`Invoke-WebRequest` there:

```powershell
curl.exe http://mysite.localhost:8000
curl.exe -H "Host: mysite.localhost" http://localhost:8000
```

The second line asks `localhost` for the site by its name, which is the
same request.

Since 0.9.0 a bench's web server and socketio listen on 127.0.0.1 inside the
distro, not on every interface. That does not change this: WSL 2 forwards
`localhost` from Windows to a port bound to 127.0.0.1 in the distro, and so
does mirrored networking mode (`localhostForwarding`, Microsoft's
documentation of the `[wsl2]` settings says ports bound to the wildcard or to
localhost are forwarded). What stops working is reaching the bench by the
distro's own address, or from another device: run `benchbar listen all` in
the distro for that, and see the [warning on `listen`](reference/cli/other.md#listen).

If you set `localhostForwarding=false` under `[wsl2]` in
`%USERPROFILE%\.wslconfig`, Windows cannot reach any bench at all. Remove
the line, or set it to `true`, and restart WSL (`wsl --shutdown` stops
every distro, so stop your benches first).

## Troubleshooting

- **Docker Desktop is the default distro.** `wsl --list` can show
  `docker-desktop` as the default. BenchBar skips it, and the other tool
  distros that Docker Desktop, Rancher Desktop and Podman add, and uses
  your Ubuntu. Choose another distro in Settings, or run
  `benchbar.exe adopt-distro`.
- **The distro runs as WSL 1.** Benches need WSL 2. The setup check says
  so. Run `benchbar.exe setup run distro_wsl2` to convert it. It stops
  that distro, so stop your benches first.
- **The distro is not Ubuntu 24.04.** Only Ubuntu 24.04 is supported. The
  setup check says so. Install it next to the other one with
  `wsl --install -d Ubuntu-24.04` and choose it with
  `benchbar.exe adopt-distro`.
- **"Do not run benchbar as root or with sudo."** The distro's default user
  is `root`, so every command runs as root and `benchbar` refuses (exit 64,
  `error_id` `root_refused`; with `--json` the refusal is JSON). This happens
  when the distro was imported from a tarball or set up without a user. Create
  a normal user and make it the default. In PowerShell:
  `wsl -d Ubuntu-24.04 -u root -- adduser --gecos "" YOURNAME`, then
  `wsl -d Ubuntu-24.04 -u root -- usermod -aG sudo YOURNAME`, then
  `wsl -d Ubuntu-24.04 -u root -- sh -c "printf '[user]\ndefault=YOURNAME\n' >> /etc/wsl.conf"`,
  then `wsl --terminate Ubuntu-24.04`. Install BenchBar again for that user
  (`benchbar.exe setup run` or the install line from inside the distro), as
  the files `root` made are not the new user's.
- **A `benchbar://` link does nothing.** The tray has to be installed
  (or have started once) so that it registered the scheme, and the link
  must be one of the routes. Open the [URL scheme](reference/url-scheme.md)
  page for the list. A link that is ignored is written to
  `%LOCALAPPDATA%\BenchBar\tray.log` with its action only. If another
  program owns `benchbar://`, the log says "registered to another
  program: left alone"; the tray does not take it over.
- **A Windows path as an argument.** `benchbar.exe adopt C:\Users\you\bench`
  is accepted as a path: the shim turns a drive path such as `C:\...` into
  `/mnt/c/...`, and a `\\wsl.localhost\Ubuntu-24.04\...` path of the same
  distro into its Linux path. But `adopt` and `install` refuse a bench on
  the Windows file system (error `bench_on_windows_fs`), because it is
  slow and file watching does not work there. Keep benches in the distro's
  own file system, under your Linux home. If you accept the problems,
  `--allow-windows-fs` overrides the refusal.
- **A relative path.** `benchbar.exe` starts the command in the folder you
  run it in, so `benchbar.exe adopt .`, `--bench-dir .\bench` and
  `site restore --from backup.sql.gz` mean that folder. This works for a
  drive folder (`C:\work`), a network folder and a `\\wsl.localhost` folder
  of your distro. A folder of another distro, or one the distro cannot
  see (a missing folder, a drive WSL does not mount), starts in your Linux
  home instead, and `benchbar.exe` says so with one line on stderr:
  `benchbar.exe: <folder> has no path in WSL, running in ~`. Stdout is not
  touched, so `--json` output stays one document. Check that line before you
  run a command such as `adopt .` or `ports plan -- .`: it would act on your
  home folder, not on the folder you meant. `.\x` and `..\x` are turned into
  `./x` and `../x`; write other relative paths with `/`.
- **Environment variables.** `benchbar.exe` passes `ADMIN_PASSWORD`,
  `MARIADB_ROOT_PASSWORD`, `BENCHBAR_SUDO`, `BENCHBAR_SUDO_PASSWORD`,
  `BENCHBAR_NONINTERACTIVE`, `BENCHBAR_LABS`, `BENCH_INIT_TIMEOUT_SECONDS`,
  `BENCHBAR_PROFILE_PATH` (a Linux path of the distro), the
  `BENCHBAR_MCP_TIMEOUT`, `_MAX_BYTES`, `_KILL_GRACE` and `_EOF_GRACE`
  settings and your proxy variables into WSL. No other variable is passed.
  A caller that has no terminal can send the passwords on standard input
  instead (`benchbar.exe install --secrets-stdin`, `KEY=VALUE` lines): stdin
  goes through the shim and `wsl.exe` unchanged, and a password sent that way
  is in no process's environment. See
  [install](reference/cli/install.md#passwords-without-the-environment).
- **The tray does not open at logon.** The tray's **Open BenchBar at
  logon** makes a shortcut in your Startup folder. Windows can switch a Startup
  entry off in Settings > Apps > Startup. Turn **BenchBar Tray** on there.
- **The PC went to sleep during the setup.** Sleep, or a closed lid, stops
  the steps that run inside WSL. Keep the PC awake (Settings > System >
  Power) until the wizard says Done. Every step can be run again, so
  start **Set Up Everything** again.

## What the tray does not do

- The runner in the notification area runs at one speed. The Overview charts
  the bench's CPU and the runner speed (`benchbar stats`) while it is on
  screen, but sampling it for the icon would keep a timer running at rest.
- It has no entry for `benchbar site hosts --prune`. That command is for the
  macOS hosts file, and the tray never edits the Windows one (a `*.localhost`
  name needs no line).
- It never reads files inside the distro: every fact comes from
  `benchbar.exe`.
- Quick Switch has a global shortcut only when you turn it on in Settings
  (see above). Open as needs a `*.localhost` name, which the Windows browser reaches
  without a hosts line (see [`*.localhost` names](#localhost-names)). See
  [benchbar open](reference/cli/other.md).
- The tray joins a room as a guest by the room's address and code, not by
  an invite link: **Join a room...** on the **Sharing** tab (see
  [Rooms on Windows](#rooms-on-windows)). The room code exchange, the pinned
  certificate and the local forwarder run in the distribution through
  `benchbar share join`; the room opens in the Windows browser on a
  `localhost` address. For an invite link run `benchbar share join` in WSL.
  A `benchbar://share/...` link shows a note in the tray. Hosting a room is
  the **Sharing** tab above.

## Rooms on Windows

A room is the host side of **Share with people on the same Wi-Fi**. The bench runs in WSL, so the room's
address is the one WSL has, and that depends on WSL's networking mode:

- **NAT (the default).** WSL has a private address that only this PC can reach. Nobody on the Wi-Fi can join
  a room there, and the checks run inside WSL, so they would pass without telling you. A room is not available on
  WSL NAT: `share preflight`, `share start` and `share invite` refuse and say so.
- **Mirrored.** WSL shares the PC's own Wi-Fi address. Put `networkingMode=mirrored` under `[wsl2]` in
  `%UserProfile%\.wslconfig` (Windows 11 22H2 or later; BenchBar never edits that file), then run
  `wsl.exe --shutdown`. Windows still drops inbound connections to WSL until its Hyper-V firewall allows the
  room's port. Run this once in a PowerShell opened as administrator:

  ```powershell
  New-NetFirewallHyperVRule -Name BenchBarRoom -DisplayName "BenchBar room" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 8443
  ```

  `share preflight` and `share start` show this line as a warning, and `share start` goes on. The other way,
  `Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Allow`,
  opens every port of WSL, so the rule above is the narrower one. Microsoft documents both under
  [mirrored mode networking](https://learn.microsoft.com/windows/wsl/networking#mirrored-mode-networking).

BenchBar reads the mode with `wslinfo --networking-mode`; a WSL that has no `wslinfo` counts as NAT.

**Joining a room** needs neither mode: a guest only connects out, and the browser opens the room on `localhost`
through WSL's localhost forwarding (on unless `.wslconfig` says `localhostForwarding=false`). The **Sharing** tab
has **Join a room...** (address, a look at the room and its host key, then the code). See
[Join a room](guides/share-on-your-network.md#in-the-windows-tray).

The **Sharing** tab has a box, **I give out the seats**, under **Start sharing**. With it ticked, a
person who joins waits: the tab says how many people wait, and under each name there is a list of
the free seats with their roles and a button, **Give NAME this seat**. For a person who has a seat
the same button moves them to the seat picked. Without the tick, guests pick their own seat.

## Labs

Labs work the same on Windows. The **Labs** page of the BenchBar window
and `benchbar.exe labs list` show them, and the ones that are not on
Windows yet say so. `benchbar.exe labs on NAME` asks first in PowerShell.
Turning one on is a person's decision, so an agent with
`BENCHBAR_NONINTERACTIVE=1` is refused; the tray's switch is your click,
so it runs the same call with the question already answered. See
[labs](reference/cli/labs.md).
