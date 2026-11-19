### Windows tray

- The tray's model and files can follow the Microsoft Store (MSIX) package: in a package its files live in the package's data folder, the logon switch reads the package's startup task, and a restart by Windows after an update runs `benchbar.exe keepalive start` once. Nothing is published to the Store in 0.9.0, and nothing changes for the one line installer's copy.
