### Mac app

- Quitting during an install, repair, app update, site change or a start, stop or restart now asks first. "Quit when it finishes" waits for the change, so a bench is never left half installed.
- A timeout or a cancel now stops the command's whole process group, not only the `benchbar` process, and a cancel is no longer reported as "did not finish within N seconds".
- A crash that happens while the Mac sleeps or the screen is locked is announced when it happens, and a crash that launchd already recovered from is announced once at wake.
- Fewer background processes: at most three `status` calls at a time, no second reload when the popover and the window open together, the room status is asked every 15 seconds unless the Sharing tab is open, and a bench that never ran is not asked every minute.
- The background check waits when macOS asks to defer it (low battery, heat).
- Only one BenchBar runs at a time, and the `benchbar` link follows the copy in `/Applications`.
