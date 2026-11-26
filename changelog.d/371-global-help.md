### Command line

- `benchbar --help` now prints each command with the short summary from the commands table, in lines of at most 100 characters, and no longer lists a command's flags under it: `benchbar COMMAND --help` has them. Some summaries read differently from before, and every command the table names (the `op`, `lease`, `labs`, `share` and `lan-guard` subcommands that the old text only mentioned) has a line of its own (#371).
- `benchbar labs` says in the global help that it lists the experiments and whether each is on (the summary of the `labs` command, also in `benchbar commands --json`).
