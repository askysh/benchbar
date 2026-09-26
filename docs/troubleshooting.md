---
title: "Troubleshooting"
description: "Common stumbles with a local Frappe bench on macOS, the cleanup tool case, what benchbar writes, and how to wipe a bench."
---

Start with `benchbar doctor`. It is read only, every warning and failure
names its fix, and `benchbar repair` applies the fixes it flagged. The
full command output of every mutating run is in
`.benchbar/logs/<timestamp>.log` inside the checkout, and the backups of
every replaced file in `.benchbar/backups/<timestamp>/`.

## Common stumbles

**`benchup: command not found`.** Run `source ~/.zshrc` once, or open a
new Terminal tab.

**`benchstatus` says `stop flag crash`.** The bench crashed three times in
ten minutes and paused itself. `benchlogs` shows why, and `--previous`
shows the run before. Fix the cause, then `benchup`.

**The site loads without styling.** Run `benchbar doctor`. If the built
assets are missing, `benchbar repair` runs `bench build`.

**`bench: command not found` after phase 2.** pipx installs to
`~/.local/bin`. Run `pipx ensurepath` and open a new Terminal.

**The browser cannot connect to `macdev`.** The `/etc/hosts` line is
missing. `benchbar repair` adds it, or run
`printf '127.0.0.1 macdev\n' | sudo tee -a /etc/hosts`.

**MariaDB rejects the root password.** `benchbar mariadb-password` prints
the one in the Keychain; confirm it with `mariadb -u root -p` in another
tab. If it changed, run `MARIADB_ROOT_PASSWORD='...' benchbar install`
once to verify and save the new one. Forgotten entirely: phase 00 prints
the reset recipe (stop MariaDB, start `mariadbd-safe --skip-grant-tables`,
`ALTER USER`), which keeps the databases.

**Phase 00 stops: "MariaDB root already has a password".** A bench set
up before 0.3 never stored the root password in the Keychain. Type it when
asked (it is verified and saved), or pass `MARIADB_ROOT_PASSWORD`. If
nobody knows it, the reset above keeps every database; stop your benches
first (`benchbar down --bench-dir ...`) so they do not lose their
database mid request, and bring them back with `benchbar up` afterwards.

**`bench init` fails with "Operation not permitted" on crontab.** On
macOS 14 and later a Terminal without Full Disk Access may not write a
crontab, and bench then offers to delete the new bench (frappe/bench#1730,
open). benchbar runs `bench init --no-backups`, which needs no crontab,
and doctor's `full_disk_access` check says when the Terminal lacks it. To
use `bench setup backups` later: System Settings > Privacy & Security >
Full Disk Access, add Terminal, open a new window.

**Two benches, and one crashes when the other starts.** Both benches need
runner template v3 (0.4): an older runner clears every `socketio.js` on
the Mac when its bench starts. `benchbar doctor` on each bench says
"runner is outdated" until `benchbar repair --bench-dir ...` rewrites it.

**A v16 bench and MariaDB 10.11.** Frappe v16 accepts MariaDB 10.6 to
11.8, so a v16 bench shares the `mariadb@10.11` server a v15 bench runs;
benchbar detects the running server and does not install `mariadb@11.8`.
A second MariaDB (11.8 on another port) is not needed for development.

**Phase 2 says the bench has apps or sites but no env.** That is the
cleanup tool case below. Run `benchbar repair`, not the installer.

**The runner is reported outdated after an update.** The runner script
carries the CLI version. `benchbar repair` rewrites it; the bench keeps
running and picks the new runner up on its next start.

**PDFs do not print.** wkhtmltopdf was skipped or is the Homebrew build.
`benchbar doctor` says which; `benchbar repair` installs the official
patched Qt package (Intel binary, Rosetta 2 offered on Apple Silicon,
`sudo` once). If a Homebrew wkhtmltopdf earlier on `PATH` shadows the
package, doctor says so: `brew uninstall wkhtmltopdf`.

**Passwords do not decrypt after a restore.** Frappe says "Encryption key
is invalid! Please check site_config.json", an Email Account stops
connecting, or `benchbar pull` warns that stored passwords do not
decrypt. Frappe encrypts every stored password (email accounts,
integrations, `Password` fields) with `encryption_key` from the site's
`site_config.json`, and `bench restore` never copies it: a restored site
without it generates a new key, which cannot read the old rows.
`benchbar pull` copies the production key for you. After a restore by
hand, or when production had no key, copy `encryption_key` from the
production `site_config.json` into the local one (only that key; the
database password and Redis settings there belong to production), then
`bench --site SITE clear-cache`. When the production key is lost, the
passwords are too: enter them again in the copy.

**Something else.** `benchbar report` writes a redacted zip for a bug
report; attach it to an issue at
<https://github.com/askysh/benchbar/issues>.

## The cleanup tool case

