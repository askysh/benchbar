---
title: "Testing BenchBar on your Mac"
description: "The ten minute guide for testers: install BenchBar, try it on a bench, and send a report."
---

Thanks for trying BenchBar. This takes about ten minutes if you already
have a bench, longer for a fresh install (Homebrew downloads and
`bench init` do most of the waiting). Three steps: install, try it, send
a report.

You need macOS 14 or later on Apple Silicon, Xcode Command Line Tools and
Homebrew. The installer checks all of that and tells you what is missing.

## 1. Install

One line, in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash
```

It clones the CLI into `~/.local/share/benchbar`, links `benchbar` into
`~/.local/bin`, adds that folder to your `~/.zshrc`, and installs the
BenchBar menu bar app into `~/Applications` when a release exists. It
prints every step before doing it and never runs `sudo` itself; only
Homebrew's own installer, if you accept it, asks for your password. At
the end it offers `benchbar adopt` for a bench it finds, or `benchbar
install`; you can say no and run them yourself as below. The last line
is `BenchBar is installed.`, and `benchbar --version` in a new Terminal
tab prints the version.

With Homebrew, `brew install askysh/tap/benchbar askysh/tap/benchbar-app`
does the same; see [Install](install.md#homebrew). Either way, the app
carries its own copy of the CLI and every `benchbar` hands off to it.

Two words you will see a lot: a **bench** is the folder that holds a
Frappe installation (its apps, its Python environment and its sites),
and a **site** is one Frappe instance inside it, with its own database
and its own address such as `http://macdev:8000`.

Then pick one:

- **You already have a bench**: run doctor on it. The examples on this
  page use `~/frappe-bench`; put your bench's folder in its place.

  ```bash
  benchbar doctor --bench-dir ~/frappe-bench
  ```

  It is read only and prints `[OK]`, `[WARN]` or `[FAIL]` per check,
  with the exact fix under every WARN and FAIL. If it looks right,
  register the bench so the app and the `bench*` helpers see it:

  ```bash
  benchbar adopt ~/frappe-bench
  ```

  `adopt` shows its plan and asks before writing `Procfile.lean` (the
  list of processes the bench runs), the runner script and the launchd
  agent (the macOS service that keeps the bench running in the
  background). It never runs `migrate`, `build` or `update`, and never
  touches your apps, sites or databases. The one exception: when the
  bench uses the same ports as another bench benchbar knows, the plan
  says so and, after asking, writes new port numbers into
  `sites/common_site_config.json` (with a backup first).

- **You have no bench yet**: run `benchbar install`. It asks for the
  folder (default `~/frappe-bench`), the site name (default `macdev`)
  and the site's Administrator password, generates a MariaDB root
  password and keeps it in your Keychain (the macOS password store),
  and does the rest, including the MariaDB setup and the patched
  wkhtmltopdf. It asks for your `sudo` password once, for the
  wkhtmltopdf package and the `/etc/hosts` line. It ends with a list of
  steps marked `done`; re-running it is always safe, and a second run
  says `unchanged`.

Open a new Terminal tab afterwards, or run `source ~/.zshrc`.

## 2. Try it

```bash
benchup            # start the bench in the background
benchstatus        # state, pid, site ping
open http://macdev:8000
benchlogs          # follow the log (Ctrl+C to stop following)
benchdown          # stop it, also across reboots
```

`benchup` ends with `bench is up: http://macdev:8000`, and `benchstatus`
shows `web ping 200` while the site answers. If you picked another site
name, use it in place of `macdev`; `benchstatus` shows the address.

Things worth checking:

- Close Terminal after `benchup`. The site should keep answering.
- Open the BenchBar app from `~/Applications`. The runner in the menu
  bar sleeps when the bench is stopped and runs when it is up. Click it
  for Start, Stop, Restart, the site, logs and a read only doctor.
- Break something on purpose, safely: stop the bench first, since its
  processes run from the Python environment in `env/`, then move that
  folder aside (moved, not deleted) and run doctor:

  ```bash
  benchdown
  mv ~/frappe-bench/env ~/frappe-bench/env.away
  benchbar doctor
  ```

  Doctor should report the missing env as a `[FAIL]` and name
  `benchbar repair` as the fix. Undo it by moving the folder back,
  `mv ~/frappe-bench/env.away ~/frappe-bench/env`, then `benchup`. Or
  let `benchbar repair` build a new env, which takes a few minutes; then
  `env.away` is left over and you can delete it once the bench runs.
