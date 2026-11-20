### Command line

- `benchbar history [--bench PATH] [--since TIME] [--limit N] [--json]` lists every run on this machine that changed things, newest first: its `op_id`, the command line (secrets as `***`), who started it (`terminal`, `app`, `tray`, `mcp`, `agent` or `script`), the bench and site, the times, the exit, what it changed and its log. The first line of every run's log says the same. The history is `history.jsonl` in the state folder (1 MB, three older files kept), so it reaches back further than the newest 100 operation records (#185).
- `BENCHBAR_CALLER` says who started a run. The Mac app, the tray and `benchbar mcp` set it, `--for-agent` says `agent`, and without it a terminal on stdin is `terminal` and anything else `script`. It is a label, not a proof.

### Agents and MCP

- The MCP tool `benchbar_history` reads the history (`bench`, `since`, `limit`): what ran before the agent, and who started it. An entry from an MCP call names the tool and the client, and `mcp-calls.jsonl` now holds the `op_id` of the run a call started (#185).
