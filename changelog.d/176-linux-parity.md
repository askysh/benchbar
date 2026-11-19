### Linux and WSL

- A bench that the crash guard pauses (or that cannot start because its ports are taken or its env is missing) now shows a desktop notification on Linux through `notify-send`. A headless server gets the record in `benchbar status` and the log. In WSL the Windows tray shows the notification, as before. Run `benchbar repair` to put the new runner in an existing bench.
- `benchbar install` on Linux takes `v16-lts` and team profiles, not only `v15-lts`. Python 3.14 comes from uv, Node 24 from fnm, and MariaDB from apt (10.11 on Ubuntu 24.04, inside the range v16 accepts). A profile whose MariaDB range excludes what apt gives is refused before anything is installed, and the message names the versions.

### Command line

- A Lab that the platform does not list stays off even when `BENCHBAR_LABS` names it. Before, `BENCHBAR_LABS=lan-rooms benchbar lan-guard install` passed the gate on Linux. The refusal now says the lab is not available on that platform.

### Docs

- The install guide has "Profiles on Linux" and "Crash notifications on Linux" sections, and the features page lists both.
