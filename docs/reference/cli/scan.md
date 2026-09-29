---
title: "scan and register"
description: "benchbar scan finds benches in a folder, read only; benchbar register remembers the ones you pick without touching their services."
---

Find the benches you already have and make benchbar remember them. The
app's **Scan Folder…** runs the same commands; see
[The menu bar app](../../app.md#find-existing-benches-in-a-folder).
Neither command writes a service file: to run a bench in the background,
`adopt` it or use [`ports setup`](ports.md#ports-setup).

## scan

```
benchbar scan PATH [--json]
```

Read only. Walks PATH and prints every bench it finds, one path per
line; a folder is a bench when it holds `sites/common_site_config.json`
or `apps/frappe`. It goes at most six folders deep and never looks
inside a bench it found. It skips hidden folders, symbolic links,
dependency and build folders (`node_modules`, `env`, `venv`,
`__pycache__`, `build`, `dist`, `vendor`), test folders (`tests`,
`test`, `fixtures`), and macOS system and media folders (`Library`,
`Applications`, `Pictures`, `Music`, `Movies`, `Volumes`, `System`,
`private`, `cores`, `dev`). The last one means a scan of `~` does not
look into `~/dev`: scan `~/dev` itself. Folders it cannot read, for
example ones macOS privacy settings block, are listed as warnings.

| Flag | What it does |
|---|---|
| `--json` | The benches, as `list` entries, and the warnings ([schema](../../json-schema.md#folder-discovery)) |

Exit codes: 0, also when nothing is found; 1 when PATH is not a
readable folder.

```bash
benchbar scan ~/dev
```

## register

```
benchbar register PATH ... [--json] [--dry-run]
```

Remembers the benches you name, so `benchbar list` and the app show
them. Every path must be a bench, or nothing is written. It adds them
to `.benchbar/registered-benches.txt` in the benchbar checkout, once
each; it does not write a service file, change the default bench or
touch the bench. To forget one, delete its line from that file.

| Flag | What it does |
|---|---|
| `--json` | Print the `list` response afterwards ([schema](../../json-schema.md#folder-discovery)) |
| `--dry-run` | Check the paths, write nothing |

Exit codes: 0; 1 when a path is not a bench.

```bash
benchbar register ~/dev/frappe-bench ~/dev/v16-bench
```
