### New defaults

- benchbar refuses to run as root or with `sudo`. A `sudo benchbar repair` left root owned files in your state folder, logs and bench, and the next normal run then failed on them. It asks for `sudo` itself where a step needs it.
  If an earlier run with `sudo` left such files, give them back: `sudo chown -R $USER ~/.local/state/benchbar`.
- A command that changes things (`up`, `down`, `restart`, `repair`, `service` and the like) on a bench it found on its own now says which one: `benchbar: acting on PATH (auto-detected ...)`. With `--for-agent` or `BENCHBAR_NONINTERACTIVE=1` and more than one bench known, it stops and lists them: pass `--bench-dir`.

### Command line

- A state folder that cannot be written (owned by root, read only, or a file where a folder belongs) now stops the run and names the path. Before, the first write of a setting waited for ever without a word.
- A command that fails inside benchbar now ends with `[FAIL] Command failed (exit N): COMMAND (file in function)`, where before only bash's own text or nothing was shown.
- The run lock waits up to 8 seconds for another run (the app and a terminal starting together) and says what it waits for. It compares the owner's start time as well as its pid, so a lock left by a crash is reclaimed even when another process now has that pid. A state folder that is a file gets its own message.
- Ctrl-C and timeouts give `brew`, `bench init`, `yarn` and `pip` up to 10 seconds to stop before they are killed (it was 1 second), and the temporary logs of a long command are removed when a signal ends the run.
