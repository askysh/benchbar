### Command line

- `benchbar pull ... --dry-run --json` prints a `token` on its plan line, and `benchbar pull ... --apply TOKEN --yes` runs exactly that plan. The run makes the plan again after its checks and stops with "The plan changed since it was shown; nothing was changed" (exit 1) when it is not the same, for example after a newer backup appeared on the server. Without `--apply` a person at a terminal is asked as before (#177).
