---
title: "report and other commands"
description: "benchbar report, self-update, list, console, db, autostart, mariadb-password, uninstall-service and help: the remaining commands with flags, exit codes and examples."
---

Every command takes the [options for every command](install.md#options-for-every-command).

## report

```
benchbar report [--print | --json]
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
| `--json` | Write the zip and print `{"zip": path, "redactions": n}`, the [report schema](../../json-schema.md#benchbar-report---json) the app reads |

Exit codes: 0; 1 when the zip could not be written.

```bash
benchbar report --print
```

Attach the zip to an issue at <https://github.com/askysh/benchbar/issues>.

## self-update

```
benchbar self-update [--check] [--json] [--dry-run] [--yes]
```

Updates the benchbar CLI and the BenchBar app with the one line
installer, the same command as the app's Update Now:
`curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --yes`.
It asks the GitHub API for the latest release, shows this CLI's and the
app's versions and the command, and asks before it runs. It changes no
bench and never runs `bench update`.

A CLI that is a git checkout of your own (not `~/.local/share/benchbar`)
gets `--app-only` and the `git -C PATH pull` to run; a CLI installed
some other way gets `--app-only` too. An app in a writable folder other
than `~/Applications` is replaced where it is (`BENCHBAR_APP_DIR`).

| Flag | What it does |
|---|---|
| `--check` | Only compare with the latest release |
| `--json` | The same as JSON, never runs anything: `current`, `app_version`, `app_path`, `latest`, `release_url`, `update_available` (true, false, null offline), `install` (`managed`, `checkout`, `other`), `cli_dir`, `app_only`, `app_dir`, `command`, `notes`, `error` |
| `--dry-run` | The plan and the command, nothing runs |
| `--yes` | Do not ask |

Exit codes: 0; 1 when GitHub could not be reached or the question was
answered no.

```bash
benchbar self-update --check
```

## docs

```
benchbar docs [TOPIC] [--print]
```

Opens this documentation in your browser, or the page of one topic:
`install`, `quick-start`, `app`, `sites`, `apps`, `doctor`, `teams`,
`agents`, `mcp`, `cli`, `config`, `json`, `runners`, `troubleshooting`,
`decisions`, `roadmap` or `contributing`. `benchbar docs --help` lists
every topic with its aliases.

| Flag | What it does |
|---|---|
| `--print` | Print the URL instead of opening it |

Exit codes: 0; 1 for an unknown topic.

```bash
benchbar docs doctor
```

## --version

```
benchbar --version
```

The first line is always `benchbar <version>`, which the app and scripts
read. When BenchBar.app is installed in `~/Applications` or
`/Applications`, a second line gives the app's version.

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

## console

```
benchbar console [--site NAME] [--bench-dir DIR]
```

`bench --site NAME console` in the bench folder: an IPython shell with
frappe connected to the site. Without `--site`, the bench's default site.
It replaces the benchbar process, so the terminal is bench's until you
leave with Ctrl-D. Nothing is written and no lock is taken. While the
bench is stopped, calls that need Redis (`frappe.cache`, `enqueue`) fail;
benchbar says so before it starts.

Exit codes: bench's; 1 when the site does not exist.

```bash
benchbar console --site macdev
```

## db

```
benchbar db [--site NAME] [--bench-dir DIR]
```

`bench --site NAME mariadb`: the MariaDB shell on the site's database,
logged in as the site's own database user from its `site_config.json`.
The MariaDB root password is not used and nothing is written to disk.

Exit codes: bench's; 1 when the site does not exist.

```bash
benchbar db --site macdev
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

Stops the bench (like `benchbar down`), then removes its launchd agent,
the runner and `Procfile.lean`, after asking. It also removes the
`# >>> benchbar >>>` block from your shell rc file, so `benchup` and the
other helpers are gone for every bench until `benchbar repair` or
`benchbar service` on a remaining bench writes the block again. The
bench, its sites, apps and databases are not touched; the plist is moved
to `~/Library/LaunchAgents-disabled/` and the other files are backed up
first. `--dry-run` shows the steps.

When the folder is no longer a bench (emptied by a cleanup tool, or
deleted) but its agent is still installed, it removes only that agent:
every `com.benchbar.*` agent whose working directory is the path is
booted out and its plist moved aside. Such an agent otherwise restarts
every 20 seconds, exits with code 127 and fills the log; doctor's
[`dead_agents`](../../guides/doctor-and-repair.md#dead_agents) check
points here.

Exit codes: 0; 1 declined, or no bench and no agent at the path.

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
