### Command line

- JSON the CLI prints is always valid UTF-8 and keeps its line breaks. A stray byte in a log line, or a message cut in the middle of a character, no longer makes `logs --json`, a `done` line or `status --json` impossible to decode: the byte becomes U+FFFD and long messages are cut at a character boundary. Newlines, tabs and carriage returns in a message are kept (`\n`, `\t`, `\r`) instead of being deleted, so a git error keeps its lines (#150).
- `doctor --json` has `"site": null` for a folder `benchbar` does not know, as `status --json` does, and no longer names the default site's guess. `benchbar list` shows a bench path that holds a `|` in one column. A bench path directly under `/` is no longer written with two slashes, and `benchbar` no longer looks for a `frappe-bench` folder next to its own checkout (#150).

### Docs

- The JSON reference says how strings and numbers are written (valid UTF-8, escapes, `null` for no value, integers only), that streams are many lines, and that `ports apply --json` streams. It adds `users`, `share users`, `share start`, `share extend`, `share stop`, `share devices`, `share revoke`, `lan-guard remove` and `lan-guard allow-node` (#150).
