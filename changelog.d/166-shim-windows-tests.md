### For contributors

- The Windows only code of `benchbar.exe` (registry, PATH, job object, named mutex, the elevation call, machine architecture) now has unit tests that run on a Windows runner and on a Windows Arm64 runner, where a smoke run of the arm64 `benchbar.exe` also runs.
- The real WSL tests also check newline, carriage return and tab in arguments, a command line of about 32 KB and 1 MB of binary stdin.
