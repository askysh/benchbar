---
title: "doctor and repair"
description: "benchbar doctor, the read only health report, and benchbar repair, which applies only the fixes doctor flagged. Flags, exit codes and examples."
---

What each check means, and its fix, is in the
[Doctor and repair guide](../../guides/doctor-and-repair.md). Both
commands take the [options for every command](install.md#options-for-every-command).

## doctor

```
benchbar doctor [--json] [--bench-dir DIR] [--profile NAME]
```

The read only health report. Every check prints `[OK]`, `[WARN]` or
`[FAIL]`, and a `fix:` line with the exact command follows every WARN
and FAIL. It changes nothing and never reads the Keychain.

| Flag | What it does |
|---|---|
| `--json` | Every check with its `id`, `level`, `fix_command` and `action` ([schema](../../json-schema.md#benchbar-doctor---json)) |
| `--bench-dir DIR` | The bench to check |
| `--profile NAME` | Check against another release profile than the remembered one |

Exit codes: 0 no check failed (warnings allowed); 1 at least one FAIL.

```bash
benchbar doctor --json --bench-dir ~/frappe-bench
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
declined.

The full output of every run is in `.benchbar/logs/<timestamp>.log` and
the backups in `.benchbar/backups/<timestamp>/`, in the checkout.

```bash
benchbar repair --dry-run
benchbar repair --yes
```
