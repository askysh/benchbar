### Agents and MCP

- `benchbar repair` and `benchbar pull` now print JSON when more than one bench is possible and none was chosen. Before, an agent that ran `repair --for-agent` (or `--jsonl`, or `--json`) with two benches and no `--bench-dir` got text on stderr and an empty stdout. Now stdout holds one `done` line with `exit` 1, `error` and `next_actions[]`: one action for each bench, then `benchbar list --json`, as the other commands give (#405). The text on stderr is unchanged, and a run that names its bench, or has one bench, prints what it did.
