### New defaults

- An option a command does not take is now an error: `benchbar repair --dry-rn --yes` stops with exit 64 (`EX_USAGE`; exit 2 stays "the MariaDB root password is unknown"), names the option and the command's usage line, and changes nothing. Before, the option was ignored and the command ran for real. A flag that needs a value (`--bench-dir`, `--site`) also stops with 64 when the value is missing, or when the next word is another option. With `--json` or `--for-agent` the refusal is JSON on stdout (`error_id` `unknown_flag` or `missing_value`, `error`, `fix`).
  To switch back, set `BENCHBAR_LENIENT_FLAGS=1`: an unknown option is then a warning on stderr and the command runs, as in 0.8; it does not cover a missing value. If a script of yours passes options a command never read, remove them, or set the variable for now.

### Agents and MCP

- Every flag a command takes is in `benchbar COMMAND --help` and `benchbar commands --json` now, including `app focus --list --auto`, `profile create --from-bench --dir`, `profile export|import|update --expect`, `lock --lock`, `report --out` and `logs -n`.