- Reboot. If the bench was running it comes back on its own; if you had
  run `benchdown` it stays down.

Everything is idempotent: run `benchbar install`, `repair` or `adopt`
twice and the second run says `unchanged`.

### More to try

- **The BenchBar window**: ⌘M in the popover (or open BenchBar again from
  Spotlight). Each bench has Overview, Sites, Apps and Health. Right
  click a bench in the sidebar for its actions.
- **Add an app**: Apps, then **Add App…**. Pick one from the list or
  paste a GitHub URL; a private repo works when `git clone` of it works
  in your Terminal (SSH key or `gh auth login`). It shows the plan, then
  clones, installs on the site you picked and builds.
- **Update an app**: **Update…** on an app shows the commits it would
  take before anything changes, then backs up every site that has the
  app, fast forwards, migrates and builds.
- **Repair from the app**: Health, then **Repair…**. It lists what it
  would do before it does it.
- **The log window**: ⌘L, with search (⌘G for the next match) and a filter per process.
- **A second bench**: `benchbar install --profile v16-lts --bench-dir
  ~/v16-bench` puts a Frappe v16 bench in a new folder next to your first
  one, on its own ports; both show up in the menu bar. It asks for the
  new site's name and Administrator password, like the first install.
- **Your team's profile**: `benchbar profile create myteam --from-bench
  ~/frappe-bench` writes `~/.config/benchbar/profiles/myteam.toml` from
  a bench you already have (it only reads the bench). A teammate with
  that file runs `benchbar install --profile myteam`.
- **A coding agent**: `claude mcp add benchbar -- benchbar mcp`, then ask
  it how your benches are doing.

Coming from an older version: update as in
[Updating](install.md#updating), then run `benchbar doctor`. If it says
the runner script is outdated, `benchbar repair` rewrites it (it asks
first).

## 3. Send a report

Whether it worked or not, run:

```bash
benchbar report
```

It writes `~/Desktop/benchbar-report-<date>.zip` with the doctor and
status output, the versions of macOS, Homebrew, Python, Node, MariaDB,
Redis, bench, Frappe, ERPNext and BenchBar, the launchd agent, and the
last 200 lines of the bench and worker logs.

The zip is safe to share: site config files are reduced to their key
names, every value whose key looks like a password, secret, token, key or
API credential is replaced by `***`, and your home folder, username and
hostname are replaced by placeholders. `REDACTIONS.txt` inside the zip
lists what was replaced. `benchbar report --print` shows the same content
in the terminal if you want to look first.

Attach the zip to a new issue at
<https://github.com/askysh/benchbar/issues> with one or two lines on
what you did and what you expected. Screenshots of the app are welcome.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --uninstall
```

removes the app, the `benchbar` links and the PATH block. Then it asks,
one at a time, whether to stop each bench's launchd agent and remove it
with its runner and `Procfile.lean`, and whether to delete the checkout
in `~/.local/share/benchbar`. The logs and file backups of every
benchbar run stay in `~/.local/state/benchbar`; move that folder to the
Trash yourself when you no longer want them. Your benches, their sites
and databases, the Homebrew packages and the MariaDB password in the
Keychain stay. Add `--dry-run` after `--uninstall` to see the list
first. `benchbar uninstall-service` alone removes only the background
service of one bench. For a Homebrew install, see
[Uninstall](install.md#uninstall).

## Running the test suite (contributors)

```bash
tests/run-tests.sh                   # every test, as many at a time as you have CPUs
PARALLEL=1 tests/run-tests.sh        # one after another
tests/run-tests.sh test-doctor       # only the named tests
SHARD=2/3 tests/run-tests.sh         # the second third, as a CI shard does
```

Each test's output is printed whole when it finishes, in list order, and
a failing test does not stop the others: the run lists every failure at
the end and exits 1. `TEST_TIMEOUT` (default 600 seconds) kills a hung
test and prints its process tree. A new `tests/test-*.sh` must be added
to the list in `tests/run-tests.sh`, or the run fails.

The app and its Swift tests build with `scripts/macos-build.sh --test`.

Issues and pull requests are welcome. For a bug, attach the zip from
`benchbar report`; it contains no secrets, paths or names. Shell code
targets macOS `/bin/bash` 3.2 with no dependencies beyond the ones the
installer needs, passes shellcheck, and every command stays idempotent:
a second run changes nothing and says so. CI runs the suite on macOS,
builds the app, and uploads an unsigned bundle for every pull request.
