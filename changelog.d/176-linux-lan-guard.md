### Linux and WSL

- `benchbar lan-guard install`, `status` and `remove` now work on Linux: one nftables table (`inet benchbar`) that refuses the bench ports from anything but loopback, and a systemd unit that loads it at boot. `remove` deletes only that table and unit. It needs `nft` and systemd, asks for sudo once, and does not change ufw (it tells you the `ufw allow` line a room's port needs). It is not reachable yet: the `lan-rooms` lab stays macOS only until `share` runs on Linux.

### Command line

- Every `lan-guard` subcommand now stops before it asks for anything on a platform that has no guard, and `lan-guard allow-node` says it is macOS only on Linux.
