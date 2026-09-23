# Roadmap

This project stays focused on simple local Frappe / ERPNext setup flows
that are easy to audit, rerun, and adapt.

## Done in 0.2.0

- One `frappe-mac` entrypoint: install, up, down, restart, status, logs,
  fg, watch, doctor, repair, autostart, uninstall-service.
- Background service under one launchd agent per bench with a crash
  guard, migration of older per-process agents, and shell helpers.
- Idempotent runs with template version headers, backups and a lock.
- Read-only doctor with exact fixes, repair in dependency order.
- The utf8mb4 MariaDB drop-in, the shell exports and the `/etc/hosts`
  entry are written by the scripts now (the hosts entry after asking).
- A mocked test suite and shellcheck on every script.

The Windows / WSL path lives in its own repo:
[askysh/frappe_wsl_dev_server](https://github.com/askysh/frappe_wsl_dev_server).

## Near term

- **Run `mariadb-secure-installation` inline** from
  `00-mac-system-deps.sh` with the answer table printed first, instead
  of leaving it as a manual step. This is the last manual step on a fresh
  Mac besides wkhtmltopdf.
- **Install patched-Qt wkhtmltopdf** by downloading the official `.pkg`
  with checksum verification and running `installer -pkg ... -target /`.
- **Install `uv` before `bench init`** when the installed `frappe-bench`
  needs it.
- **Optional scheduler** in the lean Procfile (`frappe-mac service
  --with-schedule`) for people who develop scheduled jobs.
- **Log rotation** for `bench.log` and the worker logs on a size limit,
  without the manual `repair` step.
- **`frappe-mac doctor --fix-hints`** for agents: print only the fix
  commands, one per line.
- More failure-path tests for bench creation and app installation.

## Later

- Keep the default macOS path stable for Frappe / ERPNext v15.
- A `frappe-mac wipe` that automates the "Uninstall" recipe in the README
  behind an explicit confirmation, still never touching MariaDB data
  without a backup.
- Intel Mac verification.
