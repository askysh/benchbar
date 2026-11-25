### Sharing

- The host can read out the key of a room: `benchbar share status` and the Sharing tab of the Mac app
  and the Windows tray show "Host key" with 16 digits. A guest who joins from an invite link sees the
  same digits on the join sheet, so they can tell your room from a link that only uses its name.
  `share status --json` has them as `host_key` (#159).
