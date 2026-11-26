---
title: "Doctor and repair"
description: "How to read the report of benchbar doctor, what its flags do, and how benchbar repair applies only the fixes doctor flagged."
head:
  - tag: script
    attrs:
      src: /moved/doctor-and-repair.js
      defer: true
  - tag: script
    attrs:
      src: /moved-anchors.js
      defer: true
---

```bash
benchbar doctor              # read only, exit 1 when something fails
benchbar repair --dry-run    # show the plan, change nothing
benchbar repair              # apply, with a confirmation prompt
```

Doctor is read only, with one exception: the one time move of the state
folder on the first run after an upgrade (`~/.local/share/benchbar/.benchbar`
to `~/.local/state/benchbar`), which renames and links, and never copies
or deletes.

A few names used below: the **launchd agent** is the macOS background
job that runs the bench; **honcho** is the process manager that starts
the processes listed in **`Procfile.lean`**; the **runner** is the
script the agent starts; the **stop flag** is the file that says
whether the bench was stopped on purpose (`manual`) or paused after
crashes (`crash`), so it is not restarted.

Doctor checks the Homebrew formulae, the bench env, `bench version`, the
socket.io module, the built assets that `assets.json` references, honcho,
`Procfile.lean`, the runner, the launchd agent and its last exit code,
the stop flag, the shell helpers, legacy agents, the MariaDB bind address
and charset config, the PDF engine (wkhtmltopdf, and on v16 the Chromium
frappe can use), a stray Homebrew Redis on 6379, Full Disk Access for
`crontab`, the toolchain as the bench sees it (Node, yarn, the MariaDB
server, pkg-config), honcho without `pkg_resources`, the fork safety
variables, stale processes on the bench's ports, the site
ping, whether the running bench serves every site, `/etc/hosts`, log sizes, CleanMyMac, Mole, and port clashes with
other benches. Every warning and failure names its fix. What each check
looks at, and its fix, is in the [doctor checks](../reference/doctor-checks.md).

Repair runs only the flagged fixes, in dependency order, and shows the
plan before it asks. A broken `env/` is moved to
`env.broken.<timestamp>`, never deleted. When every check passes, repair
prints `unchanged: all N checks pass, nothing to do`, and a second run
after a repair should say the same. The most common case,
a cleanup tool that removed `env/`, `node_modules` and the built assets,
is covered in [Troubleshooting](../troubleshooting.md#the-cleanup-tool-case).

## Reading the output

Each check prints one line, `[OK]`, `[WARN]` or `[FAIL]`, with its label
and a message. A `fix:` line with the exact command follows every WARN
and FAIL. `benchbar doctor --json` prints the same checks with their `id`,
`level`, `fix_command` and `action`: the id is the heading of a check
in the [doctor checks](../reference/doctor-checks.md), and the action is
what `repair` would run. The format is in the
[JSON schema](../reference/json/install-and-doctor.md#benchbar-doctor---json).

Doctor exits 1 when any check fails. Warnings alone exit 0. It never
changes anything in a bench, never asks for a password and never reads
the Keychain, so the app runs it on a timer.

A full run takes a few seconds, even with dozens of apps: doctor reads what
its checks share once, asks git about the apps several at a time and runs
the slow checks (`bench version`, `brew info`, the site ping) side by side,
then prints the rows in their usual order. `--quick` leaves the slowest out.
Set `FL_DOCTOR_JOBS=1` to run everything one after the other.

Three flags change what the report holds:

- `--prerequisites` checks a Mac before an install, without a bench: the
  first run wizard in the app shows the same list.
- `--quick` skips the checks that start brew, python, node, bench or git,
  or ask the site, and names them. `--json` lists them in
  `skipped_checks`.
- `--ack CHECK` silences one warning you have seen. It writes one line
  to the bench's state file with the message it silenced, so the warning
  returns when its message changes. `--unack CHECK` undoes it. A failure
  cannot be silenced, and `repair` ignores silenced warnings.

Checks with a repair action are fixed by `benchbar repair`. The others
name a command for you to run, because the change is a person's call
(for example which branch an app follows) or needs another app (Full
Disk Access, CleanMyMac, Mole). Commands and flags are in the
[CLI reference](../reference/cli/doctor.md).
