### Linux and WSL

- `benchbar share` works on Linux: `share setup`, `start`, `stop`, `extend`, `status` and the rest of the room commands, behind the `lan-rooms` lab and the Linux LAN guard (`benchbar lan-guard install`). The sharing job is a `systemd --user` unit in the runtime folder that is gone after a logout or a reboot. The room is listed on the network with `avahi-publish` when it is installed (`sudo apt install avahi-utils`); without it `share start` says the room is not listed and people join with the address and the code. Nothing keeps a laptop awake yet.

### Sharing

- The `lan-rooms` lab now lists Linux. `share status` reads the nftables guard on Linux, and the two checks that were the Mac's (the firewall list for node, the Local Network message) say what applies on Linux.
