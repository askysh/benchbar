# Security policy

## Reporting a vulnerability

Please report it privately, never in a public issue, discussion or pull
request: open a report at
[github.com/askysh/benchbar/security/advisories/new](https://github.com/askysh/benchbar/security/advisories/new)
(Security, then Report a vulnerability). Only the maintainers can read
it. If you cannot use GitHub, email
[mail@akashmishra.com](mailto:mail@akashmishra.com). You get an answer within a week, and a fix or a plan for one before
anything is disclosed. Say whether you want credit in the advisory.

Include what you ran, the macOS version, `benchbar --version`, and what
an attacker gains. A proof of concept helps; please use a throwaway
bench, never someone else's machine or data.

## What counts

BenchBar runs with your user's rights and, twice per install, with
`sudo`. Report anything in these areas, even when you are not sure it is
exploitable:

- **The Keychain.** Anything that reads, writes or prints the MariaDB
  root password or another stored secret where it should not, or lets
  another program get it.
- **sudo.** Anything that runs more than the `/etc/hosts` line and the
  wkhtmltopdf package with `sudo`, or lets input reach those commands.
- **A site or a database.** Anything that drops, overwrites or exposes a
  site, a database or a backup without the confirmation the command
  promises (`pull`, `repair`, `adopt`, `app update`, `site add`).
- **`benchbar report`.** A password, key, token, path or name that ends
  up in the report zip or in `report --print`.
- **Secrets elsewhere.** A token or password in logs under
  `.benchbar/logs/`, in `--json` output, in a lockfile, or in a git
  remote.
- **The app and the MCP server.** A way for another local program or a
  web page to make BenchBar or `benchbar mcp` run a command.
- **The installer and releases.** A way to make `install.sh` or a
  release download run code it should not.

Not a vulnerability: a bench's own Frappe or ERPNext code (report those
to [Frappe](https://github.com/frappe/frappe/security)), and a dev bench
reachable on your local network because you bound it there.

## Supported versions

Only the latest release gets security fixes. Update with the installer
or from the app before you report.
