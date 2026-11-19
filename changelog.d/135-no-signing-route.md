### Windows

- The Windows docs say plainly that 0.9.0 has no signed or Microsoft Store route. With Smart App Control on, the tray and `benchbar.exe` are blocked, and the page lists what you can do: run the command line inside WSL, turn Smart App Control off, or wait for a signed build.

### For contributors

- The dormant SignPath signing steps, the 6 hour package timeout and the `SIGNING_REQUIRED` gate are gone from the Windows release workflow. The signature record that feeds `README.txt` and the release notes stays.
