### Command line

- `benchbar run -- COMMAND` runs `migrate`, `clear-cache`, `clear-website-cache`, `build`, `run-tests`, `doctor`, `list-apps` or `version` in the right bench and site, with the bench's own environment, under a deadline (`--timeout`), with its output in the run log. A command that changes things shows a plan and a token first (`--dry-run --json`, then `--apply TOKEN --yes`); `migrate` takes a backup of the site first. Anything else, such as `update`, `console` or `execute`, is refused with exit 64 and the list (#181).

### Agents and MCP

- Three new tools: `benchbar_run_plan` and `benchbar_run` for the commands that change things, and `benchbar_run_read` for `doctor`, `list-apps` and `version`. The result has the bench command's own exit code, whether it timed out and the last lines of its output, labeled as data from the bench. Agents no longer need to leave benchbar for `bench migrate`, `clear-cache` or `run-tests` (#181).

### Docs

- The new reference page `run` lists the allowed commands, what each one needs and the exit codes. The agents guide and `AGENTS.md` tell an agent to use `benchbar run` and not raw `bench` (#181).
