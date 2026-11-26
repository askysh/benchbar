### Command line

- `benchbar install`, `adopt`, `repair`, `pull`, `site add` and `site drop`
  take `--secrets-stdin`: a program with no terminal (the Windows tray, an
  agent) can send the Administrator, MariaDB root and sudo passwords as
  `KEY=VALUE` lines on standard input instead of in the environment, where
  `/proc/PID/environ` shows them for the whole run. They are held in shell
  variables that are never exported, so no benchbar process, phase script or
  child has them in its environment, also with `--background`. The
  environment variables keep working (#167).
