### Command line

- A running bench no longer lets `bench.log`, `worker.log` and `worker.error.log` grow without end: its runner cuts a log over 20 MB to its last 2000 lines, in place. Run `benchbar repair` once to give an existing bench the new runner (#143).
