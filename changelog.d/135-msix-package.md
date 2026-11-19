### For contributors

- `windows/msix` holds the Microsoft Store (MSIX) package of BenchBar for Windows: the manifest, `build-msix.ps1` (a test package for sideloading, or the unsigned Store bundle and `.msixupload` for x64 and arm64) and the logos. The `MSIX package` workflow builds it on pull requests that touch the folder, the tray or the shim. It is not published and not submitted to the Store in 0.9.0.
