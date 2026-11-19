### Windows tray

- While the distro is up and every bench is stopped, the tray no longer starts `benchbar.exe` on each poll, so WSL can go idle. It still asks again after an unlock, an action or when the flyout opens, and at least every 20 minutes (#167).
- The tray menu, the crash toasts, the tooltip and the WSL messages are now read from a resource file, ready for translation (#167).
- An out of memory or similar fatal error in a window now ends the tray, and the next start reports it, instead of hiding it behind "kept running" (#167).

### Docs

- The Windows guide says how the tray polls while every bench is stopped and that the install passwords stay in the child's environment for up to 90 minutes (#167).

### For contributors

- The tray tests no longer wait on the real clock: a gate or the fake clock ends each poll, so the poller tests are stable on slow runners (#167).
