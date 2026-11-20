### New defaults

- Every new default of 0.9.0 now has a switch back, an upgrade note and a notice that shows once after the update. The first command you type in a terminal after updating from 0.8 or older prints the notices on stderr (not for `--json`, `--for-agent`, `benchbar mcp` or `BENCHBAR_NONINTERACTIVE=1`, and not after a fresh install). The three are: the bench listens on 127.0.0.1 only (switch back: `benchbar listen all`, `benchbar listen local` undoes it), an option a command does not take is an error with exit 64 (switch back: `BENCHBAR_LENIENT_FLAGS=1`), and `benchbar pull` neutralises the copy (switch back: `--keep-secrets`). [What's new](https://benchbar.akashmishra.com/whats-new/) lists each one.
- After the update, run `benchbar repair` once per bench: it rewrites the service files (`Procfile.lean`, the runner and the agent) and may restart a running bench itself. If it did not, run `benchbar restart`.

### Command line

- `benchbar notices` lists the notices an update left, `--dismiss ID` or `--all` hides them, `--json` prints them. `status --json` carries them as `notices[]` (`id`, `title`, `text`, `switch_back`, `doc`, `since`) until they are dismissed.

### Mac app

- The BenchBar window shows the notices of an update as a banner with a Dismiss button, which runs `benchbar notices --dismiss ID`.
