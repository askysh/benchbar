### Command line

- Every command that changes things has an `op_id` (`op-20261119-101500-4242`) in its `plan`, `step`, `progress` and `done` lines and in the document of `--json`, and keeps a record of itself that `benchbar op status [OP_ID]`, `benchbar op list` and `benchbar op wait OP_ID [--timeout SECS]` read: the step it is on, its last progress line, its exit. A run that was killed without a `done` line is shown as `interrupted`. The newest 100 records are kept (#180).
- `--background` on `install`, `repair`, `pull`, `app add`, `app update`, `site add`, `site backup` and `site restore` starts the run detached and prints its op_id at once. It needs `--yes` and the inputs in the environment, because nothing can be asked of a run nobody watches; `op status --json` carries the run's `done` line as `result` when it ends (#180).

### Agents and MCP

- The MCP tool `benchbar_op_status` reads one long run by `op_id`, or the ten newest, and every action returns its `op_id`. `benchbar_app_add` and `benchbar_site_restore` take `background: true` to return the `op_id` at once instead of waiting minutes. The MCP tasks primitive is left for later (#180).
