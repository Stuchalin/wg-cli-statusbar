#!/bin/bash
# Installs build/WGStatusBar.app into ~/Applications: quits a running copy,
# replaces the bundle wholesale (no stale files from older builds) and
# relaunches the new one.
#
# ditto, not cp -R: preserves the ad-hoc code signature and xattrs.
# The privileged daemon is NOT touched — its install/update stays in the
# app's menu (password prompt, version handshake).
#
# Usage: scripts/install-app.sh   (or: make install, which builds first)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="WGStatusBar"
SRC="build/${APP_NAME}.app"
DEST_DIR="${HOME}/Applications"
DEST="${DEST_DIR}/${APP_NAME}.app"

if [ ! -d "$SRC" ]; then
    echo "error: $SRC not found; run make release (or make install) first" >&2
    exit 1
fi

# Not present on a stock macOS.
mkdir -p "$DEST_DIR"

# Graceful quit (same path as ⌘Q); "not running" is not an error.
osascript -e "quit app \"${APP_NAME}\"" >/dev/null 2>&1 || true

# quit is an Apple event, not a kill: give the app a moment to exit so the
# relaunch below does not leave two menu-bar instances. Replacing the bundle
# under a live process is safe by unix semantics — this wait is only for that.
for _ in $(seq 1 20); do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.15
done
# Still alive (hung) — hard kill rather than a second instance.
pkill -x "$APP_NAME" 2>/dev/null || true

rm -rf "$DEST"
ditto "$SRC" "$DEST"
open -a "$DEST"

echo "Installed ${DEST}"
