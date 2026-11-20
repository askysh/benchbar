# Security policy

## Reporting a vulnerability

Please report it privately, never in a public issue, discussion or pull
request: open a report at
[github.com/askysh/benchbar/security/advisories/new](https://github.com/askysh/benchbar/security/advisories/new)
(Security, then Report a vulnerability). Only the maintainers can read
it. If you cannot use GitHub, email
[mail@akashmishra.com](mailto:mail@akashmishra.com). You get an answer within a week, and a fix or a plan for one before
anything is disclosed. Say whether you want credit in the advisory.

Include what you ran, the OS (the macOS version, the Ubuntu version, or
the Windows edition and build with the WSL distro), the version
(`benchbar --version`, or the versions in the tray's About window) and what
an attacker gains. A proof of concept helps; please use a throwaway
bench, never someone else's machine or data.

## What counts

BenchBar runs with your user's rights and, in the few steps listed
below, with `sudo`. Report anything in these areas, even when you are not sure it is
exploitable:

- **The Keychain.** Anything that reads, writes or prints the MariaDB
  root password or another stored secret where it should not, or lets
  another program get it. On Linux the root password is not in a
  Keychain. It is a 0600 file in a 0700 folder under the state folder
  (`$XDG_STATE_HOME/benchbar`). A file that other users can read, or a
  password that reaches a log, the command line or a child process,
  counts.
- **sudo.** Anything that runs `sudo` for more than its platform's list,
  or lets input reach those commands. The list is the same in
  [AGENTS.md](AGENTS.md). On macOS it is the `/etc/hosts`
  line, the wkhtmltopdf package (with Rosetta 2 when the package needs
  it), the LAN guard (`lan-guard install` and
  `remove`: the pf anchor and its launch daemon) and the firewall allow
  for node (`lan-guard allow-node`). On Linux it is apt (the packages and
  the wkhtmltopdf `.deb`), the MariaDB admin step (`sudo mariadb`, its
  config drop-in and a restart), and starting a stopped `mariadb` or
  `redis-server`. On Windows only `System32\wsl.exe --install --no-distribution`
  is elevated, through the UAC prompt.
- **BENCHBAR_SUDO_PASSWORD.** On Linux, with `BENCHBAR_SUDO=env`, the
  password is read once at start and removed from the environment. Report
  anything that puts it in the command line, a log, a report zip or a
  child process.
- **Sharing (the `lan-rooms` Lab).** A room opens a hardened copy of a
  site to people on your Wi-Fi. These parts can break and count: the
  gateway on port 8443 and its allow list, the room code and the join
  protocol (ten wrong codes lock a room), a guest seeing more than their
  seat's user can open, the pinned certificate and the guest identity
  (`BenchBar Share Identity` in the Keychain), the control socket (mode
  0600), the checks that end a share when a protection fails, the LAN
  guard (`lan-guard`: the pf anchor and its launch daemon) and the refusal
  of a request with another `Host` (`bad_host`, DNS rebinding). Also in
  scope: a way to reach the site, another bench or any bench port from the
  network without a room, the room code in a file, a log or JSON other than
  `share code` and `share invite`, and a share that stays on after a
  check failed. What a room shows its guests on purpose, and the limits it
  states in [How sharing keeps your bench safe](docs/concepts/sharing-safety.md),
  are not bugs.
- **Labs.** A Lab that is off must stay off: its commands refuse to run, and
  `BENCHBAR_LABS` cannot turn on a Lab the platform does not list.
- **Open as.** A sign in as another user on a site where the person has not
  turned Open as on, turning it on without a person (`site open-as on` is
  refused under `--for-agent` and `benchbar mcp`), or a login link
  (`open --as --print-url`) that reaches a log or an agent.
- **The MCP tools that change things.** `benchbar mcp` offers `benchbar_up`,
  `benchbar_down`, `benchbar_restart`, `benchbar_site_backup` and the
  appliers `benchbar_app_add`, `benchbar_site_add`, `benchbar_site_restore`
  and `benchbar_service_install`. Each applier needs the token of its plan.
  Report a way to apply without the plan, a token that outlives a change
  of the bench, an argument that becomes a different command or option, or
  any path from a tool to `repair`, `install`, `sudo`, `lan-guard`,
  `listen all`, `labs on`, the MariaDB root password or a login link, all of
  which agents never get. Text from a bench (a log line, a git message) must
  come back labeled as data. The token proves only that the bench did not
  change since the plan. Your client's approval of the applier is the gate
  for a person, and this policy does not promise more.
- **A bench open to the network.** The web server and socketio of a bench
  must listen on 127.0.0.1 unless the person ran `benchbar listen all`.
  A bench that listens on a network address with `listen` at its default
  is a bug, on macOS, Linux and WSL alike.
- **A site or a database.** Anything that drops, overwrites or exposes a
  site, a database or a backup without the confirmation the command
  promises (`pull`, `repair`, `adopt`, `app update`, `site add`).
- **`benchbar report` and Report a Bug.** A password, key, token, path or
  name that ends up in the report zip, in `report --print` or in the
  Windows zip from `report-windows`.
- **Secrets elsewhere.** A token or password in logs under
  `.benchbar/logs/`, in `--json` output, in a lockfile, or in a git
  remote.
- **The app and the MCP server.** A way for another local program or a
  web page to make BenchBar or `benchbar mcp` run a command.
- **The installer and releases.** A way to make `install.sh` or a
  release download run code it should not.

## What the installers verify

A checksum from the same release only finds a damaged download. Since
0.9.0 the release workflow also attests the build provenance of the DMG,
the app zip, the CLI tarball, `SHA256SUMS` (`release.yml`) and the Windows
zips and their checksums file (`release-windows.yml`), so
`gh attestation verify FILE -R askysh/benchbar` says that this
repository's workflow built the file. The tap workflow
(`homebrew-tap.yml`) verifies every file before it renders the formula.

- `install.sh` on a Mac checks the zip's attestation when `gh` is installed
  and signed in, and refuses on a failure. Without `gh` it says that only
  the checksum was checked and prints the command. It then runs
  `codesign --verify --deep --strict` and `spctl --assess` on the unpacked
  app, which `curl` would otherwise skip because it sets no quarantine
  flag.
- `install.ps1` removes Windows' internet mark only when the zip's
  attestation verified.

- `benchbar self-update` and `benchbar.exe self-update` run the installer
  of the release they install, after checking its SHA256 against that
  release's sums, not whatever `main` holds at that moment. The Mac CLI
  is checked out at the release's tag. Installing the CLI inside WSL from
  a release build of `benchbar.exe` follows the same rule.

What this does not cover: an attestation proves where a file was built,
not that the code is good. A `gh` that is not signed in leaves only the
checksum. On Linux `install.sh` downloads no file: git fetches the CLI
over https.

## The Keychain items

BenchBar for macOS keeps two kinds of item. One is the MariaDB root
password, described below. The other is the guest identity of this Mac,
`BenchBar Share Identity`: a P-256 key that cannot be exported and a
self-signed certificate, made when you first join a room. Every host knows
this Mac by that key. Linux and Windows have no Keychain: the password
file is described above.

`benchbar` keeps the MariaDB root password in your login Keychain as the
generic password `benchbar-mariadb` (account `root`). The item trusts one
application, `/usr/bin/security`, which is how `benchbar` and
`benchbar mariadb-password` read it without a prompt. That is also a
limit: any program running as your user can read the item through
`security find-generic-password -s benchbar-mariadb -w` without a prompt,
because a command line tool has no code signature of its own for the
Keychain to trust. The item is written through `security -i`, so the
password is never a command line argument.

If you want macOS to ask before every read, remove the trusted
application: open Keychain Access, find `benchbar-mariadb`, open its
Access Control tab and either choose "Confirm before allowing access" or
remove `security` from the list of allowed applications. macOS then shows
its password dialog each time `benchbar` needs the root password; a run
with no window session to show it in (an agent over SSH, `--yes` in a
pipeline) ends with the "MariaDB root password unknown" message and exit
code 2, and `MARIADB_ROOT_PASSWORD='...'` in the environment is the way
around it.

Not a vulnerability: a bench's own Frappe or ERPNext code (report those
to [Frappe](https://github.com/frappe/frappe/security)), and a dev bench
reachable on your local network because you chose it (`benchbar listen
all`, which asks first and which agents cannot run). This does not cover a
room: a room is a feature that shares on purpose, and a bypass of it
counts (see Sharing above). Since 0.9.0 the web server and socketio of a
bench listen on 127.0.0.1 by default. Before 0.9.0 the generated Procfile
started them on every interface (Frappe's own default). That is fixed, and
`benchbar doctor` warns about a bench that still listens on a network
address with `listen` at its default.

## Supported versions

Only the latest release gets security fixes. It is the release that
Homebrew, the one line installer, the app's update and `benchbar
self-update` give you. There is no other channel. Update before you
report, and say which version you tested.
