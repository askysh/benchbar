---
title: "report and other commands"
description: "benchbar report, list, autostart, mariadb-password, uninstall-service and help: the remaining commands with flags, exit codes and examples."
---

Every command takes the [options for every command](install.md#options-for-every-command).

## report

```
benchbar report [--print]
```

Writes a redacted diagnostics zip, `~/Desktop/benchbar-report-<stamp>.zip`,
for a bug report. It holds doctor and status as JSON, the versions of
everything involved, the launchd agent, `Procfile.lean`, `state.json` and
the last 200 lines of `bench.log` and `worker.error.log`.

Site config files are never copied, only their key names. Any value
whose key looks like a password, secret, token, key, API or auth
credential is replaced by `***`. Your home folder, user name and every
name of the Mac are replaced by placeholders. `REDACTIONS.txt` inside the
zip lists what was replaced.

| Flag | What it does |
|---|---|
| `--print` | Print the same contents to the terminal instead |

Exit codes: 0; 1 when the zip could not be written.

```bash
benchbar report --print
```

Attach the zip to an issue at <https://github.com/askysh/benchbar/issues>.

## list

```
benchbar list [--json]
```

Every bench benchbar knows about: path, default site, sites, ports, and
whether its service is installed. With `--json`, the
[list schema](../../json-schema.md#benchbar-list---json).

Exit codes: 0.

```bash
benchbar list --json
```

## autostart

```
benchbar autostart on|off
```

Whether the bench may come back after login, when it was running before.
Without an argument it says which it is.

Exit codes: 0; 1 for another argument, or when the agent could not be
written.

```bash
benchbar autostart off
```

## mariadb-password

```
benchbar mariadb-password [--yes]
```

Prints the MariaDB root password kept in the Keychain (item
`benchbar-mariadb`), after asking. `--yes` skips the question.

Exit codes: 0 printed; 1 declined, or no password in the Keychain.

```bash
benchbar mariadb-password
```

## uninstall-service

```
benchbar uninstall-service [--bench-dir DIR] [--dry-run]
```

Removes the launchd agent, the runner, `Procfile.lean` and the shell
helper block of one bench, after asking. The bench, its sites, apps and
databases are not touched; the plist is moved to
`~/Library/LaunchAgents-disabled/` and the other files are backed up
first.

Exit codes: 0; 1 declined.

```bash
benchbar uninstall-service --bench-dir ~/dev/v16-bench
```

To remove BenchBar itself, see [Uninstall](../../install.md#uninstall).

## help and version

```
benchbar --help
benchbar --version
```

`--help` (or `-h`, or `benchbar help`) prints every command and option.
`--version` prints `benchbar` and the version.
