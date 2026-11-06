#!/bin/bash
# Sourced by the sudo and osascript-gui mocks. mock_root_paths SCRIPT prints a root script with the
# absolute system paths of its tool and file assignment lines ("pfctl='/sbin/pfctl'", one per line, as
# lan-guard writes them) mapped to the mocks, and the two lan-guard root files to the test's
# FL_LANGUARD_ANCHOR and FL_LANGUARD_DAEMON when set. Only those assignment lines are touched, so the
# literal file text the script writes (the plist names /sbin/pfctl and the anchor) stays as root gets it.
# chown's mock is outside tests/mocks/bin, so it never shadows chown on the suite's PATH.
mock_root_paths() {
  local mocks="${BASH_SOURCE[0]%/*}" anchor="${FL_LANGUARD_ANCHOR:-/etc/pf.anchors/com.benchbar.lan}"
  local daemon="${FL_LANGUARD_DAEMON:-/Library/LaunchDaemons/com.benchbar.pf.plist}"
  printf '%s' "$1" | sed \
    -e "s#^\(pfctl=.*\)/sbin/pfctl#\1${mocks}/bin/pfctl#" \
    -e "s#^\(launchctl=.*\)/bin/launchctl#\1${mocks}/bin/launchctl#" \
    -e "s#^\(chown=.*\)/usr/sbin/chown#\1${mocks}/root/chown#" \
    -e "s#^\(fw=.*\)/usr/libexec/ApplicationFirewall/socketfilterfw#\1${mocks}/bin/socketfilterfw#" \
    -e "s#^\(anchor=.*\)/etc/pf.anchors/com.benchbar.lan#\1${anchor}#" \
    -e "s#^\(daemon=.*\)/Library/LaunchDaemons/com.benchbar.pf.plist#\1${daemon}#"
}
