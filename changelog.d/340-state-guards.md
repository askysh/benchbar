### Linux and WSL

- On Ubuntu 25.10 and later (uutils coreutils, also inside WSL), two runs could both hold the guard of the state folder move or of a reclaim of the settings store, because that `mkdir` reports success for a folder another run made a moment before. The guards now take their folder the way the run lock and the lease lock do since 0.9.0, so one run wins (#340).
