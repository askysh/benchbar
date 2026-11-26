### Mac app

- The app sends the Administrator and MariaDB root passwords of an install,
  and the Administrator password of Add Site, to the command line tool on
  standard input (`--secrets-stdin`) when the tool lists the flag, so they are
  no longer in the environment of the process for the length of the run. An
  older command line tool keeps the environment (#167).
