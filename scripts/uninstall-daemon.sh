#!/bin/bash
# Removes the WGStatusBarHelper LaunchDaemon (mirror of install-daemon.sh):
# boots the service out, then deletes the plist, the binary, the daemon
# socket left behind by a killed daemon (the server unlinks and rebinds it
# on start, so a leftover file never blocks reinstall), and the daemon's
# stderr log. Run as root.
#
# Usage: uninstall-daemon.sh
set -euo pipefail

LABEL="com.stuchalin.wgstatusbar.helper"
HELPER_PATH="/Library/PrivilegedHelperTools/${LABEL}"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"
SOCKET_PATH="/var/run/wgstatusbar.sock"
LOG_PATH="/var/log/wgstatusbar-helper.log"

[ "$(id -u)" -eq 0 ] || { echo "error: must run as root" >&2; exit 1; }

# "not loaded" is not an error; a stopped daemon must still be removable.
launchctl bootout system "$PLIST_PATH" 2>/dev/null || true

rm -f "$PLIST_PATH" "$HELPER_PATH" "${HELPER_PATH}.new" "$SOCKET_PATH" "$LOG_PATH"

echo "removed ${LABEL}"