A cleanup tool (most often CleanMyMac's developer junk cleanup) can delete
`env/`, `node_modules/` and `apps/*/public/dist`. The symptoms:

- `bench` commands fail with `FileNotFoundError` for `env/bin/python`,
- socketio fails with `Cannot find module 'socket.io'`,
- the site loads with no styling because `/assets/*/dist/*.bundle.*`
  returns 404, although `sites/assets/assets.json` still exists.

Doctor detects all three separately (it checks the dist files that
`assets.json` references), and repair rebuilds only what is missing: the
env (the old one moved to `env.broken.<timestamp>`), the node
requirements, `bench build`, then the caches. If CleanMyMac is installed,
doctor warns; add the bench folder to its Ignore List.

## What recovers on its own, and what does not

| Situation | What happens |
|---|---|
| A process crashes | launchd restarts the whole bench after 20 seconds |
| It crashes three times in ten minutes | Auto restart pauses and a notification appears. `benchlogs`, fix, `benchup` |
| You reboot | The bench comes back only if it was running before; `benchdown` keeps it down |
| You edit Python code | The web server reloads, the worker does not: `benchrestart` |
| You edit JS or CSS | Nothing rebuilds in the lean Procfile: `benchwatch` while you work |
| Scheduled jobs | The lean Procfile has no scheduler: `bench schedule` by hand |
| `bench update` or `bench setup procfile` | They rewrite `Procfile`. `Procfile.lean` is separate and untouched |

The bench log is `<bench>/logs/bench.log`; `benchup` keeps the tail of the
previous run in `logs/bench.previous.log`. `benchup` warns when another
running bench already uses the same web or socketio port.

## Migrating from frappe-mac 0.2 or older setups

Benches set up by frappe-mac 0.2 run under `com.frappe-mac.<bench>`.
`benchup` on such a bench says so and points at `benchbar repair`, which
moves the old agent aside and installs `com.benchbar.<bench>`, starting
the bench again if it was running. `frappe-mac` keeps working as a name
for `benchbar`.

Per process LaunchAgents (one each for web, worker, socketio and so on)
and hand made agents are listed by doctor with their launchctl state and
last exit code. Repair boots them out and moves the plists to
`~/Library/LaunchAgents-disabled/<timestamp>/`. Nothing is deleted.

Names from before 0.3.0 move over on the next `benchbar repair`: the
`# >>> frappe-mac >>>` block in `~/.zshrc` becomes a `# >>> benchbar >>>`
block in place, `frappe-mac-run.sh` in the bench becomes `benchbar-run.sh`
(the old file goes to the backups once the agent no longer uses it), and
the checkout's `.frappe-local/` folder is renamed to `.benchbar/` by the
first command that runs. Older `# >>> frappe-bench helpers >>>` blocks
are reported so you can remove them by hand.

## What benchbar writes

- `<bench>/benchbar-run.sh` and `<bench>/Procfile.lean`
- `~/Library/LaunchAgents/com.benchbar.<bench>.plist`
- the `# >>> benchbar >>>` block in `~/.zshrc` (and the
  `# >>> benchbar-path >>>` block from the installer)
- `$(brew --prefix)/etc/my.cnf.d/frappe.cnf` and
  `frappe-mac-local-only.cnf`
- the `127.0.0.1 <site>` line inside `# >>> benchbar >>>` markers in
  `/etc/hosts`
- `~/.local/bin/benchbar` and `~/.local/bin/frappe-mac`, links to the
  checkout
- the Keychain item `benchbar-mariadb`
- `<bench>/logs/.benchbar/state.json`, written by the runner
- `<bench>/.benchbar/pulls/<site>-<backup>/` (mode 0700), the download of
  `benchbar pull`: kept after a failed run so the next one resumes,
  removed after a successful one unless `--keep-staging`

Every generated file carries a `benchbar-template` header with a version
and a content hash. Do not edit inside the markers of the shell block or
the hosts block: `repair` regenerates them.

The phase scripts still work on their own: `00-mac-system-deps.sh`,
`01-install-bench-and-site.sh` and `02-background-service.sh` keep their
flags (`--yes`, `--profile`, `--dry-run`, `--offline`, `--repair-bench`).
`00` exits with code 2 only when MariaDB already has a root password that
neither the environment nor the Keychain knows. `--repair-bench` only
moves aside a folder that never became a bench; a bench with apps or
sites is always kept and sent to `benchbar repair`.

## Wiping a bench

benchbar never deletes a bench, a site or a database. To do it by hand:

```bash
benchbar uninstall-service
rm -rf ~/frappe-bench
rm -rf ~/.local/share/benchbar/.benchbar    # or the .benchbar folder of your checkout
```

Drop the site database in `mariadb -u root -p`: `SHOW DATABASES;` lists it
(the name starts with an underscore), then `DROP DATABASE` and `DROP USER`
for that name. To remove the Homebrew formulae:
`brew uninstall mariadb@10.11 redis node@20 python@3.11`.

## Things to avoid

- Do not use the unversioned Homebrew `mariadb` formula for the v15
  profile. Pin to `mariadb@10.11`.
- Do not `brew install wkhtmltopdf`. Use the official patched Qt package,
  which `benchbar repair` installs.
- Do not switch MariaDB root to `unix_socket` only. Frappe needs password
  auth.
- Do not delete `$(brew --prefix)/var/mysql` without a backup. It holds
  every database on the machine.
- Do not put the bench under an iCloud synced folder such as `~/Desktop`
  or `~/Documents`.
- Do not run `bench update` on a bench you cannot rebuild; it rewrites
  `Procfile` and can change the toolchain.
- If CleanMyMac or a similar tool is installed, add the bench folder to
  its ignore list before running any cleanup.
