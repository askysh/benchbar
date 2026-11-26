### Command line

- `benchbar install`, `adopt`, `repair`, `pull`, `site add` and `site drop`
  take `--secrets-stdin`: a program with no terminal (the Windows tray, an
  agent) can send the Administrator, MariaDB root and sudo passwords as
  `KEY=VALUE` lines on standard input instead of in the environment, where
  `/proc/PID/environ` shows them for the whole run. They are held in shell
  variables that are never exported, so no benchbar process, phase script or
  install child has them in its environment, also with `--background`. The
  MariaDB client now gets the root password in an option file that is a pipe
  instead of `MYSQL_PWD`. `site restore`, `site move`, `bench remove`,
  `db orphans` and `share setup` do not take the flag yet. The environment
  variables keep working (#167).
