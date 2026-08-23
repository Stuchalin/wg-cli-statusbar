#!/bin/bash
# Removes the WGStatusBarHelper LaunchDaemon (mirror of install-daemon.sh):
# boots the service out, then deletes the plist, the binary, and the daemon
# socket left behind by a killed daemon (the server unlinks and rebinds it
# on start, so a leftover file never blocks reinstall). Run as root.
#
# Usage: uninstall-daemon.sh
set -euo pipefail

LABEL="com.stuchalin.wgstatusbar.helper"
HELPER_PATH="/Library/PrivilegedHelperTools/${LABEL}"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"
SOCKET_PATH="/var/run/wgstatusbar.sock"

[ "$(id -u)" -eq 0 ] || { echo "error: must run as root" >&2; exit 1; }

# "not loaded" is not an error; a stopped daemon must still be removable.
launchctl bootout system "$PLIST_PATH" 2>/dev/null || true

rm -f "$PLIST_PATH" "$HELPER_PATH" "$SOCKET_PATH"

echo "removed ${LABEL}"
