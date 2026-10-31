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

BenchBar runs with your user's rights and, twice per install, with
`sudo`. Report anything in these areas, even when you are not sure it is
exploitable:

- **The Keychain.** Anything that reads, writes or prints the MariaDB
  root password or another stored secret where it should not, or lets
  another program get it. On Linux the root password is not in a
  Keychain. It is a 0600 file in a 0700 folder under the state folder
  (`$XDG_STATE_HOME/benchbar`). A file that other users can read, or a
  password that reaches a log, the command line or a child process,
  counts.
- **sudo.** Anything that runs `sudo` for more than its platform's list,
  or lets input reach those commands. On macOS the list is the `/etc/hosts`
  line and the wkhtmltopdf package. On Linux it is apt (the packages and
  the wkhtmltopdf `.deb`), the MariaDB admin step (`sudo mariadb`, its
  config drop-in and a restart), and starting a stopped `mariadb` or
  `redis-server`. On Windows only `System32\wsl.exe --install --no-distribution`
  is elevated, through the UAC prompt.
- **BENCHBAR_SUDO_PASSWORD.** On Linux, with `BENCHBAR_SUDO=env`, the
  password is read once at start and removed from the environment. Report
  anything that puts it in the command line, a log, a report zip or a
  child process.
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

## The Keychain item

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
reachable on your local network because you bound it there.

## Supported versions

Only the latest release gets security fixes. Update with the installer
or from the app before you report.
