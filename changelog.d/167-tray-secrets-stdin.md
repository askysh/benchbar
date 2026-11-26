### Windows

- The tray sends the Administrator, MariaDB root and `sudo` passwords of an
  install or an adopt to `benchbar.exe` on standard input (`--secrets-stdin`)
  when the command line tool in the distro lists the flag, so they are no
  longer in an environment for the length of the run. An older command line
  tool keeps the environment path (#167).
