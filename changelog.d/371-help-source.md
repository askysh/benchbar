### Command line

- `benchbar COMMAND --help` is wrapped at 100 characters, and shows the whole text of a command: its summary and what the summary leaves out (#371).
- `benchbar commands --json` lists a few more flags (`--json` of `install`, `adopt`, `status`, `report`, `ports plan` and `ports check`, `--dry-run` of `ports setup` and `self-update`), and the help of some flags says more (`doctor --prerequisites` and `--fetch`, `install --frappe-commit`, `uninstall-service --all`, `logs --process`). The `summary` of a command stays one text.
- `benchbar` stops with a message that says where it looked, instead of going on with no commands, when it cannot read its table of commands (#371).
