### Install

- macOS: `install` no longer stops at "redis-server is not running" (or "redis did not come up") while Redis runs. The check looked for a process named exactly `redis-server`, and on a Mac Redis shows as `redis-server 127.0.0.1:6379` (#139).

### Command line

- macOS: `status --json` and `list --json` print their document again. On a Mac they stopped with "FL_HOSTS_FILE: unbound variable" and printed nothing, or half a document, so the app had no state to show (#139).
