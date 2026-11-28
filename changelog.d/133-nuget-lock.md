### For contributors

- The Windows tray's NuGet packages are locked: each project commits a `packages.lock.json`, and the tray build and release restore with `-p:RestoreLockedMode=true`, so a changed package fails the build. To update one, edit `Directory.Packages.props` and run `dotnet restore --force-evaluate` in `windows/tray` (#133).
