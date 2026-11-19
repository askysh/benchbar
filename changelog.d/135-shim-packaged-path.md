### benchbar.exe

- `benchbar.exe` now counts as a Microsoft Store (MSIX) copy only when it also runs from a `WindowsApps` folder. A zip or installer copy that a Store app started (a launcher's child can inherit its parent's package identity) is no longer treated as packaged, so it keeps its own data folder and its own `path install` (#135).
