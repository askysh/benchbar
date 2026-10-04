---
title: "doctor and repair"
description: "benchbar doctor, the read only health report, and benchbar repair, which applies only the fixes doctor flagged. Flags, exit codes and examples."
---

What each check means, and its fix, is in the
[Doctor and repair guide](../../guides/doctor-and-repair.md). Both
commands take the [options for every command](install.md#options-for-every-command).

## doctor

```
benchbar doctor [--json | --fix-hints] [--fetch] [--bench-dir DIR] [--profile NAME]
```

The read only health report. Every check prints `[OK]`, `[WARN]` or
`[FAIL]`, and a `fix:` line with the exact command follows every WARN
and FAIL. It changes nothing, never reads the Keychain and never touches
the network unless you pass `--fetch`.

| Flag | What it does |
|---|---|
| `--json` | Every check with its `id`, `level`, `fix_command` and `action` ([schema](../../json-schema.md#benchbar-doctor---json)) |
| `--fix-hints` | Only the fix commands of FAIL and WARN checks, failures first, one per line, each once; nothing else on stdout |
| `--fetch` | First `git fetch` the branches of the apps your focus apps need, for `dependency_behind` (20 seconds each, no prompt; only `.git` changes; not with `OFFLINE=1` or `--dry-run`) |
| `--bench-dir DIR` | The bench to check |
| `--profile NAME` | Check against another release profile than the remembered one |

Exit codes: 0 no check failed (warnings allowed); 1 at least one FAIL.
The same with `--fix-hints`, which prints nothing when all is well.

```bash
benchbar doctor --json --bench-dir ~/frappe-bench
benchbar doctor --fix-hints
```

## repair

```
benchbar repair [--dry-run] [--yes] [--json] [--bench-dir DIR] [--profile NAME]
```

Applies only the fixes doctor flagged, in dependency order, with a
backup before each change. It shows the plan and asks first. A broken
folder is moved aside, never deleted. The bench path is remembered after
the first call.

| Flag | What it does |
|---|---|
| `--dry-run` | Print the plan, change nothing |
| `-y`, `--yes` | Apply without asking (a `sudo` step still asks for the password) |
| `--json` | Events as JSON lines on stdout, the text in the run's log ([schema](../../json-schema.md#benchbar-repair---json)). Without `--yes` or `--dry-run` nothing is applied |
| `--profile NAME` | Repair toward another release profile |

Exit codes: 0 repaired, or nothing to do; 1 a step failed or the plan was
declined, a check that has a repair action still needs it after the run,
or a check FAILs and nothing in the plan can repair it.

The full output of every run is in `logs/<date>-<time>-<pid>.log` and the
backups in `backups/<date>-<time>-<pid>/`, in benchbar's state folder:
`~/.local/state/benchbar` for Homebrew, the one line installer and the
app's CLI, `.benchbar` in a git checkout. `benchbar where` shows it.

```bash
benchbar repair --dry-run
benchbar repair --yes
```
