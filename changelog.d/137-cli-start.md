### Speed of the command line tool

- `benchbar path` (what `benchcd` runs) takes about 30 ms instead of 400 ms: it finds the bench folder and does no work for the site, the ports or the templates.
- `benchbar commands --json` takes about 0.15 s instead of 1 s (it started about 1000 subshells). The output is the same, byte for byte.
- `path`, `commands`, `where`, `list`, `status`, `--version` and `--help` load only the libraries they use, so every start of these (the app polls `status` for each bench) costs about 20 ms less. `BENCHBAR_LOAD_ALL=1` loads everything again.
- The log of a run takes its time stamps from one `date` and the shell's clock, not a process per line. A template renders in about 60 percent of the time (a line without a `__KEY__` is not searched for keys). On a color terminal of the xterm family the colors are fixed codes, so no `tput` starts (a terminal with no colors, such as xterm-mono or vt100, still asks `tput` and gets none).
