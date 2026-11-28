---
title: "JSON: ports and the Windows shim"
description: "The JSON of benchbar ports plan, setup and apply, and what benchbar.exe on Windows adds to a document."
---

The port documents, and the way the Windows shim forwards a document from WSL. The [rules for readers](../../json-schema.md#rules-for-readers) apply to all of them.

## Port management

`benchbar ports plan --json -- PATH ...` is read-only. Canonical paths are
sorted and deduplicated. The response has `schema_version: 1`, an opaque `token`,
`can_apply` (boolean), and `entries`. Each entry includes `path`, `name`, `site`,
`mode` (`automatic` or `fixed`), `current` and `proposed` port objects (`web`,
`socketio`, `redis_queue`, `redis_cache`), `conflicts` (strings), `blocked`
(string or null), `service_installed` (boolean), and `setup_plan` (string, or null when setup is blocked):
the adoption dry-run output for the proposed allocation, including service
and hosts changes. The approval token covers this plan.

`ports plan` without `--json` renders a readable preview. `ports setup -- PATH ...`
shows that preview and asks before applying, without manual token copying.
`ports setup --dry-run` only previews. Plan, setup and apply use each bench’s
detected site/profile and reject `--site` or `--profile` overrides.

`ports apply TOKEN --yes -- PATH ...` recomputes the selection under the CLI lock;
a changed token or any blocked entry fails before adoption. With `--json` it
streams (`plan`, `step`, `progress`, `done`, as `adopt` does; `state_after` is
null because it touches several benches); without it, it prints human
progress. Both name the completed paths and any failing path, and it exits nonzero on
failure. Earlier completed entries remain configured. A new preview is required
before retrying. With `BENCHBAR_SUDO=gui` it asks for the `/etc/hosts`
lines of all benches in one macOS password dialog, as `adopt` does for one
(see [the privileged steps](install-and-doctor.md#the-privileged-steps-and-benchbar_sudogui)).
Apply does not start services. Socket availability cannot be
reserved against unrelated programs; start checks again before launching.

`ports check --json --bench-dir PATH` returns `schema_version: 1`, `cli_version` (0.9; the labs and ports documents had none before), `conflicts`
(strings), `mode`, and `already_running` (boolean, positively owned running
processes). Clients may treat `up` as idempotent when `already_running` is true;
restart still needs a conflict check. It checks configured reservations and all listening PIDs,
ignoring only listeners positively identified as belonging to that bench.

`ports mode automatic|fixed --bench-dir PATH` saves the policy and reserves the
current ports without moving them. `--dry-run` does not save it. New benches
default to automatic. Fixed mode means the current allocation stays pinned until
the policy changes or an explicit CLI `--port-offset` override is requested.

## Windows shim

`benchbar.exe` runs on Windows and forwards to the CLI in the WSL distro. Its
own JSON is not the CLI's: the setup and report commands are answered by the
shim itself. The full contract, with the step ids, is in
[windows/shim/README.md](https://github.com/askysh/benchbar/blob/main/windows/shim/README.md).

- `benchbar.exe setup check --json` prints one document: `schema_version`,
  `distro`, `ready`, `reboot_pending` and `steps`. Each step has `id`,
  `status` (`ok`, `missing`, `warn` or `fail`), `title`, `detail`, `action`
  (the `setup run` action that fixes it, or null), `needs_admin` and
  `blocking`. It is read only. It also has `packaged` (true when `benchbar.exe`
  runs from the Microsoft Store package) and `data_dir` (the folder with
  `config.json`, `setup\`, `reports\` and the logs; in a package the physical
  `%LOCALAPPDATA%\Packages\<family>\LocalCache\Local\BenchBar`).
- `benchbar.exe setup run ACTION --jsonl` prints JSON lines: `step` and `log`
  events, then one `done` line. In the `done` line `changed` is a boolean (the
  action changed something), not the CLI's `changed[]` list. The line also has
  `exit`, `reboot_required`, `cancelled`, `warnings` and `next_actions`, and
  `error_id` when the action failed with a stable id (`distro_running`: the
  action must stop the running distro, and nothing was changed).
- `benchbar.exe doctor --json` (also `--jsonl` and `--for-agent`) is the CLI's
  document with one more key at the end, `windows_checks`: an array of the
  Windows side's checks (PATH, `distro`, `.wslconfig`, `keepalive`, tray,
  `cli_version`), each with `id`, `label`, `level`, `message`, `fix_command`
  and the older `status` and `fix`. `summary` counts only the CLI's checks.
  Stdout holds the document and nothing else, and the exit code is 1 when a
  Windows check has the level `fail`. With `--jsonl` the key is added to the
  `done` line. With `--fix-hints` the fix commands of
  the failing and warning Windows checks follow the CLI's.
- `benchbar.exe report-windows --json` prints one line: `schema_version`,
  `zip`, `included`, `skipped` (what was left out, and why), `issue_url`,
  `packaged` and `data_dir` (as in `setup check`).
- `benchbar.exe self-update --check --json` prints one document and exits 0
  whenever it printed: `schema_version`, `current` (this `benchbar.exe`),
  `latest` (the newest published release with a Windows zip for this PC, or
  null), `update_available` (a boolean, false when `latest` is unknown),
  `install` (`installer`, `store` or `other`), `exe`, `install_dir`, `arch`,
  `release_url`, `latest_source` (`api`, or `release_page` when GitHub's API
  was rate limited), `command` (`benchbar.exe self-update`, or null), `notes`,
  `error` (why `latest` is unknown, or null), and the CLI's side:
  `cli_distro`, `cli` (the CLI's own `self-update --check --json` document,
  asked only when the distro already runs) and `cli_error` (why `cli` is
  null). It changes nothing and never starts a distro.
