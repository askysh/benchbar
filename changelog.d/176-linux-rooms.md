### Linux and WSL

- `benchbar share` works on Linux: `share setup`, `start`, `stop`, `extend`, `status` and the rest of the room commands, behind the `lan-rooms` lab and the Linux LAN guard (`benchbar lan-guard install`). The sharing job is a `systemd --user` unit in the runtime folder that is gone after a logout or a reboot. The room is listed on the network with `avahi-publish` when it is installed (`sudo apt install avahi-utils`); without it `share start` says the room is not listed and people join with the address and the code. Nothing keeps a laptop awake yet.

- `benchbar profile show` on Linux names the MariaDB a profile gets there ("mariadb-server from apt", and the versions it accepts) instead of a Homebrew formula.
- The profile policy finds a MariaDB on port 3306 that came from apt or from a vendor repository, by the version it reports. Before, only a Homebrew path was recognised, so a running apt server was never preferred over the profile's own pick.
- `benchbar labs off NAME` removes a saved entry for a lab this platform does not list (a state file copied from a Mac), instead of saying it was already off.

### Sharing

- The `lan-rooms` lab now lists Linux. `share status` reads the nftables guard on Linux, and the two checks that were the Mac's (the firewall list for node, the Local Network message) say what applies on Linux.
