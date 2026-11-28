### Command line

- `doctor` no longer ignores a stop (Ctrl+C, TERM) that arrives at the moment it starts one of its background checks; it used to run on to the end now and then (#138).
- On the bash of macOS (3.2), a command in a terminal no longer stops now and then with `printf: write error: Interrupted system call` when a background task ends while it prints a line (#138).
