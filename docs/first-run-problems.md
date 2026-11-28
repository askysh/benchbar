---
title: "First run problems"
description: "What to do when benchbar install stops or ends with a warning on macOS or Linux: uv missing, an incomplete bench folder, a false MariaDB warning, no systemd user bus, a failed step with exit 0 and a dev server open to the network."
---

This page covers the first `benchbar install`. Each entry gives the
symptom, the cause, what 0.9.0 changed and what to do on 0.8.x. Run
`benchbar --version` to see which one you have. A problem that appears
later is on the [Troubleshooting](troubleshooting.md) page.

`install` is safe to run again. It skips what is done and picks up at the
step that stopped.

## macOS: `bench init` fails with `No such file or directory: 'uv'`

Issue [#112](https://github.com/askysh/benchbar/issues/112). You see:

```text
FileNotFoundError: [Errno 2] No such file or directory: 'uv'
[FAIL] bench init failed with exit code 1
```

**Cause.** `bench init` runs `uv`, even when bench itself came from pipx.
Releases before 0.9.0 did not install `uv`.

**Every rerun then says `Bench directory exists but is incomplete`.** The
failed init left a folder with empty `apps/`, `sites/`, `config/` and
`logs/` and no `env/`. The same runs also printed "Existing MariaDB/MySQL
may already be using port 3306", although the only MariaDB was the one
BenchBar installed.

**In 0.9.0.**

- Step 1 installs `uv` with Homebrew. A `uv` you already have is used.
- Step 2 stops before it installs anything when `uv` is still missing,
  and names the fix.
- A folder that holds only empty folders is moved to
  `~/frappe-bench.incomplete.<time>` and the init starts over. Nothing is
  deleted.
- `benchbar install --repair-bench` moves any other incomplete folder
  aside. It never moves a bench that has a site. Add `--dry-run` to see
  the move first.
- The port 3306 note no longer appears when the server is the Homebrew
  MariaDB that BenchBar manages.

**On 0.8.x.** Install `uv`, move the folder aside and run `install` again:

```bash
brew install uv
mv ~/frappe-bench ~/frappe-bench.incomplete.$(date +%Y%m%d%H%M%S)
benchbar install
```

Use your own bench folder if it is not `~/frappe-bench`. Check that the
folder holds only empty folders before you move it. The port 3306 note is
harmless in this case.

## Linux: doctor says MariaDB is not running

Issue [#114](https://github.com/askysh/benchbar/issues/114). After a fresh
install, `doctor` and the last step of `install` print:

```text
[WARN] MariaDB server: nothing listens on 3306: MariaDB is not running
   fix: sudo systemctl start mariadb
```

**Cause.** MariaDB from apt runs as the user `mysql`. A normal user cannot
see which process owns the socket, and the check took that for no server.
The warning is false: the bench works.

**In 0.8.3 and later** the check asks only whether something listens on
port 3306. The warning is gone.

**On 0.8.2.** Check the server yourself, then silence the warning:

```bash
systemctl is-active mariadb          # active
benchbar doctor --ack mariadb_version
```

The fix it suggests does nothing, because MariaDB is already running.

## Linux: `systemctl could not load` the unit, or `status` says `loaded: no`

Issue [#115](https://github.com/askysh/benchbar/issues/115). You started
`install` with `sudo -iu USER`, `su -`, cron or a provisioning script. It
stops with:

```text
[FAIL] systemctl could not load ~/.config/systemd/user/benchbar-frappe-bench.service
```

Afterwards `benchbar status` shows `loaded: no` although the bench runs.

**Cause.** These ways of running a command start no login session, so
`XDG_RUNTIME_DIR` is unset and `systemctl --user` cannot reach the user
bus. The error is `Failed to connect to bus: No medium found`.

**In 0.9.0.**

- `install` points `XDG_RUNTIME_DIR` at `/run/user/UID` after it turns on
  lingering, and waits up to 10 seconds for the user manager.
- When the manager is still missing, `install` stops with the fix and
  says that no package or bench was changed.
- `status` says `unknown (no user bus)` with the reason and the fix, in
  place of `loaded: no`.
- `benchbar doctor --prerequisites` has a `user_bus` check, so you see the
  problem before `install` changes anything.

**On 0.8.x.** Turn on lingering, set the variable and run again:

```bash
sudo loginctl enable-linger "$USER"
export XDG_RUNTIME_DIR=/run/user/$(id -u)
sleep 5
systemctl --user status
benchbar install
```

Wait a few seconds after `enable-linger`: the user manager needs them to
start. Run `benchbar install` once `systemctl --user status` prints the
manager's units and not `Failed to connect to bus`.

Or log in again with a real login (`ssh`, or the console) and run
`benchbar install` there.

## macOS and Linux: `install` printed `[FAIL]` and still exited with 0

Issue [#116](https://github.com/askysh/benchbar/issues/116). A step of the
background service phase failed, but the summary said `warning`, the exit
code was 0 and "Next steps" told you to run `benchup`. The bench had no
loaded service.

**In 0.9.0.**

- A phase with a step that failed is `failed` in the summary.
- `install` exits with 1, and the `done` line of `--for-agent` and
  `--json` has `exit` 1.
- "Next steps" starts with `benchbar repair` and `benchbar doctor`.
- `warning` stays for a run whose steps worked and whose last check has
  findings. A failed optional step (the wkhtmltopdf package, the
  `/etc/hosts` line) is also a `warning`, because the bench and its
  service are fine.

**On 0.8.x.** Do not rely on the exit code. Look for `[FAIL]` in the output,
or run `benchbar doctor` after the install. Doctor exits with 1 when any
check fails:

```bash
benchbar doctor --json > /dev/null || echo "install is not healthy"
```

Then run the `fix:` line that doctor prints under each `[FAIL]`.

## The dev server answers on other machines

Issue [#117](https://github.com/askysh/benchbar/issues/117). Before 0.9.0,
`bench serve` and socketio listened on every interface (Frappe's own
default), with the developer debugger on. On public Wi-Fi, or on a server
with a public address, anyone who knew the site name could reach it.

**In 0.9.0.** The web server and socketio listen on 127.0.0.1 only, on
macOS, Linux and WSL.

- After the update, each bench shows `Procfile.lean is outdated` once.
  Run `benchbar repair`, then `benchbar restart`. Until the restart, the
  running bench still listens on every interface, and doctor says so.
- To reach the bench from a phone or another PC by this computer's
  address, run `benchbar listen all` and `benchbar restart`.
  `benchbar listen local` undoes it. `benchbar listen` tells you which one
  the bench has. See [listen](reference/cli/other.md#listen).
- `benchbar doctor` has a `bench_listen` check: see
  [bench_listen](reference/doctor/service-checks.md#bench_listen).

**On 0.8.x.** Update to 0.9.0. Until then, block ports 8000 and 9000 for
other machines with your firewall, or work only on a network you trust.

## Windows

The tray's first run wizard sets up WSL, the distro and the bench. Problems
there are on the [Windows](windows.md#troubleshooting) page. Inside the
distro, the Linux entries above apply.
