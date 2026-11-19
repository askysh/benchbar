### Mac app

- VoiceOver reads a bench's state in the sidebar ("Running", "Crashed (exit 1), restarting"), and the Sharing tab says Online or Offline for a person and Passed, Warning or Failed for a check, where it showed only a colour (#164).

- Quick Switch keeps its lab on when another app holds its key, and says so under the Labs row and in the shortcuts list, instead of turning the lab off. Its shortcut is named by the letter your keyboard layout shows on that key (#164).
- Repair and the install page mark a step that was not in the plan you reviewed, when the bench changed in between (#164).
- The New Bench page has Try Again when the profile list could not be read (#164).
- Opening Settings no longer restarts the menu bar animation of a custom runner, and the Back up spinner shows only on the site being backed up (#164).

### Docs

- The custom runner guide names the real button (**Show Folder**) and the real top speed (30 frames per second) (#164).

### For contributors

- The Mac snapshot tests compare each render with a reference image and fail when a view changes (also a single status dot of the wrong colour), a missing reference fails on a pull request, and the Snapshots workflow runs on every pull request that changes `macos/`. A selected row, the page tabs and the status dots now render like the real window (#164, #43).
