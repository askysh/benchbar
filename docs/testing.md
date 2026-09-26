# Testing BenchBar on your Mac

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
prints every step before doing it and asks before anything that needs
`sudo` (only the `/etc/hosts` line for your site).

Then pick one:

- **You already have a bench** (for example `~/frappe-bench`): run
  `benchbar doctor --bench-dir ~/frappe-bench`. It is read only and
  prints `[OK]`, `[WARN]` or `[FAIL]` per check with the exact fix. If it
  looks right, register the bench so the app and the `bench*` helpers see
  it:

  ```bash
  benchbar adopt ~/frappe-bench
  ```

  `adopt` shows its plan and asks before writing `Procfile.lean`, the
  runner script and the launchd agent into place. It never runs
  `migrate`, `build` or `update`, and it never touches `sites/`.

- **You have no bench yet**: run `benchbar install`. It asks for two
  passwords (MariaDB root, which it stores in your Keychain, and the site
  Administrator) and does the rest, including the MariaDB setup and the
  patched wkhtmltopdf. Re-running it is always safe.

Open a new Terminal tab afterwards, or run `source ~/.zshrc`.

## 2. Try it

```bash
benchup            # start the bench in the background
benchstatus        # state, pid, site ping
open http://macdev:8000
benchlogs          # follow the log (Ctrl+C to stop following)
benchdown          # stop it, also across reboots
```

Things worth checking:

- Close Terminal after `benchup`. The site should keep answering.
- Open the BenchBar app from `~/Applications`. The runner in the menu
  bar sleeps when the bench is stopped and runs when it is up. Click it
  for Start, Stop, Restart, the site, logs and a read only doctor.
- Break something on purpose: `mv ~/frappe-bench/env ~/frappe-bench/env.away`
  then `benchbar doctor`. It should name the missing env and offer
  `benchbar repair`. Move the folder back afterwards (or let repair
  rebuild it, which takes a few minutes).
- Reboot. If the bench was running it comes back on its own; if you had
  run `benchdown` it stays down.

Everything is idempotent: run `benchbar install`, `repair` or `adopt`
twice and the second run says `unchanged`.

### New in 0.5, worth a try

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
  ~/v16-bench` puts a Frappe v16 bench next to your first one, on its own
  ports; both show up in the menu bar.
- **Your team's profile**: `benchbar profile create myteam --from-bench
  ~/frappe-bench` writes `~/.config/benchbar/profiles/myteam.toml` from
  a bench you already have (it only reads the bench). A teammate with
  that file runs `benchbar install --profile myteam`.
- **A coding agent**: `claude mcp add benchbar -- benchbar mcp`, then ask
  it how your benches are doing.

Coming from 0.4: re-run the install line above to update, then run
`benchbar doctor`. If it says the runner script is outdated, `benchbar
repair` rewrites it (it asks first).

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

removes the app, the `benchbar` links and the PATH block, and offers to
stop and remove the launchd agents. Your bench, its sites and databases
are never touched. `benchbar uninstall-service` alone removes only the
background service of one bench.

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
