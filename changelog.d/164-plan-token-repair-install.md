### Command line

- `benchbar repair` and `benchbar install` print a plan token with `--dry-run --json`, and `--apply TOKEN --yes` runs exactly that plan. When the plan changed since (another terminal, a new problem, a different input), or the token is older than an hour, the run stops before any step, dialog or backup and changes nothing. A run without a token is as before (#164).

### Mac app

- Repair and the first run wizard pass the token of the plan you reviewed. When the Mac changed since, nothing runs and the sheet offers Review Again (#164).
